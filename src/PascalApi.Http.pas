unit PascalApi.Http;

{$I pascalapi.inc}

(* The decisions behind the Horse middlewares, without Horse: which status
  and message an exception becomes, which CORS headers a request gets, what
  an Authorization header holds, which paths skip authentication, the
  client's IP, the request's trace context, the access log line (text or
  JSON), the labels of the HTTP metrics and the health response.

  Kept apart so they are tested without a server, on both compilers; the
  middlewares (the PascalApi.Horse units) only move values between Horse's request
  and response and these functions.

  Messages sent to clients are in TApiMessages.Current: English by default,
  replaceable at startup (e.g. in Portuguese), before the server listens.

  Ported from the middlewares of delphi-api-infra-faa (the Horse.Middleware units).
  Differences:
  - An excluded path prefix matches whole segments: '/auth/login' excludes
    '/auth/login' and '/auth/login/x', not '/auth/login-admin' (the origin's
    StartsWith excluded that too).
  - A 401 names its scheme (BearerChallenge, for WWW-Authenticate), as
    HTTP requires; the origin sent none.
  - pascal-db-faa's EPoolTimeoutException (every pooled connection busy for
    the whole wait) is 503 with TApiMessages.ServerBusy, logged; until
    0.13.0 it was a 500 here, as any unmapped exception.
  - Bodies the JSON mapper rejects become 400: EJsonParseError, and
    EJsonInputError (pascal-jsonmapper-faa 0.5.0: the JSON is at fault; its
    message has JSON terms only, its Detail the Pascal side, not sent). Any
    other EJsonMapperError is a programming error (a DTO not registered, a
    nil class property) and is a 500, logged, even when its message starts
    with a path: until 0.13.0 such a message ('$...') was a 400 that named
    Pascal classes to the client.
  - ETextEncodingException (PascalApi.Text) is 400, like EEncodingError.
  - The request id is the W3C trace id (32 hex digits, 0.8.0), resolved by
    ResolveRequestTrace from traceparent or a 32-digit X-Request-Id; the
    origin made a new 8-digit id for every request.
  - Any other exception is a 500 with a fixed message
    (TApiMessages.InternalError); its class and message go to the error log
    only. The origin, and this unit until 0.13.0, sent E.Message to the
    client, which can carry paths, hosts or SQL.
  - An EHttpException built through a constructor it inherits from
    Exception (CreateFmt, CreateRes...) gets its class's status
    (DefaultStatusCode: 400, 404, 409, 401; 500 for the base class) in
    AfterConstruction. Until 0.17.0 such an exception kept StatusCode 0, and
    the error handler answered "HTTP/1.1 0", which clients refuse (found by
    pascal-agenda-faa, measured on FPC Windows: curl's "Unsupported HTTP/1
    subversion"). A status outside 100-599 that still reaches MapException
    is a 500, logged.
  - An EHttpException may carry a Code (0.17.0), sent as "code" next to
    "error", for clients that branch on it; and every 401 it becomes names
    its scheme (TErrorResponse.Challenge: 'Bearer'), as the middlewares'
    401s do. EUnauthorizedException is the 401 for handlers (a login). *)

interface

uses
  SysUtils,
  PascalCommon.Tracing;

type
  /// A log sink (reference to procedure on Delphi, of object on FPC). The
  /// same type as pascal-common-faa's TPcLogProc, so a TLogProc goes to
  /// TPcTracing.Start as it is.
  TLogProc = TPcLogProc;

  /// An HTTP error: the status code it is answered with and a message that
  /// is safe to send to the client.
  EHttpException = class(Exception)
  private
    FStatusCode: Integer;
    FCode: string;
  public
    constructor Create(AStatusCode: Integer; const AMessage: string); overload;
    /// ACode: a machine-readable name of the refusal, sent as "code"
    /// ('' sends none).
    constructor Create(AStatusCode: Integer; const AMessage, ACode: string); overload;
    /// The status of a subclass built through an inherited Exception
    /// constructor (CreateFmt...): 500 here, each subclass its own.
    class function DefaultStatusCode: Integer; virtual;
    /// Gives StatusCode its class's default when a constructor inherited
    /// from Exception left it 0.
    procedure AfterConstruction; override;
    property StatusCode: Integer read FStatusCode;
    property Code: string read FCode;
  end;

  /// 400: invalid field, missing parameter, business rule broken.
  EValidationException = class(EHttpException)
  public
    constructor Create(const AMessage: string); overload;
    constructor Create(const AMessage, ACode: string); overload;
    class function DefaultStatusCode: Integer; override;
  end;

  /// 401 from a handler (a login refused): answered with WWW-Authenticate,
  /// as the authentication middlewares' 401s.
  EUnauthorizedException = class(EHttpException)
  public
    constructor Create(const AMessage: string; const ACode: string = '');
    class function DefaultStatusCode: Integer; override;
  end;

  /// 404: no resource with the given identifier.
  ENotFoundException = class(EHttpException)
  public
    constructor Create(const AMessage: string = '');
    class function DefaultStatusCode: Integer; override;
  end;

  /// 409: uniqueness conflict or incompatible state.
  EConflictException = class(EHttpException)
  public
    constructor Create(const AMessage: string); overload;
    constructor Create(const AMessage, ACode: string); overload;
    class function DefaultStatusCode: Integer; override;
  end;

  TApiMessages = record
    NotFound: string;
    InvalidEncoding: string;
    InvalidJson: string;               // Format: %s = the parser's message
    DatabaseUnavailable: string;
    LockConflict: string;
    ConstraintUnique: string;
    ConstraintForeignKey: string;
    ConstraintNotNull: string;
    ConstraintCheck: string;
    TokenMissing: string;
    TokenBadFormat: string;
    TokenInvalid: string;
    RateLimited: string;               // Format: %d = seconds to wait
    TenantMissing: string;             // PascalApi.Tenancy: the token names no tenant
    TenantUnknown: string;             // the token's tenant was removed
    TenantSuspended: string;
    InternalError: string;             // 500: any exception not mapped above
    ServerBusy: string;                // 503: no free database connection in time
    InvalidQueryInteger: string;       // Format: %s = the query parameter (PascalApi.Pagination)
    class function English: TApiMessages; static;
    class function Portuguese: TApiMessages; static;
    /// The messages in use. Assign once, at startup.
    class var Current: TApiMessages;
  end;

  TErrorResponse = record
    Status: Integer;
    Message: string;
    /// The EHttpException's Code, sent as "code"; '' for none.
    Code: string;
    /// The WWW-Authenticate value a 401 needs ('Bearer'); '' otherwise.
    Challenge: string;
    /// What goes to the error log; '' when the exception is an expected
    /// outcome (a client error) and isn't logged.
    LogLine: string;
  end;

  THttpHeader = record
    Name: string;
    Value: string;
  end;

  TCorsOptions = record
    /// '*' allows any origin (not allowed together with AllowCredentials).
    /// Otherwise the exact origin (e.g. 'https://app.example.com').
    AllowOrigin: string;
    AllowMethods: string;
    AllowHeaders: string;
    AllowCredentials: Boolean;
    /// Seconds the browser may cache a preflight answer; 0 omits the header.
    MaxAge: Integer;
    /// Response headers exposed to scripts, besides the safelisted ones.
    ExposeHeaders: string;
    /// AllowOrigin '*', methods GET,POST,PUT,PATCH,DELETE,OPTIONS, headers
    /// Content-Type,Authorization, no credentials, MaxAge 86400.
    class function Default: TCorsOptions; static;
  end;

  TBearerResult = (brOk, brMissing, brNotBearer, brEmpty);

  TAccessLogFormat = (alfText, alfJson);

  /// An application's field in the access log line (and, through the
  /// logger middleware, an attribute of the request's server span).
  TLogField = record
    Name: string;
    Value: string;
  end;
  TLogFields = TArray<TLogField>;

  /// One readiness check's outcome, for HealthJson.
  THealthCheckResult = record
    Name: string;
    Ok: Boolean;
  end;

  /// The trace context of one request (W3C Trace Context): its trace id,
  /// which is also the X-Request-Id, and the span the server opens for it.
  TRequestTrace = record
    /// 32 lowercase hex digits.
    TraceId: string;
    /// 16 lowercase hex digits, new for each request: the server's span.
    SpanId: string;
    /// The caller's span, from a valid incoming traceparent; '' otherwise.
    ParentSpanId: string;
    /// The caller's decision when there is one; True for a new trace.
    Sampled: Boolean;
    /// The incoming tracestate to pass on; '' when not forwarded.
    TraceState: string;
    /// '00-<TraceId>-<SpanId>-<flags>': what an outgoing call made while
    /// serving this request sends, so its span is a child of this one.
    function TraceParent: string;
  end;

/// The response for an exception escaping a handler (see the mapping in the
/// implementation). AMethod and APath only go into LogLine.
function MapException(E: Exception; const AMethod, APath: string): TErrorResponse;

/// {"error":"<message>"}.
function ErrorJson(const AMessage: string): string; overload;

/// {"error":"<message>","requestId":"<ARequestId>"}; without requestId when
/// ARequestId is ''. The error handler sends this for the errors it logs
/// (TErrorResponse.LogLine <> ''), so the id a client reports leads support
/// to the log line (which ends with trace_id=<the same id>).
function ErrorJson(const AMessage, ARequestId: string): string; overload;

/// {"error":"<message>","code":"<ACode>","requestId":"<ARequestId>"}; code
/// and requestId only when not ''.
function ErrorJson(const AMessage, ARequestId, ACode: string): string; overload;

/// The CORS headers for a request from ARequestOrigin; none when the origin
/// isn't allowed.
function CorsHeaders(const AOptions: TCorsOptions; const ARequestOrigin: string): TArray<THttpHeader>;

/// The token of "Authorization: Bearer <token>" (scheme case-insensitive).
function ParseBearer(const AAuthorization: string; out AToken: string): TBearerResult;

/// The WWW-Authenticate header of a 401, which HTTP requires (RFC 9110,
/// 11.6.1), in RFC 6750's Bearer form: 'Bearer' when the request carried no
/// Bearer token (no Authorization, or another scheme), and
/// 'Bearer error="invalid_token"' when it carried one that was refused
/// (invalid, expired, empty, or naming no usable tenant).
function BearerChallenge(ATokenRefused: Boolean): string;

/// True if APath is one of the prefixes or below it (whole segments, case
/// ignored). A prefix ending with '/' matches anything below it.
function PathMatchesAny(const APath: string; const APrefixes: array of string): Boolean;

/// The first address of X-Forwarded-For, else ARemoteAddr, else ADefault.
/// What the client claims (a client writes its own X-Forwarded-For): never
/// for a decision or a log. The library uses TrustedClientIp since 0.13.0.
function ClientIp(const AForwardedFor, ARemoteAddr, ADefault: string): string;

/// The client's address as far as it can be trusted: for a rate-limit key, a
/// log line, a span (PascalApi.Horse.Middlewares.TClientAddress).
/// The chain is X-Forwarded-For's addresses followed by ARemoteAddr (the
/// connection's peer). From the right, an address is skipped while it is a
/// proxy: a loopback address (the API calling itself, as the MCP executor
/// does, or a proxy on the same machine), or one of the AProxyHops proxies
/// in front of the API. The first address that isn't one is the client; the
/// leftmost when all are. With AProxyHops = 0 and a peer that isn't
/// loopback, X-Forwarded-For is ignored. ADefault when ARemoteAddr is ''
/// (the peer unknown: nothing in the header can be trusted).
function TrustedClientIp(const AForwardedFor, ARemoteAddr: string; AProxyHops: Integer;
  const ADefault: string): string;

/// What a proxy sends on as X-Forwarded-For: the incoming value with the
/// peer it received the request from appended (the MCP executor's calls).
function ForwardedForChain(const AForwardedFor, ARemoteAddr: string): string;

/// The trace context of a request, from its headers, in this order:
/// 1. a valid traceparent: its trace id, its span as the parent, its
///    sampled flag, and ATraceState passed on;
/// 2. else an X-Request-Id of exactly 32 lowercase hex digits, not all
///    zeros (nginx's $request_id has this shape): adopted as the trace id;
/// 3. else a new trace id.
/// Any other X-Request-Id is ignored: client text never reaches the logs.
/// The span id is always new. Sampled is True unless a valid traceparent
/// says otherwise (parent-based, every new trace sampled).
function ResolveRequestTrace(const ATraceParent, ATraceState, ARequestId: string): TRequestTrace;

/// [yyyy-mm-dd hh:nn:ss] METHOD /path STATUS Xms IP BYTES "QUERY" "USER-AGENT" REQUEST-ID
/// Empty IP, bytes, query or user agent are written as "-".
function AccessLogLine(ATime: TDateTime; const AMethod, APath: string; AStatus: Integer;
  AElapsedMs: Int64; const AIp, ABytes, AQuery, AUserAgent, ARequestId: string): string; overload;

/// The same request as one JSON object, for log collectors:
/// {"time":"yyyy-mm-ddThh:nn:ss.zzz","trace_id":...,"span_id":...,
///  "parent_span_id":...,"method":...,"path":...,"status":...,
///  "duration_ms":...,"client_ip":...,"bytes":...,"query":...,"user_agent":...}
/// ATime is written as given, without a zone (TClock.Now, as the text
/// line). Empty values are left out; bytes is a number when it is one.
function AccessLogJson(ATime: TDateTime; const AMethod, APath: string; AStatus: Integer;
  AElapsedMs: Int64; const AIp, ABytes, AQuery, AUserAgent: string;
  const ATrace: TRequestTrace): string; overload;

/// The same, with the application's fields after the standard ones: in the
/// text line as ' name=value' (the value in double quotes, '"' and '\'
/// escaped with '\', when it has a space, a quote or a backslash), in JSON as string
/// members. A field with an empty value is left out. A name is the
/// application's: one that repeats a standard key gives a JSON object with
/// the key twice.
function AccessLogLine(ATime: TDateTime; const AMethod, APath: string; AStatus: Integer;
  AElapsedMs: Int64; const AIp, ABytes, AQuery, AUserAgent, ARequestId: string;
  const AExtra: TLogFields): string; overload;
function AccessLogJson(ATime: TDateTime; const AMethod, APath: string; AStatus: Integer;
  AElapsedMs: Int64; const AIp, ABytes, AQuery, AUserAgent: string;
  const ATrace: TRequestTrace; const AExtra: TLogFields): string; overload;

/// ALine + ' trace_id=<ATraceId>'; ALine unchanged when ATraceId is ''.
/// For the error handler's line, so it can be found from the response's
/// X-Request-Id.
function WithTraceId(const ALine, ATraceId: string): string;

/// Seconds until AResetUnix, never below 0.
function RetryAfterSeconds(AResetUnix, ANowUnix: Int64): Int64;

/// The http.request.method of a metric: AMethod when it is one of the
/// methods of RFC 9110 or PATCH (GET HEAD POST PUT DELETE CONNECT OPTIONS
/// TRACE PATCH; case-sensitive, as HTTP methods are), else '_OTHER', as the
/// OpenTelemetry semantic conventions ask, so a client can't create series.
function MetricMethod(const AMethod: string): string;

/// The http.route of a metric: AMatchedRoute (THorseRequest.MatchedRoute,
/// the template, '/cities/:id'), never the raw path, so a client can't
/// create series; '' when no route matched (an empty Prometheus label is
/// the same as no label: the semantic conventions' "absent when unknown").
/// Horse leaves in MatchedRoute the deepest node it visited, also when the
/// match was partial: GET /cities/1/extra left '/cities' (measured, Horse
/// 3.3.12, FPC Win64). So a template with a different number of segments
/// than APath is '', unless its last segment is a wildcard ('*').
function MetricRoute(const AMatchedRoute, APath: string): string;

/// The body of a readiness answer and its status: 200 with
/// {"status":"ok","checks":{"<name>":"ok",...}} when every check passed,
/// 503 with "fail" in the failed ones and the top status otherwise. No
/// check: 200 {"status":"ok","checks":{}}. Only names and ok/fail: the
/// endpoint is usually public, so no error detail goes into it.
function HealthJson(const AResults: array of THealthCheckResult; out AStatus: Integer): string;

implementation

uses
  PascalJsonMapper.Json,
  PascalJsonMapper.Mapper,
  PascalCommon.TraceContext,
  PascalDb.Interfaces,
  PascalDb.Pool,
  PascalDb.Version,
  PascalApi.OrderBy,
  PascalApi.Text;

// 0.12.0: EConstraintViolationException (0.11.0) and PascalCommon.SafeLog.
// 0.15.0: TSQLResult's operations return a copy and never change Self;
// before, TTenantFilter.Prepare's ReplaceLiteral on its const parameter
// leaked on FPC 3.2.2 Linux and changed the caller's variable on Win64.
{$IF PASCALDB_VERSION < 1500}
  {$MESSAGE FATAL 'pascal-api-infra-faa needs pascal-db-faa 0.15.0 or later'}
{$IFEND}

{ EHttpException }

constructor EHttpException.Create(AStatusCode: Integer; const AMessage: string);
begin
  inherited Create(AMessage);
  FStatusCode := AStatusCode;
end;

constructor EHttpException.Create(AStatusCode: Integer; const AMessage, ACode: string);
begin
  inherited Create(AMessage);
  FStatusCode := AStatusCode;
  FCode := ACode;
end;

class function EHttpException.DefaultStatusCode: Integer;
begin
  Result := 500;
end;

procedure EHttpException.AfterConstruction;
begin
  inherited AfterConstruction;
  // CreateFmt, CreateRes... are Exception's: they never set the status.
  if FStatusCode = 0 then
    FStatusCode := DefaultStatusCode;
end;

constructor EValidationException.Create(const AMessage: string);
begin
  inherited Create(400, AMessage);
end;

constructor EValidationException.Create(const AMessage, ACode: string);
begin
  inherited Create(400, AMessage, ACode);
end;

class function EValidationException.DefaultStatusCode: Integer;
begin
  Result := 400;
end;

constructor EUnauthorizedException.Create(const AMessage, ACode: string);
begin
  inherited Create(401, AMessage, ACode);
end;

class function EUnauthorizedException.DefaultStatusCode: Integer;
begin
  Result := 401;
end;

constructor ENotFoundException.Create(const AMessage: string);
begin
  if AMessage = '' then
    inherited Create(404, TApiMessages.Current.NotFound)
  else
    inherited Create(404, AMessage);
end;

class function ENotFoundException.DefaultStatusCode: Integer;
begin
  Result := 404;
end;

constructor EConflictException.Create(const AMessage: string);
begin
  inherited Create(409, AMessage);
end;

constructor EConflictException.Create(const AMessage, ACode: string);
begin
  inherited Create(409, AMessage, ACode);
end;

class function EConflictException.DefaultStatusCode: Integer;
begin
  Result := 409;
end;

{ TApiMessages }

class function TApiMessages.English: TApiMessages;
begin
  Result.NotFound := 'Resource not found.';
  Result.InvalidEncoding := 'The request text is not valid UTF-8.';
  Result.InvalidJson := 'Invalid request body: %s';
  Result.DatabaseUnavailable := 'The database is unavailable. Try again shortly.';
  Result.LockConflict := 'The record is locked or was changed by another operation. Try again.';
  Result.ConstraintUnique := 'A record with these values already exists.';
  Result.ConstraintForeignKey :=
    'The record refers to data that does not exist, or other data refers to it.';
  Result.ConstraintNotNull := 'A required field is missing.';
  Result.ConstraintCheck := 'A value is outside the accepted rules.';
  Result.TokenMissing := 'Authorization token missing.';
  Result.TokenBadFormat := 'Invalid format. Use: Authorization: Bearer <token>';
  Result.TokenInvalid := 'Invalid or expired token.';
  Result.RateLimited := 'Rate limit exceeded. Try again in %d second(s).';
  Result.TenantMissing := 'The token names no tenant.';
  Result.TenantUnknown := 'The token''s tenant no longer exists.';
  Result.TenantSuspended := 'This tenant is suspended.';
  Result.InternalError := 'An unexpected error occurred.';
  Result.ServerBusy := 'The server is busy. Try again shortly.';
  Result.InvalidQueryInteger := '"%s" must be an integer.';
end;

class function TApiMessages.Portuguese: TApiMessages;
begin
  Result.NotFound := 'Recurso não encontrado.';
  Result.InvalidEncoding := 'Texto da requisição em codificação inválida: envie o corpo em UTF-8.';
  Result.InvalidJson := 'Corpo da requisição inválido: %s';
  Result.DatabaseUnavailable :=
    'Banco de dados indisponível ou conexão perdida. Tente novamente em instantes.';
  Result.LockConflict :=
    'O registro está bloqueado ou foi alterado por outra operação. Tente novamente.';
  Result.ConstraintUnique := 'Já existe um registro com estes dados.';
  Result.ConstraintForeignKey :=
    'O registro referencia dados inexistentes ou é referenciado por outros dados.';
  Result.ConstraintNotNull := 'Um campo obrigatório não foi informado.';
  Result.ConstraintCheck := 'Um valor está fora das regras aceitas.';
  Result.TokenMissing := 'Token de autorização ausente.';
  Result.TokenBadFormat := 'Formato inválido. Use: Authorization: Bearer <token>';
  Result.TokenInvalid := 'Token inválido ou expirado.';
  Result.RateLimited := 'Limite de requisições excedido. Tente novamente em %d segundo(s).';
  Result.TenantMissing := 'O token não informa o tenant.';
  Result.TenantUnknown := 'O tenant do token não existe mais.';
  Result.TenantSuspended := 'Este tenant está suspenso.';
  Result.InternalError := 'Ocorreu um erro inesperado.';
  Result.ServerBusy := 'O servidor está ocupado. Tente novamente em instantes.';
  Result.InvalidQueryInteger := '"%s" deve ser um número inteiro.';
end;

{ Error mapping }

function DetailLine(const AMethod, APath: string; AStatus: Integer; E: Exception;
  const AOriginalClass, AOriginalMessage: string): string;
begin
  Result := Format('%s %s -> %d: %s (%s: %s)',
    [AMethod, APath, AStatus, E.ClassName, AOriginalClass, AOriginalMessage]);
end;

function MapException(E: Exception; const AMethod, APath: string): TErrorResponse;
var
  LMessages: TApiMessages;
begin
  LMessages := TApiMessages.Current;
  Result.LogLine := '';
  Result.Code := '';
  Result.Challenge := '';

  // An HTTP status that can't go on a status line: the code that raised it
  // is wrong, and the client gets a plain 500.
  if (E is EHttpException) and
    ((EHttpException(E).StatusCode < 100) or (EHttpException(E).StatusCode > 599)) then
  begin
    Result.Status := 500;
    Result.Message := LMessages.InternalError;
    Result.LogLine := Format('%s %s -> %d: %s with status %d, not an HTTP status: %s',
      [AMethod, APath, Result.Status, E.ClassName, EHttpException(E).StatusCode, E.Message]);
  end
  // Client errors: expected outcomes, not logged.
  else if E is EHttpException then
  begin
    Result.Status := EHttpException(E).StatusCode;
    Result.Message := E.Message;
    Result.Code := EHttpException(E).Code;
    // HTTP requires the scheme on every 401 (RFC 9110, 11.6.1).
    if Result.Status = 401 then
      Result.Challenge := BearerChallenge(False);
  end
  else if E is EOrderByException then
  begin
    Result.Status := 400;
    Result.Message := E.Message;
  end
  else if (E is EEncodingError) or (E is ETextEncodingException) then
  begin
    // Delphi's Horse decodes the body with TEncoding.UTF8 and raises on
    // invalid bytes; FPC keeps the bytes (no exception there).
    Result.Status := 400;
    Result.Message := LMessages.InvalidEncoding;
  end
  else if E is EJsonParseError then
  begin
    Result.Status := 400;
    Result.Message := Format(LMessages.InvalidJson, [E.Message]);
  end
  else if E is EJsonInputError then
  begin
    Result.Status := 400;
    Result.Message := Format(LMessages.InvalidJson, [E.Message]);
  end
  // Database: fixed messages (the library's are in English and the driver's
  // detail must not reach the client); the detail goes to the log.
  else if E is EConstraintViolationException then
  begin
    case EConstraintViolationException(E).Kind of
      cvUnique: Result.Message := LMessages.ConstraintUnique;
      cvForeignKey: Result.Message := LMessages.ConstraintForeignKey;
      cvNotNull: Result.Message := LMessages.ConstraintNotNull;
    else
      Result.Message := LMessages.ConstraintCheck;
    end;
    if EConstraintViolationException(E).Kind in [cvUnique, cvForeignKey] then
      Result.Status := 409 // the client's data conflicts with what exists: expected
    else
    begin
      // NOT NULL/CHECK: the service let through a value the table refuses,
      // a missing validation worth seeing in the log.
      Result.Status := 422;
      Result.LogLine := DetailLine(AMethod, APath, Result.Status, E,
        EConstraintViolationException(E).OriginalClassName,
        EConstraintViolationException(E).OriginalMessage);
    end;
  end
  else if E is ELockConflictException then
  begin
    // The client may retry, but frequent deadlocks or long locks are a sign.
    Result.Status := 409;
    Result.Message := LMessages.LockConflict;
    Result.LogLine := DetailLine(AMethod, APath, Result.Status, E,
      ELockConflictException(E).OriginalClassName, ELockConflictException(E).OriginalMessage);
  end
  else if E is EDatabaseUnavailableException then
  begin
    Result.Status := 503;
    Result.Message := LMessages.DatabaseUnavailable;
    Result.LogLine := DetailLine(AMethod, APath, Result.Status, E,
      EDatabaseUnavailableException(E).OriginalClassName,
      EDatabaseUnavailableException(E).OriginalMessage);
  end
  else if E is EPoolTimeoutException then
  begin
    // Capacity, not the database down (pascal-db-faa's docs/errors.md): the
    // client may retry; the pool's state ("Pool: 5/5 active...") is for the
    // log, where frequent ones say the pool or the database is too small.
    Result.Status := 503;
    Result.Message := LMessages.ServerBusy;
    Result.LogLine := Format('%s %s -> %d: %s: %s',
      [AMethod, APath, Result.Status, E.ClassName, E.Message]);
  end
  else
  begin
    // The message may carry paths, hosts or SQL: only the log gets it.
    Result.Status := 500;
    Result.Message := LMessages.InternalError;
    Result.LogLine := Format('%s %s -> %d: %s: %s',
      [AMethod, APath, Result.Status, E.ClassName, E.Message]);
  end;
end;

function ErrorJson(const AMessage: string): string;
begin
  Result := ErrorJson(AMessage, '');
end;

function ErrorJson(const AMessage, ARequestId: string): string;
begin
  Result := ErrorJson(AMessage, ARequestId, '');
end;

function ErrorJson(const AMessage, ARequestId, ACode: string): string;
var
  LWriter: TJsonWriter;
begin
  LWriter := TJsonWriter.Create;
  try
    LWriter.BeginObject;
    LWriter.Name('error');
    LWriter.WriteString(AMessage);
    if ACode <> '' then
    begin
      LWriter.Name('code');
      LWriter.WriteString(ACode);
    end;
    if ARequestId <> '' then
    begin
      LWriter.Name('requestId');
      LWriter.WriteString(ARequestId);
    end;
    LWriter.EndObject;
    Result := LWriter.ToString;
  finally
    LWriter.Free;
  end;
end;

{ TCorsOptions }

class function TCorsOptions.Default: TCorsOptions;
begin
  Result.AllowOrigin := '*';
  Result.AllowMethods := 'GET,POST,PUT,PATCH,DELETE,OPTIONS';
  Result.AllowHeaders := 'Content-Type,Authorization';
  Result.AllowCredentials := False;
  Result.MaxAge := 86400;
  Result.ExposeHeaders := '';
end;

function CorsHeaders(const AOptions: TCorsOptions; const ARequestOrigin: string): TArray<THttpHeader>;
var
  LOrigin: string;

  procedure Add(const AName, AValue: string);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].Name := AName;
    Result[High(Result)].Value := AValue;
  end;

begin
  Result := nil;
  if AOptions.AllowOrigin = '*' then
    LOrigin := '*'
  else if (ARequestOrigin <> '') and SameText(ARequestOrigin, AOptions.AllowOrigin) then
    LOrigin := ARequestOrigin
  else
    Exit;

  Add('Access-Control-Allow-Origin', LOrigin);
  Add('Access-Control-Allow-Methods', AOptions.AllowMethods);
  Add('Access-Control-Allow-Headers', AOptions.AllowHeaders);
  if AOptions.AllowOrigin <> '*' then
    Add('Vary', 'Origin'); // the answer depends on Origin: caches must know
  if AOptions.AllowCredentials then
    Add('Access-Control-Allow-Credentials', 'true');
  if AOptions.MaxAge > 0 then
    Add('Access-Control-Max-Age', IntToStr(AOptions.MaxAge));
  if AOptions.ExposeHeaders <> '' then
    Add('Access-Control-Expose-Headers', AOptions.ExposeHeaders);
end;

{ Authentication }

function ParseBearer(const AAuthorization: string; out AToken: string): TBearerResult;
begin
  AToken := '';
  if Trim(AAuthorization) = '' then
    Exit(brMissing);
  if not SameText(Copy(AAuthorization, 1, 7), 'Bearer ') then
    Exit(brNotBearer);
  AToken := Trim(Copy(AAuthorization, 8, MaxInt));
  if AToken = '' then
    Result := brEmpty
  else
    Result := brOk;
end;

function BearerChallenge(ATokenRefused: Boolean): string;
begin
  if ATokenRefused then
    Result := 'Bearer error="invalid_token"'
  else
    Result := 'Bearer';
end;

function PathMatchesAny(const APath: string; const APrefixes: array of string): Boolean;
var
  I, LLen: Integer;
  LPrefix: string;
begin
  for I := 0 to High(APrefixes) do
  begin
    LPrefix := APrefixes[I];
    LLen := Length(LPrefix);
    if (LLen = 0) or not SameText(Copy(APath, 1, LLen), LPrefix) then
      Continue;
    if (Length(APath) = LLen) or (LPrefix[LLen] = '/') or (APath[LLen + 1] = '/') then
      Exit(True);
  end;
  Result := False;
end;

function ClientIp(const AForwardedFor, ARemoteAddr, ADefault: string): string;
var
  LComma: Integer;
begin
  Result := '';
  if AForwardedFor <> '' then
  begin
    LComma := Pos(',', AForwardedFor);
    if LComma > 0 then
      Result := Trim(Copy(AForwardedFor, 1, LComma - 1))
    else
      Result := Trim(AForwardedFor);
  end;
  if Result = '' then
    Result := Trim(ARemoteAddr);
  if Result = '' then
    Result := ADefault;
end;

function IsLoopback(const AAddress: string): Boolean;
var
  LAddress: string;
begin
  LAddress := LowerCase(AAddress);
  Result := (Copy(LAddress, 1, 4) = '127.') or (LAddress = '::1') or
    (Copy(LAddress, 1, 11) = '::ffff:127.');
end;

function TrustedClientIp(const AForwardedFor, ARemoteAddr: string; AProxyHops: Integer;
  const ADefault: string): string;
var
  LChain: array of string;
  LRest, LItem: string;
  LComma, I, LHops: Integer;
begin
  if Trim(ARemoteAddr) = '' then
    Exit(ADefault);
  LChain := nil;
  LRest := AForwardedFor;
  while LRest <> '' do
  begin
    LComma := Pos(',', LRest);
    if LComma = 0 then
    begin
      LItem := Trim(LRest);
      LRest := '';
    end
    else
    begin
      LItem := Trim(Copy(LRest, 1, LComma - 1));
      LRest := Copy(LRest, LComma + 1, MaxInt);
    end;
    if LItem <> '' then
    begin
      SetLength(LChain, Length(LChain) + 1);
      LChain[High(LChain)] := LItem;
    end;
  end;
  SetLength(LChain, Length(LChain) + 1);
  LChain[High(LChain)] := Trim(ARemoteAddr);
  I := High(LChain);
  LHops := 0;
  while I > 0 do
  begin
    if IsLoopback(LChain[I]) then
      Dec(I)
    else if LHops < AProxyHops then
    begin
      Inc(LHops);
      Dec(I);
    end
    else
      Break;
  end;
  Result := LChain[I];
end;

function ForwardedForChain(const AForwardedFor, ARemoteAddr: string): string;
begin
  if Trim(ARemoteAddr) = '' then
    Result := Trim(AForwardedFor)
  else if Trim(AForwardedFor) = '' then
    Result := Trim(ARemoteAddr)
  else
    Result := Trim(AForwardedFor) + ', ' + Trim(ARemoteAddr);
end;

function TRequestTrace.TraceParent: string;
begin
  Result := PcFormatTraceParent(TraceId, SpanId, Sampled);
end;

function ResolveRequestTrace(const ATraceParent, ATraceState, ARequestId: string): TRequestTrace;
var
  LParent: TPcTraceParent;
  LValid: Boolean;
begin
  LValid := PcTryParseTraceParent(ATraceParent, LParent);
  if LValid then
  begin
    Result.TraceId := LParent.TraceId;
    Result.ParentSpanId := LParent.ParentId;
    Result.Sampled := LParent.Sampled;
  end
  else
  begin
    if PcIsValidTraceId(ARequestId) then
      Result.TraceId := ARequestId
    else
      Result.TraceId := PcNewTraceId;
    Result.ParentSpanId := '';
    Result.Sampled := True;
  end;
  Result.SpanId := PcNewSpanId;
  Result.TraceState := PcResolveTraceState(LValid, ATraceState);
end;

function DashIfEmpty(const AValue: string): string;
begin
  if AValue = '' then
    Result := '-'
  else
    Result := AValue;
end;

function AccessLogLine(ATime: TDateTime; const AMethod, APath: string; AStatus: Integer;
  AElapsedMs: Int64; const AIp, ABytes, AQuery, AUserAgent, ARequestId: string): string;
begin
  Result := AccessLogLine(ATime, AMethod, APath, AStatus, AElapsedMs, AIp, ABytes, AQuery,
    AUserAgent, ARequestId, nil);
end;

function LogFieldText(const AValue: string): string;
var
  I: Integer;
begin
  if (Pos(' ', AValue) = 0) and (Pos('"', AValue) = 0) and (Pos('\', AValue) = 0) then
    Exit(AValue);
  Result := '"';
  for I := 1 to Length(AValue) do
    if (AValue[I] = '"') or (AValue[I] = '\') then
      Result := Result + '\' + AValue[I]
    else
      Result := Result + AValue[I];
  Result := Result + '"';
end;

function AccessLogLine(ATime: TDateTime; const AMethod, APath: string; AStatus: Integer;
  AElapsedMs: Int64; const AIp, ABytes, AQuery, AUserAgent, ARequestId: string;
  const AExtra: TLogFields): string;
var
  I: Integer;
begin
  Result := Format('[%s] %s %s %d %dms %s %s "%s" "%s" %s',
    [FormatDateTime('yyyy-mm-dd hh:nn:ss', ATime), AMethod, APath, AStatus, AElapsedMs,
     DashIfEmpty(AIp), DashIfEmpty(ABytes), DashIfEmpty(AQuery), DashIfEmpty(AUserAgent),
     ARequestId]);
  for I := 0 to High(AExtra) do
    if AExtra[I].Value <> '' then
      Result := Result + ' ' + AExtra[I].Name + '=' + LogFieldText(AExtra[I].Value);
end;

function AccessLogJson(ATime: TDateTime; const AMethod, APath: string; AStatus: Integer;
  AElapsedMs: Int64; const AIp, ABytes, AQuery, AUserAgent: string;
  const ATrace: TRequestTrace): string;
begin
  Result := AccessLogJson(ATime, AMethod, APath, AStatus, AElapsedMs, AIp, ABytes, AQuery,
    AUserAgent, ATrace, nil);
end;

function AccessLogJson(ATime: TDateTime; const AMethod, APath: string; AStatus: Integer;
  AElapsedMs: Int64; const AIp, ABytes, AQuery, AUserAgent: string;
  const ATrace: TRequestTrace; const AExtra: TLogFields): string;
var
  LWriter: TJsonWriter;
  LBytes: Int64;
  I: Integer;

  procedure Text(const AName, AValue: string);
  begin
    if AValue <> '' then
    begin
      LWriter.Name(AName);
      LWriter.WriteString(AValue);
    end;
  end;

begin
  LWriter := TJsonWriter.Create;
  try
    LWriter.BeginObject;
    Text('time', FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz', ATime));
    Text('trace_id', ATrace.TraceId);
    Text('span_id', ATrace.SpanId);
    Text('parent_span_id', ATrace.ParentSpanId);
    Text('method', AMethod);
    Text('path', APath);
    LWriter.Name('status');
    LWriter.WriteInt64(AStatus);
    LWriter.Name('duration_ms');
    LWriter.WriteInt64(AElapsedMs);
    Text('client_ip', AIp);
    if TryStrToInt64(ABytes, LBytes) then
    begin
      LWriter.Name('bytes');
      LWriter.WriteInt64(LBytes);
    end
    else
      Text('bytes', ABytes);
    Text('query', AQuery);
    Text('user_agent', AUserAgent);
    for I := 0 to High(AExtra) do
      Text(AExtra[I].Name, AExtra[I].Value);
    LWriter.EndObject;
    Result := LWriter.ToString;
  finally
    LWriter.Free;
  end;
end;

function WithTraceId(const ALine, ATraceId: string): string;
begin
  if ATraceId = '' then
    Result := ALine
  else
    Result := ALine + ' trace_id=' + ATraceId;
end;

function MetricMethod(const AMethod: string): string;
const
  KNOWN: array[0..8] of string = ('GET', 'HEAD', 'POST', 'PUT', 'DELETE', 'CONNECT',
    'OPTIONS', 'TRACE', 'PATCH');
var
  I: Integer;
begin
  for I := 0 to High(KNOWN) do
    if AMethod = KNOWN[I] then
      Exit(AMethod);
  Result := '_OTHER';
end;

function SegmentCount(const APath: string): Integer;
var
  I: Integer;
  LInSegment: Boolean;
begin
  Result := 0;
  LInSegment := False;
  for I := 1 to Length(APath) do
    if APath[I] = '/' then
      LInSegment := False
    else if not LInSegment then
    begin
      LInSegment := True;
      Inc(Result);
    end;
end;

function MetricRoute(const AMatchedRoute, APath: string): string;
var
  LLast: Integer;
begin
  Result := AMatchedRoute;
  if Result = '' then
    Exit;
  LLast := Length(Result);
  while (LLast > 0) and (Result[LLast] = '/') do
    Dec(LLast);
  if (LLast > 0) and (Result[LLast] = '*') then
    Exit;
  if SegmentCount(AMatchedRoute) <> SegmentCount(APath) then
    Result := '';
end;

function HealthJson(const AResults: array of THealthCheckResult; out AStatus: Integer): string;
var
  LWriter: TJsonWriter;
  LOk: Boolean;
  I: Integer;
begin
  LOk := True;
  for I := 0 to High(AResults) do
    if not AResults[I].Ok then
      LOk := False;
  if LOk then
    AStatus := 200
  else
    AStatus := 503;
  LWriter := TJsonWriter.Create;
  try
    LWriter.BeginObject;
    LWriter.Name('status');
    if LOk then
      LWriter.WriteString('ok')
    else
      LWriter.WriteString('fail');
    LWriter.Name('checks');
    LWriter.BeginObject;
    for I := 0 to High(AResults) do
    begin
      LWriter.Name(AResults[I].Name);
      if AResults[I].Ok then
        LWriter.WriteString('ok')
      else
        LWriter.WriteString('fail');
    end;
    LWriter.EndObject;
    LWriter.EndObject;
    Result := LWriter.ToString;
  finally
    LWriter.Free;
  end;
end;

function RetryAfterSeconds(AResetUnix, ANowUnix: Int64): Int64;
begin
  Result := AResetUnix - ANowUnix;
  if Result < 0 then
    Result := 0;
end;

initialization
  TApiMessages.Current := TApiMessages.English;

end.
