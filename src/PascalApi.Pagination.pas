unit PascalApi.Pagination;

{$I pascalapi.inc}

{ The HTTP side of offset paging: query-string values in, JSON envelope out.

  The paging itself (TPageRequest, TPageMeta, the SQL clause per database)
  is PascalDb.Paging, in pascal-db-faa. This unit only adds what an API needs
  around it:

    LPage := PageRequestFrom(ADto.Page, ADto.Limit);       // from a Find DTO
    LPage := PageRequestFrom(ParseQueryInt(Req.Query['page']),
      ParseQueryInt(Req.Query['limit']));                  // or straight from the URL
    ...
    Res.Send(PageEnvelopeJson(TPageMeta.Create(LPage, LTotal), LItemsJson));

  Ported from Common.Pagination (delphi-api-infra-faa). Its TPageParams and
  TPageMeta were the same idea as PascalDb.Paging's records, so they are not
  repeated here; the one visible difference is that Offset and Total are
  Int64 there. }

interface

uses
  PascalCommon.Optionals,
  PascalDb.Paging;

/// The value of a query-string parameter as an optional integer: absent when
/// the text is empty or not an integer.
function ParseQueryInt(const AText: string): IOptInteger;

/// The value of a query-string parameter as an optional string: absent when
/// the text is empty.
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
  SysUtils;

function BoolJson(AValue: Boolean): string;
begin
  if AValue then
    Result := 'true'
  else
    Result := 'false';
end;

function ParseQueryInt(const AText: string): IOptInteger;
var
  N: Integer;
begin
  if (AText <> '') and TryStrToInt(AText, N) then
    Result := TOptNullInteger.From(N)
  else
    Result := nil;
end;

function ParseQueryStr(const AText: string): IOptString;
begin
  if AText <> '' then
    Result := TOptNullString.From(AText)
  else
    Result := nil;
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
