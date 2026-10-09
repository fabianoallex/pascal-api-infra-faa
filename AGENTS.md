# AGENTS.md

Instructions for AI coding agents. The full guide is [CLAUDE.md](CLAUDE.md); read it first.

## Sibling libraries come first

This library has no messaging, cache or inter-process layer. For those, use the author's
dual-compiler libraries (Delphi 12 + FPC 3.2.2, MIT, sharing pascal-common-faa with this one)
before writing anything new:

| Need | Library | Units |
|---|---|---|
| Message broker (RabbitMQ / AMQP 0-9-1), or a broker embedded in the program | [pascal-amqp-faa](https://github.com/fabianoallex/pascal-amqp-faa) | `AMQP.*` |
| Redis: cache, locks, counters, Pub/Sub, Streams | [pascal-redis-faa](https://github.com/fabianoallex/pascal-redis-faa) | `Redis.*` |
| Inter-process: Named Pipe / Unix socket, TCP, TLS | [pascal-pipes-faa](https://github.com/fabianoallex/pascal-pipes-faa) | `Pipes.*` |

How to add them and why there is no layer here: [docs/related-libraries.md](docs/related-libraries.md).
