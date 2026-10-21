unit PascalApi.Idempotency;

{$I pascalapi.inc}

(* Idempotency-Key (0.23.0): a client that retries a POST with the same key
  gets the first answer again instead of a second effect (the IETF draft
  "The Idempotency-Key HTTP Header Field").

  - A key belongs to a scope (the tenant; '' without tenants) and to one
    request: a fingerprint, RequestFingerprint's SHA-256 of the method, the
    path and the body. The same key with another request is a 422
    (idempotency_key_reused).
  - The first request claims the key and runs; a second one arriving while
    it runs is a 409 (idempotency_key_in_flight), never a second run. A
    claim is a lease (30 seconds by default): a request that died without
    finishing leaves a key the next retry takes over once the lease ran
    out.
  - When it ends, the answer is stored (Complete): a success, and a client
    error exactly as the error handler sends it (Fail: status, code,
    fields), so the same request keeps getting the same answer. Anything
    else (a server error, a lost connection to the database) releases the
    key: a retry runs again. Stored answers expire (24 hours by default);
    an expired key is a new one.
  - The key is 1 to 255 visible ASCII characters, bare or as a structured
    field string in quotes ("..."); anything else is a 400
    (invalid_idempotency_key). Messages from TApiMessages.

  The store is an interface, the same shape as the refresh-token store:
  TDbIdempotencyStore on the application's named SQL (the SQL and the table
  are in docs/guide/concurrency.md; the application owns its migrations),
  TMemoryIdempotencyStore for one process and for tests. In a Horse
  handler, PascalApi.Horse.Idempotency's THorseIdempotentRequest does the
  header, the replay and the stored headers. Not a middleware: it would
  need the handler's response body, which Horse doesn't expose alike on
  both compilers.

  Not atomic with the request's own transaction: the claim, the request
  and the stored answer are three transactions, so a process that dies
  after the request committed and before the answer was stored runs it
  again on the retry (the request's own checks then answer: a booking
  finds its slot taken). Storing the answer in the request's transaction
  would close that, at the cost of the store knowing the request's
  connection.

  From pascal-agenda-faa (Agenda.Idempotency), where it guards booking an
  appointment. *)

interface

uses
  SysUtils,
  SyncObjs,
  PascalDb.Interfaces,
  PascalApi.Http;

const
  API_CODE_INVALID_IDEMPOTENCY_KEY = 'invalid_idempotency_key';
  API_CODE_IDEMPOTENCY_KEY_IN_FLIGHT = 'idempotency_key_in_flight';
  API_CODE_IDEMPOTENCY_KEY_REUSED = 'idempotency_key_reused';
  IDEMPOTENCY_MAX_KEY_CHARS = 255;
  IDEMPOTENCY_DEFAULT_TTL_SECONDS = 86400;
  IDEMPOTENCY_DEFAULT_LEASE_SECONDS = 30;

type
  TIdempotencyClaim = (
    icProceed,  // claimed (new, or a lease that ran out): run the request
    icReplay,   // finished: AResponse is the answer
    icInFlight, // another request with this key is running
    icMismatch  // the key was used for another request
  );

  /// An answer as it is replayed. Headers: "Name: value" lines, #10 between.
  TStoredResponse = record
    Status: Integer;
    Headers: string;
    Body: string;
  end;

  IIdempotencyStore = interface
    ['{F2C7CAC8-7BA5-4A21-BDE7-E7B5C77B0A5B}']
    /// Atomic. An expired key counts as absent.
    function Claim(const AScope, AKey, AFingerprint: string; ANow, ALeaseUntil,
      AExpiresAt: Int64; out AResponse: TStoredResponse): TIdempotencyClaim;
    procedure Complete(const AScope, AKey: string; const AResponse: TStoredResponse);
    /// Forgets a claimed key that has no answer.
    procedure Release(const AScope, AKey: string);
  end;

  /// The keys in memory, for one process (and tests). Expired keys go when
  /// they are claimed again.
  TMemoryIdempotencyStore = class(TInterfacedObject, IIdempotencyStore)
  private type
    TEntry = record
      Scope, Key, Fingerprint: string;
      Done: Boolean;
      LeaseUntil, ExpiresAt: Int64;
      Response: TStoredResponse;
    end;
  private
    FLock: TCriticalSection;
    FEntries: array of TEntry;
    function IndexOfLocked(const AScope, AKey: string): Integer;
    procedure DeleteLocked(AIndex: Integer);
  public
    constructor Create;
    destructor Destroy; override;
    function Claim(const AScope, AKey, AFingerprint: string; ANow, ALeaseUntil,
      AExpiresAt: Int64; out AResponse: TStoredResponse): TIdempotencyClaim;
    procedure Complete(const AScope, AKey: string; const AResponse: TStoredResponse);
    procedure Release(const AScope, AKey: string);
  end;

  /// The keys in a table, by six statements named in the factory's
  /// SqlLoader (the names are constructor parameters, with these defaults).
  /// Parameters: TENANT_ID (the scope), IDEM_KEY, FINGERPRINT, NOW,
  /// LEASE_UNTIL, EXPIRES_AT, CREATED_AT, STATUS_CODE, RESPONSE_HEADERS,
  /// RESPONSE_BODY; the times are Unix seconds. The claim is one
  /// transaction whose first statement is a write (the scope's expired keys
  /// deleted: on SQLite a read first takes a shared lock two writers can't
  /// both upgrade), then an INSERT that does nothing when the key exists
  /// (ON CONFLICT DO NOTHING: SQLite 3.24 and PostgreSQL 9.5 alike).
  TDbIdempotencyStore = class(TInterfacedObject, IIdempotencyStore)
  private
    FFactory: IDBFactory;
    FPurgeSql, FClaimSql, FByKeySql, FTakeOverSql, FCompleteSql, FReleaseSql: string;
    function ExecOne(const ASqlName, AScope, AKey: string): Int64;
  public
    constructor Create(const AFactory: IDBFactory;
      const APurgeSql: string = 'IDEMPOTENCY.PURGE';
      const AClaimSql: string = 'IDEMPOTENCY.CLAIM';
      const AByKeySql: string = 'IDEMPOTENCY.BY_KEY';
      const ATakeOverSql: string = 'IDEMPOTENCY.TAKE_OVER';
      const ACompleteSql: string = 'IDEMPOTENCY.COMPLETE';
      const AReleaseSql: string = 'IDEMPOTENCY.RELEASE');
    function Claim(const AScope, AKey, AFingerprint: string; ANow, ALeaseUntil,
      AExpiresAt: Int64; out AResponse: TStoredResponse): TIdempotencyClaim;
    procedure Complete(const AScope, AKey: string; const AResponse: TStoredResponse);
    procedure Release(const AScope, AKey: string);
  end;

  /// The policy over a store. Thread-safe as its store is (both here are).
  TIdempotency = class
  private
    FStore: IIdempotencyStore;
    FTtlSeconds, FLeaseSeconds: Int64;
  public
    constructor Create(const AStore: IIdempotencyStore;
      ATtlSeconds: Int64 = IDEMPOTENCY_DEFAULT_TTL_SECONDS;
      ALeaseSeconds: Int64 = IDEMPOTENCY_DEFAULT_LEASE_SECONDS);
    /// AKey as the header came, already known not to be blank. True: replay
    /// AResponse. False: run the request, then Complete or Fail with the
    /// key Start returned in AKey (unquoted). EHttpException: 400 invalid,
    /// 409 in flight, 422 another request. ANow: Unix seconds.
    function Start(const AScope: string; var AKey: string; const AFingerprint: string;
      ANow: Int64; out AResponse: TStoredResponse): Boolean;
    procedure Complete(const AScope, AKey: string; AStatus: Integer;
      const AHeaders, ABody: string);
    /// After the request raised E: a client error (one the error handler
    /// doesn't log, PascalApi.Http's MapException) is stored as the handler
    /// answers it; anything else releases the key. Never raises (the caller
    /// re-raises E).
    procedure Fail(const AScope, AKey: string; E: Exception; const AMethod, APath: string);
    property TtlSeconds: Int64 read FTtlSeconds;
    property LeaseSeconds: Int64 read FLeaseSeconds;
  end;

/// The key without its quotes, or '' when it isn't one.
function NormalizeIdempotencyKey(const AHeader: string): string;

/// Lower-case hex SHA-256 of "<method> <path>" #10 <body> (UTF-8).
function RequestFingerprint(const AMethod, APath, ABody: string): string;

/// AHeaders as TStoredResponse.Headers keeps them: "Name: value" lines, #10
/// between. A name or value with a line break is refused
/// (EArgumentException): it would split into another header.
function HeaderLines(const AHeaders: array of THttpHeader): string;

/// The headers of HeaderLines' text; a line without a name is skipped.
function ParseHeaderLines(const ALines: string): TArray<THttpHeader>;

implementation

uses
  PascalCommon.Crypto,
  PascalCommon.Utf8;

function NormalizeIdempotencyKey(const AHeader: string): string;
var
  LKey: string;
  I: Integer;
begin
  Result := '';
  LKey := Trim(AHeader);
  if (Length(LKey) >= 2) and (LKey[1] = '"') and (LKey[Length(LKey)] = '"') then
    LKey := Copy(LKey, 2, Length(LKey) - 2);
  if (LKey = '') or (Length(LKey) > IDEMPOTENCY_MAX_KEY_CHARS) then
    Exit;
  // Visible ASCII; no quote or backslash (a structured string's escapes).
  // ASCII only, so Length counts the same on both compilers.
  for I := 1 to Length(LKey) do
    if (LKey[I] < #$21) or (LKey[I] > #$7E) or (LKey[I] = '"') or (LKey[I] = '\') then
      Exit;
  Result := LKey;
end;

function RequestFingerprint(const AMethod, APath, ABody: string): string;
begin
  Result := LowerCase(PcBytesToHex(PcDigestToBytes(PcSha256(
    PcStringToUtf8Bytes(AMethod + ' ' + APath + #10 + ABody)))));
end;

function HeaderLines(const AHeaders: array of THttpHeader): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AHeaders) do
  begin
    if (Pos(#10, AHeaders[I].Name + AHeaders[I].Value) > 0) or
      (Pos(#13, AHeaders[I].Name + AHeaders[I].Value) > 0) or
      (Trim(AHeaders[I].Name) = '') or (Pos(':', AHeaders[I].Name) > 0) then
      raise EArgumentException.CreateFmt('HeaderLines: invalid header "%s"', [AHeaders[I].Name]);
    if Result <> '' then
      Result := Result + #10;
    Result := Result + AHeaders[I].Name + ': ' + AHeaders[I].Value;
  end;
end;

function ParseHeaderLines(const ALines: string): TArray<THttpHeader>;
var
  LRest, LLine: string;
  P, N: Integer;
begin
  Result := nil;
  N := 0;
  LRest := ALines;
  while LRest <> '' do
  begin
    P := Pos(#10, LRest);
    if P = 0 then
      P := Length(LRest) + 1;
    LLine := Copy(LRest, 1, P - 1);
    Delete(LRest, 1, P);
    P := Pos(':', LLine);
    if P > 1 then
    begin
      SetLength(Result, N + 1);
      Result[N].Name := Trim(Copy(LLine, 1, P - 1));
      Result[N].Value := Trim(Copy(LLine, P + 1, MaxInt));
      Inc(N);
    end;
  end;
end;

procedure ClearResponse(out AResponse: TStoredResponse);
begin
  AResponse.Status := 0;
  AResponse.Headers := '';
  AResponse.Body := '';
end;

{ TMemoryIdempotencyStore }

constructor TMemoryIdempotencyStore.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TMemoryIdempotencyStore.Destroy;
begin
  FLock.Free;
  inherited;
end;

function TMemoryIdempotencyStore.IndexOfLocked(const AScope, AKey: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(FEntries) do
    if (FEntries[I].Scope = AScope) and (FEntries[I].Key = AKey) then
      Exit(I);
end;

procedure TMemoryIdempotencyStore.DeleteLocked(AIndex: Integer);
var
  I: Integer;
begin
  for I := AIndex to High(FEntries) - 1 do
    FEntries[I] := FEntries[I + 1];
  SetLength(FEntries, Length(FEntries) - 1);
end;

function TMemoryIdempotencyStore.Claim(const AScope, AKey, AFingerprint: string;
  ANow, ALeaseUntil, AExpiresAt: Int64; out AResponse: TStoredResponse): TIdempotencyClaim;
var
  I: Integer;
begin
  ClearResponse(AResponse);
  FLock.Acquire;
  try
    I := IndexOfLocked(AScope, AKey);
    if (I >= 0) and (FEntries[I].ExpiresAt <= ANow) then
    begin
      DeleteLocked(I);
      I := -1;
    end;
    if I < 0 then
    begin
      I := Length(FEntries);
      SetLength(FEntries, I + 1);
      FEntries[I].Scope := AScope;
      FEntries[I].Key := AKey;
      FEntries[I].Fingerprint := AFingerprint;
      FEntries[I].Done := False;
      FEntries[I].LeaseUntil := ALeaseUntil;
      FEntries[I].ExpiresAt := AExpiresAt;
      Exit(icProceed);
    end;
    if FEntries[I].Fingerprint <> AFingerprint then
      Exit(icMismatch);
    if FEntries[I].Done then
    begin
      AResponse := FEntries[I].Response;
      Exit(icReplay);
    end;
    if FEntries[I].LeaseUntil > ANow then
      Exit(icInFlight);
    FEntries[I].LeaseUntil := ALeaseUntil;
    Result := icProceed;
  finally
    FLock.Release;
  end;
end;

procedure TMemoryIdempotencyStore.Complete(const AScope, AKey: string;
  const AResponse: TStoredResponse);
var
  I: Integer;
begin
  FLock.Acquire;
  try
    I := IndexOfLocked(AScope, AKey);
    if I >= 0 then
    begin
      FEntries[I].Done := True;
      FEntries[I].Response := AResponse;
    end;
  finally
    FLock.Release;
  end;
end;

procedure TMemoryIdempotencyStore.Release(const AScope, AKey: string);
var
  I: Integer;
begin
  FLock.Acquire;
  try
    I := IndexOfLocked(AScope, AKey);
    if (I >= 0) and not FEntries[I].Done then
      DeleteLocked(I);
  finally
    FLock.Release;
  end;
end;

{ TDbIdempotencyStore }

constructor TDbIdempotencyStore.Create(const AFactory: IDBFactory; const APurgeSql,
  AClaimSql, AByKeySql, ATakeOverSql, ACompleteSql, AReleaseSql: string);
begin
  inherited Create;
  FFactory := AFactory;
  FPurgeSql := APurgeSql;
  FClaimSql := AClaimSql;
  FByKeySql := AByKeySql;
  FTakeOverSql := ATakeOverSql;
  FCompleteSql := ACompleteSql;
  FReleaseSql := AReleaseSql;
end;

function TDbIdempotencyStore.Claim(const AScope, AKey, AFingerprint: string;
  ANow, ALeaseUntil, AExpiresAt: Int64; out AResponse: TStoredResponse): TIdempotencyClaim;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
begin
  ClearResponse(AResponse);
  LTx := FFactory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader[FPurgeSql].SQL;
    LQuery.Params.Strings['TENANT_ID'] := AScope;
    LQuery.Params.Int64s['NOW'] := ANow;
    LQuery.ExecSql;
    LQuery.Sql := FFactory.SqlLoader[FClaimSql].SQL;
    LQuery.Params.Strings['TENANT_ID'] := AScope;
    LQuery.Params.Strings['IDEM_KEY'] := AKey;
    LQuery.Params.Strings['FINGERPRINT'] := AFingerprint;
    LQuery.Params.Int64s['LEASE_UNTIL'] := ALeaseUntil;
    LQuery.Params.Int64s['EXPIRES_AT'] := AExpiresAt;
    LQuery.Params.Int64s['CREATED_AT'] := ANow;
    if LQuery.ExecSql = 1 then
      Result := icProceed
    else
    begin
      LQuery.Sql := FFactory.SqlLoader[FByKeySql].SQL;
      LQuery.Params.Strings['TENANT_ID'] := AScope;
      LQuery.Params.Strings['IDEM_KEY'] := AKey;
      LResult := LQuery.Open;
      if LResult.Eof then
        Result := icInFlight // released between the two statements: retry later
      else if LResult.Strings['FINGERPRINT'] <> AFingerprint then
        Result := icMismatch
      else if LResult.Integers['DONE'] <> 0 then
      begin
        AResponse.Status := LResult.Integers['STATUS_CODE'];
        AResponse.Headers := LResult.Strings['RESPONSE_HEADERS'];
        AResponse.Body := LResult.Strings['RESPONSE_BODY'];
        Result := icReplay;
      end
      else if LResult.Int64s['LEASE_UNTIL'] > ANow then
        Result := icInFlight
      else
      begin
        // A lease that ran out: taken over by one request only.
        LQuery.Sql := FFactory.SqlLoader[FTakeOverSql].SQL;
        LQuery.Params.Strings['TENANT_ID'] := AScope;
        LQuery.Params.Strings['IDEM_KEY'] := AKey;
        LQuery.Params.Int64s['LEASE_UNTIL'] := ALeaseUntil;
        LQuery.Params.Int64s['NOW'] := ANow;
        if LQuery.ExecSql = 1 then
          Result := icProceed
        else
          Result := icInFlight;
      end;
    end;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
end;

// One statement on (TENANT_ID, IDEM_KEY) in a transaction of its own.
function TDbIdempotencyStore.ExecOne(const ASqlName, AScope, AKey: string): Int64;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  LTx := FFactory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader[ASqlName].SQL;
    LQuery.Params.Strings['TENANT_ID'] := AScope;
    LQuery.Params.Strings['IDEM_KEY'] := AKey;
    Result := LQuery.ExecSql;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
end;

procedure TDbIdempotencyStore.Complete(const AScope, AKey: string;
  const AResponse: TStoredResponse);
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  LTx := FFactory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader[FCompleteSql].SQL;
    LQuery.Params.Strings['TENANT_ID'] := AScope;
    LQuery.Params.Strings['IDEM_KEY'] := AKey;
    LQuery.Params.Integers['STATUS_CODE'] := AResponse.Status;
    LQuery.Params.Strings['RESPONSE_HEADERS'] := AResponse.Headers;
    LQuery.Params.Strings['RESPONSE_BODY'] := AResponse.Body;
    LQuery.ExecSql;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
end;

procedure TDbIdempotencyStore.Release(const AScope, AKey: string);
begin
  ExecOne(FReleaseSql, AScope, AKey);
end;

{ TIdempotency }

constructor TIdempotency.Create(const AStore: IIdempotencyStore;
  ATtlSeconds, ALeaseSeconds: Int64);
begin
  inherited Create;
  if AStore = nil then
    raise EArgumentException.Create('TIdempotency: AStore is nil');
  FStore := AStore;
  FTtlSeconds := ATtlSeconds;
  FLeaseSeconds := ALeaseSeconds;
end;

function TIdempotency.Start(const AScope: string; var AKey: string;
  const AFingerprint: string; ANow: Int64; out AResponse: TStoredResponse): Boolean;
var
  LKey: string;
begin
  LKey := NormalizeIdempotencyKey(AKey);
  if LKey = '' then
    raise EHttpException.Create(400, Format(TApiMessages.Current.InvalidIdempotencyKey,
      [IDEMPOTENCY_MAX_KEY_CHARS]), API_CODE_INVALID_IDEMPOTENCY_KEY);
  AKey := LKey;
  case FStore.Claim(AScope, LKey, AFingerprint, ANow, ANow + FLeaseSeconds,
    ANow + FTtlSeconds, AResponse) of
    icReplay:
      Result := True;
    icInFlight:
      raise EHttpException.Create(409, TApiMessages.Current.IdempotencyKeyInFlight,
        API_CODE_IDEMPOTENCY_KEY_IN_FLIGHT);
    icMismatch:
      raise EHttpException.Create(422, TApiMessages.Current.IdempotencyKeyReused,
        API_CODE_IDEMPOTENCY_KEY_REUSED);
  else
    Result := False;
  end;
end;

procedure TIdempotency.Complete(const AScope, AKey: string; AStatus: Integer;
  const AHeaders, ABody: string);
var
  LResponse: TStoredResponse;
begin
  LResponse.Status := AStatus;
  LResponse.Headers := AHeaders;
  LResponse.Body := ABody;
  FStore.Complete(AScope, AKey, LResponse);
end;

procedure TIdempotency.Fail(const AScope, AKey: string; E: Exception;
  const AMethod, APath: string);
var
  LError: TErrorResponse;
begin
  try
    LError := MapException(E, AMethod, APath);
    if LError.LogLine = '' then
      Complete(AScope, AKey, LError.Status, '',
        ErrorJson(LError.Message, '', LError.Code, LError.Fields))
    else
      FStore.Release(AScope, AKey);
  except
    // The original error matters more; an unreleased key frees itself when
    // its lease runs out.
  end;
end;

end.
