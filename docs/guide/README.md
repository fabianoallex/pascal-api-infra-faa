# Guides

How to build an API with pascal-api-infra-faa, one topic at a time. These pages are for the
people who use the library. The design documents next to this folder (`docs/*-design.md`) are
for the people who maintain it: they record why each decision was taken, and what was measured.
Read a guide to build something; read a design document when you want to know why it works the
way it does.

## Available

| Guide | Read it when |
|---|---|
| [Multi-tenancy](multitenancy.md) | one API serves several customers, each seeing only its own data |

## Planned

Each one gets a page of its own, written the same way. Until then, the
[README](../../README.md) ("A quick look"), the samples and the comment at the top of each unit
are the reference.

| Guide | Covers | Today, see |
|---|---|---|
| Getting started | the dependencies, a first Horse program, the middleware order, the samples | README, `samples/01-api` |
| Configuration | `TAppConfig`: environment, `.env`, defaults | `PascalApi.Config` |
| Errors and validation | the exceptions that become 400/404/409/500, the client messages (English/Portuguese) | `PascalApi.Http`, `samples/01-api` |
| Authentication | JWT (HS256) and Bearer, excluded paths, issuing a token | `PascalApi.Jwt`, `samples/01-api` |
| Rate limiting | the window, the key, a limit per request | `PascalApi.Horse.Middlewares` |
| Database access | pascal-db-faa from a handler: paging, ordering, filters, migrations | `samples/02-db` |
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
