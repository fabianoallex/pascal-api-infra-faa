unit PascalApi.JwtKeys;

{$I pascalapi.inc}

(* JWT signing keys named by "kid": rotate the HS256 secret without
  invalidating the tokens already issued (docs/jwt-keys-design.md).
  Opt-in: TJwt and TJwtMiddleware.New(ASecret) don't use this unit.

    LRing := TStaticJwtKeyRing.Parse(TAppConfig.Get('JWT_KEYS'),
      TAppConfig.Get('JWT_SECRET'));
    LToken := TJwtKeys.Sign(LRing, LClaimsJson);           // kid = the signing key's
    if TJwtKeys.Decode(LRing, LToken, LClaims) = jrValid then ...

  A ring holds keys (kid, secret, NotAfter) and optionally a legacy secret.
  Every key verifies until its NotAfter (Unix seconds, TJwt.UnixNow, 0 for
  no end). A token without "kid" verifies with the legacy secret, so moving
  from one secret to a ring logs nobody out; with no legacy secret it is
  refused. An unknown kid, or one past its NotAfter, is jrBadSignature: the
  caller isn't told which keys exist. The kid is read before the signature
  is checked and only looked up in memory.

  Sign refuses claims without an integer "exp", or with one later than the
  ring's MaxTokenSeconds from now or than the signing key's NotAfter: such
  a token would stop verifying before its own expiry.

  Two rings:

  - TStaticJwtKeyRing (phase 1): keys fixed at creation, from JWT_KEYS,
    entries separated by ",", each "kid:secret" or "kid:secret@notAfter";
    the first entry signs.

      JWT_KEYS=k2:<new secret>,k1:<old secret>@1767225600

    A kid is 1 to 128 of A-Z a-z 0-9 . _ - ; a secret is not empty and has
    no "," and no "@". EJwtKeyError for anything else, a repeated kid, or
    no key and no legacy secret; its messages never contain a secret. It
    never changes, so request threads read it without a lock.

  - TRotatingJwtKeyRing (phase 2): keys generated (32 random bytes from
    pascal-common-faa's PcRandomBytes) and kept in an IJwtKeyStore that
    every instance of the API shares. A key is pending (verifies, doesn't
    sign) until its ActiveFrom, signs while it is the newest active one, and
    verifies until NotAfter = the next key's ActiveFrom + MaxTokenSeconds,
    a value computed when the keys load, never stored: a store only adds
    and deletes. Every ReloadSeconds (TTicker) the first request that asks
    reloads the keys; when the newest key is RotateEverySeconds old it adds
    generation n+1 with ActiveFrom = now + PropagationSeconds, so that every
    instance has loaded it before a token signed with it arrives (hence
    PropagationSeconds >= ReloadSeconds, checked). Instances racing on
    generation n+1 are settled by the store: TryAdd lets one win and the
    others reload its key. Gone keys are deleted. The store is asked
    outside the lock; while it is down the loaded keys keep working and
    OnError hears about it.

  Stores: TMemoryJwtKeyStore (one process; the keys die with it, so a
  restart logs everyone out) and TDbJwtKeyStore (pascal-db-faa, the
  application's SQL by name). The Redis store is in src/redis
  (PascalApi.Redis.JwtKeys), outside the package. A scope names whose keys
  they are: '' for an API without tenants; a scope's kids start with
  "<scope>/".

  Phase 3, one ring per tenant: PascalApi.Tenancy's TTenantJwtKeyRing. A
  ring whose ScopeClaim isn't '' makes Decode require that claim of the
  verified token to equal the scope of the key that signed it, so a
  tenant's key can't sign another tenant's tokens; SigningKey gets the
  claims to pick the scope. *)

interface

uses
  SysUtils,
  SyncObjs,
  PascalJsonMapper.Json,
  PascalDb.Interfaces,
  PascalCommon.Tracing,
  PascalApi.Jwt;

type
  EJwtKeyError = class(Exception);

  TJwtKey = record
    Kid: string;
    Secret: string;
    /// Unix seconds: the key verifies while TJwt.UnixNow < NotAfter. 0: no end.
    NotAfter: Int64;
    /// A generated key's place in its scope: 1, 2, 3... 0 for a static key.
    Generation: Integer;
    /// Unix seconds; 0 for a static key.
    CreatedAt: Int64;
    /// Unix seconds: the key signs from then on (until a newer key does).
    /// 0 for a static key.
    ActiveFrom: Int64;
    /// Whose key it is ('' for a static key or a ring without scope). Set by
    /// the ring, never stored.
    Scope: string;
    class function Create(const AKid, ASecret: string; ANotAfter: Int64 = 0): TJwtKey; static;
  end;

  TJwtKeyArray = array of TJwtKey;

  IJwtKeyRing = interface
    ['{1AB09029-B34D-4148-99E2-57201B707C00}']
    /// The key that signs AClaims now (a JSON object; nil when the ring
    /// needs none, as the static and rotating rings); False when there is
    /// none (a ring with only a legacy secret, a signing key past its
    /// NotAfter, claims naming no scope the ring knows).
    function SigningKey(const AClaims: TJsonValue; out AKey: TJwtKey): Boolean;
    /// The key named AKid, whatever its NotAfter.
    function FindKey(const AKid: string; out AKey: TJwtKey): Boolean;
    /// The secret of tokens without "kid"; '' refuses them.
    function LegacySecret: string;
    /// The longest lifetime Sign accepts, in seconds; 0: no limit but the
    /// signing key's NotAfter.
    function MaxTokenSeconds: Int64;
    /// The claim a token must carry equal to its key's Scope ('' : none).
    function ScopeClaim: string;
  end;

  /// Where generated keys live, shared by every instance of the API. Only
  /// adds and deletes: a key never changes once stored.
  IJwtKeyStore = interface
    ['{DFF8250D-EAAD-44C1-9AD7-3C909338A232}']
    /// AScope's keys (Kid, Secret, Generation, CreatedAt, ActiveFrom; NotAfter
    /// is the ring's), in any order.
    function Load(const AScope: string): TJwtKeyArray;
    /// Stores AKey; False when AScope already has AKey.Generation (another
    /// instance won the rotation). Any other failure raises.
    function TryAdd(const AScope: string; const AKey: TJwtKey): Boolean;
    /// Removes AScope's key AKid; nothing when it isn't there.
    procedure Delete(const AScope, AKid: string);
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
    function SigningKey(const AClaims: TJsonValue; out AKey: TJwtKey): Boolean;
    function FindKey(const AKid: string; out AKey: TJwtKey): Boolean;
    function LegacySecret: string;
    function MaxTokenSeconds: Int64;
    function ScopeClaim: string;
  end;

  TJwtRotationOptions = record
    /// A new key when the newest one is this old. Default: 30 days.
    RotateEverySeconds: Int64;
    /// A new key signs this long after it is stored; at least ReloadSeconds.
    /// Default: 120.
    PropagationSeconds: Int64;
    /// The longest token lifetime Sign accepts; an old key verifies this
    /// long after the next one starts signing. Must be > 0. Default: 3600.
    MaxTokenSeconds: Int64;
    /// How often the keys are read again from the store. Default: 60.
    ReloadSeconds: Int64;
    /// The secret of tokens without kid ('' refuses them). Default: ''.
    LegacySecret: string;
    class function Default: TJwtRotationOptions; static;
  end;

  /// Keys generated and rotated by the ring, kept in AStore (the unit's
  /// comment). Thread-safe.
  TRotatingJwtKeyRing = class(TInterfacedObject, IJwtKeyRing)
  private
    FStore: IJwtKeyStore;
    FOptions: TJwtRotationOptions;
    FScope: string;
    FLock: TCriticalSection;
    FKeys: TJwtKeyArray;    // by Generation, ascending; NotAfter computed
    FLoadedAtMs: UInt64;
    FBusy: Boolean;
    FOnError: TPcLogProc;
    procedure Maintain;
    procedure Refresh(ARaise: Boolean);
    function NewKid: string;
  public
    /// Loads AScope's keys from AStore, adding the first one when there is
    /// none: the store's errors raise here (at startup), not later.
    /// EArgumentException for a nil store or options out of range.
    constructor Create(const AStore: IJwtKeyStore; const AOptions: TJwtRotationOptions;
      const AScope: string = '');
    destructor Destroy; override;
    /// Reloads and rotates now, whatever ReloadSeconds says; raises the
    /// store's error.
    procedure Reload;
    function SigningKey(const AClaims: TJsonValue; out AKey: TJwtKey): Boolean;
    function FindKey(const AKid: string; out AKey: TJwtKey): Boolean;
    function LegacySecret: string;
    function MaxTokenSeconds: Int64;
    /// '': a ring on its own checks no claim (TTenantJwtKeyRing does).
    function ScopeClaim: string;
    /// The keys as loaded (NotAfter computed), oldest first.
    function Keys: TJwtKeyArray;
    /// A reload that failed after startup (the loaded keys stay in use).
    /// Set it before the ring is shared.
    property OnError: TPcLogProc read FOnError write FOnError;
  end;

  /// Keys in this process only, for tests and a single instance that
  /// accepts losing them on restart (every token is then refused).
  /// Thread-safe.
  TMemoryJwtKeyStore = class(TInterfacedObject, IJwtKeyStore)
  private type
    TEntry = record
      Scope: string;
      Key: TJwtKey;
    end;
  private
    FLock: TCriticalSection;
    FEntries: array of TEntry;
  public
    constructor Create;
    destructor Destroy; override;
    function Load(const AScope: string): TJwtKeyArray;
    function TryAdd(const AScope: string; const AKey: TJwtKey): Boolean;
    procedure Delete(const AScope, AKid: string);
  end;

  /// Keys in a database, through the application's SQL named in the
  /// factory's SqlLoader. ALoadSql takes :TENANT_ID and returns the columns
  /// KID, SECRET, GENERATION, CREATED_AT, ACTIVE_FROM; AAddSql takes
  /// :TENANT_ID, :GENERATION, :KID, :SECRET, :CREATED_AT, :ACTIVE_FROM and
  /// needs a unique key on (TENANT_ID, GENERATION): its
  /// EConstraintViolationException (cvUnique) is TryAdd's False; ADeleteSql
  /// takes :TENANT_ID and :KID. TENANT_ID is the scope ('' without tenants).
  TDbJwtKeyStore = class(TInterfacedObject, IJwtKeyStore)
  private
    FFactory: IDBFactory;
    FLoadSql, FAddSql, FDeleteSql: string;
  public
    constructor Create(const AFactory: IDBFactory; const ALoadSql: string = 'JWT_KEY.BY_TENANT';
      const AAddSql: string = 'JWT_KEY.INSERT'; const ADeleteSql: string = 'JWT_KEY.DELETE');
    function Load(const AScope: string): TJwtKeyArray;
    function TryAdd(const AScope: string; const AKey: TJwtKey): Boolean;
    procedure Delete(const AScope, AKid: string);
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

uses
  PascalCommon.SystemContext,
  PascalCommon.Random,
  PascalApi.Text,
  PascalApi.Crypto;

const
  SECRET_BYTES = 32;
  KID_BYTES = 8;  // 16 hex digits

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

function NoKey: TJwtKey;
begin
  Result := TJwtKey.Create('', '');
end;

{ TJwtKey }

class function TJwtKey.Create(const AKid, ASecret: string; ANotAfter: Int64): TJwtKey;
begin
  Result.Kid := AKid;
  Result.Secret := ASecret;
  Result.NotAfter := ANotAfter;
  Result.Generation := 0;
  Result.CreatedAt := 0;
  Result.ActiveFrom := 0;
  Result.Scope := '';
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

function TStaticJwtKeyRing.SigningKey(const AClaims: TJsonValue; out AKey: TJwtKey): Boolean;
begin
  Result := (Length(FKeys) > 0) and Alive(FKeys[0]);
  if Result then
    AKey := FKeys[0]
  else
    AKey := NoKey;
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
  AKey := NoKey;
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

function TStaticJwtKeyRing.ScopeClaim: string;
begin
  Result := '';
end;

{ TJwtRotationOptions }

class function TJwtRotationOptions.Default: TJwtRotationOptions;
begin
  Result.RotateEverySeconds := 30 * 86400;
  Result.PropagationSeconds := 120;
  Result.MaxTokenSeconds := 3600;
  Result.ReloadSeconds := 60;
  Result.LegacySecret := '';
end;

{ TRotatingJwtKeyRing }

// The keys ordered by Generation, NotAfter from the next key, the gone ones
// left out (and named in AGone, for the store). Raises on a key the store
// can't have written: such a ring would sign or verify wrongly.
function PrepareKeys(const ALoaded: TJwtKeyArray; AMaxTokenSeconds: Int64;
  const AScope: string; out AGone: TJwtKeyArray): TJwtKeyArray;
var
  LSorted: TJwtKeyArray;
  LKey: TJwtKey;
  I, J, LCount, LGoneCount: Integer;
begin
  LSorted := Copy(ALoaded);
  for I := 0 to High(LSorted) do
  begin
    if (LSorted[I].Kid = '') or (Length(PaStringToUtf8Bytes(LSorted[I].Kid)) > JWT_MAX_KID_BYTES) then
      raise EJwtKeyError.CreateFmt('JWT key store: generation %d has an invalid kid',
        [LSorted[I].Generation]);
    if LSorted[I].Secret = '' then
      raise EJwtKeyError.CreateFmt('JWT key store: key "%s" has an empty secret', [LSorted[I].Kid]);
    if LSorted[I].Generation < 1 then
      raise EJwtKeyError.CreateFmt('JWT key store: key "%s" has generation %d',
        [LSorted[I].Kid, LSorted[I].Generation]);
  end;
  // Insertion sort: a scope has a handful of keys.
  for I := 1 to High(LSorted) do
  begin
    LKey := LSorted[I];
    J := I - 1;
    while (J >= 0) and (LSorted[J].Generation > LKey.Generation) do
    begin
      LSorted[J + 1] := LSorted[J];
      Dec(J);
    end;
    LSorted[J + 1] := LKey;
  end;
  for I := 1 to High(LSorted) do
    if LSorted[I].Generation = LSorted[I - 1].Generation then
      raise EJwtKeyError.CreateFmt('JWT key store: generation %d appears twice',
        [LSorted[I].Generation]);

  Result := nil;
  AGone := nil;
  SetLength(Result, Length(LSorted));
  SetLength(AGone, Length(LSorted));
  LCount := 0;
  LGoneCount := 0;
  for I := 0 to High(LSorted) do
  begin
    LKey := LSorted[I];
    LKey.Scope := AScope;
    if I < High(LSorted) then
      LKey.NotAfter := LSorted[I + 1].ActiveFrom + AMaxTokenSeconds
    else
      LKey.NotAfter := 0;
    if Alive(LKey) then
    begin
      Result[LCount] := LKey;
      Inc(LCount);
    end
    else
    begin
      AGone[LGoneCount] := LKey;
      Inc(LGoneCount);
    end;
  end;
  SetLength(Result, LCount);
  SetLength(AGone, LGoneCount);
end;

constructor TRotatingJwtKeyRing.Create(const AStore: IJwtKeyStore;
  const AOptions: TJwtRotationOptions; const AScope: string);
begin
  inherited Create;
  if AStore = nil then
    raise EArgumentException.Create('TRotatingJwtKeyRing: no store');
  if (AOptions.RotateEverySeconds <= 0) or (AOptions.MaxTokenSeconds <= 0) or
    (AOptions.ReloadSeconds <= 0) or (AOptions.PropagationSeconds < AOptions.ReloadSeconds) then
    raise EArgumentException.Create('TRotatingJwtKeyRing: RotateEverySeconds, MaxTokenSeconds ' +
      'and ReloadSeconds must be > 0, and PropagationSeconds >= ReloadSeconds');
  // The kid is "<scope>/<16 hex>": it must fit JWT_MAX_KID_BYTES.
  if (Pos('/', AScope) > 0) or
    (Length(PaStringToUtf8Bytes(AScope)) > JWT_MAX_KID_BYTES - 2 * KID_BYTES - 1) then
    raise EArgumentException.Create('TRotatingJwtKeyRing: the scope has a "/" or is too long');
  FStore := AStore;
  FOptions := AOptions;
  FScope := AScope;
  FLock := TCriticalSection.Create;
  Refresh(True);
  FLoadedAtMs := TTicker.NowMs;
end;

destructor TRotatingJwtKeyRing.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TRotatingJwtKeyRing.NewKid: string;
begin
  Result := PaBytesToHex(PcRandomBytes(KID_BYTES)); // lowercase hex
  if FScope <> '' then
    Result := FScope + '/' + Result;
end;

procedure TRotatingJwtKeyRing.Refresh(ARaise: Boolean);
var
  LLoaded, LKeys, LGone: TJwtKeyArray;
  LNewest, LNew: TJwtKey;
  LNow: Int64;
  I: Integer;
begin
  try
    LLoaded := FStore.Load(FScope);
    LKeys := PrepareKeys(LLoaded, FOptions.MaxTokenSeconds, FScope, LGone);
    LNow := TJwt.UnixNow;
    // Rotation: no key yet, or the newest one is old enough. The first key
    // signs at once (no instance holds an older one to wait for).
    if Length(LLoaded) = 0 then
      LNewest := NoKey
    else
      LNewest := LKeys[High(LKeys)]; // the newest is never gone (NotAfter 0)
    if (Length(LLoaded) = 0) or (LNewest.ActiveFrom + FOptions.RotateEverySeconds <= LNow) then
    begin
      LNew := TJwtKey.Create(NewKid, PaBase64UrlEncode(PcRandomBytes(SECRET_BYTES)));
      LNew.Generation := LNewest.Generation + 1;
      LNew.CreatedAt := LNow;
      if Length(LLoaded) = 0 then
        LNew.ActiveFrom := LNow
      else
        LNew.ActiveFrom := LNow + FOptions.PropagationSeconds;
      // Lost or won, the store now has generation n+1: read it back.
      FStore.TryAdd(FScope, LNew);
      LLoaded := FStore.Load(FScope);
      LKeys := PrepareKeys(LLoaded, FOptions.MaxTokenSeconds, FScope, LGone);
    end;
    for I := 0 to High(LGone) do
      FStore.Delete(FScope, LGone[I].Kid);
    if Length(LKeys) = 0 then
      raise EJwtKeyError.Create('JWT key store: no key after a rotation');
    FLock.Acquire;
    try
      FKeys := LKeys;
    finally
      FLock.Release;
    end;
  except
    on E: Exception do
    begin
      if ARaise then
        raise;
      if Assigned(FOnError) then
        FOnError(Format('JWT key ring "%s": reload failed, the loaded keys stay in use: %s: %s',
          [FScope, E.ClassName, E.Message]));
    end;
  end;
end;

procedure TRotatingJwtKeyRing.Maintain;
var
  LDue: Boolean;
begin
  FLock.Acquire;
  try
    LDue := not FBusy and (TTicker.ElapsedMs(FLoadedAtMs) >= UInt64(FOptions.ReloadSeconds) * 1000);
    if LDue then
      FBusy := True;
  finally
    FLock.Release;
  end;
  if not LDue then
    Exit;
  // One thread reloads, outside the lock; the others keep the loaded keys.
  try
    Refresh(False);
  finally
    FLock.Acquire;
    try
      FBusy := False;
      FLoadedAtMs := TTicker.NowMs; // also after a failure: retried after ReloadSeconds
    finally
      FLock.Release;
    end;
  end;
end;

procedure TRotatingJwtKeyRing.Reload;
begin
  Refresh(True);
  FLock.Acquire;
  try
    FLoadedAtMs := TTicker.NowMs;
  finally
    FLock.Release;
  end;
end;

function TRotatingJwtKeyRing.SigningKey(const AClaims: TJsonValue; out AKey: TJwtKey): Boolean;
var
  I: Integer;
  LNow: Int64;
begin
  Maintain;
  AKey := NoKey;
  Result := False;
  LNow := TJwt.UnixNow;
  FLock.Acquire;
  try
    for I := High(FKeys) downto 0 do
      if (FKeys[I].ActiveFrom <= LNow) and Alive(FKeys[I]) then
      begin
        AKey := FKeys[I];
        Exit(True);
      end;
  finally
    FLock.Release;
  end;
end;

function TRotatingJwtKeyRing.FindKey(const AKid: string; out AKey: TJwtKey): Boolean;
var
  I: Integer;
begin
  Maintain;
  AKey := NoKey;
  Result := False;
  FLock.Acquire;
  try
    for I := 0 to High(FKeys) do
      if FKeys[I].Kid = AKid then
      begin
        AKey := FKeys[I];
        Exit(True);
      end;
  finally
    FLock.Release;
  end;
end;

function TRotatingJwtKeyRing.LegacySecret: string;
begin
  Result := FOptions.LegacySecret;
end;

function TRotatingJwtKeyRing.MaxTokenSeconds: Int64;
begin
  Result := FOptions.MaxTokenSeconds;
end;

function TRotatingJwtKeyRing.ScopeClaim: string;
begin
  Result := '';
end;

function TRotatingJwtKeyRing.Keys: TJwtKeyArray;
begin
  FLock.Acquire;
  try
    Result := Copy(FKeys);
  finally
    FLock.Release;
  end;
end;

{ TMemoryJwtKeyStore }

constructor TMemoryJwtKeyStore.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TMemoryJwtKeyStore.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TMemoryJwtKeyStore.Load(const AScope: string): TJwtKeyArray;
var
  I, LCount: Integer;
begin
  Result := nil;
  FLock.Acquire;
  try
    SetLength(Result, Length(FEntries));
    LCount := 0;
    for I := 0 to High(FEntries) do
      if FEntries[I].Scope = AScope then
      begin
        Result[LCount] := FEntries[I].Key;
        Result[LCount].NotAfter := 0;
        Inc(LCount);
      end;
    SetLength(Result, LCount);
  finally
    FLock.Release;
  end;
end;

function TMemoryJwtKeyStore.TryAdd(const AScope: string; const AKey: TJwtKey): Boolean;
var
  I: Integer;
begin
  FLock.Acquire;
  try
    for I := 0 to High(FEntries) do
      if (FEntries[I].Scope = AScope) and
        ((FEntries[I].Key.Generation = AKey.Generation) or (FEntries[I].Key.Kid = AKey.Kid)) then
        Exit(False);
    SetLength(FEntries, Length(FEntries) + 1);
    FEntries[High(FEntries)].Scope := AScope;
    FEntries[High(FEntries)].Key := AKey;
    Result := True;
  finally
    FLock.Release;
  end;
end;

procedure TMemoryJwtKeyStore.Delete(const AScope, AKid: string);
var
  I, J: Integer;
begin
  FLock.Acquire;
  try
    for I := 0 to High(FEntries) do
      if (FEntries[I].Scope = AScope) and (FEntries[I].Key.Kid = AKid) then
      begin
        for J := I to High(FEntries) - 1 do
          FEntries[J] := FEntries[J + 1];
        SetLength(FEntries, Length(FEntries) - 1);
        Exit;
      end;
  finally
    FLock.Release;
  end;
end;

{ TDbJwtKeyStore }

constructor TDbJwtKeyStore.Create(const AFactory: IDBFactory; const ALoadSql, AAddSql,
  ADeleteSql: string);
begin
  inherited Create;
  if AFactory = nil then
    raise EArgumentException.Create('TDbJwtKeyStore: no factory');
  FFactory := AFactory;
  FLoadSql := ALoadSql;
  FAddSql := AAddSql;
  FDeleteSql := ADeleteSql;
end;

function TDbJwtKeyStore.Load(const AScope: string): TJwtKeyArray;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
  LCount: Integer;
begin
  Result := nil;
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader[FLoadSql].SQL;
    LQuery.Params.Strings['TENANT_ID'] := AScope;
    LResult := LQuery.Open;
    LCount := 0;
    while not LResult.Eof do
    begin
      SetLength(Result, LCount + 1);
      Result[LCount] := TJwtKey.Create(LResult.Strings['KID'], LResult.Strings['SECRET']);
      Result[LCount].Generation := LResult.Integers['GENERATION'];
      Result[LCount].CreatedAt := LResult.Int64s['CREATED_AT'];
      Result[LCount].ActiveFrom := LResult.Int64s['ACTIVE_FROM'];
      Inc(LCount);
      LResult.Next;
    end;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

function TDbJwtKeyStore.TryAdd(const AScope: string; const AKey: TJwtKey): Boolean;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader[FAddSql].SQL;
    LQuery.Params.Strings['TENANT_ID'] := AScope;
    LQuery.Params.Integers['GENERATION'] := AKey.Generation;
    LQuery.Params.Strings['KID'] := AKey.Kid;
    LQuery.Params.Strings['SECRET'] := AKey.Secret;
    LQuery.Params.Int64s['CREATED_AT'] := AKey.CreatedAt;
    LQuery.Params.Int64s['ACTIVE_FROM'] := AKey.ActiveFrom;
    LQuery.ExecSql;
    LScope.Commit;
    Result := True;
  except
    on E: EConstraintViolationException do
    begin
      LScope.Rollback;
      // Another instance stored this generation first. Anything else (a
      // NOT NULL, a check) is the application's schema at fault: raise.
      if E.Kind <> cvUnique then
        raise;
      Result := False;
    end;
    on Exception do
    begin
      LScope.Rollback;
      raise;
    end;
  end;
end;

procedure TDbJwtKeyStore.Delete(const AScope, AKid: string);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader[FDeleteSql].SQL;
    LQuery.Params.Strings['TENANT_ID'] := AScope;
    LQuery.Params.Strings['KID'] := AKid;
    LQuery.ExecSql;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
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
  LClaims: TJsonValue;
  LFound: Boolean;
begin
  if ARing = nil then
    raise EArgumentException.Create('TJwtKeys.Sign: no key ring');
  // The claims as JSON first (EArgumentException): a ring with scopes picks
  // the key by one of them.
  CheckLifetime(AClaimsJson, ARing.MaxTokenSeconds, 0);
  LClaims := ParseJson(AClaimsJson);
  try
    LFound := ARing.SigningKey(LClaims, LKey);
  finally
    LClaims.Free;
  end;
  if not LFound then
    raise EJwtKeyError.Create('JWT key ring: no key signs these claims now');
  CheckLifetime(AClaimsJson, ARing.MaxTokenSeconds, LKey.NotAfter);
  Result := TJwt.SignHS256(AClaimsJson, LKey.Secret, LKey.Kid);
end;

// AClaims' member AName is the string AValue.
function ClaimIs(AClaims: TJsonValue; const AName, AValue: string): Boolean;
var
  LMember: TJsonValue;
begin
  LMember := AClaims.Find(AName);
  Result := (LMember <> nil) and (LMember.Kind = jkString) and (LMember.AsString = AValue);
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
  // A scope's key signs only its scope's tokens: a tenant whose key leaked
  // can't sign for another one.
  if (Result = jrValid) and (LKey.Scope <> '') and (ARing.ScopeClaim <> '') and
    not ClaimIs(AClaims, ARing.ScopeClaim, LKey.Scope) then
  begin
    FreeAndNil(AClaims);
    Result := jrBadSignature;
  end;
end;

class function TJwtKeys.Validate(const ARing: IJwtKeyRing; const AToken: string): Boolean;
var
  LClaims: TJsonValue;
begin
  Result := Decode(ARing, AToken, LClaims) = jrValid;
  LClaims.Free;
end;

end.
