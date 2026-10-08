program PascalApi.UnitTests;

{ DUnitX runner for the unit tests. No network, no database: HTTP-facing code
  is tested through its pure parts and in-memory fakes.

  The sibling FPCUnit suite lives in tests/Unit/fpc, with the same coverage
  and identical test bodies: the files there are GENERATED from these by
  tools/gen_fpc_mirror.py (PascalApi.DUnitXCompat exists for that). Always
  edit the DUnitX masters here and regenerate the mirror. }

{$APPTYPE CONSOLE}
{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  DUnitX.TestFramework,
  PascalApi.Version in '..\..\src\PascalApi.Version.pas',
  PascalApi.Text in '..\..\src\PascalApi.Text.pas',
  PascalApi.Config in '..\..\src\PascalApi.Config.pas',
  PascalApi.OrderBy in '..\..\src\PascalApi.OrderBy.pas',
  PascalApi.Pagination in '..\..\src\PascalApi.Pagination.pas',
  PascalApi.RateLimitState in '..\..\src\PascalApi.RateLimitState.pas',
  PascalApi.FileLog in '..\..\src\PascalApi.FileLog.pas',
  PascalApi.Dto in '..\..\src\PascalApi.Dto.pas',
  PascalApi.Messaging in '..\..\src\PascalApi.Messaging.pas',
  PascalApi.DUnitXCompat in 'PascalApi.DUnitXCompat.pas',
  PascalApi.VersionTests in 'PascalApi.VersionTests.pas',
  PascalApi.ConfigTests in 'PascalApi.ConfigTests.pas',
  PascalApi.OrderByTests in 'PascalApi.OrderByTests.pas',
  PascalApi.PaginationTests in 'PascalApi.PaginationTests.pas',
  PascalApi.RateLimitStateTests in 'PascalApi.RateLimitStateTests.pas',
  PascalApi.FileLogTests in 'PascalApi.FileLogTests.pas',
  PascalApi.DtoTests in 'PascalApi.DtoTests.pas';

var
  runner: ITestRunner;
  results: IRunResults;
  logger: ITestLogger;
  nunitLogger: ITestLogger;
begin
  // Acceptance criterion on both sides: 0 leaks (FastMM here, heaptrc on FPC).
  ReportMemoryLeaksOnShutdown := True;
  try
    TDUnitX.CheckCommandLine;

    if TDUnitX.Options.Include = '' then
      TDUnitX.Options.Include := '.';

    runner := TDUnitX.CreateRunner;
    runner.UseRTTI := True;
    runner.FailsOnNoAsserts := False;

    if TDUnitX.Options.ConsoleMode <> TDunitXConsoleMode.Off then
    begin
      logger := TDUnitXConsoleLogger.Create(
        TDUnitX.Options.ConsoleMode = TDunitXConsoleMode.Quiet);
      runner.AddLogger(logger);
    end;

    nunitLogger := TDUnitXXMLNUnitFileLogger.Create(TDUnitX.Options.XMLOutputFile);
    runner.AddLogger(nunitLogger);

    results := runner.Execute;

    if not results.AllPassed then
      System.ExitCode := EXIT_ERRORS;

    if (TDUnitX.Options.ExitBehavior = TDUnitXExitBehavior.Pause) and IsConsole then
    begin
      System.Write('Done.. press <Enter> key to quit.');
      System.Readln;
    end;
  except
    on E: Exception do
      System.Writeln(E.ClassName, ': ', E.Message);
  end;
end.
