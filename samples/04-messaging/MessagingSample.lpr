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
    POST /orders              publish the body; 202
    POST /orders/confirmed    publish and wait for the broker's confirm; 202, or 503 after 3 s
    GET  /consumed            how many messages the consumer took *)

{$MODE DELPHI}{$H+}

uses
  {$IFDEF UNIX}cthreads, cwstring,{$ENDIF}
  SysUtils, Classes, SyncObjs,
  Horse,
  PascalCommon.Tracing,
  Redis.Types, Redis.Client, Redis.Commands.Strings,
  AMQP.Connection, AMQP.Queue.Methods,
  PascalApi.Http,
  PascalApi.Horse.Middlewares;

type
  TApp = class
  public
    procedure Line(const AText: string);
    procedure OnOrder(AChannel: TAMQPChannel; const ADelivery: TAMQPDelivery);
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
  GPort: Integer;
  GRedisParams: TRedisParams;
  GAmqpParams: TAMQPConnectionParams;

procedure TApp.Line(const AText: string);
begin
  GOut.Enter;
  try
    Writeln(AText);
    Flush(Output);
  finally
    GOut.Leave;
  end;
end;

procedure TApp.OnOrder(AChannel: TAMQPChannel; const ADelivery: TAMQPDelivery);
begin
  // On the library's thread pool; ack after the work.
  InterlockedIncrement(GConsumed);
  if TPcTracing.Current <> nil then
    Line('consumed ' + ADelivery.BodyAsText + ' trace=' + TPcTracing.Current.TraceId)
  else
    Line('consumed ' + ADelivery.BodyAsText);
  AChannel.Ack(ADelivery.DeliveryTag);
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

procedure PostOrder(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  // One channel shared by every request thread.
  GPublisher.PublishText('', GQueue, AReq.Body);
  TJsonSend.Send(ARes, '{"queued":true}', 202);
end;

procedure PostOrderConfirmed(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LSeq: UInt64;
begin
  // Confirm mode: answer 202 only once the broker has taken the message.
  LSeq := GConfirmed.PublishText('', GQueue, AReq.Body);
  if not GConfirmed.WaitForConfirm(LSeq, 3000) then
  begin
    TErrorHandlerMiddleware.LogError(AReq, 'broker did not confirm publish ' + IntToStr(LSeq));
    raise EHttpException.Create(503, TApiMessages.Current.ServerBusy);
  end;
  TJsonSend.Send(ARes, '{"queued":true}', 202);
end;

procedure GetConsumed(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  TJsonSend.Send(ARes, '{"consumed":' + IntToStr(GConsumed) + '}');
end;

begin
  SetMultiByteConversionCodePage(CP_UTF8);
  GPort := StrToIntDef(ParamStr(1), 9420);
  GOut := TCriticalSection.Create;
  GApp := TApp.Create;
  TPcTracing.Start(TPcTracingOptions.Default('siblings-probe', '1'), TPrintExporter.Create);

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
  GQueue := 'probe-orders-' + IntToStr(GetTickCount64);
  GPublisher.DeclareQueue(TAMQPQueueDeclare.Create(GQueue, False));
  GConfirmed := GAmqp.CreateChannel;
  GConfirmed.ConfirmSelect;
  GConsumer := GAmqp.CreateChannel;
  if ParamStr(5) = 'declare-both' then
    GConsumer.DeclareQueue(TAMQPQueueDeclare.Create(GQueue, False));
  GConsumer.Consume(GQueue, GApp.OnOrder);

  TErrorHandlerMiddleware.Register(GApp.Line);
  THorse.Use(TLoggerMiddleware.New(GApp.Line));
  THorse.Get('/cache/:key', GetCache);
  THorse.Get('/cache2/:key', GetCacheOrCompute);
  THorse.Post('/orders', PostOrder);
  THorse.Post('/orders/confirmed', PostOrderConfirmed);
  THorse.Get('/consumed', GetConsumed);
  GApp.Line('MessagingSample listening on port ' + IntToStr(GPort) + ', queue ' + GQueue);
  THorse.Listen(GPort);
end.
