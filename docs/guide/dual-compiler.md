# Your project on both compilers

How to keep **your** application building and passing its tests on Delphi and on Lazarus/FPC
3.2.2, from one source tree. The libraries already do this for their own code; this guide is
about the code you write around them: the folder layout, the project files, the rules for the
code, the tests and CI.

The model is this repository: its samples are applications that build on both compilers, and
its tests run on both. Each step points at the file to copy. The general rules, with the
measurement behind each one, are in the `dual-compiler-delphi-lazarus` skill (see
[Working with Claude Code](#working-with-claude-code)); this guide doesn't repeat its catalog.

## What it solves

The libraries hide most of the differences between Delphi and FPC: JSON goes out as UTF-8 on
both, callbacks take a method on both, time and threads go through pascal-common-faa. What they
can't do is keep your own units portable. A single anonymous method, a `.Split`, a public
property you expected the mapper to see, and one of the two builds breaks, or worse, compiles and
behaves differently.

None of it is hard on its own. What makes it hard is that each difference shows on one compiler
only, often at run time, so it is found late unless the project is set up from day one to build,
test and run on both. That setup is what this guide gives you.

What stays with you: deciding which compilers and platforms you ship (Delphi Win32/Win64, FPC on
Windows and Linux), and running the Delphi side by hand if you use Delphi Community Edition.

## The smallest working layout

```
my-api/
  src/
    myapi.inc                 compiler and platform defines, included by every unit
    MyApi.Cities.pas          your units: one source for both compilers
  MyApi.dpr                   the program: one file, compiled by both
  MyApi.dproj                 Delphi project (Win32 and Win64 declared)
  MyApi.lpi                   Lazarus project, pointing at MyApi.dpr
  tests/Unit/
    MyApi.CitiesTests.pas     DUnitX master, written in FPCUnit's assertion dialect
    MyApi.DUnitXCompat.pas    FPCUnit's assertions on top of DUnitX
    MyApi.UnitTests.dpr/.dproj
    fpc/                      the FPCUnit mirror and its runner (.lpr/.lpi)
  external/                   the libraries and Horse, as git submodules, one copy each
  tools/                      build and test scripts, the same ones CI runs
  .gitattributes              * text=auto eol=lf
  CLAUDE.md                   your project's decisions (encoding, versions, how to test)
```

`samples/01-api` is the program part of this (`ApiSample.dpr`, `.dproj`, `.lpi`), and the
repository root is the rest (`src/pascalapi.inc`, `tests/Unit`, `tools/`, `.gitattributes`).

## Step by step

### 1. Decide a few things at the start

Each of these is cheap to decide on day one and expensive to change later. Write the answers
down (in `CLAUDE.md` or `CONTRIBUTING.md`) so every developer and every IDE follows them:

- **The FPC mode: `{$MODE DELPHI}{$H+}`.** The libraries and Horse use it, and it keeps FPC as
  close to Delphi as possible. `{$mode objfpc}` is the other choice, for code that needs
  generics everywhere (see [Choices](#choices)).
- **Source encoding: UTF-8 with a BOM** for any `.pas`/`.dpr` with a non-ASCII literal. Without
  the BOM, Delphi reads the file as ANSI. Or keep the source pure ASCII; either way, decide.
- **Line endings: LF**, enforced by `.gitattributes` (this repository's has one line,
  `* text=auto eol=lf`). Both compilers read LF, and mixed endings make huge diffs between
  machines.
- **The versions you test with**: this repository uses Delphi 12 and FPC 3.2.2 (Lazarus for
  the IDE and `lazbuild`). Older Delphi versions weren't checked.

### 2. Add the dependencies, one copy each

Every library and Horse go into your repository once, as git submodules, and both compilers
read the same copies. [Getting started](getting-started.md), step 1, has the commands, the
minimum versions, and the Delphi search path and Lazarus packages for an API.

Two rules that hold for any project on these libraries:

- **Never point at a copy inside a library's `external/`.** Those are that library's own test
  dependencies. Clone with `git submodule update --init`, without `--recursive`.
- **On Lazarus, every package line names its copy**: `DefaultFilename` with `Prefer="True"`,
  `pascal_common_faa` first. Without `Prefer`, lazbuild silently builds against the copy
  registered in the IDE, which may be another version. From `samples/01-api/ApiSample.lpi`:

```xml
<Item>
  <PackageName Value="pascal_common_faa"/>
  <DefaultFilename Value="..\..\external\pascal-common-faa\packages\pascal_common_faa.lpk" Prefer="True"/>
</Item>
```

### 3. One include file for your units

Every unit of yours starts with `{$I myapi.inc}` right after `unit X;`. The file sets FPC's
mode and gives you one platform define, because Delphi defines `MSWINDOWS` and FPC defines
`WINDOWS`. From `src/pascalapi.inc`, renamed:

```pascal
{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

{$IFDEF MSWINDOWS}
  {$DEFINE MYAPI_WINDOWS}
{$ENDIF}
{$IFDEF WINDOWS}
  {$IFNDEF MYAPI_WINDOWS}
    {$DEFINE MYAPI_WINDOWS}
  {$ENDIF}
{$ENDIF}
```

The rest of your code tests `MYAPI_WINDOWS` and `FPC`, never `MSWINDOWS` alone. The program
file (`.dpr`) doesn't include it: it starts with `{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}`
itself, as every sample does.

### 4. The project files

- **One `.dpr` for both compilers.** The `.lpi` names it as its main unit
  (`<Filename Value="ApiSample.dpr"/>` in `samples/01-api/ApiSample.lpi`), and its `<Target>`
  sets the executable's name. You need a separate `.lpr` only when the two compilers need
  different program code, like the FPCUnit runner ([Testing your application](#testing-your-application)).
- **Declare Win32 and Win64 in the `.dproj` from the start.** A `.dproj` that Delphi 12 CE
  creates for a bare `.dpr` lists Win32 only, and the IDE then offers no way to add Win64.
  Start from `samples/01-api/ApiSample.dproj` (`<Platform value="Win64">True</Platform>`) or
  from the skill's scaffold (below).
- **Output folders per compiler and platform** (`.\$(Platform)\$(Config)` in the `.dproj`,
  `lib\$(TargetCPU)-$(TargetOS)` in the `.lpi`), so the two builds never read each other's
  compiled units.
- **A project group for each IDE**, when you have more than one project: `.groupproj` for
  Delphi, `.lpg` for Lazarus. Every new project goes into both, or it silently drops out of
  "build all".

For a new console program, the skill's `scripts/scaffold_dual_project.py new --name MyApi`
writes the `.inc`, a starter unit, the `.dpr`/`.dproj`, the `.lpi` and both groups (console
programs only, names without dots). Open what it generated once in each IDE before relying on it.

### 5. The program file

The first lines of every sample's `.dpr` (`cthreads`/`cwstring` on Unix,
`SetMultiByteConversionCodePage(CP_UTF8)` on FPC) and why each one is there are in
[Getting started](getting-started.md), step 2. They are the same for any program on these
libraries, API or not.

### 6. Write code that compiles on both

The rules this repository follows in every unit, each because one compiler lacks the feature or
does it differently. The skill's `references/rtl-gotchas.md` has the full list, with the case
where each was found.

| Don't | Do | Why |
|---|---|---|
| anonymous methods, `TThread.CreateAnonymousThread`, `TTask.Run` | a method of an object; a `TThread` subclass; pascal-common-faa's `PcPool` | FPC 3.2.2 has no anonymous methods and no `System.Threading` |
| `.Split`, `.StartsWith`, `.Substring` (string helpers) | `Pos`, `Copy`, `Trim` | not every FPC mode has the same helpers |
| `uses System.SysUtils` | `uses SysUtils`; a Delphi-only unit inside `{$IFNDEF FPC}` | FPC doesn't resolve unit scope names by default |
| inline `var` in a block | the routine's `var` section | FPC's inline-var support is more limited |
| public properties in a DTO; custom attributes | `published` properties under `{$M+}` | FPC 3.2.2's RTTI sees only published members, and has no attributes ([DTOs and JSON](dtos-json.md)) |
| `Length(S)` to size text that leaves the process | the UTF-8 byte count | `Length` counts UTF-16 units on Delphi and bytes on FPC |
| `Res.Send(string)` for JSON | `TJsonSend.Send` | accented text broke on Delphi only ([Getting started](getting-started.md), step 3) |
| `Now`, `Sleep` to measure or wait | pascal-common-faa's `TClock` and `TTicker` | replaceable in tests, the same on both |
| `TryStrToInt` on input | `ParseQueryInt` (or digits only) | on FPC 3.2.2 it wraps around and reads `$3`, `0x3`, `+3` |
| a `finalization` without an `initialization` | an empty `initialization` before it | Delphi refuses it; FPC accepts it, so only the Delphi build tells you |

A callback type of your own follows the libraries' pattern: `reference to` on Delphi, `of object`
on FPC (`PASCALAPI_FUNCREFS` in `src/pascalapi.inc`), so a method works on both
([Getting started](getting-started.md), step 8).

When something compiles on one side and not the other, look it up in the skill before working
around it: the fix is often already recorded, with the version where it applies.

### 7. Build both, often

A difference found the day it is written is a one-line fix; found at release, it is a hunt. Build
on both compilers before every commit that touches shared code, not at the end:

- **FPC**: `lazbuild MyApi.lpi`, from a script. Redirect its output to a file
  (`> build.log 2>&1`); never pipe lazbuild into `head`, which hung the compiler. After a change
  to how a unit is found (from a search path to a package, for example), delete the project's
  `lib/` folder: an old `.ppu` there survived `lazbuild -B` (measured in pascal-db-faa).
- **Delphi**: the IDE. Delphi Community Edition can't build from the command line, so this side
  is manual; the executable it produces can then be run from a script.

## Choices

### `{$MODE DELPHI}` or `{$mode objfpc}`

`{$MODE DELPHI}` is the default, and what every `*-faa` library and Horse use. `{$mode objfpc}`
fits code that needs generics throughout its API, at a price: every generic declaration and
every specialization takes an `{$IFDEF FPC}generic{$ENDIF}` / `{$IFDEF FPC}specialize{$ENDIF}`
prefix, and a method assigned to an event needs an explicit `@`. The skill's "MODE DELPHI vs
objfpc" section has the real example.

### One `.dpr`, or a `.dpr` and a `.lpr`

One `.dpr` when the program is the same on both (every sample here). Two files when the program
code differs, like a test runner that opens a GUI on Lazarus. Two program files with the same name
in one folder fight over `<name>.res`: each IDE rewrites it. Give them different names
(the `.lpi`'s `<Target>` keeps the executable's name).

### Generate the FPCUnit mirror, or keep both by hand and check them

This repository generates the mirror (`tools/gen_fpc_mirror.py`), so a test exists on both sides
by construction. The skill's `scripts/verify_test_mirrors.py` is the alternative for two suites
written by hand: it reports a test without its mirror, a fixture not registered, an assertion
from the wrong dialect. Generating is less work once set up; checking fits a project that already
has two suites.

### A Windows Service

A service host is inherently single-platform: keep the application's core dual-compiler, run it
from a console host (systemd on Linux), and wrap it in a Delphi-only `TService` for Windows. The
skill's `references/background-service-hosting.md` has the pattern and the service's own traps
(its working folder is `System32`, `OnStart` can't block).

## Pitfalls

- **Testing on Windows only.** A suite green on Windows hid three problems that the first Linux
  run showed at once in pascal-db-faa (missing `cwstring`, a flaky concurrency test, dates
  parsed in the machine's format). Run the FPC suite on Linux early, even before CI: a Docker
  image with FPC is enough.
- **heaptrc on Linux prints nothing.** Its summary doesn't reach the console there: a leaking
  program exits 0 and looks clean. Run with `HEAPTRC="log=<file>"` and check the file for
  `0 unfreed memory blocks`, as `tools/test_fpc_docker.sh` does.
- **A DUnitX test that never runs.** `[Test]` on a method outside `public`/`published` compiles
  and is silently skipped. And DUnitX's `Assert.AreEqual` on strings ignores case by default,
  while FPCUnit's doesn't: the compat adapter below passes case-sensitive explicitly.
- **A test program named like one of its units.** Delphi refuses it: name the program
  `MyApi.UnitTests`, not after a test unit.
- **The wrong copy of a package.** "It builds but behaves like the old version" on Lazarus
  usually means a package line without `Prefer="True"` (step 2). The `-Fu` paths in lazbuild's
  log say which copy was compiled.
- **Console text in the wrong code page.** Accents written with `Writeln` from threads, or to a
  redirected output (Docker, systemd), came out cut or garbled: log through pascal-common-faa's
  `SafeWriteln` with `PcSetSafeLogUtf8(True)`, as the samples do.
- **The `.dfm`/`.lfm` of a form.** Two files kept by hand, and each IDE rewrites the whole file
  on save. If your application has forms, read the skill's `references/forms-dfm-lfm.md` first;
  an API usually has none.

## Testing your application

### Unit tests: one body, two frameworks

Write each test once. The masters are DUnitX units, but their bodies use FPCUnit's assertions
(`AssertEquals`, `AssertTrue`), which a small adapter provides on Delphi
(`tests/Unit/PascalApi.DUnitXCompat.pas`: copy it and rename it). The FPCUnit mirror then
differs only in the fixture declarations, and `tools/gen_fpc_mirror.py` writes it:

| DUnitX master | FPCUnit mirror |
|---|---|
| `uses DUnitX.TestFramework, PascalApi.DUnitXCompat,` | `uses fpcunit, testregistry,` |
| `[TestFixture] TCityTests = class` | `TCityTests = class(TTestCase)` |
| `[Test] procedure Insert_Valid;` (public) | `procedure Insert_Valid;` (published) |
| `TDUnitX.RegisterTestFixture(TCityTests)` | `RegisterTest(TCityTests)` |

The script matches `PascalApi.DUnitXCompat` by name: when you copy it, change that name to
your adapter's (`tools/gen_fpc_mirror.py`, the `uses` substitution). Never edit a mirror by hand;
run the script, and run it with `--check` in CI so a stale mirror fails the build.

Two rules from the adapter's header: no `AssertEquals(Double, Double)` without a delta (FPC
resolves it to the `Currency` overload and compares 4 decimals, without a warning), and text
compared case-sensitive.

The FPCUnit runner (`tests/Unit/fpc/PascalApiUnitTestsFpc.lpr`) opens the GUI runner on Windows
when started with no parameters, and runs in the console with any (`--all --format=plain`),
which is what scripts and CI use. Its `.lpi` needs `FPCUnitTestRunner` and `FCL` in its
required packages (`fpc.cfg` doesn't bring in `fcl-fpcunit`), and `LCL` for the GUI runner:
`tests/Unit/fpc/PascalApiUnitTestsFpc.lpi` has the three.

**Acceptance on both sides: 0 errors, 0 failures, 0 leaks**: heaptrc on FPC (`-gh`, or
`UseHeaptrc` in the `.lpi`) and `ReportMemoryLeaksOnShutdown` on Delphi. Keep both: Delphi's
FastMM caught leaks heaptrc didn't, in another project of this family.

### Over HTTP, against both builds

Run the same HTTP scenarios against the Delphi executable and the FPC one. Several differences
in this repository showed only this way, never in a unit test: JSON with accents broken on
Delphi only, a raw header line Indy (Delphi) kept and fpWeb (FPC) cut. [Getting
started](getting-started.md), "Testing your application", has the model script.

### CI: the FPC side, on Linux

Keep the workflow file thin and the work in a script that also runs on your machine. This
repository's `.github/workflows/ci.yml` checks out the submodules and runs `sh tools/ci-test.sh`,
nothing else. The unit suite runs with plain `fpc` in a container, no Lazarus needed
(`tools/test_fpc_docker.sh`, shortened):

```sh
fpc -v0 -Mdelphi $P -FU/t/u -gh -gl -o/t/runner PascalApiUnitTestsFpc.lpr > /t/build.log 2>&1
HEAPTRC="log=/t/heap.txt" ./runner --all --format=plain > /t/run.log 2>&1 || true
grep -qE "^Number of errors: +0$" /t/run.log && grep -qE "^Number of failures: +0$" /t/run.log \
  && grep -qE "^0 unfreed memory blocks" /t/heap.txt
```

`$P` holds `-Fu`/`-Fi` for your `src` and each library's `src`. The skill's
`assets/github-actions-fpc-linux.yml` and `assets/ci-test.sh.example` are a starting point.

CI covers the FPC side only. The Delphi side (Win32 and Win64) is a step before each release:
build in the IDE, run the unit tests, run the HTTP scenarios against the executable. "CI is
green" says nothing about Delphi.

## Working with Claude Code

The rules above, and the measurements behind them, are packaged as Claude Code skills in
[pascal-skills-faa](https://github.com/fabianoallex/pascal-skills-faa). Install the plugin once,
at user scope, so it reaches every project of yours:

```
/plugin marketplace add fabianoallex/pascal-skills-faa
/plugin install pascal-skills-faa@pascal-skills-faa
```

Claude Code then loads the right skill when a task needs it, without being asked:

| Skill | Loads when you | What it brings |
|---|---|---|
| `dual-compiler-delphi-lazarus` | start a project for both compilers, write `{$IFDEF FPC}`, mirrored tests or CI, or find something that works on one compiler only | the project anatomy, the scaffold and mirror-check scripts, the RTL and RTTI gotcha catalogs with the case behind each entry, the index of the `*-faa` libraries |
| `using-faa-libraries` | add a `*-faa` library, hit a version or package error, or write a Horse API, DTOs, database or messaging code on them | one copy per application, the minimum-version matrix, what every FPC program does at startup, the shared thread pool, and which library doc to read first |

Two habits make them work better on your project:

- **Keep a `CLAUDE.md` with your project's decisions**: the encoding, the versions you test
  with, how to run each test, what CI covers and what it doesn't. This repository's
  [CLAUDE.md](../../CLAUDE.md) is an example. The skill gives the general rule; your file says
  which choice your project made.
- **Ask for both builds.** "Build and test on FPC; I'll build the Delphi side in the IDE" is a
  normal request on Delphi Community Edition, and the assistant can then run the Delphi
  executables you built.

The skills are not a porting tool: they are written for projects that are dual-compiler from the
start. On an existing Delphi-only codebase the gotcha catalog still helps, but expect work the
skill doesn't describe.

## Reference

- `samples/01-api`: `ApiSample.dpr` (one program file for both), `ApiSample.dproj` (Win32 and
  Win64, search path), `ApiSample.lpi` (packages with `Prefer`, `src/horse` and Horse on the
  paths).
- `src/pascalapi.inc`: the include file, with `PASCALAPI_WINDOWS` and `PASCALAPI_FUNCREFS`.
- `tests/Unit`: the DUnitX masters, `PascalApi.DUnitXCompat.pas`, the FPCUnit runner in `fpc/`.
- `tools/gen_fpc_mirror.py`, `tools/test_fpc.sh` (Windows), `tools/test_fpc_docker.sh` (Linux),
  `tools/ci-test.sh`, `.github/workflows/ci.yml`.
- The `dual-compiler-delphi-lazarus` skill: `SKILL.md`, `references/rtl-gotchas.md`,
  `references/rtti-gotchas.md`, `references/project-scaffolding.md`,
  `scripts/scaffold_dual_project.py`, `scripts/verify_test_mirrors.py`.
- The `using-faa-libraries` skill: `references/application-setup.md`.
- [pascal-dfe-broker](https://github.com/fabianoallex/pascal-dfe-broker): an application (not a
  library) on these libraries, with the same setup and a Windows Service host.
- The other guides: [index](README.md).
