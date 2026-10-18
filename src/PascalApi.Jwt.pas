unit PascalApi.Jwt;

{$I pascalapi.inc}

(* JSON Web Tokens signed with HS256 (HMAC-SHA256): sign, verify, read claims.

    LToken := TJwt.SignHS256('{"sub":"42","exp":1767225600}', LSecret);

    if TJwt.Decode(LToken, LSecret, LClaims) = jrValid then
    try
      LUserId := LClaims.Find('sub').AsString;
    finally
      LClaims.Free;
    end;

  Decode refuses an empty secret (jrBadSignature): anyone can sign with an
  empty key. Then it checks, in this order: three dot-separated Base64url parts; the
  header is a JSON object with "alg":"HS256" (any other alg, "none"
  included, is refused); the signature (compared in constant time); the
  payload is a JSON object; "exp" and "nbf", when present, are numbers of
  seconds since 1970-01-01 UTC and the token is outside them. No leeway:
  an issuer and a verifier with clocks apart should agree on short
  lifetimes instead.

  "Now" is TJwt.UnixNow: the wall clock of pascal-common-faa's TClock in
  Unix seconds, replaceable in tests. On FPC 3.2.2 for Linux, Now already
  returns UTC whatever the system time zone (measured in pascal-dfe-broker,
  see the skill's native-library-interop.md); DateTimeToUnix(.., False)
  then converts with an offset of 0, so the result is still UTC.

  Claims are pascal-jsonmapper-faa's DOM (PascalJsonMapper.Json.TJsonValue);
  the caller frees what Decode returns. The secret and the payload are
  UTF-8.

  A key id: SignHS256(AClaimsJson, ASecret, AKid) adds "kid" to the header,
  and ReadKid reads it back before anything is verified, so that a key ring
  (PascalApi.JwtKeys) can pick the secret. Decode doesn't look at "kid".

  Ported from TJwtHelper in Horse.Middleware.Jwt (delphi-api-infra-faa),
  which used System.Hash/System.NetEncoding/System.JSON (Delphi only) and
  only verified tokens. New here: SignHS256, the alg check, nbf, the result
  telling why a token was refused, and the constant-time comparison. *)

interface

uses
  SysUtils,
  PascalJsonMapper.Json;

type
  TJwtResult = (jrValid, jrMalformed, jrUnsupportedAlg, jrBadSignature, jrExpired, jrNotYetValid);

const
  /// The longest "kid" accepted, in UTF-8 bytes.
  JWT_MAX_KID_BYTES = 128;

type

  TJwt = class
  public
    /// The token for AClaimsJson (a JSON object, written as given), signed
    /// with ASecret. Header: {"alg":"HS256","typ":"JWT"}.
    class function SignHS256(const AClaimsJson, ASecret: string): string; overload; static;

    /// The same, with the key id AKid in the header:
    /// {"alg":"HS256","typ":"JWT","kid":"<AKid>"}. EArgumentException when
    /// AKid is empty or longer than JWT_MAX_KID_BYTES.
    class function SignHS256(const AClaimsJson, ASecret, AKid: string): string; overload; static;

    /// The header's "kid", read WITHOUT verifying anything: input to choose a
    /// secret with, never to trust. jrValid with AKid '' when the header has
    /// none; jrMalformed when the token has no readable header, or "kid" is
    /// not a string, is empty or longer than JWT_MAX_KID_BYTES.
    class function ReadKid(const AToken: string; out AKid: string): TJwtResult; static;

    /// Verifies AToken. On jrValid, AClaims is the payload (the caller
    /// frees it); on any other result, AClaims is nil.
    class function Decode(const AToken, ASecret: string; out AClaims: TJsonValue): TJwtResult; static;

    /// Decode, discarding the claims.
    class function Validate(const AToken, ASecret: string): Boolean; static;

    /// Current time in Unix seconds (UTC), from TClock.
    class function UnixNow: Int64; static;
  end;

implementation

uses
  DateUtils,
  PascalCommon.SystemContext,
  PascalApi.Text,
  PascalApi.Crypto;

const
  HEADER_HS256 = '{"alg":"HS256","typ":"JWT"}';

function Signature(const ASigningInput, ASecret: string): TBytes;
begin
  Result := PaDigestToBytes(PaHmacSha256(PaStringToUtf8Bytes(ASecret),
    PaStringToUtf8Bytes(ASigningInput)));
end;

// The JSON object in a Base64url part, or nil.
function DecodeJsonPart(const APart: string): TJsonValue;
var
  LBytes: TBytes;
begin
  Result := nil;
  if not PaBase64UrlDecode(APart, LBytes) then
    Exit;
  try
    Result := ParseJson(PaUtf8BytesToString(LBytes, 'JWT'));
  except
    on Exception do
      Exit(nil);
  end;
  if Result.Kind <> jkObject then
    FreeAndNil(Result);
end;

// A numeric claim; False if present but not an integer number.
function ReadTimeClaim(AClaims: TJsonValue; const AName: string; out APresent: Boolean;
  out AValue: Int64): Boolean;
var
  LValue: TJsonValue;
begin
  AValue := 0;
  LValue := AClaims.Find(AName);
  APresent := Assigned(LValue);
  if not APresent then
    Exit(True);
  Result := (LValue.Kind = jkNumber) and LValue.TryAsInt64(AValue);
end;

{ TJwt }

class function TJwt.SignHS256(const AClaimsJson, ASecret: string): string;
var
  LInput: string;
begin
  LInput := PaBase64UrlEncode(PaStringToUtf8Bytes(HEADER_HS256)) + '.' +
    PaBase64UrlEncode(PaStringToUtf8Bytes(AClaimsJson));
  Result := LInput + '.' + PaBase64UrlEncode(Signature(LInput, ASecret));
end;

function KidFits(const AKid: string): Boolean;
begin
  Result := (AKid <> '') and (Length(PaStringToUtf8Bytes(AKid)) <= JWT_MAX_KID_BYTES);
end;

class function TJwt.SignHS256(const AClaimsJson, ASecret, AKid: string): string;
var
  LWriter: TJsonWriter;
  LHeader, LInput: string;
begin
  if not KidFits(AKid) then
    raise EArgumentException.CreateFmt(
      'TJwt.SignHS256: the kid must have 1 to %d bytes', [JWT_MAX_KID_BYTES]);
  // TJsonWriter, not concatenation: the kid is escaped.
  LWriter := TJsonWriter.Create;
  try
    LWriter.BeginObject;
    LWriter.Name('alg');
    LWriter.WriteString('HS256');
    LWriter.Name('typ');
    LWriter.WriteString('JWT');
    LWriter.Name('kid');
    LWriter.WriteString(AKid);
    LWriter.EndObject;
    LHeader := LWriter.ToString;
  finally
    LWriter.Free;
  end;
  LInput := PaBase64UrlEncode(PaStringToUtf8Bytes(LHeader)) + '.' +
    PaBase64UrlEncode(PaStringToUtf8Bytes(AClaimsJson));
  Result := LInput + '.' + PaBase64UrlEncode(Signature(LInput, ASecret));
end;

class function TJwt.ReadKid(const AToken: string; out AKid: string): TJwtResult;
var
  LDot: Integer;
  LHeader, LKid: TJsonValue;
begin
  AKid := '';
  LDot := Pos('.', AToken);
  if LDot <= 1 then
    Exit(jrMalformed);
  LHeader := DecodeJsonPart(Copy(AToken, 1, LDot - 1));
  if LHeader = nil then
    Exit(jrMalformed);
  try
    LKid := LHeader.Find('kid');
    if LKid = nil then
      Exit(jrValid);
    if (LKid.Kind <> jkString) or not KidFits(LKid.AsString) then
      Exit(jrMalformed);
    AKid := LKid.AsString;
    Result := jrValid;
  finally
    LHeader.Free;
  end;
end;

class function TJwt.Decode(const AToken, ASecret: string; out AClaims: TJsonValue): TJwtResult;
var
  LDot1, LDot2: Integer;
  LHeaderPart, LPayloadPart, LSignaturePart: string;
  LHeader, LAlg: TJsonValue;
  LGiven: TBytes;
  LPresent: Boolean;
  LTime: Int64;
begin
  AClaims := nil;
  if ASecret = '' then
    Exit(jrBadSignature);
  LDot1 := Pos('.', AToken);
  if LDot1 = 0 then
    Exit(jrMalformed);
  LDot2 := Pos('.', Copy(AToken, LDot1 + 1, MaxInt));
  if LDot2 = 0 then
    Exit(jrMalformed);
  LDot2 := LDot1 + LDot2;
  LHeaderPart := Copy(AToken, 1, LDot1 - 1);
  LPayloadPart := Copy(AToken, LDot1 + 1, LDot2 - LDot1 - 1);
  LSignaturePart := Copy(AToken, LDot2 + 1, MaxInt);
  if (LHeaderPart = '') or (LPayloadPart = '') or (Pos('.', LSignaturePart) > 0) then
    Exit(jrMalformed);

  LHeader := DecodeJsonPart(LHeaderPart);
  if LHeader = nil then
    Exit(jrMalformed);
  try
    LAlg := LHeader.Find('alg');
    if (LAlg = nil) or (LAlg.Kind <> jkString) or (LAlg.AsString <> 'HS256') then
      Exit(jrUnsupportedAlg);
  finally
    LHeader.Free;
  end;

  if not PaBase64UrlDecode(LSignaturePart, LGiven) then
    Exit(jrMalformed);
  if not PaSameBytes(LGiven, Signature(LHeaderPart + '.' + LPayloadPart, ASecret)) then
    Exit(jrBadSignature);

  AClaims := DecodeJsonPart(LPayloadPart);
  if AClaims = nil then
    Exit(jrMalformed);

  Result := jrValid;
  if not ReadTimeClaim(AClaims, 'exp', LPresent, LTime) then
    Result := jrMalformed
  else if LPresent and (UnixNow >= LTime) then
    Result := jrExpired
  else if not ReadTimeClaim(AClaims, 'nbf', LPresent, LTime) then
    Result := jrMalformed
  else if LPresent and (UnixNow < LTime) then
    Result := jrNotYetValid;
  if Result <> jrValid then
    FreeAndNil(AClaims);
end;

class function TJwt.Validate(const AToken, ASecret: string): Boolean;
var
  LClaims: TJsonValue;
begin
  Result := Decode(AToken, ASecret, LClaims) = jrValid;
  LClaims.Free;
end;

class function TJwt.UnixNow: Int64;
begin
  Result := DateTimeToUnix(TClock.Now, False);
end;

end.
