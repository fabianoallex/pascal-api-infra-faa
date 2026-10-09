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
  end;

  ICity = interface(IResponseDTOBase)
    ['{2AD7DFDC-6A1C-4F82-8E47-3E646F5971DD}']
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

  TCity = class(TResponseDTOBase, ICity)
  private
    FCode, FName, FState: string;
    FPopulation: INullInteger;
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
    function ReadCity(const AResult: IQueryResult): ICity;
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
  PascalApi.Http;

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
    .Add(DIR, 'CITY.INSERT',
      'INSERT INTO CITIES (CODE, NAME, STATE, POPULATION) VALUES (:CODE, :NAME, :STATE, :POPULATION)')
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

{ TCityRepository }

constructor TCityRepository.Create(const AFactory: IDBFactory);
begin
  inherited Create;
  FFactory := AFactory;
end;

function TCityRepository.ReadCity(const AResult: IQueryResult): ICity;
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

function TCityRepository.FindPage(const AState: IOptString; const AOrderBy: string;
  const APage: TPageRequest): TPage<ICity>;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
  LOrder: string;
  LCount: Integer;
begin
  LOrder := CityOrderSpec.Build(AOrderBy); // before touching the database: 400 if invalid
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader['CITY.COUNT'].ProcessTag('STATE', AState.HasValue).SQL;
    if AState.HasValue then
      LQuery.Params.Strings['STATE'] := UpperCase(AState.Value);
    Result.Meta := TPageMeta.Create(APage, LQuery.Open.Int64s['TOTAL']);

    LQuery.Sql := FFactory.SqlLoader['CITY.PAGE'].ProcessTag('STATE', AState.HasValue)
      .ReplaceLiteral('ORDER', LOrder).ReplaceLiteral('PAGE', PdbPagingClause(LScope, APage)).SQL;
    if AState.HasValue then
      LQuery.Params.Strings['STATE'] := UpperCase(AState.Value);
    LResult := LQuery.Open;
    Result.Items := nil;
    SetLength(Result.Items, LResult.RecordCount);
    LCount := 0;
    while not LResult.Eof do
    begin
      Result.Items[LCount] := ReadCity(LResult);
      Inc(LCount);
      LResult.Next;
    end;
    SetLength(Result.Items, LCount);
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
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
  LCode: string;
begin
  LCode := Trim(ACity.GetCode);
  if (Length(LCode) <> 7) or (StrToIntDef(LCode, -1) < 0) then
    raise EValidationException.Create('"code" must be the 7-digit IBGE code.');
  if Trim(ACity.GetName) = '' then
    raise EValidationException.Create('"name" is required.');
  if Length(Trim(ACity.GetState)) <> 2 then
    raise EValidationException.Create('"state" must have 2 letters.');

  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader['CITY.INSERT'].SQL;
    LQuery.Params.Strings['CODE'] := LCode;
    LQuery.Params.Strings['NAME'] := Trim(ACity.GetName);
    LQuery.Params.Strings['STATE'] := UpperCase(Trim(ACity.GetState));
    // An absent population is NULL. OptIntegers would leave the parameter
    // unbound when absent; OptNullIntegers binds NULL for an explicit null.
    if ACity.GetPopulation.HasValue then
      LQuery.Params.OptNullIntegers['POPULATION'] := TOptNullInteger.From(ACity.GetPopulation.Value)
    else
      LQuery.Params.OptNullIntegers['POPULATION'] := TOptNullInteger.Null;
    LQuery.ExecSql; // EConstraintViolationException (cvUnique) -> 409
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
  Result := FindByCode(LCode);
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
  // OpenAPI metadata the types can't tell (FPC has no attributes).
  TApiSchema.Describe(TypeInfo(ICityInsert), 'A new city')
    .Prop('Code').Desc('IBGE code').Example('4205407').Pattern('^[0-9]{7}$')
    .Prop('Name').Desc('City name').Example('Florianópolis').MaxLength(100)
    .Prop('State').Desc('Two-letter state').Example('SC').MinLength(2).MaxLength(2)
    .Prop('Population').Desc('Inhabitants, when known').Example('537211').Minimum(0);
  TApiSchema.Describe(TypeInfo(ICity), 'A city')
    .Prop('Code').Desc('IBGE code').Example('4205407')
    .Prop('Population').Desc('Inhabitants; null when unknown');

end.
