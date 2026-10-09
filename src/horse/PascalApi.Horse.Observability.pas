unit PascalApi.Horse.Observability;

{$I pascalapi.inc}

(* Metrics and health for a Horse API: the HTTP server metrics of the
  OpenTelemetry semantic conventions, served in the Prometheus text format,
  and liveness/readiness endpoints.

    THorse.Use(TLoggerMiddleware.New);
    THorse.Use(TMetricsMiddleware.New);          // right after the logger
    ...routes...
    TMetricsEndpoint.Register('/metrics');
    THealthEndpoint.AddCheck('database', LChecks.Database);
    THealthEndpoint.Register('/health');         // /health/live, /health/ready

  Metrics (pascal-common-faa's PascalCommon.Metrics, PcMetrics unless a
  registry is given), named as OpenTelemetry names them; PcPrometheusText
  converts the names:
  - http.server.request.duration: histogram, seconds, PC_DURATION_BUCKETS,
    labels http.request.method, http.route, http.response.status_code;
    Prometheus http_server_request_duration_seconds.
  - http.server.active_requests: up-down counter, {request}, label
    http.request.method; Prometheus http_server_active_requests.
  http.route is PascalApi.Http.MetricRoute: THorseRequest.MatchedRoute
  (Horse 3.3.12), the template ('/cities/:id'), never the raw path, so a
  client can't create series; '' when no route matched, and also when a
  global middleware answered before the router reached the route (a 401
  from TJwtMiddleware: measured). http.request.method is MetricMethod
  ('_OTHER' for unknown methods), for the same reason.

  The endpoints are ordinary routes: behind TJwtMiddleware/TAuthMiddleware
  unless the application excludes their paths (a scraper and an orchestrator
  usually have no token). Their requests are measured too.

  Readiness checks are registered at startup, before Listen; they run on
  every GET of <path>/ready, in registration order. A check that raises
  counts as failed. The answer has only names and ok/fail (HealthJson); the
  reason goes to AOnFailure when given.

  One configuration per process, as the other middlewares (Horse's FPC
  callbacks are plain procedures, see PascalApi.Horse.Middlewares). *)

interface

uses
  SysUtils,
  Horse,
  Horse.Callback,
  PascalCommon.Metrics,
  PascalApi.Http;

type
  {$IFDEF PASCALAPI_FUNCREFS}
  THealthCheck = reference to function: Boolean;
  {$ELSE}
  THealthCheck = function: Boolean of object;
  {$ENDIF}

  /// Records http.server.request.duration and http.server.active_requests
  /// for every request. Use it right after TLoggerMiddleware, so the time
  /// includes everything after it.
  TMetricsMiddleware = class
  public
    class function New: THorseCallback; overload; static;
    class function New(ARegistry: TPcMetricRegistry): THorseCallback; overload; static;
  end;

  /// GET APath: every metric of the registry (PcMetrics by default) in the
  /// Prometheus text format 0.0.4.
  TMetricsEndpoint = class
  public
    class procedure Register(const APath: string = '/metrics'); overload; static;
    class procedure Register(const APath: string; ARegistry: TPcMetricRegistry); overload; static;
  end;

  /// GET <APath>/live: 200 {"status":"ok"} while the process answers.
  /// GET <APath>/ready: the checks (HealthJson), 200 or 503.
  THealthEndpoint = class
  public
    /// AName: the key in the answer. Call at startup, before Listen.
    class procedure AddCheck(const AName: string; const ACheck: THealthCheck); static;
    class procedure Register(const APath: string = '/health'); overload; static;
    /// AOnFailure gets 'health check <name> failed: <reason>' for each check
    /// that returns False or raises.
    class procedure Register(const APath: string; const AOnFailure: TLogProc); overload; static;
  end;

implementation

uses
  Generics.Collections,
  Horse.Core.Param,
  PascalCommon.Threading,
  PascalApi.Text,
  PascalApi.Horse.Middlewares;

type
  THealthEntry = record
    Name: string;
    Check: THealthCheck;
  end;

const
  // Set on the request by the first pass (see TLoggerMiddleware: Horse runs
  // global middlewares twice when no route matches). A header name can't
  // contain ':', so no client can send it.
  METERED_KEY = ':pascalapi-metered';

var
  GDuration: TPcHistogram;
  GActive: TPcUpDownCounter;
  GMetricsRegistry: TPcMetricRegistry;
  GChecks: TList<THealthEntry>;
  GOnHealthFailure: TLogProc;

// The same as PascalApi.Horse.Middlewares' AsCallback: on FPC a
// THorseCallback is a record, and "Result := AProc" would read as a call.
function AsCallback(AProc: THorseCallbackProc): THorseCallback;
begin
  {$IFDEF FPC}
  Result := @AProc;
  {$ELSE}
  Result := AProc;
  {$ENDIF}
end;

function JoinPath(const APath, ASegment: string): string;
begin
  Result := APath;
  while (Result <> '') and (Result[Length(Result)] = '/') do
    SetLength(Result, Length(Result) - 1);
  Result := Result + '/' + ASegment;
end;

{ Metrics middleware }

procedure MetricsHandler(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LHeaders: THorseList;
  LMethod: string;
  LActive: TPcUpDownCounterSeries;
  LStart: Int64;
begin
  LHeaders := AReq.Headers.Dictionary;
  if LHeaders.ContainsKey(METERED_KEY) then
  begin
    ANext();
    Exit;
  end;
  LHeaders.Add(METERED_KEY, '1');
  LMethod := MetricMethod(AReq.Method);
  LActive := GActive.Labels([LMethod]);
  LActive.Inc;
  LStart := PcTickUs;
  try
    ANext();
  finally
    LActive.Dec;
    // The status is final here: Horse's OnError (TErrorHandlerMiddleware)
    // answers inside the chain, before this finally runs.
    GDuration.Labels([LMethod, MetricRoute(AReq.MatchedRoute, AReq.PathInfo), IntToStr(ARes.Status)])
      .Observe((PcTickUs - LStart) / 1000000);
  end;
end;

class function TMetricsMiddleware.New: THorseCallback;
begin
  Result := New(PcMetrics);
end;

class function TMetricsMiddleware.New(ARegistry: TPcMetricRegistry): THorseCallback;
begin
  GDuration := ARegistry.Histogram('http.server.request.duration', 's',
    'Duration of HTTP server requests.',
    ['http.request.method', 'http.route', 'http.response.status_code'], PC_DURATION_BUCKETS);
  GActive := ARegistry.UpDownCounter('http.server.active_requests', '{request}',
    'Number of active HTTP server requests.', ['http.request.method']);
  Result := AsCallback(MetricsHandler);
end;

{ Metrics endpoint }

procedure MetricsGet(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  ARes.Status(200).ContentType(PC_PROMETHEUS_CONTENT_TYPE)
    .Send(PaStringToUtf8Bytes(PcPrometheusText(GMetricsRegistry)));
end;

class procedure TMetricsEndpoint.Register(const APath: string);
begin
  Register(APath, PcMetrics);
end;

class procedure TMetricsEndpoint.Register(const APath: string; ARegistry: TPcMetricRegistry);
begin
  GMetricsRegistry := ARegistry;
  THorse.Get(APath, MetricsGet);
end;

{ Health endpoints }

procedure HealthLive(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  TJsonSend.Send(ARes, '{"status":"ok"}');
end;

procedure HealthReady(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LResults: array of THealthCheckResult;
  LReason, LBody: string;
  LStatus, I: Integer;
begin
  LResults := nil;
  SetLength(LResults, GChecks.Count);
  for I := 0 to GChecks.Count - 1 do
  begin
    LResults[I].Name := GChecks[I].Name;
    try
      LResults[I].Ok := GChecks[I].Check();
      LReason := 'returned False';
    except
      on E: Exception do
      begin
        LResults[I].Ok := False;
        LReason := E.ClassName + ': ' + E.Message;
      end;
    end;
    if (not LResults[I].Ok) and Assigned(GOnHealthFailure) then
      GOnHealthFailure('health check ' + LResults[I].Name + ' failed: ' + LReason);
  end;
  LBody := HealthJson(LResults, LStatus);
  TJsonSend.Send(ARes, LBody, LStatus);
end;

class procedure THealthEndpoint.AddCheck(const AName: string; const ACheck: THealthCheck);
var
  LEntry: THealthEntry;
begin
  LEntry.Name := AName;
  LEntry.Check := ACheck;
  GChecks.Add(LEntry);
end;

class procedure THealthEndpoint.Register(const APath: string);
begin
  Register(APath, nil);
end;

class procedure THealthEndpoint.Register(const APath: string; const AOnFailure: TLogProc);
begin
  GOnHealthFailure := AOnFailure;
  THorse.Get(JoinPath(APath, 'live'), HealthLive);
  THorse.Get(JoinPath(APath, 'ready'), HealthReady);
end;

initialization
  GChecks := TList<THealthEntry>.Create;

finalization
  GChecks.Free;

end.
