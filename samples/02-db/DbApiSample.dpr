program DbApiSample;

(* Sample 02: a Horse API over a real database, SQLite through pascal-db-faa
  (SQLdb on FPC, FireDAC on Delphi). One source for Delphi
  (DbApiSample.dproj) and Lazarus/FPC (DbApiSample.lpi).

    DbApiSample [port] [--reset]       (default port 9330)

  --reset deletes the database file first, so every run starts from the
  migrations. The file is DB_FILE (environment or .env), by default
  dbapi_sample.sqlite next to the executable. On FPC the SQLite client
  library is SQLITE_CLIENT, by default sqlite3.dll on Windows (it must be
  sqlite.org's build: pascal-db-faa's gotcha 23) and libsqlite3.so.0 on
  Linux; FireDAC links SQLite into the program.

  Routes:
    GET    /cities          paged: ?state=&page=&limit=&orderBy=name|-name|state|population
    GET    /cities/:code    404 when it doesn't exist
    POST   /cities          {"code":"4205407","name":"...","state":"SC","population":123}
                            201; 409 when the code exists (the database says so), 400 invalid
    DELETE /cities/:code    204; 404 when it doesn't exist

  On startup the migrations run (TDBMigrationEngine): SCHEMA_MIGRATIONS,
  CITIES and seed rows; a second start applies nothing. tools/http_scenarios_db.sh
  checks all of this over HTTP. *)

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}
  cthreads,
  cwstring,
  {$ENDIF}
  SysUtils,
  Horse,
  PascalCommon.Optionals,
  PascalJsonMapper.Mapper,
  PascalCommon.JsonMapper.Optionals,
  PascalDb.Interfaces,
  PascalDb.Paging,
  PascalDb.Migrations,
  PascalDb.Adapter.Base,
  {$IFDEF FPC}
  PascalDb.Adapter.SQLdb,
  {$ELSE}
  PascalDb.Adapter.FireDAC,
  {$ENDIF}
  PascalApi.Config,
  PascalApi.Pagination,
  PascalApi.Horse.Middlewares,
  DbApiSample.Cities in 'DbApiSample.Cities.pas';

var
  GFactory: IDBFactory;
  GCities: TCityRepository;

{ Handlers }

procedure GetCities(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LPage: TPage<ICity>;
begin
  LPage := GCities.FindPage(ParseQueryStr(AReq.Query['state']), AReq.Query['orderBy'],
    PageRequestFrom(ParseQueryInt(AReq.Query['page']), ParseQueryInt(AReq.Query['limit']), 2, 50));
  TJsonSend.Send(ARes, PageEnvelopeJson(LPage.Meta,
    TJsonMapper.Shared.Serialize<TCityArray>(LPage.Items)));
end;

procedure GetCity(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<ICity>(GCities.FindByCode(AReq.Params['code'])));
end;

procedure PostCity(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<ICity>(
    GCities.Insert(TJsonMapper.Shared.FromJson<ICityInsert>(AReq.Body))), 201);
end;

procedure DeleteCity(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  GCities.Delete(AReq.Params['code']);
  ARes.Status(204).Send('');
end;

{ Setup }

type
  TSampleLog = class
  public
    procedure Error(const ALine: string);
    procedure Migration(const AEvent: TMigrationEvent);
  end;

procedure TSampleLog.Error(const ALine: string);
begin
  Writeln('ERROR ', ALine);
end;

procedure TSampleLog.Migration(const AEvent: TMigrationEvent);
begin
  if AEvent.Kind = mekApplied then
    Writeln('migration ', AEvent.Version, ' ', AEvent.ScriptName);
end;

function NewFactory(const ADatabaseFile: string): IDBFactory;
var
  LConfig: IDatabaseConfig; // an interface variable, never a class one (pascal-db-faa's rule)
begin
  LConfig := TDatabaseConfig.Create;
  {$IFDEF FPC}
  LConfig.ConnectionParams.Values['ConnectorType'] := 'SQLite3';
  LConfig.ConnectionParams.Values['DatabaseName'] := ADatabaseFile;
  {$IFDEF UNIX}
  LConfig.ConnectionParams.Values['ClientLibrary'] := TAppConfig.Get('SQLITE_CLIENT', 'libsqlite3.so.0');
  {$ELSE}
  LConfig.ConnectionParams.Values['ClientLibrary'] := TAppConfig.Get('SQLITE_CLIENT', '');
  {$ENDIF}
  {$ELSE}
  LConfig.ConnectionParams.Values['DriverID'] := 'SQLite';
  LConfig.ConnectionParams.Values['Database'] := ADatabaseFile;
  {$ENDIF}
  LConfig.SQLDialect := 'SQLite';
  LConfig.SQLDirectory := 'SQLITE';
  LConfig.SqlSource := CitySqlSource;
  LConfig.PoolIniConnections := 1;
  LConfig.PoolMaxConnections := 5;
  LConfig.PoolWaitMaxAttemps := 50;
  LConfig.PoolWaitMilliseconds := 100;
  {$IFDEF FPC}
  Result := TSQLdbFactory.Create(LConfig);
  {$ELSE}
  Result := TFDFactory.Create(LConfig);
  {$ENDIF}
end;

var
  GLog: TSampleLog;
  GPort, I: Integer;
  GReset: Boolean;
  GFile: string;
  GEngine: TDBMigrationEngine;

begin
  {$IFDEF FPC}
  SetMultiByteConversionCodePage(CP_UTF8);
  {$ENDIF}
  GPort := 9330;
  GReset := False;
  for I := 1 to ParamCount do
    if ParamStr(I) = '--reset' then
      GReset := True
    else
      GPort := StrToIntDef(ParamStr(I), GPort);
  GFile := ExpandFileName(TAppConfig.Get('DB_FILE', ExtractFilePath(ParamStr(0)) + 'dbapi_sample.sqlite'));
  if GReset and FileExists(GFile) then
    DeleteFile(GFile);

  GLog := TSampleLog.Create;
  try
    GFactory := NewFactory(GFile);
    GEngine := TDBMigrationEngine.Create(GFactory, GLog.Migration);
    try
      GEngine.Execute(CityMigrations);
      Writeln('database ', GFile, ' at version ', GEngine.CurrentVersion);
    finally
      GEngine.Free;
    end;
    GCities := TCityRepository.Create(GFactory);

    TErrorHandlerMiddleware.Register(GLog.Error);
    THorse.Use(TLoggerMiddleware.New);
    THorse.Get('/cities', GetCities);
    THorse.Get('/cities/:code', GetCity);
    THorse.Post('/cities', PostCity);
    THorse.Delete('/cities/:code', DeleteCity);

    Writeln('DbApiSample listening on port ', GPort);
    THorse.Listen(GPort);
  finally
    GCities.Free;
    GFactory := nil;
    GLog.Free;
  end;
end.
