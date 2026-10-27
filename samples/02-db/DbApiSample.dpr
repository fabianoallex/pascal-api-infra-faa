program DbApiSample;

(* Sample 02: a Horse API over a real database, SQLite or PostgreSQL through
  pascal-db-faa (SQLdb on FPC, FireDAC on Delphi). One source for Delphi
  (DbApiSample.dproj) and Lazarus/FPC (DbApiSample.lpi).

    DbApiSample [port] [--reset]       (default port 9330)

  DB_ENGINE (environment or .env) picks the database:
  - sqlite (default): the file DB_FILE, by default dbapi_sample.sqlite next
    to the executable; --reset deletes it first. On FPC the SQLite client
    library is SQLITE_CLIENT, by default sqlite3.dll on Windows (it must be
    sqlite.org's build: pascal-db-faa's gotcha 23) and libsqlite3.so.0 on
    Linux; FireDAC links SQLite into the program.
  - postgresql: DB_HOST (localhost), DB_PORT (5432), DB_NAME (dbapi_sample),
    DB_USER (postgres), DB_PASSWORD; the database must exist (the
    migrations create the tables). --reset drops the sample's tables first.
    PG_CLIENT is libpq: on Windows the full path of a 64-bit libpq.dll
    (PostgreSQL ships no 32-bit client, so a Delphi build for it is Win64);
    on Linux libpq.so.5 is found by default.
  Either way, every run with --reset starts from the migrations.

  The SQL is the same on both (DbApiSample.Cities, directory COMMON):
  TFallbackSqlSource asks for SQLITE/<KEY> or PG/<KEY> first, then
  COMMON/<KEY>, so a statement that had to differ would go under its
  database's directory only. One difference shows over HTTP: ordered by
  population, the city without one sorts as the smallest value on SQLite
  and as the largest on PostgreSQL (each database's default for NULL), so
  "-population" starts with it on PostgreSQL.

  Routes:
    GET    /cities          paged: ?state=&page=&limit=&orderBy=name|-name|state|population
    GET    /cities/:code    404 when it doesn't exist; ETag: the row's version ("1"), which
                            the body's "version" carries too (1)
    POST   /cities          {"code":"4205407","name":"...","state":"SC","population":123}
                            201; 409 when the code exists (the database says so), 400 invalid.
                            Idempotency-Key (optional): a retry with the same key and body
                            gets the first answer again, Idempotent-Replayed: true
                            (PascalApi.Idempotency, keys in the database, 24 hours)
    PATCH  /cities/:code    {"name":"...","state":"..","population":123|null}: only the
                            members that came change; null clears population; 200
    PUT    /cities/:code    {"name":"...","state":"..","population":123|null}, with
                            If-Match: the ETag read (PascalApi.Preconditions): 428 without
                            it, 412 when the city changed since; 200 with the new ETag
    DELETE /cities/:code    204; 404 when it doesn't exist
    GET    /metrics         Prometheus text (http.server.* metrics)
    GET    /health/live     200 while the process answers
    GET    /health/ready    the readiness check "database" (SELECT 1 through the pool)
    GET    /swagger         Swagger UI; /swagger/doc.json is the OpenAPI 3.0.3 document
    POST   /mcp             MCP (2026-07-28): the routes above as tools, with the schemas
                            of their DTOs; replace_city (PUT) takes ifMatch, create_citie
                            idempotencyKey (0.25.0, McpHeader); browser origin allowed: the MCP
                            Inspector's (http://localhost:6274)

  On startup the migrations run (TDBMigrationEngine): SCHEMA_MIGRATIONS,
  CITIES and seed rows; a second start applies nothing. tools/http_scenarios_db.sh
  checks all of this over HTTP.

  The access log is JSON, one object per request (sample 01 keeps the text
  line), with the trace id the response carries as X-Request-Id. Spans go to
  an OpenTelemetry collector when OTEL_EXPORTER_OTLP_ENDPOINT is set, and so
  do the metrics /metrics serves (0.26.0, TOtlpMetricsExporter, every
  OTEL_METRIC_EXPORT_INTERVAL ms): CI reads them back from a Prometheus that
  scrapes the collector. *)

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
  PascalJsonMapper.Mapper,
  PascalCommon.JsonMapper.Optionals,
  PascalDb.Interfaces,
  PascalDb.SqlSources,
  PascalDb.Paging,
  PascalDb.Migrations,
  PascalDb.Adapter.Base,
  {$IFDEF FPC}
  PascalDb.Adapter.SQLdb,
  {$ELSE}
  PascalDb.Adapter.FireDAC,
  {$ENDIF}
  PascalApi.Config,
  PascalApi.Pagination,
  PascalApi.OrderBy,
  PascalApi.OpenApi,
  PascalApi.Http,
  PascalApi.Preconditions,
  PascalApi.Idempotency,
  PascalApi.Horse.Middlewares,
  PascalApi.Horse.Idempotency,
  PascalApi.Horse.OpenApi,
  PascalApi.Horse.Mcp,
  PascalApi.Horse.Observability,
  PascalCommon.Tracing,
  PascalCommon.SafeLog,
  PascalCommon.Metrics,
  PascalApi.Otlp,
  DbApiSample.Normalizers in 'DbApiSample.Normalizers.pas',
  DbApiSample.Validators in 'DbApiSample.Validators.pas',
  DbApiSample.Cities in 'DbApiSample.Cities.pas';

var
  GFactory: IDBFactory;
  GCities: TCityRepository;
  GIdempotency: TIdempotency;
  GMetricsExporter: TOtlpMetricsExporter;

{ Handlers }

procedure GetCities(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LFind: ICityFind;
  LPage: TPage<ICity>;
begin
  // The query string into the Find DTO the route documents (QueryParams),
  // by the same members (0.19.0): a value of the wrong kind is a 400 naming
  // the parameter.
  LFind := THorseQueryParams.Read<ICityFind>(AReq);
  LPage := GCities.FindPage(LFind.State, LFind.OrderBy.Value,
    PageRequestFrom(LFind.Page, LFind.Limit, 2, 50));
  TJsonSend.Send(ARes, PageEnvelopeJson(LPage.Meta,
    TJsonMapper.Shared.Serialize<TCityArray>(LPage.Items)));
end;

// A city and its ETag (the row's version), which PUT's If-Match sends back.
procedure SendCity(ARes: THorseResponse; const ACity: ICity; AVersion: Int64;
  AStatus: Integer = 200);
begin
  ARes.AddHeader('ETag', VersionETag(AVersion));
  TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<ICity>(ACity), AStatus);
end;

procedure GetCity(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LCity: ICity;
  LVersion: Int64;
begin
  LCity := GCities.FindByCode(AReq.Params['code'], LVersion);
  SendCity(ARes, LCity, LVersion);
end;

// With an Idempotency-Key (0.23.0): a retry with the same key and body gets
// the first answer again, a 201 or the 4xx it was (a duplicate code's 409);
// the same key with another body is a 422. Without one, as before.
procedure PostCity(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LIdem: THorseIdempotentRequest;
  LVersion: Int64;
  LJson, LHeaders: string;
begin
  if LIdem.Start(GIdempotency, AReq, ARes, '') then
    Exit; // replayed
  try
    LJson := TJsonMapper.Shared.ToJson<ICity>(
      GCities.Insert(THorseBody.Read<ICityInsert>(AReq), LVersion));
    LHeaders := HeaderLines([HttpHeader('ETag', VersionETag(LVersion))]);
    LIdem.Complete(201, LJson, LHeaders);
  except
    on E: Exception do
    begin
      LIdem.Fail(E);
      raise;
    end;
  end;
  LIdem.Send(201, LJson, LHeaders);
end;

procedure PatchCity(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LCity: ICity;
  LVersion: Int64;
begin
  LCity := GCities.Update(AReq.Params['code'], THorseBody.Read<ICityPatch>(AReq), LVersion);
  SendCity(ARes, LCity, LVersion);
end;

// Every member, guarded by If-Match (0.23.0): the version read, or a 412.
procedure PutCity(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LCity: ICity;
  LVersion: Int64;
begin
  LCity := GCities.Replace(AReq.Params['code'], AReq.Headers['If-Match'],
    THorseBody.Read<ICityReplace>(AReq), LVersion);
  SendCity(ARes, LCity, LVersion);
end;

procedure DeleteCity(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  GCities.Delete(AReq.Params['code']);
  ARes.Status(204).Send('');
end;

{ Setup }

type
  TSampleLog = class
  public
    procedure Error(const ALine: string);
    procedure Migration(const AEvent: TMigrationEvent);
    function DatabaseReady: Boolean;
  end;

procedure TSampleLog.Error(const ALine: string);
begin
  SafeWriteln('ERROR ' + ALine);
end;

procedure TSampleLog.Migration(const AEvent: TMigrationEvent);
begin
  if AEvent.Kind = mekApplied then
    SafeWriteln('migration %d %s', [AEvent.Version, AEvent.ScriptName]);
end;

// A connection from the pool answers a query. Raises when the database
// can't be reached (the endpoint counts that as a failure).
function TSampleLog.DatabaseReady: Boolean;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := GFactory.GetPool.AcquireQuery(LQuery);
  LQuery.Sql := 'SELECT 1 AS ONE';
  Result := LQuery.Open.RecordCount = 1;
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

// The adapters' names for the same settings (pascal-db-faa's docs/adapters.md).
procedure SetPostgreSQLParams(const AConfig: IDatabaseConfig);
begin
  {$IFDEF FPC}
  AConfig.ConnectionParams.Values['ConnectorType'] := 'PostgreSQL';
  AConfig.ConnectionParams.Values['HostName'] := TAppConfig.Get('DB_HOST', 'localhost');
  AConfig.ConnectionParams.Values['Port'] := TAppConfig.Get('DB_PORT', '5432');
  AConfig.ConnectionParams.Values['DatabaseName'] := TAppConfig.Get('DB_NAME', 'dbapi_sample');
  AConfig.ConnectionParams.Values['UserName'] := TAppConfig.Get('DB_USER', 'postgres');
  AConfig.ConnectionParams.Values['Password'] := TAppConfig.Get('DB_PASSWORD', '');
  AConfig.ConnectionParams.Values['CharSet'] := 'UTF8';
  AConfig.ConnectionParams.Values['ClientLibrary'] := TAppConfig.Get('PG_CLIENT', '');
  {$ELSE}
  AConfig.ConnectionParams.Values['DriverID'] := 'PG';
  AConfig.ConnectionParams.Values['Server'] := TAppConfig.Get('DB_HOST', 'localhost');
  AConfig.ConnectionParams.Values['Port'] := TAppConfig.Get('DB_PORT', '5432');
  AConfig.ConnectionParams.Values['Database'] := TAppConfig.Get('DB_NAME', 'dbapi_sample');
  AConfig.ConnectionParams.Values['User_Name'] := TAppConfig.Get('DB_USER', 'postgres');
  AConfig.ConnectionParams.Values['Password'] := TAppConfig.Get('DB_PASSWORD', '');
  AConfig.ConnectionParams.Values['CharacterSet'] := 'UTF8';
  AConfig.ConnectionParams.Values['VendorLib'] := TAppConfig.Get('PG_CLIENT', '');
  {$ENDIF}
  AConfig.SQLDialect := 'PostgreSQL';
  AConfig.SQLDirectory := 'PG';
end;

procedure SetSQLiteParams(const AConfig: IDatabaseConfig; const ADatabaseFile: string);
begin
  {$IFDEF FPC}
  AConfig.ConnectionParams.Values['ConnectorType'] := 'SQLite3';
  AConfig.ConnectionParams.Values['DatabaseName'] := ADatabaseFile;
  {$IFDEF UNIX}
  AConfig.ConnectionParams.Values['ClientLibrary'] := TAppConfig.Get('SQLITE_CLIENT', 'libsqlite3.so.0');
  {$ELSE}
  AConfig.ConnectionParams.Values['ClientLibrary'] := TAppConfig.Get('SQLITE_CLIENT', '');
  {$ENDIF}
  {$ELSE}
  AConfig.ConnectionParams.Values['DriverID'] := 'SQLite';
  AConfig.ConnectionParams.Values['Database'] := ADatabaseFile;
  {$ENDIF}
  AConfig.SQLDialect := 'SQLite';
  AConfig.SQLDirectory := 'SQLITE';
end;

function NewFactory(APostgreSQL: Boolean; const ADatabaseFile: string): IDBFactory;
var
  LConfig: IDatabaseConfig; // an interface variable, never a class one (pascal-db-faa's rule)
begin
  LConfig := TDatabaseConfig.Create;
  if APostgreSQL then
    SetPostgreSQLParams(LConfig)
  else
    SetSQLiteParams(LConfig, ADatabaseFile);
  // The database's own directory first, then the SQL every database runs.
  LConfig.SqlSource := TFallbackSqlSource.Create(CitySqlSource, CITY_SQL_COMMON_DIR);
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

// --reset on PostgreSQL: the sample's tables go, so the migrations run again.
procedure DropSampleTables(const AFactory: IDBFactory);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := AFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := 'DROP TABLE IF EXISTS CITIES';
    LQuery.ExecSql;
    LQuery.Sql := 'DROP TABLE IF EXISTS IDEMPOTENCY_KEYS';
    LQuery.ExecSql;
    LQuery.Sql := 'DROP TABLE IF EXISTS SCHEMA_MIGRATIONS';
    LQuery.ExecSql;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

var
  GLog: TSampleLog;
  GPort, I: Integer;
  GReset, GPostgreSQL: Boolean;
  GFile, GDescription: string;
  GEngine: TDBMigrationEngine;

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
  GPort := 9330;
  GReset := False;
  for I := 1 to ParamCount do
    if ParamStr(I) = '--reset' then
      GReset := True
    else
      GPort := StrToIntDef(ParamStr(I), GPort);
  GPostgreSQL := IsPostgreSQL;
  if GPostgreSQL then
    GDescription := Format('postgresql %s:%s/%s', [TAppConfig.Get('DB_HOST', 'localhost'),
      TAppConfig.Get('DB_PORT', '5432'), TAppConfig.Get('DB_NAME', 'dbapi_sample')])
  else
  begin
    GFile := ExpandFileName(TAppConfig.Get('DB_FILE', ExtractFilePath(ParamStr(0)) + 'dbapi_sample.sqlite'));
    GDescription := 'sqlite ' + GFile;
    if GReset and FileExists(GFile) then
      DeleteFile(GFile);
  end;

  GLog := TSampleLog.Create;
  try
    GFactory := NewFactory(GPostgreSQL, GFile);
    if GPostgreSQL and GReset then
      DropSampleTables(GFactory);
    GEngine := TDBMigrationEngine.Create(GFactory, GLog.Migration);
    try
      GEngine.Execute(CityMigrations);
      SafeWriteln('database %s at version %d', [GDescription, GEngine.CurrentVersion]);
    finally
      GEngine.Free;
    end;
    GCities := TCityRepository.Create(GFactory);
    // Idempotency-Key on POST /cities: the keys in the database (the scope
    // is '' without tenants), kept 24 hours, a lease of 30 seconds.
    GIdempotency := TIdempotency.Create(TDbIdempotencyStore.Create(GFactory));

    if TAppConfig.Get('OTEL_EXPORTER_OTLP_ENDPOINT', '') <> '' then
      TPcTracing.Start(TPcTracingOptions.FromEnvironment('cities-api', '1.0.0', ReadAppConfig),
        TOtlpHttpExporter.FromEnvironment, GLog.Error);
    // The same registry as /metrics, pushed to the collector (0.26.0).
    if TAppConfig.Get('OTEL_EXPORTER_OTLP_ENDPOINT', '') <> '' then
      GMetricsExporter := TOtlpMetricsExporter.Create(PcMetrics,
        TOtlpMetricsOptions.FromEnvironment('cities-api', '1.0.0', ReadAppConfig), GLog.Error);
    TErrorHandlerMiddleware.Register(GLog.Error);
    THorse.Use(TLoggerMiddleware.New(nil, alfJson));
    THorse.Use(TMetricsMiddleware.New);
    // Each route registered in Horse and documented in one call.
    TRouteDoc.Get('/cities')
      .Summary('List cities, a page at a time').Tag('cities')
      .QueryParams<ICityFind>
      .ResponsePaged<ICity>(200, 'A page of cities')
      .Error(400, 'An order field that is not allowed')
      .Register(GetCities);
    TRouteDoc.Get('/cities/:code')
      .Summary('One city').Tag('cities')
      .PathParam('code', 'IBGE code (7 digits)')
      .Response<ICity>(200)
      .ResponseHeader('ETag', 'The version read, for If-Match')
      .Error(404, 'No city with this code')
      .Register(GetCity);
    TRouteDoc.Post('/cities')
      .Summary('Create a city').Tag('cities')
      .HeaderParam('Idempotency-Key', 'Optional, 1 to 255 visible ASCII characters (a UUID): ' +
        'a retry with the same key and body gets the first answer again, for 24 hours')
      .McpHeader('Idempotency-Key') // the tool's "idempotencyKey"
      .Body<ICityInsert>
      .Response<ICity>(201, 'Created')
      .ResponseHeader('ETag', 'The new city''s version')
      .ResponseHeader('Idempotent-Replayed', '"true" on an answer sent again')
      .Error(400, 'Invalid data, or invalid_idempotency_key')
      .Error(409, 'A city with this code already exists, or idempotency_key_in_flight')
      .Error(422, 'idempotency_key_reused: the key was used for another request')
      .Register(PostCity);
    TRouteDoc.Patch('/cities/:code')
      .Summary('Change some members of a city').Tag('cities')
      .PathParam('code', 'IBGE code (7 digits)')
      .Body<ICityPatch>
      .Response<ICity>(200, 'The city after the change')
      .ResponseHeader('ETag', 'The new version')
      .Error(400, 'Invalid data')
      .Error(404, 'No city with this code')
      .Register(PatchCity);
    // An MCP tool too (0.25.0): McpHeader makes If-Match its "ifMatch"
    // argument, which the city's "version" in quotes fills. Named, since
    // the derived name (update_citie) is PATCH's.
    TRouteDoc.Put('/cities/:code')
      .Summary('Replace a city''s members, from the version read').Tag('cities')
      .OperationId('replace_city')
      .PathParam('code', 'IBGE code (7 digits)')
      .HeaderParam('If-Match', 'The version read, in quotes: "3" for version 3', True)
      .McpHeader('If-Match')
      .Body<ICityReplace>
      .Response<ICity>(200, 'The city after the change')
      .ResponseHeader('ETag', 'The new version')
      .Error(400, 'Invalid data, or invalid_if_match')
      .Error(404, 'No city with this code')
      .Error(412, 'precondition_failed: the city changed since that version')
      .Error(428, 'precondition_required: If-Match missing, or "*"')
      .Register(PutCity);
    TRouteDoc.Delete('/cities/:code')
      .Summary('Delete a city').Tag('cities')
      .PathParam('code', 'IBGE code (7 digits)')
      .NoContent(204, 'Deleted')
      .Error(404, 'No city with this code')
      .Register(DeleteCity);
    TMetricsEndpoint.Register;
    THealthEndpoint.AddCheck('database', GLog.DatabaseReady);
    THealthEndpoint.Register('/health', GLog.Error);
    TRouteDoc.Serve('/swagger', 'Cities API (pascal-api-infra-faa sample 02)', '1.0.0');
    TMcpEndpoint.Register('/mcp', 'http://127.0.0.1:' + IntToStr(GPort), 'cities-api', '1.0.0',
      [], ['http://localhost:6274']);

    SafeWriteln('DbApiSample listening on port %d', [GPort]);
    THorse.Listen(GPort);
  finally
    GMetricsExporter.Free; // the last export
    GIdempotency.Free;
    GCities.Free;
    GFactory := nil;
    GLog.Free;
  end;
end.
