unit PascalApi.Http;

{$I pascalapi.inc}

(* The decisions behind the Horse middlewares, without Horse: which status
  and message an exception becomes, which CORS headers a request gets, what
  an Authorization header holds, which paths skip authentication, the
  client's IP and the access log line.

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
  - Bodies the JSON mapper rejects become 400: EJsonParseError, and
    EJsonMapperError whose message carries a JSON path ('$...'). An
    EJsonMapperError without a path is a programming error (a DTO not
    registered) and stays 500.
  - ETextEncodingException (PascalApi.Text) is 400, like EEncodingError. *)

interface

uses
  SysUtils;

type
  {$IFDEF PASCALAPI_FUNCREFS}
  TLogProc = reference to procedure(const ALine: string);
  {$ELSE}
  TLogProc = procedure(const ALine: string) of object;
  {$ENDIF}

  /// An HTTP error: the status code it is answered with and a message that
  /// is safe to send to the client.
  EHttpException = class(Exception)
  private
    FStatusCode: Integer;
  public
    constructor Create(AStatusCode: Integer; const AMessage: string);
    property StatusCode: Integer read FStatusCode;
  end;

  /// 400: invalid field, missing parameter, business rule broken.
  EValidationException = class(EHttpException)
  public
    constructor Create(const AMessage: string);
  end;

  /// 404: no resource with the given identifier.
  ENotFoundException = class(EHttpException)
  public
    constructor Create(const AMessage: string = '');
  end;

  /// 409: uniqueness conflict or incompatible state.
  EConflictException = class(EHttpException)
  public
    constructor Create(const AMessage: string);
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
    class function English: TApiMessages; static;
    class function Portuguese: TApiMessages; static;
    /// The messages in use. Assign once, at startup.
    class var Current: TApiMessages;
  end;

  TErrorResponse = record
    Status: Integer;
    Message: string;
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

/// The response for an exception escaping a handler (see the mapping in the
/// implementation). AMethod and APath only go into LogLine.
function MapException(E: Exception; const AMethod, APath: string): TErrorResponse;

/// {"error":"<message>"}.
function ErrorJson(const AMessage: string): string;

/// The CORS headers for a request from ARequestOrigin; none when the origin
/// isn't allowed.
function CorsHeaders(const AOptions: TCorsOptions; const ARequestOrigin: string): TArray<THttpHeader>;

/// The token of "Authorization: Bearer <token>" (scheme case-insensitive).
function ParseBearer(const AAuthorization: string; out AToken: string): TBearerResult;

/// True if APath is one of the prefixes or below it (whole segments, case
/// ignored). A prefix ending with '/' matches anything below it.
function PathMatchesAny(const APath: string; const APrefixes: array of string): Boolean;

/// The first address of X-Forwarded-For, else ARemoteAddr, else ADefault.
function ClientIp(const AForwardedFor, ARemoteAddr, ADefault: string): string;

/// 8 hex digits, new for every call (MD5 of a fresh GUID).
function NewRequestId: string;

/// [yyyy-mm-dd hh:nn:ss] METHOD /path STATUS Xms IP BYTES "QUERY" "USER-AGENT" REQUEST-ID
/// Empty IP, bytes, query or user agent are written as "-".
function AccessLogLine(ATime: TDateTime; const AMethod, APath: string; AStatus: Integer;
  AElapsedMs: Int64; const AIp, ABytes, AQuery, AUserAgent, ARequestId: string): string;

/// Seconds until AResetUnix, never below 0.
function RetryAfterSeconds(AResetUnix, ANowUnix: Int64): Int64;

implementation

uses
  PascalJsonMapper.Json,
  PascalJsonMapper.Mapper,
  PascalDb.Interfaces,
  PascalDb.Version,
  PascalApi.OrderBy,
  PascalApi.Text;

// 0.12.0: EConstraintViolationException (0.11.0) and PascalCommon.SafeLog.
{$IF PASCALDB_VERSION < 1200}
  {$MESSAGE FATAL 'pascal-api-infra-faa needs pascal-db-faa 0.12.0 or later'}
{$IFEND}

{ EHttpException }

constructor EHttpException.Create(AStatusCode: Integer; const AMessage: string);
begin
  inherited Create(AMessage);
  FStatusCode := AStatusCode;
end;

constructor EValidationException.Create(const AMessage: string);
begin
  inherited Create(400, AMessage);
end;

constructor ENotFoundException.Create(const AMessage: string);
begin
  if AMessage = '' then
    inherited Create(404, TApiMessages.Current.NotFound)
  else
    inherited Create(404, AMessage);
end;

constructor EConflictException.Create(const AMessage: string);
begin
  inherited Create(409, AMessage);
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

  // Client errors: expected outcomes, not logged.
  if E is EHttpException then
  begin
    Result.Status := EHttpException(E).StatusCode;
    Result.Message := E.Message;
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
  else if (E is EJsonMapperError) and (Copy(E.Message, 1, 1) = '$') then
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
  else
  begin
    Result.Status := 500;
    Result.Message := E.Message;
    Result.LogLine := Format('%s %s -> %d: %s: %s',
      [AMethod, APath, Result.Status, E.ClassName, E.Message]);
  end;
end;

function ErrorJson(const AMessage: string): string;
var
  LWriter: TJsonWriter;
begin
  LWriter := TJsonWriter.Create;
  try
    LWriter.BeginObject;
    LWriter.Name('error');
    LWriter.WriteString(AMessage);
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

function NewRequestId: string;
var
  LGuid: TGUID;
begin
  CreateGUID(LGuid);
  Result := Copy(PaMd5Hex(PaStringToUtf8Bytes(GUIDToString(LGuid))), 1, 8);
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
  Result := Format('[%s] %s %s %d %dms %s %s "%s" "%s" %s',
    [FormatDateTime('yyyy-mm-dd hh:nn:ss', ATime), AMethod, APath, AStatus, AElapsedMs,
     DashIfEmpty(AIp), DashIfEmpty(ABytes), DashIfEmpty(AQuery), DashIfEmpty(AUserAgent),
     ARequestId]);
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
