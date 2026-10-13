unit TenantApiSample.Tenancy;

{ The tenancy pieces of sample 03, kept in the sample until the design
  (docs/multitenancy-design.md) is proven on both compilers; then they move
  to the library.

  - TTenantInfo and ITenantCatalog: who the tenants are. The sample's catalog
    comes from configuration (TENANTS), parsed once and never changed, so
    reading it from many request threads needs no lock.
  - TTenantDataScope and ITenantDataResolver: the one contract the
    repositories see (decision 2). The scope carries the database's
    IDBFactory, not just its pool: a repository also needs the factory's
    SqlLoader. The discriminator is always the tenant id, also on a
    dedicated database (decision 4: repositories always filter).
  - TTenantDataResolver: one database per dedicated tenant, one shared by the
    others (decision 3), each an IDBFactory kept by database key and created
    on first use under a lock. Pools are named by mode, never by tenant
    (decision 9). No eviction of idle pools yet: whether a closed pool takes
    back its metrics is still to be measured in pascal-db-faa.
  - TTenantFilter: the condition and its parameter, set together (decision 8).
  - CheckTenant: the claim's tenant against the catalog (decision 7). }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  SysUtils,
  SyncObjs,
  Generics.Collections,
  PascalDb.Interfaces;

type
  TTenantMode = (tmDedicated, tmShared);

  TTenantInfo = record
    Id: string;
    Mode: TTenantMode;
    Suspended: Boolean;
  end;

  ETenantCatalogError = class(Exception);

  ITenantCatalog = interface
    ['{3FBC7155-0B55-444F-90B2-69972C5F3F3C}']
    /// False when no tenant has this id (exact, case-sensitive).
    function Find(const AId: string; out AInfo: TTenantInfo): Boolean;
    function All: TArray<TTenantInfo>;
  end;

  /// The catalog from one configuration string:
  ///   acme=dedicated;initech=shared;soylent=shared,suspended
  /// Ids are 1 to 40 characters of a-z, 0-9 and '-' (they name database
  /// files). ETenantCatalogError for anything else, or a repeated id.
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
    /// The tenant's database.
    Factory: IDBFactory;
    /// The TENANT_ID value every query filters by.
    Discriminator: string;
  end;

  ITenantDataResolver = interface
    ['{C4D89A3E-5529-44D4-AB63-58825B548048}']
    function ScopeFor(const ATenant: TTenantInfo): TTenantDataScope;
  end;

  /// Creates the factory of one database: ADatabaseKey names it ('shared',
  /// 'tenant_<id>'), APoolName is the pool's metric name.
  TTenantFactoryFunc = function(const ADatabaseKey, APoolName: string): IDBFactory;

  TTenantDataResolver = class(TInterfacedObject, ITenantDataResolver)
  private
    FLock: TCriticalSection;
    FFactories: TDictionary<string, IDBFactory>;
    FNewFactory: TTenantFactoryFunc;
  public
    constructor Create(ANewFactory: TTenantFactoryFunc);
    destructor Destroy; override;
    function ScopeFor(const ATenant: TTenantInfo): TTenantDataScope;
  end;

  TTenantFilter = class
  public
    /// 'TENANT_ID = :TENANT_ID', or 'c.TENANT_ID = :TENANT_ID' for alias c.
    class function Condition(const AAlias: string = ''): string; static;
    /// Sets AQuery's SQL to the scope's ASqlName with ${TENANT} replaced by
    /// Condition, and binds :TENANT_ID when the SQL has it: one call, so the
    /// condition and its parameter can't be separated.
    class procedure Prepare(const AQuery: IQuery; const AScope: TTenantDataScope;
      const ASqlName: string); static;
  end;

  TTenantCheck = (tcOk, tcNoTenant, tcUnknown, tcSuspended);

/// The tenant a token names, against the catalog: tcNoTenant for an empty
/// id, tcUnknown when the catalog doesn't have it, tcSuspended, or tcOk with
/// AInfo filled.
function CheckTenant(const ACatalog: ITenantCatalog; const AId: string;
  out AInfo: TTenantInfo): TTenantCheck;

/// The database a tenant's data lives in: 'tenant_<id>' or 'shared'.
function DatabaseKeyOf(const ATenant: TTenantInfo): string;

/// The pool's metric name: 'dedicated' or 'shared', never the tenant.
function PoolNameOf(const ATenant: TTenantInfo): string;

implementation

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
  LRest: string;
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
    if Trim(Copy(LRest, 1, P - 1)) <> '' then
      AddEntry(Trim(Copy(LRest, 1, P - 1)));
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
    raise ETenantCatalogError.CreateFmt('Invalid tenant id "%s".', [LInfo.Id]);
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

constructor TTenantDataResolver.Create(ANewFactory: TTenantFactoryFunc);
begin
  inherited Create;
  FNewFactory := ANewFactory;
  FLock := TCriticalSection.Create;
  FFactories := TDictionary<string, IDBFactory>.Create;
end;

destructor TTenantDataResolver.Destroy;
begin
  FFactories.Free;
  FLock.Free;
  inherited;
end;

function TTenantDataResolver.ScopeFor(const ATenant: TTenantInfo): TTenantDataScope;
var
  LKey: string;
  LFactory: IDBFactory;
begin
  LKey := DatabaseKeyOf(ATenant);
  // Lookup and creation under one lock: a factory is created once even when
  // two first requests of a tenant arrive together. Creating one opens the
  // pool's first connection, so another tenant's first request waits for it.
  FLock.Acquire;
  try
    if not FFactories.TryGetValue(LKey, LFactory) then
    begin
      LFactory := FNewFactory(LKey, PoolNameOf(ATenant));
      FFactories.Add(LKey, LFactory);
    end;
  finally
    FLock.Release;
  end;
  Result.Factory := LFactory;
  Result.Discriminator := ATenant.Id;
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
