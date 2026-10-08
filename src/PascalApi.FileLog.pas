unit PascalApi.FileLog;

{$I pascalapi.inc}

{ Asynchronous file logging, one file per category, rotated by size.

  FileLog only queues the line; it never makes the calling thread wait for
  disk I/O. A dedicated thread drains the queue and writes in batches, at the
  configured interval. The queue is bounded: when full, the oldest line is
  dropped, because logging must never block or bring down the caller.

  Each category writes to its own file (<LOG_DIR>/<category>.log). When the
  current file reaches the maximum size, it is renamed to
  <category>_yyyymmddhhnnss.log (with _1, _2... if that name is taken) and a
  new file is started.

  Every line starts with [<id> <date time>]. The id (8 hex digits) is made
  once per call and is the same in every category of that call, so two lines
  in two files can be recognized as the same event:

    FileLog(['exception', 'startup'], 'Could not connect: %s', [E.Message]);

  Configuration (environment or .env, through TAppConfig), read once when
  the unit initializes:
    LOG_DIR                 folder of the log files (default: logs)
    LOG_QUEUE_CAPACITY      maximum lines waiting in memory (default: 10000)
    LOG_FLUSH_INTERVAL_MS   interval between writes (default: 200)
    LOG_MAX_FILE_SIZE_MB    size that triggers rotation (default: 2)

  Files are UTF-8 (see PascalApi.Text). Timestamps come from TClock
  (pascal-common-faa), so tests can fix them.

  Ported from Common.FileLog (delphi-api-infra-faa). Dual-compiler changes:
  the flush thread is a TThread subclass (no anonymous threads on FPC 3.2.2);
  System.IOUtils/System.Hash became SysUtils and PascalApi.Text; TLogTruncate
  measures in UTF-8 bytes on both compilers (Length counts UTF-16 units on
  Delphi and bytes on FPC, so the origin's "first 250 characters" would be a
  different cut on each, and on FPC could split a character); a rotation
  never overwrites an earlier archive from the same second (rename replaces
  the target on Linux). }

interface

uses
  Classes,
  SyncObjs,
  Generics.Collections;

type
  TLogItem = record
    Category: string;
    Line: string;
  end;

  IFileLogger = interface
    ['{C5B8DC0B-D00A-4443-8808-2169D478DA52}']
    procedure Log(const ACategory, AText: string); overload;
    procedure Log(const ACategories: array of string; const AText: string); overload;
    procedure Log(const ACategory, AFormatStr: string; const AArgs: array of const); overload;
    procedure Log(const ACategories: array of string; const AFormatStr: string;
      const AArgs: array of const); overload;
    procedure FlushNow;
    function PendingCount: Integer;
  end;

  TFileLogger = class;

  TFileLogFlushThread = class(TThread)
  private
    FOwner: TFileLogger;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TFileLogger);
  end;

  { AAutoFlush = False (tests only) creates no thread: the caller drains the
    queue with FlushNow, synchronously and deterministically. }
  TFileLogger = class(TInterfacedObject, IFileLogger)
  private
    FLogDir: string;
    FCapacity: Integer;
    FFlushIntervalMs: Integer;
    FMaxFileSize: Int64;
    FQueue: TQueue<TLogItem>;
    FLock: TCriticalSection;
    FThread: TFileLogFlushThread;
    FWake: TEvent;
    function NewEventId: string;
    procedure Enqueue(const ACategory, ALine: string);
    procedure FlushQueue;
    function CategoryFilePath(const ACategory: string): string;
    procedure RotateIfNeeded(const APath: string);
    procedure StopFlushThread;
  public
    constructor Create(const ALogDir: string; ACapacity, AFlushIntervalMs: Integer;
      AMaxFileSizeBytes: Int64; AAutoFlush: Boolean = True);
    destructor Destroy; override;
    procedure Log(const ACategory, AText: string); overload;
    procedure Log(const ACategories: array of string; const AText: string); overload;
    procedure Log(const ACategory, AFormatStr: string; const AArgs: array of const); overload;
    procedure Log(const ACategories: array of string; const AFormatStr: string;
      const AArgs: array of const); overload;
    procedure FlushNow;
    function PendingCount: Integer;
  end;

  { Cuts large content before logging it (a message body, say) without
    losing traceability: appends the total size and a short hash of the
    whole content, so two cut lines can be matched without storing the
    content anywhere. Sizes are UTF-8 bytes. }
  TLogTruncate = class
  public
    class function Apply(const AContent: string; AMaxBytes: Integer = 250): string;
  end;

procedure FileLog(const ACategory, AText: string); overload;
procedure FileLog(const ACategories: array of string; const AText: string); overload;
procedure FileLog(const ACategory, AFormatStr: string; const AArgs: array of const); overload;
procedure FileLog(const ACategories: array of string; const AFormatStr: string;
  const AArgs: array of const); overload;

implementation

uses
  SysUtils,
  PascalCommon.SafeLog,
  PascalCommon.SystemContext,
  PascalApi.Config,
  PascalApi.Text;

function FileSizeOf(const APath: string): Int64;
var
  LStream: TFileStream;
begin
  Result := 0;
  if not FileExists(APath) then
    Exit;
  LStream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    Result := LStream.Size;
  finally
    LStream.Free;
  end;
end;

procedure AppendBytes(const APath: string; const ABytes: TBytes);
var
  LStream: TFileStream;
begin
  if FileExists(APath) then
  begin
    LStream := TFileStream.Create(APath, fmOpenReadWrite or fmShareDenyWrite);
    LStream.Seek(0, soEnd);
  end
  else
    LStream := TFileStream.Create(APath, fmCreate);
  try
    if Length(ABytes) > 0 then
      LStream.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    LStream.Free;
  end;
end;

{ TLogTruncate }

class function TLogTruncate.Apply(const AContent: string; AMaxBytes: Integer): string;
var
  LBytes: TBytes;
begin
  LBytes := PaStringToUtf8Bytes(AContent);
  if Length(LBytes) <= AMaxBytes then
    Exit(AContent);
  Result := PaUtf8Prefix(AContent, AMaxBytes) + Format(' [cut; total_bytes=%d; hash=%s]',
    [Length(LBytes), Copy(PaMd5Hex(LBytes), 1, 8)]);
end;

{ TFileLogFlushThread }

constructor TFileLogFlushThread.Create(AOwner: TFileLogger);
begin
  inherited Create(True); // started by the owner, once the event exists
  FOwner := AOwner;
  FreeOnTerminate := False;
end;

procedure TFileLogFlushThread.Execute;
begin
  // Manual-reset event: SetEvent at shutdown wakes the thread at once,
  // without waiting for a full interval.
  while FOwner.FWake.WaitFor(FOwner.FFlushIntervalMs) = wrTimeout do
    FOwner.FlushQueue;
  FOwner.FlushQueue; // drains what is left before ending
end;

{ TFileLogger }

constructor TFileLogger.Create(const ALogDir: string; ACapacity, AFlushIntervalMs: Integer;
  AMaxFileSizeBytes: Int64; AAutoFlush: Boolean);
begin
  inherited Create;
  FLogDir := ALogDir;
  FCapacity := ACapacity;
  FFlushIntervalMs := AFlushIntervalMs;
  FMaxFileSize := AMaxFileSizeBytes;
  FQueue := TQueue<TLogItem>.Create;
  FLock := TCriticalSection.Create;
  if not AAutoFlush then
    Exit;
  FWake := TEvent.Create(nil, True, False, '');
  FThread := TFileLogFlushThread.Create(Self);
  FThread.Start;
end;

destructor TFileLogger.Destroy;
begin
  StopFlushThread;
  FlushQueue; // nothing left behind, with or without the thread
  FQueue.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TFileLogger.StopFlushThread;
begin
  if not Assigned(FThread) then
    Exit;
  FWake.SetEvent;
  FThread.WaitFor;
  FreeAndNil(FThread);
  FreeAndNil(FWake);
end;

procedure TFileLogger.Enqueue(const ACategory, ALine: string);
var
  LItem: TLogItem;
begin
  LItem.Category := ACategory;
  LItem.Line := ALine;
  FLock.Enter;
  try
    if FQueue.Count >= FCapacity then
      FQueue.Dequeue; // drop the oldest: the queue must never block the caller
    FQueue.Enqueue(LItem);
  finally
    FLock.Leave;
  end;
end;

function TFileLogger.PendingCount: Integer;
begin
  FLock.Enter;
  try
    Result := FQueue.Count;
  finally
    FLock.Leave;
  end;
end;

function TFileLogger.CategoryFilePath(const ACategory: string): string;
begin
  Result := IncludeTrailingPathDelimiter(FLogDir) + ACategory + '.log';
end;

procedure TFileLogger.RotateIfNeeded(const APath: string);
var
  LBase, LArchive: string;
  LSuffix: Integer;
begin
  if FileSizeOf(APath) < FMaxFileSize then
    Exit;
  LBase := ChangeFileExt(APath, '') + '_' + FormatDateTime('yyyymmddhhnnss', TClock.Now);
  LArchive := LBase + '.log';
  LSuffix := 0;
  while FileExists(LArchive) do
  begin
    Inc(LSuffix);
    LArchive := LBase + '_' + IntToStr(LSuffix) + '.log';
  end;
  if not RenameFile(APath, LArchive) then
    raise EInOutError.CreateFmt('could not rename %s to %s', [APath, LArchive]);
end;

procedure TFileLogger.FlushQueue;
var
  LItem: TLogItem;
  LByCat: TObjectDictionary<string, TStringList>;
  LList: TStringList;
  LPair: TPair<string, TStringList>;
  LPath: string;
begin
  LByCat := TObjectDictionary<string, TStringList>.Create([doOwnsValues]);
  try
    FLock.Enter;
    try
      while FQueue.Count > 0 do
      begin
        LItem := FQueue.Dequeue;
        if not LByCat.TryGetValue(LItem.Category, LList) then
        begin
          LList := TStringList.Create;
          LByCat.Add(LItem.Category, LList);
        end;
        LList.Add(LItem.Line);
      end;
    finally
      FLock.Leave;
    end;

    if LByCat.Count = 0 then
      Exit;

    for LPair in LByCat do
    begin
      LPath := CategoryFilePath(LPair.Key);
      try
        ForceDirectories(FLogDir);
        RotateIfNeeded(LPath);
        AppendBytes(LPath, PaStringToUtf8Bytes(LPair.Value.Text));
      except
        on E: Exception do
          // A log file must not bring the application down; best effort on
          // the console.
          SafeWriteln('[PascalApi.FileLog] could not write the log file (' + LPair.Key + '): ' +
            E.Message);
      end;
    end;
  finally
    LByCat.Free;
  end;
end;

procedure TFileLogger.FlushNow;
begin
  FlushQueue;
end;

function TFileLogger.NewEventId: string;
var
  LGuid: TGUID;
begin
  CreateGUID(LGuid);
  Result := Copy(PaMd5Hex(PaStringToUtf8Bytes(GUIDToString(LGuid))), 1, 8);
end;

procedure TFileLogger.Log(const ACategory, AText: string);
begin
  Log([ACategory], AText);
end;

procedure TFileLogger.Log(const ACategories: array of string; const AText: string);
var
  LLine: string;
  I: Integer;
begin
  // One id for every category of this call: the same line written to more
  // than one file can be matched.
  LLine := Format('[%s %s] %s',
    [NewEventId, FormatDateTime('yyyy-mm-dd hh:nn:ss', TClock.Now), AText]);
  for I := 0 to High(ACategories) do
    Enqueue(ACategories[I], LLine);
end;

procedure TFileLogger.Log(const ACategory, AFormatStr: string; const AArgs: array of const);
begin
  Log([ACategory], Format(AFormatStr, AArgs));
end;

procedure TFileLogger.Log(const ACategories: array of string; const AFormatStr: string;
  const AArgs: array of const);
begin
  Log(ACategories, Format(AFormatStr, AArgs));
end;

{ FileLog: the process-wide instance }

var
  GDefaultLogger: IFileLogger;

procedure FileLog(const ACategory, AText: string);
begin
  GDefaultLogger.Log(ACategory, AText);
end;

procedure FileLog(const ACategories: array of string; const AText: string);
begin
  GDefaultLogger.Log(ACategories, AText);
end;

procedure FileLog(const ACategory, AFormatStr: string; const AArgs: array of const);
begin
  GDefaultLogger.Log(ACategory, AFormatStr, AArgs);
end;

procedure FileLog(const ACategories: array of string; const AFormatStr: string;
  const AArgs: array of const);
begin
  GDefaultLogger.Log(ACategories, AFormatStr, AArgs);
end;

initialization
  // Created here, not lazily (a lazy default raced in pascal-common-faa's
  // TClock). A relative LOG_DIR is relative to the current directory.
  GDefaultLogger := TFileLogger.Create(
    TAppConfig.Get('LOG_DIR', 'logs'),
    TAppConfig.GetInt('LOG_QUEUE_CAPACITY', 10000),
    TAppConfig.GetInt('LOG_FLUSH_INTERVAL_MS', 200),
    Int64(TAppConfig.GetInt('LOG_MAX_FILE_SIZE_MB', 2)) * 1024 * 1024);

finalization
  GDefaultLogger := nil; // refcount 0: Destroy stops the thread and drains the queue

end.
