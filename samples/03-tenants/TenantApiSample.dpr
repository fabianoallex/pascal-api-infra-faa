program TenantApiSample;

(* Sample 03: a multi-tenant Horse API, the first step of
  docs/multitenancy-design.md. SQLite through pascal-db-faa (SQLdb on FPC,
  FireDAC on Delphi). One source for Delphi (TenantApiSample.dproj) and
  Lazarus/FPC (TenantApiSample.lpi).

    TenantApiSample [port] [--reset]       (default port 9350)

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
    POST   /auth/login     public; {"tenant":"acme","user":"ana"} -> {"token":"..."}
                           (HS256, 1 hour, no password: a sample). 404 for an
                           unknown tenant, the same for every name; 403 suspended
    GET    /tenant         the caller's tenant and its mode
    GET    /cities         the tenant's cities, by name
    GET    /cities/:code   404 when the tenant has none with this code
    POST   /cities         {"code":"4205407","name":"...","state":"SC","population":123}
                           201; 409 when the tenant already has the code
    DELETE /cities/:code   204; 404 when the tenant has none with this code
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
  PascalApi.Http,
  PascalApi.Horse.Middlewares,
  PascalApi.Horse.OpenApi,
  PascalApi.Horse.Observability,
  PascalCommon.Tracing,
  PascalApi.Otlp,
  PascalApi.Tenancy,
  PascalApi.Horse.Tenancy,
  TenantApiSample.Cities in 'TenantApiSample.Cities.pas',
  TenantApiSample.Control in 'TenantApiSample.Control.pas';

const
  DEFAULT_TENANTS =
    'acme=dedicated;globex=dedicated;initech=shared;umbrella=shared;soylent=shared,suspended;' +
    'hooli=shared,plan:free';
  // Requests per minute: the plan "free", and everyone else.
  FREE_LIMIT = 5;
  DEFAULT_LIMIT = 1000;

var
  GSecret, GClaim, GDataDir: string;
  GCatalog: ITenantCatalog;
  GResolver: ITenantDataResolver;

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
  end;

function NewSqliteFactory(const AFile, APoolName: string; const ASource: ISqlSource): IDBFactory;
var
  LConfig: IDatabaseConfig; // an interface variable, never a class one (pascal-db-faa's rule)
  LFile: string;
begin
  LFile := AFile;
  LConfig := TDatabaseConfig.Create;
  {$IFDEF FPC}
  LConfig.ConnectionParams.Values['ConnectorType'] := 'SQLite3';
  LConfig.ConnectionParams.Values['DatabaseName'] := LFile;
  {$IFDEF UNIX}
  LConfig.ConnectionParams.Values['ClientLibrary'] := TAppConfig.Get('SQLITE_CLIENT', 'libsqlite3.so.0');
  {$ELSE}
  LConfig.ConnectionParams.Values['ClientLibrary'] := TAppConfig.Get('SQLITE_CLIENT', '');
  {$ENDIF}
  {$ELSE}
  LConfig.ConnectionParams.Values['DriverID'] := 'SQLite';
  LConfig.ConnectionParams.Values['Database'] := LFile;
  {$ENDIF}
  LConfig.SQLDialect := 'SQLite';
  LConfig.SQLDirectory := 'SQLITE';
  LConfig.SqlSource := ASource;
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
  Result := NewSqliteFactory(GDataDir + ADatabaseKey + '.sqlite', APoolName, CitySqlSource);
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

procedure PostLogin(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LBody: TJsonValue;
  LWriter: TJsonWriter;
  LTenant, LUser, LClaims: string;
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
  LWriter := TJsonWriter.Create;
  try
    LWriter.BeginObject;
    LWriter.Name('sub');
    LWriter.WriteString(LUser);
    LWriter.Name(GClaim);
    LWriter.WriteString(LInfo.Id);
    LWriter.Name('exp');
    LWriter.WriteInt64(TJwt.UnixNow + 3600);
    LWriter.EndObject;
    LClaims := LWriter.ToString;
  finally
    LWriter.Free;
  end;
  LWriter := TJsonWriter.Create;
  try
    LWriter.BeginObject;
    LWriter.Name('token');
    LWriter.WriteString(TJwt.SignHS256(LClaims, GSecret));
    LWriter.EndObject;
    TJsonSend.Send(ARes, LWriter.ToString);
  finally
    LWriter.Free;
  end;
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
  end;

procedure TSampleLog.Error(const ALine: string);
begin
  Writeln('ERROR ', ALine);
end;

procedure TSampleLog.Migration(const AEvent: TMigrationEvent);
begin
  if AEvent.Kind = mekApplied then
    Writeln('migration ', AEvent.Version, ' ', AEvent.ScriptName);
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
      Writeln('database ', LKey, ' at version ', LEngine.CurrentVersion);
    finally
      LEngine.Free;
    end;
  end;
end;

// --reset. A file another process holds open (another instance on the same
// DATA_DIR) can't be deleted on Windows: stop instead of starting on old data
// (seen: a second Delphi Win64 instance kept the first one's rows).
procedure DeleteDatabases(const ASpec: ITenantCatalog);

  procedure DeleteDatabase(const AKey: string);
  var
    LFile: string;
  begin
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
function OpenCatalog(const ASpec: ITenantCatalog; ALog: TSampleLog): ITenantCatalog;
var
  LControl: IDBFactory;
  LEngine: TDBMigrationEngine;
begin
  LControl := NewSqliteFactory(GDataDir + 'control.sqlite', 'control', ControlSqlSource);
  LEngine := TDBMigrationEngine.Create(LControl, ALog.Migration);
  try
    LEngine.Execute(ControlMigrations);
    Writeln('database control at version ', LEngine.CurrentVersion);
  finally
    LEngine.Free;
  end;
  SeedTenants(LControl, ASpec);
  Result := TCachedTenantCatalog.Create(TDbTenantCatalog.Create(LControl),
    StrToIntDef(TAppConfig.Get('CATALOG_TTL', '30'), 30));
end;

var
  GLog: TSampleLog;
  GHooks: TSampleHooks;
  GSpec: ITenantCatalog;
  GRateLimit: TRateLimitOptions;
  GPort, I: Integer;
  GReset: Boolean;

begin
  {$IFDEF FPC}
  SetMultiByteConversionCodePage(CP_UTF8);
  {$ENDIF}
  GPort := 9350;
  GReset := False;
  for I := 1 to ParamCount do
    if ParamStr(I) = '--reset' then
      GReset := True
    else
      GPort := StrToIntDef(ParamStr(I), GPort);
  GDataDir := IncludeTrailingPathDelimiter(ExpandFileName(
    TAppConfig.Get('DATA_DIR', ExtractFilePath(ParamStr(0)))));
  GSecret := TAppConfig.Get('JWT_SECRET', 'development-secret-change-me');
  GClaim := TAppConfig.Get('TENANT_CLAIM', TENANT_DEFAULT_CLAIM);

  GLog := TSampleLog.Create;
  GHooks := TSampleHooks.Create;
  try
    GSpec := TConfigTenantCatalog.Create(TAppConfig.Get('TENANTS', DEFAULT_TENANTS));
    if GReset then
      DeleteDatabases(GSpec);
    GCatalog := OpenCatalog(GSpec, GLog);
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
    THorse.Use(TJwtMiddleware.New(GSecret, ['/health', '/metrics', '/auth/login', '/swagger']));
    THorse.Use(TTenantMiddleware.New(GCatalog, GClaim));
    // After the tenant: one window per tenant, its limit by plan.
    GRateLimit := TRateLimitOptions.Default;
    GRateLimit.Limit := DEFAULT_LIMIT;
    GRateLimit.WindowSeconds := 60;
    GRateLimit.KeyExtractor := GHooks.RateKey;
    GRateLimit.LimitFor := GHooks.PlanLimit;
    THorse.Use(TRateLimitMiddleware.New(GRateLimit));
    TRouteDoc.Post('/auth/login').Summary('Get a token for one tenant (1 hour)').Tag('public')
      .NoContent(200, '{"token": "..."}')
      .Error(400, '"tenant" or "user" is missing')
      .Error(403, 'The tenant is suspended')
      .Error(404, 'No such tenant')
      .Register(PostLogin);
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
    TMetricsEndpoint.Register;
    THealthEndpoint.Register('/health', GLog.Error);
    TRouteDoc.Serve('/swagger', 'Cities API, multi-tenant (pascal-api-infra-faa sample 03)', '1.0.0');

    Writeln('TenantApiSample listening on port ', GPort);
    THorse.Listen(GPort);
  finally
    GResolver := nil;
    GCatalog := nil;
    GSpec := nil;
    GHooks.Free;
    GLog.Free;
  end;
end.
