unit PascalApi.Horse.Middlewares;

{$I pascalapi.inc}

(* The Horse middlewares: error handler, CORS, request logger, Bearer
  authentication, JWT and rate limiting.

    TErrorHandlerMiddleware.Register(LOnError);                 // before Listen
    THorse.Use(TLoggerMiddleware.New);                           // first in the chain; trace id
    THorse.Use(TCorsMiddleware.New('https://app.example.com'));
    THorse.Use(TRateLimitMiddleware.New(60, 60));
    THorse.Use(TJwtMiddleware.New(TAppConfig.Get('JWT_SECRET'), ['/health', '/auth/login']));

  Same calls as delphi-api-infra-faa, with one difference that comes from
  Horse itself: on FPC a Horse callback is a plain procedure, with no
  closure to hold its settings. So each middleware keeps its settings in
  this unit and has ONE configuration per process: calling New again
  replaces the previous settings for every place the middleware was used.
  Configure everything at startup, before Listen.

  The decisions (status codes, headers, messages, log lines) are
  PascalApi.Http's pure functions, tested without a server; this unit moves
  values between Horse's request/response and them. The behavior over HTTP
  is checked by samples/01-api with tools/http_scenarios.sh, on FPC
  (Windows and Linux) and Delphi.

  Callbacks the application passes (token validator, log procedure, rate
  limit key) follow PASCALAPI_FUNCREFS: "reference to" on Delphi, "of
  object" on FPC 3.2.2. *)

interface

uses
  SysUtils,
  Horse,
  Horse.Callback,
  PascalJsonMapper.Json,
  PascalApi.Http;

type
  {$IFDEF PASCALAPI_FUNCREFS}
  TTokenValidator = reference to function(const AToken: string): Boolean;
  TRateLimitKeyExtractor = reference to function(AReq: THorseRequest): string;
  {$ELSE}
  TTokenValidator = function(const AToken: string): Boolean of object;
  TRateLimitKeyExtractor = function(AReq: THorseRequest): string of object;
  {$ENDIF}

  /// Answers exceptions that escape the handlers with {"error": "..."} and
  /// the status of PascalApi.Http.MapException, through THorse.OnError (not
  /// a middleware in the chain: register it any time before Listen). AOnError
  /// gets the log line of the errors worth monitoring (500, 503, 422, lock
  /// conflicts), ending with " trace_id=<X-Request-Id>" when
  /// TLoggerMiddleware is in use; client errors aren't passed to it.
  /// Sends AJson with AStatus as "application/json; charset=utf-8", as UTF-8
  /// bytes. Use it instead of Res.Send(string) for JSON: on Delphi,
  /// Send(string) goes through the web response's Content, which encodes by
  /// the Content-Type's charset; with plain "application/json", "São Paulo"
  /// arrived one byte short with an invalid character in its place
  /// (observed with the console provider, Delphi 12 Win32 and Win64; the
  /// ANSI fallback is the explanation, the bytes weren't dumped). On FPC the
  /// string is already UTF-8 and it doesn't show. Bytes are the same on both.
  TJsonSend = class
  public
    class procedure Send(ARes: THorseResponse; const AJson: string; AStatus: Integer = 200); static;
  end;

  TErrorHandlerMiddleware = class
  public
    class procedure Register; overload; static;
    class procedure Register(const AOnError: TLogProc); overload; static;
  end;

  /// Preflight (OPTIONS) is answered 204 with the CORS headers and stops
  /// there; other requests get the headers and go on.
  TCorsMiddleware = class
  public
    class function New: THorseCallback; overload; static;
    class function New(const AAllowOrigin: string): THorseCallback; overload; static;
    class function New(const AOptions: TCorsOptions): THorseCallback; overload; static;
  end;

  /// One line per request, written when the request ends: text
  /// (PascalApi.Http.AccessLogLine) or JSON (AccessLogJson); to the console
  /// (SafeWriteln) unless AOnLog is given. Use it first, so the time and
  /// status include everything after it.
  ///
  /// It also resolves the request's trace context (ResolveRequestTrace) and
  /// sets, before the handler runs:
  /// - X-Request-Id on the request and the response: the trace id;
  /// - traceparent on the request: this request's span, what an outgoing
  ///   call made by the handler should send (tracestate too, when forwarded).
  /// A handler reads them as AReq.Headers['X-Request-Id'] and
  /// AReq.Headers['traceparent'] (e.g. for its own FileLog lines).
  TLoggerMiddleware = class
  public
    class function New: THorseCallback; overload; static;
    class function New(const AOnLog: TLogProc): THorseCallback; overload; static;
    class function New(const AOnLog: TLogProc; AFormat: TAccessLogFormat): THorseCallback; overload; static;
  end;

  /// "Authorization: Bearer <token>", checked by AValidator; 401 otherwise.
  /// Paths matching AExcludedPrefixes (whole segments) pass untouched.
  TAuthMiddleware = class
  public
    class function Bearer(const AValidator: TTokenValidator): THorseCallback; overload; static;
    class function Bearer(const AValidator: TTokenValidator;
      const AExcludedPrefixes: array of string): THorseCallback; overload; static;
    /// Bearer was called (for TRouteDoc.Serve, which documents the scheme).
    class function Configured: Boolean; static;
    /// APath is one of the excluded prefixes' (needs no token).
    class function Excludes(const APath: string): Boolean; static;
  end;

  /// Bearer authentication with an HS256 JWT (PascalApi.Jwt): signature,
  /// exp and nbf. Independent of TAuthMiddleware (each has its settings).
  TJwtMiddleware = class
  public
    class function New(const ASecret: string): THorseCallback; overload; static;
    class function New(const ASecret: string;
      const AExcludedPrefixes: array of string): THorseCallback; overload; static;
    /// The claims of the request's token, verified again with the configured
    /// secret; nil when absent or invalid. The caller frees the result.
    class function Claims(AReq: THorseRequest): TJsonValue; static;
    /// New was called (for TRouteDoc.Serve, which documents the scheme).
    class function Configured: Boolean; static;
    /// APath is one of the excluded prefixes' (needs no token).
    class function Excludes(const APath: string): Boolean; static;
  end;

  TRateLimitOptions = record
    Limit: Integer;
    WindowSeconds: Integer;
    /// nil: the client's IP (X-Forwarded-For, then the remote address).
    KeyExtractor: TRateLimitKeyExtractor;
    /// 60 requests per 60 seconds, by IP.
    class function Default: TRateLimitOptions; static;
  end;

  /// Sliding window per key (PascalApi.RateLimitState). Every response gets
  /// X-RateLimit-Limit/-Remaining/-Reset; a refused one is 429 with
  /// Retry-After.
  TRateLimitMiddleware = class
  public
    class function New(ALimit, AWindowSeconds: Integer): THorseCallback; overload; static;
    class function New(const AOptions: TRateLimitOptions): THorseCallback; overload; static;
  end;

implementation

uses
  Generics.Collections,
  DateUtils,
  Horse.Core.Param,
  PascalCommon.SafeLog,
  PascalCommon.SystemContext,
  PascalCommon.Threading,
  PascalApi.Jwt,
  PascalApi.RateLimitState,
  PascalApi.Text;

type
  TStringArray = array of string;

var
  GOnError: TLogProc;
  GCorsOptions: TCorsOptions;
  GOnLog: TLogProc;
  GLogFormat: TAccessLogFormat;
  GAuthValidator: TTokenValidator;
  GAuthExcluded: TStringArray;
  GJwtSecret: string;
  GJwtExcluded: TStringArray;
  GRateLimit: TRateLimitOptions;
  GRateLimitState: IRateLimitState;

function AsCallback(AProc: THorseCallbackProc): THorseCallback;
begin
  // FPC: THorseCallback is a record; "Result := AProc" would read as a call.
  // @AProc is the code address (Delphi mode), what Horse's own
  // Implicit(THorseCallbackProc) stores.
  {$IFDEF FPC}
  Result := @AProc;
  {$ELSE}
  Result := AProc;
  {$ENDIF}
end;

function CopyPrefixes(const APrefixes: array of string): TStringArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(APrefixes));
  for I := 0 to High(APrefixes) do
    Result[I] := APrefixes[I];
end;

// THorseRequest.RemoteAddr is only filled by Horse's raw providers (Epoll,
// IOCP, HttpSys, Daemon, LCL); with the console provider it is '' and the
// address is on the web request object (fpWeb on FPC, Indy on Delphi).
// Delphi: from reading Horse's code, not measured yet.
// Seen on FPC 3.2.2/Windows: the access log showed "-" for every request.
function RemoteAddrOf(AReq: THorseRequest): string;
begin
  Result := AReq.RemoteAddr;
  if (Result = '') and (AReq.RawWebRequest <> nil) then
    Result := AReq.RawWebRequest.RemoteAddr;
end;

class procedure TJsonSend.Send(ARes: THorseResponse; const AJson: string; AStatus: Integer);
begin
  ARes.Status(AStatus).ContentType('application/json; charset=utf-8')
    .Send(PaStringToUtf8Bytes(AJson));
end;

procedure SendError(ARes: THorseResponse; AStatus: Integer; const AMessage: string);
begin
  TJsonSend.Send(ARes, ErrorJson(AMessage), AStatus);
end;

{ Error handler }

procedure HandleError(const ARequest: THorseRequest; const AResponse: THorseResponse;
  const AException: Exception);
var
  LError: TErrorResponse;
begin
  LError := MapException(AException, ARequest.Method, ARequest.PathInfo);
  if (LError.LogLine <> '') and Assigned(GOnError) then
    GOnError(WithTraceId(LError.LogLine, ARequest.Headers['X-Request-Id']));
  SendError(AResponse, LError.Status, LError.Message);
end;

class procedure TErrorHandlerMiddleware.Register;
begin
  GOnError := nil;
  THorse.OnError(HandleError);
end;

class procedure TErrorHandlerMiddleware.Register(const AOnError: TLogProc);
begin
  GOnError := AOnError;
  THorse.OnError(HandleError);
end;

{ CORS }

procedure CorsHandler(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LHeaders: TArray<THttpHeader>;
  I: Integer;
begin
  LHeaders := CorsHeaders(GCorsOptions, AReq.Headers['Origin']);
  for I := 0 to High(LHeaders) do
    ARes.AddHeader(LHeaders[I].Name, LHeaders[I].Value);
  if SameText(AReq.Method, 'OPTIONS') then
  begin
    ARes.Status(204).Send('');
    Exit;
  end;
  ANext();
end;

class function TCorsMiddleware.New: THorseCallback;
begin
  Result := New(TCorsOptions.Default);
end;

class function TCorsMiddleware.New(const AAllowOrigin: string): THorseCallback;
var
  LOptions: TCorsOptions;
begin
  LOptions := TCorsOptions.Default;
  LOptions.AllowOrigin := AAllowOrigin;
  Result := New(LOptions);
end;

class function TCorsMiddleware.New(const AOptions: TCorsOptions): THorseCallback;
begin
  GCorsOptions := AOptions;
  Result := AsCallback(CorsHandler);
end;

{ Logger }

function QueryText(AReq: THorseRequest): string;
var
  LPairs: TArray<TPair<string, string>>;
  I: Integer;
begin
  Result := '';
  LPairs := AReq.Query.ToArray;
  for I := 0 to High(LPairs) do
  begin
    if Result <> '' then
      Result := Result + '&';
    Result := Result + LPairs[I].Key + '=' + LPairs[I].Value;
  end;
end;

function ResponseBytes(ARes: THorseResponse): string;
begin
  // Only providers built on a web response object (Indy on Delphi, fpWeb on
  // FPC) expose it; the others leave the field as "-".
  if ARes.RawWebResponse <> nil then
    Result := IntToStr(ARes.RawWebResponse.ContentLength)
  else
    Result := '';
end;

// Set on the request by the first pass of the logger. A header name can't
// contain ':' (it ends the name in HTTP/1.1, and Horse strips HTTP/2
// pseudo-headers), so no client can send it.
const
  LOGGED_KEY = ':pascalapi-logged';

procedure LoggerHandler(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LTrace: TRequestTrace;
  LLine, LIp: string;
  LStart: UInt64;
  LHeaders: THorseList;
begin
  // When no route matches, Horse 3.3.12 runs the router again with '/*'
  // (Horse.Core.RouterTree, DoExecuteInternal), so global middlewares run
  // twice for one request. Seen in samples/02-db's log: two lines for one
  // GET /, the second a child span of the first. The first pass logs it.
  LHeaders := AReq.Headers.Dictionary;
  if LHeaders.ContainsKey(LOGGED_KEY) then
  begin
    ANext();
    Exit;
  end;
  LHeaders.Add(LOGGED_KEY, '1');
  LTrace := ResolveRequestTrace(AReq.Headers['traceparent'], AReq.Headers['tracestate'],
    AReq.Headers['X-Request-Id']);
  // Set before Next, so they are there even when the handler raises. The
  // dictionary ignores case: these replace the incoming headers.
  LHeaders.AddOrSetValue('X-Request-Id', LTrace.TraceId);
  LHeaders.AddOrSetValue('traceparent', LTrace.TraceParent);
  if LTrace.TraceState <> '' then
    LHeaders.AddOrSetValue('tracestate', LTrace.TraceState)
  else
    LHeaders.Remove('tracestate');
  ARes.AddHeader('X-Request-Id', LTrace.TraceId);
  LStart := PcTickMs;
  try
    ANext();
  finally
    LIp := ClientIp(AReq.Headers['X-Forwarded-For'], RemoteAddrOf(AReq), '');
    if GLogFormat = alfJson then
      LLine := AccessLogJson(TClock.Now, AReq.Method, AReq.PathInfo, ARes.Status,
        Int64(PcTickMs - LStart), LIp, ResponseBytes(ARes), QueryText(AReq),
        AReq.Headers['User-Agent'], LTrace)
    else
      LLine := AccessLogLine(TClock.Now, AReq.Method, AReq.PathInfo, ARes.Status,
        Int64(PcTickMs - LStart), LIp, ResponseBytes(ARes), QueryText(AReq),
        AReq.Headers['User-Agent'], LTrace.TraceId);
    if Assigned(GOnLog) then
      GOnLog(LLine)
    else
      SafeWriteln(LLine);
  end;
end;

class function TLoggerMiddleware.New: THorseCallback;
begin
  Result := New(nil, alfText);
end;

class function TLoggerMiddleware.New(const AOnLog: TLogProc): THorseCallback;
begin
  Result := New(AOnLog, alfText);
end;

class function TLoggerMiddleware.New(const AOnLog: TLogProc; AFormat: TAccessLogFormat): THorseCallback;
begin
  GOnLog := AOnLog;
  GLogFormat := AFormat;
  Result := AsCallback(LoggerHandler);
end;

{ Bearer authentication and JWT }

// True when the request may go on; otherwise the 401 was sent.
function CheckBearer(AReq: THorseRequest; ARes: THorseResponse; const AExcluded: TStringArray;
  AUseJwt: Boolean): Boolean;
var
  LToken: string;
  LValid: Boolean;
begin
  if PathMatchesAny(AReq.PathInfo, AExcluded) then
    Exit(True);
  case ParseBearer(AReq.Headers['Authorization'], LToken) of
    brMissing:
      begin
        SendError(ARes, 401, TApiMessages.Current.TokenMissing);
        Exit(False);
      end;
    brNotBearer:
      begin
        SendError(ARes, 401, TApiMessages.Current.TokenBadFormat);
        Exit(False);
      end;
    brEmpty:
      begin
        SendError(ARes, 401, TApiMessages.Current.TokenInvalid);
        Exit(False);
      end;
  end;
  if AUseJwt then
    LValid := TJwt.Validate(LToken, GJwtSecret)
  else
    LValid := Assigned(GAuthValidator) and GAuthValidator(LToken);
  if not LValid then
    SendError(ARes, 401, TApiMessages.Current.TokenInvalid);
  Result := LValid;
end;

procedure AuthHandler(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  if CheckBearer(AReq, ARes, GAuthExcluded, False) then
    ANext();
end;

procedure JwtHandler(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  if CheckBearer(AReq, ARes, GJwtExcluded, True) then
    ANext();
end;

class function TAuthMiddleware.Bearer(const AValidator: TTokenValidator): THorseCallback;
begin
  Result := Bearer(AValidator, []);
end;

class function TAuthMiddleware.Bearer(const AValidator: TTokenValidator;
  const AExcludedPrefixes: array of string): THorseCallback;
begin
  GAuthValidator := AValidator;
  GAuthExcluded := CopyPrefixes(AExcludedPrefixes);
  Result := AsCallback(AuthHandler);
end;

class function TAuthMiddleware.Configured: Boolean;
begin
  Result := Assigned(GAuthValidator);
end;

class function TAuthMiddleware.Excludes(const APath: string): Boolean;
begin
  Result := PathMatchesAny(APath, GAuthExcluded);
end;

class function TJwtMiddleware.Configured: Boolean;
begin
  Result := GJwtSecret <> ''; // New refuses an empty secret
end;

class function TJwtMiddleware.Excludes(const APath: string): Boolean;
begin
  Result := PathMatchesAny(APath, GJwtExcluded);
end;

class function TJwtMiddleware.New(const ASecret: string): THorseCallback;
begin
  Result := New(ASecret, []);
end;

class function TJwtMiddleware.New(const ASecret: string;
  const AExcludedPrefixes: array of string): THorseCallback;
begin
  if ASecret = '' then
    raise EArgumentException.Create('TJwtMiddleware.New: the secret is empty');
  GJwtSecret := ASecret;
  GJwtExcluded := CopyPrefixes(AExcludedPrefixes);
  Result := AsCallback(JwtHandler);
end;

class function TJwtMiddleware.Claims(AReq: THorseRequest): TJsonValue;
var
  LToken: string;
begin
  Result := nil;
  if ParseBearer(AReq.Headers['Authorization'], LToken) = brOk then
    TJwt.Decode(LToken, GJwtSecret, Result);
end;

{ Rate limit }

class function TRateLimitOptions.Default: TRateLimitOptions;
begin
  Result.Limit := 60;
  Result.WindowSeconds := 60;
  Result.KeyExtractor := nil;
end;

procedure RateLimitHandler(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LKey: string;
  LRemaining: Integer;
  LResetUnix, LRetryAfter: Int64;
  LExceeded: Boolean;
begin
  if Assigned(GRateLimit.KeyExtractor) then
    LKey := GRateLimit.KeyExtractor(AReq)
  else
    LKey := ClientIp(AReq.Headers['X-Forwarded-For'], RemoteAddrOf(AReq), 'unknown');

  GRateLimitState.CheckAndRecord(LKey, GRateLimit.Limit, GRateLimit.WindowSeconds,
    LRemaining, LResetUnix, LExceeded);
  ARes.AddHeader('X-RateLimit-Limit', IntToStr(GRateLimit.Limit));
  ARes.AddHeader('X-RateLimit-Remaining', IntToStr(LRemaining));
  ARes.AddHeader('X-RateLimit-Reset', IntToStr(LResetUnix));
  if not LExceeded then
  begin
    ANext();
    Exit;
  end;
  LRetryAfter := RetryAfterSeconds(LResetUnix, DateTimeToUnix(TClock.Now, False));
  ARes.AddHeader('Retry-After', IntToStr(LRetryAfter));
  SendError(ARes, 429, Format(TApiMessages.Current.RateLimited, [LRetryAfter]));
end;

class function TRateLimitMiddleware.New(ALimit, AWindowSeconds: Integer): THorseCallback;
var
  LOptions: TRateLimitOptions;
begin
  LOptions := TRateLimitOptions.Default;
  LOptions.Limit := ALimit;
  LOptions.WindowSeconds := AWindowSeconds;
  Result := New(LOptions);
end;

class function TRateLimitMiddleware.New(const AOptions: TRateLimitOptions): THorseCallback;
begin
  GRateLimit := AOptions;
  GRateLimitState := TRateLimitState.Create; // a new configuration starts with empty windows
  Result := AsCallback(RateLimitHandler);
end;

initialization
  GCorsOptions := TCorsOptions.Default;
  GRateLimit := TRateLimitOptions.Default;
  GRateLimitState := TRateLimitState.Create;

finalization
  GRateLimitState := nil;
  GOnError := nil;
  GOnLog := nil;
  GAuthValidator := nil;

end.
