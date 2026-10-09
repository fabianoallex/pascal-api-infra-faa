program ApiSample;

(* Sample 01: a small Horse API using every middleware of the library, with
  no database (cities live in memory). One source for Delphi
  (ApiSample.dproj) and Lazarus/FPC (ApiSample.lpi).

    ApiSample [port]          (default 9310)

  Routes:
    GET  /health              public
    POST /auth/login          public; {"user":"..."} -> {"token":"..."} (HS256, 1 hour)
    GET  /me                  the token's "sub"
    GET  /cities              paged: ?page=&limit=&orderBy=name|-name|state
    GET  /cities/:id          404 when it doesn't exist
    POST /cities              {"name":"...","state":"..","population":123}; 201
    GET  /fail/server         an unexpected exception: 500
    GET  /fail/database       the database is down: 503
    GET  /limited             rate limited: 3 requests per minute per X-Client header
    GET  /trace               the request's trace context, as the handler sees it
    PUT  /maintenance         {"on":true|false}; while on, /health/ready answers 503
    GET  /metrics             public; Prometheus text (http.server.* metrics)
    GET  /health/live         public; 200 while the process answers
    GET  /health/ready        public; the readiness checks (here: "maintenance")
    GET  /swagger             public; Swagger UI, and /swagger/doc.json the OpenAPI document
    POST /mcp                 MCP (2026-07-28): the documented routes as tools; needs the
                              token, which each tool call passes on to the route

  Middlewares, in order: request log (console), metrics, CORS for
  https://app.example.com, rate limit (only on /limited, keyed by the
  X-Client header), JWT (all but /health, /metrics, /auth/login and
  /swagger), and the error
  handler (THorse.OnError). tools/http_scenarios.sh checks all of this over
  HTTP with curl.

  The JWT secret comes from JWT_SECRET (environment or .env), with a
  development default. *)

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
  ApiSample.Cities in 'ApiSample.Cities.pas';

var
  GPort: Integer;
  GSecret: string;
  GMaintenance: Boolean;

{ Handlers }

procedure GetHealth(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  TJsonSend.Send(ARes, '{"status":"ok"}');
end;

procedure PostLogin(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LBody, LUser: TJsonValue;
  LWriter: TJsonWriter;
  LClaims: string;
begin
  LBody := ParseJson(AReq.Body);
  try
    LUser := LBody.Find('user');
    if (LUser = nil) or (LUser.Kind <> jkString) or (LUser.AsString = '') then
      raise EValidationException.Create('"user" is required.');
    LWriter := TJsonWriter.Create;
    try
      LWriter.BeginObject;
      LWriter.Name('sub');
      LWriter.WriteString(LUser.AsString);
      LWriter.Name('exp');
      LWriter.WriteInt64(TJwt.UnixNow + 3600);
      LWriter.EndObject;
      LClaims := LWriter.ToString;
    finally
      LWriter.Free;
    end;
  finally
    LBody.Free;
  end;
  TJsonSend.Send(ARes, JsonMember('token', TJwt.SignHS256(LClaims, GSecret)));
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
  LPage := PageRequestFrom(ParseQueryInt(AReq.Query['page']), ParseQueryInt(AReq.Query['limit']), 2, 10);
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

procedure FailServer(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  raise EInvalidOpException.Create('something broke');
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

procedure GetLimited(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  TJsonSend.Send(ARes, '{"ok":true}');
end;

// What TLoggerMiddleware left on the request: the trace id (X-Request-Id)
// and this request's span (traceparent), what an outgoing call would send.
procedure GetTrace(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LWriter: TJsonWriter;
begin
  LWriter := TJsonWriter.Create;
  try
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
  Writeln('ERROR ', ALine);
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
  GPort := StrToIntDef(ParamStr(1), 9310);
  GSecret := TAppConfig.Get('JWT_SECRET', 'development-secret-change-me');
  GCallbacks := TSampleCallbacks.Create;

  TErrorHandlerMiddleware.Register(GCallbacks.LogError);
  THorse.Use(TLoggerMiddleware.New);
  THorse.Use(TMetricsMiddleware.New);
  THorse.Use(TCorsMiddleware.New('https://app.example.com'));
  THorse.Use(TJwtMiddleware.New(GSecret, ['/health', '/metrics', '/auth/login', '/swagger']));

  GRateLimit := TRateLimitOptions.Default;
  GRateLimit.Limit := 3;
  GRateLimit.WindowSeconds := 60;
  GRateLimit.KeyExtractor := GCallbacks.ClientKey;

  // Routes registered and documented together. The responses here are JSON
  // written by hand, not DTOs, so only their status codes are documented;
  // samples/02-db documents full schemas.
  TRouteDoc.Get('/health').Summary('Liveness').Tag('public').NoContent(200, 'Up').Register(GetHealth);
  TRouteDoc.Post('/auth/login').Summary('Get a token (1 hour)').Tag('public')
    .NoContent(200, '{"token": "..."}').Error(400, '"user" is missing').Register(PostLogin);
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
  TRouteDoc.Get('/fail/server').Summary('Always 500').Tag('errors').NoMcp
    .Error(500).Register(FailServer);
  TRouteDoc.Get('/fail/database').Summary('Always 503').Tag('errors').NoMcp
    .Error(503).Register(FailDatabase);
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

  Writeln('ApiSample listening on port ', GPort);
  THorse.Listen(GPort);
  GCallbacks.Free;
end.
