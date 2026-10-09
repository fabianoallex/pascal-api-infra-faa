unit PascalApi.Tracing;

{$I pascalapi.inc}

(* Spans for an API: a tracer with a current span per thread, parent-based
  sampling with a ratio for new traces, and a batch processor that hands
  finished spans to an exporter on its own thread (PascalApi.Otlp's
  TOtlpHttpExporter, or a test's).

    TTracing.Start(TTracingOptions.FromEnvironment('cities-api', '1.0.0'),
      TOtlpHttpExporter.FromEnvironment);
    ...
    LSpan := TTracing.StartSpan('load cities');   // a child of the current span
    try
      LSpan.SetAttribute('db.system', 'sqlite');
      ...
    finally
      LSpan.Finish;
    end;

  TLoggerMiddleware opens the server span of each request with the ids it
  resolves (the trace id is the X-Request-Id), so a handler's spans are its
  children; the MCP executor opens a client span around each tool call.

  UNSTABLE API (phase C of docs/observability-design.md): these contracts
  move to pascal-common-faa when the sibling libraries need them (phase D),
  and may change until then.

  Decisions:
  - Not started (or after Shutdown), every call still works: spans carry ids
    and a traceparent, record nothing and export nothing.
  - Sampling: a span with a parent follows the parent's sampled flag; a new
    trace is sampled when the last 16 hex digits of its id, as a 64-bit
    number, fall below SampleRatio * 2^64 (OpenTelemetry's
    TraceIdRatioBased, deterministic for a trace id). Only sampled spans are
    exported.
  - The current span is a per-thread pointer, not an interface threadvar
    (Delphi doesn't finalize managed threadvars). A span holds its parent
    alive; Finish (or freeing an unfinished span) puts the parent back.
    Horse runs a request on one thread, so the server span is the current
    one for the whole handler; another thread starts with none.
  - Time: start and end in Unix nanoseconds, UTC. The wall clock is
    TClock.Now converted to UTC with DateTimeToUnix(.., False) (the
    conversion PascalApi.Jwt uses), milliseconds precision; the duration
    comes from PcTickUs, so end - start is monotonic.
  - The processor's queue is bounded (QueueCapacity): when full, the
    oldest span is dropped and counted (DroppedCount). Exporting never
    blocks a request; a failed batch is dropped and reported to AOnError.
  - Configuration from the standard OpenTelemetry variables (through
    TAppConfig): OTEL_SERVICE_NAME, OTEL_RESOURCE_ATTRIBUTES,
    OTEL_TRACES_SAMPLER_ARG, OTEL_BSP_MAX_QUEUE_SIZE,
    OTEL_BSP_SCHEDULE_DELAY, OTEL_BSP_MAX_EXPORT_BATCH_SIZE. *)

interface

uses
  SysUtils,
  Classes,
  SyncObjs,
  Generics.Collections,
  PascalApi.Http;

type
  TSpanKind = (skInternal, skServer, skClient, skProducer, skConsumer);
  TSpanStatus = (ssUnset, ssOk, ssError);
  TSpanAttributeType = (satString, satInt, satDouble, satBool);

  TSpanAttribute = record
    Key: string;
    ValueType: TSpanAttributeType;
    StringValue: string;
    IntValue: Int64;
    DoubleValue: Double;
    BoolValue: Boolean;
  end;
  TSpanAttributes = array of TSpanAttribute;

  /// A finished span, as the exporter gets it.
  TSpanData = record
    TraceId: string;
    SpanId: string;
    ParentSpanId: string;
    TraceState: string;
    Name: string;
    Kind: TSpanKind;
    StartUnixNano: Int64;
    EndUnixNano: Int64;
    Attributes: TSpanAttributes;
    Status: TSpanStatus;
    StatusMessage: string;
  end;
  TSpanDataArray = array of TSpanData;

  ISpan = interface
    ['{DE5181AE-5A6A-4DD3-9FED-ED5435D88C1A}']
    function TraceId: string;
    function SpanId: string;
    function ParentSpanId: string;
    function Sampled: Boolean;
    /// '00-<trace id>-<span id>-<flags>': what an outgoing call made inside
    /// this span sends.
    function TraceParent: string;
    function TraceState: string;
    procedure SetName(const AName: string);
    /// A second call with the same key replaces the value.
    procedure SetAttribute(const AKey, AValue: string);
    procedure SetIntAttribute(const AKey: string; AValue: Int64);
    procedure SetDoubleAttribute(const AKey: string; AValue: Double);
    procedure SetBoolAttribute(const AKey: string; AValue: Boolean);
    procedure SetStatus(AStatus: TSpanStatus; const AMessage: string = '');
    /// Ends the span (only the first call counts), hands it to the exporter
    /// when sampled, and makes its parent the current span again.
    procedure Finish;
  end;

  ISpanExporter = interface
    ['{F4F418ED-F9BB-454B-9AE8-984B492D47AB}']
    /// Called on the processor's thread, one batch at a time. Raise (or
    /// return False with AError set) when the batch was not accepted.
    function ExportSpans(const ASpans: TSpanDataArray; out AError: string): Boolean;
  end;

  TTracingOptions = record
    ServiceName: string;
    ServiceVersion: string;
    /// 'key=value,key=value' (OTEL_RESOURCE_ATTRIBUTES), added to the
    /// resource after service.name and service.version.
    ResourceAttributes: string;
    /// 0 to 1: the share of new traces sampled. 1 by default.
    SampleRatio: Double;
    /// Spans waiting for export; when full, the oldest is dropped. 2048.
    QueueCapacity: Integer;
    /// Most spans in one export. 512.
    MaxBatchSize: Integer;
    /// Milliseconds between exports. 5000 (OpenTelemetry's default).
    FlushIntervalMs: Integer;
    class function Default(const AServiceName, AServiceVersion: string): TTracingOptions; static;
    /// Default, then the OTEL_* variables (OTEL_SERVICE_NAME replaces
    /// AServiceName). Invalid numbers keep the default.
    class function FromEnvironment(const AServiceName, AServiceVersion: string): TTracingOptions; static;
  end;

  TTracing = class
  public
    /// Starts recording: finished sampled spans go to AExporter in batches.
    /// AAutoFlush = False (tests only) starts no thread: FlushNow exports.
    /// Calling Start again replaces the previous configuration (after
    /// flushing it).
    class procedure Start(const AOptions: TTracingOptions; const AExporter: ISpanExporter;
      AAutoFlush: Boolean = True); overload; static;
    class procedure Start(const AOptions: TTracingOptions; const AExporter: ISpanExporter;
      const AOnError: TLogProc; AAutoFlush: Boolean = True); overload; static;
    /// Exports what is queued, stops the thread, forgets the exporter.
    class procedure Shutdown; static;
    class function Enabled: Boolean; static;
    class function Options: TTracingOptions; static;
    /// A span that is a child of the current one (or the root of a new
    /// trace), and becomes the current one.
    class function StartSpan(const AName: string; AKind: TSpanKind = skInternal): ISpan; static;
    /// A span with the ids given (the server span, whose ids come from the
    /// request), and becomes the current one.
    class function StartSpanWith(const ATraceId, ASpanId, AParentSpanId, ATraceState: string;
      ASampled: Boolean; const AName: string; AKind: TSpanKind): ISpan; static;
    /// The current span of this thread; nil when none.
    class function Current: ISpan; static;
    /// The sampling decision for a new trace with this id (see the header).
    class function ShouldSample(const ATraceId: string): Boolean; static;
    /// Exports what is queued now, on the calling thread.
    class procedure FlushNow; static;
    /// Spans dropped because the queue was full, since Start.
    class function DroppedCount: Int64; static;
    /// Spans waiting for export.
    class function PendingCount: Integer; static;
  end;

/// Unix time in nanoseconds, UTC, of a local TDateTime (milliseconds
/// precision).
function UnixNanoOfLocal(ATime: TDateTime): Int64;

/// The pairs of 'key=value,key=value' (OTEL_RESOURCE_ATTRIBUTES and
/// OTEL_EXPORTER_OTLP_HEADERS): trimmed, '%XX' decoded; pairs without '=' or
/// with an empty key are skipped.
function ParseKeyValueList(const AText: string): TArray<THttpHeader>;

implementation

uses
  DateUtils,
  PascalCommon.SystemContext,
  PascalCommon.Threading,
  PascalCommon.TraceContext,
  PascalJsonMapper.Json,
  PascalApi.Config,
  PascalApi.Text;

type
  TSpan = class;

  TSpanProcessor = class;

  TSpanProcessorThread = class(TThread)
  private
    FOwner: TSpanProcessor;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TSpanProcessor);
  end;

  TSpanProcessor = class
  private
    FOptions: TTracingOptions;
    FExporter: ISpanExporter;
    FOnError: TLogProc;
    FQueue: TQueue<TSpanData>;
    FLock: TCriticalSection;
    FExportLock: TCriticalSection;
    FWake: TEvent;
    FThread: TSpanProcessorThread;
    FDropped: Int64;
    function TakeBatch: TSpanDataArray;
  public
    constructor Create(const AOptions: TTracingOptions; const AExporter: ISpanExporter;
      const AOnError: TLogProc; AAutoFlush: Boolean);
    destructor Destroy; override;
    procedure Enqueue(const ASpan: TSpanData);
    procedure Flush;
    function PendingCount: Integer;
  end;

  TSpan = class(TInterfacedObject, ISpan)
  private
    FData: TSpanData;
    FSampled: Boolean;
    FRecording: Boolean;
    FFinished: Boolean;
    FStartTick: Int64;
    // The parent, kept alive by FParent; FParentSpan is the same object, for
    // the thread's current-span pointer.
    FParent: ISpan;
    FParentSpan: TSpan;
    procedure AddAttribute(const AAttribute: TSpanAttribute);
    procedure LeaveCurrent;
  public
    constructor Create(const ATraceId, ASpanId, AParentSpanId, ATraceState: string;
      ASampled: Boolean; const AName: string; AKind: TSpanKind; AParent: TSpan);
    destructor Destroy; override;
    function TraceId: string;
    function SpanId: string;
    function ParentSpanId: string;
    function Sampled: Boolean;
    function TraceParent: string;
    function TraceState: string;
    procedure SetName(const AName: string);
    procedure SetAttribute(const AKey, AValue: string);
    procedure SetIntAttribute(const AKey: string; AValue: Int64);
    procedure SetDoubleAttribute(const AKey: string; AValue: Double);
    procedure SetBoolAttribute(const AKey: string; AValue: Boolean);
    procedure SetStatus(AStatus: TSpanStatus; const AMessage: string = '');
    procedure Finish;
  end;

threadvar
  // The current span of the thread (a TSpan, not counted: see the header).
  GCurrent: Pointer;

var
  // Replaced only by Start/Shutdown (at startup and exit); read by every
  // span's Finish under GStateLock.
  GProcessor: TSpanProcessor;
  GOptions: TTracingOptions;
  GStateLock: TCriticalSection;

{ Helpers }

function UnixNanoOfLocal(ATime: TDateTime): Int64;
var
  LOffsetSeconds: Int64;
begin
  // DateTimeToUnix(T, False) treats T as local time, (T, True) as UTC: the
  // difference is the local offset in seconds, at that moment.
  LOffsetSeconds := DateTimeToUnix(ATime, False) - DateTimeToUnix(ATime, True);
  Result := (Round((ATime - UnixDateDelta) * MSecsPerDay) + LOffsetSeconds * 1000) * 1000000;
end;

function HexDigit(C: Char; out AValue: Integer): Boolean;
begin
  Result := True;
  if (C >= '0') and (C <= '9') then
    AValue := Ord(C) - Ord('0')
  else if (C >= 'a') and (C <= 'f') then
    AValue := Ord(C) - Ord('a') + 10
  else if (C >= 'A') and (C <= 'F') then
    AValue := Ord(C) - Ord('A') + 10
  else
    Result := False;
end;

// '%XX' sequences decoded as UTF-8 bytes; a malformed one is kept as is, and
// so is the whole text when the result isn't valid UTF-8.
function PercentDecode(const AText: string): string;
var
  LBytes: TBytes;
  LCount, I, LHigh, LLow: Integer;
  LUtf8: TBytes;
begin
  if Pos('%', AText) = 0 then
    Exit(AText);
  LUtf8 := PaStringToUtf8Bytes(AText);
  LBytes := nil;
  SetLength(LBytes, Length(LUtf8));
  LCount := 0;
  I := 0;
  while I < Length(LUtf8) do
  begin
    if (LUtf8[I] = Ord('%')) and (I + 2 < Length(LUtf8)) and HexDigit(Char(LUtf8[I + 1]), LHigh)
      and HexDigit(Char(LUtf8[I + 2]), LLow) then
    begin
      LBytes[LCount] := LHigh * 16 + LLow;
      Inc(I, 3);
    end
    else
    begin
      LBytes[LCount] := LUtf8[I];
      Inc(I);
    end;
    Inc(LCount);
  end;
  SetLength(LBytes, LCount);
  try
    Result := PaUtf8BytesToString(LBytes, 'a percent-encoded value');
  except
    on ETextEncodingException do
      Result := AText;
  end;
end;

function ParseKeyValueList(const AText: string): TArray<THttpHeader>;
var
  LRest, LPair, LKey: string;
  LComma, LEquals, LCount: Integer;
begin
  Result := nil;
  LCount := 0;
  LRest := AText;
  while LRest <> '' do
  begin
    LComma := Pos(',', LRest);
    if LComma > 0 then
    begin
      LPair := Copy(LRest, 1, LComma - 1);
      Delete(LRest, 1, LComma);
    end
    else
    begin
      LPair := LRest;
      LRest := '';
    end;
    LEquals := Pos('=', LPair);
    if LEquals = 0 then
      Continue;
    LKey := Trim(PercentDecode(Copy(LPair, 1, LEquals - 1)));
    if LKey = '' then
      Continue;
    SetLength(Result, LCount + 1);
    Result[LCount].Name := LKey;
    Result[LCount].Value := Trim(PercentDecode(Copy(LPair, LEquals + 1, MaxInt)));
    Inc(LCount);
  end;
end;

function SpanAttribute(const AKey: string; AType: TSpanAttributeType): TSpanAttribute;
begin
  Result.Key := AKey;
  Result.ValueType := AType;
  Result.StringValue := '';
  Result.IntValue := 0;
  Result.DoubleValue := 0;
  Result.BoolValue := False;
end;

{ TTracingOptions }

class function TTracingOptions.Default(const AServiceName, AServiceVersion: string): TTracingOptions;
begin
  Result.ServiceName := AServiceName;
  Result.ServiceVersion := AServiceVersion;
  Result.ResourceAttributes := '';
  Result.SampleRatio := 1;
  Result.QueueCapacity := 2048;
  Result.MaxBatchSize := 512;
  Result.FlushIntervalMs := 5000;
end;

class function TTracingOptions.FromEnvironment(const AServiceName, AServiceVersion: string): TTracingOptions;
var
  LRatio: Double;
begin
  Result := Default(TAppConfig.Get('OTEL_SERVICE_NAME', AServiceName), AServiceVersion);
  Result.ResourceAttributes := TAppConfig.Get('OTEL_RESOURCE_ATTRIBUTES', '');
  if TryStrToFloat(TAppConfig.Get('OTEL_TRACES_SAMPLER_ARG', ''), LRatio, JsonFormatSettings)
    and (LRatio >= 0) and (LRatio <= 1) then
    Result.SampleRatio := LRatio;
  Result.QueueCapacity := TAppConfig.GetInt('OTEL_BSP_MAX_QUEUE_SIZE', Result.QueueCapacity);
  Result.FlushIntervalMs := TAppConfig.GetInt('OTEL_BSP_SCHEDULE_DELAY', Result.FlushIntervalMs);
  Result.MaxBatchSize := TAppConfig.GetInt('OTEL_BSP_MAX_EXPORT_BATCH_SIZE', Result.MaxBatchSize);
  if Result.QueueCapacity < 1 then
    Result.QueueCapacity := 2048;
  if Result.FlushIntervalMs < 1 then
    Result.FlushIntervalMs := 5000;
  if Result.MaxBatchSize < 1 then
    Result.MaxBatchSize := 512;
end;

{ TSpanProcessorThread }

constructor TSpanProcessorThread.Create(AOwner: TSpanProcessor);
begin
  FOwner := AOwner;
  inherited Create(False);
  FreeOnTerminate := False;
end;

procedure TSpanProcessorThread.Execute;
begin
  // Woken early only to stop; every interval, export what is queued.
  while FOwner.FWake.WaitFor(FOwner.FOptions.FlushIntervalMs) = wrTimeout do
    FOwner.Flush;
  FOwner.Flush;
end;

{ TSpanProcessor }

constructor TSpanProcessor.Create(const AOptions: TTracingOptions; const AExporter: ISpanExporter;
  const AOnError: TLogProc; AAutoFlush: Boolean);
begin
  inherited Create;
  FOptions := AOptions;
  FExporter := AExporter;
  FOnError := AOnError;
  FQueue := TQueue<TSpanData>.Create;
  FLock := TCriticalSection.Create;
  FExportLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, True, False, '');
  if AAutoFlush then
    FThread := TSpanProcessorThread.Create(Self);
end;

destructor TSpanProcessor.Destroy;
begin
  if FThread <> nil then
  begin
    FWake.SetEvent;
    FThread.WaitFor;
    FreeAndNil(FThread);
  end
  else
    Flush;
  FWake.Free;
  FExportLock.Free;
  FLock.Free;
  FQueue.Free;
  inherited;
end;

procedure TSpanProcessor.Enqueue(const ASpan: TSpanData);
begin
  FLock.Acquire;
  try
    if FQueue.Count >= FOptions.QueueCapacity then
    begin
      FQueue.Dequeue;
      Inc(FDropped);
    end;
    FQueue.Enqueue(ASpan);
  finally
    FLock.Release;
  end;
end;

function TSpanProcessor.TakeBatch: TSpanDataArray;
var
  LCount, I: Integer;
begin
  FLock.Acquire;
  try
    LCount := FQueue.Count;
    if LCount > FOptions.MaxBatchSize then
      LCount := FOptions.MaxBatchSize;
    Result := nil;
    SetLength(Result, LCount);
    for I := 0 to LCount - 1 do
      Result[I] := FQueue.Dequeue;
  finally
    FLock.Release;
  end;
end;

procedure TSpanProcessor.Flush;
var
  LBatch: TSpanDataArray;
  LError: string;
  LOk: Boolean;
begin
  if FExporter = nil then
    Exit;
  // One export at a time (the thread and a FlushNow may meet).
  FExportLock.Acquire;
  try
    repeat
      LBatch := TakeBatch;
      if Length(LBatch) = 0 then
        Break;
      LError := '';
      try
        LOk := FExporter.ExportSpans(LBatch, LError);
      except
        on E: Exception do
        begin
          LOk := False;
          LError := E.ClassName + ': ' + E.Message;
        end;
      end;
      if (not LOk) and Assigned(FOnError) then
        FOnError(Format('span export failed (%d spans dropped): %s', [Length(LBatch), LError]));
    until False;
  finally
    FExportLock.Release;
  end;
end;

function TSpanProcessor.PendingCount: Integer;
begin
  FLock.Acquire;
  try
    Result := FQueue.Count;
  finally
    FLock.Release;
  end;
end;

{ TSpan }

constructor TSpan.Create(const ATraceId, ASpanId, AParentSpanId, ATraceState: string;
  ASampled: Boolean; const AName: string; AKind: TSpanKind; AParent: TSpan);
begin
  inherited Create;
  FData.TraceId := ATraceId;
  FData.SpanId := ASpanId;
  FData.ParentSpanId := AParentSpanId;
  FData.TraceState := ATraceState;
  FData.Name := AName;
  FData.Kind := AKind;
  FData.Status := ssUnset;
  FData.StatusMessage := '';
  FData.Attributes := nil;
  FSampled := ASampled;
  FRecording := ASampled and TTracing.Enabled;
  FParentSpan := AParent;
  FParent := AParent;
  FData.StartUnixNano := UnixNanoOfLocal(TClock.Now);
  FStartTick := PcTickUs;
end;

destructor TSpan.Destroy;
begin
  // Freed unfinished (the last reference went away): don't leave the thread
  // pointing at it.
  if GCurrent = Pointer(Self) then
    LeaveCurrent;
  inherited;
end;

procedure TSpan.LeaveCurrent;
begin
  if GCurrent = Pointer(Self) then
  begin
    GCurrent := Pointer(FParentSpan);
  end;
end;

function TSpan.TraceId: string;
begin
  Result := FData.TraceId;
end;

function TSpan.SpanId: string;
begin
  Result := FData.SpanId;
end;

function TSpan.ParentSpanId: string;
begin
  Result := FData.ParentSpanId;
end;

function TSpan.Sampled: Boolean;
begin
  Result := FSampled;
end;

function TSpan.TraceParent: string;
begin
  Result := PcFormatTraceParent(FData.TraceId, FData.SpanId, FSampled);
end;

function TSpan.TraceState: string;
begin
  Result := FData.TraceState;
end;

procedure TSpan.SetName(const AName: string);
begin
  FData.Name := AName;
end;

procedure TSpan.AddAttribute(const AAttribute: TSpanAttribute);
var
  I: Integer;
begin
  if not FRecording or FFinished then
    Exit;
  for I := 0 to High(FData.Attributes) do
    if FData.Attributes[I].Key = AAttribute.Key then
    begin
      FData.Attributes[I] := AAttribute;
      Exit;
    end;
  SetLength(FData.Attributes, Length(FData.Attributes) + 1);
  FData.Attributes[High(FData.Attributes)] := AAttribute;
end;

procedure TSpan.SetAttribute(const AKey, AValue: string);
var
  LAttribute: TSpanAttribute;
begin
  LAttribute := SpanAttribute(AKey, satString);
  LAttribute.StringValue := AValue;
  AddAttribute(LAttribute);
end;

procedure TSpan.SetIntAttribute(const AKey: string; AValue: Int64);
var
  LAttribute: TSpanAttribute;
begin
  LAttribute := SpanAttribute(AKey, satInt);
  LAttribute.IntValue := AValue;
  AddAttribute(LAttribute);
end;

procedure TSpan.SetDoubleAttribute(const AKey: string; AValue: Double);
var
  LAttribute: TSpanAttribute;
begin
  LAttribute := SpanAttribute(AKey, satDouble);
  LAttribute.DoubleValue := AValue;
  AddAttribute(LAttribute);
end;

procedure TSpan.SetBoolAttribute(const AKey: string; AValue: Boolean);
var
  LAttribute: TSpanAttribute;
begin
  LAttribute := SpanAttribute(AKey, satBool);
  LAttribute.BoolValue := AValue;
  AddAttribute(LAttribute);
end;

procedure TSpan.SetStatus(AStatus: TSpanStatus; const AMessage: string);
begin
  if FFinished then
    Exit;
  FData.Status := AStatus;
  if AStatus = ssError then
    FData.StatusMessage := AMessage
  else
    FData.StatusMessage := '';
end;

procedure TSpan.Finish;
begin
  if FFinished then
    Exit;
  FFinished := True;
  FData.EndUnixNano := FData.StartUnixNano + (PcTickUs - FStartTick) * 1000;
  LeaveCurrent;
  if FRecording then
  begin
    GStateLock.Acquire;
    try
      if GProcessor <> nil then
        GProcessor.Enqueue(FData);
    finally
      GStateLock.Release;
    end;
  end;
end;

{ TTracing }

class procedure TTracing.Start(const AOptions: TTracingOptions; const AExporter: ISpanExporter;
  AAutoFlush: Boolean);
begin
  Start(AOptions, AExporter, nil, AAutoFlush);
end;

class procedure TTracing.Start(const AOptions: TTracingOptions; const AExporter: ISpanExporter;
  const AOnError: TLogProc; AAutoFlush: Boolean);
var
  LOld: TSpanProcessor;
begin
  GStateLock.Acquire;
  try
    LOld := GProcessor;
    GOptions := AOptions;
    GProcessor := TSpanProcessor.Create(AOptions, AExporter, AOnError, AAutoFlush);
  finally
    GStateLock.Release;
  end;
  LOld.Free;
end;

class procedure TTracing.Shutdown;
var
  LOld: TSpanProcessor;
begin
  GStateLock.Acquire;
  try
    LOld := GProcessor;
    GProcessor := nil;
  finally
    GStateLock.Release;
  end;
  // Exports what is left (the thread's last Flush, or Destroy's).
  LOld.Free;
end;

class function TTracing.Enabled: Boolean;
begin
  GStateLock.Acquire;
  try
    Result := GProcessor <> nil;
  finally
    GStateLock.Release;
  end;
end;

class function TTracing.Options: TTracingOptions;
begin
  GStateLock.Acquire;
  try
    Result := GOptions;
  finally
    GStateLock.Release;
  end;
end;

class function TTracing.ShouldSample(const ATraceId: string): Boolean;
var
  LRatio: Double;
  LValue: UInt64;
  I, LDigit: Integer;
begin
  LRatio := Options.SampleRatio;
  if LRatio >= 1 then
    Exit(True);
  if (LRatio <= 0) or (Length(ATraceId) <> 32) then
    Exit(False);
  LValue := 0;
  for I := 17 to 32 do
  begin
    if not HexDigit(ATraceId[I], LDigit) then
      Exit(False);
    LValue := (LValue shl 4) or UInt64(LDigit);
  end;
  // The top 53 bits are enough for a Double comparison.
  Result := (LValue shr 11) < UInt64(Trunc(LRatio * 9007199254740992.0));
end;

class function TTracing.StartSpanWith(const ATraceId, ASpanId, AParentSpanId, ATraceState: string;
  ASampled: Boolean; const AName: string; AKind: TSpanKind): ISpan;
var
  LSpan: TSpan;
begin
  LSpan := TSpan.Create(ATraceId, ASpanId, AParentSpanId, ATraceState, ASampled, AName, AKind,
    TSpan(GCurrent));
  Result := LSpan;
  GCurrent := Pointer(LSpan);
end;

class function TTracing.StartSpan(const AName: string; AKind: TSpanKind): ISpan;
var
  LParent: ISpan;
  LTraceId: string;
begin
  LParent := Current;
  if LParent <> nil then
    Result := StartSpanWith(LParent.TraceId, PcNewSpanId, LParent.SpanId, LParent.TraceState,
      LParent.Sampled, AName, AKind)
  else
  begin
    LTraceId := PcNewTraceId;
    Result := StartSpanWith(LTraceId, PcNewSpanId, '', '', ShouldSample(LTraceId), AName, AKind);
  end;
end;

class function TTracing.Current: ISpan;
begin
  if GCurrent = nil then
    Result := nil
  else
    Result := TSpan(GCurrent);
end;

class procedure TTracing.FlushNow;
begin
  GStateLock.Acquire;
  try
    if GProcessor <> nil then
      GProcessor.Flush;
  finally
    GStateLock.Release;
  end;
end;

class function TTracing.DroppedCount: Int64;
begin
  GStateLock.Acquire;
  try
    if GProcessor = nil then
      Result := 0
    else
    begin
      GProcessor.FLock.Acquire;
      try
        Result := GProcessor.FDropped;
      finally
        GProcessor.FLock.Release;
      end;
    end;
  finally
    GStateLock.Release;
  end;
end;

class function TTracing.PendingCount: Integer;
begin
  GStateLock.Acquire;
  try
    if GProcessor = nil then
      Result := 0
    else
      Result := GProcessor.PendingCount;
  finally
    GStateLock.Release;
  end;
end;

initialization
  GStateLock := TCriticalSection.Create;
  GOptions := TTracingOptions.Default('', '');

finalization
  // Without exporting: the exporter's units (an HTTP client) may be
  // finalized already. An application that must not lose the last spans
  // calls TTracing.Shutdown before it ends.
  if GProcessor <> nil then
  begin
    GProcessor.FExporter := nil;
    FreeAndNil(GProcessor);
  end;
  GStateLock.Free;

end.
