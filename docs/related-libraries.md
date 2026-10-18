# Messaging, Redis and IPC: the sibling libraries

pascal-api-infra-faa has no messaging, cache or inter-process layer of its own. For those, an
API built on it **uses these libraries first**: same author, same dual-compiler rules (one
source for Delphi 12 and FPC 3.2.2), MIT, and the same base library (pascal-common-faa) the API
already has. Write something new only for a need none of them covers, and say why.

| The API needs | Use | Repository | Units | Lazarus package |
|---|---|---|---|---|
| A message broker: publish, consume with ack, RabbitMQ (AMQP 0-9-1); or a broker **inside** the program, without RabbitMQ (tests, one-machine products) | **pascal-amqp-faa** | https://github.com/fabianoallex/pascal-amqp-faa | `AMQP.*` | `pascal_amqp_faa` (client), `pascal_amqp_faa_server` (embedded broker) |
| Redis (or Valkey, KeyDB, Dragonfly): cache, counters, distributed locks, Pub/Sub, work queues with Streams and consumer groups | **pascal-redis-faa** | https://github.com/fabianoallex/pascal-redis-faa | `Redis.*` | `pascal_redis_faa` |
| Talk to another process: same machine (Named Pipe on Windows, Unix socket on Linux), TCP or TLS, with request/reply | **pascal-pipes-faa** (was pascal-named-pipes-faa) | https://github.com/fabianoallex/pascal-pipes-faa | `Pipes.*` | `pipes_faa` |

Versions when this page was written (2026-10-09): pascal-amqp-faa 0.1.2, pascal-redis-faa
0.1.2, pascal-pipes-faa 0.1.1; checked again on 2026-10-14 against 0.2.0, 0.2.0 and 0.1.1, and pascal-amqp-faa 0.4.1 and pascal-pipes-faa 0.3.0 on
2026-10-15 (use those or later: amqp 0.2.0 could fail to reconnect, silently, amqp 0.3.0 left a
message stuck when its consumer raised, 0.4.0 logged it without its trace id, and pipes 0.1.1
lost an exception raised in `OnMessage`, 0.2.0 reported it in Portuguese), for
[docs/guide/messaging.md](guide/messaging.md), which shows them **inside an API** (one client per
process, spans, what the API answers when the server is down), measured with `samples/04-messaging`. Each library's README is the source for its features and the
platforms it was validated on; check it before relying on a platform (pascal-pipes-faa, for
example, lists Delphi on Win64 and Android and FPC on Linux).

## Why not a layer here

Until 0.5.0 this library had `PascalApi.Messaging`: broker-agnostic interfaces (consumer,
publisher, handler) and a registry of adapters by name, ported from delphi-api-infra-faa. It was
removed in 0.6.0 (decided with the user, 2026-10-09): no adapter for it existed on FPC, no
program used it, and a contract with nothing behind it made each consumer write the adapter
before sending a single message. Putting pascal-amqp-faa in this library's package instead would
make every API link sockets, reader threads and TLS, even the ones without a queue. So: the
application references the library it needs, directly, and only then.

## Adding one to an API

As with this library's own dependencies: a **git submodule of the application** (one copy per
program, never `pascal-api-infra-faa/external/...`), plus the search path or the package.

```sh
git submodule add https://github.com/fabianoallex/pascal-amqp-faa external/pascal-amqp-faa
```

- **Delphi:** add the library's `src` to the search path. It needs pascal-common-faa's `src`,
  which an application of this library already has: keep **one** copy for all of them.
- **Lazarus:** require the library's `.lpk`; point its `pascal_common_faa` requirement at the
  application's copy (the same one `pascal_api_infra_faa.lpk` uses).
- Minimum pascal-common-faa: 1.8.0 for pascal-amqp-faa 0.2.0 and pascal-redis-faa 0.2.0 (their
  spans, `PascalCommon.Tracing`), 1.0 for Pipes; this library requires 1.16.0 (since 0.15.0), which covers them all
  (pascal-db-faa 0.13.0 needs 1.8.0). Their spans join
  the API's trace on their own once `TPcTracing.Start` runs: a Redis command or a publish made in
  a handler is a child of the request's server span, and an AMQP consumer continues the
  producer's trace from the message's `traceparent`.
- Callbacks in all three are `procedure ... of object` (FPC 3.2.2 has no anonymous methods):
  write a method of a class of yours, as for this library's middlewares.

## A first look

AMQP: publish, then consume with a manual ack (callbacks run on the library's thread pool, never
on the reader thread):

```pascal
uses AMQP.Connection, AMQP.Queue.Methods;

procedure TOrders.OnMessage(AChannel: TAMQPChannel; const ADelivery: TAMQPDelivery);
begin
  Process(ADelivery.BodyAsText);
  AChannel.Ack(ADelivery.DeliveryTag);   // at-least-once: ack after the work
end;

  LConn := TAMQPConnection.Create(TAMQPConnectionParams.Localhost);
  LConn.Open;
  LChan := LConn.CreateChannel;
  LChan.DeclareQueue(TAMQPQueueDeclare.Create('orders'));
  LChan.PublishText('', 'orders', '{"id":1}');
  LChan.Consume('orders', LOrders.OnMessage);
```

Redis, through `TRedisClient` (a pool inside, safe to share across Horse's threads; a
`TRedisConnection` is one socket, for one thread):

```pascal
uses Redis.Types, Redis.Client, Redis.Commands.Strings;

  GRedis := TRedisClient.Create(RedisDefaultParams);   // localhost:6379; at startup
  ...
  GRedis.Strings.SetEx('session:42', 3600, LToken);
  if not GRedis.Strings.TryGet('session:42', LValue) then ...
```

Pipes (another process on the same machine):

```pascal
  Server := TPipeServer.Create('my_app');
  Server.OnMessage := MyHandler.HandleMessage;
  Server.Listen;

  Client := TPipeClient.Create('my_app');
  Client.Connect(5000);
  Reply := Client.RequestText('ping', 3000);   // request/reply with a timeout
```

These are sketches: the libraries' READMEs have the full API (confirms, reconnection, TLS,
pools, pipelines, transactions, consumer groups, discovery, compression).

## Keeping this page right

The index of every `*-faa` library is the `dual-compiler-delphi-lazarus` skill's
`references/faa-libraries.md`. When one of these three changes name, repository or minimum
pascal-common-faa, update that index and this page together.
