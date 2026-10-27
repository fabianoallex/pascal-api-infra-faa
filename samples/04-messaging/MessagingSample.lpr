program MessagingSample;

(* Sample 04: the probe API behind docs/guide/messaging.md. An API on this
  library that uses pascal-redis-faa (a shared TRedisClient, cache-aside in
  a handler, and a cache that falls back when Redis is down) and
  pascal-amqp-faa (publishing from handlers on one shared channel, with and
  without publisher confirms, and a consumer in the same process). Spans are
  printed by a small exporter, to show the trace.

  Not like samples 01-03: FPC only, built by hand (build_fpc.sh), not by CI,
  since the two libraries aren't dependencies of this repository. Measured
  on FPC 3.2.2/Windows on 2026-10-14 with pascal-redis-faa 0.2.0 and
  pascal-amqp-faa 0.2.0, against Redis 7.2 and RabbitMQ 3 in Docker; the
  reconnection again on 2026-10-15 with pascal-amqp-faa 0.3.0, which it now
  needs (OnReconnectError). Delphi wasn't tried.

    MessagingSample [port [redisPort [amqpPort [reconnect [declare-both]]]]]

  Defaults: 9420, Redis on 127.0.0.1:6379, RabbitMQ on 127.0.0.1:5672.
  "reconnect" turns on AutoReconnect, and each failed reconnect attempt is
  logged. "declare-both" also declares the queue on the consuming channel:
  what 0.2.0 needed to recover after a broker restart (the guide, step 4);
  0.3.0 recovers without it.

  Routes:
    GET  /cache/:key          cache-aside through Redis
    GET  /cache2/:key         the same, computing the value when Redis is down
    POST /orders              {"item":"...","quantity":N}: read into an IOrder (400 when
                              it isn't one), published as application/json; 202
    POST /orders/confirmed    the same, and wait for the broker's confirm; 202, or 503 after 3 s
    POST /orders/raw          sample only, like sample 01's /fail/*: publish the body
                              unchecked, to show what the consumer does with a bad message
    GET  /consumed            how many orders the consumer took, and the last item

  The queue is ORDERS_QUEUE (environment or .env), by default a new name per
  run. The consumer reads each message into an IOrder; one it can't read
  raises, and pascal-amqp-faa (0.4.1 or later) calls OnConsumerError, which
  logs, then rejects it without requeue (to the queue's dead-letter exchange
  if it has one, else dropped). Until 0.3.0 it stayed unacknowledged.

  Metrics over OTLP (0.26.0): the consumer counts what it handled
  (orders.consumed, by result: done or rejected) in PcMetrics, and with
  OTEL_EXPORTER_OTLP_ENDPOINT set a TOtlpMetricsExporter pushes the registry
  to that collector every OTEL_METRIC_EXPORT_INTERVAL ms: the way a worker
  without HTTP reaches Prometheus. Measured on FPC 3.2.2/Windows on
  2026-10-27 against the collector and Prometheus of tools/otelcol.yaml and
  tools/prometheus.yml. *)

{$MODE DELPHI}{$H+}

uses
  {$IFDEF UNIX}cthreads, cwstring,{$ENDIF}
  SysUtils, Classes, SyncObjs,
  Horse,
  PascalCommon.Tracing,
  PascalCommon.SafeLog,
  PascalCommon.Metrics,
  Redis.Types, Redis.Client, Redis.Commands.Strings,
  AMQP.Connection, AMQP.Queue.Methods, AMQP.Basic.Methods,
  PascalJsonMapper.Json, PascalJsonMapper.Mapper,
  PascalApi.Http, PascalApi.Text, PascalApi.Config, PascalApi.Otlp,
  PascalApi.Horse.Middlewares;

type
  /// The message: what POST /orders reads and the consumer reads back.
  IOrder = interface
    ['{3ABC5334-03C4-4455-908F-3C52DB19953C}']
    function GetItem: string;
    function GetQuantity: Integer;
    property Item: string read GetItem;
    property Quantity: Integer read GetQuantity;
  end;

{$M+}
  TOrder = class(TInterfacedObject, IOrder)
  private
    FItem: string;
    FQuantity: Integer;
  public
    function GetItem: string;
    function GetQuantity: Integer;
  published
    property Item: string read FItem write FItem;
    property Quantity: Integer read FQuantity write FQuantity;
  end;
{$M-}

  TApp = class
  public
    procedure Line(const AText: string);
    procedure OnOrder(AChannel: TAMQPChannel; const ADelivery: TAMQPDelivery);
    procedure OnOrderError(AChannel: TAMQPChannel; const ADelivery: TAMQPDelivery;
      AError: Exception; var AAction: TAMQPConsumerErrorAction);
    procedure OnReconnectError(AConnection: TAMQPConnection; AAttempt: Integer;
      const AError: string);
  end;

  TPrintExporter = class(TInterfacedObject, IPcSpanExporter)
  public
    function ExportSpans(const ASpans: TPcSpanDataArray; out AError: string): Boolean;
  end;

const
  KIND_NAMES: array[TPcSpanKind] of string = ('internal', 'server', 'client', 'producer', 'consumer');

var
  GApp: TApp;
  GOut: TCriticalSection;
  GRedis: TRedisClient;
  GAmqp: TAMQPConnection;
  GPublisher, GConsumer, GConfirmed: TAMQPChannel;
  GQueue: string;
  GConsumed: Integer;
  GOrders: TPcCounter;
  GMetrics: TOtlpMetricsExporter;
  GLastItem: string; // under GOut
  GPort: Integer;
  GRedisParams: TRedisParams;
  GAmqpParams: TAMQPConnectionParams;

procedure TApp.Line(const AText: string);
begin
  // SafeWriteln locks and flushes; with PcSetSafeLogUtf8 the line is UTF-8
  // (Writeln wrote "café" with the byte 0x82, code page 850: measured).
  SafeWriteln(AText);
end;

/// The span's trace id, or '' without tracing.
function TraceIdOf(const ASpan: IPcSpan): string;
begin
  if ASpan <> nil then
    Result := ASpan.TraceId
  else
    Result := '';
end;

function TOrder.GetItem: string;
begin
  Result := FItem;
end;

function TOrder.GetQuantity: Integer;
begin
  Result := FQuantity;
end;

procedure TApp.OnOrder(AChannel: TAMQPChannel; const ADelivery: TAMQPDelivery);
var
  LOrder: IOrder;
begin
  // On the library's thread pool. No try: a message that can't be read
  // raises, and OnOrderError logs it (pascal-amqp-faa 0.4.0).
  LOrder := TJsonMapper.Shared.FromJson<IOrder>(ADelivery.BodyAsText);
  InterlockedIncrement(GConsumed);
  GOrders.Labels(['done']).Inc;
  GOut.Enter;
  try
    GLastItem := LOrder.Item;
  finally
    GOut.Leave;
  end;
  Line(Format('consumed %d x %s trace=%s', [LOrder.Quantity, LOrder.Item,
    TraceIdOf(TPcTracing.Current)]));
  AChannel.Ack(ADelivery.DeliveryTag);
end;

procedure TApp.OnOrderError(AChannel: TAMQPChannel; const ADelivery: TAMQPDelivery;
  AError: Exception; var AAction: TAMQPConsumerErrorAction);
begin
  // Same pool thread, after OnOrder raised. AError belongs to the library
  // (never free or re-raise it). AAction comes as ceaReject (Nack without
  // requeue) for a message still pending: kept. ceaRequeue would loop on a
  // message that always fails.
  // Inside the message's 'process' span (pascal-amqp-faa 0.4.1; 0.4.0 had
  // already finished it), so the line carries the trace id.
  GOrders.Labels(['rejected']).Inc;
  TErrorHandlerMiddleware.LogError(Format('order rejected: %s: %s',
    [AError.ClassName, AError.Message]), TraceIdOf(TPcTracing.Current));
end;

procedure TApp.OnReconnectError(AConnection: TAMQPConnection; AAttempt: Integer;
  const AError: string);
begin
  // On the library's thread; no request, so no request id.
  TErrorHandlerMiddleware.LogError(Format('AMQP reconnect attempt %d failed: %s',
    [AAttempt, AError]), '');
end;

function TPrintExporter.ExportSpans(const ASpans: TPcSpanDataArray; out AError: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(ASpans) do
    GApp.Line(Format('SPAN %s kind=%s trace=%s span=%s parent=%s status=%d',
      [ASpans[I].Name, KIND_NAMES[ASpans[I].Kind], ASpans[I].TraceId, ASpans[I].SpanId,
       ASpans[I].ParentSpanId, Ord(ASpans[I].Status)]));
  AError := '';
  Result := True;
end;

procedure GetCache(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LKey, LValue: string;
begin
  // Cache-aside: the shared client takes a pooled connection per command.
  LKey := 'probe:' + AReq.Params['key'];
  if GRedis.Strings.TryGet(LKey, LValue) then
    TJsonSend.Send(ARes, '{"hit":true,"value":"' + LValue + '"}')
  else
  begin
    LValue := UpperCase(AReq.Params['key']); // the "expensive" work
    GRedis.Strings.SetEx(LKey, 60, LValue);
    TJsonSend.Send(ARes, '{"hit":false,"value":"' + LValue + '"}');
  end;
end;

procedure GetCacheOrCompute(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LKey, LValue: string;
begin
  // A cache is optional: when Redis can't answer, compute and log the reason.
  LKey := 'probe:' + AReq.Params['key'];
  try
    if GRedis.Strings.TryGet(LKey, LValue) then
    begin
      TJsonSend.Send(ARes, '{"hit":true,"value":"' + LValue + '"}');
      Exit;
    end;
  except
    on E: ERedisConnectionLost do
      TErrorHandlerMiddleware.LogError(AReq, 'cache unavailable: ' + E.ClassName + ': ' + E.Message);
    on E: ERedisTimeout do
      TErrorHandlerMiddleware.LogError(AReq, 'cache unavailable: ' + E.ClassName + ': ' + E.Message);
  end;
  LValue := UpperCase(AReq.Params['key']);
  TJsonSend.Send(ARes, '{"hit":false,"value":"' + LValue + '"}');
end;

/// The body read into an IOrder and checked, written back by the mapper: a
/// bad order is a 400 here, never a message the consumer can't read.
function OrderJson(AReq: THorseRequest): string;
var
  LOrder: IOrder;
begin
  LOrder := TJsonMapper.Shared.FromJson<IOrder>(AReq.Body);
  if Trim(LOrder.Item) = '' then
    raise EValidationException.Create('"item" is required.');
  if LOrder.Quantity <= 0 then
    raise EValidationException.Create('"quantity" must be positive.');
  Result := TJsonMapper.Shared.ToJson<IOrder>(LOrder);
end;

/// UTF-8 bytes with content type application/json (PublishText says
/// text/plain), persistent.
function PublishJson(AChannel: TAMQPChannel; const AJson: string): UInt64;
var
  LProps: TAMQPBasicProperties;
begin
  LProps := TAMQPBasicProperties.Empty;
  LProps.SetContentType('application/json');
  LProps.SetPersistent;
  Result := AChannel.Publish('', GQueue, PaStringToUtf8Bytes(AJson), LProps);
end;

procedure PostOrder(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  // One channel shared by every request thread.
  PublishJson(GPublisher, OrderJson(AReq));
  TJsonSend.Send(ARes, '{"queued":true}', 202);
end;

procedure PostOrderRaw(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  // Sample only: no check, so a bad message reaches the consumer.
  PublishJson(GPublisher, AReq.Body);
  TJsonSend.Send(ARes, '{"queued":true}', 202);
end;

procedure PostOrderConfirmed(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LSeq: UInt64;
begin
  // Confirm mode: answer 202 only once the broker has taken the message.
  LSeq := PublishJson(GConfirmed, OrderJson(AReq));
  if not GConfirmed.WaitForConfirm(LSeq, 3000) then
  begin
    TErrorHandlerMiddleware.LogError(AReq, 'broker did not confirm publish ' + IntToStr(LSeq));
    raise EHttpException.Create(503, TApiMessages.Current.ServerBusy);
  end;
  TJsonSend.Send(ARes, '{"queued":true}', 202);
end;

procedure GetConsumed(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LWriter: TJsonWriter;
begin
  LWriter := TJsonWriter.Create;
  try
    LWriter.BeginObject;
    LWriter.Name('consumed');
    LWriter.WriteInt64(GConsumed);
    LWriter.Name('lastItem');
    GOut.Enter;
    try
      LWriter.WriteString(GLastItem);
    finally
      GOut.Leave;
    end;
    LWriter.EndObject;
    TJsonSend.Send(ARes, LWriter.ToString);
  finally
    LWriter.Free;
  end;
end;

begin
  SetMultiByteConversionCodePage(CP_UTF8);
  // Log lines in UTF-8, to a file or a pipe too (pascal-common-faa 1.10.0).
  PcSetSafeLogUtf8(True);
  GPort := StrToIntDef(ParamStr(1), 9420);
  GOut := TCriticalSection.Create;
  GApp := TApp.Create;
  TPcTracing.Start(TPcTracingOptions.Default('siblings-probe', '1'), TPrintExporter.Create);
  GOrders := PcMetrics.Counter('orders.consumed', '{order}',
    'Orders the consumer handled, by result', ['result']);
  // Pushed, as a worker without HTTP would (0.26.0). Never freed here:
  // Listen doesn't return; a worker frees it on its stop, for the last export.
  if TAppConfig.Get('OTEL_EXPORTER_OTLP_ENDPOINT', '') <> '' then
    GMetrics := TOtlpMetricsExporter.Create(PcMetrics,
      TOtlpMetricsOptions.FromEnvironment('siblings-probe', '1', ReadAppConfig), GApp.Line);

  GRedisParams := RedisDefaultParams;
  GRedisParams.Port := StrToIntDef(ParamStr(2), 6379);
  GRedis := TRedisClient.Create(GRedisParams);   // a pool inside; no connection yet
  GAmqpParams := TAMQPConnectionParams.Localhost;
  GAmqpParams.Host := '127.0.0.1';
  GAmqpParams.Port := StrToIntDef(ParamStr(3), 5672);
  GAmqpParams.AutoReconnect := ParamStr(4) = 'reconnect';
  GAmqp := TAMQPConnection.Create(GAmqpParams);
  GAmqp.OnReconnectError := GApp.OnReconnectError;
  GAmqp.Open;
  GPublisher := GAmqp.CreateChannel;
  GQueue := TAppConfig.Get('ORDERS_QUEUE', 'probe-orders-' + IntToStr(GetTickCount64));
  GPublisher.DeclareQueue(TAMQPQueueDeclare.Create(GQueue, False));
  GConfirmed := GAmqp.CreateChannel;
  GConfirmed.ConfirmSelect;
  GConsumer := GAmqp.CreateChannel;
  GConsumer.OnConsumerError := GApp.OnOrderError;
  if ParamStr(5) = 'declare-both' then
    GConsumer.DeclareQueue(TAMQPQueueDeclare.Create(GQueue, False));
  GConsumer.Consume(GQueue, GApp.OnOrder);

  TJsonMapper.Shared.RegisterMapping<IOrder, TOrder>;
  TJsonMapper.Shared.UnknownMembers := umError;
  TErrorHandlerMiddleware.Register(GApp.Line);
  THorse.Use(TLoggerMiddleware.New(GApp.Line));
  THorse.Get('/cache/:key', GetCache);
  THorse.Get('/cache2/:key', GetCacheOrCompute);
  THorse.Post('/orders', PostOrder);
  THorse.Post('/orders/confirmed', PostOrderConfirmed);
  THorse.Post('/orders/raw', PostOrderRaw);
  THorse.Get('/consumed', GetConsumed);
  GApp.Line('MessagingSample listening on port ' + IntToStr(GPort) + ', queue ' + GQueue);
  THorse.Listen(GPort);
end.
