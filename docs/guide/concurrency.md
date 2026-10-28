# Lost updates and retries: If-Match and Idempotency-Key

Two clients changing one row, and one client sending the same POST twice. `PascalApi.Preconditions`
answers the first with the row's version as an `ETag` and `If-Match` (RFC 9110); `PascalApi.Idempotency`
answers the second with an `Idempotency-Key` whose first answer is stored and sent again. The
code comes from `samples/02-db` (`PUT /cities/:code` with `If-Match`, `POST /cities` with an
optional `Idempotency-Key`, on SQLite and PostgreSQL). `PascalApi.PreconditionsTests` and
`PascalApi.IdempotencyTests` cover the units (the second with a test clock in its arguments and
pascal-db-faa's mock for the database store); `tools/http_scenarios_db.sh` runs every case below
over HTTP, four requests at once included, on both databases. Both were first written and proven
in pascal-agenda-faa (changing and cancelling an appointment; booking one), and moved here in
0.23.0.

## What it solves

**A lost update.** Ana and Bruno read city 4314902 (version 1). Ana saves; Bruno saves a minute
later, from what he read, and Ana's change is gone without anyone knowing. With optimistic
concurrency every answer carries the row's version as `ETag: "1"`; a change sends it back as
`If-Match: "1"`, and the server writes only if the row is still at that version. Bruno gets a
**412** and reads again. No lock is held between the read and the write.

**A POST sent twice.** A client creates a city, the connection drops before the answer arrives,
and the client retries. Without help, the retry creates a second row (or, with a unique key, an
error for a request that worked). With `Idempotency-Key: <a UUID>` the first request claims the
key, runs, and its answer is stored; the retry gets that same answer, marked
`Idempotent-Replayed: true`, and nothing runs twice.

Neither needs a middleware: the version check needs the row, which only the handler reads, and
storing an answer needs the handler's response body, which Horse doesn't expose alike on both
compilers. They are calls in the handler.

## The smallest working program

`If-Match` on a change (the repository of sample 02, shortened):

```pascal
uses PascalApi.Preconditions;

function TCityRepository.Replace(const ACode, AIfMatch: string; const ACity: ICityReplace;
  out AVersion: Int64): ICity;
begin
  RequireIfMatchSent(AIfMatch);                  // 428 absent or "*", 400 not a tag list
  ...                                            // the body's rules (400)
  FindByCode(ACode, LRead);                      // 404
  RequireIfMatch(AIfMatch, VersionETag(LRead));  // 412: not the current version
  // UPDATE CITIES SET ..., VERSION = VERSION + 1 WHERE CODE = :CODE AND VERSION = :VERSION
  LRows := LQuery.ExecSql;
  if LRows = 0 then
    RaisePreconditionFailed;                     // 412: changed after the check
  Result := FindByCode(ACode, AVersion);
end;
```

`Idempotency-Key` on a POST (the handler of sample 02):

```pascal
uses PascalApi.Idempotency, PascalApi.Horse.Idempotency;

GIdempotency := TIdempotency.Create(TDbIdempotencyStore.Create(GFactory));
...
procedure PostCity(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LIdem: THorseIdempotentRequest;
  LInsert: ICityInsert;
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LVersion: Int64;
  LJson, LHeaders: string;
begin
  if LIdem.Start(GIdempotency, AReq, ARes, '') then
    Exit; // replayed
  try
    LInsert := THorseBody.Read<ICityInsert>(AReq);
    LScope := GFactory.GetPool.AcquireQuery(LQuery);
    LScope.StartTransaction;
    try
      LJson := TJsonMapper.Shared.ToJson<ICity>(GCities.InsertOn(LQuery, LInsert, LVersion));
      LHeaders := HeaderLines([HttpHeader('ETag', VersionETag(LVersion))]);
      LIdem.CompleteOn(LQuery, 201, LJson, LHeaders); // commits with the city
      LScope.Commit;
    except
      LScope.Rollback;
      raise;
    end;
  except
    on E: Exception do
    begin
      LQuery := nil;  // the connection back in the pool
      LScope := nil;
      LIdem.Fail(E);  // after the rollback
      raise;
    end;
  end;
  LIdem.Send(201, LJson, LHeaders);
end;
```

When the repository opens and commits its own transaction, or the keys' table is in another
database, store the answer after the commit instead (step 4):

```pascal
  try
    LJson := TJsonMapper.Shared.ToJson<ICity>(
      GCities.Insert(THorseBody.Read<ICityInsert>(AReq), LVersion)); // commits
    LHeaders := HeaderLines([HttpHeader('ETag', VersionETag(LVersion))]);
    LIdem.Complete(201, LJson, LHeaders);  // never raises (0.27.0)
  except
    on E: Exception do
    begin
      LIdem.Fail(E);
      raise;
    end;
  end;
  LIdem.Send(201, LJson, LHeaders);
```

## Step by step

### 1. A version on the row

Add a column every change moves up, and send it as the ETag:

```sql
-- MIG.0004
ALTER TABLE CITIES ADD COLUMN VERSION INTEGER DEFAULT 1 NOT NULL;
```

Every statement that changes the row adds `VERSION = VERSION + 1` (sample 02's `PATCH` too, so a
`PUT` from the version before a `PATCH` is a 412). Every answer that shows the row sends
`ETag: VersionETag(Version)`, which is the version in quotes (`"3"`), a strong validator. When a
list shows the version in its body, a client can build the tag from it.

### 2. The check, in this order

1. `RequireIfMatchSent(AReq.Headers['If-Match'])` before anything else: **428**
   `precondition_required` when it is absent (or `"*"`, see Choices), **400** `invalid_if_match`
   when it isn't a list of entity tags (`If-Match: 3`, without quotes).
2. The body's checks (400) and the read (404).
3. `RequireIfMatch(AHeader, VersionETag(LRead))`: **412** `precondition_failed` unless one of
   the tags is strongly equal to the current one. The message names the current ETag.
4. The write names the version read (`WHERE VERSION = :VERSION`). Zero rows: the row changed
   between 3 and 4, `RaisePreconditionFailed` (412).

Step 4 is what makes it safe: four `PUT`s from one version at once give one 200 and three 412 in
`tools/http_scenarios_db.sh`, on SQLite and on PostgreSQL.

What `If-Match` accepts (RFC 9110, sections 5.6.1 and 13.1.1): one or more entity tags separated
by commas, with blanks and empty elements (`"1", "3"`, ` , "3" ,, `); a weak tag (`W/"3"`) never
matches, since `If-Match` uses the strong comparison; `"3"` doesn't match `"31"`.

### 3. The keys' table

`TDbIdempotencyStore.Create(AFactory)` runs six statements by name from the factory's
`SqlLoader` (the names are parameters of the constructor, with these defaults). `TENANT_ID` is
the scope: the tenant's id, or `''` without tenants. Your application owns the migration; sample
02's, the same on SQLite and PostgreSQL:

```sql
-- MIG.0005
CREATE TABLE IDEMPOTENCY_KEYS (TENANT_ID VARCHAR(64) NOT NULL,
  IDEM_KEY VARCHAR(255) NOT NULL, FINGERPRINT CHAR(64) NOT NULL,
  DONE INTEGER DEFAULT 0 NOT NULL, LEASE_UNTIL BIGINT NOT NULL, EXPIRES_AT BIGINT NOT NULL,
  STATUS_CODE INTEGER DEFAULT 0 NOT NULL, RESPONSE_HEADERS VARCHAR(2000) DEFAULT '' NOT NULL,
  RESPONSE_BODY TEXT DEFAULT '' NOT NULL, CREATED_AT BIGINT NOT NULL,
  CONSTRAINT PK_IDEMPOTENCY_KEYS PRIMARY KEY (TENANT_ID, IDEM_KEY));
CREATE INDEX IX_IDEMPOTENCY_KEYS_EXPIRES ON IDEMPOTENCY_KEYS (TENANT_ID, EXPIRES_AT);

-- IDEMPOTENCY.PURGE
DELETE FROM IDEMPOTENCY_KEYS WHERE TENANT_ID = :TENANT_ID AND EXPIRES_AT <= :NOW
-- IDEMPOTENCY.CLAIM
INSERT INTO IDEMPOTENCY_KEYS (TENANT_ID, IDEM_KEY, FINGERPRINT, DONE, LEASE_UNTIL,
  EXPIRES_AT, CREATED_AT) VALUES (:TENANT_ID, :IDEM_KEY, :FINGERPRINT, 0, :LEASE_UNTIL,
  :EXPIRES_AT, :CREATED_AT) ON CONFLICT (TENANT_ID, IDEM_KEY) DO NOTHING
-- IDEMPOTENCY.BY_KEY
SELECT FINGERPRINT, DONE, LEASE_UNTIL, STATUS_CODE, RESPONSE_HEADERS, RESPONSE_BODY
  FROM IDEMPOTENCY_KEYS WHERE TENANT_ID = :TENANT_ID AND IDEM_KEY = :IDEM_KEY
-- IDEMPOTENCY.TAKE_OVER
UPDATE IDEMPOTENCY_KEYS SET LEASE_UNTIL = :LEASE_UNTIL WHERE TENANT_ID = :TENANT_ID
  AND IDEM_KEY = :IDEM_KEY AND DONE = 0 AND LEASE_UNTIL <= :NOW
-- IDEMPOTENCY.COMPLETE
UPDATE IDEMPOTENCY_KEYS SET DONE = 1, STATUS_CODE = :STATUS_CODE,
  RESPONSE_HEADERS = :RESPONSE_HEADERS, RESPONSE_BODY = :RESPONSE_BODY
  WHERE TENANT_ID = :TENANT_ID AND IDEM_KEY = :IDEM_KEY
-- IDEMPOTENCY.RELEASE
DELETE FROM IDEMPOTENCY_KEYS WHERE TENANT_ID = :TENANT_ID AND IDEM_KEY = :IDEM_KEY
  AND DONE = 0
```

- The times are Unix seconds. The claim is one transaction that starts with the purge (a
  write) and then the `INSERT`: one row is a claim; zero rows reads the key. On SQLite a
  transaction whose first statement is a read takes a shared lock that two writers can't both
  upgrade, hence the write first.
- `ON CONFLICT ... DO NOTHING` is the same on SQLite (3.24 and later) and PostgreSQL (9.5 and
  later); on another database, write that statement under its own SQL directory.
- `TAKE_OVER`'s `WHERE ... LEASE_UNTIL <= :NOW` lets one request only take over a lease that ran
  out.
- The tenant's expired keys go at each claim; nothing else deletes them.

### 4. The handler

`THorseIdempotentRequest` is a record on the handler's stack (the code above):

- `Start` reads `Idempotency-Key`. Absent or blank: the request runs as before, and
  `Complete`/`Fail` do nothing; with `ARequired` (0.24.0) it is a **400**
  `idempotency_key_required` instead, and the handler never runs without a key. Otherwise the key is claimed with the request's fingerprint (the
  SHA-256 of the method, the path and the body): `True` means the key already has an answer,
  which `Start` sent (the stored headers, `Idempotent-Replayed: true`, the body); the handler
  exits. **400** `invalid_idempotency_key` for a key that isn't 1 to 255 visible ASCII characters
  (bare or in quotes, `"..."`); **409** `idempotency_key_in_flight` while the first request still
  runs; **422** `idempotency_key_reused` for the same key with another request.
- **`CompleteOn(LQuery, ...)`** (0.27.0) stores the answer on your query, inside your write's
  transaction, before its commit: the answer commits with the change or neither does, and no
  second connection is taken. It needs `TDbIdempotencyStore` (the memory store raises
  `EArgumentException`) and the keys' table in the same database as your write. Then no
  `Complete`. If it or the commit raises, roll back, let the connection go back to the pool,
  then `Fail`: it releases the key only if no answer committed (the `RELEASE` statement's
  `AND DONE = 0`), and never stores a client error over an answer.
- **`Complete`** stores the answer after your write committed, in a transaction of its own on
  another pooled connection. Since 0.27.0 it **never raises**: when the store fails (no
  connection left in the pool, SQLite's writer lock still held after its busy timeout), the
  change is already made, so the line goes to the error log, the answer is sent, and the key
  stays claimed until its lease runs out. A retry before then gets the 409 in flight; after it,
  the request runs again and your own checks answer it (pitfalls). Until 0.26.0 the client got
  the store's error (a 503 or a 409 for a change that was made) and `Fail` released the key, so
  the retry ran the change again at once (pascal-agenda-faa, measured under load on PostgreSQL
  and SQLite). Putting it inside the `try` is still fine: it doesn't raise, and a `Fail` after
  it does nothing.
- `Fail(E)` stores a client error as the error handler would send it (status, code, fields), so
  the retry of a request that was refused is refused the same way; anything else (a 500, the
  database gone) releases the key, so a retry runs again. Only before an answer: after
  `Complete` it does nothing.
- `Send` sends the headers and the body. The stored headers are `HeaderLines` text
  (`"Name: value"` lines); a header with a line break is refused there.

With tenants, the scope is the tenant's id (`TTenantMiddleware.Current(AReq).Id`), so two
tenants' keys of the same name never meet.

## Choices

- **`"*"` in `If-Match`.** It matches any current version, so it says nothing about what the
  client read. `RequireIfMatch(..., AAcceptAny = False)` answers it with a 428 (the default, and
  pascal-agenda-faa's choice); pass `True` where "change it if it exists" is fine.
- **`If-Match` required, or only checked when sent.** The units implement "required" (a 428
  without it), which is the only way a lost update can't happen. To check it only when sent,
  call `EvaluateIfMatch` yourself and skip the check on `imAbsent`.
- **The version in the body.** Sample 02 sends it only as the header; pascal-agenda-faa also
  puts `version` in the body, so a client that read a list can build `If-Match` without a read
  per row.
- **The store.** `TDbIdempotencyStore` for several instances of the API (they share the table);
  `TMemoryIdempotencyStore` for one process and for tests (it is lost on restart). A Redis store
  isn't written (docs/plan.md).
- **How long.** `TIdempotency.Create(AStore, ATtlSeconds, ALeaseSeconds)`: answers are replayed
  for 24 hours by default; a claim holds for 30 seconds (a request that died leaves a key the
  next retry takes over after that). Keep the lease above the longest request.
- **Required key.** `Start` leaves the key optional. To require one (a public booking route),
  pass `ARequired = True` (0.24.0): a missing or blank key is a 400 `idempotency_key_required`
  (`RequireIdempotencyKey` does the check where there is no Horse request). Where a stored answer
  carries something only its client should see (pascal-agenda-faa's public booking answers with
  a signed link), also require a key long enough not to be guessed: the body must match too, but
  `"1"` is a key two clients may both pick.

## Pitfalls

- **`Complete` is not atomic with your write.** The claim, your write and `Complete` are three
  transactions. If `Complete` fails, or the process dies, after your write committed, the key
  has no answer: a retry after the lease runs again, and your own checks answer it (a duplicate
  code's 409, a booked slot's 409). No duplicate row, but the client sees an error for a request
  that worked. Under load `Complete` is the likeliest to fail: it needs a second connection
  while the pool is busy, and on SQLite a second writer. `CompleteOn` closes both: one
  connection, one transaction.
- **`CompleteOn` holds the key's row until your commit.** `Fail` after it must come after the
  rollback (and with the connection back in the pool): before it, the release waits on your own
  transaction (PostgreSQL's row lock, SQLite's writer lock).
- **A read before the check is not enough.** Comparing the ETag and then writing without
  `WHERE VERSION = :VERSION` lets a change slip in between: the 412 of step 4 is the guarantee.
- **Every change moves the version.** A statement that changes the row and forgets
  `VERSION = VERSION + 1` makes a stale `If-Match` match.
- **The fingerprint is method, path and body, byte for byte.** A client that re-serializes the
  body differently on a retry (another member order) gets a 422. Send the same bytes again.
- **Headers in the MCP tools.** A header parameter (`HeaderParam`) is a tool argument only
  when the route opts it in with `McpHeader` (0.25.0): sample 02's `replace_city` takes
  `ifMatch` and `create_citie` takes `idempotencyKey` ([MCP](mcp.md), step 6). The model sees
  only the body, so the version must be there too, not only in the `ETag` header.
- **Curl from Git Bash** sends `If-Match: "1"` as written (single quotes around the whole
  header). In a script, keep the double quotes inside single quotes.

## Testing your application

- The 428, 400, 412 and the 200 with the next ETag, a weak tag, a list, and a lost update
  across two kinds of change (sample 02: a `PATCH`, then a `PUT` from before it).
- Four changes from one version at once: exactly one success.
- A retry with the same key: the same status, body and headers, `Idempotent-Replayed: true`.
  The same key with another body: 422. A refused request retried: the same refusal, replayed.
  Four requests with one key at once: one runs; the others get 409 in flight or the replay;
  one row.
- A store whose `Complete` fails after your write: the answer is sent and a retry gets the 409
  in flight, not a second run (`PascalApi.IdempotencyTests`, `Call_*`: a store that raises in
  `Complete`, and pascal-db-faa's mock with `AddFailure('IDEMPOTENCY.COMPLETE', ...)`). Over
  HTTP it needs a busy pool, which a scenario can't make happen on demand.
- The lease and the expiry need a clock: test them on `TMemoryIdempotencyStore` with the
  instants in the arguments (`PascalApi.IdempotencyTests`), not over HTTP.

`tools/http_scenarios_db.sh` does all of the HTTP ones; copy its shell loops for the concurrent
cases.

## Reference

- `PascalApi.Preconditions`: `VersionETag`, `EvaluateIfMatch`, `RequireIfMatchSent`,
  `RequireIfMatch`, `RaisePreconditionFailed`; codes `API_CODE_PRECONDITION_REQUIRED`,
  `API_CODE_INVALID_IF_MATCH`, `API_CODE_PRECONDITION_FAILED`.
- `PascalApi.Idempotency`: `TIdempotency` (`Start`, `Complete`, `CompleteOn`, `Release`,
  `Fail`), `TIdempotentCall` (one request's key without Horse: `Complete`, `CompleteOn`, `Fail`,
  `CompleteError`), `IIdempotencyStore`, `IIdempotencyQueryStore`,
  `TMemoryIdempotencyStore`, `TDbIdempotencyStore`, `NormalizeIdempotencyKey`,
  `RequestFingerprint`, `HeaderLines`, `ParseHeaderLines`.
- `src/horse/PascalApi.Horse.Idempotency`: `THorseIdempotentRequest` (`Start`, `Complete`,
  `CompleteOn`, `Fail`, `Send`),
  `THorseIdempotency.SendReplay`.
- Documenting them: `TRouteDoc` `HeaderParam('If-Match', ..., True)`,
  `ResponseHeader('ETag', ...)` ([OpenAPI](openapi.md)); as MCP tool arguments,
  `McpHeader('If-Match')` ([MCP](mcp.md)).
- The messages are `TApiMessages` (English and Portuguese, [Errors](errors.md)).
- Sample: `samples/02-db`; scenarios: `tools/http_scenarios_db.sh`.
