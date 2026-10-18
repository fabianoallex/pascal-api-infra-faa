unit PascalApi.JwtKeys;

{$I pascalapi.inc}

(* JWT signing keys named by "kid": rotate the HS256 secret without
  invalidating the tokens already issued (docs/jwt-keys-design.md, phase 1).
  Opt-in: TJwt and TJwtMiddleware.New(ASecret) don't use this unit.

    LRing := TStaticJwtKeyRing.Parse(TAppConfig.Get('JWT_KEYS'),
      TAppConfig.Get('JWT_SECRET'));
    LToken := TJwtKeys.Sign(LRing, LClaimsJson);           // kid = the signing key's
    if TJwtKeys.Decode(LRing, LToken, LClaims) = jrValid then ...

  A ring holds keys (kid, secret, NotAfter) and optionally a legacy secret.
  The first key signs; every key verifies until its NotAfter (Unix seconds,
  TJwt.UnixNow, 0 for no end). A token without "kid" verifies with the
  legacy secret, so moving from one secret to a ring logs nobody out; with
  no legacy secret it is refused. An unknown kid, or one past its NotAfter,
  is jrBadSignature: the caller isn't told which keys exist. The kid is read
  before the signature is checked and only looked up in memory.

  Sign refuses claims without an integer "exp", or with one later than the
  ring's MaxTokenSeconds from now or than the signing key's NotAfter: such
  a token would stop verifying before its own expiry.

  JWT_KEYS, read by TStaticJwtKeyRing.Parse: entries separated by ",",
  each "kid:secret" or "kid:secret@notAfter"; the first entry signs.

    JWT_KEYS=k2:<new secret>,k1:<old secret>@1767225600

  A kid is 1 to 128 of A-Z a-z 0-9 . _ - ; a secret is not empty and has no
  "," and no "@". EJwtKeyError for anything else, a repeated kid, or no key
  and no legacy secret; its messages never contain a secret.

  The static ring never changes after it is created, so request threads read
  it without a lock. The rotating ring with a store comes in phase 2. *)

interface

uses
  SysUtils,
  PascalJsonMapper.Json,
  PascalApi.Jwt;

type
  EJwtKeyError = class(Exception);

  TJwtKey = record
    Kid: string;
    Secret: string;
    /// Unix seconds: the key verifies while TJwt.UnixNow < NotAfter. 0: no end.
    NotAfter: Int64;
    class function Create(const AKid, ASecret: string; ANotAfter: Int64 = 0): TJwtKey; static;
  end;

  TJwtKeyArray = array of TJwtKey;

  IJwtKeyRing = interface
    ['{1AB09029-B34D-4148-99E2-57201B707C00}']
    /// The key that signs now; False when there is none (a ring with only a
    /// legacy secret, or whose signing key is past its NotAfter).
    function SigningKey(out AKey: TJwtKey): Boolean;
    /// The key named AKid, whatever its NotAfter.
    function FindKey(const AKid: string; out AKey: TJwtKey): Boolean;
    /// The secret of tokens without "kid"; '' refuses them.
    function LegacySecret: string;
    /// The longest lifetime Sign accepts, in seconds; 0: no limit but the
    /// signing key's NotAfter.
    function MaxTokenSeconds: Int64;
  end;

  /// Keys fixed at creation (JWT_KEYS): manual rotation.
  TStaticJwtKeyRing = class(TInterfacedObject, IJwtKeyRing)
  private
    FKeys: TJwtKeyArray;
    FLegacySecret: string;
    FMaxTokenSeconds: Int64;
  public
    /// AKeys[0] signs. EJwtKeyError for an invalid or repeated kid, an empty
    /// secret, or no key and no legacy secret.
    constructor Create(const AKeys: array of TJwtKey; const ALegacySecret: string = '';
      AMaxTokenSeconds: Int64 = 0);
    /// A ring from JWT_KEYS' format (the unit's comment).
    class function Parse(const AText: string; const ALegacySecret: string = '';
      AMaxTokenSeconds: Int64 = 0): IJwtKeyRing; static;
    function SigningKey(out AKey: TJwtKey): Boolean;
    function FindKey(const AKid: string; out AKey: TJwtKey): Boolean;
    function LegacySecret: string;
    function MaxTokenSeconds: Int64;
  end;

  TJwtKeys = class
  public
    /// AClaimsJson signed with the ring's signing key, its kid in the header.
    /// EJwtKeyError when the ring has no signing key; EArgumentException when
    /// the claims break CheckLifetime.
    class function Sign(const ARing: IJwtKeyRing; const AClaimsJson: string): string; static;
    /// TJwt.Decode with the secret the token's kid names (the legacy secret
    /// without a kid). On jrValid the caller frees AClaims; otherwise nil.
    class function Decode(const ARing: IJwtKeyRing; const AToken: string;
      out AClaims: TJsonValue): TJwtResult; static;
    /// Decode, discarding the claims.
    class function Validate(const ARing: IJwtKeyRing; const AToken: string): Boolean; static;
    /// EArgumentException unless AClaimsJson is a JSON object with an integer
    /// "exp" no later than now + AMaxTokenSeconds (when > 0) and than
    /// ANotAfter (when > 0).
    class procedure CheckLifetime(const AClaimsJson: string;
      AMaxTokenSeconds, ANotAfter: Int64); static;
  end;

implementation

function KidIsValid(const AKid: string): Boolean;
var
  I: Integer;
begin
  Result := (AKid <> '') and (Length(AKid) <= JWT_MAX_KID_BYTES);
  if Result then
    for I := 1 to Length(AKid) do
      if not CharInSet(AKid[I], ['A'..'Z', 'a'..'z', '0'..'9', '.', '_', '-']) then
        Exit(False);
end;

function IsDigits(const AText: string): Boolean;
var
  I: Integer;
begin
  Result := AText <> '';
  for I := 1 to Length(AText) do
    if not CharInSet(AText[I], ['0'..'9']) then
      Exit(False);
end;

function Alive(const AKey: TJwtKey): Boolean;
begin
  Result := (AKey.NotAfter <= 0) or (TJwt.UnixNow < AKey.NotAfter);
end;

{ TJwtKey }

class function TJwtKey.Create(const AKid, ASecret: string; ANotAfter: Int64): TJwtKey;
begin
  Result.Kid := AKid;
  Result.Secret := ASecret;
  Result.NotAfter := ANotAfter;
end;

{ TStaticJwtKeyRing }

constructor TStaticJwtKeyRing.Create(const AKeys: array of TJwtKey;
  const ALegacySecret: string; AMaxTokenSeconds: Int64);
var
  I, J: Integer;
begin
  inherited Create;
  if (Length(AKeys) = 0) and (ALegacySecret = '') then
    raise EJwtKeyError.Create('JWT key ring: no key and no legacy secret');
  SetLength(FKeys, Length(AKeys));
  for I := 0 to High(AKeys) do
  begin
    if not KidIsValid(AKeys[I].Kid) then
      raise EJwtKeyError.CreateFmt('JWT key ring: key %d has an invalid kid ' +
        '(1 to %d of A-Z a-z 0-9 . _ -)', [I + 1, JWT_MAX_KID_BYTES]);
    if AKeys[I].Secret = '' then
      raise EJwtKeyError.CreateFmt('JWT key ring: key "%s" has an empty secret', [AKeys[I].Kid]);
    for J := 0 to I - 1 do
      if FKeys[J].Kid = AKeys[I].Kid then
        raise EJwtKeyError.CreateFmt('JWT key ring: kid "%s" appears twice', [AKeys[I].Kid]);
    FKeys[I] := AKeys[I];
  end;
  FLegacySecret := ALegacySecret;
  FMaxTokenSeconds := AMaxTokenSeconds;
end;

class function TStaticJwtKeyRing.Parse(const AText, ALegacySecret: string;
  AMaxTokenSeconds: Int64): IJwtKeyRing;
var
  LKeys: TJwtKeyArray;
  LRest, LEntry, LKid, LSecret, LNotAfter: string;
  LComma, LColon, LAt, LCount: Integer;
  LValue: Int64;
begin
  LKeys := nil;
  LCount := 0;
  LRest := Trim(AText);
  while LRest <> '' do
  begin
    LComma := Pos(',', LRest);
    if LComma = 0 then
    begin
      LEntry := Trim(LRest);
      LRest := '';
    end
    else
    begin
      LEntry := Trim(Copy(LRest, 1, LComma - 1));
      LRest := Trim(Copy(LRest, LComma + 1, MaxInt));
      if LRest = '' then
        raise EJwtKeyError.Create('JWT_KEYS: an empty entry after the last ","');
    end;
    Inc(LCount);
    LColon := Pos(':', LEntry);
    if LColon = 0 then
      raise EJwtKeyError.CreateFmt('JWT_KEYS: entry %d is not kid:secret', [LCount]);
    LKid := Trim(Copy(LEntry, 1, LColon - 1));
    LSecret := Copy(LEntry, LColon + 1, MaxInt);
    LValue := 0;
    LAt := Pos('@', LSecret);
    if LAt > 0 then
    begin
      LNotAfter := Trim(Copy(LSecret, LAt + 1, MaxInt));
      LSecret := Copy(LSecret, 1, LAt - 1);
      // Digits only, and short enough for an Int64: TryStrToInt64 alone
      // would read $10, 0x10 and +10.
      if not IsDigits(LNotAfter) or (Length(LNotAfter) > 18) or
        not TryStrToInt64(LNotAfter, LValue) or (LValue = 0) then
        raise EJwtKeyError.CreateFmt('JWT_KEYS: entry %d has an invalid notAfter ' +
          '(Unix seconds after "@"; a secret has no "@")', [LCount]);
    end;
    LSecret := Trim(LSecret);
    if LSecret = '' then
      raise EJwtKeyError.CreateFmt('JWT_KEYS: entry %d has an empty secret', [LCount]);
    SetLength(LKeys, LCount);
    LKeys[LCount - 1] := TJwtKey.Create(LKid, LSecret, LValue);
  end;
  Result := TStaticJwtKeyRing.Create(LKeys, ALegacySecret, AMaxTokenSeconds);
end;

function TStaticJwtKeyRing.SigningKey(out AKey: TJwtKey): Boolean;
begin
  Result := (Length(FKeys) > 0) and Alive(FKeys[0]);
  if Result then
    AKey := FKeys[0]
  else
    AKey := TJwtKey.Create('', '');
end;

function TStaticJwtKeyRing.FindKey(const AKid: string; out AKey: TJwtKey): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FKeys) do
    if FKeys[I].Kid = AKid then
    begin
      AKey := FKeys[I];
      Exit(True);
    end;
  AKey := TJwtKey.Create('', '');
  Result := False;
end;

function TStaticJwtKeyRing.LegacySecret: string;
begin
  Result := FLegacySecret;
end;

function TStaticJwtKeyRing.MaxTokenSeconds: Int64;
begin
  Result := FMaxTokenSeconds;
end;

{ TJwtKeys }

class procedure TJwtKeys.CheckLifetime(const AClaimsJson: string;
  AMaxTokenSeconds, ANotAfter: Int64);
var
  LClaims, LExp: TJsonValue;
  LValue: Int64;
begin
  try
    LClaims := ParseJson(AClaimsJson);
  except
    on Exception do
      raise EArgumentException.Create('JWT claims: not valid JSON');
  end;
  try
    if LClaims.Kind <> jkObject then
      raise EArgumentException.Create('JWT claims: not a JSON object');
    LExp := LClaims.Find('exp');
    if (LExp = nil) or (LExp.Kind <> jkNumber) or not LExp.TryAsInt64(LValue) then
      raise EArgumentException.Create('JWT claims: "exp" is missing or not an integer');
    if (AMaxTokenSeconds > 0) and (LValue > TJwt.UnixNow + AMaxTokenSeconds) then
      raise EArgumentException.CreateFmt('JWT claims: "exp" is more than %d seconds ahead',
        [AMaxTokenSeconds]);
    if (ANotAfter > 0) and (LValue > ANotAfter) then
      raise EArgumentException.Create(
        'JWT claims: "exp" is later than the signing key''s NotAfter');
  finally
    LClaims.Free;
  end;
end;

class function TJwtKeys.Sign(const ARing: IJwtKeyRing; const AClaimsJson: string): string;
var
  LKey: TJwtKey;
begin
  if ARing = nil then
    raise EArgumentException.Create('TJwtKeys.Sign: no key ring');
  if not ARing.SigningKey(LKey) then
    raise EJwtKeyError.Create('JWT key ring: no key signs now');
  CheckLifetime(AClaimsJson, ARing.MaxTokenSeconds, LKey.NotAfter);
  Result := TJwt.SignHS256(AClaimsJson, LKey.Secret, LKey.Kid);
end;

class function TJwtKeys.Decode(const ARing: IJwtKeyRing; const AToken: string;
  out AClaims: TJsonValue): TJwtResult;
var
  LKid: string;
  LKey: TJwtKey;
begin
  AClaims := nil;
  if ARing = nil then
    Exit(jrBadSignature);
  Result := TJwt.ReadKid(AToken, LKid);
  if Result <> jrValid then
    Exit;
  if LKid = '' then
    // TJwt.Decode refuses an empty secret: no legacy secret, no legacy token.
    Exit(TJwt.Decode(AToken, ARing.LegacySecret, AClaims));
  if not ARing.FindKey(LKid, LKey) or not Alive(LKey) then
    Exit(jrBadSignature);
  Result := TJwt.Decode(AToken, LKey.Secret, AClaims);
end;

class function TJwtKeys.Validate(const ARing: IJwtKeyRing; const AToken: string): Boolean;
var
  LClaims: TJsonValue;
begin
  Result := Decode(ARing, AToken, LClaims) = jrValid;
  LClaims.Free;
end;

end.
