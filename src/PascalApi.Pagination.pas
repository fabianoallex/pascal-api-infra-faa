unit PascalApi.Pagination;

{$I pascalapi.inc}

{ The HTTP side of offset paging: query-string values in, JSON envelope out.

  The paging itself (TPageRequest, TPageMeta, the SQL clause per database)
  is PascalDb.Paging, in pascal-db-faa. This unit only adds what an API needs
  around it:

    LPage := PageRequestFrom(ADto.Page, ADto.Limit);       // from a Find DTO
    LPage := PageRequestFrom(ParseQueryInt('page', Req.Query['page']),
      ParseQueryInt('limit', Req.Query['limit']));         // or straight from the URL
    ...
    Res.Send(PageEnvelopeJson(TPageMeta.Create(LPage, LTotal), LItemsJson));

  ParseQueryInt/ParseQueryStr return an absent optional, never nil (they
  returned nil until 0.1.1, as in the origin, and a caller testing HasValue on
  a missing parameter got an access violation: found by samples/02-db).

  ParseQueryInt takes only an optional '-' and decimal digits, within
  Integer, and raises EValidationException (400) naming the parameter for
  anything else. Until 0.13.0 it used TryStrToInt and returned an absent
  value for text it couldn't read: 'abc' silently became the default, '$3',
  '0x3', '+3' and ' 3' were read as 3, and on FPC 3.2.2 a number past
  Integer wrapped around (page=99999999999 became page 1215752191,
  measured through samples/02-db).

  Ported from Common.Pagination (delphi-api-infra-faa). Its TPageParams and
  TPageMeta were the same idea as PascalDb.Paging's records, so they are not
  repeated here; the one visible difference is that Offset and Total are
  Int64 there. }

interface

uses
  PascalCommon.Optionals,
  PascalDb.Paging;

/// The value of the query-string parameter AName (AText) as an optional
/// integer: absent when AText is empty, never nil. AText must be an optional
/// '-' and decimal digits within Integer; anything else raises
/// EValidationException (400) with TApiMessages.InvalidQueryInteger, naming
/// AName.
function ParseQueryInt(const AName, AText: string): IOptInteger;

/// True with AValue when AText is an optional '-' and decimal digits within
/// Integer; never wraps around (FPC 3.2.2's TryStrToInt does).
function TryParseQueryInteger(const AText: string; out AValue: Integer): Boolean;

/// The value of a query-string parameter as an optional string: absent when
/// the text is empty. Never nil (since 0.2.0).
function ParseQueryStr(const AText: string): IOptString;

/// A page request from optional page and limit (nil or absent use the
/// defaults); out-of-range values are normalized by TPageRequest.Create.
function PageRequestFrom(const APage, ALimit: IOptInteger;
  ADefaultLimit: Integer = PDB_PAGE_DEFAULT_LIMIT;
  AMaxLimit: Integer = PDB_PAGE_MAX_LIMIT): TPageRequest;

/// The standard paged response:
///   {"page":2,"limit":10,"total":25,"totalPages":3,"hasNext":true,
///    "hasPrev":true,"items":<AItemsJson>}
/// AItemsJson is inserted as is: it must be a JSON array.
function PageEnvelopeJson(const AMeta: TPageMeta; const AItemsJson: string): string;

implementation

uses
  SysUtils,
  PascalApi.Http;

function BoolJson(AValue: Boolean): string;
begin
  if AValue then
    Result := 'true'
  else
    Result := 'false';
end;

function TryParseQueryInteger(const AText: string; out AValue: Integer): Boolean;
var
  I, LFirst: Integer;
  LAcc: Int64;
  LNegative: Boolean;
begin
  AValue := 0;
  Result := False;
  LNegative := (AText <> '') and (AText[1] = '-');
  if LNegative then
    LFirst := 2
  else
    LFirst := 1;
  if LFirst > Length(AText) then
    Exit;
  LAcc := 0;
  for I := LFirst to Length(AText) do
  begin
    if (AText[I] < '0') or (AText[I] > '9') then
      Exit;
    LAcc := LAcc * 10 + (Ord(AText[I]) - Ord('0'));
    if LAcc > Int64(High(Integer)) + 1 then // stops long before Int64 could wrap
      Exit;
  end;
  if LNegative then
    LAcc := -LAcc;
  if (LAcc < Low(Integer)) or (LAcc > High(Integer)) then
    Exit;
  AValue := Integer(LAcc);
  Result := True;
end;

function ParseQueryInt(const AName, AText: string): IOptInteger;
var
  N: Integer;
begin
  if AText = '' then
    Result := TOptNullInteger.Undefined
  else if TryParseQueryInteger(AText, N) then
    Result := TOptNullInteger.From(N)
  else
    raise EValidationException.Create(Format(TApiMessages.Current.InvalidQueryInteger, [AName]));
end;

function ParseQueryStr(const AText: string): IOptString;
begin
  if AText <> '' then
    Result := TOptNullString.From(AText)
  else
    Result := TOptNullString.Undefined;
end;

function PageRequestFrom(const APage, ALimit: IOptInteger;
  ADefaultLimit, AMaxLimit: Integer): TPageRequest;
var
  LPage, LLimit: Integer;
begin
  LPage := 1;
  LLimit := 0; // below 1: TPageRequest.Create uses the default limit
  if Assigned(APage) and APage.HasValue then
    LPage := APage.Value;
  if Assigned(ALimit) and ALimit.HasValue then
    LLimit := ALimit.Value;
  Result := TPageRequest.Create(LPage, LLimit, ADefaultLimit, AMaxLimit);
end;

function PageEnvelopeJson(const AMeta: TPageMeta; const AItemsJson: string): string;
begin
  Result := Format(
    '{"page":%d,"limit":%d,"total":%d,"totalPages":%d,"hasNext":%s,"hasPrev":%s,"items":%s}',
    [AMeta.Page, AMeta.Limit, AMeta.Total, AMeta.TotalPages, BoolJson(AMeta.HasNext),
     BoolJson(AMeta.HasPrev), AItemsJson]);
end;

end.
