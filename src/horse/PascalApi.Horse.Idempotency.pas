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
  - Complete goes inside the try: a store that fails there releases the key
    through Fail, and the client gets the error instead of an answer the
    store never kept.

  Not a middleware: one would have to capture the handler's response body,
  which Horse doesn't expose the same way on both compilers. From
  pascal-agenda-faa's booking handler (SendReplay, PostAppointment). }

interface

uses
  SysUtils,
  Horse,
  PascalApi.Idempotency;

type
  /// One request's use of the key; a value on the handler's stack.
  THorseIdempotentRequest = record
  private
    FIdempotency: TIdempotency;
    FReq: THorseRequest;
    FRes: THorseResponse;
    FScope: string;
    FKey: string;
  public
    /// Reads Idempotency-Key. Without one: False, and the rest does nothing;
    /// or, with ARequired (0.24.0), EHttpException 400
    /// idempotency_key_required. With one: TIdempotency.Start; True when
    /// the key already has an answer, which was sent (the handler exits).
    /// EHttpException 400, 409, 422 as Start raises them.
    function Start(AIdempotency: TIdempotency; AReq: THorseRequest; ARes: THorseResponse;
      const AScope: string; ARequired: Boolean = False): Boolean;
    /// Stores the answer under the key (nothing without one). AHeaders as
    /// HeaderLines writes them.
    procedure Complete(AStatus: Integer; const AJson: string; const AHeaders: string = '');
    /// After the handler raised E: TIdempotency.Fail. Never raises.
    procedure Fail(E: Exception);
    /// Sends AHeaders and the JSON body with AStatus (TJsonSend).
    procedure Send(AStatus: Integer; const AJson: string; const AHeaders: string = '');
    /// The key, unquoted; '' without one.
    property Key: string read FKey;
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
  FIdempotency := AIdempotency;
  FReq := AReq;
  FRes := ARes;
  FScope := AScope;
  FKey := '';
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
    FKey := LKey;
end;

procedure THorseIdempotentRequest.Complete(AStatus: Integer; const AJson, AHeaders: string);
begin
  if FKey <> '' then
    FIdempotency.Complete(FScope, FKey, AStatus, AHeaders, AJson);
end;

procedure THorseIdempotentRequest.Fail(E: Exception);
begin
  if FKey <> '' then
    FIdempotency.Fail(FScope, FKey, E, FReq.Method, FReq.PathInfo);
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
