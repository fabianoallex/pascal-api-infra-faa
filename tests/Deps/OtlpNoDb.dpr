program OtlpNoDb;

{ Checks that PascalApi.Otlp builds without pascal-db-faa (0.28.0, asked by
  pascal-agenda-faa: a desktop client exports spans and has no database).

  The check is the search path, not the code: it has src,
  pascal-common-faa's src and pascal-jsonmapper-faa's src, and nothing else
  (no pascal-db-faa, no jsonmapper bridge, no Horse). A unit that brings
  pascal-db-faa back into PascalApi.Otlp (PascalApi.Http, say) stops this
  build with "Can't find unit PascalDb...". The code below only touches the
  public surface, so the program also runs, with 0 leaks.

  FPC: tools/test_fpc.sh (Windows) and tools/test_fpc_docker.sh (Linux, CI)
  build it with plain fpc and -gh. Delphi: OtlpNoDb.dproj in
  PascalApi.groupproj, Win32 and Win64; it only proves something when the
  IDE's Library Path doesn't have pascal-db-faa either. Exit code 1 on a
  failed check. }

{$IFDEF FPC}
  {$MODE DELPHI}{$H+}
{$ELSE}
  {$APPTYPE CONSOLE}
{$ENDIF}

uses
  SysUtils,
  PascalCommon.Tracing,
  PascalApi.HttpTypes,
  PascalApi.Otlp;

var
  GFailures: Integer = 0;

procedure Check(ACondition: Boolean; const AWhat: string);
begin
  if ACondition then
    Writeln('ok   ', AWhat)
  else
  begin
    Writeln('FAIL ', AWhat);
    Inc(GFailures);
  end;
end;

procedure Run;
var
  LHeaders: TArray<THttpHeader>;
  LResource: TArray<THttpHeader>;
  LBody: string;
  LExporter: IPcSpanExporter;
begin
  LHeaders := ParseKeyValueList('api-key=abc, x-team = desk');
  Check(Length(LHeaders) = 2, 'ParseKeyValueList reads two pairs');
  Check((Length(LHeaders) = 2) and (LHeaders[1].Name = 'x-team') and (LHeaders[1].Value = 'desk'),
    'ParseKeyValueList trims the pair');

  LResource := OtlpResourceAttributes('agenda-desktop', '1.0.0', '');
  Check((Length(LResource) > 0) and (LResource[0].Name = 'service.name')
    and (LResource[0].Value = 'agenda-desktop'), 'OtlpResourceAttributes starts with service.name');

  LBody := OtlpTracesJson(TPcTracingOptions.Default('agenda-desktop', '1.0.0'), nil);
  Check(Pos('"resourceSpans"', LBody) > 0, 'OtlpTracesJson builds a body');

  // Built, never sent: no collector here.
  LExporter := TOtlpHttpExporter.Create('http://127.0.0.1:4318/v1/traces', LHeaders, 1000);
  Check(LExporter <> nil, 'TOtlpHttpExporter is an IPcSpanExporter');
end;

begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  try
    Run;
  except
    on E: Exception do
    begin
      Writeln('FAIL ', E.ClassName, ': ', E.Message);
      Inc(GFailures);
    end;
  end;
  if GFailures = 0 then
    Writeln('PascalApi.Otlp without pascal-db-faa: ok')
  else
    Writeln('PascalApi.Otlp without pascal-db-faa: ', GFailures, ' failure(s)');
  if GFailures > 0 then
    Halt(1);
end.
