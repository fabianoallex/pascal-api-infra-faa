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

    LArgs := TQueryArgs.New;
    if HasSearch then
      LArgs := LArgs.Strings('SEARCH', PdbLikeContains(LKey));
    if AFind.Active.HasValue then
      LArgs := LArgs.Flags('ACTIVE', AFind.Active.Value);
    Result := TTenantPagedQuery.Run<IService>(FScope,
      Filtered(FScope.Factory.SqlLoader['SERVICE.COUNT']),
      Filtered(FScope.Factory.SqlLoader['SERVICE.PAGE']),
      ServiceOrderSpec.Build(AFind.OrderBy.ValueOr('')), APage, LArgs, ReadService);

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
    function Count: Integer;
    /// Binds every value to AQuery.Params (after its SQL is set).
    procedure ApplyTo(const AQuery: IQuery);
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

function TQueryArgs.Count: Integer;
begin
  Result := Length(FItems);
end;

procedure TQueryArgs.ApplyTo(const AQuery: IQuery);
var
  K: Integer;
begin
  for K := 0 to High(FItems) do
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
      TTenantFilter.Prepare(LQuery, AScope, ACountSql)
    else
      LQuery.Sql := ACountSql.SQL;
    AArgs.ApplyTo(LQuery);
    Result.Meta := TPageMeta.Create(ARequest, LQuery.Open.Int64s['TOTAL']);

    LPageSql := APageSql.ReplaceLiteral('ORDER', AOrderBy)
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
