unit PascalApi.Crypto;

{$I pascalapi.inc}

{ SHA-256, HMAC-SHA256 and Base64url, the same on both compilers.

  They exist for JWT (HS256). FPC 3.2.2's hash package has HMAC only for MD5
  and SHA-1 and no SHA-256 at all (measured in C:\lazarus4.0, 2026-10-08:
  packages/hash/src/hmac.pp), and Delphi's System.Hash/System.NetEncoding
  don't exist on FPC. Small enough to own: SHA-256 follows FIPS 180-4, HMAC
  RFC 2104, Base64url RFC 4648 section 5 without padding (as JWT uses it).
  Checked against the NIST/RFC 4231/RFC 4648 vectors in
  PascalApi.CryptoTests.

  Arithmetic is modulo 2^32 on purpose: overflow and range checks are off in
  this unit (the Delphi test project turns them on in Debug), and every
  intermediate is stored in a Cardinal, so FPC's 64-bit promotion of
  expressions can't leak extra bits. }

{$Q-}
{$R-}

interface

uses
  SysUtils;

type
  TSha256Digest = array[0..31] of Byte;

function PaSha256(const AData: TBytes): TSha256Digest;
function PaHmacSha256(const AKey, AData: TBytes): TSha256Digest;
function PaDigestToBytes(const ADigest: TSha256Digest): TBytes;
function PaBytesToHex(const ABytes: TBytes): string;

/// Base64url without padding.
function PaBase64UrlEncode(const ABytes: TBytes): string;
/// Accepts input with or without padding. Returns False on any character
/// outside the Base64url alphabet or an impossible length.
function PaBase64UrlDecode(const AText: string; out ABytes: TBytes): Boolean;

/// Compares in time independent of where the first difference is (for
/// signatures).
function PaSameBytes(const A, B: TBytes): Boolean;

implementation

const
  K: array[0..63] of Cardinal = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
    $d807aa98, $12835b01, $243185be, $550c7dc3, $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
    $e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147, $06ca6351, $14292967,
    $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13, $650a7354, $766a0abb, $81c2c92e, $92722c85,
    $a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
    $748f82ee, $78a5636f, $84c87814, $8cc70208, $90befffa, $a4506ceb, $bef9a3f7, $c67178f2);

  BASE64URL_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

function Ror(AValue: Cardinal; ABits: Integer): Cardinal; inline;
var
  LLow, LHigh: Cardinal;
begin
  LLow := AValue shr ABits;
  LHigh := AValue shl (32 - ABits);
  Result := LLow or LHigh;
end;

procedure Compress(var AState: array of Cardinal; const ABlock: PByte);
var
  W: array[0..63] of Cardinal;
  A, B, C, D, E, F, G, H, T1, T2, S0, S1: Cardinal;
  I: Integer;
begin
  for I := 0 to 15 do
    W[I] := (Cardinal(ABlock[I * 4]) shl 24) or (Cardinal(ABlock[I * 4 + 1]) shl 16) or
      (Cardinal(ABlock[I * 4 + 2]) shl 8) or Cardinal(ABlock[I * 4 + 3]);
  for I := 16 to 63 do
  begin
    S0 := Ror(W[I - 15], 7) xor Ror(W[I - 15], 18) xor (W[I - 15] shr 3);
    S1 := Ror(W[I - 2], 17) xor Ror(W[I - 2], 19) xor (W[I - 2] shr 10);
    T1 := W[I - 16] + S0;
    T1 := T1 + W[I - 7];
    W[I] := T1 + S1;
  end;

  A := AState[0]; B := AState[1]; C := AState[2]; D := AState[3];
  E := AState[4]; F := AState[5]; G := AState[6]; H := AState[7];
  for I := 0 to 63 do
  begin
    S1 := Ror(E, 6) xor Ror(E, 11) xor Ror(E, 25);
    T1 := H + S1;
    T1 := T1 + ((E and F) xor ((not E) and G));
    T1 := T1 + K[I];
    T1 := T1 + W[I];
    S0 := Ror(A, 2) xor Ror(A, 13) xor Ror(A, 22);
    T2 := S0 + ((A and B) xor (A and C) xor (B and C));
    H := G; G := F; F := E;
    E := D + T1;
    D := C; C := B; B := A;
    A := T1 + T2;
  end;
  AState[0] := AState[0] + A; AState[1] := AState[1] + B;
  AState[2] := AState[2] + C; AState[3] := AState[3] + D;
  AState[4] := AState[4] + E; AState[5] := AState[5] + F;
  AState[6] := AState[6] + G; AState[7] := AState[7] + H;
end;

function PaSha256(const AData: TBytes): TSha256Digest;
var
  LState: array[0..7] of Cardinal;
  LBlock: array[0..63] of Byte;
  LLen, LOffset, LRest, I: Integer;
  LBits: UInt64;
begin
  LState[0] := $6a09e667; LState[1] := $bb67ae85; LState[2] := $3c6ef372; LState[3] := $a54ff53a;
  LState[4] := $510e527f; LState[5] := $9b05688c; LState[6] := $1f83d9ab; LState[7] := $5be0cd19;

  LLen := Length(AData);
  LOffset := 0;
  while LLen - LOffset >= 64 do
  begin
    Compress(LState, @AData[LOffset]);
    Inc(LOffset, 64);
  end;

  // Padding: 0x80, zeros, then the length in bits (big-endian, 64 bits).
  LRest := LLen - LOffset;
  FillChar(LBlock, SizeOf(LBlock), 0);
  if LRest > 0 then
    Move(AData[LOffset], LBlock[0], LRest);
  LBlock[LRest] := $80;
  if LRest >= 56 then
  begin
    Compress(LState, @LBlock[0]);
    FillChar(LBlock, SizeOf(LBlock), 0);
  end;
  LBits := UInt64(LLen) * 8;
  for I := 0 to 7 do
    LBlock[63 - I] := Byte(LBits shr (I * 8));
  Compress(LState, @LBlock[0]);

  for I := 0 to 7 do
  begin
    Result[I * 4] := Byte(LState[I] shr 24);
    Result[I * 4 + 1] := Byte(LState[I] shr 16);
    Result[I * 4 + 2] := Byte(LState[I] shr 8);
    Result[I * 4 + 3] := Byte(LState[I]);
  end;
end;

function PaDigestToBytes(const ADigest: TSha256Digest): TBytes;
begin
  Result := nil;
  SetLength(Result, SizeOf(ADigest));
  Move(ADigest[0], Result[0], SizeOf(ADigest));
end;

function PaHmacSha256(const AKey, AData: TBytes): TSha256Digest;
const
  BLOCK = 64;
var
  LKey, LInner, LOuter: TBytes;
  I: Integer;
begin
  if Length(AKey) > BLOCK then
    LKey := PaDigestToBytes(PaSha256(AKey))
  else
    LKey := Copy(AKey, 0, Length(AKey));
  SetLength(LKey, BLOCK); // pads with zeros

  LInner := nil;
  SetLength(LInner, BLOCK + Length(AData));
  for I := 0 to BLOCK - 1 do
    LInner[I] := LKey[I] xor $36;
  if Length(AData) > 0 then
    Move(AData[0], LInner[BLOCK], Length(AData));

  LOuter := nil;
  SetLength(LOuter, BLOCK + SizeOf(TSha256Digest));
  for I := 0 to BLOCK - 1 do
    LOuter[I] := LKey[I] xor $5c;
  Result := PaSha256(LInner);
  Move(Result[0], LOuter[BLOCK], SizeOf(TSha256Digest));
  Result := PaSha256(LOuter);
end;

function PaBytesToHex(const ABytes: TBytes): string;
const
  HEX = '0123456789abcdef';
var
  I: Integer;
begin
  Result := '';
  SetLength(Result, Length(ABytes) * 2);
  for I := 0 to High(ABytes) do
  begin
    Result[I * 2 + 1] := HEX[(ABytes[I] shr 4) + 1];
    Result[I * 2 + 2] := HEX[(ABytes[I] and $F) + 1];
  end;
end;

function PaBase64UrlEncode(const ABytes: TBytes): string;
var
  I, LLen: Integer;
  LGroup: Cardinal;
begin
  Result := '';
  LLen := Length(ABytes);
  I := 0;
  while I + 2 < LLen do
  begin
    LGroup := (Cardinal(ABytes[I]) shl 16) or (Cardinal(ABytes[I + 1]) shl 8) or ABytes[I + 2];
    Result := Result + BASE64URL_CHARS[(LGroup shr 18) and 63 + 1] +
      BASE64URL_CHARS[(LGroup shr 12) and 63 + 1] + BASE64URL_CHARS[(LGroup shr 6) and 63 + 1] +
      BASE64URL_CHARS[LGroup and 63 + 1];
    Inc(I, 3);
  end;
  case LLen - I of
    1:
      begin
        LGroup := Cardinal(ABytes[I]) shl 16;
        Result := Result + BASE64URL_CHARS[(LGroup shr 18) and 63 + 1] +
          BASE64URL_CHARS[(LGroup shr 12) and 63 + 1];
      end;
    2:
      begin
        LGroup := (Cardinal(ABytes[I]) shl 16) or (Cardinal(ABytes[I + 1]) shl 8);
        Result := Result + BASE64URL_CHARS[(LGroup shr 18) and 63 + 1] +
          BASE64URL_CHARS[(LGroup shr 12) and 63 + 1] + BASE64URL_CHARS[(LGroup shr 6) and 63 + 1];
      end;
  end;
end;

function Base64UrlValue(C: Char): Integer;
begin
  case C of
    'A'..'Z': Result := Ord(C) - Ord('A');
    'a'..'z': Result := Ord(C) - Ord('a') + 26;
    '0'..'9': Result := Ord(C) - Ord('0') + 52;
    '-': Result := 62;
    '_': Result := 63;
  else
    Result := -1;
  end;
end;

function PaBase64UrlDecode(const AText: string; out ABytes: TBytes): Boolean;
var
  LLen, I, LCount, LValue: Integer;
  LAcc: Cardinal;
  LBits: Integer;
begin
  ABytes := nil;
  LLen := Length(AText);
  while (LLen > 0) and (AText[LLen] = '=') do
    Dec(LLen);
  // 4n + 1 characters can't come from whole bytes.
  if LLen mod 4 = 1 then
    Exit(False);
  SetLength(ABytes, (LLen * 6) div 8);
  LAcc := 0;
  LBits := 0;
  LCount := 0;
  for I := 1 to LLen do
  begin
    LValue := Base64UrlValue(AText[I]);
    if LValue < 0 then
    begin
      ABytes := nil;
      Exit(False);
    end;
    LAcc := ((LAcc shl 6) or Cardinal(LValue)) and $FFFFFF;
    Inc(LBits, 6);
    if LBits >= 8 then
    begin
      Dec(LBits, 8);
      ABytes[LCount] := Byte(LAcc shr LBits);
      Inc(LCount);
    end;
  end;
  Result := True;
end;

function PaSameBytes(const A, B: TBytes): Boolean;
var
  I: Integer;
  LDiff: Byte;
begin
  if Length(A) <> Length(B) then
    Exit(False);
  LDiff := 0;
  for I := 0 to High(A) do
    LDiff := LDiff or (A[I] xor B[I]);
  Result := LDiff = 0;
end;

end.
