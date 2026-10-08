{ Shared compiler directives (dual Delphi / Free Pascal).

  Every unit of the library includes this file right after 'unit ...;'. On
  Delphi it doesn't change the mode; on FPC it enables Delphi mode (long
  strings, Delphi-style generics, advanced records).

  PASCALAPI_WINDOWS: defined when the target is Windows, on either compiler
  (Delphi defines MSWINDOWS; FPC defines WINDOWS). }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

{$IFDEF MSWINDOWS}
  {$DEFINE PASCALAPI_WINDOWS}
{$ENDIF}
{$IFDEF WINDOWS}
  {$IFNDEF PASCALAPI_WINDOWS}
    {$DEFINE PASCALAPI_WINDOWS}
  {$ENDIF}
{$ENDIF}

{ PASCALAPI_FUNCREFS: the library's public callbacks are "reference to" on
  Delphi (they accept a closure OR a method). FPC 3.2.2 (stable) has no
  "reference to", so the same types become "of object" there: the portable
  subset is "pass a method". With an FPC that has function references
  (trunk/3.3+), define PASCALAPI_FPC_FUNCREFS in the project to get the
  Delphi API. Same pattern as PASCALDB_FUNCREFS (pascal-db-faa) and Horse's
  HORSE_FPC_FUNCTIONREFERENCES. }
{$IFNDEF FPC}
  {$DEFINE PASCALAPI_FUNCREFS}
{$ELSE}
  {$IFDEF PASCALAPI_FPC_FUNCREFS}
    {$MODESWITCH FUNCTIONREFERENCES}
    {$MODESWITCH ANONYMOUSFUNCTIONS}
    {$DEFINE PASCALAPI_FUNCREFS}
  {$ENDIF}
{$ENDIF}
