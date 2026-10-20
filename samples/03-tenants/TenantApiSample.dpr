program TenantApiSample;

(* Sample 03: a multi-tenant Horse API, the first step of
  docs/multitenancy-design.md. SQLite or PostgreSQL through pascal-db-faa
  (SQLdb on FPC, FireDAC on Delphi). One source for Delphi
  (TenantApiSample.dproj) and Lazarus/FPC (TenantApiSample.lpi).

    TenantApiSample [port] [--reset]       (default port 9350)
    TenantApiSample --check-key-store      (checks the key store's race, exits)

  The tenants come from TENANTS (environment or .env), by default

    acme=dedicated;globex=dedicated;initech=shared;umbrella=shared;
    soylent=shared,suspended;hooli=shared,plan:free

  On startup they are written to a control database, control.sqlite (the
  sample's stand-in for provisioning: TenantApiSample.Control), which the
  server reads through the library's TDbTenantCatalog, cached CATALOG_TTL
  seconds (default 30) by TCachedTenantCatalog.

  A dedicated tenant has its own database file, tenant_<id>.sqlite; the
  others share shared.sqlite. Every file sits in DATA_DIR (by default next to
  the executable) and gets the same migrations on startup, every tenant's,
  before the server listens (never on a tenant's first request). A database
  no request asked for in DB_IDLE_SECONDS (default 600) is closed, and
  opened again when needed. --reset deletes the files first.

  DB_ENGINE=postgresql (default sqlite) puts each of those databases on a
  PostgreSQL server instead, one database per name: control, shared and
  tenant_<id> for each dedicated tenant (tenant_acme, tenant_globex by
  default). They must exist (the migrations create the tables, not the
  databases: the stand-in for provisioning stops at the rows); --reset
  empties each one (DROP SCHEMA public CASCADE). DB_HOST (localhost),
  DB_PORT (5432), DB_USER (postgres), DB_PASSWORD; PG_CLIENT is libpq (on
  Windows the full path of a 64-bit libpq.dll, so a Delphi build for it is
  Win64; on Linux libpq.so.5 is found by default). The SQL is the same on
  both, in one directory, COMMON, behind TFallbackSqlSource.

  Signing keys: a key ring from JWT_KEYS (PascalApi.JwtKeys, phase 1 of
  docs/jwt-keys-design.md), by default three keys with development secrets
  (DEFAULT_JWT_KEYS): k2, k1, and k0 until 2026-01-01. k2 signs the login's tokens (its kid in the header); k1 still verifies,
  as after a rotation; k0 is past its NotAfter and verifies nothing. A token
  without kid verifies with JWT_SECRET (the legacy secret): the tokens the
  scenario script signs itself. A token lives at most one hour (the ring's
  MaxTokenSeconds).

  With JWT_KEY_STORE=db the keys are generated instead, one ring per tenant
  (TTenantJwtKeyRing, phase 3: kid "<tenant>/<hex>", and a tenant's key
  verifies only tokens whose tenant_id names it), kept in the control
  database (TDbJwtKeyStore, table JWT_KEYS) and rotated by the rings
  themselves (TRotatingJwtKeyRing, phase 2): every JWT_ROTATE_SECONDS (default 30 days)
  a new key, signing JWT_PROPAGATION_SECONDS later (default 120), the keys
  read again every JWT_RELOAD_SECONDS (default 60); an old key verifies one
  token lifetime after the next one signs. JWT_SECRET stays the legacy
  secret. With JWT_KEY_STORE=redis the same, kept in Redis instead
  (TRedisJwtKeyStore, src/redis; REDIS_HOST, default 127.0.0.1, REDIS_PORT,
  default 6379, and JWT_REDIS_PREFIX, default tenants-api:).
  --check-key-store stores generation 1 of a scratch scope twice through
  TDbJwtKeyStore in the control database and expects the second TryAdd to be
  False with one row left (two instances racing on a rotation), then
  removes it and exits 0, or 1 with the reason: the database adapter's
  unique violation (SQLdb on FPC, FireDAC on Delphi) is what settles the
  race, and the HTTP scenarios can't make two instances hit it at once.
  tools/http_scenarios_jwt_rotation.sh runs both with seconds. In both, the
  secrets are sealed in the store (TSealedJwtKeyStore, AES-256-GCM) under
  JWT_KEYS_MASTER_KEY, by default a development key (DEFAULT_MASTER_KEY);
  JWT_KEYS_REQUIRE_SEALED=true refuses a secret stored in plain text.

  Refresh tokens (PascalApi.RefreshTokens): kept in the control database
  (TDbRefreshTokenStore, table REFRESH_TOKENS), so every instance on it
  rotates them; the scope is the tenant, in clear in the token
  ("acme.<secret>"), checked against the catalog before any lookup. The
  access token lives ACCESS_TOKEN_SECONDS (default and at most 3600, the
  key ring's MaxTokenSeconds), the refresh token REFRESH_TOKEN_SECONDS
  (default 30 days). No users table: any name logs in, and a name starting
  with "blocked" stands for a user deactivated after the login.

  Rate limit: one window per tenant, 1000 requests a minute, 5 for the plan
  "free" (hooli). Each access line and server span carries tenant.id
  (TLoggerMiddleware.AddField); spans go to an OpenTelemetry collector when
  OTEL_EXPORTER_OTLP_ENDPOINT is set.

  The tenancy is the library's (PascalApi.Tenancy, PascalApi.Horse.Tenancy;
  it lived in this sample until it was proven). The tenant of a request is
  the token's claim TENANT_CLAIM (by default tenant_id; not tid, which
  Microsoft Entra ID uses for its own tenant), read by TTenantMiddleware.
  Nothing else names it: a header or a body field naming another tenant is
  ignored. A token with no tenant, or one the catalog doesn't have (removed
  after the token was issued), is 401; a suspended tenant is 403 with
  "code":"tenant_suspended".

  Routes:
    POST   /auth/login     public; {"tenant":"acme","user":"ana"} -> {"token",
                           "expiresIn","refreshToken","refreshExpiresIn"} (no
                           password: a sample). 404 for an unknown tenant, the
                           same for every name; 403 suspended
    POST   /auth/refresh   public; {"refreshToken":"acme.<secret>"} -> the next
                           pair. 401 invalid_refresh_token for any reason (an
                           unknown tenant too); 403 suspended
    POST   /auth/logout    public; {"refreshToken":"..."} -> 204, whatever the token
    GET    /tenant         the caller's tenant and its mode
    GET    /cities         the tenant's cities, by name
    GET    /cities/:code   404 when the tenant has none with this code
    POST   /cities         {"code":"4205407","name":"...","state":"SC","population":123}
                           201; 409 when the tenant already has the code
    DELETE /cities/:code   204; 404 when the tenant has none with this code
    GET    /cities/:code/details  the city and its state's name in the tenant
                           (a JOIN: TTenantFilter's ${TENANT.alias}); stateName
                           null when the tenant hasn't registered the state
    POST   /states         {"code":"SC","name":"Santa Catarina"}; 201; 409 when
                           the tenant already has the code
    GET    /metrics        Prometheus text; the pools are named dedicated and shared
    GET    /health/live    200 while the process answers
    GET    /swagger        Swagger UI; /swagger/doc.json is the OpenAPI document

  tools/http_scenarios_tenants.sh checks all of this over HTTP, the
  cross-tenant attempts first among them. *)

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}
  cthreads,
  cwstring,
  {$ENDIF}
  SysUtils,
  Horse,
  PascalCommon.Optionals,
  PascalJsonMapper.Json,
  PascalJsonMapper.Mapper,
  PascalCommon.JsonMapper.Optionals,
  PascalDb.Interfaces,
  PascalDb.SqlSources,
  PascalDb.Migrations,
  PascalDb.Adapter.Base,
  {$IFDEF FPC}
  PascalDb.Adapter.SQLdb,
  {$ELSE}
  PascalDb.Adapter.FireDAC,
  {$ENDIF}
  PascalApi.Config,
  PascalApi.Jwt,
  PascalApi.JwtKeys,
  Redis.Types,
  Redis.Client,
  PascalApi.Redis.JwtKeys,
  PascalApi.Http,
  PascalApi.Horse.Middlewares,
  PascalApi.Horse.OpenApi,
  PascalApi.Horse.Observability,
  PascalCommon.Tracing,
  PascalCommon.SafeLog,
  PascalApi.Otlp,
  PascalApi.Tenancy,
  PascalApi.Horse.Tenancy,
  PascalApi.RefreshTokens,
  TenantApiSample.Cities in 'TenantApiSample.Cities.pas',
  TenantApiSample.Control in 'TenantApiSample.Control.pas',
  TenantApiSample.Auth in 'TenantApiSample.Auth.pas';

const
  DEFAULT_TENANTS =
    'acme=dedicated;globex=dedicated;initech=shared;umbrella=shared;soylent=shared,suspended;' +
    'hooli=shared,plan:free';
  // Requests per minute: the plan "free", and everyone else.
  FREE_LIMIT = 5;
  DEFAULT_LIMIT = 1000;
  // Development keys: never in production. k0's NotAfter is 2026-01-01.
  DEFAULT_JWT_KEYS = 'k2:development-key-2-change-me,k1:development-key-1-change-me,' +
    'k0:development-key-0-change-me@1767225600';
  TOKEN_SECONDS = 3600;
  // Development master key (the 32 bytes "development-master-key-change-me"):
  // never in production. Generate one with: openssl rand -base64 32
  DEFAULT_MASTER_KEY = 'dev:ZGV2ZWxvcG1lbnQtbWFzdGVyLWtleS1jaGFuZ2UtbWU=';

var
  GSecret, GClaim, GDataDir: string;
  GPostgreSQL: Boolean;
  GKeys: IJwtKeyRing;
  GControl: IDBFactory;
  GCatalog: ITenantCatalog;
  GResolver: ITenantDataResolver;
  GRefresh: TRefreshTokens;
  GAccessSeconds, GRefreshSeconds: Int64;

{ Tenancy }

type
  // The library's callbacks are methods on FPC (PASCALAPI_FUNCREFS: "of
  // object" there, "reference to" on Delphi).
  TSampleHooks = class
  public
    /// TTenantDataResolver's: a tenant database.
    function NewFactory(const ADatabaseKey, APoolName: string): IDBFactory;
    /// TRateLimitOptions.KeyExtractor: one window per tenant; requests with
    /// no tenant (login, health) share one.
    function RateKey(AReq: THorseRequest): string;
    /// TRateLimitOptions.LimitFor: the tenant's plan.
    function PlanLimit(AReq: THorseRequest): Integer;
    /// TRefreshUserCheck: may this user of the tenant still refresh? Here
    /// every name is a user, and one starting with "blocked" was deactivated
    /// after its login. A real API looks the user up in the tenant.
    function UserActive(const AScope, AUserId: string): Boolean;
  end;

function IsPostgreSQL: Boolean;
var
  LEngine: string;
begin
  LEngine := LowerCase(TAppConfig.Get('DB_ENGINE', 'sqlite'));
  if (LEngine <> 'sqlite') and (LEngine <> 'postgresql') then
    raise Exception.CreateFmt('DB_ENGINE must be sqlite or postgresql, not "%s"', [LEngine]);
  Result := LEngine = 'postgresql';
end;

// The database AKey (control, shared, tenant_<id>): a file in DATA_DIR on
// SQLite, a database of that name on PostgreSQL.
function NewDatabaseFactory(const AKey, APoolName: string; const ASource: ISqlSource): IDBFactory;
var
  LConfig: IDatabaseConfig; // an interface variable, never a class one (pascal-db-faa's rule)
begin
  LConfig := TDatabaseConfig.Create;
  if GPostgreSQL then
  begin
    {$IFDEF FPC}
    LConfig.ConnectionParams.Values['ConnectorType'] := 'PostgreSQL';
    LConfig.ConnectionParams.Values['HostName'] := TAppConfig.Get('DB_HOST', 'localhost');
    LConfig.ConnectionParams.Values['Port'] := TAppConfig.Get('DB_PORT', '5432');
    LConfig.ConnectionParams.Values['DatabaseName'] := AKey;
    LConfig.ConnectionParams.Values['UserName'] := TAppConfig.Get('DB_USER', 'postgres');
    LConfig.ConnectionParams.Values['Password'] := TAppConfig.Get('DB_PASSWORD', '');
    LConfig.ConnectionParams.Values['CharSet'] := 'UTF8';
    LConfig.ConnectionParams.Values['ClientLibrary'] := TAppConfig.Get('PG_CLIENT', '');
    {$ELSE}
    LConfig.ConnectionParams.Values['DriverID'] := 'PG';
    LConfig.ConnectionParams.Values['Server'] := TAppConfig.Get('DB_HOST', 'localhost');
    LConfig.ConnectionParams.Values['Port'] := TAppConfig.Get('DB_PORT', '5432');
    LConfig.ConnectionParams.Values['Database'] := AKey;
    LConfig.ConnectionParams.Values['User_Name'] := TAppConfig.Get('DB_USER', 'postgres');
    LConfig.ConnectionParams.Values['Password'] := TAppConfig.Get('DB_PASSWORD', '');
    LConfig.ConnectionParams.Values['CharacterSet'] := 'UTF8';
    LConfig.ConnectionParams.Values['VendorLib'] := TAppConfig.Get('PG_CLIENT', '');
    {$ENDIF}
    LConfig.SQLDialect := 'PostgreSQL';
    LConfig.SQLDirectory := 'PG';
  end
  else
  begin
    {$IFDEF FPC}
    LConfig.ConnectionParams.Values['ConnectorType'] := 'SQLite3';
    LConfig.ConnectionParams.Values['DatabaseName'] := GDataDir + AKey + '.sqlite';
    {$IFDEF UNIX}
    LConfig.ConnectionParams.Values['ClientLibrary'] := TAppConfig.Get('SQLITE_CLIENT', 'libsqlite3.so.0');
    {$ELSE}
    LConfig.ConnectionParams.Values['ClientLibrary'] := TAppConfig.Get('SQLITE_CLIENT', '');
    {$ENDIF}
    {$ELSE}
    LConfig.ConnectionParams.Values['DriverID'] := 'SQLite';
    LConfig.ConnectionParams.Values['Database'] := GDataDir + AKey + '.sqlite';
    {$ENDIF}
    LConfig.SQLDialect := 'SQLite';
    LConfig.SQLDirectory := 'SQLITE';
  end;
  // The database's own directory first, then the SQL both run.
  LConfig.SqlSource := TFallbackSqlSource.Create(ASource, 'COMMON');
  LConfig.PoolName := APoolName;
  LConfig.PoolIniConnections := 1;
  LConfig.PoolMaxConnections := 5;
  LConfig.PoolWaitMaxAttemps := 50;
  LConfig.PoolWaitMilliseconds := 100;
  {$IFDEF FPC}
  Result := TSQLdbFactory.Create(LConfig);
  {$ELSE}
  Result := TFDFactory.Create(LConfig);
  {$ENDIF}
end;

function TSampleHooks.NewFactory(const ADatabaseKey, APoolName: string): IDBFactory;
begin
  Result := NewDatabaseFactory(ADatabaseKey, APoolName, CitySqlSource);
end;

function TSampleHooks.RateKey(AReq: THorseRequest): string;
var
  LInfo: TTenantInfo;
begin
  if TTenantMiddleware.TryCurrent(AReq, LInfo) then
    Result := 'tenant:' + LInfo.Id
  else
    Result := 'anonymous';
end;

function TSampleHooks.PlanLimit(AReq: THorseRequest): Integer;
var
  LInfo: TTenantInfo;
begin
  Result := 0; // the options' Limit
  if TTenantMiddleware.TryCurrent(AReq, LInfo) and (LInfo.Plan = 'free') then
    Result := FREE_LIMIT;
end;

function TSampleHooks.UserActive(const AScope, AUserId: string): Boolean;
begin
  Result := Copy(AUserId, 1, 7) <> 'blocked';
end;

var
  GHooks: TSampleHooks;

function CitiesOf(AReq: THorseRequest): TCityRepository;
begin
  Result := TCityRepository.Create(GResolver.ScopeFor(TTenantMiddleware.Current(AReq)));
end;

{ Handlers }

function StringMember(ABody: TJsonValue; const AName: string): string;
var
  LValue: TJsonValue;
begin
  LValue := ABody.Find(AName);
  if (LValue = nil) or (LValue.Kind <> jkString) or (LValue.AsString = '') then
    raise EValidationException.Create(Format('"%s" is required.', [AName]));
  Result := LValue.AsString;
end;

// The access token: the user and the tenant, signed as the middleware
// verifies (the ring's signing key, its kid).
function AccessToken(const ATenant, AUser: string): string;
var
  LWriter: TJsonWriter;
begin
  LWriter := TJsonWriter.Create;
  try
    LWriter.BeginObject;
    LWriter.Name('sub');
    LWriter.WriteString(AUser);
    LWriter.Name(GClaim);
    LWriter.WriteString(ATenant);
    LWriter.Name('exp');
    LWriter.WriteInt64(TJwt.UnixNow + GAccessSeconds);
    LWriter.EndObject;
    Result := TJwtMiddleware.Sign(LWriter.ToString);
  finally
    LWriter.Free;
  end;
end;

procedure SendTokens(ARes: THorseResponse; const ATenant, AUser, ARefreshToken: string);
var
  LTokens: TTokens;
  LResult: ITokens;
begin
  LTokens := TTokens.Create;
  LResult := LTokens;
  LTokens.Token := AccessToken(ATenant, AUser);
  LTokens.ExpiresIn := GAccessSeconds;
  LTokens.RefreshToken := ARefreshToken;
  LTokens.RefreshExpiresIn := GRefreshSeconds;
  // Tokens are credentials: no cache may keep them (RFC 6749, section 5.1).
  ARes.AddHeader('Cache-Control', 'no-store');
  TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<ITokens>(LResult));
end;

// One answer for every refusal, an unknown tenant included: the reason is
// for the log, not the client.
function InvalidRefreshToken: EUnauthorizedException;
begin
  Result := EUnauthorizedException.Create('Invalid or expired refresh token.',
    'invalid_refresh_token');
end;

function RefreshTokenOf(AReq: THorseRequest): string;
begin
  Result := TJsonMapper.Shared.FromJson<IRefreshRequest>(AReq.Body).RefreshToken;
  if Result = '' then
    raise EValidationException.Create('"refreshToken" is required.');
end;

procedure PostLogin(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LBody: TJsonValue;
  LTenant, LUser: string;
  LInfo: TTenantInfo;
  LStatus: Integer;
begin
  LBody := ParseJson(AReq.Body);
  try
    if LBody.Kind <> jkObject then
      raise EValidationException.Create('The body must be a JSON object.');
    LTenant := StringMember(LBody, 'tenant');
    LUser := StringMember(LBody, 'user');
  finally
    LBody.Free;
  end;
  // Before a token exists, the tenant is a name anyone can try: one answer
  // for every unknown name, so the answers don't list the customers.
  case CheckTenant(GCatalog, LTenant, LInfo) of
    tcSuspended:
      begin
        TJsonSend.Send(ARes, TenantRejection(tcSuspended, LStatus), LStatus);
        Exit;
      end;
    tcOk: ;
  else
    raise ENotFoundException.Create('Tenant not found.');
  end;
  // The refresh token's scope is the tenant: "acme.<secret>".
  SendTokens(ARes, LInfo.Id, LUser, GRefresh.Issue(LInfo.Id, LUser));
end;

procedure PostRefresh(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LToken, LTenant: string;
  LInfo: TTenantInfo;
  LNext: TRotatedRefreshToken;
  LStatus: Integer;
begin
  LToken := RefreshTokenOf(AReq);
  // The tenant is in the token, in clear: checked against the catalog
  // before any lookup. Every token here names one (no scope '').
  if not TRefreshTokens.TryParse(LToken, LTenant) then
    raise InvalidRefreshToken;
  case CheckTenant(GCatalog, LTenant, LInfo) of
    tcOk: ;
    tcSuspended:
      begin
        TJsonSend.Send(ARes, TenantRejection(tcSuspended, LStatus), LStatus);
        Exit;
      end;
  else
    raise InvalidRefreshToken; // no tenant, or one the catalog doesn't have
  end;
  try
    LNext := GRefresh.Rotate(LToken, GHooks.UserActive);
  except
    on E: ERefreshTokenRejected do
      raise InvalidRefreshToken;
  end;
  SendTokens(ARes, LInfo.Id, LNext.UserId, LNext.Token);
end;

procedure PostLogout(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LToken, LTenant: string;
  LInfo: TTenantInfo;
begin
  LToken := RefreshTokenOf(AReq);
  // A suspended tenant's user may still log out; the answer is the same
  // for any token.
  if TRefreshTokens.TryParse(LToken, LTenant) and
    (CheckTenant(GCatalog, LTenant, LInfo) in [tcOk, tcSuspended]) then
    GRefresh.Revoke(LToken);
  ARes.Status(204).Send('');
end;

procedure GetTenant(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LInfo: TTenantInfo;
  LWriter: TJsonWriter;
begin
  LInfo := TTenantMiddleware.Current(AReq);
  LWriter := TJsonWriter.Create;
  try
    LWriter.BeginObject;
    LWriter.Name('tenant');
    LWriter.WriteString(LInfo.Id);
    LWriter.Name('mode');
    LWriter.WriteString(PoolNameOf(LInfo));
    LWriter.EndObject;
    TJsonSend.Send(ARes, LWriter.ToString);
  finally
    LWriter.Free;
  end;
end;

procedure GetCities(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LCities: TCityRepository;
begin
  LCities := CitiesOf(AReq);
  try
    TJsonSend.Send(ARes, TJsonMapper.Shared.Serialize<TCityArray>(LCities.List));
  finally
    LCities.Free;
  end;
end;

procedure GetCity(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LCities: TCityRepository;
begin
  LCities := CitiesOf(AReq);
  try
    TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<ICity>(LCities.FindByCode(AReq.Params['code'])));
  finally
    LCities.Free;
  end;
end;

procedure PostCity(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LCities: TCityRepository;
begin
  LCities := CitiesOf(AReq);
  try
    TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<ICity>(
      LCities.Insert(TJsonMapper.Shared.FromJson<ICityInsert>(AReq.Body))), 201);
  finally
    LCities.Free;
  end;
end;

procedure GetCityDetails(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LCities: TCityRepository;
begin
  LCities := CitiesOf(AReq);
  try
    TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<ICityDetails>(
      LCities.Details(AReq.Params['code'])));
  finally
    LCities.Free;
  end;
end;

procedure PostState(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LCities: TCityRepository;
begin
  LCities := CitiesOf(AReq);
  try
    TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<IState>(
      LCities.InsertState(TJsonMapper.Shared.FromJson<IStateInsert>(AReq.Body))), 201);
  finally
    LCities.Free;
  end;
end;

procedure DeleteCity(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LCities: TCityRepository;
begin
  LCities := CitiesOf(AReq);
  try
    LCities.Delete(AReq.Params['code']);
  finally
    LCities.Free;
  end;
  ARes.Status(204).Send('');
end;

{ Setup }

type
  TSampleLog = class
  public
    procedure Error(const ALine: string);
    procedure Migration(const AEvent: TMigrationEvent);
    /// TRefreshTokens' OnSecurity: a family revoked for a reuse, a race or
    /// a user gone.
    procedure Security(const ALine: string);
  end;

procedure TSampleLog.Error(const ALine: string);
begin
  SafeWriteln('ERROR ' + ALine);
end;

procedure TSampleLog.Security(const ALine: string);
begin
  SafeWriteln('SECURITY ' + ALine);
end;

procedure TSampleLog.Migration(const AEvent: TMigrationEvent);
begin
  if AEvent.Kind = mekApplied then
    SafeWriteln('migration %d %s', [AEvent.Version, AEvent.ScriptName]);
end;

// Every tenant's database, once each (the shared one serves several), at
// startup: a tenant's first request never waits for a migration.
procedure MigrateAll(ALog: TSampleLog);
var
  LTenants: TArray<TTenantInfo>;
  LDone, LKey: string;
  LEngine: TDBMigrationEngine;
  I: Integer;
begin
  LTenants := GCatalog.All;
  LDone := '|';
  for I := 0 to High(LTenants) do
  begin
    LKey := DatabaseKeyOf(LTenants[I]);
    if Pos('|' + LKey + '|', LDone) > 0 then
      Continue;
    LDone := LDone + LKey + '|';
    LEngine := TDBMigrationEngine.Create(GResolver.ScopeFor(LTenants[I]).Factory, ALog.Migration);
    try
      LEngine.Execute(CityMigrations);
      SafeWriteln('database %s at version %d', [LKey, LEngine.CurrentVersion]);
    finally
      LEngine.Free;
    end;
  end;
end;

// --reset. A file another process holds open (another instance on the same
// DATA_DIR) can't be deleted on Windows: stop instead of starting on old data
// (seen: a second Delphi Win64 instance kept the first one's rows). On
// PostgreSQL the database stays and its tables go.
procedure DeleteDatabases(const ASpec: ITenantCatalog);

  procedure DeleteDatabase(const AKey: string);
  var
    LFile: string;
    LFactory: IDBFactory;
    LQuery: IQuery;
    LScope: IScopeTransaction;
  begin
    if GPostgreSQL then
    begin
      LFactory := NewDatabaseFactory(AKey, 'reset', TMemorySqlSource.Create);
      LScope := LFactory.GetPool.AcquireQuery(LQuery);
      LScope.StartTransaction;
      try
        LQuery.Sql := 'DROP SCHEMA public CASCADE';
        LQuery.ExecSql;
        LQuery.Sql := 'CREATE SCHEMA public';
        LQuery.ExecSql;
        LScope.Commit;
      except
        LScope.Rollback;
        raise;
      end;
      Exit;
    end;
    LFile := GDataDir + AKey + '.sqlite';
    if FileExists(LFile) and not DeleteFile(LFile) then
      raise Exception.CreateFmt('--reset: can''t delete %s (another instance using it?)', [LFile]);
  end;

var
  LTenants: TArray<TTenantInfo>;
  I: Integer;
begin
  DeleteDatabase('control');
  LTenants := ASpec.All;
  for I := 0 to High(LTenants) do
    DeleteDatabase(DatabaseKeyOf(LTenants[I]));
end;

// The catalog: control.sqlite, seeded from TENANTS (the sample's stand-in
// for provisioning), read through the library's TDbTenantCatalog and kept
// CATALOG_TTL seconds by TCachedTenantCatalog.
function OpenCatalog(const ASpec: ITenantCatalog; ALog: TSampleLog;
  out AControl: IDBFactory): ITenantCatalog;
var
  LControl: IDBFactory;
  LEngine: TDBMigrationEngine;
begin
  LControl := NewDatabaseFactory('control', 'control', ControlSqlSource);
  LEngine := TDBMigrationEngine.Create(LControl, ALog.Migration);
  try
    LEngine.Execute(ControlMigrations);
    SafeWriteln('database control at version %d', [LEngine.CurrentVersion]);
  finally
    LEngine.Free;
  end;
  SeedTenants(LControl, ASpec);
  Result := TCachedTenantCatalog.Create(TDbTenantCatalog.Create(LControl),
    StrToIntDef(TAppConfig.Get('CATALOG_TTL', '30'), 30));
  AControl := LControl;
end;

function SecondsSetting(const AName: string; ADefault: Int64): Int64;
begin
  Result := StrToInt64Def(TAppConfig.Get(AName, ''), ADefault);
end;

// --check-key-store: two instances storing the same generation at once, as
// the database sees it. Exit code 0 when the store settles it.
function CheckKeyStore(const AControl: IDBFactory): Integer;
const
  SCOPE = 'race-check';
var
  LStore: IJwtKeyStore;
  LKey: TJwtKey;
  LKeys: TJwtKeyArray;
  LFirst, LSecond: Boolean;
  I: Integer;
begin
  Result := 1;
  try
    LStore := TDbJwtKeyStore.Create(AControl);
    LKeys := LStore.Load(SCOPE); // a check stopped halfway
    for I := 0 to High(LKeys) do
      LStore.Delete(SCOPE, LKeys[I].Kid);
    LKey := TJwtKey.Create(SCOPE + '/aaaaaaaaaaaaaaaa', 'check-secret-a');
    LKey.Generation := 1;
    LKey.CreatedAt := TJwt.UnixNow;
    LKey.ActiveFrom := LKey.CreatedAt;
    LFirst := LStore.TryAdd(SCOPE, LKey);
    LKey.Kid := SCOPE + '/bbbbbbbbbbbbbbbb';
    LKey.Secret := 'check-secret-b';
    LSecond := LStore.TryAdd(SCOPE, LKey);
    LKeys := LStore.Load(SCOPE);
    for I := 0 to High(LKeys) do
      LStore.Delete(SCOPE, LKeys[I].Kid);
    if LFirst and not LSecond and (Length(LKeys) = 1) and (LKeys[0].Secret = 'check-secret-a') then
    begin
      SafeWriteln('key store check: ok (the second TryAdd of generation 1 was False, one row)');
      Result := 0;
    end
    else
      SafeWriteln('key store check: FAILED (first %s, second %s, %d rows)',
        [BoolToStr(LFirst, True), BoolToStr(LSecond, True), Length(LKeys)]);
  except
    on E: Exception do
      SafeWriteln('key store check: FAILED, %s: %s', [E.ClassName, E.Message]);
  end;
end;

// The signing keys: JWT_KEYS (static, the default), or generated and rotated
// in the control database (JWT_KEY_STORE=db) or in Redis (redis).
function OpenKeys(const AControl: IDBFactory; ALog: TSampleLog): IJwtKeyRing;
var
  LMode: string;
  LOptions: TJwtRotationOptions;
  LStore: IJwtKeyStore;
  LMaster, LSealed: string;
  LRing: TTenantJwtKeyRing;
  LParams: TRedisParams;
begin
  LMode := LowerCase(TAppConfig.Get('JWT_KEY_STORE', 'static'));
  if LMode = 'static' then
    Exit(TStaticJwtKeyRing.Parse(TAppConfig.Get('JWT_KEYS', DEFAULT_JWT_KEYS), GSecret,
      TOKEN_SECONDS));
  if (LMode <> 'db') and (LMode <> 'redis') then
    raise EArgumentException.CreateFmt('JWT_KEY_STORE: "%s" is not static, db or redis', [LMode]);
  LOptions := TJwtRotationOptions.Default;
  LOptions.MaxTokenSeconds := TOKEN_SECONDS;
  LOptions.LegacySecret := GSecret;
  LOptions.RotateEverySeconds := SecondsSetting('JWT_ROTATE_SECONDS', LOptions.RotateEverySeconds);
  LOptions.PropagationSeconds := SecondsSetting('JWT_PROPAGATION_SECONDS',
    LOptions.PropagationSeconds);
  LOptions.ReloadSeconds := SecondsSetting('JWT_RELOAD_SECONDS', LOptions.ReloadSeconds);
  if LMode = 'db' then
    LStore := TDbJwtKeyStore.Create(AControl)
  else
  begin
    LParams := RedisDefaultParams;
    LParams.Host := TAppConfig.Get('REDIS_HOST', '127.0.0.1');
    LParams.Port := StrToIntDef(TAppConfig.Get('REDIS_PORT', '6379'), 6379);
    LParams.ClientName := 'tenants-api';
    // The store owns this client: the sample uses Redis for nothing else.
    // An API that does keeps one client and passes it here too.
    LStore := TRedisJwtKeyStore.Create(TRedisClient.Create(LParams),
      TAppConfig.Get('JWT_REDIS_PREFIX', 'tenants-api:'), True);
  end;
  // The secrets sealed in the store, under the master key.
  LMaster := TAppConfig.Get('JWT_KEYS_MASTER_KEY', DEFAULT_MASTER_KEY);
  if LMaster <> '' then
    LStore := TSealedJwtKeyStore.Create(LStore, TAesGcmSecretCipher.Create(LMaster),
      TAppConfig.GetBool('JWT_KEYS_REQUIRE_SEALED', False));
  // A reload that fails later keeps the loaded keys; the log says so.
  LRing := TTenantJwtKeyRing.Create(GCatalog, LStore, LOptions, GClaim, ALog.Error);
  Result := LRing;
  // Not BoolToStr(B, 'a', 'b'): FPC has it, Delphi's second parameter is a Boolean.
  if LMaster <> '' then
    LSealed := 'sealed'
  else
    LSealed := 'not sealed';
  SafeWriteln('JWT keys: generated, in %s, one ring per tenant (%d tenants), %s',
    [LMode, LRing.TenantCount, LSealed]);
end;

var
  GLog: TSampleLog;
  GSpec: ITenantCatalog;
  GRateLimit: TRateLimitOptions;
  GPort, I: Integer;
  GReset, GCheckKeyStore: Boolean;

begin
  {$IFDEF FPC}
  SetMultiByteConversionCodePage(CP_UTF8);
  {$ENDIF}
  // Log lines in UTF-8 on both compilers, to a file or a pipe too
  // (pascal-common-faa 1.10.0; off by default). Only SafeWriteln follows it:
  // every log line of this program goes through SafeWriteln.
  PcSetSafeLogUtf8(True);
  // A member the DTO doesn't have is a 400 with its path ("$.popultion"),
  // not silently dropped (the mapper's default ignores it).
  TJsonMapper.Shared.UnknownMembers := umError;
  GPort := 9350;
  GReset := False;
  GCheckKeyStore := False;
  for I := 1 to ParamCount do
    if ParamStr(I) = '--reset' then
      GReset := True
    else if ParamStr(I) = '--check-key-store' then
      GCheckKeyStore := True
    else
      GPort := StrToIntDef(ParamStr(I), GPort);
  GDataDir := IncludeTrailingPathDelimiter(ExpandFileName(
    TAppConfig.Get('DATA_DIR', ExtractFilePath(ParamStr(0)))));
  GPostgreSQL := IsPostgreSQL;
  GSecret := TAppConfig.Get('JWT_SECRET', 'development-secret-change-me');
  GClaim := TAppConfig.Get('TENANT_CLAIM', TENANT_DEFAULT_CLAIM);

  GLog := TSampleLog.Create;
  GHooks := TSampleHooks.Create;
  try
    GSpec := TConfigTenantCatalog.Create(TAppConfig.Get('TENANTS', DEFAULT_TENANTS));
    if GReset then
      DeleteDatabases(GSpec);
    GCatalog := OpenCatalog(GSpec, GLog, GControl);
    if GCheckKeyStore then
    begin
      ExitCode := CheckKeyStore(GControl);
      Exit;
    end;
    GKeys := OpenKeys(GControl, GLog);
    GAccessSeconds := SecondsSetting('ACCESS_TOKEN_SECONDS', TOKEN_SECONDS);
    if (GAccessSeconds < 1) or (GAccessSeconds > TOKEN_SECONDS) then
      raise EArgumentException.CreateFmt('ACCESS_TOKEN_SECONDS: 1 to %d (the key ring''s ' +
        'MaxTokenSeconds)', [TOKEN_SECONDS]);
    GRefreshSeconds := SecondsSetting('REFRESH_TOKEN_SECONDS', REFRESH_DEFAULT_LIFETIME_SECONDS);
    // In the control database: every instance on it rotates the tokens.
    GRefresh := TRefreshTokens.Create(TDbRefreshTokenStore.Create(GControl), GRefreshSeconds,
      GLog.Security);
    GResolver := TTenantDataResolver.Create(GHooks.NewFactory,
      StrToIntDef(TAppConfig.Get('DB_IDLE_SECONDS', '600'), 600));
    MigrateAll(GLog);

    if TAppConfig.Get('OTEL_EXPORTER_OTLP_ENDPOINT', '') <> '' then
      TPcTracing.Start(TPcTracingOptions.FromEnvironment('tenants-api', '1.0.0', ReadAppConfig),
        TOtlpHttpExporter.FromEnvironment, GLog.Error);
    TErrorHandlerMiddleware.Register(GLog.Error);
    // tenant.id in each access line and on each server span.
    TLoggerMiddleware.AddField('tenant.id', TenantIdOf);
    THorse.Use(TLoggerMiddleware.New(nil, alfJson));
    THorse.Use(TMetricsMiddleware.New);
    THorse.Use(TJwtMiddleware.New(GKeys, ['/health', '/metrics', '/auth/login', '/auth/refresh',
      '/auth/logout', '/swagger']));
    THorse.Use(TTenantMiddleware.New(GCatalog, GClaim));
    // After the tenant: one window per tenant, its limit by plan.
    GRateLimit := TRateLimitOptions.Default;
    GRateLimit.Limit := DEFAULT_LIMIT;
    GRateLimit.WindowSeconds := 60;
    GRateLimit.KeyExtractor := GHooks.RateKey;
    GRateLimit.LimitFor := GHooks.PlanLimit;
    THorse.Use(TRateLimitMiddleware.New(GRateLimit));
    TRouteDoc.Post('/auth/login').Summary('Get a token for one tenant (1 hour)').Tag('public')
      .Response<ITokens>(200, 'An access token and a refresh token')
      .Error(400, '"tenant" or "user" is missing')
      .Error(403, 'The tenant is suspended')
      .Error(404, 'No such tenant')
      .Register(PostLogin);
    TRouteDoc.Post('/auth/refresh').Summary('The next tokens; the refresh token is spent')
      .Tag('public')
      .Body<IRefreshRequest>
      .Response<ITokens>(200, 'The next access token and refresh token')
      .Error(400, '"refreshToken" is missing')
      .Error(401, 'invalid_refresh_token: malformed, unknown (its tenant too), expired, ' +
        'revoked or already used (a spent token that comes back revokes every token of ' +
        'its login)')
      .Error(403, 'The tenant is suspended')
      .Register(PostRefresh);
    TRouteDoc.Post('/auth/logout').Summary('Revoke a refresh token and its login').Tag('public')
      .Body<IRefreshRequest>
      .NoContent(204, 'Done (the same for any token)')
      .Error(400, '"refreshToken" is missing')
      .Register(PostLogout);
    TRouteDoc.Get('/tenant').Summary('The caller''s tenant and its mode').Tag('tenant')
      .NoContent(200, '{"tenant": "acme", "mode": "dedicated"}')
      .Error(401, 'No token, or its tenant no longer exists')
      .Error(403, 'The tenant is suspended')
      .Register(GetTenant);
    TRouteDoc.Get('/cities')
      .Summary('The tenant''s cities, by name').Tag('cities')
      .ResponseArray<ICity>(200, 'The cities')
      .Error(401, 'No token, or its tenant no longer exists')
      .Error(403, 'The tenant is suspended')
      .Register(GetCities);
    TRouteDoc.Get('/cities/:code')
      .Summary('One city of the tenant').Tag('cities')
      .PathParam('code', 'IBGE code (7 digits)')
      .Response<ICity>(200)
      .Error(404, 'The tenant has no city with this code')
      .Register(GetCity);
    TRouteDoc.Post('/cities')
      .Summary('Create a city in the tenant').Tag('cities')
      .Body<ICityInsert>
      .Response<ICity>(201, 'Created')
      .Error(400, 'Invalid data')
      .Error(409, 'The tenant already has a city with this code')
      .Register(PostCity);
    TRouteDoc.Delete('/cities/:code')
      .Summary('Delete a city of the tenant').Tag('cities')
      .PathParam('code', 'IBGE code (7 digits)')
      .NoContent(204, 'Deleted')
      .Error(404, 'The tenant has no city with this code')
      .Register(DeleteCity);
    TRouteDoc.Get('/cities/:code/details')
      .Summary('One city of the tenant and its state''s name').Tag('cities')
      .PathParam('code', 'IBGE code (7 digits)')
      .Response<ICityDetails>(200)
      .Error(404, 'The tenant has no city with this code')
      .Register(GetCityDetails);
    TRouteDoc.Post('/states')
      .Summary('Create a state in the tenant').Tag('states')
      .Body<IStateInsert>
      .Response<IState>(201, 'Created')
      .Error(400, 'Invalid data')
      .Error(409, 'The tenant already has a state with this code')
      .Register(PostState);
    TMetricsEndpoint.Register;
    THealthEndpoint.Register('/health', GLog.Error);
    TRouteDoc.Serve('/swagger', 'Cities API, multi-tenant (pascal-api-infra-faa sample 03)', '1.0.0');

    SafeWriteln('TenantApiSample listening on port %d', [GPort]);
    THorse.Listen(GPort);
  finally
    GRefresh.Free;
    GResolver := nil;
    GCatalog := nil;
    GSpec := nil;
    GHooks.Free;
    GLog.Free;
  end;
end.
