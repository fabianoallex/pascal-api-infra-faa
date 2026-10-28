unit PascalApi.Horse.Idempotency;

{$I pascalapi.inc}

{ Idempotency-Key in a Horse handler (0.23.0): PascalApi.Idempotency's
  policy, with the header read, the fingerprint taken and a stored answer
  sent again.

    procedure PostOrder(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
    var
      LIdem: THorseIdempotentRequest;
      LJson, LHeaders: string;
    begin
      if LIdem.Start(GIdempotency, AReq, ARes, '') then
        Exit;                                  // replayed: the answer was sent
      try
        LJson := ...;                          // the work, and its answer
        LHeaders := HeaderLines([HttpHeader('ETag', VersionETag(LVersion))]);
        LIdem.Complete(201, LJson, LHeaders);  // stored before it is sent
      except
        on E: Exception do
        begin
          LIdem.Fail(E);                       // a 4xx stored, anything else released
          raise;
        end;
      end;
      LIdem.Send(201, LJson, LHeaders);
    end;

  - Without an Idempotency-Key (absent or blank) the request runs as
    before: Start returns False, Complete and Fail do nothing, Send sends.
    Unless ARequired (0.24.0): then Start raises 400
    idempotency_key_required (RequireIdempotencyKey), and the handler
    never runs without a key.
  - The fingerprint is the request's method, path (THorseRequest.PathInfo)
    and body; the scope is the caller's (the tenant's id, '' without
    tenants).
  - A replay sends the stored headers, then Idempotent-Replayed: true, then
    the stored JSON body with its status.
  - Complete goes after the change committed (0.27.0). It never raises: a
    store that fails there (no pooled connection, SQLite's writer lock)
    goes to the error log, the answer is sent, and the key stays claimed
    until its lease runs out; Fail after it does nothing. Until 0.26.0 the
    client got the store's error (a 409 or a 503 for a change that was
    made) and Fail released the key, so a retry ran the change again
    (pascal-agenda-faa, measured under load).
  - CompleteOn (0.27.0) stores the answer on the handler's own query,
    before its commit, when the keys' table is in the same database: the
    answer commits with the change or neither does, and no second
    connection is taken. Then no Complete; Fail after the rollback.

  Not a middleware: one would have to capture the handler's response body,
  which Horse doesn't expose the same way on both compilers. From
  pascal-agenda-faa's booking handler (SendReplay, PostAppointment). }

interface

uses
  SysUtils,
  Horse,
  PascalDb.Interfaces,
  PascalApi.Idempotency;

type
  /// One request's use of the key; a value on the handler's stack.
  THorseIdempotentRequest = record
  private
    FReq: THorseRequest;
    FRes: THorseResponse;
    FCall: TIdempotentCall;
    function GetKey: string;
  public
    /// Reads Idempotency-Key. Without one: False, and the rest does nothing;
    /// or, with ARequired (0.24.0), EHttpException 400
    /// idempotency_key_required. With one: TIdempotency.Start; True when
    /// the key already has an answer, which was sent (the handler exits).
    /// EHttpException 400, 409, 422 as Start raises them.
    function Start(AIdempotency: TIdempotency; AReq: THorseRequest; ARes: THorseResponse;
      const AScope: string; ARequired: Boolean = False): Boolean;
    /// Stores the answer under the key (nothing without one), after the
    /// change committed. AHeaders as HeaderLines writes them. Never raises
    /// (0.27.0): a store's error goes to TErrorHandlerMiddleware.LogError
    /// and the key stays claimed until its lease runs out.
    procedure Complete(AStatus: Integer; const AJson: string; const AHeaders: string = '');
    /// Stores the answer on AQuery, inside the handler's transaction,
    /// before its commit (0.27.0; TDbIdempotencyStore, the keys' table in
    /// the same database). Raises what the store raises: roll back.
    procedure CompleteOn(const AQuery: IQuery; AStatus: Integer; const AJson: string;
      const AHeaders: string = '');
    /// After the handler raised E: TIdempotentCall.Fail. Never raises.
    procedure Fail(E: Exception);
    /// Sends AHeaders and the JSON body with AStatus (TJsonSend).
    procedure Send(AStatus: Integer; const AJson: string; const AHeaders: string = '');
    /// The key, unquoted; '' without one.
    property Key: string read GetKey;
  end;

  THorseIdempotency = class
  public
    /// The stored headers, Idempotent-Replayed: true, then the stored body.
    class procedure SendReplay(ARes: THorseResponse; const AResponse: TStoredResponse); static;
    /// "Name: value" lines (HeaderLines) as response headers.
    class procedure AddHeaders(ARes: THorseResponse; const AHeaders: string); static;
  end;

const
  IDEMPOTENCY_KEY_HEADER = 'Idempotency-Key';
  IDEMPOTENT_REPLAYED_HEADER = 'Idempotent-Replayed';

implementation

uses
  PascalApi.Http,
  PascalApi.Jwt,
  PascalApi.Horse.Middlewares;

{ THorseIdempotentRequest }

function THorseIdempotentRequest.Start(AIdempotency: TIdempotency; AReq: THorseRequest;
  ARes: THorseResponse; const AScope: string; ARequired: Boolean): Boolean;
var
  LKey: string;
  LReplay: TStoredResponse;
begin
  FReq := AReq;
  FRes := ARes;
  FCall.Init(nil, AScope, '', AReq.Method, AReq.PathInfo);
  Result := False;
  LKey := Trim(AReq.Headers[IDEMPOTENCY_KEY_HEADER]);
  if ARequired then
    RequireIdempotencyKey(LKey);
  if LKey = '' then
    Exit;
  if AIdempotency = nil then
    raise EArgumentException.Create('THorseIdempotentRequest.Start: AIdempotency is nil');
  Result := AIdempotency.Start(AScope, LKey,
    RequestFingerprint(AReq.Method, AReq.PathInfo, AReq.Body), TJwt.UnixNow, LReplay);
  if Result then
    THorseIdempotency.SendReplay(ARes, LReplay)
  else
    FCall.Init(AIdempotency, AScope, LKey, AReq.Method, AReq.PathInfo);
end;

function THorseIdempotentRequest.GetKey: string;
begin
  Result := FCall.Key;
end;

procedure THorseIdempotentRequest.Complete(AStatus: Integer; const AJson, AHeaders: string);
begin
  // No key in the line: a key may guard an answer only its client sees.
  if not FCall.Complete(AStatus, AHeaders, AJson) then
    TErrorHandlerMiddleware.LogError(FReq, Format('%s %s: the Idempotency-Key answer was ' +
      'not stored, sent anyway (the key stays claimed until its lease runs out): %s',
      [FReq.Method, FReq.PathInfo, FCall.CompleteError]));
end;

procedure THorseIdempotentRequest.CompleteOn(const AQuery: IQuery; AStatus: Integer;
  const AJson, AHeaders: string);
begin
  FCall.CompleteOn(AQuery, AStatus, AHeaders, AJson);
end;

procedure THorseIdempotentRequest.Fail(E: Exception);
begin
  FCall.Fail(E);
end;

procedure THorseIdempotentRequest.Send(AStatus: Integer; const AJson, AHeaders: string);
begin
  THorseIdempotency.AddHeaders(FRes, AHeaders);
  TJsonSend.Send(FRes, AJson, AStatus);
end;

{ THorseIdempotency }

class procedure THorseIdempotency.AddHeaders(ARes: THorseResponse; const AHeaders: string);
var
  LHeaders: TArray<THttpHeader>;
  I: Integer;
begin
  LHeaders := ParseHeaderLines(AHeaders);
  for I := 0 to High(LHeaders) do
    ARes.AddHeader(LHeaders[I].Name, LHeaders[I].Value);
end;

class procedure THorseIdempotency.SendReplay(ARes: THorseResponse;
  const AResponse: TStoredResponse);
begin
  AddHeaders(ARes, AResponse.Headers);
  ARes.AddHeader(IDEMPOTENT_REPLAYED_HEADER, 'true');
  TJsonSend.Send(ARes, AResponse.Body, AResponse.Status);
end;

end.
