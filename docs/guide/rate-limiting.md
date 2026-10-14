# Rate limiting

How many requests a client may make in a time window, and what it gets when it makes more.
The code comes from `samples/01-api` and `samples/03-tenants`. `PascalApi.RateLimitStateTests`
covers the window with a manual clock, `PascalApi.HttpTests` the client's address, and
`tools/http_scenarios.sh` and `tools/http_scenarios_tenants.sh` the answers over HTTP. A few
behaviours below were measured with a probe program on FPC 3.2.2/Windows for this guide
(2026-10-14), and each one says so.

## What it solves

One client (a script in a loop, a misbehaving integration, someone trying passwords) can take
the capacity every other client needs. A rate limit counts each client's requests and refuses
the ones above a limit, with an answer that tells the client when to try again.

`TRateLimitMiddleware` keeps a **sliding window** per key: a request is refused when the key
already has `Limit` accepted requests in the last `WindowSeconds`. The key is the client's IP by
default, or whatever your function returns (a user, a tenant, an API key).

## The smallest working program

```pascal
THorse.Use(TLoggerMiddleware.New);
THorse.Use(TRateLimitMiddleware.New(60, 60));   // 60 requests a minute per IP
```

Every response then carries the window's state, and the 61st request within the minute is
refused:

```
HTTP/1.1 200
X-RateLimit-Limit: 60
X-RateLimit-Remaining: 59
X-RateLimit-Reset: 1792000102

HTTP/1.1 429
Retry-After: 42
{"error":"Rate limit exceeded. Try again in 42 second(s)."}
```

## Step by step

### 1. Choose the limit and the window

```pascal
GRateLimit := TRateLimitOptions.Default;   // 60 per 60 s, by IP, no proxy trusted
GRateLimit.Limit := 3;
GRateLimit.WindowSeconds := 60;
THorse.Use(TRateLimitMiddleware.New(GRateLimit));
```

The window slides: a slot comes back when the request that used it is `WindowSeconds` old, not
at the turn of the minute. A refused request uses no slot, so a client that keeps retrying
doesn't push its own wait further (tested: `OverLimit_TakesNoSlot`, `AfterWindow_FullQuotaBack`).

The window is measured with the monotonic `TTicker`, so a change of the system time (daylight
saving, NTP) neither extends nor shortens a block (tested: `WallClockMovesBack_*`,
`WallClockMovesForward_*`).

### 2. The headers and the 429

| Header | On | Value |
|---|---|---|
| `X-RateLimit-Limit` | every response | the key's limit |
| `X-RateLimit-Remaining` | every response | slots left in the window |
| `X-RateLimit-Reset` | every response | when the oldest request leaves the window, in Unix seconds |
| `Retry-After` | 429 only | seconds until then |

The 429's body is `TApiMessages.RateLimited`, with the seconds in it (English or Portuguese; see
[Errors and validation](errors.md), step 6). Sample 01's scenario checks the countdown, the 429
and that `Retry-After` is between 1 and 60:

```sh
for N in 2 1 0; do
  req GET /limited "" -H "$AUTH" -H 'X-Client: a'
  status_is 200 "limited, remaining $N"
  header_is X-RateLimit-Remaining "$N" "limited"
done
req GET /limited "" -H "$AUTH" -H 'X-Client: a'
status_is 429 "over the limit"
```

### 3. Behind a proxy: `ProxyHops`

With the default key, the client's address is the connection's peer. Behind a load balancer or a
reverse proxy, the peer is the proxy, and the client's address is in `X-Forwarded-For`, which the
proxy appends to. But a client can send that header too, with anything in it. So the library
trusts the header only as far as you say there are proxies:

```pascal
GRateLimit.ProxyHops := 1;   // one proxy in front of the API
```

How the address is found (`TrustedClientIp`, tested): the chain is `X-Forwarded-For`'s addresses
followed by the peer. From the right, each address is skipped while it is a proxy, that is one
of the `ProxyHops` you declared, or a loopback address (a proxy on the same machine, or the API
calling itself). The first address that isn't one is the client.

| Peer | `X-Forwarded-For` | `ProxyHops` | Key |
|---|---|---|---|
| `198.51.100.7` | `203.0.113.1` (sent by the client) | 0 | `198.51.100.7`: the header is ignored |
| `10.0.0.2` (your proxy) | `1.2.3.4, 203.0.113.7` | 1 | `203.0.113.7`: what your proxy appended |
| `10.0.0.2` | `1.2.3.4, 203.0.113.7, 10.0.0.1` | 2 | `203.0.113.7` |
| `127.0.0.1` (nginx on the same machine) | `1.2.3.4, 203.0.113.7` | 0 | `203.0.113.7` |
| unknown | anything | any | `unknown` |

Set `ProxyHops` to the number of proxies that append to the header, no more: one too many, and the
client's own first entry becomes the key again. Measured with the probe, `ProxyHops` 0, from a
non-loopback address: six requests with a new `X-Forwarded-For` each got 200, 200, 200, 429,
429, 429. **Until 0.13.0 the key was the header's first address**, and the same six requests
all got 200: anyone could escape the limit.

A tool call made through [the MCP endpoint](../mcp-design.md) comes back to the API from a
loopback address, with the caller's chain in `X-Forwarded-For` (the executor appends its peer, as
a proxy does), so it is counted under the caller's key (unit-tested; not checked over HTTP).

### 4. Your own key

When the IP isn't the right unit (users behind one office NAT share an IP; one user has many
IPs), pass a function. Sample 01 keys by a header, for its scenario:

```pascal
function TSampleCallbacks.ClientKey(AReq: THorseRequest): string;
begin
  Result := AReq.Headers['X-Client'];
  if Result = '' then
    Result := 'anonymous';
end;

GRateLimit.KeyExtractor := GCallbacks.ClientKey;
```

A header like `X-Client` is chosen by the client, so it is only for a sample. In an API, key by
something the client can't choose: the token's subject, after `TJwtMiddleware`
([Authentication](authentication.md)), or the tenant, as sample 03 does (step 6). The function
is a method on FPC ([Getting started](getting-started.md), step 8).

### 5. Only some routes

`THorse.Use` with a path limits only that path and what is below it. From sample 01:

```pascal
THorse.Use('/limited', TRateLimitMiddleware.New(GRateLimit));
TRouteDoc.Get('/limited')...Register(GetLimited);
```

(checked: `/cities/1` still answers 200 while `/limited` answers 429). There is **one
configuration per process**: a second `TRateLimitMiddleware.New` replaces the limit, the key
function and the counts for every place the middleware is used. Two paths with two different
limits need a key function that tells them apart and a `LimitFor` (step 6) that gives each its
limit.

### 6. A limit per client: `LimitFor`

`LimitFor` returns each request's limit; 0 or less falls back to `Limit`. Sample 03 gives each
tenant its own window, and the tenants on the free plan a smaller limit:

```pascal
function TSampleHooks.RateKey(AReq: THorseRequest): string;
var
  LInfo: TTenantInfo;
begin
  if TTenantMiddleware.TryCurrent(AReq, LInfo) then
    Result := 'tenant:' + LInfo.Id
  else
    Result := 'anonymous';
end;

function TSampleHooks.PlanLimit(AReq: THorseRequest): Integer;
var
  LInfo: TTenantInfo;
begin
  Result := 0; // the options' Limit
  if TTenantMiddleware.TryCurrent(AReq, LInfo) and (LInfo.Plan = 'free') then
    Result := FREE_LIMIT;
end;

THorse.Use(TJwtMiddleware.New(GSecret, [...]));
THorse.Use(TTenantMiddleware.New(GCatalog, GClaim));
// After the tenant: one window per tenant, its limit by plan.
GRateLimit := TRateLimitOptions.Default;
GRateLimit.Limit := DEFAULT_LIMIT;
GRateLimit.WindowSeconds := 60;
GRateLimit.KeyExtractor := GHooks.RateKey;
GRateLimit.LimitFor := GHooks.PlanLimit;
THorse.Use(TRateLimitMiddleware.New(GRateLimit));
```

`tools/http_scenarios_tenants.sh` checks it: a free tenant's 6th request in the minute is 429
with `X-RateLimit-Limit: 5`, another tenant has the default 1000, and a third, on the same shared
database, has its own window. The key and the limit must group requests the same way: two
requests with the same key and different limits share one window, judged by each one's limit.

## Choices

### Where in the chain

- **Before authentication**, keyed by IP: it also limits requests without a valid token,
  including login attempts. Put it right after the logger.
- **After authentication**, keyed by user or tenant: a fair share per customer, but requests
  refused by JWT aren't counted.

Both, for an API open to the internet, need two keys from one configuration (step 5): key by IP
when there is no token and by user when there is, in one function.

### One process or several

The counts are in the process's memory. Two instances behind a load balancer each allow the full
limit, and a restart starts every window over. For a limit shared by instances, the counts must
live elsewhere: Redis is the usual place, through
[pascal-redis-faa](../related-libraries.md); the library has no adapter for it today
(`IRateLimitState` is the contract one would implement).

### Memory

Each key in the window holds its requests' timestamps. Keys whose window is over are freed once
per window. Measured with the probe: one million keys, each seen once, then their window over,
then one more request: nothing left held (0 KiB). **Until 0.13.0 a key stayed forever**: the same
run held 231 MiB, and with the `X-Forwarded-For` hole of step 3 a client could grow it at will.
Memory now follows the keys seen in the last window, so a long window with many clients still
costs memory while it lasts.

## Pitfalls

- **Trusting a header the client writes.** `X-Forwarded-For` without `ProxyHops` (step 3), or a
  key function that reads `X-Client`, `X-Api-Key` without checking it, or any request header:
  each new value is a new window.
- **`ProxyHops` too high**, or set while the API is reachable without the proxy: the client's
  own entry becomes the key. Expose the API only through the proxy.
- **A second `New`** replaces the first configuration and starts every window over (step 5).
- **A route that doesn't exist** runs the global middlewares twice in Horse 3.3.12. The limit
  counts it once (checked over HTTP by `tools/http_scenarios_tenants.sh`). Until 0.13.0 it took
  two slots and sent the headers twice (measured with the probe).
- **Several instances** don't share counts (Choices).

## Testing your application

The window depends on time. Install a manual clock in `TClock` and `TTicker`, as
`PascalApi.RateLimitStateTests` does, and test the state without a server:

```pascal
procedure TRateLimitStateTests.Setup;
begin
  FT0 := EncodeDate(2025, 1, 1) + EncodeTime(12, 0, 0, 0);
  FClock := TManualClock.Create(FT0);    // IClock and ITicker, moved by SetTime
  FClockRef := FClock;
  TClock.SetClock(FClock);
  TTicker.SetTicker(FClock);
  FImpl := TRateLimitState.Create;
  FState := FImpl;
end;

procedure TRateLimitStateTests.AfterWindow_FullQuotaBack;
var
  LRem: Integer; LReset: Int64; LExc: Boolean;
begin
  FillBucket('ip1', 10, 60, 10);
  FClock.SetTime(FT0 + 61 / SECS_PER_DAY);
  FState.CheckAndRecord('ip1', 10, 60, LRem, LReset, LExc);
  TAssert.AssertEquals(9, LRem);
end;
```

(the teardown calls `TClock.Reset` and `TTicker.Reset`). Your key function is a plain function of
the request: test it with the values it reads. Over HTTP, use a small limit in a test
configuration, count down `X-RateLimit-Remaining`, and check the 429 and `Retry-After` (step 2).

## Reference

- `PascalApi.RateLimitState`: the sliding window, the sweep (comment at the top).
- `PascalApi.Http`: `TrustedClientIp`, `ForwardedForChain`, `RetryAfterSeconds`.
- `PascalApi.Horse.Middlewares`: `TRateLimitMiddleware`, `TRateLimitOptions`.
- `PascalApi.RateLimitStateTests`, `PascalApi.HttpTests`.
- `samples/01-api` (`/limited`) and `samples/03-tenants` (per tenant and plan);
  `tools/http_scenarios.sh`, `tools/http_scenarios_tenants.sh`.
