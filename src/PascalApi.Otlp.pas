unit PascalApi.Otlp;

{$I pascalapi.inc}

(* OpenTelemetry's OTLP over HTTP with JSON encoding, for traces: the request
  body (pure, OtlpTracesJson) and an IPcSpanExporter that POSTs it
  (TOtlpHttpExporter).

    TPcTracing.Start(TPcTracingOptions.FromEnvironment('cities-api', '1.0.0', ReadAppConfig),
      TOtlpHttpExporter.FromEnvironment, LOnError);

  The JSON follows the OTLP specification's JSON mapping: trace and span ids
  as hex (not base64, unlike protobuf's generic JSON mapping), enums as
  numbers, 64-bit integers (timestamps, intValue) as strings, attribute
  values wrapped by type ({"stringValue": ...}). The resource has
  service.name, service.version, telemetry.sdk.name/version, then
  OTEL_RESOURCE_ATTRIBUTES. One resourceSpans with one scopeSpans per
  request.

  Endpoint, as the specification says: OTEL_EXPORTER_OTLP_TRACES_ENDPOINT as
  is, else OTEL_EXPORTER_OTLP_ENDPOINT + '/v1/traces', else
  http://localhost:4318/v1/traces. OTEL_EXPORTER_OTLP_HEADERS
  ('key=value,...') are sent with every request (an API key for a hosted
  backend), OTEL_EXPORTER_OTLP_TIMEOUT is the timeout in milliseconds
  (10000). HTTP client: fphttpclient on FPC, THTTPClient on Delphi, as the MCP
  executor. On FPC an https endpoint needs the program to use the
  opensslsockets unit (fphttpclient finds its TLS handler there); this unit
  doesn't, so an API that sends to a local collector over http doesn't load
  OpenSSL. Any status other than 2xx is a failed batch.

  Metrics (0.26.0, asked by pascal-agenda-faa for a worker without HTTP):
  TOtlpMetricsExporter sends a TPcMetricRegistry (usually PcMetrics) to
  /v1/metrics every IntervalMs on a thread of its own, and once more when
  it is freed, so a console program pushes what /metrics would serve.

    LMetrics := TOtlpMetricsExporter.Create(PcMetrics,
      TOtlpMetricsOptions.FromEnvironment('agenda-worker', '1.0.0', ReadAppConfig), LOnError);
    try
      RunWorker;
    finally
      LMetrics.Free; // the last export, then the thread is joined
    end;

  The body (pure, OtlpMetricsJson) is the specification's JSON mapping: a
  counter is a monotonic sum, an up-down counter a non-monotonic sum, a
  gauge a gauge, a histogram a histogram (explicitBounds, bucketCounts);
  cumulative temporality, every point starting when the exporter was
  created; values as asDouble; uint64 counts as strings; the labels as
  string attributes; the resource as for traces. A metric without series
  is left out, and an export with no series sends nothing. Settings:
  OTEL_EXPORTER_OTLP_METRICS_ENDPOINT as is, else OTEL_EXPORTER_OTLP_ENDPOINT
  + '/v1/metrics', else http://localhost:4318/v1/metrics; headers and
  timeout from OTEL_EXPORTER_OTLP_METRICS_HEADERS/_TIMEOUT, else the
  OTEL_EXPORTER_OTLP_ ones; OTEL_METRIC_EXPORT_INTERVAL (60000 ms, the
  specification's default). A failed export (a status other than 2xx, the
  collector down) goes to the error callback as "metric export failed:
  ...", never to the program; the next one sends the cumulative values
  again, so nothing is lost but the points in between. *)

interface

uses
  SysUtils,
  Classes,
  SyncObjs,
  PascalApi.Http,
  PascalCommon.Metrics,
  PascalCommon.Tracing;

const
  OTLP_DEFAULT_TRACES_ENDPOINT = 'http://localhost:4318/v1/traces';
  OTLP_DEFAULT_METRICS_ENDPOINT = 'http://localhost:4318/v1/metrics';
  OTLP_DEFAULT_TIMEOUT_MS = 10000;
  /// OTEL_METRIC_EXPORT_INTERVAL's default, in milliseconds.
  OTLP_DEFAULT_METRIC_INTERVAL_MS = 60000;
  /// telemetry.sdk.name of the resource.
  OTLP_SDK_NAME = 'pascal-api-infra-faa';

type
  /// Where and how often TOtlpMetricsExporter sends (0.26.0).
  TOtlpMetricsOptions = record
    ServiceName: string;
    ServiceVersion: string;
    /// 'key=value,key=value' (OTEL_RESOURCE_ATTRIBUTES).
    ResourceAttributes: string;
    Endpoint: string;
    Headers: TArray<THttpHeader>;
    TimeoutMs: Integer;
    IntervalMs: Integer;
    /// The default endpoint, no headers, 10 s timeout, 60 s interval.
    class function Default(const AServiceName, AServiceVersion: string): TOtlpMetricsOptions; static;
    /// Default, then the OTEL_* variables through ALookup (ReadAppConfig keeps
    /// the .env; see the unit header): OTEL_SERVICE_NAME replaces
    /// AServiceName; an invalid number keeps the default.
    class function FromEnvironment(const AServiceName, AServiceVersion: string;
      ALookup: TPcEnvironmentLookup): TOtlpMetricsOptions; static;
  end;

  /// Sends one OTLP request body; TOtlpMetricsExporter's seam for tests.
  IOtlpSender = interface
    ['{FC13E684-3479-4B54-B0D0-85BCC6791187}']
    /// False (and AError) for a status other than 2xx; may raise on a
    /// transport failure.
    function Send(const ABody: string; out AError: string): Boolean;
  end;

  /// POSTs to AEndpoint, as TOtlpHttpExporter does.
  TOtlpHttpSender = class(TInterfacedObject, IOtlpSender)
  private
    FEndpoint: string;
    FHeaders: TArray<THttpHeader>;
    FTimeoutMs: Integer;
  public
    constructor Create(const AEndpoint: string; const AHeaders: TArray<THttpHeader>;
      ATimeoutMs: Integer = OTLP_DEFAULT_TIMEOUT_MS);
    function Send(const ABody: string; out AError: string): Boolean;
  end;

  /// Exports a registry's metrics on its own thread (see the unit header).
  /// Free stops the thread and exports once more.
  TOtlpMetricsExporter = class
  private
    FRegistry: TPcMetricRegistry;
    FOptions: TOtlpMetricsOptions;
    FSender: IOtlpSender;
    FOnError: TPcLogProc;
    FStartUnixNano: Int64;
    FLock: TCriticalSection;
    FThread: TThread;
  public
    /// Sends to AOptions.Endpoint every AOptions.IntervalMs. ARegistry must
    /// outlive the exporter (PcMetrics lives until finalization).
    constructor Create(ARegistry: TPcMetricRegistry; const AOptions: TOtlpMetricsOptions;
      const AOnError: TPcLogProc); overload;
    /// Through ASender; AAutoExport = False (tests) starts no thread: only
    /// ExportNow and Free export.
    constructor Create(ARegistry: TPcMetricRegistry; const AOptions: TOtlpMetricsOptions;
      const ASender: IOtlpSender; const AOnError: TPcLogProc; AAutoExport: Boolean = True); overload;
    destructor Destroy; override;
    /// Exports now. Never raises: False after telling the error callback.
    /// True also when there was nothing to send.
    function ExportNow: Boolean;
    property Options: TOtlpMetricsOptions read FOptions;
  end;

/// The resource attributes: service.name, service.version (when not ''),
/// telemetry.sdk.name and telemetry.sdk.version, then the pairs of
/// AOptions.ResourceAttributes (one that repeats a key above replaces it).
function OtlpResourceAttributes(const AOptions: TPcTracingOptions): TArray<THttpHeader>; overload;
function OtlpResourceAttributes(const AServiceName, AServiceVersion,
  AResourceAttributes: string): TArray<THttpHeader>; overload;

/// The body of POST /v1/metrics for every series of ARegistry, read now:
/// sums start at AStartUnixNano, every point is at ATimeUnixNano. '' when
/// no metric has a series.
function OtlpMetricsJson(const AOptions: TOtlpMetricsOptions; ARegistry: TPcMetricRegistry;
  AStartUnixNano, ATimeUnixNano: Int64): string;

/// The metrics endpoint from the OTEL_EXPORTER_OTLP_* values (see the header).
function OtlpMetricsEndpoint(const AMetricsEndpoint, ABaseEndpoint: string): string;

/// The body of POST /v1/traces for ASpans.
function OtlpTracesJson(const AOptions: TPcTracingOptions; const ASpans: TPcSpanDataArray): string;

/// The pairs of 'key=value,key=value' (OTEL_RESOURCE_ATTRIBUTES and
/// OTEL_EXPORTER_OTLP_HEADERS): trimmed, '%XX' decoded; pairs without '=' or
/// with an empty key are skipped.
function ParseKeyValueList(const AText: string): TArray<THttpHeader>;

/// The traces endpoint from the OTEL_EXPORTER_OTLP_* values (see the header).
function OtlpTracesEndpoint(const ATracesEndpoint, ABaseEndpoint: string): string;

type
  TOtlpHttpExporter = class(TInterfacedObject, IPcSpanExporter)
  private
    FEndpoint: string;
    FHeaders: TArray<THttpHeader>;
    FTimeoutMs: Integer;
  public
    constructor Create(const AEndpoint: string; const AHeaders: TArray<THttpHeader>;
      ATimeoutMs: Integer = OTLP_DEFAULT_TIMEOUT_MS);
    /// Endpoint, headers and timeout from the OTEL_EXPORTER_OTLP_* variables.
    class function FromEnvironment: TOtlpHttpExporter; static;
    function ExportSpans(const ASpans: TPcSpanDataArray; out AError: string): Boolean;
    property Endpoint: string read FEndpoint;
  end;

implementation

uses
  {$IFDEF FPC}
  fphttpclient,
  {$ELSE}
  System.Net.HttpClient,
  System.Net.URLClient,
  {$ENDIF}
  Math,
  PascalJsonMapper.Json,
  PascalCommon.SystemContext,
  PascalApi.Config,
  PascalApi.Text,
  PascalApi.Version;

const
  // SpanKind and StatusCode of opentelemetry/proto/trace/v1/trace.proto.
  SPAN_KIND_CODES: array[TPcSpanKind] of Integer = (1, 2, 3, 4, 5);
  STATUS_CODES: array[TPcSpanStatus] of Integer = (0, 1, 2);

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

function OtlpResourceAttributes(const AOptions: TPcTracingOptions): TArray<THttpHeader>;
begin
  Result := OtlpResourceAttributes(AOptions.ServiceName, AOptions.ServiceVersion,
    AOptions.ResourceAttributes);
end;

function OtlpResourceAttributes(const AServiceName, AServiceVersion,
  AResourceAttributes: string): TArray<THttpHeader>;
var
  LList: TArray<THttpHeader>;
  LExtra: TArray<THttpHeader>;
  I, J: Integer;
  LFound: Boolean;

  // Into LList, not Result: a nested routine writing the outer function's
  // Result is not something both compilers are known to accept.
  procedure Add(const AKey, AValue: string);
  begin
    SetLength(LList, Length(LList) + 1);
    LList[High(LList)].Name := AKey;
    LList[High(LList)].Value := AValue;
  end;

begin
  LList := nil;
  if AServiceName <> '' then
    Add('service.name', AServiceName);
  if AServiceVersion <> '' then
    Add('service.version', AServiceVersion);
  Add('telemetry.sdk.name', OTLP_SDK_NAME);
  Add('telemetry.sdk.version', PASCALAPI_VERSION_STRING);
  LExtra := ParseKeyValueList(AResourceAttributes);
  for I := 0 to High(LExtra) do
  begin
    LFound := False;
    for J := 0 to High(LList) do
      if LList[J].Name = LExtra[I].Name then
      begin
        LList[J].Value := LExtra[I].Value;
        LFound := True;
      end;
    if not LFound then
      Add(LExtra[I].Name, LExtra[I].Value);
  end;
  Result := LList;
end;

procedure WriteKeyValue(AWriter: TJsonWriter; const AKey: string; const AAttribute: TPcSpanAttribute);
begin
  AWriter.BeginObject;
  AWriter.Name('key');
  AWriter.WriteString(AKey);
  AWriter.Name('value');
  AWriter.BeginObject;
  case AAttribute.ValueType of
    satString:
      begin
        AWriter.Name('stringValue');
        AWriter.WriteString(AAttribute.StringValue);
      end;
    satInt:
      begin
        AWriter.Name('intValue');
        AWriter.WriteString(IntToStr(AAttribute.IntValue));
      end;
    satDouble:
      begin
        AWriter.Name('doubleValue');
        AWriter.WriteDouble(AAttribute.DoubleValue);
      end;
    satBool:
      begin
        AWriter.Name('boolValue');
        AWriter.WriteBoolean(AAttribute.BoolValue);
      end;
  end;
  AWriter.EndObject;
  AWriter.EndObject;
end;

procedure WriteStringKeyValue(AWriter: TJsonWriter; const AKey, AValue: string);
var
  LAttribute: TPcSpanAttribute;
begin
  LAttribute.Key := AKey;
  LAttribute.ValueType := satString;
  LAttribute.StringValue := AValue;
  LAttribute.IntValue := 0;
  LAttribute.DoubleValue := 0;
  LAttribute.BoolValue := False;
  WriteKeyValue(AWriter, AKey, LAttribute);
end;

procedure WriteSpan(AWriter: TJsonWriter; const ASpan: TPcSpanData);
var
  I: Integer;
begin
  AWriter.BeginObject;
  AWriter.Name('traceId');
  AWriter.WriteString(ASpan.TraceId);
  AWriter.Name('spanId');
  AWriter.WriteString(ASpan.SpanId);
  if ASpan.TraceState <> '' then
  begin
    AWriter.Name('traceState');
    AWriter.WriteString(ASpan.TraceState);
  end;
  if ASpan.ParentSpanId <> '' then
  begin
    AWriter.Name('parentSpanId');
    AWriter.WriteString(ASpan.ParentSpanId);
  end;
  AWriter.Name('name');
  AWriter.WriteString(ASpan.Name);
  AWriter.Name('kind');
  AWriter.WriteInt64(SPAN_KIND_CODES[ASpan.Kind]);
  AWriter.Name('startTimeUnixNano');
  AWriter.WriteString(IntToStr(ASpan.StartUnixNano));
  AWriter.Name('endTimeUnixNano');
  AWriter.WriteString(IntToStr(ASpan.EndUnixNano));
  AWriter.Name('attributes');
  AWriter.BeginArray;
  for I := 0 to High(ASpan.Attributes) do
    WriteKeyValue(AWriter, ASpan.Attributes[I].Key, ASpan.Attributes[I]);
  AWriter.EndArray;
  AWriter.Name('status');
  AWriter.BeginObject;
  if ASpan.StatusMessage <> '' then
  begin
    AWriter.Name('message');
    AWriter.WriteString(ASpan.StatusMessage);
  end;
  AWriter.Name('code');
  AWriter.WriteInt64(STATUS_CODES[ASpan.Status]);
  AWriter.EndObject;
  AWriter.EndObject;
end;

function OtlpTracesJson(const AOptions: TPcTracingOptions; const ASpans: TPcSpanDataArray): string;
var
  LWriter: TJsonWriter;
  LResource: TArray<THttpHeader>;
  I: Integer;
begin
  LResource := OtlpResourceAttributes(AOptions);
  LWriter := TJsonWriter.Create;
  try
    LWriter.BeginObject;
    LWriter.Name('resourceSpans');
    LWriter.BeginArray;
    LWriter.BeginObject;
    LWriter.Name('resource');
    LWriter.BeginObject;
    LWriter.Name('attributes');
    LWriter.BeginArray;
    for I := 0 to High(LResource) do
      WriteStringKeyValue(LWriter, LResource[I].Name, LResource[I].Value);
    LWriter.EndArray;
    LWriter.EndObject;
    LWriter.Name('scopeSpans');
    LWriter.BeginArray;
    LWriter.BeginObject;
    LWriter.Name('scope');
    LWriter.BeginObject;
    LWriter.Name('name');
    LWriter.WriteString(OTLP_SDK_NAME);
    LWriter.Name('version');
    LWriter.WriteString(PASCALAPI_VERSION_STRING);
    LWriter.EndObject;
    LWriter.Name('spans');
    LWriter.BeginArray;
    for I := 0 to High(ASpans) do
      WriteSpan(LWriter, ASpans[I]);
    LWriter.EndArray;
    LWriter.EndObject;
    LWriter.EndArray;
    LWriter.EndObject;
    LWriter.EndArray;
    LWriter.EndObject;
    Result := LWriter.ToString;
  finally
    LWriter.Free;
  end;
end;

function OtlpTracesEndpoint(const ATracesEndpoint, ABaseEndpoint: string): string;
begin
  if Trim(ATracesEndpoint) <> '' then
    Exit(Trim(ATracesEndpoint));
  Result := Trim(ABaseEndpoint);
  if Result = '' then
    Exit(OTLP_DEFAULT_TRACES_ENDPOINT);
  while (Result <> '') and (Result[Length(Result)] = '/') do
    SetLength(Result, Length(Result) - 1);
  Result := Result + '/v1/traces';
end;

{ TOtlpHttpExporter }

constructor TOtlpHttpExporter.Create(const AEndpoint: string; const AHeaders: TArray<THttpHeader>;
  ATimeoutMs: Integer);
begin
  inherited Create;
  FEndpoint := AEndpoint;
  FHeaders := Copy(AHeaders, 0, Length(AHeaders));
  FTimeoutMs := ATimeoutMs;
end;

class function TOtlpHttpExporter.FromEnvironment: TOtlpHttpExporter;
var
  LTimeout: Integer;
begin
  LTimeout := TAppConfig.GetInt('OTEL_EXPORTER_OTLP_TIMEOUT', OTLP_DEFAULT_TIMEOUT_MS);
  if LTimeout < 1 then
    LTimeout := OTLP_DEFAULT_TIMEOUT_MS;
  Result := TOtlpHttpExporter.Create(
    OtlpTracesEndpoint(TAppConfig.Get('OTEL_EXPORTER_OTLP_TRACES_ENDPOINT', ''),
      TAppConfig.Get('OTEL_EXPORTER_OTLP_ENDPOINT', '')),
    ParseKeyValueList(TAppConfig.Get('OTEL_EXPORTER_OTLP_HEADERS', '')), LTimeout);
end;

// One POST of ABody (JSON) to AEndpoint: True for a 2xx answer. Raises on a
// transport failure (refused, timeout).
{$IFDEF FPC}

function OtlpPost(const AEndpoint: string; const AHeaders: TArray<THttpHeader>;
  ATimeoutMs: Integer; const ABody: string; out AError: string): Boolean;
var
  LClient: TFPHTTPClient;
  LSent: TBytesStream;
  LReceived: TBytesStream;
  I, LStatus: Integer;
begin
  LClient := TFPHTTPClient.Create(nil);
  LSent := TBytesStream.Create(PaStringToUtf8Bytes(ABody));
  LReceived := TBytesStream.Create;
  try
    LClient.ConnectTimeout := ATimeoutMs;
    LClient.IOTimeout := ATimeoutMs;
    LClient.AllowRedirect := False;
    LClient.AddHeader('Content-Type', 'application/json');
    for I := 0 to High(AHeaders) do
      LClient.AddHeader(AHeaders[I].Name, AHeaders[I].Value);
    LClient.RequestBody := LSent;
    LClient.HTTPMethod('POST', AEndpoint, LReceived, []);
    LStatus := LClient.ResponseStatusCode;
    Result := (LStatus >= 200) and (LStatus < 300);
    if Result then
      AError := ''
    else
      AError := Format('%s answered %d', [AEndpoint, LStatus]);
  finally
    LClient.RequestBody := nil;
    LReceived.Free;
    LSent.Free;
    LClient.Free;
  end;
end;

{$ELSE}

function OtlpPost(const AEndpoint: string; const AHeaders: TArray<THttpHeader>;
  ATimeoutMs: Integer; const ABody: string; out AError: string): Boolean;
var
  LClient: THTTPClient;
  LRequest: IHTTPRequest;
  LSent: TBytesStream;
  LResponse: IHTTPResponse;
  I, LStatus: Integer;
begin
  LClient := THTTPClient.Create;
  LSent := TBytesStream.Create(PaStringToUtf8Bytes(ABody));
  try
    LClient.ConnectionTimeout := ATimeoutMs;
    LClient.ResponseTimeout := ATimeoutMs;
    LClient.HandleRedirects := False;
    LRequest := LClient.GetRequest('POST', AEndpoint);
    LRequest.SetHeaderValue('Content-Type', 'application/json');
    for I := 0 to High(AHeaders) do
      LRequest.SetHeaderValue(AHeaders[I].Name, AHeaders[I].Value);
    LRequest.SourceStream := LSent;
    LResponse := LClient.Execute(LRequest);
    LStatus := LResponse.StatusCode;
    Result := (LStatus >= 200) and (LStatus < 300);
    if Result then
      AError := ''
    else
      AError := Format('%s answered %d', [AEndpoint, LStatus]);
  finally
    // Released before the stream and the client they point to.
    LResponse := nil;
    LRequest := nil;
    LSent.Free;
    LClient.Free;
  end;
end;

{$ENDIF}

function TOtlpHttpExporter.ExportSpans(const ASpans: TPcSpanDataArray; out AError: string): Boolean;
begin
  Result := OtlpPost(FEndpoint, FHeaders, FTimeoutMs, OtlpTracesJson(TPcTracing.Options, ASpans),
    AError);
end;

{ Metrics: the body }

function OtlpMetricsEndpoint(const AMetricsEndpoint, ABaseEndpoint: string): string;
begin
  if Trim(AMetricsEndpoint) <> '' then
    Exit(Trim(AMetricsEndpoint));
  Result := Trim(ABaseEndpoint);
  if Result = '' then
    Exit(OTLP_DEFAULT_METRICS_ENDPOINT);
  while (Result <> '') and (Result[Length(Result)] = '/') do
    SetLength(Result, Length(Result) - 1);
  Result := Result + '/v1/metrics';
end;

// A Double as OTLP's JSON writes it: a number, or the protobuf JSON
// mapping's "NaN"/"Infinity"/"-Infinity" strings (a gauge may be set to an
// infinity; JSON has no number for it).
procedure WriteOtlpDouble(AWriter: TJsonWriter; AValue: Double);
begin
  if IsNan(AValue) then
    AWriter.WriteString('NaN')
  else if IsInfinite(AValue) then
  begin
    if AValue > 0 then
      AWriter.WriteString('Infinity')
    else
      AWriter.WriteString('-Infinity');
  end
  else
    AWriter.WriteDouble(AValue);
end;

procedure WritePointAttributes(AWriter: TJsonWriter; AMetric: TPcMetric;
  const APoint: TPcMetricPoint);
var
  I: Integer;
begin
  AWriter.Name('attributes');
  AWriter.BeginArray;
  for I := 0 to High(AMetric.LabelNames) do
    if I <= High(APoint.LabelValues) then
      WriteStringKeyValue(AWriter, AMetric.LabelNames[I], APoint.LabelValues[I]);
  AWriter.EndArray;
end;

procedure WriteMetric(AWriter: TJsonWriter; AMetric: TPcMetric; const APoints: TPcMetricPoints;
  AStartUnixNano, ATimeUnixNano: Int64);
var
  I, J: Integer;
begin
  AWriter.BeginObject;
  AWriter.Name('name');
  AWriter.WriteString(AMetric.Name);
  if AMetric.Description <> '' then
  begin
    AWriter.Name('description');
    AWriter.WriteString(AMetric.Description);
  end;
  if AMetric.MetricUnit <> '' then
  begin
    AWriter.Name('unit');
    AWriter.WriteString(AMetric.MetricUnit);
  end;
  case AMetric.Kind of
    mkCounter, mkUpDownCounter: AWriter.Name('sum');
    mkGauge: AWriter.Name('gauge');
  else
    AWriter.Name('histogram');
  end;
  AWriter.BeginObject;
  AWriter.Name('dataPoints');
  AWriter.BeginArray;
  for I := 0 to High(APoints) do
  begin
    AWriter.BeginObject;
    WritePointAttributes(AWriter, AMetric, APoints[I]);
    // A gauge has no start: its value is a sample, not an accumulation.
    if AMetric.Kind <> mkGauge then
    begin
      AWriter.Name('startTimeUnixNano');
      AWriter.WriteString(IntToStr(AStartUnixNano));
    end;
    AWriter.Name('timeUnixNano');
    AWriter.WriteString(IntToStr(ATimeUnixNano));
    if AMetric.Kind = mkHistogram then
    begin
      AWriter.Name('count');
      AWriter.WriteString(UIntToStr(APoints[I].Count));
      AWriter.Name('sum');
      WriteOtlpDouble(AWriter, APoints[I].Sum);
      AWriter.Name('bucketCounts');
      AWriter.BeginArray;
      for J := 0 to High(APoints[I].BucketCounts) do
        AWriter.WriteString(UIntToStr(APoints[I].BucketCounts[J]));
      AWriter.EndArray;
      AWriter.Name('explicitBounds');
      AWriter.BeginArray;
      for J := 0 to High(AMetric.Bounds) do
        WriteOtlpDouble(AWriter, AMetric.Bounds[J]);
      AWriter.EndArray;
    end
    else
    begin
      AWriter.Name('asDouble');
      WriteOtlpDouble(AWriter, APoints[I].Value);
    end;
    AWriter.EndObject;
  end;
  AWriter.EndArray;
  // AggregationTemporality of opentelemetry/proto/metrics/v1/metrics.proto:
  // 2 is cumulative.
  if AMetric.Kind <> mkGauge then
  begin
    AWriter.Name('aggregationTemporality');
    AWriter.WriteInt64(2);
  end;
  if AMetric.Kind in [mkCounter, mkUpDownCounter] then
  begin
    AWriter.Name('isMonotonic');
    AWriter.WriteBoolean(AMetric.Kind = mkCounter);
  end;
  AWriter.EndObject;
  AWriter.EndObject;
end;

function OtlpMetricsJson(const AOptions: TOtlpMetricsOptions; ARegistry: TPcMetricRegistry;
  AStartUnixNano, ATimeUnixNano: Int64): string;
var
  LWriter: TJsonWriter;
  LResource: TArray<THttpHeader>;
  LMetrics: TPcMetricList;
  LPoints: TPcMetricPoints;
  LAny: Boolean;
  I: Integer;
begin
  LResource := OtlpResourceAttributes(AOptions.ServiceName, AOptions.ServiceVersion,
    AOptions.ResourceAttributes);
  LMetrics := ARegistry.Metrics;
  LAny := False;
  LWriter := TJsonWriter.Create;
  try
    LWriter.BeginObject;
    LWriter.Name('resourceMetrics');
    LWriter.BeginArray;
    LWriter.BeginObject;
    LWriter.Name('resource');
    LWriter.BeginObject;
    LWriter.Name('attributes');
    LWriter.BeginArray;
    for I := 0 to High(LResource) do
      WriteStringKeyValue(LWriter, LResource[I].Name, LResource[I].Value);
    LWriter.EndArray;
    LWriter.EndObject;
    LWriter.Name('scopeMetrics');
    LWriter.BeginArray;
    LWriter.BeginObject;
    LWriter.Name('scope');
    LWriter.BeginObject;
    LWriter.Name('name');
    LWriter.WriteString(OTLP_SDK_NAME);
    LWriter.Name('version');
    LWriter.WriteString(PASCALAPI_VERSION_STRING);
    LWriter.EndObject;
    LWriter.Name('metrics');
    LWriter.BeginArray;
    for I := 0 to High(LMetrics) do
    begin
      // One snapshot per metric: its points are read once, written once.
      LPoints := LMetrics[I].Snapshot;
      if Length(LPoints) = 0 then
        Continue;
      WriteMetric(LWriter, LMetrics[I], LPoints, AStartUnixNano, ATimeUnixNano);
      LAny := True;
    end;
    LWriter.EndArray;
    LWriter.EndObject;
    LWriter.EndArray;
    LWriter.EndObject;
    LWriter.EndArray;
    LWriter.EndObject;
    if LAny then
      Result := LWriter.ToString
    else
      Result := '';
  finally
    LWriter.Free;
  end;
end;

{ TOtlpMetricsOptions }

class function TOtlpMetricsOptions.Default(const AServiceName,
  AServiceVersion: string): TOtlpMetricsOptions;
begin
  Result.ServiceName := AServiceName;
  Result.ServiceVersion := AServiceVersion;
  Result.ResourceAttributes := '';
  Result.Endpoint := OTLP_DEFAULT_METRICS_ENDPOINT;
  Result.Headers := nil;
  Result.TimeoutMs := OTLP_DEFAULT_TIMEOUT_MS;
  Result.IntervalMs := OTLP_DEFAULT_METRIC_INTERVAL_MS;
end;

// A positive count of milliseconds: digits only (TryStrToInt wraps around
// on FPC 3.2.2 and reads '$3'), at most 9 of them; else ADefault.
function PositiveMs(const AText: string; ADefault: Integer): Integer;
var
  LText: string;
  I: Integer;
begin
  LText := Trim(AText);
  if (LText = '') or (Length(LText) > 9) then
    Exit(ADefault);
  Result := 0;
  for I := 1 to Length(LText) do
  begin
    if (LText[I] < '0') or (LText[I] > '9') then
      Exit(ADefault);
    Result := Result * 10 + Ord(LText[I]) - Ord('0');
  end;
  if Result < 1 then
    Result := ADefault;
end;

// The signal's own variable, else the general one.
function FirstSet(ALookup: TPcEnvironmentLookup; const ASignalName, AGeneralName: string): string;
begin
  Result := Trim(ALookup(ASignalName));
  if Result = '' then
    Result := Trim(ALookup(AGeneralName));
end;

class function TOtlpMetricsOptions.FromEnvironment(const AServiceName, AServiceVersion: string;
  ALookup: TPcEnvironmentLookup): TOtlpMetricsOptions;
var
  LName: string;
begin
  LName := Trim(ALookup('OTEL_SERVICE_NAME'));
  if LName = '' then
    LName := AServiceName;
  Result := Default(LName, AServiceVersion);
  Result.ResourceAttributes := Trim(ALookup('OTEL_RESOURCE_ATTRIBUTES'));
  Result.Endpoint := OtlpMetricsEndpoint(ALookup('OTEL_EXPORTER_OTLP_METRICS_ENDPOINT'),
    ALookup('OTEL_EXPORTER_OTLP_ENDPOINT'));
  Result.Headers := ParseKeyValueList(FirstSet(ALookup, 'OTEL_EXPORTER_OTLP_METRICS_HEADERS',
    'OTEL_EXPORTER_OTLP_HEADERS'));
  Result.TimeoutMs := PositiveMs(FirstSet(ALookup, 'OTEL_EXPORTER_OTLP_METRICS_TIMEOUT',
    'OTEL_EXPORTER_OTLP_TIMEOUT'), OTLP_DEFAULT_TIMEOUT_MS);
  Result.IntervalMs := PositiveMs(ALookup('OTEL_METRIC_EXPORT_INTERVAL'),
    OTLP_DEFAULT_METRIC_INTERVAL_MS);
end;

{ TOtlpHttpSender }

constructor TOtlpHttpSender.Create(const AEndpoint: string; const AHeaders: TArray<THttpHeader>;
  ATimeoutMs: Integer);
begin
  inherited Create;
  FEndpoint := AEndpoint;
  FHeaders := Copy(AHeaders, 0, Length(AHeaders));
  FTimeoutMs := ATimeoutMs;
end;

function TOtlpHttpSender.Send(const ABody: string; out AError: string): Boolean;
begin
  Result := OtlpPost(FEndpoint, FHeaders, FTimeoutMs, ABody, AError);
end;

{ TOtlpMetricsThread }

type
  // Waits IntervalMs on an event, exports, again; the event (set by
  // Destroy) ends the wait at once, so stopping doesn't wait an interval.
  TOtlpMetricsThread = class(TThread)
  private
    FOwner: TOtlpMetricsExporter;
    FIntervalMs: Cardinal;
    FWake: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TOtlpMetricsExporter; AIntervalMs: Integer);
    destructor Destroy; override;
    procedure Stop;
  end;

constructor TOtlpMetricsThread.Create(AOwner: TOtlpMetricsExporter; AIntervalMs: Integer);
begin
  FOwner := AOwner;
  FIntervalMs := AIntervalMs;
  FWake := TEvent.Create(nil, True, False, '');
  inherited Create(False);
end;

destructor TOtlpMetricsThread.Destroy;
begin
  FWake.Free;
  inherited;
end;

procedure TOtlpMetricsThread.Execute;
begin
  while not Terminated do
  begin
    if FWake.WaitFor(FIntervalMs) <> wrTimeout then
      Break;
    FOwner.ExportNow;
  end;
end;

procedure TOtlpMetricsThread.Stop;
begin
  Terminate;
  FWake.SetEvent;
  WaitFor;
end;

{ TOtlpMetricsExporter }

constructor TOtlpMetricsExporter.Create(ARegistry: TPcMetricRegistry;
  const AOptions: TOtlpMetricsOptions; const AOnError: TPcLogProc);
begin
  Create(ARegistry, AOptions, TOtlpHttpSender.Create(AOptions.Endpoint, AOptions.Headers,
    AOptions.TimeoutMs), AOnError, True);
end;

constructor TOtlpMetricsExporter.Create(ARegistry: TPcMetricRegistry;
  const AOptions: TOtlpMetricsOptions; const ASender: IOtlpSender; const AOnError: TPcLogProc;
  AAutoExport: Boolean);
begin
  inherited Create;
  if ARegistry = nil then
    raise EArgumentException.Create('TOtlpMetricsExporter: the registry is nil');
  FRegistry := ARegistry;
  FOptions := AOptions;
  if FOptions.IntervalMs < 1 then
    FOptions.IntervalMs := OTLP_DEFAULT_METRIC_INTERVAL_MS;
  FSender := ASender;
  FOnError := AOnError;
  FStartUnixNano := PcUnixNanoOfLocal(TClock.Now);
  FLock := TCriticalSection.Create;
  if AAutoExport then
    FThread := TOtlpMetricsThread.Create(Self, FOptions.IntervalMs);
end;

destructor TOtlpMetricsExporter.Destroy;
begin
  // The thread first (it may be exporting), then the last export here.
  if FThread <> nil then
  begin
    TOtlpMetricsThread(FThread).Stop;
    FreeAndNil(FThread);
  end;
  if FLock <> nil then
    ExportNow;
  FSender := nil;
  FLock.Free;
  inherited;
end;

function TOtlpMetricsExporter.ExportNow: Boolean;
var
  LBody, LError: string;
begin
  Result := True;
  FLock.Enter;
  try
    try
      LBody := OtlpMetricsJson(FOptions, FRegistry, FStartUnixNano, PcUnixNanoOfLocal(TClock.Now));
      if LBody = '' then
        Exit;
      Result := FSender.Send(LBody, LError);
    except
      on E: Exception do
      begin
        Result := False;
        LError := E.ClassName + ': ' + E.Message;
      end;
    end;
    if not Result and Assigned(FOnError) then
      try
        FOnError('metric export failed: ' + LError);
      except
        // The callback's own failure stays here: the exporter must go on.
      end;
  finally
    FLock.Leave;
  end;
end;

end.
