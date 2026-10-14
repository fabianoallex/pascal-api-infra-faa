unit TenantApiSample.Control;

{ The control database of sample 03 (control.sqlite): the tenants, read by
  PascalApi.Tenancy's TDbTenantCatalog through the SQL named TENANT.BY_ID and
  TENANT.ALL (the columns that catalog expects: ID, MODE, SUSPENDED, PLAN).

  The sample has no admin API: on startup, SeedTenants replaces the table's
  rows with the TENANTS configuration, standing in for whatever provisions
  tenants in a real application (decision 10 of docs/multitenancy-design.md:
  the library reads the catalog, it doesn't own it). }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  PascalDb.Interfaces,
  PascalDb.SqlSources,
  PascalDb.Migrations,
  PascalApi.Tenancy;

function ControlSqlSource: ISqlSource;

/// SCHEMA_MIGRATIONS and TENANTS.
function ControlMigrations: TArray<TMigrationItem>;

/// The TENANTS rows become ASource's tenants, in one transaction.
procedure SeedTenants(const AFactory: IDBFactory; const ASource: ITenantCatalog);

implementation

uses
  PascalCommon.Optionals;

const
  DIR = 'SQLITE';

function ControlSqlSource: ISqlSource;
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
      'CREATE TABLE TENANTS (ID VARCHAR(40) NOT NULL PRIMARY KEY, MODE VARCHAR(10) NOT NULL, ' +
      'SUSPENDED INTEGER NOT NULL, PLAN VARCHAR(40));')
    .Add(DIR, 'TENANT.BY_ID', 'SELECT ID, MODE, SUSPENDED, PLAN FROM TENANTS WHERE ID = :ID')
    .Add(DIR, 'TENANT.ALL', 'SELECT ID, MODE, SUSPENDED, PLAN FROM TENANTS ORDER BY ID')
    .Add(DIR, 'TENANT.DELETE_ALL', 'DELETE FROM TENANTS')
    .Add(DIR, 'TENANT.INSERT',
      'INSERT INTO TENANTS (ID, MODE, SUSPENDED, PLAN) VALUES (:ID, :MODE, :SUSPENDED, :PLAN)');
end;

function ControlMigrations: TArray<TMigrationItem>;

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

procedure SeedTenants(const AFactory: IDBFactory; const ASource: ITenantCatalog);
const
  MODES: array[TTenantMode] of string = ('dedicated', 'shared');
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LTenants: TArray<TTenantInfo>;
  I: Integer;
begin
  LTenants := ASource.All;
  LScope := AFactory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    LQuery.Sql := AFactory.SqlLoader['TENANT.DELETE_ALL'].SQL;
    LQuery.ExecSql;
    for I := 0 to High(LTenants) do
    begin
      LQuery.Sql := AFactory.SqlLoader['TENANT.INSERT'].SQL;
      LQuery.Params.Strings['ID'] := LTenants[I].Id;
      LQuery.Params.Strings['MODE'] := MODES[LTenants[I].Mode];
      LQuery.Params.Integers['SUSPENDED'] := Ord(LTenants[I].Suspended);
      if LTenants[I].Plan <> '' then
        LQuery.Params.OptNullStrings['PLAN'] := TOptNullString.From(LTenants[I].Plan)
      else
        LQuery.Params.OptNullStrings['PLAN'] := TOptNullString.Null;
      LQuery.ExecSql;
    end;
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
end;

end.
