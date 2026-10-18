unit PascalApi.Redis.JwtKeys;

{$I pascalapi.inc}

(* JWT signing keys in Redis: TRedisJwtKeyStore, an IJwtKeyStore
  (PascalApi.JwtKeys) for an API that already runs Redis, on
  pascal-redis-faa's TRedisClient (docs/jwt-keys-design.md, decision 5).

    GRedis := TRedisClient.Create(RedisDefaultParams);      // the API's one client
    LStore := TRedisJwtKeyStore.Create(GRedis, 'cities-api:');
    LRing := TRotatingJwtKeyRing.Create(LStore, LOptions);

  Outside the package, as src/horse is for Horse: the core has no Redis
  code, so an API without Redis builds as before. A consumer adds src/redis
  and its own pascal-redis-faa to the search path.

  One hash per scope, <prefix>jwt-keys:<scope> (the prefix is the
  application's, as for any key it shares a Redis with): field = the
  generation, value = the key as JSON ({"kid", "secret", "createdAt",
  "activeFrom"}). TryAdd is HSETNX, so of two instances adding the same
  generation exactly one wins; Load is HGETALL; Delete finds the kid's
  generation and HDELs it. The hash has no TTL.

  Two settings of the Redis server log every user out when they go wrong,
  as the keys vanish: no persistence (no RDB or AOF) loses them on a
  restart, and an eviction policy other than noeviction or a volatile-*
  one can evict them under memory pressure. pascal-redis-faa never repeats
  a command in flight after a reconnect (HSETNX isn't idempotent): a TryAdd
  that fails that way raises, and the ring retries on its next reload.

  The client is shared (TRedisClient has a pool inside, safe across
  threads); the store frees it only when created with AOwnsClient. *)

interface

uses
  SysUtils,
  Redis.Types,
  Redis.Client,
  Redis.Commands.Hashes,
  PascalApi.JwtKeys;

type
  TRedisJwtKeyStore = class(TInterfacedObject, IJwtKeyStore)
  private
    FClient: TRedisClient;
    FOwnsClient: Boolean;
    FPrefix: string;
  public
    /// AClient: the API's client. APrefix goes before every key
    /// ('cities-api:' -> 'cities-api:jwt-keys:<scope>').
    constructor Create(AClient: TRedisClient; const APrefix: string = '';
      AOwnsClient: Boolean = False);
    destructor Destroy; override;
    /// The hash of AScope's keys.
    function HashKey(const AScope: string): string;
    function Load(const AScope: string): TJwtKeyArray;
    function TryAdd(const AScope: string; const AKey: TJwtKey): Boolean;
    procedure Delete(const AScope, AKid: string);
  end;

implementation

uses
  PascalJsonMapper.Json;

function KeyToJson(const AKey: TJwtKey): string;
var
  LWriter: TJsonWriter;
begin
  LWriter := TJsonWriter.Create;
  try
    LWriter.BeginObject;
    LWriter.Name('kid');
    LWriter.WriteString(AKey.Kid);
    LWriter.Name('secret');
    LWriter.WriteString(AKey.Secret);
    LWriter.Name('createdAt');
    LWriter.WriteInt64(AKey.CreatedAt);
    LWriter.Name('activeFrom');
    LWriter.WriteInt64(AKey.ActiveFrom);
    LWriter.EndObject;
    Result := LWriter.ToString;
  finally
    LWriter.Free;
  end;
end;

// The field and value of one hash entry as a key; EJwtKeyError when they
// can't be what TryAdd wrote (the ring then keeps the keys it had). The
// message never contains the value: it holds the secret.
function JsonToKey(const AField, AJson: string): TJwtKey;
var
  LValue, LMember: TJsonValue;
  LGeneration: Integer;
  LInt: Int64;
begin
  if not TryStrToInt(AField, LGeneration) or (LGeneration < 1) or
    (IntToStr(LGeneration) <> AField) then
    raise EJwtKeyError.CreateFmt('JWT key store (Redis): field "%s" is not a generation', [AField]);
  try
    LValue := ParseJson(AJson);
  except
    on Exception do
      raise EJwtKeyError.CreateFmt('JWT key store (Redis): generation %d is not JSON', [LGeneration]);
  end;
  try
    Result := TJwtKey.Create('', '');
    Result.Generation := LGeneration;
    if LValue.Kind <> jkObject then
      raise EJwtKeyError.CreateFmt('JWT key store (Redis): generation %d is not an object',
        [LGeneration]);
    LMember := LValue.Find('kid');
    if (LMember <> nil) and (LMember.Kind = jkString) then
      Result.Kid := LMember.AsString;
    LMember := LValue.Find('secret');
    if (LMember <> nil) and (LMember.Kind = jkString) then
      Result.Secret := LMember.AsString;
    LMember := LValue.Find('createdAt');
    if (LMember <> nil) and LMember.TryAsInt64(LInt) then
      Result.CreatedAt := LInt;
    LMember := LValue.Find('activeFrom');
    if (LMember = nil) or not LMember.TryAsInt64(LInt) then
      raise EJwtKeyError.CreateFmt('JWT key store (Redis): generation %d has no activeFrom',
        [LGeneration]);
    Result.ActiveFrom := LInt;
  finally
    LValue.Free;
  end;
end;

{ TRedisJwtKeyStore }

constructor TRedisJwtKeyStore.Create(AClient: TRedisClient; const APrefix: string;
  AOwnsClient: Boolean);
begin
  inherited Create;
  if AClient = nil then
    raise EArgumentException.Create('TRedisJwtKeyStore: no client');
  FClient := AClient;
  FOwnsClient := AOwnsClient;
  FPrefix := APrefix;
end;

destructor TRedisJwtKeyStore.Destroy;
begin
  if FOwnsClient then
    FClient.Free;
  inherited Destroy;
end;

function TRedisJwtKeyStore.HashKey(const AScope: string): string;
begin
  Result := FPrefix + 'jwt-keys:' + AScope;
end;

function TRedisJwtKeyStore.Load(const AScope: string): TJwtKeyArray;
var
  LReply: IRedisReply;
  I, LCount: Integer;
begin
  Result := nil;
  LReply := FClient.Hashes.HGetAll(HashKey(AScope));
  // Flattened: field, value, field, value... (RESP2 and RESP3 alike).
  SetLength(Result, LReply.Count div 2);
  LCount := 0;
  I := 0;
  while I + 1 < LReply.Count do
  begin
    Result[LCount] := JsonToKey(LReply[I].AsString, LReply[I + 1].AsString);
    Inc(LCount);
    Inc(I, 2);
  end;
  SetLength(Result, LCount);
end;

function TRedisJwtKeyStore.TryAdd(const AScope: string; const AKey: TJwtKey): Boolean;
begin
  Result := FClient.Hashes.HSetNx(HashKey(AScope), IntToStr(AKey.Generation), KeyToJson(AKey));
end;

procedure TRedisJwtKeyStore.Delete(const AScope, AKid: string);
var
  LKeys: TJwtKeyArray;
  I: Integer;
begin
  LKeys := Load(AScope);
  for I := 0 to High(LKeys) do
    if LKeys[I].Kid = AKid then
    begin
      FClient.Hashes.HDel(HashKey(AScope), IntToStr(LKeys[I].Generation));
      Exit;
    end;
end;

end.
