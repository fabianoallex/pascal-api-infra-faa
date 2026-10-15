# Messaging, Redis, IPC

How to use a message broker, Redis, or a channel to another process from an API built on this
library. The library has no layer of its own for these: an application uses the sibling libraries
directly, which share the same rules (one source for Delphi and FPC) and the same base,
pascal-common-faa. Which one does what, how to add it, and why there is no layer here are in
[docs/related-libraries.md](../related-libraries.md); this guide is about using them **inside an
API**: where the client lives, threads, spans, and what the API answers when the server behind
it is down.

**Where the code comes from.** The code below comes from
[samples/04-messaging](../../samples/04-messaging/MessagingSample.lpr) (the "probe" below), written for
this guide and run on FPC 3.2.2/Windows on 2026-10-14, against Redis 7.2 and RabbitMQ 3 in
Docker, with pascal-redis-faa 0.2.0 and pascal-amqp-faa 0.2.0; the reconnection measurements
(steps 4 and 6) were repeated on 2026-10-15 with pascal-amqp-faa 0.3.0, which fixed what 0.2.0
did there. Use **pascal-amqp-faa 0.3.0 or later**. Unlike samples 01-03 it is built
by hand (`sh samples/04-messaging/build_fpc.sh`, with your clones of the two libraries in
`REDIS_FAA` and `AMQP_FAA`), not by CI: those libraries aren't this repository's dependencies, so
it can go out of date; each library's own samples and tests are the reference. Delphi wasn't
tried. The Pipes part
wasn't run at all: pascal-pipes-faa supports FPC on Linux only, not on Windows, and says so.

## What it solves

An API often needs more than its database: a cache in front of a slow query, a counter or a lock
shared by several instances, work handed to a background process through a queue, a request to a
service on the same machine. Each needs a client that is safe on Horse's threads, joins the
request's trace, and fails in a way the API can answer.

## The smallest working program

Redis, as a cache shared by every request:

```pascal
uses
  Horse, Redis.Types, Redis.Client, Redis.Commands.Strings,
  PascalApi.Http, PascalApi.Horse.Middlewares;

var
  GRedis: TRedisClient;

procedure GetCache(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LKey, LValue: string;
begin
  LKey := 'probe:' + AReq.Params['key'];
  if GRedis.Strings.TryGet(LKey, LValue) then
    TJsonSend.Send(ARes, '{"hit":true,"value":"' + LValue + '"}')
  else
  begin
    LValue := UpperCase(AReq.Params['key']); // the "expensive" work
    GRedis.Strings.SetEx(LKey, 60, LValue);
    TJsonSend.Send(ARes, '{"hit":false,"value":"' + LValue + '"}');
  end;
end;

begin
  GRedis := TRedisClient.Create(RedisDefaultParams);   // a pool inside; no connection yet
  TErrorHandlerMiddleware.Register(GApp.Line);
  THorse.Use(TLoggerMiddleware.New(GApp.Line));
  THorse.Get('/cache/:key', GetCache);
  THorse.Listen(9420);
end.
```

(`GApp.Line` writes a line; see [Getting started](getting-started.md), step 8.) The first request
answered `{"hit":false,"value":"ABC"}`, the second `{"hit":true,"value":"ABC"}`. The JSON is built
by hand to keep the probe short; an application uses a DTO.

## Step by step

### 1. Add the library

As a git submodule of the application, with **one** copy of pascal-common-faa for everything
([docs/related-libraries.md](../related-libraries.md), "Adding one to an API"). The probe was built
with this repository's pascal-common-faa (1.8.1) and the two libraries' `src` on the search path.
A copy of pascal-common-faa older than a library needs stops the build with a message naming the
version (from the libraries' READMEs).

### 2. One client for the process, created at startup

Create the client before `THorse.Listen`, keep it in a global, and share it with every request:

- **Redis: `TRedisClient`**, a pool inside. Each command takes a connection and gives it back, so
  one client is safe across threads (pascal-redis-faa's README). Measured with the probe: 400
  requests to `/cache/:key`, 32 at a time, all 200, no error line. **Don't share a
  `TRedisConnection`**: it is one socket, and the unit of concurrency is the connection (the
  README). The sketch in
  `docs/related-libraries.md` used one, and it is fine in a single-threaded program only.
- **AMQP: one `TAMQPConnection`**, opened at startup, and a channel for publishing shared by the
  requests. Measured: 400 publishes from 32 request threads at once on one channel, all 202, and
  the consumer received all of them.
- **Pipes: one `TPipeClient`**. "Concurrent calls from multiple threads on the same client are
  supported" (pascal-pipes-faa's README; not measured here).

The pool belongs to the client: a command waits for a free connection (10 by default) and raises
`ERedisPoolExhausted` when none frees in time (pascal-redis-faa's README; not measured here).

### 3. Publish from a handler

```pascal
procedure PostOrder(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  // One channel shared by every request thread.
  GPublisher.PublishText('', GQueue, AReq.Body);
  TJsonSend.Send(ARes, '{"queued":true}', 202);
end;
```

**A plain publish returning means the bytes were written, not that the broker has them.**
Measured: with the RabbitMQ container paused, `POST /orders` still answered 202 in 5 ms (the
message arrived once the broker was unpaused; had the broker died, it would have been lost, which
wasn't measured). To
answer 202 only for a message the broker has taken, use publisher confirms. A channel in confirm
mode can be shared too: each request waits for its own sequence number.

```pascal
// At startup:
GConfirmed := GAmqp.CreateChannel;
GConfirmed.ConfirmSelect;

procedure PostOrderConfirmed(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LSeq: UInt64;
begin
  // Confirm mode: answer 202 only once the broker has taken the message.
  LSeq := GConfirmed.PublishText('', GQueue, AReq.Body);
  if not GConfirmed.WaitForConfirm(LSeq, 3000) then
  begin
    TErrorHandlerMiddleware.LogError(AReq, 'broker did not confirm publish ' + IntToStr(LSeq));
    raise EHttpException.Create(503, TApiMessages.Current.ServerBusy);
  end;
  TJsonSend.Send(ARes, '{"queued":true}', 202);
end;
```

Measured: 400 requests, 32 at a time, all 202; with the broker paused, 503 after the 3 s wait and
a log line (`broker did not confirm publish 401 trace_id=...`). **That message was still delivered
after the unpause**: a 503 here means "not confirmed in time", not "not sent". A client that
retries can send it twice, so the consumer must accept a message twice (AMQP is at-least-once
anyway; pascal-amqp-faa's README).

`TErrorHandlerMiddleware.LogError(AReq, ...)` writes through the callback given to
`TErrorHandlerMiddleware.Register`, ending with the request's id (the one `TLoggerMiddleware` set,
never a client's own `X-Request-Id`). `EHttpException` isn't logged by the error handler (it is
treated as an answer the client caused), which is why the handler logs first.

### 4. Consume in the same process (or another)

```pascal
procedure TApp.OnOrder(AChannel: TAMQPChannel; const ADelivery: TAMQPDelivery);
begin
  // On the library's thread pool; ack after the work.
  InterlockedIncrement(GConsumed);
  ...
  AChannel.Ack(ADelivery.DeliveryTag);
end;

// At startup, on its own channel (the queue was declared on GPublisher):
GConsumer := GAmqp.CreateChannel;
GConsumer.Consume(GQueue, GApp.OnOrder);
```

The callback runs on pascal-common-faa's thread pool (`PcPool`), several at a time, not on Horse's
threads and not in order (pascal-amqp-faa's README, "Concurrency and message ordering", which also
shows how to get ordering). It is a method (`of object`) on both compilers.

**With pascal-amqp-faa 0.2.0, declare the queue on the consuming channel too.** Measured there
with automatic reconnection on (`AutoReconnect := True`) and this non-durable queue declared only
on the publishing channel: after a broker restart the connection **never recovered**, and every
publish answered 500 for the 90 s the probe kept trying, with nothing in the log but those 500s.
0.2.0 replayed each channel's own topology, the consumer's first; its consume hit a queue the
restart had deleted, and each attempt failed silently. 0.3.0 replays the whole connection
(exchanges, queues, bindings, then consumers): measured with the code above, unchanged, publishing
worked again about 16 s after `docker restart` was issued and the consumer took every message
accepted after it. On 0.2.0 (the sample itself now needs 0.3.0), the declaration on the consuming channel too
recovered the same way; the sample's `declare-both` argument adds it.

### 5. Spans: one trace through Redis and the broker

With `TPcTracing.Start` called at startup (as in [Logging and observability](observability.md),
step 9), both libraries open spans on their own, under the request's server span. Measured with an
exporter that printed each span:

```
SPAN GET /cache/:key kind=server trace=5261f909...  span=5cf2f6bf61b8c7ff parent=
SPAN GET             kind=client trace=5261f909...  span=7f60f09e17c4a4ae parent=5cf2f6bf61b8c7ff
SPAN SETEX           kind=client trace=5261f909...  span=ca5d8c0c4504af81 parent=5cf2f6bf61b8c7ff
SPAN POST /orders    kind=server   trace=de6fd0a0...  span=d3a345758cbd58d6 parent=
SPAN publish amq.default kind=producer trace=de6fd0a0... span=8c986d67aeec3a32 parent=d3a345758cbd58d6
SPAN process probe-orders-... kind=consumer trace=de6fd0a0... span=93bb7bd018172276 parent=8c986d67aeec3a32
```

The Redis commands are children of the request. The publish is too, and the consumer's `process`
span continues the same trace from the message's `traceparent` header, so the request and the
work it queued show up as one trace. Redis's spans carry only the command and the first key
(`SET session:42 ?`), never the values (pascal-redis-faa's README).

### 6. When the server behind is down

Measured with the probe:

| What failed | What the handler raised | What the API answered |
|---|---|---|
| Redis unreachable (nothing on the port) | `ERedisConnectionLost` (after ~2 s per request, the connect attempt) | 500, fixed message, logged |
| RabbitMQ stopped, no `AutoReconnect` | `EAMQPConnection: connection closed by server: 320 CONNECTION_FORCED - broker forced connection closure with reason 'shutdown'` (0.2.0 raised `EWriteError: Stream write error`) | 500, and **still 500 after the broker came back**: the connection stays dead until the process restarts |
| RabbitMQ restarted, `AutoReconnect := True` | `EAMQPConnection: connection unavailable right now (reconnecting; connection closed by server: 320 ...; last attempt failed: end of stream while reading frame ...)` | 500 until reconnected (about 16 s after `docker restart`) |
| RabbitMQ paused, confirm mode | `WaitForConfirm` returned False | 503 (step 3) |

A 500 is the error handler's answer to an exception it doesn't know: the message stays in the log,
and the client gets `An unexpected error occurred.` with the request id
([Errors and validation](errors.md), step 4). **Turn on `AutoReconnect`** for a long-running API:
without it, one broker restart breaks publishing until the API restarts.

**Log the failed reconnection attempts.** With `MaxReconnectAttempts = 0` the library tries for
ever, so an attempt that keeps failing is only visible through `OnReconnectError` (or
`LastReconnectError`, the last one's reason, '' once reconnected), both new in pascal-amqp-faa
0.3.0. The sample logs each one:

```pascal
procedure TApp.OnReconnectError(AConnection: TAMQPConnection; AAttempt: Integer;
  const AError: string);
begin
  // On the library's thread; no request, so no request id.
  TErrorHandlerMiddleware.LogError(Format('AMQP reconnect attempt %d failed: %s',
    [AAttempt, AError]), '');
end;

// At startup, before Open:
GAmqp.OnReconnectError := GApp.OnReconnectError;
```

Measured during the restart above: six lines, `AMQP reconnect attempt 1 failed: end of stream
while reading frame (connection closed?)` and so on, one about every 2 s while the broker was
coming back, then none. `LastReconnectError` would also fit a readiness check
([Logging and observability](observability.md)); not tried here.

Where the server is optional, handle the failure in the handler. A cache is the usual case:

```pascal
procedure GetCacheOrCompute(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LKey, LValue: string;
begin
  // A cache is optional: when Redis can't answer, compute and log the reason.
  LKey := 'probe:' + AReq.Params['key'];
  try
    if GRedis.Strings.TryGet(LKey, LValue) then
    begin
      TJsonSend.Send(ARes, '{"hit":true,"value":"' + LValue + '"}');
      Exit;
    end;
  except
    on E: ERedisConnectionLost do
      TErrorHandlerMiddleware.LogError(AReq, 'cache unavailable: ' + E.ClassName + ': ' + E.Message);
    on E: ERedisTimeout do
      TErrorHandlerMiddleware.LogError(AReq, 'cache unavailable: ' + E.ClassName + ': ' + E.Message);
  end;
  LValue := UpperCase(AReq.Params['key']);
  TJsonSend.Send(ARes, '{"hit":false,"value":"' + LValue + '"}');
end;
```

Measured with Redis unreachable: 200 with the computed value, and the log line
`cache unavailable: ERedisConnectionLost: ... trace_id=<the request's id>`. Each request still
paid the ~2 s connect attempt; a shorter `ConnectTimeoutMs` in `TRedisParams` should shorten it
(not measured). Catch only the connection's failures: an `ERedisReplyError` or `ERedisTypeError`
is a bug or a wrong command, which a fallback would hide.

## Choices

### A queue or a direct call

A queue decouples the API from the work: the request answers 202 and the work happens later,
elsewhere, retried if it fails. The price is that the client doesn't get the result in the
answer, the work can run twice, and a broker joins the things that must be up. A direct call (an
HTTP request, a Pipes request/reply) is simpler when the answer is needed now.

### Plain publish or confirms

Plain publish costs nothing and loses messages when the broker dies at the wrong moment. Confirms
cost a round trip per request (a wait in the handler) and tell you when the broker didn't take the
message. For orders, payments, anything a user was told is "queued", use confirms.

### Redis or the database

Redis for what can be lost or rebuilt: a cache, a rate-limit count shared by instances
([Rate limiting](rate-limiting.md), "One process or several"), a short-lived lock or session. The
database for what must survive.

### Pipes or HTTP

pascal-pipes-faa talks to another process on the same machine (a Named Pipe on Windows, a Unix
socket on Linux) or over TCP/TLS, with request/reply and pub/sub. For a service on the same
machine that isn't an HTTP server (a device driver, a desktop program), it is the natural fit; for
another API, HTTP. Remember the platforms: Delphi on Windows, FPC on Linux.

## Pitfalls

- **A `TRedisConnection` shared by the request threads** instead of a `TRedisClient` (step 2).
- **A 202 after a plain publish** taken as "the broker has it" (step 3).
- **A retried 503 from a confirm timeout** sends the message twice: make the consumer idempotent.
- **No `AutoReconnect`**: one broker restart, and publishing fails until the API restarts (step 6).
- **pascal-amqp-faa 0.2.0 and a queue not declared on the consuming channel**: after a broker restart the connection never
  recovers, silently (step 4). Fixed in 0.3.0.
- **Reconnection attempts nobody logs**: with unlimited attempts, a reconnection that never
  succeeds shows only as 500s; log `OnReconnectError` (step 6).
- **A consumer callback that blocks forever** stalls the channel's shutdown (pascal-amqp-faa's
  README, "The consumer callback must always finish on its own").
- **A fallback that catches `ERedisException`**: it also hides bugs (step 6).
- **Values in the logs**: log the key, not the value; Redis values are often tokens or sessions.

## Testing your application

- **The handler's logic, without servers.** Put the Redis or broker calls behind an interface of
  your own (a cache, a publisher) and give the handler's code a fake, as this library's tests do
  for the MCP executor ([MCP](mcp.md), "Testing your application").
- **Against real servers.** Run Redis and RabbitMQ in containers, as those two libraries' own
  integration tests do (the `docker/` folder of each repository). Check the happy path, then stop or pause
  the container and check what the API answers (step 6), and that it recovers.
- **Concurrency.** Send requests in parallel (`xargs -P 32 curl ...`), as the probe did: a client
  that isn't safe across threads fails here first.

## Reference

- [docs/related-libraries.md](../related-libraries.md): which library does what, adding one,
  why there is no layer here.
- [pascal-redis-faa](https://github.com/fabianoallex/pascal-redis-faa): `TRedisClient`,
  `Redis.Commands.*`, the pool, timeouts, spans (README).
- [pascal-amqp-faa](https://github.com/fabianoallex/pascal-amqp-faa): `TAMQPConnection`,
  `TAMQPChannel`, confirms, reconnection, concurrency, spans (README).
- [pascal-pipes-faa](https://github.com/fabianoallex/pascal-pipes-faa): `TPipeServer`,
  `TPipeClient`, request/reply, threading guarantees (README).
- `PascalApi.Horse.Middlewares`: `TErrorHandlerMiddleware.LogError`.
