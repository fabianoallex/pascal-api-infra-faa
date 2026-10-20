unit TenantApiSample.Control;

{ The control database of sample 03 (control.sqlite, or the database
  control on PostgreSQL): the tenants, read by
  PascalApi.Tenancy's TDbTenantCatalog through the SQL named TENANT.BY_ID and
  TENANT.ALL (the columns that catalog expects: ID, MODE, SUSPENDED, PLAN);
  and the JWT signing keys when JWT_KEY_STORE=db, read and written by
  PascalApi.JwtKeys' TDbJwtKeyStore through JWT_KEY.BY_TENANT, JWT_KEY.INSERT
  and JWT_KEY.DELETE (the unique key on TENANT_ID and GENERATION is what
  settles two instances rotating at once); and the refresh tokens of every
  tenant, read and written by PascalApi.RefreshTokens' TDbRefreshTokenStore
  through REFRESH.* (TENANT_ID is the token's scope; the UPDATE of
  REFRESH.MARK_USED matches a row only while USED_AT and REVOKED_AT are
  NULL, so the rows it changed decide two refreshes of one token).

  The sample has no admin API: on startup, SeedTenants replaces the table's
  rows with the TENANTS configuration, standing in for whatever provisions
  tenants in a real application (decision 10 of docs/multitenancy-design.md:
  the library reads the catalog, it doesn't own it). SUSPENDED is an INTEGER
  flag, bound with Flags (pascal-db-faa 0.17.0): PostgreSQL refuses a
  Boolean parameter for an integer column.

  The SQL is the same on SQLite and PostgreSQL: directory COMMON, which the
  program's TFallbackSqlSource asks after the database's own. }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  PascalDb.Interfaces,
  PascalDb.SqlSources,
  PascalDb.Migrations,
  PascalApi.Tenancy;

function ControlSqlSource: ISqlSource;

/// SCHEMA_MIGRATIONS, TENANTS, JWT_KEYS and REFRESH_TOKENS.
function ControlMigrations: TArray<TMigrationItem>;

/// The TENANTS rows become ASource's tenants, in one transaction.
procedure SeedTenants(const AFactory: IDBFactory; const ASource: ITenantCatalog);

implementation

uses
  PascalCommon.Optionals;

const
  DIR = 'COMMON';

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
    .Add(DIR, 'MIG.0003',
      'CREATE TABLE JWT_KEYS (TENANT_ID VARCHAR(40) NOT NULL, GENERATION INTEGER NOT NULL, ' +
      'KID VARCHAR(128) NOT NULL, SECRET VARCHAR(255) NOT NULL, CREATED_AT BIGINT NOT NULL, ' +
      'ACTIVE_FROM BIGINT NOT NULL, CONSTRAINT PK_JWT_KEYS PRIMARY KEY (TENANT_ID, GENERATION), ' +
      'CONSTRAINT UQ_JWT_KEYS_KID UNIQUE (KID));')
    // Only the token's SHA-256 is stored (TOKEN_HASH, 64 hex digits).
    .Add(DIR, 'MIG.0004',
      'CREATE TABLE REFRESH_TOKENS (ID VARCHAR(32) NOT NULL PRIMARY KEY, ' +
      'TENANT_ID VARCHAR(64) NOT NULL, TOKEN_HASH CHAR(64) NOT NULL, ' +
      'USER_ID VARCHAR(128) NOT NULL, FAMILY_ID VARCHAR(32) NOT NULL, ' +
      'CREATED_AT BIGINT NOT NULL, EXPIRES_AT BIGINT NOT NULL, USED_AT BIGINT, REVOKED_AT BIGINT, ' +
      'CONSTRAINT UQ_REFRESH_TOKENS_HASH UNIQUE (TENANT_ID, TOKEN_HASH));' +
      'CREATE INDEX IX_REFRESH_TOKENS_FAMILY ON REFRESH_TOKENS (TENANT_ID, FAMILY_ID);' +
      'CREATE INDEX IX_REFRESH_TOKENS_USER ON REFRESH_TOKENS (TENANT_ID, USER_ID);')
    .Add(DIR, 'REFRESH.INSERT',
      'INSERT INTO REFRESH_TOKENS (ID, TENANT_ID, TOKEN_HASH, USER_ID, FAMILY_ID, CREATED_AT, ' +
      'EXPIRES_AT) VALUES (:ID, :TENANT_ID, :TOKEN_HASH, :USER_ID, :FAMILY_ID, :CREATED_AT, ' +
      ':EXPIRES_AT)')
    .Add(DIR, 'REFRESH.BY_HASH',
      'SELECT ID, USER_ID, FAMILY_ID, EXPIRES_AT, USED_AT, REVOKED_AT FROM REFRESH_TOKENS ' +
      'WHERE TENANT_ID = :TENANT_ID AND TOKEN_HASH = :TOKEN_HASH')
    .Add(DIR, 'REFRESH.MARK_USED',
      'UPDATE REFRESH_TOKENS SET USED_AT = :USED_AT WHERE TENANT_ID = :TENANT_ID AND ID = :ID ' +
      'AND USED_AT IS NULL AND REVOKED_AT IS NULL')
    .Add(DIR, 'REFRESH.REVOKE_FAMILY',
      'UPDATE REFRESH_TOKENS SET REVOKED_AT = :REVOKED_AT WHERE TENANT_ID = :TENANT_ID ' +
      'AND FAMILY_ID = :FAMILY_ID AND REVOKED_AT IS NULL')
    .Add(DIR, 'REFRESH.REVOKE_USER',
      'UPDATE REFRESH_TOKENS SET REVOKED_AT = :REVOKED_AT WHERE TENANT_ID = :TENANT_ID ' +
      'AND USER_ID = :USER_ID AND REVOKED_AT IS NULL')
    .Add(DIR, 'JWT_KEY.BY_TENANT',
      'SELECT KID, SECRET, GENERATION, CREATED_AT, ACTIVE_FROM FROM JWT_KEYS ' +
      'WHERE TENANT_ID = :TENANT_ID')
    .Add(DIR, 'JWT_KEY.INSERT',
      'INSERT INTO JWT_KEYS (TENANT_ID, GENERATION, KID, SECRET, CREATED_AT, ACTIVE_FROM) ' +
      'VALUES (:TENANT_ID, :GENERATION, :KID, :SECRET, :CREATED_AT, :ACTIVE_FROM)')
    .Add(DIR, 'JWT_KEY.DELETE', 'DELETE FROM JWT_KEYS WHERE TENANT_ID = :TENANT_ID AND KID = :KID')
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
  SetLength(Result, 4);
  Result[0] := Item(1, 'MIG.0001');
  Result[1] := Item(2, 'MIG.0002');
  Result[2] := Item(3, 'MIG.0003');
  Result[3] := Item(4, 'MIG.0004');
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
      LQuery.Params.Flags['SUSPENDED'] := LTenants[I].Suspended;
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
