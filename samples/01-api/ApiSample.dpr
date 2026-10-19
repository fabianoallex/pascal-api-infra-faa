program ApiSample;

(* Sample 01: a small Horse API using every middleware of the library, with
  no database (cities live in memory). One source for Delphi
  (ApiSample.dproj) and Lazarus/FPC (ApiSample.lpi).

    ApiSample [port]          (default 9310)

  Routes:
    GET  /health              public
    POST /auth/login          public; {"user":"..."} -> {"token","expiresIn",
                              "refreshToken","refreshExpiresIn"}: an access token
                              (HS256, ACCESS_TOKEN_SECONDS, default 3600) and a
                              refresh token (REFRESH_TOKEN_SECONDS, default 30 days)
    POST /auth/refresh        public; {"refreshToken":"..."} -> the next pair; the
                              token is spent. 401 invalid_refresh_token for any
                              reason; a spent token that comes back revokes its
                              login (a SECURITY line in the log)
    POST /auth/logout         public; {"refreshToken":"..."} -> 204, whatever the token
    POST /auth/logout-all     every refresh token of the caller (the access
                              token's "sub") revoked; 204
    GET  /me                  the token's "sub"
    GET  /cities              paged: ?page=&limit=&orderBy=name|-name|state
    GET  /cities/:id          404 when it doesn't exist
    POST /cities              {"name":"...","state":"..","population":123}; 201
    POST /prices              {"item":"...","amount":1.2345}; the price back, read and
                              written by the mapper (a Currency, exact up to its limits)
    GET  /fail/server         an unexpected exception: 500
    GET  /fail/database       the database is down: 503
    GET  /fail/busy           no free database connection in time: 503
    GET  /fail/middleware     a middleware raises: 500 (?kind=validation: 400)
    GET  /fail/createfmt      EValidationException.CreateFmt: 400 (until 0.17.0
                              status 0, an "HTTP/1.1 0" answer)
    GET  /fail/unauthorized   EUnauthorizedException with a code: 401, its
                              WWW-Authenticate and "code"
    GET  /limited             rate limited: 3 requests per minute per X-Client header
    GET  /trace               the request's trace context, as the handler sees it
    PUT  /maintenance         {"on":true|false}; while on, /health/ready answers 503
    GET  /metrics             public; Prometheus text (http.server.* metrics)
    GET  /health/live         public; 200 while the process answers
    GET  /health/ready        public; the readiness checks (here: "maintenance")
    GET  /swagger             public; Swagger UI, and /swagger/doc.json the OpenAPI document
    POST /mcp                 MCP (2026-07-28): the documented routes as tools; needs the
                              token, which each tool call passes on to the route
    POST /mcp/unreachable     MCP whose API can't be reached (port 1): a failed call

  Middlewares, in order: request log (console), metrics, CORS for
  https://app.example.com, rate limit (only on /limited, keyed by the
  X-Client header), JWT (all but /health, /metrics, /auth/login,
  /auth/refresh, /auth/logout and /swagger), and the error
  handler (THorse.OnError). tools/http_scenarios.sh checks all of this over
  HTTP with curl.

  The JWT secret comes from JWT_SECRET (environment or .env), with a
  development default.

  Refresh tokens (PascalApi.RefreshTokens) live in this process
  (TMemoryRefreshTokenStore, scope '': no tenants): a restart ends every
  login. There are no passwords and no user table: any name logs in, and
  a name starting with "blocked" stands for a user deactivated after the
  login, refused by the refresh's user check (TRefreshUserCheck).

  Tracing: when OTEL_EXPORTER_OTLP_ENDPOINT is set (e.g.
  http://localhost:4318), every request's span goes to that OpenTelemetry
  collector (PascalCommon.Tracing, PascalApi.Otlp); GET /trace adds a child
  span. CI checks what the collector received (tools/otlp_check.py). *)

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
  PascalDb.Pool,
  PascalDb.Paging,
  PascalApi.Config,
  PascalApi.OrderBy,
  PascalApi.Pagination,
  PascalApi.Jwt,
  PascalApi.Http,
  PascalApi.OpenApi,
  PascalApi.Horse.Middlewares,
  PascalApi.Horse.OpenApi,
  PascalApi.Horse.Mcp,
  PascalApi.Horse.Observability,
  PascalCommon.Tracing,
  PascalCommon.SafeLog,
  PascalApi.Otlp,
  PascalApi.RefreshTokens,
  ApiSample.Cities in 'ApiSample.Cities.pas',
  ApiSample.Auth in 'ApiSample.Auth.pas';

type
  // A Currency read and written by the mapper: tools/http_scenarios.sh sends
  // the largest values, which pascal-jsonmapper-faa before 0.6.0 changed on
  // FPC 3.2.2 (lost digits on Win64, a 500 at the top of the range).
  IPrice = interface
    ['{105EF129-E440-4988-9419-D8730144006C}']
    function GetItem: string;
    function GetAmount: Currency;
    property Item: string read GetItem;
    property Amount: Currency read GetAmount;
  end;

{$M+}
  TPrice = class(TInterfacedObject, IPrice)
  private
    FItem: string;
    FAmount: Currency;
  public
    function GetItem: string;
    function GetAmount: Currency;
  published
    property Item: string read FItem write FItem;
    property Amount: Currency read FAmount write FAmount;
  end;
{$M-}

function TPrice.GetItem: string;
begin
  Result := FItem;
end;

function TPrice.GetAmount: Currency;
begin
  Result := FAmount;
end;

var
  GPort: Integer;
  GSecret: string;
  GMaintenance: Boolean;
  GRefresh: TRefreshTokens;
  GAccessSeconds, GRefreshSeconds: Int64;

{ Handlers }

procedure GetHealth(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  TJsonSend.Send(ARes, '{"status":"ok"}');
end;

{ Refresh tokens: the user check and the security log, methods (the
  portable callback form: "of object" on FPC) }

type
  TRefreshHooks = class
  public
    /// TRefreshUserCheck: may this user still refresh? Here every name is a
    /// user, and one starting with "blocked" was deactivated after its login.
    /// A real API looks the user up (exists, active).
    function UserActive(const AScope, AUserId: string): Boolean;
    /// TRefreshTokens' OnSecurity: a family revoked for a reuse, a race or
    /// a user gone.
    procedure Security(const ALine: string);
  end;

function TRefreshHooks.UserActive(const AScope, AUserId: string): Boolean;
begin
  Result := Copy(AUserId, 1, 7) <> 'blocked';
end;

procedure TRefreshHooks.Security(const ALine: string);
begin
  SafeWriteln('SECURITY ' + ALine);
end;

var
  GRefreshHooks: TRefreshHooks;

// The access token: short-lived, so a stolen one is useful only for
// minutes; the refresh token gets the next one.
function AccessToken(const AUser: string): string;
var
  LWriter: TJsonWriter;
begin
  LWriter := TJsonWriter.Create;
  try
    LWriter.BeginObject;
    LWriter.Name('sub');
    LWriter.WriteString(AUser);
    LWriter.Name('exp');
    LWriter.WriteInt64(TJwt.UnixNow + GAccessSeconds);
    LWriter.EndObject;
    Result := TJwt.SignHS256(LWriter.ToString, GSecret);
  finally
    LWriter.Free;
  end;
end;

procedure SendTokens(ARes: THorseResponse; const AUser, ARefreshToken: string);
var
  LTokens: TTokens;
  LResult: ITokens;
begin
  LTokens := TTokens.Create;
  LResult := LTokens;
  LTokens.Token := AccessToken(AUser);
  LTokens.ExpiresIn := GAccessSeconds;
  LTokens.RefreshToken := ARefreshToken;
  LTokens.RefreshExpiresIn := GRefreshSeconds;
  // Tokens are credentials: no cache may keep them (RFC 6749, section 5.1).
  ARes.AddHeader('Cache-Control', 'no-store');
  TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<ITokens>(LResult));
end;

// One answer for every refusal (malformed, unknown, expired, revoked,
// reused, raced, user gone): the reason is for the log, not the client.
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
  LBody, LUser: TJsonValue;
  LName: string;
begin
  LBody := ParseJson(AReq.Body);
  try
    LUser := LBody.Find('user');
    if (LUser = nil) or (LUser.Kind <> jkString) or (LUser.AsString = '') then
      raise EValidationException.Create('"user" is required.');
    LName := LUser.AsString;
  finally
    LBody.Free;
  end;
  // A sample: no password. A real login checks it first, and answers the
  // same 401 for every wrong part.
  SendTokens(ARes, LName, GRefresh.Issue('', LName));
end;

procedure PostRefresh(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LNext: TRotatedRefreshToken;
begin
  try
    LNext := GRefresh.Rotate(RefreshTokenOf(AReq), GRefreshHooks.UserActive);
  except
    on E: ERefreshTokenRejected do
      raise InvalidRefreshToken;
  end;
  SendTokens(ARes, LNext.UserId, LNext.Token);
end;

procedure PostLogout(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  // The same answer for any token: a logout tells nothing about it.
  GRefresh.Revoke(RefreshTokenOf(AReq));
  ARes.Status(204).Send('');
end;

// Sign out everywhere: what a new password or a deactivated user does too.
procedure PostLogoutAll(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LClaims: TJsonValue;
begin
  LClaims := TJwtMiddleware.Claims(AReq);
  try
    GRefresh.RevokeUser('', LClaims.Find('sub').AsString);
  finally
    LClaims.Free;
  end;
  ARes.Status(204).Send('');
end;

procedure GetMe(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LClaims: TJsonValue;
begin
  LClaims := TJwtMiddleware.Claims(AReq);
  try
    TJsonSend.Send(ARes, JsonMember('sub', LClaims.Find('sub').AsString));
  finally
    LClaims.Free;
  end;
end;

procedure GetCities(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LPage: TPageRequest;
  LTotal: Int64;
  LItems: string;
begin
  LPage := PageRequestFrom(ParseQueryInt('page', AReq.Query['page']),
    ParseQueryInt('limit', AReq.Query['limit']), 2, 10);
  LItems := CityPageJson(AReq.Query['orderBy'], LPage, LTotal);
  TJsonSend.Send(ARes, PageEnvelopeJson(TPageMeta.Create(LPage, LTotal), LItems));
end;

procedure GetCity(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  TJsonSend.Send(ARes, CityJson(StrToIntDef(AReq.Params['id'], 0)));
end;

procedure PostCity(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  TJsonSend.Send(ARes, AddCity(TJsonMapper.Shared.FromJson<ICityInsert>(AReq.Body)), 201);
end;

procedure PostPrice(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<IPrice>(
    TJsonMapper.Shared.FromJson<IPrice>(AReq.Body)));
end;

procedure FailServer(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  raise EInvalidOpException.Create('something broke (ação)');
end;

procedure FailDatabase(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LDriver: Exception;
begin
  LDriver := Exception.Create('connection refused db.internal:3050');
  try
    raise EDatabaseUnavailableException.Create(LDriver);
  finally
    LDriver.Free;
  end;
end;

// A middleware that raises, as a token check or a tenant catalog would. The
// logger answers its exception like the error handler answers a handler's
// (on FPC, Horse doesn't pass it to THorse.OnError).
procedure FailingMiddleware(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  if AReq.Query['kind'] = 'validation' then
    raise EValidationException.Create('"kind" was rejected by a middleware.');
  raise EInvalidOpException.Create('middleware broke at db.internal:3050');
end;

procedure NeverReached(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  TJsonSend.Send(ARes, '{"reached":true}');
end;

// What pascal-db-faa's pool raises when every connection stayed busy for the
// whole wait.
procedure FailCreateFmt(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  raise EValidationException.CreateFmt('"%s" is required.', ['name']);
end;

procedure FailUnauthorized(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  raise EUnauthorizedException.Create('Invalid email or password.', 'invalid_credentials');
end;

procedure FailBusy(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  raise EPoolTimeoutException.Create(5, 5, 3, 50);
end;

procedure GetLimited(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  TJsonSend.Send(ARes, '{"ok":true}');
end;

// What TLoggerMiddleware left on the request: the trace id (X-Request-Id)
// and this request's span (traceparent), what an outgoing call would send.
procedure GetTrace(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LWriter: TJsonWriter;
  LSpan: IPcSpan;
begin
  // A child of the request's server span (the current one).
  LSpan := TPcTracing.StartSpan('build trace answer');
  LWriter := TJsonWriter.Create;
  try
    LSpan.SetAttribute('sample.answer', 'trace');
    LWriter.BeginObject;
    LWriter.Name('requestId');
    LWriter.WriteString(AReq.Headers['X-Request-Id']);
    LWriter.Name('traceparent');
    LWriter.WriteString(AReq.Headers['traceparent']);
    LWriter.Name('tracestate');
    LWriter.WriteString(AReq.Headers['tracestate']);
    LWriter.EndObject;
    TJsonSend.Send(ARes, LWriter.ToString);
  finally
    LWriter.Free;
    LSpan.Finish;
  end;
end;

// The switch behind the "maintenance" readiness check.
procedure PutMaintenance(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LBody, LOn: TJsonValue;
begin
  LBody := ParseJson(AReq.Body);
  try
    LOn := LBody.Find('on');
    if (LOn = nil) or (LOn.Kind <> jkBoolean) then
      raise EValidationException.Create('"on" (true or false) is required.');
    GMaintenance := LOn.AsBoolean;
  finally
    LBody.Free;
  end;
  ARes.Status(204).Send('');
end;

{ Rate limit key, error log and readiness check: methods, the portable
  callback form }

type
  TSampleCallbacks = class
  public
    function ClientKey(AReq: THorseRequest): string;
    procedure LogError(const ALine: string);
    function NotInMaintenance: Boolean;
  end;

function TSampleCallbacks.ClientKey(AReq: THorseRequest): string;
begin
  Result := AReq.Headers['X-Client'];
  if Result = '' then
    Result := 'anonymous';
end;

procedure TSampleCallbacks.LogError(const ALine: string);
begin
  SafeWriteln('ERROR ' + ALine);
end;

// Raises rather than returning False, so the endpoint's exception path is
// exercised too.
function TSampleCallbacks.NotInMaintenance: Boolean;
begin
  if GMaintenance then
    raise Exception.Create('in maintenance');
  Result := True;
end;

var
  GCallbacks: TSampleCallbacks;
  GRateLimit: TRateLimitOptions;

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
  TJsonMapper.Shared.RegisterMapping<IPrice, TPrice>;
  GPort := StrToIntDef(ParamStr(1), 9310);
  GSecret := TAppConfig.Get('JWT_SECRET', 'development-secret-change-me');
  GCallbacks := TSampleCallbacks.Create;
  // Short lifetimes from the environment let tools/http_scenarios.sh see a
  // refresh token expire without a long wait.
  GAccessSeconds := TAppConfig.GetInt('ACCESS_TOKEN_SECONDS', 3600);
  GRefreshSeconds := TAppConfig.GetInt('REFRESH_TOKEN_SECONDS', REFRESH_DEFAULT_LIFETIME_SECONDS);
  GRefreshHooks := TRefreshHooks.Create;
  GRefresh := TRefreshTokens.Create(TMemoryRefreshTokenStore.Create, GRefreshSeconds,
    GRefreshHooks.Security);

  if TAppConfig.Get('OTEL_EXPORTER_OTLP_ENDPOINT', '') <> '' then
    TPcTracing.Start(TPcTracingOptions.FromEnvironment('pascal-api-sample-01', '1.0.0', ReadAppConfig),
      TOtlpHttpExporter.FromEnvironment, GCallbacks.LogError);
  TErrorHandlerMiddleware.Register(GCallbacks.LogError);
  THorse.Use(TLoggerMiddleware.New);
  THorse.Use(TMetricsMiddleware.New);
  THorse.Use(TCorsMiddleware.New('https://app.example.com'));
  THorse.Use(TJwtMiddleware.New(GSecret, ['/health', '/metrics', '/auth/login', '/auth/refresh',
    '/auth/logout', '/swagger']));

  GRateLimit := TRateLimitOptions.Default;
  GRateLimit.Limit := 3;
  GRateLimit.WindowSeconds := 60;
  GRateLimit.KeyExtractor := GCallbacks.ClientKey;

  // Routes registered and documented together. The responses here are JSON
  // written by hand, not DTOs, so only their status codes are documented;
  // samples/02-db documents full schemas.
  TRouteDoc.Get('/health').Summary('Liveness').Tag('public').NoContent(200, 'Up').Register(GetHealth);
  TRouteDoc.Post('/auth/login').Summary('Get a token (1 hour)').Tag('public')
    .Response<ITokens>(200, 'An access token and a refresh token')
    .Error(400, '"user" is missing').Register(PostLogin);
  // Not MCP tools: a model has no use for a refresh token, and one in its
  // context could be replayed.
  TRouteDoc.Post('/auth/refresh').Summary('The next tokens; the refresh token is spent')
    .Tag('public').NoMcp
    .Body<IRefreshRequest>
    .Response<ITokens>(200, 'The next access token and refresh token')
    .Error(400, '"refreshToken" is missing')
    .Error(401, 'invalid_refresh_token: malformed, unknown, expired, revoked or already ' +
      'used (a spent token that comes back revokes every token of its login)')
    .Register(PostRefresh);
  TRouteDoc.Post('/auth/logout').Summary('Revoke a refresh token and its login').Tag('public')
    .NoMcp
    .Body<IRefreshRequest>
    .NoContent(204, 'Done (the same for any token)').Error(400, '"refreshToken" is missing')
    .Register(PostLogout);
  TRouteDoc.Post('/auth/logout-all').Summary('Revoke every refresh token of the caller')
    .Tag('auth').NoMcp
    .NoContent(204, 'Done').Error(401, 'No or invalid token')
    .Register(PostLogoutAll);
  TRouteDoc.Get('/me').Summary('The token''s subject').Tag('auth')
    .NoContent(200, '{"sub": "..."}').Error(401, 'No or invalid token').Register(GetMe);
  TRouteDoc.Get('/cities').Summary('List cities').Tag('cities')
    .QueryParam('page', '', ptInteger).QueryParam('limit', '', ptInteger)
    .QueryParam('orderBy', 'name, -name or state')
    .NoContent(200, 'A page of cities').Error(400, 'Invalid order field').Error(401)
    .Register(GetCities);
  TRouteDoc.Get('/cities/:id').Summary('One city').Tag('cities')
    .PathParam('id', 'City id', ptInteger)
    .NoContent(200, 'The city').Error(404).Error(401).Register(GetCity);
  TRouteDoc.Post('/cities').Summary('Create a city').Tag('cities')
    .Body<ICityInsert>.NoContent(201, 'The new city').Error(400).Error(401).Register(PostCity);
  TRouteDoc.Post('/prices').Summary('A price back, as the mapper reads it').Tag('json').NoMcp
    .Body<IPrice>.NoContent(200, 'The price').Error(400).Error(401).Register(PostPrice);
  TRouteDoc.Get('/fail/server').Summary('Always 500').Tag('errors').NoMcp
    .Error(500).Register(FailServer);
  TRouteDoc.Get('/fail/database').Summary('Always 503').Tag('errors').NoMcp
    .Error(503).Register(FailDatabase);
  TRouteDoc.Get('/fail/busy').Summary('Always 503 (pool timeout)').Tag('errors').NoMcp
    .Error(503).Register(FailBusy);
  TRouteDoc.Get('/fail/createfmt').Summary('Always 400 (CreateFmt)').Tag('errors').NoMcp
    .Error(400).Register(FailCreateFmt);
  TRouteDoc.Get('/fail/unauthorized').Summary('Always 401 with a code').Tag('errors').NoMcp
    .Error(401).Register(FailUnauthorized);
  THorse.Use('/fail/middleware', FailingMiddleware);
  TRouteDoc.Get('/fail/middleware').Summary('A middleware raises').Tag('errors').NoMcp
    .QueryParam('kind', 'validation: a 400').Error(400).Error(500).Register(NeverReached);
  THorse.Use('/limited', TRateLimitMiddleware.New(GRateLimit));
  TRouteDoc.Get('/limited').Summary('3 requests a minute per X-Client').Tag('limits')
    .NoContent(200).Error(429).Register(GetLimited);
  TRouteDoc.Get('/trace').Summary('The request''s trace context').Tag('trace')
    .NoContent(200, '{"requestId": "...", "traceparent": "...", "tracestate": "..."}')
    .Error(401).Register(GetTrace);
  TRouteDoc.Put('/maintenance').Summary('Readiness switch (sample only)').Tag('health').NoMcp
    .NoContent(204).Error(400).Error(401).Register(PutMaintenance);
  TRouteDoc.Serve('/swagger', 'pascal-api-infra-faa sample 01', '1.0.0');
  TMetricsEndpoint.Register('/metrics');
  THealthEndpoint.AddCheck('maintenance', GCallbacks.NotInMaintenance);
  THealthEndpoint.Register('/health', GCallbacks.LogError);
  // After every route: the tools are the operations documented so far.
  TMcpEndpoint.Register('/mcp', 'http://127.0.0.1:' + IntToStr(GPort), 'pascal-api-sample-01', '1.0.0');
  // Sample only, like /fail/*: an endpoint whose API can't be reached (port 1),
  // to check that a failed call gives the client a fixed text and the log the
  // reason.
  TMcpEndpoint.Register('/mcp/unreachable', 'http://127.0.0.1:1', 'pascal-api-sample-01', '1.0.0',
    ['trace']);

  SafeWriteln('ApiSample listening on port %d', [GPort]);
  THorse.Listen(GPort);
  GRefresh.Free;
  GRefreshHooks.Free;
  GCallbacks.Free;
end.
