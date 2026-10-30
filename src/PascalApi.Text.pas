unit PascalApi.Text;

{$I pascalapi.inc}

{ UTF-8 bytes to string and back, the same on both compilers.

  Files this library reads (.env) and writes (logs) are UTF-8. On Delphi,
  string is UTF-16 and TEncoding.UTF8 converts. On FPC, in (*$MODE DELPHI*),
  string is an AnsiString in the process's default code page; unless that
  code page is UTF-8, characters outside it silently become "?" (measured in
  pascal-db-faa, see the skill's rtl-gotchas.md, "Encoding"). So decoding
  non-ASCII bytes when the code page isn't UTF-8 raises ETextEncodingException
  instead of corrupting the text. LCL applications already run in UTF-8;
  console and service programs call SetMultiByteConversionCodePage(CP_UTF8)
  at startup. Since 0.1.1 the decoding is pascal-common-faa's
  PcTryUtf8BytesToString, which pascal-db-faa's PdbUtf8BytesToString uses too.

  Since 0.29.0 the message says which problem it is. Bytes that aren't UTF-8
  (a .env saved as UTF-16 by PowerShell 5.1's ">", or in a legacy code page)
  give "<origin> is not UTF-8 (...): save it as UTF-8" on both compilers;
  the code-page message is only for UTF-8 that FPC's code page can't hold.
  Before, Delphi raised EEncodingError with no file name and FPC loaded the
  UTF-16 file silently, with #0 in every key (pascal-agenda-faa, 2026-10-30).
  pascal-common-faa 1.25.0 validates the bytes and has PcIsValidUtf8. }

interface

uses
  SysUtils;

type
  ETextEncodingException = class(Exception);

/// The text in ABytes (UTF-8, with or without a BOM). AOrigin names where the
/// bytes came from, for the error message. ETextEncodingException when the
/// bytes aren't UTF-8 (a UTF-16 byte order mark is named), and on FPC when
/// they are non-ASCII and the process code page isn't UTF-8.
function PaUtf8BytesToString(const ABytes: TBytes; const AOrigin: string): string;

/// AText as UTF-8 bytes, without a BOM.
function PaStringToUtf8Bytes(const AText: string): TBytes;

/// The MD5 of ABytes as 32 lower-case hex digits (System.Hash on Delphi, the
/// md5 unit on FPC). For correlation ids and fingerprints, not security.
function PaMd5Hex(const ABytes: TBytes): string;

/// The longest prefix of AText that fits in AMaxBytes UTF-8 bytes without
/// cutting a character in half. Measured in UTF-8 bytes on both compilers,
/// so the result is the same text on both (Length counts UTF-16 units on
/// Delphi and bytes on FPC).
function PaUtf8Prefix(const AText: string; AMaxBytes: Integer): string;

/// The number of characters (Unicode code points) in AText, the same on
/// both compilers: Length counts bytes on FPC and UTF-16 units on Delphi, so
/// a rule like "at most 100 characters" needs this instead.
function PaCharCount(const AText: string): Integer;

implementation

uses
  {$IFDEF FPC}
  md5,
  {$ELSE}
  System.Hash,
  {$ENDIF}
  PascalCommon.Utf8,
  PascalCommon.Text;

function PaUtf8BytesToString(const ABytes: TBytes; const AOrigin: string): string;
begin
  // The decoding is pascal-common-faa's (1.4.0); this keeps the exception
  // and the message.
  if PcTryUtf8BytesToString(ABytes, Result) then
    Exit;
  if (Length(ABytes) >= 2) and (((ABytes[0] = $FF) and (ABytes[1] = $FE)) or
    ((ABytes[0] = $FE) and (ABytes[1] = $FF))) then
    raise ETextEncodingException.CreateFmt(
      '%s is not UTF-8 (it starts with a UTF-16 byte order mark): save it as UTF-8', [AOrigin]);
  if not PcIsValidUtf8(ABytes) then
    raise ETextEncodingException.CreateFmt(
      '%s is not UTF-8 (it has bytes that are not valid UTF-8): save it as UTF-8', [AOrigin]);
  raise ETextEncodingException.CreateFmt(
      '%s contains non-ASCII characters, but the process default code page is %d, ' +
      'not UTF-8 (65001): FPC would silently turn characters outside that code page into "?". ' +
      'Call SetMultiByteConversionCodePage(CP_UTF8) at startup (LCL applications already run in UTF-8).',
      [AOrigin, DefaultSystemCodePage]);
end;

function PaStringToUtf8Bytes(const AText: string): TBytes;
{$IFDEF FPC}
var
  LUtf8: UTF8String;
{$ENDIF}
begin
  Result := nil;
  {$IFDEF FPC}
  // The conversion follows the string's own code page: a no-op when it is
  // already UTF-8, a real conversion from any other.
  LUtf8 := UTF8String(AText);
  SetLength(Result, Length(LUtf8));
  if Length(LUtf8) > 0 then
    Move(LUtf8[1], Result[0], Length(LUtf8));
  {$ELSE}
  Result := TEncoding.UTF8.GetBytes(AText);
  {$ENDIF}
end;

function PaMd5Hex(const ABytes: TBytes): string;
var
  {$IFDEF FPC}
  LEmpty: Byte;
  {$ELSE}
  LHash: THashMD5;
  {$ENDIF}
begin
  {$IFDEF FPC}
  if Length(ABytes) = 0 then
  begin
    LEmpty := 0;
    Result := MD5Print(MD5Buffer(LEmpty, 0));
  end
  else
    Result := MD5Print(MD5Buffer(PByte(ABytes)^, Length(ABytes)));
  {$ELSE}
  LHash := THashMD5.Create;
  LHash.Update(ABytes);
  Result := LowerCase(LHash.HashAsString);
  {$ENDIF}
end;

function PaUtf8Prefix(const AText: string; AMaxBytes: Integer): string;
var
  LBytes, LPrefix: TBytes;
  LCut: Integer;
begin
  LBytes := PaStringToUtf8Bytes(AText);
  if Length(LBytes) <= AMaxBytes then
    Exit(AText);
  if AMaxBytes <= 0 then
    Exit('');
  // Back off over continuation bytes (10xxxxxx): the cut lands right before
  // the first byte of a character.
  LCut := AMaxBytes;
  while (LCut > 0) and ((LBytes[LCut] and $C0) = $80) do
    Dec(LCut);
  LPrefix := Copy(LBytes, 0, LCut);
  Result := PaUtf8BytesToString(LPrefix, 'PaUtf8Prefix');
end;

function PaCharCount(const AText: string): Integer;
begin
  // pascal-common-faa's since its 1.21.0 (the validators count with it).
  Result := PcCharCount(AText);
end;

end.
