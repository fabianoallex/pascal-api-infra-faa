unit PascalApi.Horse.Mcp;

{$I pascalapi.inc}

(* The MCP endpoint (PascalApi.Mcp, protocol 2026-07-28) on Horse: the
  routes documented with TRouteDoc become tools an AI client can list and
  call.

    TRouteDoc.Get('/cities')...Register(GetCities);   // every route first
    TRouteDoc.Serve('/swagger', 'Cities API', '1.0.0');
    TMcpEndpoint.Register('/mcp', 'http://127.0.0.1:9330', 'cities-api', '1.0.0');
    TMcpEndpoint.Register('/mcp/cities', 'http://127.0.0.1:9330', 'cities', '1.0.0', ['cities']);

  Register builds the catalog from TRouteDoc.Document at that moment, so it
  goes after every route; it registers POST <path> (the JSON-RPC messages)
  and GET/DELETE <path> (405, as the transport says for a server without
  SSE streams or sessions).

  A tool call is an HTTP request to the API itself at ABaseUrl (fphttpclient
  on FPC, THTTPClient on Delphi), so it goes through every middleware as a
  direct call would: the incoming Authorization header and the caller's
  address (as X-Forwarded-For) are passed on. The endpoint is a route like
  any other: behind TJwtMiddleware unless the application excludes it. The
  provider must serve requests concurrently (Horse's are threaded), since
  the call waits for the API while the MCP request is open.

  Origin: a request with an Origin header not in AAllowedOrigins is
  answered 403 (DNS rebinding protection, required by the transport). The
  default, an empty list, refuses every browser origin and accepts clients
  that send none (SDKs, CLI agents). *)

interface

uses
  SysUtils,
  Generics.Collections,
  Horse,
  PascalApi.Mcp;

const
  MCP_HTTP_TIMEOUT_MS = 30000;

type
  /// IMcpToolExecutor over HTTP: ABaseUrl + the tool's path and query.
  TMcpHttpExecutor = class(TInterfacedObject, IMcpToolExecutor)
  private
    FBaseUrl: string;
    FTimeoutMs: Integer;
  public
    constructor Create(const ABaseUrl: string; ATimeoutMs: Integer = MCP_HTTP_TIMEOUT_MS);
    function Execute(const AMethod, APathAndQuery, ABody: string; const AForward: TMcpForward;
      out AStatus: Integer): string;
  end;

  TMcpEndpoint = class
  public
    /// Serves the tools of TRouteDoc.Document's operations on APath, calling
    /// the API at ABaseUrl (e.g. 'http://127.0.0.1:9000'); ATags limits the
    /// tools to operations with one of these tags.
    class procedure Register(const APath, ABaseUrl, AServerName, AServerVersion: string); overload; static;
    class procedure Register(const APath, ABaseUrl, AServerName, AServerVersion: string;
      const ATags: array of string); overload; static;
    class procedure Register(const APath, ABaseUrl, AServerName, AServerVersion: string;
      const ATags, AAllowedOrigins: array of string); overload; static;
    /// The server registered on APath (nil if none), for inspection.
    class function Server(const APath: string): TMcpServer; static;
  end;

implementation

uses
  {$IFDEF FPC}
  Classes,
  fphttpclient,
  {$ELSE}
  Classes,
  System.Net.HttpClient,
  System.Net.URLClient,
  {$ENDIF}
  PascalApi.Text,
  PascalApi.Http,
  PascalApi.OpenApi,
  PascalApi.Horse.Middlewares,
  PascalApi.Horse.OpenApi;

type
  TMcpEntry = class
  public
    Path: string;
    Server: TMcpServer;
    Origins: TArray<string>;
    destructor Destroy; override;
  end;

var
  GEntries: TObjectList<TMcpEntry>;

destructor TMcpEntry.Destroy;
begin
  Server.Free;
  inherited;
end;

function NormalizePath(const APath: string): string;
begin
  Result := APath;
  while (Length(Result) > 1) and (Result[Length(Result)] = '/') do
    SetLength(Result, Length(Result) - 1);
end;

function FindEntry(const APath: string): TMcpEntry;
var
  I: Integer;
  LPath: string;
begin
  LPath := NormalizePath(APath);
  for I := 0 to GEntries.Count - 1 do
    if GEntries[I].Path = LPath then
      Exit(GEntries[I]);
  Result := nil;
end;

{ TMcpHttpExecutor }

constructor TMcpHttpExecutor.Create(const ABaseUrl: string; ATimeoutMs: Integer);
begin
  inherited Create;
  FBaseUrl := NormalizePath(ABaseUrl);
  FTimeoutMs := ATimeoutMs;
end;

{$IFDEF FPC}

function TMcpHttpExecutor.Execute(const AMethod, APathAndQuery, ABody: string;
  const AForward: TMcpForward; out AStatus: Integer): string;
var
  LClient: TFPHTTPClient;
  LSent: TStringStream;
  LReceived: TBytesStream;
begin
  LClient := TFPHTTPClient.Create(nil);
  LSent := nil;
  LReceived := TBytesStream.Create;
  try
    LClient.ConnectTimeout := FTimeoutMs;
    LClient.IOTimeout := FTimeoutMs;
    LClient.AllowRedirect := False;
    LClient.AddHeader('Accept', 'application/json');
    if AForward.Authorization <> '' then
      LClient.AddHeader('Authorization', AForward.Authorization);
    if AForward.ForwardedFor <> '' then
      LClient.AddHeader('X-Forwarded-For', AForward.ForwardedFor);
    if ABody <> '' then
    begin
      // FPC strings are UTF-8 already (the jsonmapper writes them so).
      LSent := TStringStream.Create(ABody);
      LClient.AddHeader('Content-Type', 'application/json; charset=utf-8');
      LClient.RequestBody := LSent;
    end;
    // No accepted-status list: every status is an answer, not an exception.
    LClient.HTTPMethod(AMethod, FBaseUrl + APathAndQuery, LReceived, []);
    AStatus := LClient.ResponseStatusCode;
    Result := PaUtf8BytesToString(Copy(LReceived.Bytes, 0, LReceived.Size), 'MCP tool response');
  finally
    LClient.RequestBody := nil;
    LReceived.Free;
    LSent.Free;
    LClient.Free;
  end;
end;

{$ELSE}

function TMcpHttpExecutor.Execute(const AMethod, APathAndQuery, ABody: string;
  const AForward: TMcpForward; out AStatus: Integer): string;
var
  LClient: THTTPClient;
  LRequest: IHTTPRequest;
  LSent: TBytesStream;
  LResponse: IHTTPResponse;
begin
  LClient := THTTPClient.Create;
  LSent := nil;
  try
    LClient.ConnectionTimeout := FTimeoutMs;
    LClient.ResponseTimeout := FTimeoutMs;
    LClient.HandleRedirects := False;
    LRequest := LClient.GetRequest(AMethod, FBaseUrl + APathAndQuery);
    LRequest.SetHeaderValue('Accept', 'application/json');
    if AForward.Authorization <> '' then
      LRequest.SetHeaderValue('Authorization', AForward.Authorization);
    if AForward.ForwardedFor <> '' then
      LRequest.SetHeaderValue('X-Forwarded-For', AForward.ForwardedFor);
    if ABody <> '' then
    begin
      LSent := TBytesStream.Create(PaStringToUtf8Bytes(ABody));
      LRequest.SetHeaderValue('Content-Type', 'application/json; charset=utf-8');
      LRequest.SourceStream := LSent;
    end;
    LResponse := LClient.Execute(LRequest);
    AStatus := LResponse.StatusCode;
    Result := LResponse.ContentAsString(TEncoding.UTF8);
  finally
    // Released before the stream and the client they point to.
    LResponse := nil;
    LRequest := nil;
    LSent.Free;
    LClient.Free;
  end;
end;

{$ENDIF}

{ Handlers }

function RemoteAddr(AReq: THorseRequest): string;
begin
  // Empty with the console provider; the web request has it (see
  // PascalApi.Horse.Middlewares, RemoteAddrOf).
  Result := AReq.RemoteAddr;
  if (Result = '') and (AReq.RawWebRequest <> nil) then
    Result := AReq.RawWebRequest.RemoteAddr;
end;

function OriginAllowed(AEntry: TMcpEntry; const AOrigin: string): Boolean;
var
  I: Integer;
begin
  if AOrigin = '' then
    Exit(True);
  for I := 0 to High(AEntry.Origins) do
    if SameText(AEntry.Origins[I], AOrigin) then
      Exit(True);
  Result := False;
end;

procedure McpPost(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LEntry: TMcpEntry;
  LHeaders: TMcpHeaders;
  LForward: TMcpForward;
  LStatus: Integer;
  LAnswer: string;
begin
  LEntry := FindEntry(AReq.PathInfo);
  if LEntry = nil then
  begin
    TJsonSend.Send(ARes, ErrorJson('No MCP endpoint here'), 404);
    Exit;
  end;
  if not OriginAllowed(LEntry, AReq.Headers['Origin']) then
  begin
    TJsonSend.Send(ARes, ErrorJson('Origin not allowed'), 403);
    Exit;
  end;
  LHeaders.ProtocolVersion := AReq.Headers['MCP-Protocol-Version'];
  LHeaders.Method := AReq.Headers['Mcp-Method'];
  LHeaders.Name := AReq.Headers['Mcp-Name'];
  LForward.Authorization := AReq.Headers['Authorization'];
  LForward.ForwardedFor := ClientIp(AReq.Headers['X-Forwarded-For'], RemoteAddr(AReq), '');
  LAnswer := LEntry.Server.HandlePost(AReq.Body, LHeaders, LForward, LStatus);
  if LStatus = 202 then
    ARes.Status(202).Send('')
  else
    TJsonSend.Send(ARes, LAnswer, LStatus);
end;

procedure McpNotAllowed(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  ARes.AddHeader('Allow', 'POST');
  TJsonSend.Send(ARes, ErrorJson('Method not allowed: this MCP endpoint takes POST only'), 405);
end;

{ TMcpEndpoint }

class procedure TMcpEndpoint.Register(const APath, ABaseUrl, AServerName, AServerVersion: string);
begin
  Register(APath, ABaseUrl, AServerName, AServerVersion, [], []);
end;

class procedure TMcpEndpoint.Register(const APath, ABaseUrl, AServerName, AServerVersion: string;
  const ATags: array of string);
begin
  Register(APath, ABaseUrl, AServerName, AServerVersion, ATags, []);
end;

class procedure TMcpEndpoint.Register(const APath, ABaseUrl, AServerName, AServerVersion: string;
  const ATags, AAllowedOrigins: array of string);
var
  LEntry: TMcpEntry;
  I: Integer;
begin
  if FindEntry(APath) <> nil then
    raise EMcpError.CreateFmt('MCP: an endpoint is already registered on %s', [APath]);
  LEntry := TMcpEntry.Create;
  try
    LEntry.Path := NormalizePath(APath);
    SetLength(LEntry.Origins, Length(AAllowedOrigins));
    for I := 0 to High(AAllowedOrigins) do
      LEntry.Origins[I] := AAllowedOrigins[I];
    LEntry.Server := TMcpServer.Create(TRouteDoc.Document, AServerName, AServerVersion, ATags,
      TMcpHttpExecutor.Create(ABaseUrl));
  except
    LEntry.Free;
    raise;
  end;
  GEntries.Add(LEntry);
  THorse.Post(LEntry.Path, McpPost);
  THorse.Get(LEntry.Path, McpNotAllowed);
  THorse.Delete(LEntry.Path, McpNotAllowed);
end;

class function TMcpEndpoint.Server(const APath: string): TMcpServer;
var
  LEntry: TMcpEntry;
begin
  LEntry := FindEntry(APath);
  if LEntry = nil then
    Result := nil
  else
    Result := LEntry.Server;
end;

initialization
  GEntries := TObjectList<TMcpEntry>.Create(True);

finalization
  GEntries.Free;

end.
