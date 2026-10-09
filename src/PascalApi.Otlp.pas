unit PascalApi.Otlp;

{$I pascalapi.inc}

(* OpenTelemetry's OTLP over HTTP with JSON encoding, for traces: the request
  body (pure, OtlpTracesJson) and an ISpanExporter that POSTs it
  (TOtlpHttpExporter).

    TTracing.Start(TTracingOptions.FromEnvironment('cities-api', '1.0.0'),
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
  OpenSSL. Any status other than 2xx is a failed batch. *)

interface

uses
  SysUtils,
  PascalApi.Http,
  PascalApi.Tracing;

const
  OTLP_DEFAULT_TRACES_ENDPOINT = 'http://localhost:4318/v1/traces';
  OTLP_DEFAULT_TIMEOUT_MS = 10000;
  /// telemetry.sdk.name of the resource.
  OTLP_SDK_NAME = 'pascal-api-infra-faa';

/// The resource attributes: service.name, service.version (when not ''),
/// telemetry.sdk.name and telemetry.sdk.version, then the pairs of
/// AOptions.ResourceAttributes (one that repeats a key above replaces it).
function OtlpResourceAttributes(const AOptions: TTracingOptions): TArray<THttpHeader>;

/// The body of POST /v1/traces for ASpans.
function OtlpTracesJson(const AOptions: TTracingOptions; const ASpans: TSpanDataArray): string;

/// The traces endpoint from the OTEL_EXPORTER_OTLP_* values (see the header).
function OtlpTracesEndpoint(const ATracesEndpoint, ABaseEndpoint: string): string;

type
  TOtlpHttpExporter = class(TInterfacedObject, ISpanExporter)
  private
    FEndpoint: string;
    FHeaders: TArray<THttpHeader>;
    FTimeoutMs: Integer;
  public
    constructor Create(const AEndpoint: string; const AHeaders: TArray<THttpHeader>;
      ATimeoutMs: Integer = OTLP_DEFAULT_TIMEOUT_MS);
    /// Endpoint, headers and timeout from the OTEL_EXPORTER_OTLP_* variables.
    class function FromEnvironment: TOtlpHttpExporter; static;
    function ExportSpans(const ASpans: TSpanDataArray; out AError: string): Boolean;
    property Endpoint: string read FEndpoint;
  end;

implementation

uses
  Classes,
  {$IFDEF FPC}
  fphttpclient,
  {$ELSE}
  System.Net.HttpClient,
  System.Net.URLClient,
  {$ENDIF}
  PascalJsonMapper.Json,
  PascalApi.Config,
  PascalApi.Text,
  PascalApi.Version;

const
  // SpanKind and StatusCode of opentelemetry/proto/trace/v1/trace.proto.
  SPAN_KIND_CODES: array[TSpanKind] of Integer = (1, 2, 3, 4, 5);
  STATUS_CODES: array[TSpanStatus] of Integer = (0, 1, 2);

function OtlpResourceAttributes(const AOptions: TTracingOptions): TArray<THttpHeader>;
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
  if AOptions.ServiceName <> '' then
    Add('service.name', AOptions.ServiceName);
  if AOptions.ServiceVersion <> '' then
    Add('service.version', AOptions.ServiceVersion);
  Add('telemetry.sdk.name', OTLP_SDK_NAME);
  Add('telemetry.sdk.version', PASCALAPI_VERSION_STRING);
  LExtra := ParseKeyValueList(AOptions.ResourceAttributes);
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

procedure WriteKeyValue(AWriter: TJsonWriter; const AKey: string; const AAttribute: TSpanAttribute);
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
  LAttribute: TSpanAttribute;
begin
  LAttribute.Key := AKey;
  LAttribute.ValueType := satString;
  LAttribute.StringValue := AValue;
  LAttribute.IntValue := 0;
  LAttribute.DoubleValue := 0;
  LAttribute.BoolValue := False;
  WriteKeyValue(AWriter, AKey, LAttribute);
end;

procedure WriteSpan(AWriter: TJsonWriter; const ASpan: TSpanData);
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

function OtlpTracesJson(const AOptions: TTracingOptions; const ASpans: TSpanDataArray): string;
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

{$IFDEF FPC}

function TOtlpHttpExporter.ExportSpans(const ASpans: TSpanDataArray; out AError: string): Boolean;
var
  LClient: TFPHTTPClient;
  LSent: TBytesStream;
  LReceived: TBytesStream;
  I, LStatus: Integer;
begin
  LClient := TFPHTTPClient.Create(nil);
  LSent := TBytesStream.Create(PaStringToUtf8Bytes(OtlpTracesJson(TTracing.Options, ASpans)));
  LReceived := TBytesStream.Create;
  try
    LClient.ConnectTimeout := FTimeoutMs;
    LClient.IOTimeout := FTimeoutMs;
    LClient.AllowRedirect := False;
    LClient.AddHeader('Content-Type', 'application/json');
    for I := 0 to High(FHeaders) do
      LClient.AddHeader(FHeaders[I].Name, FHeaders[I].Value);
    LClient.RequestBody := LSent;
    LClient.HTTPMethod('POST', FEndpoint, LReceived, []);
    LStatus := LClient.ResponseStatusCode;
    Result := (LStatus >= 200) and (LStatus < 300);
    if Result then
      AError := ''
    else
      AError := Format('%s answered %d', [FEndpoint, LStatus]);
  finally
    LClient.RequestBody := nil;
    LReceived.Free;
    LSent.Free;
    LClient.Free;
  end;
end;

{$ELSE}

function TOtlpHttpExporter.ExportSpans(const ASpans: TSpanDataArray; out AError: string): Boolean;
var
  LClient: THTTPClient;
  LRequest: IHTTPRequest;
  LSent: TBytesStream;
  LResponse: IHTTPResponse;
  I, LStatus: Integer;
begin
  LClient := THTTPClient.Create;
  LSent := TBytesStream.Create(PaStringToUtf8Bytes(OtlpTracesJson(TTracing.Options, ASpans)));
  try
    LClient.ConnectionTimeout := FTimeoutMs;
    LClient.ResponseTimeout := FTimeoutMs;
    LClient.HandleRedirects := False;
    LRequest := LClient.GetRequest('POST', FEndpoint);
    LRequest.SetHeaderValue('Content-Type', 'application/json');
    for I := 0 to High(FHeaders) do
      LRequest.SetHeaderValue(FHeaders[I].Name, FHeaders[I].Value);
    LRequest.SourceStream := LSent;
    LResponse := LClient.Execute(LRequest);
    LStatus := LResponse.StatusCode;
    Result := (LStatus >= 200) and (LStatus < 300);
    if Result then
      AError := ''
    else
      AError := Format('%s answered %d', [FEndpoint, LStatus]);
  finally
    // Released before the stream and the client they point to.
    LResponse := nil;
    LRequest := nil;
    LSent.Free;
    LClient.Free;
  end;
end;

{$ENDIF}

end.
