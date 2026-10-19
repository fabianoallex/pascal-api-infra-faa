unit DbApiSample.Cities;

{ The cities of sample 02 in a real database (SQLite through pascal-db-faa):
  DTOs, migrations, and a repository that pages and orders in SQL.

  Everything that reaches the SQL text from the client goes through an
  allow-list or a parameter: the ORDER BY comes from TOrderBySpec.Build, the
  page clause from the connection's dialect (PdbPagingClause), and the
  filter is a :STATE parameter in a tagged block, kept only when the
  filter came. A duplicate code makes the database raise a constraint
  violation, which the error handler answers with 409; nothing here checks
  for duplicates first.

  The SQL is registered in code (TMemorySqlSource, directory SQLITE) to keep
  the sample in two files; an application would usually embed .sql files as
  resources (pascal-db-faa's tools/build_sql_res.py). }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  PascalCommon.Optionals,
  PascalDb.Interfaces,
  PascalDb.Paging,
  PascalDb.SqlSources,
  PascalDb.Migrations,
  PascalApi.OrderBy,
  PascalApi.Dto;

type
  ICityInsert = interface(IInsertDTOBase)
    ['{0AFFB926-76E8-45B7-87CB-C5E844FAF997}']
    function GetCode: string;
    function GetName: string;
    function GetState: string;
    function GetPopulation: IOptInteger;
    property Code: string read GetCode;
    property Name: string read GetName;
    property State: string read GetState;
    property Population: IOptInteger read GetPopulation;
  end;

  /// The query string of GET /cities: page, limit, orderBy and search from
  /// the base, plus the state filter.
  ICityFind = interface(IFindPaginationDTOBase)
    ['{68703148-01FA-4EC6-A0A5-529487B0AC1F}']
    function GetState: IOptString;
    property State: IOptString read GetState;
  end;

  ICity = interface(IResponseDTOBase)
    ['{2AD7DFDC-6A1C-4F82-8E47-3E646F5971DD}']
    function GetCode: string;
    function GetName: string;
    function GetState: string;
    function GetPopulation: INullInteger;
    property Code: string read GetCode;
    property Name: string read GetName;
    property State: string read GetState;
    property Population: INullInteger read GetPopulation;
  end;

  /// PATCH /cities/:code: every member may be absent (left as it is). Name
  /// and state may not be null (the columns are NOT NULL); population may
  /// (null clears it).
  ICityPatch = interface(IUpdateDTOBase)
    ['{D69D9227-473F-495A-95B3-C505E3E4BB25}']
    function GetName: IOptString;
    function GetState: IOptString;
    function GetPopulation: IOptNullInteger;
    property Name: IOptString read GetName;
    property State: IOptString read GetState;
    property Population: IOptNullInteger read GetPopulation;
  end;

{$M+}
  TCityInsert = class(TInsertDTOBase, ICityInsert)
  private
    FCode, FName, FState: string;
    FPopulation: IOptInteger;
  public
    function GetCode: string;
    function GetName: string;
    function GetState: string;
    function GetPopulation: IOptInteger;
  published
    property Code: string read FCode write FCode;
    property Name: string read FName write FName;
    property State: string read FState write FState;
    property Population: IOptInteger read FPopulation write FPopulation;
  end;

  TCityFind = class(TFindPaginationDTOBase, ICityFind)
  private
    FState: IOptString;
  public
    function GetState: IOptString;
  published
    property State: IOptString read FState write FState;
  end;

  TCityPatch = class(TUpdateDTOBase, ICityPatch)
  private
    FName, FState: IOptString;
    FPopulation: IOptNullInteger;
  public
    function GetName: IOptString;
    function GetState: IOptString;
    function GetPopulation: IOptNullInteger;
  published
    property Name: IOptString read FName write FName;
    property State: IOptString read FState write FState;
    property Population: IOptNullInteger read FPopulation write FPopulation;
  end;

  TCity = class(TResponseDTOBase, ICity)
  private
    FCode, FName, FState: string;
    FPopulation: INullInteger;
  public
    function GetCode: string;
    function GetName: string;
    function GetState: string;
    function GetPopulation: INullInteger;
  published
    property Code: string read FCode write FCode;
    property Name: string read FName write FName;
    property State: string read FState write FState;
    property Population: INullInteger read FPopulation write FPopulation;
  end;
{$M-}

  // TArray<ICity>, not "array of ICity": the same type as TPage<ICity>.Items
  // (two "array of" declarations are incompatible on Delphi, E2008), and a
  // name for Serialize<> (FPC reads ">>" in Serialize<TArray<ICity>> as shr).
  TCityArray = TArray<ICity>;

  TCityRepository = class
  private
    FFactory: IDBFactory;
  public
    constructor Create(const AFactory: IDBFactory);
    /// A page of cities, optionally of one state, ordered by AOrderBy (the
    /// client's syntax, see TOrderBySpec). EOrderByException for a field not
    /// allowed.
    function FindPage(const AState: IOptString; const AOrderBy: string;
      const APage: TPageRequest): TPage<ICity>;
    /// ENotFoundException when there is none.
    function FindByCode(const ACode: string): ICity;
    /// EValidationException for invalid data; the database's
    /// EConstraintViolationException for a code that already exists.
    function Insert(const ACity: ICityInsert): ICity;
    /// Changes only the members that came; an empty patch changes nothing.
    /// ENotFoundException when there is none, EValidationException for
    /// invalid data.
    function Update(const ACode: string; const APatch: ICityPatch): ICity;
    /// ENotFoundException when there is none.
    procedure Delete(const ACode: string);
  end;

/// The ordering the client may ask for (also the orderBy parameter's
/// documentation, through DocHint).
function CityOrderSpec: TOrderBySpec;

/// Every SQL of the sample, under the SQLITE directory.
function CitySqlSource: ISqlSource;

/// The migrations: SCHEMA_MIGRATIONS, CITIES, seed rows.
function CityMigrations: TArray<TMigrationItem>;

implementation

uses
  SysUtils,
  TypInfo,
  PascalJsonMapper.Mapper,
  PascalApi.OpenApi,
  PascalApi.Http,
  PascalApi.PagedQuery,
  PascalApi.Text,
  PascalCommon.Validators,
  DbApiSample.Normalizers,
  DbApiSample.Validators;

const
  DIR = 'SQLITE';

function CitySqlSource: ISqlSource;
var
  LSource: TMemorySqlSource;
begin
  LSource := TMemorySqlSource.Create;
  Result := LSource;
  LSource
    .Add(DIR, 'MIG.0001',
      'CREATE TABLE IF NOT EXISTS SCHEMA_MIGRATIONS (VERSION INTEGER NOT NULL, ' +
      'APPLIED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL, ' +
      'CONSTRAINT PK_SCHEMA_MIGRATIONS PRIMARY KEY (VERSION));')
    .Add(DIR, 'MIG.0002',
      'CREATE TABLE CITIES (CODE VARCHAR(7) NOT NULL PRIMARY KEY, NAME VARCHAR(100) NOT NULL, ' +
      'STATE VARCHAR(2) NOT NULL, POPULATION INTEGER);')
    .Add(DIR, 'MIG.0003',
      'INSERT INTO CITIES VALUES (''3550308'', ''São Paulo'', ''SP'', 11451999);' + sLineBreak +
      'INSERT INTO CITIES VALUES (''4314902'', ''Porto Alegre'', ''RS'', 1332845);' + sLineBreak +
      'INSERT INTO CITIES VALUES (''4106902'', ''Curitiba'', ''PR'', 1773718);' + sLineBreak +
      'INSERT INTO CITIES VALUES (''1501402'', ''Belém'', ''PA'', 1303403);' + sLineBreak +
      'INSERT INTO CITIES VALUES (''3509502'', ''Campinas'', ''SP'', 1139047);' + sLineBreak +
      'INSERT INTO CITIES VALUES (''4205407'', ''Florianópolis'', ''SC'', NULL);')
    // The [STATE] block is kept (without its markers) only when the filter
    // came: ProcessTag('STATE', HasValue).
    .Add(DIR, 'CITY.COUNT',
      'SELECT COUNT(*) AS TOTAL FROM CITIES WHERE 1 = 1 [STATE {] AND STATE = :STATE [} STATE]')
    .Add(DIR, 'CITY.PAGE',
      'SELECT CODE, NAME, STATE, POPULATION FROM CITIES WHERE 1 = 1 ' +
      '[STATE {] AND STATE = :STATE [} STATE] ORDER BY ${ORDER} ${PAGE}')
    .Add(DIR, 'CITY.BY_CODE', 'SELECT CODE, NAME, STATE, POPULATION FROM CITIES WHERE CODE = :CODE')
    // The POPULATION blocks are kept only when it came; without them the
    // column takes its default, NULL.
    .Add(DIR, 'CITY.INSERT',
      'INSERT INTO CITIES (CODE, NAME, STATE [POPULATION {], POPULATION [} POPULATION]) ' +
      'VALUES (:CODE, :NAME, :STATE [POPULATION {], :POPULATION [} POPULATION])')
    // One block per member a PATCH may carry, kept only when it came.
    .Add(DIR, 'CITY.UPDATE',
      'UPDATE CITIES SET CODE = CODE [NAME {], NAME = :NAME [} NAME] ' +
      '[STATE {], STATE = :STATE [} STATE] [POPULATION {], POPULATION = :POPULATION [} POPULATION] ' +
      'WHERE CODE = :CODE')
    .Add(DIR, 'CITY.DELETE', 'DELETE FROM CITIES WHERE CODE = :CODE');
end;

function CityMigrations: TArray<TMigrationItem>;

  function Item(AVersion: Integer; const AName: string; AIsDDL: Boolean): TMigrationItem;
  begin
    Result.Version := AVersion;
    Result.ScriptName := AName;
    Result.ParamReplaceProc := nil;
    Result.Terminator := ';';
    Result.IsDDL := AIsDDL;
  end;

begin
  Result := nil;
  SetLength(Result, 3);
  Result[0] := Item(1, 'MIG.0001', True);
  Result[1] := Item(2, 'MIG.0002', True);
  Result[2] := Item(3, 'MIG.0003', False);
end;

function CityOrderSpec: TOrderBySpec;
begin
  Result := TOrderBySpec.New
    .Allow('name', 'NAME')
    .Allow('state', 'STATE')
    .Allow('population', 'POPULATION')
    .Default('name')
    .AlwaysLast('CODE');
end;

{ TCityInsert }

function TCityInsert.GetCode: string;
begin
  Result := FCode;
end;

function TCityInsert.GetName: string;
begin
  Result := FName;
end;

function TCityInsert.GetState: string;
begin
  Result := FState;
end;

function TCityInsert.GetPopulation: IOptInteger;
begin
  Result := TOptionals.Safe(FPopulation);
end;

{ TCityPatch }

function TCityPatch.GetName: IOptString;
begin
  Result := TOptionals.Safe(FName);
end;

function TCityPatch.GetState: IOptString;
begin
  Result := TOptionals.Safe(FState);
end;

function TCityPatch.GetPopulation: IOptNullInteger;
begin
  Result := TOptionals.Safe(FPopulation);
end;

{ TCityFind }

function TCityFind.GetState: IOptString;
begin
  Result := TOptionals.Safe(FState);
end;

{ TCity }

function TCity.GetCode: string;
begin
  Result := FCode;
end;

function TCity.GetName: string;
begin
  Result := FName;
end;

function TCity.GetState: string;
begin
  Result := FState;
end;

function TCity.GetPopulation: INullInteger;
begin
  Result := TOptionals.Safe(FPopulation);
end;

{ TCityRepository }

constructor TCityRepository.Create(const AFactory: IDBFactory);
begin
  inherited Create;
  FFactory := AFactory;
end;

// A plain function, not a method: TPagedQuery's row reader (TPageRowFunc)
// and FindByCode share it.
function ReadCity(const AResult: IQueryResult): ICity;
var
  LCity: TCity;
begin
  LCity := TCity.Create;
  Result := LCity;
  LCity.Code := AResult.Strings['CODE'];
  LCity.Name := AResult.Strings['NAME'];
  LCity.State := AResult.Strings['STATE'];
  LCity.Population := AResult.NullableIntegers['POPULATION'];
end;

// The count and the page through the same filter (PascalApi.PagedQuery,
// 0.19.0): the STATE block kept in both, its value bound to both.
function TCityRepository.FindPage(const AState: IOptString; const AOrderBy: string;
  const APage: TPageRequest): TPage<ICity>;
var
  LOrder: string;
  LArgs: TQueryArgs;
begin
  LOrder := CityOrderSpec.Build(AOrderBy); // before touching the database: 400 if invalid
  LArgs := TQueryArgs.New;
  if AState.HasValue then
    LArgs := LArgs.Strings('STATE', UpperCase(AState.Value));
  Result := TPagedQuery.Run<ICity>(FFactory,
    FFactory.SqlLoader['CITY.COUNT'].ProcessTag('STATE', AState.HasValue),
    FFactory.SqlLoader['CITY.PAGE'].ProcessTag('STATE', AState.HasValue),
    LOrder, APage, LArgs, ReadCity);
end;

function TCityRepository.FindByCode(const ACode: string): ICity;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
begin
  Result := nil;
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader['CITY.BY_CODE'].SQL;
    LQuery.Params.Strings['CODE'] := ACode;
    LResult := LQuery.Open;
    if not LResult.Eof then
      Result := ReadCity(LResult);
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
  if Result = nil then
    raise ENotFoundException.Create(Format('City %s not found.', [ACode]));
end;

function TCityRepository.Insert(const ACity: ICityInsert): ICity;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LCode, LName: string;
  LCheck: TPcValidation;
begin
  // The limits the OpenAPI document declares (TApiSchema.Describe below)
  // were enforced at the edge (THorseBody.Read, pascal-api-infra-faa 0.20.0).
  // Here: normalize, then the rules the document can't say (DbApiSample.Validators),
  // every failing field in one 400.
  LCode := Trim(ACity.Code);
  LName := TNorm.CityName.Apply(ACity.Name);
  LCheck := TPcValidation.Create;
  LCheck.Check('code', LCode, TValid.IbgeCode);
  LCheck.Check('name', LName, TValid.Required);
  LCheck.RaiseIfAny;

  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader['CITY.INSERT']
      .ProcessTag('POPULATION', ACity.Population.HasValue).SQL;
    LQuery.Params.Strings['CODE'] := LCode;
    LQuery.Params.Strings['NAME'] := LName;
    LQuery.Params.Strings['STATE'] := TNorm.StateCode.Apply(ACity.State);
    // No if: absent, the column and its parameter are gone (the database
    // writes NULL); present, the value is bound.
    LQuery.Params.OptIntegers['POPULATION'] := ACity.Population;
    LQuery.ExecSql; // EConstraintViolationException (cvUnique) -> 409
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
  Result := FindByCode(LCode);
end;

function TCityRepository.Update(const ACode: string; const APatch: ICityPatch): ICity;
var
  LName, LState: IOptString;
  LPopulation: IOptNullInteger;
  LCheck: TPcValidation;
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LRows: Int64;
begin
  // Normalized inside the optionals, by the rules of DbApiSample.Normalizers
  // (pascal-common-faa 1.13.0): an absent member stays absent, so there is
  // no if here. HasValue is "the member came": for population, with a
  // number or null.
  LName := TOptionals.Normalize(APatch.Name, TNorm.CityName);
  LState := TOptionals.Normalize(APatch.State, TNorm.StateCode);
  LPopulation := APatch.Population;
  // The document's limits were enforced at the edge (THorseBody.Read); the
  // rule it can't say, for the members that came: an absent name isn't
  // checked.
  LCheck := TPcValidation.Create;
  LCheck.Check('name', LName, TValid.Required);
  LCheck.RaiseIfAny;
  if not (LName.HasValue or LState.HasValue or LPopulation.HasValue) then
    Exit(FindByCode(ACode)); // nothing to change

  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader['CITY.UPDATE']
      .ProcessTag('NAME', LName.HasValue)
      .ProcessTag('STATE', LState.HasValue)
      .ProcessTag('POPULATION', LPopulation.HasValue).SQL;
    // No if per member: an absent optional binds nothing (its block is
    // gone), a Null binds NULL, a value binds it.
    LQuery.Params.Strings['CODE'] := ACode;
    LQuery.Params.OptStrings['NAME'] := LName;
    LQuery.Params.OptStrings['STATE'] := LState;
    LQuery.Params.OptNullIntegers['POPULATION'] := LPopulation;
    LRows := LQuery.ExecSql;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
  if LRows = 0 then
    raise ENotFoundException.Create(Format('City %s not found.', [ACode]));
  Result := FindByCode(ACode);
end;

procedure TCityRepository.Delete(const ACode: string);
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LRows: Int64;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader['CITY.DELETE'].SQL;
    LQuery.Params.Strings['CODE'] := ACode;
    LRows := LQuery.ExecSql;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
  if LRows = 0 then
    raise ENotFoundException.Create(Format('City %s not found.', [ACode]));
end;

initialization
  TJsonMapper.Shared.RegisterMapping<ICityInsert, TCityInsert>;
  TJsonMapper.Shared.RegisterMapping<ICity, TCity>;
  TJsonMapper.Shared.RegisterMapping<ICityFind, TCityFind>;
  TJsonMapper.Shared.RegisterMapping<ICityPatch, TCityPatch>;
  // OpenAPI metadata the types can't tell (FPC has no attributes).
  TApiSchema.Describe(TypeInfo(ICityInsert), 'A new city')
    .Prop('Code').Desc('IBGE code').Example('4205407').Pattern('^[0-9]{7}$')
    .Prop('Name').Desc('City name').Example('Florianópolis').MaxLength(100)
    .Prop('State').Desc('Two-letter state').Example('SC').MinLength(2).MaxLength(2)
    .Prop('Population').Desc('Inhabitants, when known').Example('537211').Minimum(0);
  TApiSchema.Describe(TypeInfo(ICityFind))
    .Prop('Page').Desc('Page number, from 1')
    .Prop('Limit').Desc('Cities per page (default 2, at most 50)')
    .Prop('OrderBy').Desc(CityOrderSpec.DocHint)
    .Prop('Search').Desc('Not used by this sample')
    .Prop('State').Desc('Only the cities of this state (two letters)');
  TApiSchema.Describe(TypeInfo(ICityPatch), 'The members to change; the others stay')
    .Prop('Name').Desc('City name; never null').Example('Florianópolis').MaxLength(100)
    .Prop('State').Desc('Two-letter state; never null').Example('SC').MinLength(2).MaxLength(2)
    .Prop('Population').Desc('Inhabitants; null clears it').Example('537211').Minimum(0);
  TApiSchema.Describe(TypeInfo(ICity), 'A city')
    .Prop('Code').Desc('IBGE code').Example('4205407')
    .Prop('Population').Desc('Inhabitants; null when unknown');

end.
