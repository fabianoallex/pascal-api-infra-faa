unit PascalApi.Version;

{$I pascalapi.inc}

{ The library's version, as constants a consumer can test at compile time.

  A consumer that needs something added in a given version states it, so an
  older copy of pascal-api-infra-faa fails the build with a clear message
  instead of a missing identifier somewhere inside the consumer:

    (*$IF PASCALAPI_VERSION < 200*)
      (*$MESSAGE FATAL 'my-app needs pascal-api-infra-faa 0.2.0 or later'*)
    (*$IFEND*)

  (braces instead of the parenthesized form in real code), with
  PascalApi.Version in that unit's uses: a constant is only seen by the units
  that use the unit declaring it. Same format as PASCALCOMMON_VERSION
  (pascal-common-faa) and PASCALDB_VERSION (pascal-db-faa).

  Bump every constant here with each release, together with the version in
  packages/*.lpk, README.md and CHANGELOG.md. PascalApi.VersionTests checks
  that the constants agree with each other. }

interface

const
  PASCALAPI_VERSION_MAJOR = 0;
  PASCALAPI_VERSION_MINOR = 8;
  PASCALAPI_VERSION_PATCH = 0;

  /// major * 10000 + minor * 100 + patch: 0.1.0 is 100, 1.2.3 is 10203.
  PASCALAPI_VERSION = 800;

  PASCALAPI_VERSION_STRING = '0.8.0';

implementation

end.
