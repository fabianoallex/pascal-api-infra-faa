unit PascalApi.Crypto;

{$I pascalapi.inc}

{ SHA-256, HMAC-SHA256 and Base64url, the same on both compilers: wrappers.

  The code moved to pascal-common-faa 1.17.0 (PascalCommon.Crypto), next to
  its AES-GCM, so the crypto of the *-faa libraries lives in one place; the
  same was done with the UTF-8 decoder in 1.4.0. These Pa* names stay for
  the code that uses them (PascalApi.Jwt, PascalApi.JwtKeys, applications).
  New code can call the Pc* functions directly. The vectors are tested in
  pascal-common-faa's PascalCommon.CryptoTests, and here through the
  wrappers in PascalApi.CryptoTests.

  TSha256Digest is TPcSha256Digest (an alias, the same type). }

interface

uses
  SysUtils,
  PascalCommon.Crypto;

type
  TSha256Digest = TPcSha256Digest;

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

function PaSha256(const AData: TBytes): TSha256Digest;
begin
  Result := PcSha256(AData);
end;

function PaHmacSha256(const AKey, AData: TBytes): TSha256Digest;
begin
  Result := PcHmacSha256(AKey, AData);
end;

function PaDigestToBytes(const ADigest: TSha256Digest): TBytes;
begin
  Result := PcDigestToBytes(ADigest);
end;

function PaBytesToHex(const ABytes: TBytes): string;
begin
  Result := PcBytesToHex(ABytes);
end;

function PaBase64UrlEncode(const ABytes: TBytes): string;
begin
  Result := PcBase64UrlEncode(ABytes);
end;

function PaBase64UrlDecode(const AText: string; out ABytes: TBytes): Boolean;
begin
  Result := PcBase64UrlDecode(AText, ABytes);
end;

function PaSameBytes(const A, B: TBytes): Boolean;
begin
  Result := PcSameBytes(A, B);
end;

end.
