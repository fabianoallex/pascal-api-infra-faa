unit TenantApiSample.Cities;

(* The cities of sample 03: one table, the same in every database (each
  dedicated tenant's and the shared one), with TENANT_ID in every row and in
  the primary key. A repository is created per request from the tenant's
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
  end;

  ICity = interface(IResponseDTOBase)
    ['{6F3FCCDA-382F-49BA-8D73-E871EB26E7EF}']
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
  end;

/// Every SQL of the sample, under the SQLITE directory.
function CitySqlSource: ISqlSource;

/// The migrations of every database: SCHEMA_MIGRATIONS, CITIES.
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
      'CREATE TABLE CITIES (TENANT_ID VARCHAR(40) NOT NULL, CODE VARCHAR(7) NOT NULL, ' +
      'NAME VARCHAR(100) NOT NULL, STATE VARCHAR(2) NOT NULL, POPULATION INTEGER, ' +
      'CONSTRAINT PK_CITIES PRIMARY KEY (TENANT_ID, CODE));')
    .Add(DIR, 'CITY.LIST',
      'SELECT CODE, NAME, STATE, POPULATION FROM CITIES WHERE ${TENANT} ORDER BY NAME, CODE')
    .Add(DIR, 'CITY.BY_CODE',
      'SELECT CODE, NAME, STATE, POPULATION FROM CITIES WHERE CODE = :CODE AND ${TENANT}')
    .Add(DIR, 'CITY.INSERT',
      'INSERT INTO CITIES (TENANT_ID, CODE, NAME, STATE, POPULATION) ' +
      'VALUES (:TENANT_ID, :CODE, :NAME, :STATE, :POPULATION)')
    .Add(DIR, 'CITY.DELETE', 'DELETE FROM CITIES WHERE CODE = :CODE AND ${TENANT}');
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
  SetLength(Result, 2);
  Result[0] := Item(1, 'MIG.0001');
  Result[1] := Item(2, 'MIG.0002');
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
  LCode := Trim(ACity.GetCode);
  if (Length(LCode) <> 7) or (StrToIntDef(LCode, -1) < 0) then
    raise EValidationException.Create('"code" must be the 7-digit IBGE code.');
  if Trim(ACity.GetName) = '' then
    raise EValidationException.Create('"name" is required.');
  if Length(Trim(ACity.GetState)) <> 2 then
    raise EValidationException.Create('"state" must have 2 letters.');

  LScope := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    TTenantFilter.Prepare(LQuery, FScope, 'CITY.INSERT');
    LQuery.Params.Strings['CODE'] := LCode;
    LQuery.Params.Strings['NAME'] := Trim(ACity.GetName);
    LQuery.Params.Strings['STATE'] := UpperCase(Trim(ACity.GetState));
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

initialization
  TJsonMapper.Shared.RegisterMapping<ICityInsert, TCityInsert>;
  TJsonMapper.Shared.RegisterMapping<ICity, TCity>;
  TApiSchema.Describe(TypeInfo(ICityInsert), 'A new city of the caller''s tenant')
    .Prop('Code').Desc('IBGE code, unique within the tenant').Example('4205407').Pattern('^[0-9]{7}$')
    .Prop('Name').Desc('City name').Example('Florianópolis').MaxLength(100)
    .Prop('State').Desc('Two-letter state').Example('SC').MinLength(2).MaxLength(2)
    .Prop('Population').Desc('Inhabitants, when known').Example('537211').Minimum(0);
  TApiSchema.Describe(TypeInfo(ICity), 'A city of the caller''s tenant')
    .Prop('Code').Desc('IBGE code').Example('4205407')
    .Prop('Population').Desc('Inhabitants; null when unknown');

end.
