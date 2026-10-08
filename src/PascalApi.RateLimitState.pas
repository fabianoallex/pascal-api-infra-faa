unit PascalApi.RateLimitState;

{$I pascalapi.inc}

{ The sliding window behind rate limiting, apart from any HTTP framework.

  Kept separate from the middleware so it can be tested without Horse. Each
  key (an IP, a user) keeps the instants of its accepted requests inside the
  window; a request is refused when the window already holds ALimit of them.
  Refused requests take no slot.

  The window is measured with TTicker (monotonic clock), never with TClock:
  with the wall clock, setting the system time back (end of daylight saving
  time, NTP, an operator) left the entries "in the future" and kept a client
  blocked until the clock caught up with them, up to an hour longer than the
  window. TClock is used only to express AResetUnix (wall-clock now plus what
  is left of the window). Both are replaceable in tests (pascal-common-faa's
  PascalCommon.SystemContext).

  Ported from Common.RateLimitState (delphi-api-infra-faa) unchanged except
  for the comments, in English here. }

interface

uses
  Generics.Collections,
  SyncObjs;

type
  IRateLimitState = interface
    ['{05DA1A33-9889-4E6B-A6E6-CFA0916EA931}']
    /// Records a request for AKey if the window has room. AExceeded tells
    /// whether it was refused; ARemaining is what is left in the window;
    /// AResetUnix is when the oldest entry leaves the window (Unix seconds).
    procedure CheckAndRecord(const AKey: string; ALimit, AWindowSeconds: Integer;
      out ARemaining: Integer; out AResetUnix: Int64; out AExceeded: Boolean);
  end;

  /// In-memory implementation; thread-safe (one lock for all keys).
  TRateLimitState = class(TInterfacedObject, IRateLimitState)
  private
    FLock: TCriticalSection;
    FBuckets: TObjectDictionary<string, TList<UInt64>>; // TTicker.NowMs readings, ascending
  public
    constructor Create;
    destructor Destroy; override;
    procedure CheckAndRecord(const AKey: string; ALimit, AWindowSeconds: Integer;
      out ARemaining: Integer; out AResetUnix: Int64; out AExceeded: Boolean);
  end;

implementation

uses
  SysUtils,
  DateUtils,
  Math,
  PascalCommon.SystemContext;

{ TRateLimitState }

constructor TRateLimitState.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FBuckets := TObjectDictionary<string, TList<UInt64>>.Create([doOwnsValues]);
end;

destructor TRateLimitState.Destroy;
begin
  FBuckets.Free;
  FLock.Free;
  inherited;
end;

procedure TRateLimitState.CheckAndRecord(const AKey: string; ALimit, AWindowSeconds: Integer;
  out ARemaining: Integer; out AResetUnix: Int64; out AExceeded: Boolean);
var
  LBucket: TList<UInt64>;
  LNowMs, LWindowMs, LResetInMs: UInt64;

  // Age of an entry; 0 if it is ahead of LNowMs (only with a test ticker
  // that goes back). Never wraps around the UInt64.
  function AgeMs(AEntryMs: UInt64): UInt64;
  begin
    if LNowMs > AEntryMs then
      Result := LNowMs - AEntryMs
    else
      Result := 0;
  end;

begin
  LWindowMs := UInt64(Max(AWindowSeconds, 0)) * 1000;

  FLock.Enter;
  try
    // Read under the lock: a key's entries stay ascending even with
    // concurrent requests.
    LNowMs := TTicker.NowMs;

    if not FBuckets.TryGetValue(AKey, LBucket) then
    begin
      LBucket := TList<UInt64>.Create;
      FBuckets.Add(AKey, LBucket);
    end;

    // Ascending list: expired entries are at the front.
    while (LBucket.Count > 0) and (AgeMs(LBucket[0]) > LWindowMs) do
      LBucket.Delete(0);

    AExceeded := LBucket.Count >= ALimit;
    if not AExceeded then
      LBucket.Add(LNowMs);

    // Reset: when the oldest entry of the window expires, on the wall clock
    // (it is a Unix timestamp for the client).
    if LBucket.Count > 0 then
    begin
      if AgeMs(LBucket[0]) < LWindowMs then
        LResetInMs := LWindowMs - AgeMs(LBucket[0])
      else
        LResetInMs := 0;
    end
    else
      LResetInMs := LWindowMs;
    AResetUnix := DateTimeToUnix(TClock.Now + LResetInMs / MSecsPerDay, False);

    ARemaining := Max(0, ALimit - LBucket.Count);
  finally
    FLock.Leave;
  end;
end;

end.
