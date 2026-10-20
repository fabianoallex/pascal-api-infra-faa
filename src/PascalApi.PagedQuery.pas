unit PascalApi.PagedQuery;

{$I pascalapi.inc}

(* A page of rows on a tenant's scope in one call: the count and the page
  through the same filters, the ordering, the dialect's paging clause, the
  rows read into a TPage<T>, in one transaction.

  pascal-agenda-faa, the first application on the library, had five
  repositories with the same 35-line FindPage: acquire, start a
  transaction, prepare the COUNT with the filters' tags, bind the filters,
  read the total, prepare the page with ${ORDER} and ${PAGE}, bind the
  filters again, read every row, commit (rollback on an exception). What
  changed between them was the two SQL names, the tags, the parameters and
  the row reader. With this unit a repository says only that:

    LArgs := TQueryArgs.New
      .OptStrings('SEARCH', LSearchPattern, 'SEARCH')
      .OptFlags('ACTIVE', AFind.Active, 'ACTIVE');
    Result := TTenantPagedQuery.Run<IService>(FScope,
      FScope.Factory.SqlLoader['SERVICE.COUNT'], FScope.Factory.SqlLoader['SERVICE.PAGE'],
      ServiceOrderSpec.Build(AFind.OrderBy.ValueOr('')), APage, LArgs, ReadService);

  - An optional filter (0.22.0): OptStrings, OptFlags... take the IOptXxx as
    it is and the SQL tag whose block holds its condition. Absent, it binds
    nothing and its block goes; present, it binds and the block stays. Run
    processes the tags of both statements (ProcessTags), so the filter is
    written once instead of a HasValue for the tag and an if for the
    parameter (pascal-agenda-faa had both in six repositories). The absent
    ones are kept, not dropped: a block nobody processes loses its markers
    and keeps its content (pascal-db-faa's TSQLResult.SQL), which would
    leave the condition with no value. Processing a tag the SQL doesn't
    have changes nothing, so SQL a caller already filtered is safe.

  - The parameters are a value (TQueryArgs), bound to both statements, not
    a callback: FPC 3.2.2 has no anonymous methods, and a bind method per
    repository would need its own object to carry the filter. The setters
    have IParams' names and return a changed copy, so they chain. A flag
    stored in an integer column goes through Flags (the Integer 1/0);
    Booleans is for the database's Boolean type: PostgreSQL refuses a
    Boolean parameter for an integer column (pascal-db-faa's gotcha 54,
    found by pascal-agenda-faa).
  - The row reader is a plain function (TPageRowFunc<T>), the same function
    a FindById uses: ReadService(AResult): IService.
  - The page SQL marks the order and the clause with ${ORDER} and ${PAGE}
    literals (PascalApi.OrderBy's TOrderBySpec.Build, pascal-db-faa's
    PdbPagingClause), as the library's samples already do. The COUNT reads
    a column named TOTAL.
  - TTenantPagedQuery runs both statements through TTenantFilter.Prepare:
    the ${TENANT} condition and its value, as every repository query on a
    tenant's scope must. TPagedQuery is the same on a factory, for an API
    without tenants (sample 02).
  - The page grows past RecordCount if the driver counts short.

  This comment uses parenthesis-asterisk: it quotes ${TENANT}, whose brace
  would close a brace comment. *)

interface

uses
  PascalCommon.Optionals,
  PascalDb.Interfaces,
  PascalDb.SqlLoader,
  PascalDb.Paging,
  PascalApi.Tenancy;

type
  TQueryArgKind = (qakString, qakInteger, qakInt64, qakBoolean, qakDouble, qakFlag);

  TQueryArg = record
    Name: string;
    Kind: TQueryArgKind;
    S: string;
    I: Int64;
    D: Double;
    /// False for an optional that was absent: not bound, its tag removed.
    Present: Boolean;
    /// The SQL tag whose block this value opens ('' for none).
    Tag: string;
  end;

  /// Named parameter values, bound to a query by ApplyTo. Each setter
  /// returns a changed copy: LArgs := LArgs.Strings('A', 'x').Integers('B', 1).
  TQueryArgs = record
  private
    FItems: array of TQueryArg;
    function Add(const AArg: TQueryArg): TQueryArgs;
  public
    class function New: TQueryArgs; static;
    function Strings(const AName, AValue: string): TQueryArgs;
    function Integers(const AName: string; AValue: Integer): TQueryArgs;
    function Int64s(const AName: string; AValue: Int64): TQueryArgs;
    /// For a column of the database's Boolean type (BOOLEAN, BIT).
    function Booleans(const AName: string; AValue: Boolean): TQueryArgs;
    function Doubles(const AName: string; AValue: Double): TQueryArgs;
    /// For a flag stored in a SMALLINT/INTEGER column: bound as the Integer
    /// 1/0 (IParams.Flags).
    function Flags(const AName: string; AValue: Boolean): TQueryArgs;

    /// An optional filter (IParams' names): AValue absent (or nil) binds
    /// nothing and removes ATag's block; present, it binds and keeps the
    /// block. ATag '' when the value opens no block.
    function OptStrings(const AName: string; const AValue: IOptString;
      const ATag: string = ''): TQueryArgs;
    function OptIntegers(const AName: string; const AValue: IOptInteger;
      const ATag: string = ''): TQueryArgs;
    function OptInt64s(const AName: string; const AValue: IOptInt64;
      const ATag: string = ''): TQueryArgs;
    /// For a column of the database's Boolean type, as Booleans.
    function OptBooleans(const AName: string; const AValue: IOptBoolean;
      const ATag: string = ''): TQueryArgs;
    function OptDoubles(const AName: string; const AValue: IOptDouble;
      const ATag: string = ''): TQueryArgs;
    /// For a flag in a SMALLINT/INTEGER column, as Flags: the Integer 1/0.
    function OptFlags(const AName: string; const AValue: IOptBoolean;
      const ATag: string = ''): TQueryArgs;

    /// Every item, the absent optionals included.
    function Count: Integer;
    /// Binds every present value to AQuery.Params (after its SQL is set).
    procedure ApplyTo(const AQuery: IQuery);
    /// ASql with the block of every item's tag kept (present) or removed
    /// (absent). A tag ASql doesn't have changes nothing.
    function ProcessTags(const ASql: TSQLResult): TSQLResult;
  end;

  /// Reads the current row into a T: the function a repository's FindById
  /// uses too.
  TPageRowFunc<T> = function(const AResult: IQueryResult): T;

  TPagedQuery = class
  protected
    class function Execute<T>(const AFactory: IDBFactory; ATenant: Boolean;
      const AScope: TTenantDataScope; const ACountSql, APageSql: TSQLResult;
      const AOrderBy: string; const ARequest: TPageRequest; const AArgs: TQueryArgs;
      ARead: TPageRowFunc<T>): TPage<T>; static;
  public
    /// The page ARequest of the rows ACountSql counts and APageSql lists, on
    /// AFactory's database. APageSql's ${ORDER} becomes AOrderBy (an ORDER
    /// BY body, from TOrderBySpec.Build) and ${PAGE} the paging clause of the
    /// database. AArgs is bound to both statements; ARead reads each row.
    /// One transaction, rolled back on an exception.
    class function Run<T>(const AFactory: IDBFactory; const ACountSql, APageSql: TSQLResult;
      const AOrderBy: string; const ARequest: TPageRequest; const AArgs: TQueryArgs;
      ARead: TPageRowFunc<T>): TPage<T>; static;
  end;

  TTenantPagedQuery = class(TPagedQuery)
  public
    /// TPagedQuery.Run on AScope: both statements through
    /// TTenantFilter.Prepare (the ${TENANT} condition and its value).
    class function Run<T>(const AScope: TTenantDataScope; const ACountSql, APageSql: TSQLResult;
      const AOrderBy: string; const ARequest: TPageRequest; const AArgs: TQueryArgs;
      ARead: TPageRowFunc<T>): TPage<T>; static;
  end;

implementation

uses
  SysUtils;

{ TQueryArgs }

class function TQueryArgs.New: TQueryArgs;
begin
  Result.FItems := nil;
end;

function TQueryArgs.Add(const AArg: TQueryArg): TQueryArgs;
begin
  // A copy of the array: the record this was called on keeps its own.
  Result.FItems := Copy(FItems, 0, Length(FItems));
  SetLength(Result.FItems, Length(Result.FItems) + 1);
  Result.FItems[High(Result.FItems)] := AArg;
end;

function NewArg(const AName: string; AKind: TQueryArgKind): TQueryArg;
begin
  Result.Name := AName;
  Result.Kind := AKind;
  Result.S := '';
  Result.I := 0;
  Result.D := 0;
  Result.Present := True;
  Result.Tag := '';
end;

// An optional's item: present when AHasValue, with its tag.
function NewOptArg(const AName: string; AKind: TQueryArgKind; AHasValue: Boolean;
  const ATag: string): TQueryArg;
begin
  Result := NewArg(AName, AKind);
  Result.Present := AHasValue;
  Result.Tag := ATag;
end;

function TQueryArgs.Strings(const AName, AValue: string): TQueryArgs;
var
  LArg: TQueryArg;
begin
  LArg := NewArg(AName, qakString);
  LArg.S := AValue;
  Result := Add(LArg);
end;

function TQueryArgs.Integers(const AName: string; AValue: Integer): TQueryArgs;
var
  LArg: TQueryArg;
begin
  LArg := NewArg(AName, qakInteger);
  LArg.I := AValue;
  Result := Add(LArg);
end;

function TQueryArgs.Int64s(const AName: string; AValue: Int64): TQueryArgs;
var
  LArg: TQueryArg;
begin
  LArg := NewArg(AName, qakInt64);
  LArg.I := AValue;
  Result := Add(LArg);
end;

function TQueryArgs.Booleans(const AName: string; AValue: Boolean): TQueryArgs;
var
  LArg: TQueryArg;
begin
  LArg := NewArg(AName, qakBoolean);
  LArg.I := Ord(AValue);
  Result := Add(LArg);
end;

function TQueryArgs.Doubles(const AName: string; AValue: Double): TQueryArgs;
var
  LArg: TQueryArg;
begin
  LArg := NewArg(AName, qakDouble);
  LArg.D := AValue;
  Result := Add(LArg);
end;

function TQueryArgs.Flags(const AName: string; AValue: Boolean): TQueryArgs;
var
  LArg: TQueryArg;
begin
  LArg := NewArg(AName, qakFlag);
  LArg.I := Ord(AValue);
  Result := Add(LArg);
end;

// A nil optional counts as absent (TOptionals.Safe's rule), as IParams'
// Opt setters treat it.

function TQueryArgs.OptStrings(const AName: string; const AValue: IOptString;
  const ATag: string): TQueryArgs;
var
  LArg: TQueryArg;
begin
  LArg := NewOptArg(AName, qakString, Assigned(AValue) and AValue.HasValue, ATag);
  if LArg.Present then
    LArg.S := AValue.Value;
  Result := Add(LArg);
end;

function TQueryArgs.OptIntegers(const AName: string; const AValue: IOptInteger;
  const ATag: string): TQueryArgs;
var
  LArg: TQueryArg;
begin
  LArg := NewOptArg(AName, qakInteger, Assigned(AValue) and AValue.HasValue, ATag);
  if LArg.Present then
    LArg.I := AValue.Value;
  Result := Add(LArg);
end;

function TQueryArgs.OptInt64s(const AName: string; const AValue: IOptInt64;
  const ATag: string): TQueryArgs;
var
  LArg: TQueryArg;
begin
  LArg := NewOptArg(AName, qakInt64, Assigned(AValue) and AValue.HasValue, ATag);
  if LArg.Present then
    LArg.I := AValue.Value;
  Result := Add(LArg);
end;

function TQueryArgs.OptBooleans(const AName: string; const AValue: IOptBoolean;
  const ATag: string): TQueryArgs;
var
  LArg: TQueryArg;
begin
  LArg := NewOptArg(AName, qakBoolean, Assigned(AValue) and AValue.HasValue, ATag);
  if LArg.Present then
    LArg.I := Ord(AValue.Value);
  Result := Add(LArg);
end;

function TQueryArgs.OptDoubles(const AName: string; const AValue: IOptDouble;
  const ATag: string): TQueryArgs;
var
  LArg: TQueryArg;
begin
  LArg := NewOptArg(AName, qakDouble, Assigned(AValue) and AValue.HasValue, ATag);
  if LArg.Present then
    LArg.D := AValue.Value;
  Result := Add(LArg);
end;

function TQueryArgs.OptFlags(const AName: string; const AValue: IOptBoolean;
  const ATag: string): TQueryArgs;
var
  LArg: TQueryArg;
begin
  LArg := NewOptArg(AName, qakFlag, Assigned(AValue) and AValue.HasValue, ATag);
  if LArg.Present then
    LArg.I := Ord(AValue.Value);
  Result := Add(LArg);
end;

function TQueryArgs.Count: Integer;
begin
  Result := Length(FItems);
end;

function TQueryArgs.ProcessTags(const ASql: TSQLResult): TSQLResult;
var
  K: Integer;
begin
  Result := ASql;
  for K := 0 to High(FItems) do
    if FItems[K].Tag <> '' then
      Result := Result.ProcessTag(FItems[K].Tag, FItems[K].Present);
end;

procedure TQueryArgs.ApplyTo(const AQuery: IQuery);
var
  K: Integer;
begin
  for K := 0 to High(FItems) do
    if FItems[K].Present then
      case FItems[K].Kind of
        qakString: AQuery.Params.Strings[FItems[K].Name] := FItems[K].S;
        qakInteger: AQuery.Params.Integers[FItems[K].Name] := Integer(FItems[K].I);
        qakInt64: AQuery.Params.Int64s[FItems[K].Name] := FItems[K].I;
        qakBoolean: AQuery.Params.Booleans[FItems[K].Name] := FItems[K].I <> 0;
        qakDouble: AQuery.Params.Doubles[FItems[K].Name] := FItems[K].D;
        qakFlag: AQuery.Params.Flags[FItems[K].Name] := FItems[K].I <> 0;
      end;
end;

{ TPagedQuery }

class function TPagedQuery.Execute<T>(const AFactory: IDBFactory; ATenant: Boolean;
  const AScope: TTenantDataScope; const ACountSql, APageSql: TSQLResult;
  const AOrderBy: string; const ARequest: TPageRequest; const AArgs: TQueryArgs;
  ARead: TPageRowFunc<T>): TPage<T>;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
  LPageSql: TSQLResult;
  LCount: Integer;
begin
  Result.Items := nil;
  LTx := AFactory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    if ATenant then
      TTenantFilter.Prepare(LQuery, AScope, AArgs.ProcessTags(ACountSql))
    else
      LQuery.Sql := AArgs.ProcessTags(ACountSql).SQL;
    AArgs.ApplyTo(LQuery);
    Result.Meta := TPageMeta.Create(ARequest, LQuery.Open.Int64s['TOTAL']);

    LPageSql := AArgs.ProcessTags(APageSql).ReplaceLiteral('ORDER', AOrderBy)
      .ReplaceLiteral('PAGE', PdbPagingClause(LTx, ARequest));
    if ATenant then
      TTenantFilter.Prepare(LQuery, AScope, LPageSql)
    else
      LQuery.Sql := LPageSql.SQL;
    AArgs.ApplyTo(LQuery);
    LResult := LQuery.Open;
    SetLength(Result.Items, LResult.RecordCount);
    LCount := 0;
    while not LResult.Eof do
    begin
      if LCount = Length(Result.Items) then
        SetLength(Result.Items, LCount + 16);
      Result.Items[LCount] := ARead(LResult);
      Inc(LCount);
      LResult.Next;
    end;
    SetLength(Result.Items, LCount);
    LResult := nil;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
end;

class function TPagedQuery.Run<T>(const AFactory: IDBFactory;
  const ACountSql, APageSql: TSQLResult; const AOrderBy: string;
  const ARequest: TPageRequest; const AArgs: TQueryArgs; ARead: TPageRowFunc<T>): TPage<T>;
var
  LNoScope: TTenantDataScope;
begin
  LNoScope.Factory := nil;
  LNoScope.Discriminator := '';
  Result := Execute<T>(AFactory, False, LNoScope, ACountSql, APageSql, AOrderBy, ARequest,
    AArgs, ARead);
end;

{ TTenantPagedQuery }

class function TTenantPagedQuery.Run<T>(const AScope: TTenantDataScope;
  const ACountSql, APageSql: TSQLResult; const AOrderBy: string;
  const ARequest: TPageRequest; const AArgs: TQueryArgs; ARead: TPageRowFunc<T>): TPage<T>;
begin
  Result := Execute<T>(AScope.Factory, True, AScope, ACountSql, APageSql, AOrderBy, ARequest,
    AArgs, ARead);
end;

end.
