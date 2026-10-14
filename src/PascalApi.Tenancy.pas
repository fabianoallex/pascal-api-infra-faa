unit PascalApi.Tenancy;

{$I pascalapi.inc}

(* Multi-tenancy without Horse (docs/multitenancy-design.md): who the
  tenants are, which database and filter a tenant's data lives behind, and
  what a request with a bad tenant is answered. The middleware that applies
  this to a request is PascalApi.Horse.Tenancy. Opt-in: no other unit of the
  library uses this one.

  - TTenantInfo and ITenantCatalog. TConfigTenantCatalog reads one
    configuration string ("acme=dedicated,plan:gold;initech=shared;
    x=shared,suspended"), parsed once and never changed, so many threads
    read it without a lock. TDbTenantCatalog reads a control database
    through the application's SQL; TCachedTenantCatalog keeps another
    catalog's answers for a TTL (found tenants only).
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
    parameter are never set apart. ${TENANT.c} is the condition for alias c,
    for a JOIN (measured on SQLite 3.50: a bare TENANT_ID with two tables
    that have it is "ambiguous column name", and a join whose ON lacks the
    tenant returns the other tenants' joined rows).
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
    /// The application's name for what the tenant pays for ('' when none):
    /// e.g. the rate limit's TRateLimitOptions.LimitFor maps it to a limit.
    Plan: string;
  end;

  ETenantCatalogError = class(Exception);

  ITenantCatalog = interface
    ['{210FF83F-5B87-499D-AEBB-AFC26FC099D3}']
    /// False when no tenant has this id (exact, case-sensitive).
    function Find(const AId: string; out AInfo: TTenantInfo): Boolean;
    function All: TArray<TTenantInfo>;
  end;

  /// The catalog from one configuration string, entries split by ';':
  ///   acme=dedicated,plan:gold;initech=shared;soylent=shared,suspended
  /// Ids and plans are 1 to 40 characters of a-z, 0-9 and '-' (ids name
  /// databases). ETenantCatalogError for anything else, a repeated id, or
  /// an entry without dedicated/shared.
  TConfigTenantCatalog = class(TInterfacedObject, ITenantCatalog)
  private
    FItems: TArray<TTenantInfo>;
    procedure AddEntry(const AEntry: string);
  public
    constructor Create(const ASpec: string);
    function Find(const AId: string; out AInfo: TTenantInfo): Boolean;
    function All: TArray<TTenantInfo>;
  end;

  /// The catalog from a control database (not a tenant's), through the
  /// application's SQL, named in the factory's SqlLoader: AFindSql takes :ID
  /// and returns at most one row, AAllSql returns every tenant; both with
  /// the columns ID, MODE ('dedicated' or 'shared'), SUSPENDED (0 or 1) and
  /// PLAN (NULL when none). A row that breaks those rules raises
  /// ETenantCatalogError. Every call reads the database: wrap it in a
  /// TCachedTenantCatalog.
  TDbTenantCatalog = class(TInterfacedObject, ITenantCatalog)
  private
    FFactory: IDBFactory;
    FFindSql, FAllSql: string;
    function ReadInfo(const AResult: IQueryResult): TTenantInfo;
  public
    constructor Create(const AFactory: IDBFactory; const AFindSql: string = 'TENANT.BY_ID';
      const AAllSql: string = 'TENANT.ALL');
    function Find(const AId: string; out AInfo: TTenantInfo): Boolean;
    function All: TArray<TTenantInfo>;
  end;

  /// Another catalog's answers, kept for ATtlSeconds (TTicker). Only tenants
  /// found are kept: an unknown id asks the inner catalog every time (a
  /// login can name any id, so remembering misses would let clients grow
  /// the cache without bound; and a tenant just provisioned is seen at
  /// once). A change to a known tenant (suspended, plan) shows after the TTL,
  /// or at once after Invalidate/InvalidateAll (e.g. on a pascal-redis-faa
  /// Pub/Sub message, when several instances run). Thread-safe; the inner
  /// catalog is asked outside the lock.
  TCachedTenantCatalog = class(TInterfacedObject, ITenantCatalog)
  private type
    TCached = record
      Info: TTenantInfo;
      AtMs: UInt64;
    end;
  private
    FInner: ITenantCatalog;
    FTtlMs: UInt64;
    FLock: TCriticalSection;
    FItems: TDictionary<string, TCached>;
    FAll: TArray<TTenantInfo>;
    FAllAtMs: UInt64;
    FAllValid: Boolean;
  public
    constructor Create(const AInner: ITenantCatalog; ATtlSeconds: Integer);
    destructor Destroy; override;
    function Find(const AId: string; out AInfo: TTenantInfo): Boolean;
    function All: TArray<TTenantInfo>;
    procedure Invalidate(const AId: string);
    procedure InvalidateAll;
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
    /// replaced by Condition and each ${TENANT.alias} by Condition(alias),
    /// and binds :TENANT_ID when the SQL has it. One call, so the condition
    /// and its parameter can't be set apart. In a JOIN, every joined table
    /// with the column gets its own tag (in ON for the joined ones), or its
    /// rows come from every tenant. Other parameters are bound after it
    /// (setting the SQL resets them).
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
  PascalCommon.Optionals,
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
    else if Copy(LOption, 1, 5) = 'plan:' then
    begin
      LInfo.Plan := Copy(LOption, 6, MaxInt);
      if not ValidTenantId(LInfo.Plan) then
        raise ETenantCatalogError.CreateFmt('Tenant "%s": invalid plan "%s".', [LInfo.Id, LInfo.Plan]);
    end
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

{ TDbTenantCatalog }

constructor TDbTenantCatalog.Create(const AFactory: IDBFactory; const AFindSql, AAllSql: string);
begin
  inherited Create;
  if AFactory = nil then
    raise EArgumentException.Create('TDbTenantCatalog: no factory');
  FFactory := AFactory;
  FFindSql := AFindSql;
  FAllSql := AAllSql;
end;

function TDbTenantCatalog.ReadInfo(const AResult: IQueryResult): TTenantInfo;
var
  LMode: string;
  LPlan: INullString;
begin
  Result := Default(TTenantInfo);
  Result.Id := AResult.Strings['ID'];
  if not ValidTenantId(Result.Id) then
    raise ETenantCatalogError.CreateFmt('Invalid tenant id "%s" in the catalog.', [Result.Id]);
  LMode := LowerCase(Trim(AResult.Strings['MODE']));
  if LMode = 'dedicated' then
    Result.Mode := tmDedicated
  else if LMode = 'shared' then
    Result.Mode := tmShared
  else
    raise ETenantCatalogError.CreateFmt('Tenant "%s": mode "%s" in the catalog.', [Result.Id, LMode]);
  Result.Suspended := AResult.Integers['SUSPENDED'] <> 0;
  LPlan := AResult.NullableStrings['PLAN'];
  if (LPlan <> nil) and not LPlan.IsNull then
    Result.Plan := LPlan.Value;
  if (Result.Plan <> '') and not ValidTenantId(Result.Plan) then
    raise ETenantCatalogError.CreateFmt('Tenant "%s": plan "%s" in the catalog.', [Result.Id, Result.Plan]);
end;

function TDbTenantCatalog.Find(const AId: string; out AInfo: TTenantInfo): Boolean;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
begin
  AInfo := Default(TTenantInfo);
  // An id that can't be a tenant's never reaches the database.
  if not ValidTenantId(AId) then
    Exit(False);
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader[FFindSql].SQL;
    LQuery.Params.Strings['ID'] := AId;
    LResult := LQuery.Open;
    Result := not LResult.Eof;
    if Result then
      AInfo := ReadInfo(LResult);
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

function TDbTenantCatalog.All: TArray<TTenantInfo>;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
  LCount: Integer;
begin
  Result := nil;
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader[FAllSql].SQL;
    LResult := LQuery.Open;
    SetLength(Result, LResult.RecordCount);
    LCount := 0;
    while not LResult.Eof do
    begin
      if LCount >= Length(Result) then
        SetLength(Result, LCount + 16);
      Result[LCount] := ReadInfo(LResult);
      Inc(LCount);
      LResult.Next;
    end;
    SetLength(Result, LCount);
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

{ TCachedTenantCatalog }

constructor TCachedTenantCatalog.Create(const AInner: ITenantCatalog; ATtlSeconds: Integer);
begin
  inherited Create;
  if AInner = nil then
    raise EArgumentException.Create('TCachedTenantCatalog: no inner catalog');
  if ATtlSeconds <= 0 then
    raise EArgumentException.Create('TCachedTenantCatalog: the TTL must be positive');
  FInner := AInner;
  FTtlMs := UInt64(ATtlSeconds) * 1000;
  FLock := TCriticalSection.Create;
  FItems := TDictionary<string, TCached>.Create;
end;

destructor TCachedTenantCatalog.Destroy;
begin
  FItems.Free;
  FLock.Free;
  inherited;
end;

function TCachedTenantCatalog.Find(const AId: string; out AInfo: TTenantInfo): Boolean;
var
  LCached: TCached;
begin
  FLock.Acquire;
  try
    if FItems.TryGetValue(AId, LCached) and (TTicker.ElapsedMs(LCached.AtMs) < FTtlMs) then
    begin
      AInfo := LCached.Info;
      Exit(True);
    end;
  finally
    FLock.Release;
  end;
  // Outside the lock: a slow control database delays only this tenant's
  // first request, not every request. Two threads may both ask; the last
  // answer stays.
  Result := FInner.Find(AId, AInfo);
  FLock.Acquire;
  try
    if Result then
    begin
      LCached.Info := AInfo;
      LCached.AtMs := TTicker.NowMs;
      FItems.AddOrSetValue(AId, LCached);
    end
    else
      FItems.Remove(AId);
  finally
    FLock.Release;
  end;
end;

function TCachedTenantCatalog.All: TArray<TTenantInfo>;
begin
  FLock.Acquire;
  try
    if FAllValid and (TTicker.ElapsedMs(FAllAtMs) < FTtlMs) then
      Exit(Copy(FAll));
  finally
    FLock.Release;
  end;
  Result := FInner.All;
  FLock.Acquire;
  try
    FAll := Copy(Result);
    FAllAtMs := TTicker.NowMs;
    FAllValid := True;
  finally
    FLock.Release;
  end;
end;

procedure TCachedTenantCatalog.Invalidate(const AId: string);
begin
  FLock.Acquire;
  try
    FItems.Remove(AId);
    FAllValid := False;
  finally
    FLock.Release;
  end;
end;

procedure TCachedTenantCatalog.InvalidateAll;
begin
  FLock.Acquire;
  try
    FItems.Clear;
    FAllValid := False;
  finally
    FLock.Release;
  end;
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

// Each ${TENANT.alias} replaced by Condition(alias). A tag whose alias isn't
// an identifier is left as it is: the database rejects the SQL that shows it.
function ReplaceAliasedTenantTags(const ASql: string): string;
const
  OPEN_TAG = '${TENANT.';
var
  LRest: string;
  LStart, LEnd: Integer;
  LAlias: string;
  LValid: Boolean;
  I: Integer;
begin
  Result := '';
  LRest := ASql;
  LStart := Pos(OPEN_TAG, LRest);
  while LStart > 0 do
  begin
    LEnd := LStart + Length(OPEN_TAG);
    while (LEnd <= Length(LRest)) and (LRest[LEnd] <> '}') do
      Inc(LEnd);
    LAlias := Copy(LRest, LStart + Length(OPEN_TAG), LEnd - LStart - Length(OPEN_TAG));
    LValid := (LEnd <= Length(LRest)) and (LAlias <> '');
    for I := 1 to Length(LAlias) do
      if not CharInSet(LAlias[I], ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
        LValid := False;
    if LValid then
    begin
      Result := Result + Copy(LRest, 1, LStart - 1) + TTenantFilter.Condition(LAlias);
      Delete(LRest, 1, LEnd);
    end
    else
    begin
      Result := Result + Copy(LRest, 1, LStart + Length(OPEN_TAG) - 1);
      Delete(LRest, 1, LStart + Length(OPEN_TAG) - 1);
    end;
    LStart := Pos(OPEN_TAG, LRest);
  end;
  Result := Result + LRest;
end;

class procedure TTenantFilter.Prepare(const AQuery: IQuery; const AScope: TTenantDataScope;
  const ASqlName: string);
begin
  AQuery.Sql := ReplaceAliasedTenantTags(
    AScope.Factory.SqlLoader[ASqlName].ReplaceLiteral('TENANT', Condition).SQL);
  if Pos(':TENANT_ID', UpperCase(AQuery.Sql)) > 0 then
    AQuery.Params.Strings['TENANT_ID'] := AScope.Discriminator;
end;

end.
