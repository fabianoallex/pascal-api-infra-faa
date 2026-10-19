# Guides

How to build an API with pascal-api-infra-faa, one topic at a time. These pages are for the
people who use the library. The design documents next to this folder (`docs/*-design.md`) are
for the people who maintain it: they record why each decision was taken, and what was measured.
Read a guide to build something; read a design document when you want to know why it works the
way it does.

## Available

| Guide | Read it when |
|---|---|
| [Getting started](getting-started.md) | you start an API: the dependencies, the program file, JSON out, errors, a DTO, paging, the middleware order, the samples |
| [Configuration](configuration.md) | settings from the environment, a `.env` file or a default; the variables the library reads |
| [Authentication](authentication.md) | routes need a token: JWT (HS256) or your own check, the open paths, issuing and reading a token |
| [Refresh tokens](refresh-tokens.md) | access tokens should be short: a refresh token used once, a copy that comes back ending the login, two refreshes at once, logout, ending every login of a user; the table a database store needs |
| [JWT signing keys and rotation](jwt-keys.md) | one secret is no longer enough: keys named by `kid`, rotating by themselves in a database or Redis, one per tenant, sealed under a master key; what to do when one leaks |
| [Rate limiting](rate-limiting.md) | a client may make so many requests a minute: the window, the key (behind a proxy too), a limit per client, the headers and the 429 |
| [Database access](database.md) | handlers over a real database: the factory, migrations, SQL by key, paging and ordering in SQL, transactions, what the database's errors become |
| [Logging and observability](observability.md) | the request id, the access line, the client's address, files, metrics, health, spans to OpenTelemetry |
| [OpenAPI](openapi.md) | documenting routes and DTOs, Swagger UI, authentication in the document; the limits a handler must still enforce |
| [MCP](mcp.md) | an AI client should call the API: the routes as tools, which ones, who may call, what a call returns |
| [DTOs and JSON](dtos-json.md) | request and response bodies: DTOs, absent/null/value (a PATCH), the query string, the database, the same DTOs on a queue or a pipe, what a bad body gets |
| [Errors and validation](errors.md) | a request fails: the exceptions and their statuses, validating input, the database's errors, the client messages (English/Portuguese) |
| [Multi-tenancy](multitenancy.md) | one API serves several customers, each seeing only its own data |
| [Messaging, Redis, IPC](messaging.md) | the API needs a cache, a queue or another process: the sibling libraries inside an API, threads, spans, a server that is down |
| [Your project on both compilers](dual-compiler.md) | your own code must build and pass its tests on Delphi and Lazarus/FPC: the layout, the project files, the rules, mirrored tests, CI, the Claude Code skills |

## How a guide is written

So that every guide reads the same way, each one has these parts, in this order (a part that
has nothing to say is left out):

1. **What it solves**: the problem, in a paragraph, and what the library does about it.
2. **The smallest working program**: the few lines that turn it on.
3. **Step by step**: building a real application, one piece at a time.
4. **Choices**: the options, and when to pick each one.
   **Procedures** (only where the topic has operations to run on a live API, as rotating or
   revoking keys): each one as numbered steps, with what is tested.
5. **Pitfalls**: what goes wrong silently, and how to avoid it.
6. **Testing your application**: what to check and how.
7. **Reference**: the units, the sample, the design document.

Rules:

- **Code comes from a sample that compiles and is tested**, shortened where it says so. A
  snippet nobody compiles goes out of date without anyone noticing.
- **One source for Delphi and FPC.** Where the two differ (callbacks are methods on FPC, for
  example), the guide says so where it happens.
- **A claim about behaviour is backed by a test, a scenario check or a measurement.** If it
  isn't, the guide says so.
- English, like the rest of the repository.
