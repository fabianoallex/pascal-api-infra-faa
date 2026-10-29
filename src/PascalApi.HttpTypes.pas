unit PascalApi.HttpTypes;

{$I pascalapi.inc}

{ HTTP value types with no dependency at all, for units that need them
  without PascalApi.Http (whose implementation uses pascal-db-faa and
  pascal-jsonmapper-faa's mapper).

  PascalApi.Otlp takes its headers and resource attributes from here, so a
  program that only exports spans (a desktop client) builds without
  pascal-db-faa (0.28.0, asked by pascal-agenda-faa).
  tests/Deps/PascalApi.OtlpNoDb is the check: built with a search path that
  has no pascal-db-faa, by tools/test_fpc.sh, tools/test_fpc_docker.sh (CI)
  and in the Delphi IDE.

  PascalApi.Http declares THttpHeader as an alias of this one, so code that
  names it through PascalApi.Http doesn't change. Keep this unit's uses
  empty. }

interface

type
  THttpHeader = record
    Name: string;
    Value: string;
  end;

implementation

end.
