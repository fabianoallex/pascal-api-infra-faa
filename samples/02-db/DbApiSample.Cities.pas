unit DbApiSample.Cities;

{ The cities of sample 02 in a real database (SQLite or PostgreSQL through
  pascal-db-faa):
  DTOs, migrations, and a repository that pages and orders in SQL.

  Everything that reaches the SQL text from the client goes through an
  allow-list or a parameter: the ORDER BY comes from TOrderBySpec.Build, the
  page clause from the connection's dialect (PdbPagingClause), and the
  filter is a :STATE parameter in a tagged block, kept only when the
  filter came. A duplicate code makes the database raise a constraint
  violation, which the error handler answers with 409; nothing here checks
  for duplicates first.

  The SQL is registered in code (TMemorySqlSource) to keep the sample in two
  files; an application would usually embed .sql files as resources
  (pascal-db-faa's tools/build_sql_res.py). It is the same on SQLite and
  PostgreSQL, so it lives in one directory, COMMON, which the program's
  TFallbackSqlSource asks after the database's own (SQLITE, PG).

  Optimistic concurrency (0.23.0, PascalApi.Preconditions): every row has
  a VERSION that each change moves up; the handlers send it as the ETag,
  and Replace (PUT) needs If-Match with the version read and writes only
  WHERE VERSION = :VERSION. The keys of PascalApi.Idempotency's database
  store (POST /cities with an Idempotency-Key) are in IDEMPOTENCY_KEYS,
  migration 5, with the store's six statements; without tenants their
  TENANT_ID (the scope) is ''. }

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

  /// PUT /cities/:code: every member but the code, which the path names.
  /// Population is required and may be null (unknown).
  ICityReplace = interface(IUpdateDTOBase)
    ['{A96926BF-90E3-4021-8A56-88F6E965B663}']
    function GetName: string;
    function GetState: string;
    function GetPopulation: INullInteger;
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

  TCityReplace = class(TUpdateDTOBase, ICityReplace)
  private
    FName, FState: string;
    FPopulation: INullInteger;
  public
    function GetName: string;
    function GetState: string;
    function GetPopulation: INullInteger;
  published
    property Name: string read FName write FName;
    property State: string read FState write FState;
    property Population: INullInteger read FPopulation write FPopulation;
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
    /// ENotFoundException when there is none. AVersion: the row's version
    /// (its ETag is PascalApi.Preconditions.VersionETag(AVersion)).
    function FindByCode(const ACode: string): ICity; overload;
    function FindByCode(const ACode: string; out AVersion: Int64): ICity; overload;
    /// EValidationException for invalid data; the database's
    /// EConstraintViolationException for a code that already exists.
    function Insert(const ACity: ICityInsert; out AVersion: Int64): ICity;
    /// Changes only the members that came; an empty patch changes nothing.
    /// ENotFoundException when there is none, EValidationException for
    /// invalid data.
    function Update(const ACode: string; const APatch: ICityPatch; out AVersion: Int64): ICity;
    /// Every member at once, guarded by AIfMatch (If-Match's value): 428
    /// without it, 400 when it isn't one, 404 for no city, 412 when it
    /// doesn't name the current version, or when the row changed between
    /// the check and the write. 400 for invalid data.
    function Replace(const ACode, AIfMatch: string; const ACity: ICityReplace;
      out AVersion: Int64): ICity;
    /// ENotFoundException when there is none.
    procedure Delete(const ACode: string);
  end;

/// The ordering the client may ask for (also the orderBy parameter's
/// documentation, through DocHint).
function CityOrderSpec: TOrderBySpec;

const
  /// The directory of the SQL every database runs.
  CITY_SQL_COMMON_DIR = 'COMMON';

/// Every SQL of the sample, under CITY_SQL_COMMON_DIR.
function CitySqlSource: ISqlSource;

/// The migrations: SCHEMA_MIGRATIONS, CITIES, seed rows, CITIES.VERSION,
/// IDEMPOTENCY_KEYS.
function CityMigrations: TArray<TMigrationItem>;

implementation

uses
  SysUtils,
  TypInfo,
  PascalJsonMapper.Mapper,
  PascalApi.OpenApi,
  PascalApi.Http,
  PascalApi.Preconditions,
  PascalApi.PagedQuery,
  PascalApi.Text,
  PascalCommon.Validators,
  DbApiSample.Normalizers,
  DbApiSample.Validators;

const
  DIR = CITY_SQL_COMMON_DIR;

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
    // 0.23.0: the version each change moves up (the ETag), and the keys of
    // PascalApi.Idempotency's database store, as docs/guide/concurrency.md
    // gives them.
    .Add(DIR, 'MIG.0004', 'ALTER TABLE CITIES ADD COLUMN VERSION INTEGER DEFAULT 1 NOT NULL;')
    .Add(DIR, 'MIG.0005',
      'CREATE TABLE IDEMPOTENCY_KEYS (TENANT_ID VARCHAR(64) NOT NULL, ' +
      'IDEM_KEY VARCHAR(255) NOT NULL, FINGERPRINT CHAR(64) NOT NULL, ' +
      'DONE INTEGER DEFAULT 0 NOT NULL, LEASE_UNTIL BIGINT NOT NULL, EXPIRES_AT BIGINT NOT NULL, ' +
      'STATUS_CODE INTEGER DEFAULT 0 NOT NULL, RESPONSE_HEADERS VARCHAR(2000) DEFAULT '''' NOT NULL, ' +
      'RESPONSE_BODY TEXT DEFAULT '''' NOT NULL, CREATED_AT BIGINT NOT NULL, ' +
      'CONSTRAINT PK_IDEMPOTENCY_KEYS PRIMARY KEY (TENANT_ID, IDEM_KEY));' + sLineBreak +
      'CREATE INDEX IX_IDEMPOTENCY_KEYS_EXPIRES ON IDEMPOTENCY_KEYS (TENANT_ID, EXPIRES_AT);')
    // The [STATE] block is kept (without its markers) only when the filter
    // came: ProcessTag('STATE', HasValue).
    .Add(DIR, 'CITY.COUNT',
      'SELECT COUNT(*) AS TOTAL FROM CITIES WHERE 1 = 1 [STATE {] AND STATE = :STATE [} STATE]')
    .Add(DIR, 'CITY.PAGE',
      'SELECT CODE, NAME, STATE, POPULATION FROM CITIES WHERE 1 = 1 ' +
      '[STATE {] AND STATE = :STATE [} STATE] ORDER BY ${ORDER} ${PAGE}')
    .Add(DIR, 'CITY.BY_CODE',
      'SELECT CODE, NAME, STATE, POPULATION, VERSION FROM CITIES WHERE CODE = :CODE')
    // The POPULATION blocks are kept only when it came; without them the
    // column takes its default, NULL.
    .Add(DIR, 'CITY.INSERT',
      'INSERT INTO CITIES (CODE, NAME, STATE [POPULATION {], POPULATION [} POPULATION]) ' +
      'VALUES (:CODE, :NAME, :STATE [POPULATION {], :POPULATION [} POPULATION])')
    // One block per member a PATCH may carry, kept only when it came.
    .Add(DIR, 'CITY.UPDATE',
      'UPDATE CITIES SET VERSION = VERSION + 1 [NAME {], NAME = :NAME [} NAME] ' +
      '[STATE {], STATE = :STATE [} STATE] [POPULATION {], POPULATION = :POPULATION [} POPULATION] ' +
      'WHERE CODE = :CODE')
    // Only the version read: a change in between matches no row (a 412).
    .Add(DIR, 'CITY.REPLACE',
      'UPDATE CITIES SET NAME = :NAME, STATE = :STATE, POPULATION = :POPULATION, ' +
      'VERSION = VERSION + 1 WHERE CODE = :CODE AND VERSION = :VERSION')
    .Add(DIR, 'CITY.DELETE', 'DELETE FROM CITIES WHERE CODE = :CODE')
    // TDbIdempotencyStore's statements (PascalApi.Idempotency), its default
    // names. The claim's INSERT does nothing when the key exists: the same
    // on SQLite (3.24 and later) and PostgreSQL.
    .Add(DIR, 'IDEMPOTENCY.PURGE',
      'DELETE FROM IDEMPOTENCY_KEYS WHERE TENANT_ID = :TENANT_ID AND EXPIRES_AT <= :NOW')
    .Add(DIR, 'IDEMPOTENCY.CLAIM',
      'INSERT INTO IDEMPOTENCY_KEYS (TENANT_ID, IDEM_KEY, FINGERPRINT, DONE, LEASE_UNTIL, ' +
      'EXPIRES_AT, CREATED_AT) VALUES (:TENANT_ID, :IDEM_KEY, :FINGERPRINT, 0, :LEASE_UNTIL, ' +
      ':EXPIRES_AT, :CREATED_AT) ON CONFLICT (TENANT_ID, IDEM_KEY) DO NOTHING')
    .Add(DIR, 'IDEMPOTENCY.BY_KEY',
      'SELECT FINGERPRINT, DONE, LEASE_UNTIL, STATUS_CODE, RESPONSE_HEADERS, RESPONSE_BODY ' +
      'FROM IDEMPOTENCY_KEYS WHERE TENANT_ID = :TENANT_ID AND IDEM_KEY = :IDEM_KEY')
    .Add(DIR, 'IDEMPOTENCY.TAKE_OVER',
      'UPDATE IDEMPOTENCY_KEYS SET LEASE_UNTIL = :LEASE_UNTIL WHERE TENANT_ID = :TENANT_ID ' +
      'AND IDEM_KEY = :IDEM_KEY AND DONE = 0 AND LEASE_UNTIL <= :NOW')
    .Add(DIR, 'IDEMPOTENCY.COMPLETE',
      'UPDATE IDEMPOTENCY_KEYS SET DONE = 1, STATUS_CODE = :STATUS_CODE, ' +
      'RESPONSE_HEADERS = :RESPONSE_HEADERS, RESPONSE_BODY = :RESPONSE_BODY ' +
      'WHERE TENANT_ID = :TENANT_ID AND IDEM_KEY = :IDEM_KEY')
    .Add(DIR, 'IDEMPOTENCY.RELEASE',
      'DELETE FROM IDEMPOTENCY_KEYS WHERE TENANT_ID = :TENANT_ID AND IDEM_KEY = :IDEM_KEY ' +
      'AND DONE = 0');
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
  SetLength(Result, 5);
  Result[0] := Item(1, 'MIG.0001', True);
  Result[1] := Item(2, 'MIG.0002', True);
  Result[2] := Item(3, 'MIG.0003', False);
  Result[3] := Item(4, 'MIG.0004', True);
  Result[4] := Item(5, 'MIG.0005', True);
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

{ TCityReplace }

function TCityReplace.GetName: string;
begin
  Result := FName;
end;

function TCityReplace.GetState: string;
begin
  Result := FState;
end;

function TCityReplace.GetPopulation: INullInteger;
begin
  Result := TOptionals.Safe(FPopulation);
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
// 0.19.0; the optional as it is since 0.22.0): when the state came, its
// STATE block is kept in both statements and its value bound to both; when
// it didn't, the block goes and nothing is bound.
function TCityRepository.FindPage(const AState: IOptString; const AOrderBy: string;
  const APage: TPageRequest): TPage<ICity>;
var
  LOrder: string;
begin
  LOrder := CityOrderSpec.Build(AOrderBy); // before touching the database: 400 if invalid
  Result := TPagedQuery.Run<ICity>(FFactory, FFactory.SqlLoader['CITY.COUNT'],
    FFactory.SqlLoader['CITY.PAGE'], LOrder, APage,
    TQueryArgs.New.OptStrings('STATE', TOptionals.Upper(AState), 'STATE'), ReadCity);
end;

function TCityRepository.FindByCode(const ACode: string): ICity;
var
  LVersion: Int64;
begin
  Result := FindByCode(ACode, LVersion);
end;

function TCityRepository.FindByCode(const ACode: string; out AVersion: Int64): ICity;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
begin
  Result := nil;
  AVersion := 0;
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader['CITY.BY_CODE'].SQL;
    LQuery.Params.Strings['CODE'] := ACode;
    LResult := LQuery.Open;
    if not LResult.Eof then
    begin
      Result := ReadCity(LResult);
      AVersion := LResult.Int64s['VERSION'];
    end;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
  if Result = nil then
    raise ENotFoundException.Create(Format('City %s not found.', [ACode]));
end;

function TCityRepository.Insert(const ACity: ICityInsert; out AVersion: Int64): ICity;
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
  Result := FindByCode(LCode, AVersion);
end;

function TCityRepository.Update(const ACode: string; const APatch: ICityPatch;
  out AVersion: Int64): ICity;
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
    Exit(FindByCode(ACode, AVersion)); // nothing to change

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
  Result := FindByCode(ACode, AVersion);
end;

function TCityRepository.Replace(const ACode, AIfMatch: string; const ACity: ICityReplace;
  out AVersion: Int64): ICity;
var
  LName, LState: string;
  LCheck: TPcValidation;
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LRead, LRows: Int64;
begin
  // 428 or 400 before anything else: without a version there is nothing
  // to compare.
  RequireIfMatchSent(AIfMatch);
  LName := TNorm.CityName.Apply(ACity.Name);
  LState := TNorm.StateCode.Apply(ACity.State);
  LCheck := TPcValidation.Create;
  LCheck.Check('name', LName, TValid.Required);
  LCheck.RaiseIfAny;
  // Read (404), compare (412), then a write that names the version read.
  // The read is its own transaction: on SQLite a transaction's first
  // statement is a write when another writer may race.
  FindByCode(ACode, LRead);
  RequireIfMatch(AIfMatch, VersionETag(LRead));
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader['CITY.REPLACE'].SQL;
    LQuery.Params.Strings['CODE'] := ACode;
    LQuery.Params.Int64s['VERSION'] := LRead;
    LQuery.Params.Strings['NAME'] := LName;
    LQuery.Params.Strings['STATE'] := LState;
    LQuery.Params.NullIntegers['POPULATION'] := ACity.Population;
    LRows := LQuery.ExecSql;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
  if LRows = 0 then
    RaisePreconditionFailed; // changed (or deleted) after the check
  Result := FindByCode(ACode, AVersion);
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
  TJsonMapper.Shared.RegisterMapping<ICityReplace, TCityReplace>;
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
  TApiSchema.Describe(TypeInfo(ICityReplace), 'Every member of the city but its code')
    .Prop('Name').Desc('City name').Example('Florianópolis').MaxLength(100)
    .Prop('State').Desc('Two-letter state').Example('SC').MinLength(2).MaxLength(2)
    .Prop('Population').Desc('Inhabitants; null when unknown').Example('537211').Minimum(0);
  TApiSchema.Describe(TypeInfo(ICity), 'A city')
    .Prop('Code').Desc('IBGE code').Example('4205407')
    .Prop('Population').Desc('Inhabitants; null when unknown');

end.
