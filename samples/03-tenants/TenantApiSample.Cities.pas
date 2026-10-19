unit TenantApiSample.Cities;

(* The cities of sample 03 and their states: two tables, the same in every
  database (each dedicated tenant's and the shared one), with TENANT_ID in
  every row and in the primary key. A repository is created per request from the tenant's
  TTenantDataScope, and every query filters by TENANT_ID (decision 4), also
  on a dedicated database, where the filter is redundant: the same code
  serves both modes.

  Every query is set through TTenantFilter.Prepare, which loads the SQL,
  replaces ${TENANT} with the condition and binds :TENANT_ID in one call:
  replacing and binding separately let one be forgotten, and a forgotten
  bind is silent on SQLdb/SQLite (measured: the unbound parameter is NULL,
  the condition matches nothing, the route answers 404 with nothing in the
  log). A query written without Prepare is what the cross-tenant checks of
  tools/http_scenarios_tenants.sh catch (measured: dropping the condition
  from two queries failed 5 of them).

  CITY.DETAILS joins the two tables: each one gets its own tag with its
  alias, ${TENANT.c} and ${TENANT.s}, the state's in the LEFT JOIN's ON
  (measured on SQLite: plain ${TENANT} is "ambiguous column name", and a
  join without the tenant in ON returns another tenant's state; in WHERE,
  the state's condition would drop a city whose state the tenant hasn't
  registered).

  No seed rows: the scenarios create each tenant's cities over HTTP.

  This comment uses parenthesis-asterisk: it quotes ${TENANT}, whose brace
  would close a brace comment. *)

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  PascalCommon.Optionals,
  PascalDb.Interfaces,
  PascalDb.SqlSources,
  PascalDb.Migrations,
  PascalApi.Dto,
  PascalApi.Tenancy;

type
  ICityInsert = interface(IInsertDTOBase)
    ['{9A7301BD-0E4B-4EED-879B-771546674A04}']
    function GetCode: string;
    function GetName: string;
    function GetState: string;
    function GetPopulation: IOptInteger;
    property Code: string read GetCode;
    property Name: string read GetName;
    property State: string read GetState;
    property Population: IOptInteger read GetPopulation;
  end;

  ICity = interface(IResponseDTOBase)
    ['{6F3FCCDA-382F-49BA-8D73-E871EB26E7EF}']
    function GetCode: string;
    function GetName: string;
    function GetState: string;
    function GetPopulation: INullInteger;
    property Code: string read GetCode;
    property Name: string read GetName;
    property State: string read GetState;
    property Population: INullInteger read GetPopulation;
  end;

  ICityDetails = interface(IResponseDTOBase)
    ['{755E8846-CD22-4487-A5C4-3594E5D002D6}']
    function GetCode: string;
    function GetName: string;
    function GetState: string;
    function GetStateName: INullString;
    property Code: string read GetCode;
    property Name: string read GetName;
    property State: string read GetState;
    property StateName: INullString read GetStateName;
  end;

  IStateInsert = interface(IInsertDTOBase)
    ['{4ED8D867-E4B2-4B8D-ADFA-50D2BD542BB6}']
    function GetCode: string;
    function GetName: string;
    property Code: string read GetCode;
    property Name: string read GetName;
  end;

  IState = interface(IResponseDTOBase)
    ['{8571B874-C3D1-47D2-A446-A3E178C1A56B}']
    function GetCode: string;
    function GetName: string;
    property Code: string read GetCode;
    property Name: string read GetName;
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

  TCityDetails = class(TResponseDTOBase, ICityDetails)
  private
    FCode, FName, FState: string;
    FStateName: INullString;
  public
    function GetCode: string;
    function GetName: string;
    function GetState: string;
    function GetStateName: INullString;
  published
    property Code: string read FCode write FCode;
    property Name: string read FName write FName;
    property State: string read FState write FState;
    property StateName: INullString read FStateName write FStateName;
  end;

  TStateInsert = class(TInsertDTOBase, IStateInsert)
  private
    FCode, FName: string;
  public
    function GetCode: string;
    function GetName: string;
  published
    property Code: string read FCode write FCode;
    property Name: string read FName write FName;
  end;

  TState = class(TResponseDTOBase, IState)
  private
    FCode, FName: string;
  public
    function GetCode: string;
    function GetName: string;
  published
    property Code: string read FCode write FCode;
    property Name: string read FName write FName;
  end;
{$M-}

  // TArray<ICity>, not "array of ICity", as in sample 02 (E2008 on Delphi;
  // FPC reads ">>" in Serialize<TArray<ICity>> as shr).
  TCityArray = TArray<ICity>;

  TCityRepository = class
  private
    FScope: TTenantDataScope;
    function ReadCity(const AResult: IQueryResult): ICity;
  public
    constructor Create(const AScope: TTenantDataScope);
    /// The tenant's cities, by name.
    function List: TCityArray;
    /// ENotFoundException when the tenant has none with this code.
    function FindByCode(const ACode: string): ICity;
    /// EValidationException for invalid data; the database's
    /// EConstraintViolationException when the tenant already has the code.
    function Insert(const ACity: ICityInsert): ICity;
    /// ENotFoundException when the tenant has none with this code.
    procedure Delete(const ACode: string);
    /// The city and the name of its state in the tenant (a JOIN); StateName
    /// is null when the tenant hasn't registered the state. ENotFoundException
    /// when the tenant has no city with this code.
    function Details(const ACode: string): ICityDetails;
    /// EValidationException for invalid data; the database's
    /// EConstraintViolationException when the tenant already has the state.
    function InsertState(const AState: IStateInsert): IState;
  end;

/// Every SQL of the sample, under the SQLITE directory.
function CitySqlSource: ISqlSource;

/// The migrations of every database: SCHEMA_MIGRATIONS, CITIES, STATES.
function CityMigrations: TArray<TMigrationItem>;

implementation

uses
  SysUtils,
  TypInfo,
  PascalJsonMapper.Mapper,
  PascalApi.OpenApi,
  PascalApi.Http,
  PascalApi.Text;

const
  DIR = 'SQLITE';

/// True when AText is exactly ALength ASCII digits. StrToIntDef would also
/// take '+123456' or '-000001'.
function IsDigits(const AText: string; ALength: Integer): Boolean;
var
  I: Integer;
begin
  Result := Length(AText) = ALength;
  for I := 1 to Length(AText) do
    if (AText[I] < '0') or (AText[I] > '9') then
      Exit(False);
end;

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
      'CREATE TABLE CITIES (TENANT_ID VARCHAR(40) NOT NULL, CODE VARCHAR(7) NOT NULL, ' +
      'NAME VARCHAR(100) NOT NULL, STATE VARCHAR(2) NOT NULL, POPULATION INTEGER, ' +
      'CONSTRAINT PK_CITIES PRIMARY KEY (TENANT_ID, CODE));')
    .Add(DIR, 'CITY.LIST',
      'SELECT CODE, NAME, STATE, POPULATION FROM CITIES WHERE ${TENANT} ORDER BY NAME, CODE')
    .Add(DIR, 'CITY.BY_CODE',
      'SELECT CODE, NAME, STATE, POPULATION FROM CITIES WHERE CODE = :CODE AND ${TENANT}')
    // The POPULATION blocks are kept only when it came; without them the
    // column takes its default, NULL.
    .Add(DIR, 'CITY.INSERT',
      'INSERT INTO CITIES (TENANT_ID, CODE, NAME, STATE[POPULATION {], POPULATION[} POPULATION]) ' +
      'VALUES (:TENANT_ID, :CODE, :NAME, :STATE[POPULATION {], :POPULATION[} POPULATION])')
    .Add(DIR, 'CITY.DELETE', 'DELETE FROM CITIES WHERE CODE = :CODE AND ${TENANT}')
    .Add(DIR, 'MIG.0003',
      'CREATE TABLE STATES (TENANT_ID VARCHAR(40) NOT NULL, CODE VARCHAR(2) NOT NULL, ' +
      'NAME VARCHAR(100) NOT NULL, CONSTRAINT PK_STATES PRIMARY KEY (TENANT_ID, CODE));')
    // Both tables have TENANT_ID: one tag per alias, the state's in ON.
    .Add(DIR, 'CITY.DETAILS',
      'SELECT c.CODE, c.NAME, c.STATE, s.NAME AS STATE_NAME FROM CITIES c ' +
      'LEFT JOIN STATES s ON s.CODE = c.STATE AND ${TENANT.s} ' +
      'WHERE c.CODE = :CODE AND ${TENANT.c}')
    .Add(DIR, 'STATE.INSERT',
      'INSERT INTO STATES (TENANT_ID, CODE, NAME) VALUES (:TENANT_ID, :CODE, :NAME)');
end;

function CityMigrations: TArray<TMigrationItem>;

  function Item(AVersion: Integer; const AName: string): TMigrationItem;
  begin
    Result.Version := AVersion;
    Result.ScriptName := AName;
    Result.ParamReplaceProc := nil;
    Result.Terminator := ';';
    Result.IsDDL := True;
  end;

begin
  Result := nil;
  SetLength(Result, 3);
  Result[0] := Item(1, 'MIG.0001');
  Result[1] := Item(2, 'MIG.0002');
  Result[2] := Item(3, 'MIG.0003');
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

{ TStateInsert }

function TStateInsert.GetCode: string;
begin
  Result := FCode;
end;

function TStateInsert.GetName: string;
begin
  Result := FName;
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

{ TCityDetails }

function TCityDetails.GetCode: string;
begin
  Result := FCode;
end;

function TCityDetails.GetName: string;
begin
  Result := FName;
end;

function TCityDetails.GetState: string;
begin
  Result := FState;
end;

function TCityDetails.GetStateName: INullString;
begin
  Result := TOptionals.Safe(FStateName);
end;

{ TState }

function TState.GetCode: string;
begin
  Result := FCode;
end;

function TState.GetName: string;
begin
  Result := FName;
end;

{ TCityRepository }

constructor TCityRepository.Create(const AScope: TTenantDataScope);
begin
  inherited Create;
  FScope := AScope;
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

function TCityRepository.List: TCityArray;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
  LCount: Integer;
begin
  Result := nil;
  LScope := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    TTenantFilter.Prepare(LQuery, FScope, 'CITY.LIST');
    LResult := LQuery.Open;
    SetLength(Result, LResult.RecordCount);
    LCount := 0;
    while not LResult.Eof do
    begin
      Result[LCount] := ReadCity(LResult);
      Inc(LCount);
      LResult.Next;
    end;
    SetLength(Result, LCount);
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
  LScope := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    TTenantFilter.Prepare(LQuery, FScope, 'CITY.BY_CODE');
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
  // The limits the OpenAPI document declares (TApiSchema.Describe below): the
  // document describes them, only this enforces them.
  LCode := Trim(ACity.Code);
  if not IsDigits(LCode, 7) then
    raise EValidationException.Create('"code" must be the 7-digit IBGE code.');
  if Trim(ACity.Name) = '' then
    raise EValidationException.Create('"name" is required.');
  if PaCharCount(Trim(ACity.Name)) > 100 then
    raise EValidationException.Create('"name" must have at most 100 characters.');
  if Length(Trim(ACity.State)) <> 2 then
    raise EValidationException.Create('"state" must have 2 letters.');
  if ACity.Population.HasValue and (ACity.Population.Value < 0) then
    raise EValidationException.Create('"population" can''t be negative.');

  LScope := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    // SQL already processed (the POPULATION block), then the tenant's
    // condition and :TENANT_ID in the same call.
    TTenantFilter.Prepare(LQuery, FScope, FScope.Factory.SqlLoader['CITY.INSERT']
      .ProcessTag('POPULATION', ACity.Population.HasValue));
    LQuery.Params.Strings['CODE'] := LCode;
    LQuery.Params.Strings['NAME'] := Trim(ACity.Name);
    LQuery.Params.Strings['STATE'] := UpperCase(Trim(ACity.State));
    // No if: absent, the column and its parameter are gone (NULL).
    LQuery.Params.OptIntegers['POPULATION'] := ACity.Population;
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
  LScope := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    TTenantFilter.Prepare(LQuery, FScope, 'CITY.DELETE');
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

function TCityRepository.Details(const ACode: string): ICityDetails;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
  LDetails: TCityDetails;
begin
  Result := nil;
  LScope := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    TTenantFilter.Prepare(LQuery, FScope, 'CITY.DETAILS');
    LQuery.Params.Strings['CODE'] := ACode;
    LResult := LQuery.Open;
    if not LResult.Eof then
    begin
      LDetails := TCityDetails.Create;
      Result := LDetails;
      LDetails.Code := LResult.Strings['CODE'];
      LDetails.Name := LResult.Strings['NAME'];
      LDetails.State := LResult.Strings['STATE'];
      LDetails.StateName := LResult.NullableStrings['STATE_NAME'];
    end;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
  if Result = nil then
    raise ENotFoundException.Create(Format('City %s not found.', [ACode]));
end;

function TCityRepository.InsertState(const AState: IStateInsert): IState;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LState: TState;
  LCode: string;
begin
  LCode := UpperCase(Trim(AState.Code));
  if Length(LCode) <> 2 then
    raise EValidationException.Create('"code" must have 2 letters.');
  if Trim(AState.Name) = '' then
    raise EValidationException.Create('"name" is required.');
  if PaCharCount(Trim(AState.Name)) > 100 then
    raise EValidationException.Create('"name" must have at most 100 characters.');

  LScope := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    TTenantFilter.Prepare(LQuery, FScope, 'STATE.INSERT');
    LQuery.Params.Strings['CODE'] := LCode;
    LQuery.Params.Strings['NAME'] := Trim(AState.Name);
    LQuery.ExecSql; // EConstraintViolationException (cvUnique) -> 409
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
  LState := TState.Create;
  Result := LState;
  LState.Code := LCode;
  LState.Name := Trim(AState.Name);
end;

initialization
  TJsonMapper.Shared.RegisterMapping<ICityInsert, TCityInsert>;
  TJsonMapper.Shared.RegisterMapping<ICity, TCity>;
  TJsonMapper.Shared.RegisterMapping<ICityDetails, TCityDetails>;
  TJsonMapper.Shared.RegisterMapping<IStateInsert, TStateInsert>;
  TJsonMapper.Shared.RegisterMapping<IState, TState>;
  TApiSchema.Describe(TypeInfo(ICityInsert), 'A new city of the caller''s tenant')
    .Prop('Code').Desc('IBGE code, unique within the tenant').Example('4205407').Pattern('^[0-9]{7}$')
    .Prop('Name').Desc('City name').Example('Florianópolis').MaxLength(100)
    .Prop('State').Desc('Two-letter state').Example('SC').MinLength(2).MaxLength(2)
    .Prop('Population').Desc('Inhabitants, when known').Example('537211').Minimum(0);
  TApiSchema.Describe(TypeInfo(ICity), 'A city of the caller''s tenant')
    .Prop('Code').Desc('IBGE code').Example('4205407')
    .Prop('Population').Desc('Inhabitants; null when unknown');
  TApiSchema.Describe(TypeInfo(ICityDetails), 'A city of the caller''s tenant and its state')
    .Prop('StateName').Desc('The state''s name in the tenant; null when not registered')
    .Example('Santa Catarina');
  TApiSchema.Describe(TypeInfo(IStateInsert), 'A new state of the caller''s tenant')
    .Prop('Code').Desc('Two-letter code, unique within the tenant').Example('SC')
    .MinLength(2).MaxLength(2)
    .Prop('Name').Desc('State name').Example('Santa Catarina').MaxLength(100);
  TApiSchema.Describe(TypeInfo(IState), 'A state of the caller''s tenant');

end.
