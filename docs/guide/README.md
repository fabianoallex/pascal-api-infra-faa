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
| [Rate limiting](rate-limiting.md) | a client may make so many requests a minute: the window, the key (behind a proxy too), a limit per client, the headers and the 429 |
| [Database access](database.md) | handlers over a real database: the factory, migrations, SQL by key, paging and ordering in SQL, transactions, what the database's errors become |
| [Errors and validation](errors.md) | a request fails: the exceptions and their statuses, validating input, the database's errors, the client messages (English/Portuguese) |
| [Multi-tenancy](multitenancy.md) | one API serves several customers, each seeing only its own data |

## Planned

Each one gets a page of its own, written the same way. Until then, the
[README](../../README.md) ("A quick look"), the samples and the comment at the top of each unit
are the reference.

| Guide | Covers | Today, see |
|---|---|---|
| Logging and observability | the access log, trace context, metrics, health, spans to OpenTelemetry | `docs/observability-design.md` |
| OpenAPI | documenting routes and DTOs, Swagger UI | `docs/openapi-design.md` |
| MCP | the API's routes as tools for an AI client | `docs/mcp-design.md` |
| Messaging, Redis, IPC | the sibling libraries | `docs/related-libraries.md` |

## How a guide is written

So that every guide reads the same way, each one has these parts, in this order (a part that
has nothing to say is left out):

1. **What it solves**: the problem, in a paragraph, and what the library does about it.
2. **The smallest working program**: the few lines that turn it on.
3. **Step by step**: building a real application, one piece at a time.
4. **Choices**: the options, and when to pick each one.
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
