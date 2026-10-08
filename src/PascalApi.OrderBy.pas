unit PascalApi.OrderBy;

{$I pascalapi.inc}

{ Turns a client's ordering expression into an SQL ORDER BY fragment, through
  an allow-list.

  The client sends field names separated by commas, "-name" for descending:
  "name,-state" becomes "NAME ASC, STATE DESC". Only names registered with
  Allow are accepted, so the client never writes SQL; anything else raises
  EOrderByException, which the API answers with HTTP 400.

    class function TCityRepository.OrderBySpec: TOrderBySpec;
    begin
      Result := TOrderBySpec.New
        .Allow('name', 'NAME')
        .Allow('ibgeCode', 'IBGE_CODE')
        .Default('name')
        .AlwaysLast('IBGE_CODE');
    end;

  AlwaysLast adds a fixed tiebreaker at the end of every ORDER BY. Offset
  paging needs one: without a unique set of columns, rows can move between
  pages (see PascalDb.Paging).

  Ported from Common.OrderBy (delphi-api-infra-faa) with the string helpers
  (Split, StartsWith, Substring) replaced by plain routines, which behave the
  same on FPC 3.2.2. Messages are in English. }

interface

uses
  SysUtils;

type
  EOrderByException = class(Exception);

  TOrderDir = (odAsc, odDesc);

  TOrderBySpec = record
  private
    type
      TField = record
        ClientName: string;
        SqlExpr: string;
      end;
      TFixed = record
        SqlExpr: string;
        Dir: TOrderDir;
      end;
    var
      FAllowed: TArray<TField>;
      FDefault: string;
      FTiebreakers: TArray<TFixed>;
    function TryFind(const AName: string; out ASql: string): Boolean;
    function FindClientName(const ASqlExpr: string): string;
    function ParseExpr(const AExpr: string): string;
    function AllowedNames: string;
  public
    class function New: TOrderBySpec; static;

    /// A field the client may order by, and the SQL expression it maps to.
    function Allow(const AClientName, ASqlExpr: string): TOrderBySpec;

    /// The ordering used when the client sends none, in the client's syntax
    /// ('name' or '-name').
    function Default(const AClientExpr: string): TOrderBySpec;

    /// A fixed ordering added at the END of every ORDER BY (tiebreaker),
    /// whatever the client sent.
    function AlwaysLast(const ASqlExpr: string; ADir: TOrderDir = odAsc): TOrderBySpec;

    /// The SQL fragment, without "ORDER BY". An empty AOrderBy uses the
    /// default. Raises EOrderByException for a field not allowed, and
    /// EOrderByException when there is nothing to order by at all (no
    /// default and no tiebreaker).
    function Build(const AOrderBy: string): string;

    /// A description for API documentation: the fields the client may use,
    /// the default and the tiebreaker, by client name (never the SQL).
    function DocHint: string;
  end;

implementation

function DirStr(ADir: TOrderDir): string;
begin
  if ADir = odAsc then
    Result := 'ASC'
  else
    Result := 'DESC';
end;

procedure AppendList(var AList: string; const AItem: string);
begin
  if AList <> '' then
    AList := AList + ', ';
  AList := AList + AItem;
end;

{ TOrderBySpec }

class function TOrderBySpec.New: TOrderBySpec;
begin
  Result.FAllowed := nil;
  Result.FDefault := '';
  Result.FTiebreakers := nil;
end;

function TOrderBySpec.Allow(const AClientName, ASqlExpr: string): TOrderBySpec;
begin
  Result := Self;
  SetLength(Result.FAllowed, Length(Result.FAllowed) + 1);
  Result.FAllowed[High(Result.FAllowed)].ClientName := AClientName;
  Result.FAllowed[High(Result.FAllowed)].SqlExpr := ASqlExpr;
end;

function TOrderBySpec.Default(const AClientExpr: string): TOrderBySpec;
begin
  Result := Self;
  Result.FDefault := AClientExpr;
end;

function TOrderBySpec.AlwaysLast(const ASqlExpr: string; ADir: TOrderDir): TOrderBySpec;
begin
  Result := Self;
  SetLength(Result.FTiebreakers, Length(Result.FTiebreakers) + 1);
  Result.FTiebreakers[High(Result.FTiebreakers)].SqlExpr := ASqlExpr;
  Result.FTiebreakers[High(Result.FTiebreakers)].Dir := ADir;
end;

function TOrderBySpec.TryFind(const AName: string; out ASql: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FAllowed) do
    if SameText(FAllowed[I].ClientName, AName) then
    begin
      ASql := FAllowed[I].SqlExpr;
      Exit(True);
    end;
  ASql := '';
  Result := False;
end;

function TOrderBySpec.FindClientName(const ASqlExpr: string): string;
var
  I: Integer;
begin
  for I := 0 to High(FAllowed) do
    if SameText(FAllowed[I].SqlExpr, ASqlExpr) then
      Exit(FAllowed[I].ClientName);
  Result := ASqlExpr;
end;

function TOrderBySpec.AllowedNames: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(FAllowed) do
    AppendList(Result, FAllowed[I].ClientName);
end;

function TOrderBySpec.ParseExpr(const AExpr: string): string;
var
  LRest, LName, LSql: string;
  LComma: Integer;
  LDir: TOrderDir;
begin
  Result := '';
  LRest := AExpr;
  while LRest <> '' do
  begin
    LComma := Pos(',', LRest);
    if LComma = 0 then
    begin
      LName := Trim(LRest);
      LRest := '';
    end
    else
    begin
      LName := Trim(Copy(LRest, 1, LComma - 1));
      LRest := Copy(LRest, LComma + 1, MaxInt);
    end;
    if LName = '' then
      Continue;

    LDir := odAsc;
    if LName[1] = '-' then
    begin
      LDir := odDesc;
      LName := Trim(Copy(LName, 2, MaxInt));
      if LName = '' then
        Continue;
    end;

    if not TryFind(LName, LSql) then
      raise EOrderByException.CreateFmt('Invalid order field: "%s". Available: %s',
        [LName, AllowedNames]);
    AppendList(Result, LSql + ' ' + DirStr(LDir));
  end;
end;

function TOrderBySpec.Build(const AOrderBy: string): string;
var
  I: Integer;
begin
  if Trim(AOrderBy) <> '' then
    Result := ParseExpr(AOrderBy)
  else if FDefault <> '' then
    Result := ParseExpr(FDefault)
  else
    Result := '';

  for I := 0 to High(FTiebreakers) do
    AppendList(Result, FTiebreakers[I].SqlExpr + ' ' + DirStr(FTiebreakers[I].Dir));

  if Result = '' then
    raise EOrderByException.Create(
      'TOrderBySpec.Build: nothing to order by. Configure Default or AlwaysLast.');
end;

function TOrderBySpec.DocHint: string;
var
  I: Integer;
  LTies, LExample: string;
begin
  LTies := '';
  for I := 0 to High(FTiebreakers) do
    AppendList(LTies, FindClientName(FTiebreakers[I].SqlExpr) + ' ' +
      DirStr(FTiebreakers[I].Dir));

  if FDefault <> '' then
    LExample := FDefault
  else if Length(FAllowed) > 0 then
    LExample := FAllowed[0].ClientName
  else
    LExample := '';

  Result := 'Available fields: ' + AllowedNames + '.';
  if FDefault <> '' then
    Result := Result + ' Default: ' + FDefault + '.';
  if LTies <> '' then
    Result := Result + ' Fixed tiebreaker: ' + LTies + '.';
  Result := Result + ' Use "-field" for descending; separate several with commas.';
  if LExample <> '' then
    Result := Result + ' Example: "' + LExample + '"';
end;

end.
