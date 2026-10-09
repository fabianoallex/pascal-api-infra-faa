program PascalApiUnitTestsFpc;

{ FPCUnit runner for the unit tests. Same coverage as the DUnitX suite
  (tests/Unit/PascalApi.UnitTests.dpr): the fixtures in tests/Unit/fpc are
  generated from the DUnitX masters by tools/gen_fpc_mirror.py.

  Console (text output), when called with any parameter:
    .\PascalApiUnitTestsFpc.exe --all --format=plain
  GUI (test tree + green/red bar), with no parameters:
    .\PascalApiUnitTestsFpc.exe
  Outside Windows it always runs in console mode (no LCL/widgetset). }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  // Without cwstring, FPC on Unix converts WideString Variants back to string
  // one byte per character, ignoring the UTF-8 code page (measured in
  // pascal-db-faa; see the skill's rtl-gotchas.md, "Encoding").
  cwstring,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Interfaces, Forms, GuiTestRunner,
  {$ENDIF}
  Classes, consoletestrunner, testregistry,
  PascalApi.VersionTests,
  PascalApi.ConfigTests,
  PascalApi.OrderByTests,
  PascalApi.PaginationTests,
  PascalApi.RateLimitStateTests,
  PascalApi.FileLogTests,
  PascalApi.DtoTests,
  PascalApi.CryptoTests,
  PascalApi.HttpTests,
  PascalApi.OpenApiTests;

var
  ConsoleApp: TTestRunner;
begin
  // Plain FPC console: DefaultSystemCodePage isn't UTF-8 by default, and the
  // tests' non-ASCII literals would be transcoded wrongly.
  SetMultiByteConversionCodePage(CP_UTF8);

  {$IFDEF MSWINDOWS}
  if ParamCount = 0 then
  begin
    Application.Initialize;
    Application.CreateForm(TGUITestRunner, TestRunner);
    Application.Run;
  end
  else
  {$ENDIF}
  begin
    DefaultFormat := fPlain;
    DefaultRunAllTests := True;
    ConsoleApp := TTestRunner.Create(nil);
    try
      ConsoleApp.Initialize;
      ConsoleApp.Title := 'pascal-api-infra-faa - unit tests (FPCUnit)';
      ConsoleApp.Run;
    finally
      ConsoleApp.Free;
    end;
  end;
end.
