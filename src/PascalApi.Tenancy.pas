unit PascalApi.Tenancy;

{$I pascalapi.inc}

(* Multi-tenancy without Horse (docs/multitenancy-design.md): who the
  tenants are, which database and filter a tenant's data lives behind, and
  what a request with a bad tenant is answered. The middleware that applies
  this to a request is PascalApi.Horse.Tenancy. Opt-in: no other unit of the
  library uses this one.

  - TTenantInfo and ITenantCatalog. TConfigTenantCatalog reads one
    configuration string ("acme=dedicated;initech=shared;x=shared,suspended"),
    parsed once and never changed, so many threads read it without a lock.
  - TTenantDataScope and ITenantDataResolver: the one contract repositories
    see. The scope carries the database's IDBFactory (its pool and its
    SqlLoader) and the discriminator, the tenant id, always set: repositories
    filter by it in every mode.
  - TTenantDataResolver: one database per dedicated tenant ('tenant_<id>'),
    one shared by the others ('shared'); an IDBFactory per database, created
    by the application's callback on first use, under a lock. Pools are named
    by mode ('dedicated', 'shared'), never by tenant, so the pool metrics'
    cardinality doesn't grow with the tenants; pools sharing a name add up,
    and a pool gives its series back when it is freed (pascal-db-faa 0.14.0,
    its PoolMetricsTests). With AIdleSeconds > 0, a database no request
    asked for in that time is dropped (checked at most once a second, on a
    request): a request still using it keeps its factory alive until it
    ends, and the next one creates a new factory.
  - TTenantFilter.Prepare: the SQL's ${TENANT} replaced by the condition and
    :TENANT_ID bound, in one call. Measured in samples/03-tenants: an unbound
    :TENANT_ID is silent on SQLdb/SQLite (NULL, the condition matches
    nothing, a 404 with nothing in the log), so the condition and its
    parameter are never set apart.
  - CheckTenant, TenantIdFromClaims and TenantRejection: a token's tenant
    against the catalog, and the status and body of each refusal (401 no
    tenant or a removed one, 403 suspended, with "code":"tenant_suspended").
    Messages from TApiMessages.Current.

  Time through TTicker (PascalCommon.SystemContext), replaceable in tests.

  This comment uses parenthesis-asterisk: it quotes ${TENANT}, whose brace
  would close a brace comment. *)

interface

uses
  SysUtils,
  SyncObjs,
  Generics.Collections,
  PascalJsonMapper.Json,
  PascalDb.Interfaces;

const
  /// The "code" of a 403 for a suspended tenant.
  TENANT_SUSPENDED_CODE = 'tenant_suspended';
  /// The default claim that names the tenant (not "tid": Microsoft Entra ID
  /// uses it for the identity provider's own tenant).
  TENANT_DEFAULT_CLAIM = 'tenant_id';

type
  TTenantMode = (tmDedicated, tmShared);

  TTenantInfo = record
    Id: string;
    Mode: TTenantMode;
    Suspended: Boolean;
  end;

  ETenantCatalogError = class(Exception);

  ITenantCatalog = interface
    ['{210FF83F-5B87-499D-AEBB-AFC26FC099D3}']
    /// False when no tenant has this id (exact, case-sensitive).
    function Find(const AId: string; out AInfo: TTenantInfo): Boolean;
    function All: TArray<TTenantInfo>;
  end;

  /// The catalog from one configuration string, entries split by ';':
  ///   acme=dedicated;initech=shared;soylent=shared,suspended
  /// Ids are 1 to 40 characters of a-z, 0-9 and '-' (they name databases).
  /// ETenantCatalogError for anything else, a repeated id, or an entry
  /// without dedicated/shared.
  TConfigTenantCatalog = class(TInterfacedObject, ITenantCatalog)
  private
    FItems: TArray<TTenantInfo>;
    procedure AddEntry(const AEntry: string);
  public
    constructor Create(const ASpec: string);
    function Find(const AId: string; out AInfo: TTenantInfo): Boolean;
    function All: TArray<TTenantInfo>;
  end;

  TTenantDataScope = record
    /// The tenant's database: its pool and its SqlLoader.
    Factory: IDBFactory;
    /// The TENANT_ID value every query filters by.
    Discriminator: string;
  end;

  ITenantDataResolver = interface
    ['{8DB7BD6F-F108-430A-8F85-5A7712B55584}']
    function ScopeFor(const ATenant: TTenantInfo): TTenantDataScope;
  end;

  /// Creates the factory of one database: ADatabaseKey names it ('shared',
  /// 'tenant_<id>'), APoolName is its pool's metric name (pass it to
  /// IDatabaseConfig.PoolName).
  {$IFDEF PASCALAPI_FUNCREFS}
  TTenantFactoryFunc = reference to function(const ADatabaseKey, APoolName: string): IDBFactory;
  {$ELSE}
  TTenantFactoryFunc = function(const ADatabaseKey, APoolName: string): IDBFactory of object;
  {$ENDIF}

  TTenantDataResolver = class(TInterfacedObject, ITenantDataResolver)
  private type
    TEntry = record
      Factory: IDBFactory;
      LastUseMs: UInt64;
    end;
  private
    FLock: TCriticalSection;
    FEntries: TDictionary<string, TEntry>;
    FNewFactory: TTenantFactoryFunc;
    FIdleMs: UInt64;
    FLastSweepMs: UInt64;
    procedure SweepIdle(const AKeep: string; ANowMs: UInt64);
  public
    /// AIdleSeconds 0: databases are kept until the resolver is freed.
    constructor Create(const ANewFactory: TTenantFactoryFunc; AIdleSeconds: Integer = 0);
    destructor Destroy; override;
    function ScopeFor(const ATenant: TTenantInfo): TTenantDataScope;
    /// Databases currently held (for tests and diagnostics).
    function DatabaseCount: Integer;
  end;

  TTenantFilter = class
  public
    /// 'TENANT_ID = :TENANT_ID', or 'c.TENANT_ID = :TENANT_ID' for alias c.
    class function Condition(const AAlias: string = ''): string; static;
    /// Sets AQuery's SQL to the scope's SQL named ASqlName with ${TENANT}
    /// replaced by Condition, and binds :TENANT_ID when the SQL has it. One
    /// call, so the condition and its parameter can't be set apart. Other
    /// parameters are bound after it (setting the SQL resets them).
    class procedure Prepare(const AQuery: IQuery; const AScope: TTenantDataScope;
      const ASqlName: string); static;
  end;

  TTenantCheck = (tcOk, tcNoTenant, tcUnknown, tcSuspended);

/// The tenant a token names, against the catalog: tcNoTenant for an empty
/// id, tcUnknown when the catalog doesn't have it, tcSuspended, or tcOk with
/// AInfo filled.
function CheckTenant(const ACatalog: ITenantCatalog; const AId: string;
  out AInfo: TTenantInfo): TTenantCheck;

/// The string claim AClaimName of verified claims; '' when AClaims is nil,
/// the claim is absent, or it isn't a string.
function TenantIdFromClaims(AClaims: TJsonValue; const AClaimName: string): string;

/// What a request whose token names no usable tenant is answered: 401 for
/// tcNoTenant and tcUnknown (a token's tenant comes from us, so an unknown
/// one was removed after the token was issued; the client should log in
/// again), 403 with "code":"tenant_suspended" for tcSuspended. '' and 0 for
/// tcOk.
function TenantRejection(ACheck: TTenantCheck; out AStatus: Integer): string;

/// The database a tenant's data lives in: 'tenant_<id>' or 'shared'.
function DatabaseKeyOf(const ATenant: TTenantInfo): string;

/// The pool's metric name: 'dedicated' or 'shared', never the tenant.
function PoolNameOf(const ATenant: TTenantInfo): string;

implementation

uses
  PascalCommon.SystemContext,
  PascalApi.Http;

const
  SWEEP_EVERY_MS = 1000;

function ValidTenantId(const AId: string): Boolean;
var
  I: Integer;
begin
  Result := (Length(AId) >= 1) and (Length(AId) <= 40);
  if Result then
    for I := 1 to Length(AId) do
      if not CharInSet(AId[I], ['a'..'z', '0'..'9', '-']) then
        Exit(False);
end;

function CheckTenant(const ACatalog: ITenantCatalog; const AId: string;
  out AInfo: TTenantInfo): TTenantCheck;
begin
  AInfo := Default(TTenantInfo);
  if AId = '' then
    Result := tcNoTenant
  else if not ACatalog.Find(AId, AInfo) then
    Result := tcUnknown
  else if AInfo.Suspended then
    Result := tcSuspended
  else
    Result := tcOk;
end;

function TenantIdFromClaims(AClaims: TJsonValue; const AClaimName: string): string;
var
  LValue: TJsonValue;
begin
  Result := '';
  if (AClaims = nil) or (AClaims.Kind <> jkObject) then
    Exit;
  LValue := AClaims.Find(AClaimName);
  if (LValue <> nil) and (LValue.Kind = jkString) then
    Result := LValue.AsString;
end;

function TenantRejection(ACheck: TTenantCheck; out AStatus: Integer): string;
var
  LWriter: TJsonWriter;
begin
  case ACheck of
    tcNoTenant:
      begin
        AStatus := 401;
        Result := ErrorJson(TApiMessages.Current.TenantMissing);
      end;
    tcUnknown:
      begin
        AStatus := 401;
        Result := ErrorJson(TApiMessages.Current.TenantUnknown);
      end;
    tcSuspended:
      begin
        AStatus := 403;
        LWriter := TJsonWriter.Create;
        try
          LWriter.BeginObject;
          LWriter.Name('error');
          LWriter.WriteString(TApiMessages.Current.TenantSuspended);
          LWriter.Name('code');
          LWriter.WriteString(TENANT_SUSPENDED_CODE);
          LWriter.EndObject;
          Result := LWriter.ToString;
        finally
          LWriter.Free;
        end;
      end;
  else
    AStatus := 0;
    Result := '';
  end;
end;

function DatabaseKeyOf(const ATenant: TTenantInfo): string;
begin
  if ATenant.Mode = tmDedicated then
    Result := 'tenant_' + ATenant.Id
  else
    Result := 'shared';
end;

function PoolNameOf(const ATenant: TTenantInfo): string;
begin
  if ATenant.Mode = tmDedicated then
    Result := 'dedicated'
  else
    Result := 'shared';
end;

{ TConfigTenantCatalog }

constructor TConfigTenantCatalog.Create(const ASpec: string);
var
  LRest, LEntry: string;
  P: Integer;
begin
  inherited Create;
  FItems := nil;
  LRest := ASpec;
  while LRest <> '' do
  begin
    P := Pos(';', LRest);
    if P = 0 then
      P := Length(LRest) + 1;
    LEntry := Trim(Copy(LRest, 1, P - 1));
    if LEntry <> '' then
      AddEntry(LEntry);
    Delete(LRest, 1, P);
  end;
end;

procedure TConfigTenantCatalog.AddEntry(const AEntry: string);
var
  LInfo, LOther: TTenantInfo;
  LOptions, LOption: string;
  P: Integer;
  LModeSeen: Boolean;
begin
  P := Pos('=', AEntry);
  if P = 0 then
    raise ETenantCatalogError.CreateFmt('Tenant entry "%s" has no "=".', [AEntry]);
  LInfo := Default(TTenantInfo);
  LInfo.Id := Trim(Copy(AEntry, 1, P - 1));
  if not ValidTenantId(LInfo.Id) then
    raise ETenantCatalogError.CreateFmt(
      'Invalid tenant id "%s": 1 to 40 of a-z, 0-9 and "-".', [LInfo.Id]);
  if Find(LInfo.Id, LOther) then
    raise ETenantCatalogError.CreateFmt('Tenant "%s" appears twice.', [LInfo.Id]);
  LModeSeen := False;
  LOptions := Copy(AEntry, P + 1, MaxInt) + ',';
  while LOptions <> '' do
  begin
    P := Pos(',', LOptions);
    LOption := LowerCase(Trim(Copy(LOptions, 1, P - 1)));
    Delete(LOptions, 1, P);
    if LOption = 'dedicated' then
    begin
      LInfo.Mode := tmDedicated;
      LModeSeen := True;
    end
    else if LOption = 'shared' then
    begin
      LInfo.Mode := tmShared;
      LModeSeen := True;
    end
    else if LOption = 'suspended' then
      LInfo.Suspended := True
    else if LOption <> '' then
      raise ETenantCatalogError.CreateFmt('Tenant "%s": unknown option "%s".', [LInfo.Id, LOption]);
  end;
  if not LModeSeen then
    raise ETenantCatalogError.CreateFmt('Tenant "%s": dedicated or shared?', [LInfo.Id]);
  SetLength(FItems, Length(FItems) + 1);
  FItems[High(FItems)] := LInfo;
end;

function TConfigTenantCatalog.Find(const AId: string; out AInfo: TTenantInfo): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FItems) do
    if FItems[I].Id = AId then
    begin
      AInfo := FItems[I];
      Exit(True);
    end;
  AInfo := Default(TTenantInfo);
  Result := False;
end;

function TConfigTenantCatalog.All: TArray<TTenantInfo>;
begin
  Result := Copy(FItems);
end;

{ TTenantDataResolver }

constructor TTenantDataResolver.Create(const ANewFactory: TTenantFactoryFunc;
  AIdleSeconds: Integer);
begin
  inherited Create;
  if not Assigned(ANewFactory) then
    raise EArgumentException.Create('TTenantDataResolver: no factory callback');
  FNewFactory := ANewFactory;
  if AIdleSeconds > 0 then
    FIdleMs := UInt64(AIdleSeconds) * 1000
  else
    FIdleMs := 0;
  FLock := TCriticalSection.Create;
  FEntries := TDictionary<string, TEntry>.Create;
  FLastSweepMs := TTicker.NowMs;
end;

destructor TTenantDataResolver.Destroy;
begin
  FEntries.Free;
  FLock.Free;
  inherited;
end;

// Under FLock. Keys first, then removal: a dictionary isn't changed while
// it is enumerated.
procedure TTenantDataResolver.SweepIdle(const AKeep: string; ANowMs: UInt64);
var
  LPair: TPair<string, TEntry>;
  LIdle: TArray<string>;
  I: Integer;
begin
  LIdle := nil;
  for LPair in FEntries do
    if (LPair.Key <> AKeep) and (ANowMs >= LPair.Value.LastUseMs) and
      (ANowMs - LPair.Value.LastUseMs >= FIdleMs) then
    begin
      SetLength(LIdle, Length(LIdle) + 1);
      LIdle[High(LIdle)] := LPair.Key;
    end;
  for I := 0 to High(LIdle) do
    FEntries.Remove(LIdle[I]);
end;

function TTenantDataResolver.ScopeFor(const ATenant: TTenantInfo): TTenantDataScope;
var
  LKey: string;
  LEntry: TEntry;
  LNowMs: UInt64;
begin
  LKey := DatabaseKeyOf(ATenant);
  // Lookup and creation under one lock: a factory is created once even when
  // two first requests of a tenant arrive together. Creating one opens its
  // pool's first connections, so another tenant's first request waits.
  FLock.Acquire;
  try
    LNowMs := TTicker.NowMs;
    if not FEntries.TryGetValue(LKey, LEntry) then
      LEntry.Factory := FNewFactory(LKey, PoolNameOf(ATenant));
    LEntry.LastUseMs := LNowMs;
    FEntries.AddOrSetValue(LKey, LEntry);
    if (FIdleMs > 0) and (TTicker.ElapsedMs(FLastSweepMs) >= SWEEP_EVERY_MS) then
    begin
      FLastSweepMs := LNowMs;
      SweepIdle(LKey, LNowMs);
    end;
  finally
    FLock.Release;
  end;
  Result.Factory := LEntry.Factory;
  Result.Discriminator := ATenant.Id;
end;

function TTenantDataResolver.DatabaseCount: Integer;
begin
  FLock.Acquire;
  try
    Result := FEntries.Count;
  finally
    FLock.Release;
  end;
end;

{ TTenantFilter }

class function TTenantFilter.Condition(const AAlias: string): string;
begin
  if AAlias = '' then
    Result := 'TENANT_ID = :TENANT_ID'
  else
    Result := AAlias + '.TENANT_ID = :TENANT_ID';
end;

class procedure TTenantFilter.Prepare(const AQuery: IQuery; const AScope: TTenantDataScope;
  const ASqlName: string);
begin
  AQuery.Sql := AScope.Factory.SqlLoader[ASqlName].ReplaceLiteral('TENANT', Condition).SQL;
  if Pos(':TENANT_ID', UpperCase(AQuery.Sql)) > 0 then
    AQuery.Params.Strings['TENANT_ID'] := AScope.Discriminator;
end;

end.
