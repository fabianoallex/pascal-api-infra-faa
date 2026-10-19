unit PascalApi.RefreshTokens;

{$I pascalapi.inc}

(* Refresh tokens that are used once: issued with a short access token,
  exchanged for the next one, and a copy that comes back ends the whole
  login.

  docs/jwt-keys-design.md left refresh tokens to the application ("an
  application's flow"). pascal-agenda-faa, the library's first application,
  wrote the flow and proved it over HTTP on both compilers; the user chose
  to bring its core here (2026-10-19). Login, passwords, users and the
  access token's claims stay in the application.

  - A token is "<scope>.<secret>": the scope in clear (a tenant id, or ''
    for an API without tenants, then the token is the secret alone) and 32
    random bytes in Base64url (43 characters). The scope is in clear so the
    application can check it (the tenant exists, isn't suspended) before
    any lookup. Only the SHA-256 of the whole token is stored: a copy of the
    table gives nobody a usable token.
  - Each token belongs to a family: the login that started it. Rotate marks
    the token used and issues the next one in the same family. A token used
    twice means it was copied: the family is revoked, the legitimate holder
    included, and OnSecurity hears of it. Two rotations racing on one token
    are the same case: the store's MarkUsed is True for one of them only
    (an UPDATE ... WHERE USED_AT IS NULL that must match one row), and the
    other revokes the family. A store that can (IRefreshTokenAtomicRotation:
    both stores here) marks the token used and stores the next one in one
    transaction: the loser's MarkUsed waits for the winner's row lock, finds
    the token used, and its revoke, a later statement, sees the next token.
    With any other store the winner reads its spent token again after
    storing the next one: when the loser's revoke came first, the winner
    revokes the family too and is refused (rrRaced), so no token of a
    revoked family is ever handed out; both answers can then be refusals.
    That re-read alone wasn't enough on PostgreSQL (0.20.1): under READ
    COMMITTED the loser's revoke takes its snapshot when it starts, so it
    can miss a next token committed while it runs and commit after the
    winner's re-read. pascal-agenda-faa's race scenario saw the next token
    survive in 4 of 7 runs on Linux; SQLite, one writer at a time, never.
  - Before a token is marked used, the application's check says whether the
    user may still have one (TRefreshUserCheck); a user gone or inactive
    revokes the family.
  - Revoke (logout) revokes the token's family and answers the same for any
    token; RevokeUser ends every login of a user (a new password, a user
    deactivated).
  - Every refusal is one ERefreshTokenRejected, its Reason for logs: the
    API answers the same 401 whatever happened.
  - The store is an interface (IRefreshTokenStore): TDbRefreshTokenStore on
    the application's named SQL, TMemoryRefreshTokenStore for tests. Each
    store call is its own transaction (MarkUsedAndAdd included): when
    issuing the next token fails after the old one was marked, the holder
    logs in again.

  Time is TJwt.UnixNow (pascal-common-faa's TClock), so tests set the clock. *)

interface

uses
  SysUtils,
  SyncObjs,
  PascalCommon.Tracing,
  PascalDb.Interfaces;

const
  REFRESH_SECRET_BYTES = 32;
  /// Base64url of 32 bytes, no padding.
  REFRESH_SECRET_CHARS = 43;
  /// A scope is 0 to 64 characters of A-Z, a-z, 0-9, '-' and '_'.
  REFRESH_MAX_SCOPE_LENGTH = 64;
  REFRESH_DEFAULT_LIFETIME_SECONDS = 30 * 86400;

type
  TRefreshRejection = (
    rrMalformed,  // not "<scope>.<secret>"
    rrUnknown,    // no such token in the scope
    rrExpired,
    rrRevoked,    // its family was revoked (a logout, a reuse, a user gone)
    rrReused,     // already used: a copy came back; the family is revoked now
    rrRaced,      // used by another request at the same moment; the family is revoked
    rrUserGone);  // the application's check refused the user; the family is revoked

  ERefreshTokenRejected = class(Exception)
  private
    FReason: TRefreshRejection;
  public
    constructor Create(AReason: TRefreshRejection);
    property Reason: TRefreshRejection read FReason;
  end;

  TRefreshTokenRecord = record
    Id: string;
    UserId: string;
    FamilyId: string;
    ExpiresAt: Int64;   // Unix seconds
    Used: Boolean;
    Revoked: Boolean;
  end;

  /// Where tokens live. Every method is one transaction of its own.
  IRefreshTokenStore = interface
    ['{F9928DF9-BCB2-4FA1-BCAF-7FE47AB63326}']
    procedure Add(const AScope, AHash: string; const ARecord: TRefreshTokenRecord;
      ACreatedAt: Int64);
    function FindByHash(const AScope, AHash: string; out ARecord: TRefreshTokenRecord): Boolean;
    /// True only for the call that marks it: neither used nor revoked before.
    function MarkUsed(const AScope, AId: string; AAt: Int64): Boolean;
    /// The tokens revoked now (not revoked before).
    function RevokeFamily(const AScope, AFamilyId: string; AAt: Int64): Integer;
    function RevokeUser(const AScope, AUserId: string; AAt: Int64): Integer;
  end;

  /// Optional, next to IRefreshTokenStore: the rotation as one transaction
  /// (the unit's header says why). TRefreshTokens.Rotate uses it when the
  /// store has it (Supports), else MarkUsed then Add.
  IRefreshTokenAtomicRotation = interface
    ['{628DAAA4-A5C0-4C16-B014-7D9235B0FEDE}']
    /// MarkUsed(AScope, AUsedId, AAt) and, only when that marked it,
    /// Add(AScope, ANextHash, ANext, AAt), all or nothing: False, and
    /// nothing stored, when the token was used or revoked already.
    function MarkUsedAndAdd(const AScope, AUsedId: string; AAt: Int64;
      const ANextHash: string; const ANext: TRefreshTokenRecord): Boolean;
  end;

  /// Tokens in this process only: tests, or one instance that accepts
  /// losing every login on restart. Thread-safe.
  TMemoryRefreshTokenStore = class(TInterfacedObject, IRefreshTokenStore,
    IRefreshTokenAtomicRotation)
  private type
    TEntry = record
      Scope: string;
      Hash: string;
      Rec: TRefreshTokenRecord;
    end;
  private
    FLock: TCriticalSection;
    FEntries: array of TEntry;
    // Under FLock, held by the caller.
    procedure AddLocked(const AScope, AHash: string; const ARecord: TRefreshTokenRecord);
    function MarkUsedLocked(const AScope, AId: string): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(const AScope, AHash: string; const ARecord: TRefreshTokenRecord;
      ACreatedAt: Int64);
    function FindByHash(const AScope, AHash: string; out ARecord: TRefreshTokenRecord): Boolean;
    function MarkUsed(const AScope, AId: string; AAt: Int64): Boolean;
    function RevokeFamily(const AScope, AFamilyId: string; AAt: Int64): Integer;
    function RevokeUser(const AScope, AUserId: string; AAt: Int64): Integer;
    function MarkUsedAndAdd(const AScope, AUsedId: string; AAt: Int64;
      const ANextHash: string; const ANext: TRefreshTokenRecord): Boolean;
    function Count: Integer;
  end;

  /// Tokens in a database, through the application's SQL named in the
  /// factory's SqlLoader; TENANT_ID is the scope ('' without tenants):
  /// - AInsertSql: :TENANT_ID, :ID, :TOKEN_HASH, :USER_ID, :FAMILY_ID,
  ///   :CREATED_AT, :EXPIRES_AT;
  /// - AByHashSql: :TENANT_ID, :TOKEN_HASH -> ID, USER_ID, FAMILY_ID,
  ///   EXPIRES_AT, USED_AT, REVOKED_AT (the last two NULL until set);
  /// - AMarkUsedSql: :TENANT_ID, :ID, :USED_AT, and "WHERE USED_AT IS NULL
  ///   AND REVOKED_AT IS NULL": the rows it changes decide the race;
  /// - ARevokeFamilySql: :TENANT_ID, :FAMILY_ID, :REVOKED_AT, "REVOKED_AT IS
  ///   NULL"; ARevokeUserSql the same with :USER_ID.
  /// TOKEN_HASH should be unique within TENANT_ID. MarkUsedAndAdd runs
  /// AMarkUsedSql and AInsertSql in one transaction.
  TDbRefreshTokenStore = class(TInterfacedObject, IRefreshTokenStore,
    IRefreshTokenAtomicRotation)
  private
    FFactory: IDBFactory;
    FInsertSql, FByHashSql, FMarkUsedSql, FRevokeFamilySql, FRevokeUserSql: string;
    function Exec(const ASqlName, AScope, AParam, AValue, ATimeParam: string;
      ATime: Int64): Int64;
    procedure BindInsert(const AQuery: IQuery; const AScope, AHash: string;
      const ARecord: TRefreshTokenRecord; ACreatedAt: Int64);
    procedure BindMarkUsed(const AQuery: IQuery; const AScope, AId: string; AAt: Int64);
  public
    constructor Create(const AFactory: IDBFactory;
      const AInsertSql: string = 'REFRESH.INSERT';
      const AByHashSql: string = 'REFRESH.BY_HASH';
      const AMarkUsedSql: string = 'REFRESH.MARK_USED';
      const ARevokeFamilySql: string = 'REFRESH.REVOKE_FAMILY';
      const ARevokeUserSql: string = 'REFRESH.REVOKE_USER');
    procedure Add(const AScope, AHash: string; const ARecord: TRefreshTokenRecord;
      ACreatedAt: Int64);
    function FindByHash(const AScope, AHash: string; out ARecord: TRefreshTokenRecord): Boolean;
    function MarkUsed(const AScope, AId: string; AAt: Int64): Boolean;
    function RevokeFamily(const AScope, AFamilyId: string; AAt: Int64): Integer;
    function RevokeUser(const AScope, AUserId: string; AAt: Int64): Integer;
    function MarkUsedAndAdd(const AScope, AUsedId: string; AAt: Int64;
      const ANextHash: string; const ANext: TRefreshTokenRecord): Boolean;
  end;

  /// Whether AUserId of AScope may still refresh (exists, active).
  {$IFDEF PASCALAPI_FUNCREFS}
  TRefreshUserCheck = reference to function(const AScope, AUserId: string): Boolean;
  {$ELSE}
  TRefreshUserCheck = function(const AScope, AUserId: string): Boolean of object;
  {$ENDIF}

  TRotatedRefreshToken = record
    Token: string;      // the next refresh token
    Scope: string;
    UserId: string;
    FamilyId: string;
  end;

  TRefreshTokens = class
  private
    FStore: IRefreshTokenStore;
    FLifetime: Int64;
    FOnSecurity: TPcLogProc;
    procedure Security(const ALine: string);
    function Find(const AToken: string; out AScope: string;
      out ARecord: TRefreshTokenRecord): Boolean;
    procedure RevokeFamilyOf(const AScope, AFamilyId, AReason: string);
    /// A new token of AFamilyId ('' starts a family): its text in AToken,
    /// its record (not stored) in Result.
    function NextRecord(const AScope, AUserId, AFamilyId: string;
      out AToken: string): TRefreshTokenRecord;
  public
    /// ALifetimeSeconds: how long a token is valid. AOnSecurity hears of a
    /// family revoked for a reuse, a race or a user gone (one line each).
    constructor Create(const AStore: IRefreshTokenStore;
      ALifetimeSeconds: Int64 = REFRESH_DEFAULT_LIFETIME_SECONDS;
      const AOnSecurity: TPcLogProc = nil);
    /// A new token for AUserId in AScope; AFamilyId '' starts a family (a
    /// login).
    function Issue(const AScope, AUserId: string; const AFamilyId: string = ''): string;
    /// AToken exchanged for the next one of its family. ERefreshTokenRejected
    /// for anything wrong; a reuse, a race or ACheckUser saying False
    /// revoke the family first. Never returns a token whose family is
    /// revoked: a race lost after the next token was stored is rrRaced too.
    function Rotate(const AToken: string; const ACheckUser: TRefreshUserCheck): TRotatedRefreshToken;
    /// Logout: revokes AToken's family; nothing, and no error, for anything
    /// else.
    procedure Revoke(const AToken: string);
    /// Every token of AUserId in AScope; the number revoked.
    function RevokeUser(const AScope, AUserId: string): Integer;

    /// "<scope>.<secret>" (the secret alone for AScope ''). EArgumentException
    /// for a scope that isn't one (IsScope).
    class function NewToken(const AScope: string): string; static;
    /// True with AScope when AToken has a valid scope and a 32-byte secret.
    class function TryParse(const AToken: string; out AScope: string): Boolean; static;
    /// What is stored: the SHA-256 of the whole token, 64 lower-case hex digits.
    class function Hash(const AToken: string): string; static;
    class function IsScope(const AText: string): Boolean; static;
    /// 32 lower-case hex digits from the system's random source.
    class function NewId: string; static;
  end;

function RefreshRejectionName(AReason: TRefreshRejection): string;

implementation

uses
  PascalCommon.Crypto,
  PascalCommon.Random,
  PascalCommon.Utf8,
  PascalApi.Jwt;

const
  REJECTION_NAMES: array[TRefreshRejection] of string = ('malformed', 'unknown', 'expired',
    'revoked', 'reused', 'raced', 'user_gone');

function RefreshRejectionName(AReason: TRefreshRejection): string;
begin
  Result := REJECTION_NAMES[AReason];
end;

{ ERefreshTokenRejected }

constructor ERefreshTokenRejected.Create(AReason: TRefreshRejection);
begin
  inherited CreateFmt('Refresh token rejected: %s', [REJECTION_NAMES[AReason]]);
  FReason := AReason;
end;

{ TMemoryRefreshTokenStore }

constructor TMemoryRefreshTokenStore.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TMemoryRefreshTokenStore.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TMemoryRefreshTokenStore.AddLocked(const AScope, AHash: string;
  const ARecord: TRefreshTokenRecord);
var
  I: Integer;
begin
  for I := 0 to High(FEntries) do
    if (FEntries[I].Scope = AScope) and (FEntries[I].Hash = AHash) then
      raise EArgumentException.Create('TMemoryRefreshTokenStore.Add: the hash is already stored');
  SetLength(FEntries, Length(FEntries) + 1);
  FEntries[High(FEntries)].Scope := AScope;
  FEntries[High(FEntries)].Hash := AHash;
  FEntries[High(FEntries)].Rec := ARecord;
end;

function TMemoryRefreshTokenStore.MarkUsedLocked(const AScope, AId: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(FEntries) do
    if (FEntries[I].Scope = AScope) and (FEntries[I].Rec.Id = AId) then
    begin
      Result := not FEntries[I].Rec.Used and not FEntries[I].Rec.Revoked;
      FEntries[I].Rec.Used := True;
      Exit;
    end;
end;

procedure TMemoryRefreshTokenStore.Add(const AScope, AHash: string;
  const ARecord: TRefreshTokenRecord; ACreatedAt: Int64);
begin
  FLock.Enter;
  try
    AddLocked(AScope, AHash, ARecord);
  finally
    FLock.Leave;
  end;
end;

function TMemoryRefreshTokenStore.FindByHash(const AScope, AHash: string;
  out ARecord: TRefreshTokenRecord): Boolean;
var
  I: Integer;
begin
  Result := False;
  FLock.Enter;
  try
    for I := 0 to High(FEntries) do
      if (FEntries[I].Scope = AScope) and (FEntries[I].Hash = AHash) then
      begin
        ARecord := FEntries[I].Rec;
        Exit(True);
      end;
  finally
    FLock.Leave;
  end;
end;

function TMemoryRefreshTokenStore.MarkUsed(const AScope, AId: string; AAt: Int64): Boolean;
begin
  FLock.Enter;
  try
    Result := MarkUsedLocked(AScope, AId);
  finally
    FLock.Leave;
  end;
end;

function TMemoryRefreshTokenStore.RevokeFamily(const AScope, AFamilyId: string;
  AAt: Int64): Integer;
var
  I: Integer;
begin
  Result := 0;
  FLock.Enter;
  try
    for I := 0 to High(FEntries) do
      if (FEntries[I].Scope = AScope) and (FEntries[I].Rec.FamilyId = AFamilyId) and
        not FEntries[I].Rec.Revoked then
      begin
        FEntries[I].Rec.Revoked := True;
        Inc(Result);
      end;
  finally
    FLock.Leave;
  end;
end;

function TMemoryRefreshTokenStore.RevokeUser(const AScope, AUserId: string;
  AAt: Int64): Integer;
var
  I: Integer;
begin
  Result := 0;
  FLock.Enter;
  try
    for I := 0 to High(FEntries) do
      if (FEntries[I].Scope = AScope) and (FEntries[I].Rec.UserId = AUserId) and
        not FEntries[I].Rec.Revoked then
      begin
        FEntries[I].Rec.Revoked := True;
        Inc(Result);
      end;
  finally
    FLock.Leave;
  end;
end;

function TMemoryRefreshTokenStore.MarkUsedAndAdd(const AScope, AUsedId: string;
  AAt: Int64; const ANextHash: string; const ANext: TRefreshTokenRecord): Boolean;
begin
  // One hold of the lock: nobody sees the token used without its next one.
  FLock.Enter;
  try
    Result := MarkUsedLocked(AScope, AUsedId);
    if Result then
      AddLocked(AScope, ANextHash, ANext);
  finally
    FLock.Leave;
  end;
end;

function TMemoryRefreshTokenStore.Count: Integer;
begin
  FLock.Enter;
  try
    Result := Length(FEntries);
  finally
    FLock.Leave;
  end;
end;

{ TDbRefreshTokenStore }

constructor TDbRefreshTokenStore.Create(const AFactory: IDBFactory;
  const AInsertSql, AByHashSql, AMarkUsedSql, ARevokeFamilySql, ARevokeUserSql: string);
begin
  inherited Create;
  FFactory := AFactory;
  FInsertSql := AInsertSql;
  FByHashSql := AByHashSql;
  FMarkUsedSql := AMarkUsedSql;
  FRevokeFamilySql := ARevokeFamilySql;
  FRevokeUserSql := ARevokeUserSql;
end;

// One UPDATE in a transaction of its own: the rows it changed.
function TDbRefreshTokenStore.Exec(const ASqlName, AScope, AParam, AValue,
  ATimeParam: string; ATime: Int64): Int64;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  LTx := FFactory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader[ASqlName].SQL;
    LQuery.Params.Strings['TENANT_ID'] := AScope;
    LQuery.Params.Strings[AParam] := AValue;
    LQuery.Params.Int64s[ATimeParam] := ATime;
    Result := LQuery.ExecSql;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
end;

procedure TDbRefreshTokenStore.BindInsert(const AQuery: IQuery; const AScope, AHash: string;
  const ARecord: TRefreshTokenRecord; ACreatedAt: Int64);
begin
  AQuery.Sql := FFactory.SqlLoader[FInsertSql].SQL;
  AQuery.Params.Strings['TENANT_ID'] := AScope;
  AQuery.Params.Strings['ID'] := ARecord.Id;
  AQuery.Params.Strings['TOKEN_HASH'] := AHash;
  AQuery.Params.Strings['USER_ID'] := ARecord.UserId;
  AQuery.Params.Strings['FAMILY_ID'] := ARecord.FamilyId;
  AQuery.Params.Int64s['CREATED_AT'] := ACreatedAt;
  AQuery.Params.Int64s['EXPIRES_AT'] := ARecord.ExpiresAt;
end;

procedure TDbRefreshTokenStore.BindMarkUsed(const AQuery: IQuery; const AScope, AId: string;
  AAt: Int64);
begin
  AQuery.Sql := FFactory.SqlLoader[FMarkUsedSql].SQL;
  AQuery.Params.Strings['TENANT_ID'] := AScope;
  AQuery.Params.Strings['ID'] := AId;
  AQuery.Params.Int64s['USED_AT'] := AAt;
end;

procedure TDbRefreshTokenStore.Add(const AScope, AHash: string;
  const ARecord: TRefreshTokenRecord; ACreatedAt: Int64);
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  LTx := FFactory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    BindInsert(LQuery, AScope, AHash, ARecord, ACreatedAt);
    LQuery.ExecSql;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
end;

function TDbRefreshTokenStore.MarkUsedAndAdd(const AScope, AUsedId: string; AAt: Int64;
  const ANextHash: string; const ANext: TRefreshTokenRecord): Boolean;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  LTx := FFactory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    // The UPDATE takes the row's lock until the commit: a request racing on
    // the same token waits here, then matches no row.
    BindMarkUsed(LQuery, AScope, AUsedId, AAt);
    Result := LQuery.ExecSql = 1;
    if Result then
    begin
      BindInsert(LQuery, AScope, ANextHash, ANext, AAt);
      LQuery.ExecSql;
      LTx.Commit;
    end
    else
      LTx.Rollback;
  except
    LTx.Rollback;
    raise;
  end;
end;

function TDbRefreshTokenStore.FindByHash(const AScope, AHash: string;
  out ARecord: TRefreshTokenRecord): Boolean;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
begin
  LTx := FFactory.GetPool.AcquireQuery(LQuery);
  LQuery.Sql := FFactory.SqlLoader[FByHashSql].SQL;
  LQuery.Params.Strings['TENANT_ID'] := AScope;
  LQuery.Params.Strings['TOKEN_HASH'] := AHash;
  LResult := LQuery.Open;
  Result := not LResult.Eof;
  if Result then
  begin
    ARecord.Id := LResult.Strings['ID'];
    ARecord.UserId := LResult.Strings['USER_ID'];
    ARecord.FamilyId := LResult.Strings['FAMILY_ID'];
    ARecord.ExpiresAt := LResult.Int64s['EXPIRES_AT'];
    ARecord.Used := not LResult.NullableInt64['USED_AT'].IsNull;
    ARecord.Revoked := not LResult.NullableInt64['REVOKED_AT'].IsNull;
  end;
end;

function TDbRefreshTokenStore.MarkUsed(const AScope, AId: string; AAt: Int64): Boolean;
begin
  Result := Exec(FMarkUsedSql, AScope, 'ID', AId, 'USED_AT', AAt) = 1;
end;

function TDbRefreshTokenStore.RevokeFamily(const AScope, AFamilyId: string;
  AAt: Int64): Integer;
begin
  Result := Integer(Exec(FRevokeFamilySql, AScope, 'FAMILY_ID', AFamilyId, 'REVOKED_AT', AAt));
end;

function TDbRefreshTokenStore.RevokeUser(const AScope, AUserId: string; AAt: Int64): Integer;
begin
  Result := Integer(Exec(FRevokeUserSql, AScope, 'USER_ID', AUserId, 'REVOKED_AT', AAt));
end;

{ TRefreshTokens }

constructor TRefreshTokens.Create(const AStore: IRefreshTokenStore; ALifetimeSeconds: Int64;
  const AOnSecurity: TPcLogProc);
begin
  inherited Create;
  if AStore = nil then
    raise EArgumentException.Create('TRefreshTokens: AStore is nil');
  if ALifetimeSeconds < 1 then
    raise EArgumentException.Create('TRefreshTokens: ALifetimeSeconds must be at least 1');
  FStore := AStore;
  FLifetime := ALifetimeSeconds;
  FOnSecurity := AOnSecurity;
end;

procedure TRefreshTokens.Security(const ALine: string);
begin
  if Assigned(FOnSecurity) then
    FOnSecurity(ALine);
end;

class function TRefreshTokens.IsScope(const AText: string): Boolean;
var
  I: Integer;
begin
  Result := Length(AText) <= REFRESH_MAX_SCOPE_LENGTH;
  if Result then
    for I := 1 to Length(AText) do
      if not CharInSet(AText[I], ['A'..'Z', 'a'..'z', '0'..'9', '-', '_']) then
        Exit(False);
end;

class function TRefreshTokens.NewId: string;
begin
  Result := LowerCase(PcBytesToHex(PcRandomBytes(16)));
end;

class function TRefreshTokens.NewToken(const AScope: string): string;
begin
  if not IsScope(AScope) then
    raise EArgumentException.CreateFmt('TRefreshTokens: "%s" is not a scope', [AScope]);
  Result := PcBase64UrlEncode(PcRandomBytes(REFRESH_SECRET_BYTES));
  if AScope <> '' then
    Result := AScope + '.' + Result;
end;

class function TRefreshTokens.TryParse(const AToken: string; out AScope: string): Boolean;
var
  P: Integer;
  LScope, LSecret: string;
  LBytes: TBytes;
begin
  Result := False;
  AScope := '';
  P := Pos('.', AToken);
  if P = 0 then
  begin
    LScope := '';
    LSecret := AToken;
  end
  else
  begin
    LScope := Copy(AToken, 1, P - 1);
    LSecret := Copy(AToken, P + 1, MaxInt);
    if LScope = '' then
      Exit; // ".secret": a scope '' is written without the dot
  end;
  if not IsScope(LScope) or (Length(LSecret) <> REFRESH_SECRET_CHARS) then
    Exit;
  if not PcBase64UrlDecode(LSecret, LBytes) or (Length(LBytes) <> REFRESH_SECRET_BYTES) then
    Exit;
  AScope := LScope;
  Result := True;
end;

class function TRefreshTokens.Hash(const AToken: string): string;
begin
  Result := LowerCase(PcBytesToHex(PcDigestToBytes(PcSha256(PcStringToUtf8Bytes(AToken)))));
end;

function TRefreshTokens.NextRecord(const AScope, AUserId, AFamilyId: string;
  out AToken: string): TRefreshTokenRecord;
begin
  if AUserId = '' then
    raise EArgumentException.Create('TRefreshTokens.Issue: AUserId is empty');
  AToken := NewToken(AScope);
  Result.Id := NewId;
  Result.UserId := AUserId;
  Result.FamilyId := AFamilyId;
  if Result.FamilyId = '' then
    Result.FamilyId := NewId;
  Result.ExpiresAt := TJwt.UnixNow + FLifetime;
  Result.Used := False;
  Result.Revoked := False;
end;

function TRefreshTokens.Issue(const AScope, AUserId, AFamilyId: string): string;
var
  LRecord: TRefreshTokenRecord;
begin
  LRecord := NextRecord(AScope, AUserId, AFamilyId, Result);
  FStore.Add(AScope, Hash(Result), LRecord, TJwt.UnixNow);
end;

function TRefreshTokens.Find(const AToken: string; out AScope: string;
  out ARecord: TRefreshTokenRecord): Boolean;
begin
  Result := TryParse(AToken, AScope) and FStore.FindByHash(AScope, Hash(AToken), ARecord);
end;

procedure TRefreshTokens.RevokeFamilyOf(const AScope, AFamilyId, AReason: string);
begin
  if (FStore.RevokeFamily(AScope, AFamilyId, TJwt.UnixNow) > 0) and (AReason <> '') then
    if AScope = '' then
      Security(Format('refresh token family %s revoked: %s', [AFamilyId, AReason]))
    else
      Security(Format('refresh token family %s of scope %s revoked: %s',
        [AFamilyId, AScope, AReason]));
end;

function TRefreshTokens.Rotate(const AToken: string;
  const ACheckUser: TRefreshUserCheck): TRotatedRefreshToken;
var
  LScope: string;
  LRecord, LNext: TRefreshTokenRecord;
  LAtomic: IRefreshTokenAtomicRotation;
begin
  if not TryParse(AToken, LScope) then
    raise ERefreshTokenRejected.Create(rrMalformed);
  if not FStore.FindByHash(LScope, Hash(AToken), LRecord) then
    raise ERefreshTokenRejected.Create(rrUnknown);
  if LRecord.Revoked then
    raise ERefreshTokenRejected.Create(rrRevoked);
  if LRecord.Used then
  begin
    RevokeFamilyOf(LScope, LRecord.FamilyId, 'a used refresh token came back (copied?)');
    raise ERefreshTokenRejected.Create(rrReused);
  end;
  if LRecord.ExpiresAt <= TJwt.UnixNow then
    raise ERefreshTokenRejected.Create(rrExpired);
  if Assigned(ACheckUser) and not ACheckUser(LScope, LRecord.UserId) then
  begin
    RevokeFamilyOf(LScope, LRecord.FamilyId, 'the user is gone or inactive');
    raise ERefreshTokenRejected.Create(rrUserGone);
  end;
  Result.Scope := LScope;
  Result.UserId := LRecord.UserId;
  Result.FamilyId := LRecord.FamilyId;
  if Supports(FStore, IRefreshTokenAtomicRotation, LAtomic) then
  begin
    // Marked and the next stored together: a request that lost waited for
    // this commit, so its revoke (below, in that request) sees the next one.
    LNext := NextRecord(LScope, LRecord.UserId, LRecord.FamilyId, Result.Token);
    if not LAtomic.MarkUsedAndAdd(LScope, LRecord.Id, TJwt.UnixNow, Hash(Result.Token), LNext) then
    begin
      RevokeFamilyOf(LScope, LRecord.FamilyId, 'two refreshes raced on one token');
      raise ERefreshTokenRejected.Create(rrRaced);
    end;
    Exit;
  end;
  if not FStore.MarkUsed(LScope, LRecord.Id, TJwt.UnixNow) then
  begin
    // Another request used it between the read and here.
    RevokeFamilyOf(LScope, LRecord.FamilyId, 'two refreshes raced on one token');
    raise ERefreshTokenRejected.Create(rrRaced);
  end;
  Result.Token := Issue(LScope, LRecord.UserId, LRecord.FamilyId);
  // The request that lost MarkUsed revokes the family, and its revoke can
  // land before Issue stored the next token, which would then survive it
  // (0.19.0 returned it). Read the spent token again: revoked means the
  // race was lost after all; revoke what Issue added and refuse.
  if FStore.FindByHash(LScope, Hash(AToken), LRecord) and LRecord.Revoked then
  begin
    RevokeFamilyOf(LScope, Result.FamilyId, 'two refreshes raced on one token');
    raise ERefreshTokenRejected.Create(rrRaced);
  end;
end;

procedure TRefreshTokens.Revoke(const AToken: string);
var
  LScope: string;
  LRecord: TRefreshTokenRecord;
begin
  if Find(AToken, LScope, LRecord) then
    RevokeFamilyOf(LScope, LRecord.FamilyId, '');
end;

function TRefreshTokens.RevokeUser(const AScope, AUserId: string): Integer;
begin
  Result := FStore.RevokeUser(AScope, AUserId, TJwt.UnixNow);
end;

end.
