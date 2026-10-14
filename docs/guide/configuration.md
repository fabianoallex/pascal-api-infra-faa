# Configuration

Settings such as a port, a secret, a database path or a collector's address: read from the
environment in production, from a `.env` file on a developer's machine, and from a default in
the code. The code comes from the samples. `PascalApi.ConfigTests` covers the lookup order and
the file format. The other behaviours below were measured with a probe program on
FPC 3.2.2/Windows for this guide (2026-10-14), and each one says so. None of those were measured
on Delphi.

## What it solves

The same executable runs on a developer's machine, in CI and in production. The differences
between those places (the secret, the database, where logs go) must not be compiled in. The
usual answer is environment variables, plus a file for development so nobody has to export
twenty variables by hand.

`TAppConfig` reads a setting from three places, in order, and returns the first one it finds:

1. the process environment;
2. a `.env` file in the executable's folder;
3. the default you pass in the code.

There is nothing to set up: the unit is ready when your program starts.

## The smallest working program

```pascal
uses
  PascalApi.Config;

var
  GPort: Integer;
  GSecret: string;

begin
  GPort := TAppConfig.GetInt('SERVER_PORT', 9000);
  GSecret := TAppConfig.Get('JWT_SECRET', 'development-secret-change-me');
  ...
end.
```

With no variable and no file, the port is 9000. A `.env` next to the executable changes it:

```
# .env
SERVER_PORT=9310
JWT_SECRET=a-long-random-value
```

and `SERVER_PORT=9400` in the environment overrides the file.

## Step by step

### 1. Read every setting at startup

Read the settings once, at the start of the program, into variables, and pass them on. From
`samples/03-tenants/TenantApiSample.dpr`:

```pascal
GDataDir := IncludeTrailingPathDelimiter(ExpandFileName(
  TAppConfig.Get('DATA_DIR', ExtractFilePath(ParamStr(0)))));
GSecret := TAppConfig.Get('JWT_SECRET', 'development-secret-change-me');
GClaim := TAppConfig.Get('TENANT_CLAIM', TENANT_DEFAULT_CLAIM);
...
GCatalog := TConfigTenantCatalog.Create(TAppConfig.Get('TENANTS', DEFAULT_TENANTS));
```

Reading everything in one place shows every setting the program has, and an invalid value
stops the program at startup, not at the first request that needs it (sample 03's tenant list
raises `ETenantCatalogError` there).

Give every setting a default that works on a developer's machine, except the ones that must
never have one in production (see [Pitfalls](#pitfalls)).

### 2. Typed values

```pascal
GPort := TAppConfig.GetInt('SERVER_PORT', 9000);
GVerbose := TAppConfig.GetBool('VERBOSE_LOG', False);
```

| Function | Value found | Result | Tested |
|---|---|---|---|
| `GetInt` | `9000` | 9000 | yes |
| `GetInt` | `abc` | the default, silently | yes |
| `GetInt` | absent | the default | yes |
| `GetBool` | `true`, `1`, `yes` (any case) | True | yes |
| `GetBool` | anything else (`false`, `on`, `0`) | **False, even when the default is True** | yes |
| `GetBool` | absent | the default | yes |

`GetBool` doesn't fall back to the default for a value it doesn't know: `VERBOSE=on` is False.
`GetInt` does, so a typo in a number goes unnoticed. If a wrong number must stop the program,
read it with `Get` and check it yourself.

### 3. Write the `.env` file

```
# Comments start with '#', at the beginning of the line.
SERVER_PORT=9310
JWT_SECRET="a value with spaces"
TENANTS=acme=dedicated,plan:gold;initech=shared
```

What the unit's tests check:

- one `KEY=VALUE` per line; blank lines and lines starting with `#` are skipped;
- the value is everything after the first `=` (`TENANTS` above keeps its own `=`);
- spaces around the key and the value are ignored: `PORT = 9000` is `9000`;
- a value wrapped in double or single quotes loses them, and keeps the spaces inside them:
  `NAME = "  two spaces  "` is `  two spaces  `;
- when a key repeats, the last line wins, as in a shell;
- an empty value counts as absent: `A=` then `A=later` is `later`, and `A=earlier` then `A=`
  gives the default;
- a comment after a value is part of the value: `A=value # comment` is `value # comment`
  (a `#` can be part of a password);
- keys in the file ignore case (`server_port` matches `SERVER_PORT`);
- UTF-8, with or without a BOM, with LF or CRLF line ends.

The shell's `export A=value` form isn't understood: no key matches it, so the default is used
(measured with the probe, FPC/Windows).

Until 0.13.0, spaces after `=` stayed in the value (`PORT = 9000` was ` 9000`) and the first
line of a repeated key won. Both were found while measuring for this guide, and fixed.

The file is read again on every call: the probe changed `A=1` to `A=2` between two calls and
the second call saw `2`. Settings you read at startup still need a restart (step 1); only code
that calls `TAppConfig.Get` while running sees the change. That also means each call opens and
reads the file, so don't call it for every request.

### 4. Where the file is

The default path is `.env` in the **executable's folder** (`ParamStr(0)`), not the current
directory: the probe, run with `C:\` as the current directory, still read the file next to the
executable. A service or a scheduled task, whose current directory is often
`C:\Windows\System32` or `/`, finds it the same way.

To use another file, call `SetEnvFile` before reading anything:

```pascal
TAppConfig.SetEnvFile('/etc/cities-api/cities-api.env');
```

No file is not an error: every setting then comes from the environment or the defaults.

### 5. The environment in production

In production, set the variables in the environment (Docker's `environment:`/`env_file:`, a
systemd unit's `Environment=`/`EnvironmentFile=`, a Windows service's environment) and leave no
`.env` next to the executable, or one with only harmless values. The environment wins over the
file (tested).

An empty variable counts as absent: the lookup goes on to the file and then the default. On
Linux, `JWT_SECRET=` in the environment doesn't clear a `JWT_SECRET` in the `.env` file.

How a variable's name matches depends on the operating system: Windows ignores case, Linux
doesn't. Write names in capitals everywhere. Only the keys inside the `.env` file ignore case on
every system.

### 6. The settings the library reads itself

| Variables | Read by | When |
|---|---|---|
| `LOG_DIR` (`logs`), `LOG_QUEUE_CAPACITY` (10000), `LOG_FLUSH_INTERVAL_MS` (200), `LOG_MAX_FILE_SIZE_MB` (2) | `PascalApi.FileLog`, for its default logger | in the unit's `initialization`, before your program's first line |
| `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, `OTEL_EXPORTER_OTLP_HEADERS`, `OTEL_EXPORTER_OTLP_TIMEOUT` | `TOtlpHttpExporter.FromEnvironment` (`PascalApi.Otlp`) | when you call it |
| `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`, `OTEL_TRACES_SAMPLER_ARG`, `OTEL_BSP_*` | pascal-common-faa's `TPcTracingOptions.FromEnvironment` | when you call it |

Two consequences:

- **The `LOG_*` settings are read before your code runs**, so they come from the environment or
  the default `.env` path. A `SetEnvFile` call in your program is too late for them. (This
  follows from the order of unit initialization; it wasn't measured.)
- **pascal-common-faa doesn't know `TAppConfig`.** Its `FromEnvironment` reads the process
  environment only, unless you pass `ReadAppConfig` as the lookup. Every sample does:

  ```pascal
  if TAppConfig.Get('OTEL_EXPORTER_OTLP_ENDPOINT', '') <> '' then
    TPcTracing.Start(TPcTracingOptions.FromEnvironment('pascal-api-sample-01', '1.0.0', ReadAppConfig),
      TOtlpHttpExporter.FromEnvironment, GCallbacks.LogError);
  ```

  Without `ReadAppConfig`, an `OTEL_SERVICE_NAME` in the `.env` file is ignored
  (`PascalApi.OtlpTests`, `TracingOptions_ReadAppConfig_ReadsTheConfig`, checks the lookup).

## Choices

### What goes in `.env`, and what doesn't

The `.env` file is for development. Keep it out of version control (`.gitignore`), and commit a
`.env.example` with every key and a harmless value, so a new developer knows what exists.

Secrets in production belong in the environment, set by whatever starts the program, or in
your platform's secret store, which puts them there.

### `Get` with a default, or a required setting

A default that works for development (`DATA_DIR` = the executable's folder) makes the program
start with no configuration at all, which is what you want for most settings. For a setting
that has no safe default, read it without one and stop if it's missing:

```pascal
GSecret := TAppConfig.Get('JWT_SECRET');
if GSecret = '' then
  raise Exception.Create('JWT_SECRET is not set.');
```

The samples use a development default for `JWT_SECRET` because they are samples.

## Pitfalls

- **A development secret in production.** `TAppConfig.Get('JWT_SECRET', 'development-secret-change-me')`
  starts without complaint when the variable is missing, and anyone who read the sample can
  sign tokens for your API. Make production secrets required (Choices).
- **FPC without `SetMultiByteConversionCodePage(CP_UTF8)`.** A `.env` file with any non-ASCII
  character makes **every** `Get` raise `ETextEncodingException`, naming the file and the call
  that fixes it (measured: the probe built without the call, a file with `São`). An all-ASCII
  file works either way. See [Getting started](getting-started.md), step 2.
- **A `.env` file that isn't UTF-8.** With the call in place, a file saved as Windows-1252
  (`S`, `E3`, `o`) was read without an error, and the value kept the raw byte `E3`, which is
  invalid UTF-8 (measured on FPC; Delphi not measured). Save `.env` files as UTF-8.
- **A comment after a value, or `export`.** See step 3: the first becomes part of the value,
  the second is never found, and neither gives an error.
- **`GetBool` with an unknown word** is False, whatever the default (step 2).
- **Calling `Get` in a hot path.** Each call reads the file (step 3).
- **Two settings for one thing.** The samples read `OTEL_EXPORTER_OTLP_ENDPOINT` to decide
  whether to start tracing, and the exporter reads it again. That's fine because both go
  through `TAppConfig`; a value read some other way (`GetEnvironmentVariable`) would miss the
  `.env` file.

## Testing your application

In tests, don't change the real environment: on Unix, FPC's `GetEnvironmentVariable` reads the
environment captured at startup, so a `setenv` made afterwards isn't seen. Replace both
sources instead, and put them back in the teardown. From `PascalApi.ConfigTests`:

```pascal
var
  GFakeEnv: TStringList;

function FakeEnvironment(const AName: string): string;   // a plain function
begin
  Result := GFakeEnv.Values[AName];
end;

procedure TAppConfigTests.Setup;
begin
  FSavedEnvPath := TAppConfig.EnvFilePath;
  TAppConfig.SetEnvFile(TempFolder + 'pascalapi_config_test.env');
  GFakeEnv := TStringList.Create;
  TAppConfig.SetEnvironmentReader(FakeEnvironment);
end;

procedure TAppConfigTests.TearDown;
begin
  TAppConfig.SetEnvironmentReader(nil);   // nil: the process environment again
  TAppConfig.SetEnvFile(FSavedEnvPath);
  FreeAndNil(GFakeEnv);
end;
```

`TAppConfig` is global, one per process, so tests that replace it must not run in parallel.

Over HTTP, start the program with the variables you want to test. The samples' scripts do this
with the environment (`OTEL_*` in CI), not with a `.env` file.

## Reference

- `PascalApi.Config`: the comment at the top of the unit (lookup order and file format).
- `PascalApi.ConfigTests`: the format, the order and the typed readers.
- `samples/03-tenants/TenantApiSample.dpr`: every setting read at startup (`DATA_DIR`,
  `JWT_SECRET`, `TENANT_CLAIM`, `TENANTS`, `CATALOG_TTL`, `DB_IDLE_SECONDS`).
- `PascalApi.FileLog` (the `LOG_*` variables) and `PascalApi.Otlp` (`OTEL_EXPORTER_OTLP_*`).
- [docs/observability-design.md](../observability-design.md): the `OTEL_*` variables.
