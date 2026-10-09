unit PascalApi.Mcp;

{$I pascalapi.inc}

(* An MCP server (protocol revision 2026-07-28 only) over the routes
  documented with TRouteDoc: the tool catalog and the JSON-RPC dispatcher,
  without Horse.

  Each documented operation (except NoMcp ones, and those outside the tag
  filter) becomes a tool: named by its operationId, else derived from method
  and path (McpDeriveName, the origin's rule); its input schema is JSON
  Schema 2020-12 (PascalApi.OpenApi's ApiJsonSchema), flattening path
  parameters, query parameters and the body DTO's properties into one object
  with additionalProperties false. A name used twice raises EMcpError when
  the catalog is built.

  The dispatcher follows the revision's rules for Streamable HTTP, one POST
  at a time and stateless: every request carries
  params._meta["io.modelcontextprotocol/protocolVersion"] and
  ["io.modelcontextprotocol/clientCapabilities"] (missing: 400, -32602); the
  version must be 2026-07-28 (else 400, -32022, listing it); the headers
  MCP-Protocol-Version, Mcp-Method and, for tools/call, Mcp-Name must match
  the body (else 400, -32020); unknown methods are 404, -32601 (initialize
  included, naming the supported version: legacy clients are not served,
  decided with the user).
  Notifications get 202 and no body. Methods: server/discover, tools/list,
  tools/call; the first two carry ttlMs 0 and cacheScope "private".

  A call goes through IMcpToolExecutor (PascalApi.Horse.Mcp's executor makes
  an HTTP request to the API itself, so every middleware applies): path
  arguments into the URL, query arguments into the query string, the others
  into a JSON body. An HTTP status of 400 or more gives a result with
  isError true and the API's body as text, which the model can act on.

  Design and decisions: docs/mcp-design.md. *)

interface

uses
  SysUtils,
  Generics.Collections,
  PascalJsonMapper.Json,
  PascalApi.OpenApi;

const
  MCP_PROTOCOL_VERSION = '2026-07-28';

type
  EMcpError = class(Exception);

  /// What the HTTP layer passes on to the API with every tool call.
  TMcpForward = record
    Authorization: string; // the incoming Authorization header, as is
    ForwardedFor: string;  // the caller's address, sent as X-Forwarded-For
    TraceParent: string;   // the MCP request's span (TLoggerMiddleware), so the call is its child
    TraceState: string;    // passed on with it
  end;

  IMcpToolExecutor = interface
    ['{ED67DA02-F1D8-47AB-9914-6046174D2EA6}']
    /// Performs AMethod on APathAndQuery (e.g. '/cities?state=SP') with
    /// ABody ('' for none) and returns the response body; AStatus is the
    /// HTTP status. Raises on transport failure.
    function Execute(const AMethod, APathAndQuery, ABody: string; const AForward: TMcpForward;
      out AStatus: Integer): string;
  end;

  TMcpArgLocation = (alPath, alQuery, alBody);

  TMcpArg = record
    Name: string;
    Location: TMcpArgLocation;
    Required: Boolean;
  end;

  TMcpTool = class
  public
    Name: string;
    Description: string;
    Method: string;      // get, post, put, patch, delete
    Path: string;        // Horse form: '/cities/:code'
    Args: TArray<TMcpArg>;
    HasBody: Boolean;    // the operation takes a JSON body (Body<I>)
    InputSchema: string; // JSON text
    function FindArg(const AName: string; out AArg: TMcpArg): Boolean;
  end;

  TMcpToolList = TObjectList<TMcpTool>;

  /// The request headers the transport mirrors from the body; an empty
  /// string means the header was absent.
  TMcpHeaders = record
    ProtocolVersion: string;
    Method: string;
    Name: string;
  end;

  TMcpServer = class
  private
    FName: string;
    FVersion: string;
    FTools: TMcpToolList;
    FExecutor: IMcpToolExecutor;
    function FindTool(const AName: string): TMcpTool;
    procedure WriteServerMeta(AWriter: TJsonWriter);
    function CallTool(ATool: TMcpTool; AArgs: TJsonValue; const AForward: TMcpForward;
      out AIsError: Boolean): string;
  public
    /// The tools of ADoc's operations (tags: only operations with at least
    /// one of them; empty: all). The catalog is built here, once; ADoc can
    /// change afterwards without effect.
    constructor Create(ADoc: TApiDocument; const AServerName, AServerVersion: string;
      const ATags: array of string; const AExecutor: IMcpToolExecutor);
    destructor Destroy; override;
    function Tools: TMcpToolList;
    /// One HTTP POST to the MCP endpoint: its body and mirrored headers.
    /// Returns the response body ('' with AStatus 202 for a notification).
    function HandlePost(const ABody: string; const AHeaders: TMcpHeaders;
      const AForward: TMcpForward; out AStatus: Integer): string;
  end;

/// A tool name from method and OpenAPI path, the origin's rule:
/// GET /cities -> list_citie, GET /cities/{id} -> get_citie, POST -> create_,
/// PUT/PATCH -> update_, DELETE -> delete_; the last literal segment, each
/// hyphen-separated word without a final "s", joined with "_".
function McpDeriveName(const AMethod, APath: string): string;

/// True if AFilter is empty or shares a tag with AOpTags.
function McpMatchesTags(const AOpTags, AFilter: array of string): Boolean;

/// Percent-encodes AText's UTF-8 bytes for a URL path segment or query value
/// (RFC 3986 unreserved characters stay as they are).
function McpUrlEncode(const AText: string): string;

implementation

uses
  PascalApi.Text,
  PascalApi.Crypto;

const
  META_VERSION = 'io.modelcontextprotocol/protocolVersion';
  META_CAPABILITIES = 'io.modelcontextprotocol/clientCapabilities';
  META_SERVER_INFO = 'io.modelcontextprotocol/serverInfo';

  ERR_PARSE = -32700;
  ERR_INVALID_REQUEST = -32600;
  ERR_METHOD_NOT_FOUND = -32601;
  ERR_INVALID_PARAMS = -32602;
  ERR_HEADER_MISMATCH = -32020;
  ERR_UNSUPPORTED_VERSION = -32022;

{ Helpers }

function McpDeriveName(const AMethod, APath: string): string;
var
  LRest, LSeg, LWord, LResource, LSingular: string;
  LHasId: Boolean;
  P, Q: Integer;
begin
  LHasId := Pos('{', APath) > 0;
  LResource := '';
  LRest := APath;
  while LRest <> '' do
  begin
    P := Pos('/', LRest);
    if P = 1 then
    begin
      LRest := Copy(LRest, 2, MaxInt);
      Continue;
    end;
    if P = 0 then
    begin
      LSeg := LRest;
      LRest := '';
    end
    else
    begin
      LSeg := Copy(LRest, 1, P - 1);
      LRest := Copy(LRest, P + 1, MaxInt);
    end;
    if (LSeg = '') or (LSeg[1] = '{') then
      Continue;
    // Each hyphen-separated word without a final "s", joined with "_".
    LResource := '';
    while LSeg <> '' do
    begin
      Q := Pos('-', LSeg);
      if Q = 0 then
      begin
        LWord := LSeg;
        LSeg := '';
      end
      else
      begin
        LWord := Copy(LSeg, 1, Q - 1);
        LSeg := Copy(LSeg, Q + 1, MaxInt);
      end;
      LSingular := LWord;
      if (LSingular <> '') and (LSingular[Length(LSingular)] = 's') then
        SetLength(LSingular, Length(LSingular) - 1);
      if LResource = '' then
        LResource := LSingular
      else
        LResource := LResource + '_' + LSingular;
    end;
  end;
  if SameText(AMethod, 'GET') and not LHasId then Result := 'list_' + LResource
  else if SameText(AMethod, 'GET') then Result := 'get_' + LResource
  else if SameText(AMethod, 'POST') then Result := 'create_' + LResource
  else if SameText(AMethod, 'PATCH') or SameText(AMethod, 'PUT') then Result := 'update_' + LResource
  else if SameText(AMethod, 'DELETE') then Result := 'delete_' + LResource
  else Result := LowerCase(AMethod) + '_' + LResource;
end;

function McpMatchesTags(const AOpTags, AFilter: array of string): Boolean;
var
  I, J: Integer;
begin
  if Length(AFilter) = 0 then
    Exit(True);
  for I := 0 to High(AOpTags) do
    for J := 0 to High(AFilter) do
      if SameText(AOpTags[I], AFilter[J]) then
        Exit(True);
  Result := False;
end;

function McpUrlEncode(const AText: string): string;
const
  HEX = '0123456789ABCDEF';
var
  LBytes: TBytes;
  I: Integer;
  B: Byte;
begin
  Result := '';
  LBytes := PaStringToUtf8Bytes(AText);
  for I := 0 to High(LBytes) do
  begin
    B := LBytes[I];
    if AnsiChar(B) in ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~'] then
      Result := Result + Char(B)
    else
      Result := Result + '%' + HEX[(B shr 4) + 1] + HEX[(B and $F) + 1];
  end;
end;

// "=?base64?...?=" (the transport's sentinel for non-ASCII header values)
// decoded; anything else as is. False if the sentinel's content is invalid.
function DecodeHeaderValue(const AValue: string; out AText: string): Boolean;
var
  LInner: string;
  LBytes: TBytes;
  I: Integer;
begin
  AText := AValue;
  Result := True;
  if (Copy(AValue, 1, 9) <> '=?base64?') or (Copy(AValue, Length(AValue) - 1, 2) <> '?=') or
    (Length(AValue) < 11) then
    Exit;
  LInner := Copy(AValue, 10, Length(AValue) - 11);
  // Standard Base64 to the url alphabet PaBase64UrlDecode reads.
  for I := 1 to Length(LInner) do
    if LInner[I] = '+' then
      LInner[I] := '-'
    else if LInner[I] = '/' then
      LInner[I] := '_';
  Result := PaBase64UrlDecode(LInner, LBytes);
  if Result then
    AText := PaUtf8BytesToString(LBytes, 'Mcp-Name header');
end;

// A JSON scalar as text for a URL ('' for null).
function ScalarText(AValue: TJsonValue): string;
begin
  case AValue.Kind of
    jkString: Result := AValue.AsString;
    jkNumber: Result := AValue.NumberText;
    jkBoolean:
      if AValue.AsBoolean then
        Result := 'true'
      else
        Result := 'false';
    jkNull: Result := '';
  else
    Result := AValue.ToJson;
  end;
end;

function ParamTypeJson(AType: TApiParamType): string;
begin
  case AType of
    ptInteger: Result := 'integer';
    ptNumber: Result := 'number';
    ptBoolean: Result := 'boolean';
  else
    Result := 'string';
  end;
end;

{ TMcpTool }

function TMcpTool.FindArg(const AName: string; out AArg: TMcpArg): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(Args) do
    if Args[I].Name = AName then
    begin
      AArg := Args[I];
      Exit(True);
    end;
  Result := False;
end;

{ Catalog }

// "Returns ...: field (type, description), ..." from the success response's
// schema, as the origin described its tools.
function ReturnsHint(ADoc: TApiDocument; AOp: TApiOperation): string;
var
  I, J: Integer;
  LSchema, LProps, LProp, LType, LDesc: TJsonValue;
  LText, LTypeText: string;
begin
  Result := '';
  for I := 0 to High(AOp.Responses) do
    if (AOp.Responses[I].Code in [200, 201]) and
      (AOp.Responses[I].Kind in [rkObject, rkArray, rkPaged]) then
    begin
      LSchema := ParseJson(ApiJsonSchema(ADoc, AOp.Responses[I].Schema));
      try
        LProps := LSchema.Find('properties');
        if (LProps = nil) or (LProps.Count = 0) then
          Exit;
        LText := '';
        for J := 0 to LProps.Count - 1 do
        begin
          LProp := LProps.Items[J];
          LType := LProp.Find('type');
          LTypeText := '';
          if LType <> nil then
            if LType.Kind = jkString then
              LTypeText := LType.AsString
            else if (LType.Kind = jkArray) and (LType.Count > 0) then
              LTypeText := LType.Items[0].AsString + ' or null';
          if LText <> '' then
            LText := LText + ', ';
          LText := LText + LProps.Names[J] + ' (' + LTypeText;
          LDesc := LProp.Find('description');
          if LDesc <> nil then
            LText := LText + ', ' + LDesc.AsString;
          LText := LText + ')';
        end;
        case AOp.Responses[I].Kind of
          rkArray: Result := 'Returns a list of: ' + LText + '.';
          rkPaged: Result := 'Returns a page (page, limit, total, totalPages, hasNext, hasPrev, ' +
            'items) whose items have: ' + LText + '.';
        else
          Result := 'Returns: ' + LText + '.';
        end;
      finally
        LSchema.Free;
      end;
      Exit;
    end;
end;

procedure AddArg(ATool: TMcpTool; const AName: string; ALocation: TMcpArgLocation;
  ARequired: Boolean);
var
  LArg: TMcpArg;
begin
  if ATool.FindArg(AName, LArg) then
    raise EMcpError.CreateFmt('MCP tool %s: the argument "%s" is used twice ' +
      '(a path, query or body name repeated)', [ATool.Name, AName]);
  LArg.Name := AName;
  LArg.Location := ALocation;
  LArg.Required := ARequired;
  SetLength(ATool.Args, Length(ATool.Args) + 1);
  ATool.Args[High(ATool.Args)] := LArg;
end;

function IsRequiredName(AReq: TJsonValue; const AName: string): Boolean;
var
  I: Integer;
begin
  if AReq <> nil then
    for I := 0 to AReq.Count - 1 do
      if AReq.Items[I].AsString = AName then
        Exit(True);
  Result := False;
end;

function BuildTool(ADoc: TApiDocument; AOp: TApiOperation): TMcpTool;
var
  LParams: TArray<TApiParam>;
  LBody, LProps, LReq: TJsonValue;
  LW: TJsonWriter;
  LHint: string;
  LAnyRequired: Boolean;
  I: Integer;
begin
  Result := TMcpTool.Create;
  LBody := nil;
  LW := TJsonWriter.Create;
  try
    Result.Method := LowerCase(AOp.Method);
    Result.Path := AOp.Path;
    Result.HasBody := AOp.Body <> nil;
    if AOp.OperationId <> '' then
      Result.Name := AOp.OperationId
    else
      Result.Name := McpDeriveName(Result.Method, AOp.OpenApiPath);

    Result.Description := AOp.Summary;
    if AOp.Description <> '' then
    begin
      if Result.Description <> '' then
        Result.Description := Result.Description + '. ';
      Result.Description := Result.Description + AOp.Description;
    end;
    if Result.Description = '' then
      Result.Description := UpperCase(AOp.Method) + ' ' + AOp.OpenApiPath;
    LHint := ReturnsHint(ADoc, AOp);
    if LHint <> '' then
      if Result.Description[Length(Result.Description)] = '.' then
        Result.Description := Result.Description + ' ' + LHint
      else
        Result.Description := Result.Description + '. ' + LHint;

    // The arguments: path and query parameters, then the body's properties.
    LParams := ApiOperationParams(ADoc, AOp);
    for I := 0 to High(LParams) do
      if LParams[I].Location = plPath then
        AddArg(Result, LParams[I].Name, alPath, True)
      else
        AddArg(Result, LParams[I].Name, alQuery, LParams[I].Required);
    LProps := nil;
    LReq := nil;
    if AOp.Body <> nil then
    begin
      LBody := ParseJson(ApiJsonSchema(ADoc, AOp.Body));
      LProps := LBody.Find('properties');
      LReq := LBody.Find('required');
      if LProps <> nil then
        for I := 0 to LProps.Count - 1 do
          AddArg(Result, LProps.Names[I], alBody, IsRequiredName(LReq, LProps.Names[I]));
    end;

    LW.BeginObject;
    LW.Name('type');
    LW.WriteString('object');
    LW.Name('properties');
    LW.BeginObject;
    for I := 0 to High(LParams) do
    begin
      LW.Name(LParams[I].Name);
      LW.BeginObject;
      LW.Name('type');
      LW.WriteString(ParamTypeJson(LParams[I].ParamType));
      if LParams[I].Description <> '' then
      begin
        LW.Name('description');
        LW.WriteString(LParams[I].Description);
      end;
      LW.EndObject;
    end;
    if LProps <> nil then
      for I := 0 to LProps.Count - 1 do
      begin
        LW.Name(LProps.Names[I]);
        LW.WriteValue(LProps.Items[I]);
      end;
    LW.EndObject;
    LAnyRequired := False;
    for I := 0 to High(Result.Args) do
      if Result.Args[I].Required then
      begin
        if not LAnyRequired then
        begin
          LW.Name('required');
          LW.BeginArray;
          LAnyRequired := True;
        end;
        LW.WriteString(Result.Args[I].Name);
      end;
    if LAnyRequired then
      LW.EndArray;
    LW.Name('additionalProperties');
    LW.WriteBoolean(False);
    LW.EndObject;
    Result.InputSchema := LW.ToString;
  except
    LW.Free;
    LBody.Free;
    Result.Free;
    raise;
  end;
  LW.Free;
  LBody.Free;
end;

{ TMcpServer }

// ttlMs and cacheScope, required on the cacheable results (server/discover,
// tools/list) by 2026-07-28's schema; the official Python SDK rejects a
// tools/list without them. Not cached, and never in a shared cache: the
// endpoint usually sits behind the API's authentication.
procedure WriteCacheHints(AWriter: TJsonWriter);
begin
  AWriter.Name('ttlMs');
  AWriter.WriteInt64(0);
  AWriter.Name('cacheScope');
  AWriter.WriteString('private');
end;

constructor TMcpServer.Create(ADoc: TApiDocument; const AServerName, AServerVersion: string;
  const ATags: array of string; const AExecutor: IMcpToolExecutor);
var
  I: Integer;
  LOp: TApiOperation;
  LTool: TMcpTool;
  LName: string;
begin
  inherited Create;
  FName := AServerName;
  FVersion := AServerVersion;
  FExecutor := AExecutor;
  FTools := TMcpToolList.Create(True);
  for I := 0 to ADoc.Operations.Count - 1 do
  begin
    LOp := ADoc.Operations[I];
    if LOp.NoMcp or not McpMatchesTags(LOp.Tags, ATags) then
      Continue;
    LTool := BuildTool(ADoc, LOp);
    if FindTool(LTool.Name) <> nil then
    begin
      LName := LTool.Name;
      LTool.Free;
      raise EMcpError.CreateFmt('MCP: two tools named "%s" (%s %s); give one an OperationId',
        [LName, UpperCase(LOp.Method), LOp.OpenApiPath]);
    end;
    FTools.Add(LTool);
  end;
end;

destructor TMcpServer.Destroy;
begin
  FTools.Free;
  inherited;
end;

function TMcpServer.Tools: TMcpToolList;
begin
  Result := FTools;
end;

function TMcpServer.FindTool(const AName: string): TMcpTool;
var
  I: Integer;
begin
  for I := 0 to FTools.Count - 1 do
    if FTools[I].Name = AName then
      Exit(FTools[I]);
  Result := nil;
end;

procedure TMcpServer.WriteServerMeta(AWriter: TJsonWriter);
begin
  AWriter.Name('_meta');
  AWriter.BeginObject;
  AWriter.Name(META_SERVER_INFO);
  AWriter.BeginObject;
  AWriter.Name('name');
  AWriter.WriteString(FName);
  AWriter.Name('version');
  AWriter.WriteString(FVersion);
  AWriter.EndObject;
  AWriter.EndObject;
end;

function TMcpServer.CallTool(ATool: TMcpTool; AArgs: TJsonValue; const AForward: TMcpForward;
  out AIsError: Boolean): string;
var
  LPath, LQuery, LSeg, LValueText: string;
  LBody: TJsonWriter;
  LHasBody: Boolean;
  LArg: TMcpArg;
  I, P, Q: Integer;
  LStatus: Integer;
begin
  AIsError := True;
  // Arguments the schema doesn't have, and required ones missing: errors
  // the model can correct.
  if AArgs <> nil then
    for I := 0 to AArgs.Count - 1 do
      if not ATool.FindArg(AArgs.Names[I], LArg) then
        Exit('Unknown argument: ' + AArgs.Names[I]);
  for I := 0 to High(ATool.Args) do
    if ATool.Args[I].Required and ((AArgs = nil) or (AArgs.Find(ATool.Args[I].Name) = nil) or
      AArgs.Find(ATool.Args[I].Name).IsNull) then
      Exit('Missing required argument: ' + ATool.Args[I].Name);

  // Path: ':name' segments replaced with the encoded value.
  LPath := '';
  LSeg := ATool.Path;
  while LSeg <> '' do
  begin
    P := Pos(':', LSeg);
    if (P = 0) or ((P > 1) and (LSeg[P - 1] <> '/')) then
    begin
      LPath := LPath + LSeg;
      Break;
    end;
    LPath := LPath + Copy(LSeg, 1, P - 1);
    Q := P + 1;
    while (Q <= Length(LSeg)) and (LSeg[Q] <> '/') do
      Inc(Q);
    LValueText := ScalarText(AArgs.Find(Copy(LSeg, P + 1, Q - P - 1)));
    LPath := LPath + McpUrlEncode(LValueText);
    LSeg := Copy(LSeg, Q, MaxInt);
  end;

  LQuery := '';
  LHasBody := False;
  LBody := TJsonWriter.Create;
  try
    LBody.BeginObject;
    if AArgs <> nil then
      for I := 0 to AArgs.Count - 1 do
      begin
        ATool.FindArg(AArgs.Names[I], LArg);
        case LArg.Location of
          alQuery:
            if not AArgs.Items[I].IsNull then
            begin
              if LQuery <> '' then
                LQuery := LQuery + '&';
              LQuery := LQuery + McpUrlEncode(LArg.Name) + '=' + McpUrlEncode(ScalarText(AArgs.Items[I]));
            end;
          alBody:
            begin
              LBody.Name(LArg.Name);
              LBody.WriteValue(AArgs.Items[I]);
              LHasBody := True;
            end;
        end;
      end;
    LBody.EndObject;
    if LQuery <> '' then
      LPath := LPath + '?' + LQuery;
    if ATool.HasBody then
      LHasBody := True; // "{}" for a body route called with no body arguments
    try
      if LHasBody then
        Result := FExecutor.Execute(UpperCase(ATool.Method), LPath, LBody.ToString, AForward, LStatus)
      else
        Result := FExecutor.Execute(UpperCase(ATool.Method), LPath, '', AForward, LStatus);
      AIsError := LStatus >= 400;
    except
      on E: Exception do
        Result := 'Could not call the API: ' + E.Message;
    end;
  finally
    LBody.Free;
  end;
end;

function TMcpServer.HandlePost(const ABody: string; const AHeaders: TMcpHeaders;
  const AForward: TMcpForward; out AStatus: Integer): string;
var
  LRequest, LId, LMethodNode, LParams, LMeta, LVersion, LCaps, LNameNode, LArgs: TJsonValue;
  LMethod, LVersionText, LHeaderName: string;
  LW: TJsonWriter;
  LTool: TMcpTool;
  LText: string;
  LIsError: Boolean;
  I: Integer;

  procedure StartResponse;
  begin
    LW.BeginObject;
    LW.Name('jsonrpc');
    LW.WriteString('2.0');
    LW.Name('id');
    if LId <> nil then
      LW.WriteValue(LId)
    else
      LW.WriteNull; // the request's id couldn't be read
  end;

  function Fail(AHttpStatus, ACode: Integer; const AMessage: string): string;
  begin
    AStatus := AHttpStatus;
    StartResponse;
    LW.Name('error');
    LW.BeginObject;
    LW.Name('code');
    LW.WriteInt64(ACode);
    LW.Name('message');
    LW.WriteString(AMessage);
    if ACode = ERR_UNSUPPORTED_VERSION then
    begin
      LW.Name('data');
      LW.BeginObject;
      LW.Name('supported');
      LW.BeginArray;
      LW.WriteString(MCP_PROTOCOL_VERSION);
      LW.EndArray;
      LW.Name('requested');
      LW.WriteString(LVersionText);
      LW.EndObject;
    end;
    LW.EndObject;
    LW.EndObject;
    Result := LW.ToString;
  end;

begin
  AStatus := 200;
  LRequest := nil;
  LId := nil;
  LVersionText := '';
  LW := TJsonWriter.Create;
  try
    try
      LRequest := ParseJson(ABody);
    except
      on Exception do
        Exit(Fail(400, ERR_PARSE, 'Parse error'));
    end;
    if LRequest.Kind <> jkObject then
      Exit(Fail(400, ERR_INVALID_REQUEST, 'Invalid Request: not a JSON-RPC object'));
    LId := LRequest.Find('id');
    LMethodNode := LRequest.Find('method');
    if (LMethodNode = nil) or (LMethodNode.Kind <> jkString) then
      Exit(Fail(400, ERR_INVALID_REQUEST, 'Invalid Request: "method" missing'));
    LMethod := LMethodNode.AsString;
    if LId = nil then
    begin
      // A notification: accepted, nothing to answer.
      AStatus := 202;
      Exit('');
    end;
    if not (LId.Kind in [jkString, jkNumber]) then
    begin
      LId := nil;
      Exit(Fail(400, ERR_INVALID_REQUEST, 'Invalid Request: "id" must be a string or a number'));
    end;

    LParams := LRequest.Find('params');
    if LMethod = 'initialize' then
    begin
      // A legacy client: unknown method, naming the version this server speaks.
      Exit(Fail(404, ERR_METHOD_NOT_FOUND, 'Method not found: initialize (this server speaks MCP ' +
        MCP_PROTOCOL_VERSION + ' only, without the initialize handshake)'));
    end;
    LMeta := nil;
    if (LParams <> nil) and (LParams.Kind = jkObject) then
      LMeta := LParams.Find('_meta');
    if (LMeta = nil) or (LMeta.Kind <> jkObject) then
      Exit(Fail(400, ERR_INVALID_PARAMS, 'Invalid params: params._meta is required'));
    LVersion := LMeta.Find(META_VERSION);
    LCaps := LMeta.Find(META_CAPABILITIES);
    if (LVersion = nil) or (LVersion.Kind <> jkString) then
      Exit(Fail(400, ERR_INVALID_PARAMS, 'Invalid params: _meta["' + META_VERSION + '"] is required'));
    if (LCaps = nil) or (LCaps.Kind <> jkObject) then
      Exit(Fail(400, ERR_INVALID_PARAMS, 'Invalid params: _meta["' + META_CAPABILITIES + '"] is required'));
    LVersionText := LVersion.AsString;
    if LVersionText <> MCP_PROTOCOL_VERSION then
      Exit(Fail(400, ERR_UNSUPPORTED_VERSION, 'Unsupported protocol version'));

    // The headers must mirror the body.
    if AHeaders.ProtocolVersion <> LVersionText then
      Exit(Fail(400, ERR_HEADER_MISMATCH, 'Header mismatch: MCP-Protocol-Version header "' +
        AHeaders.ProtocolVersion + '" does not match the body''s "' + LVersionText + '"'));
    if AHeaders.Method <> LMethod then
      Exit(Fail(400, ERR_HEADER_MISMATCH, 'Header mismatch: Mcp-Method header "' + AHeaders.Method +
        '" does not match the body''s "' + LMethod + '"'));

    if LMethod = 'server/discover' then
    begin
      StartResponse;
      LW.Name('result');
      LW.BeginObject;
      LW.Name('resultType');
      LW.WriteString('complete');
      WriteCacheHints(LW);
      LW.Name('supportedVersions');
      LW.BeginArray;
      LW.WriteString(MCP_PROTOCOL_VERSION);
      LW.EndArray;
      LW.Name('capabilities');
      LW.BeginObject;
      LW.Name('tools');
      LW.BeginObject;
      LW.EndObject;
      LW.EndObject;
      WriteServerMeta(LW);
      LW.EndObject;
      LW.EndObject;
      Exit(LW.ToString);
    end;

    if LMethod = 'tools/list' then
    begin
      StartResponse;
      LW.Name('result');
      LW.BeginObject;
      LW.Name('resultType');
      LW.WriteString('complete');
      WriteCacheHints(LW);
      LW.Name('tools');
      LW.BeginArray;
      for I := 0 to FTools.Count - 1 do
      begin
        LW.BeginObject;
        LW.Name('name');
        LW.WriteString(FTools[I].Name);
        LW.Name('description');
        LW.WriteString(FTools[I].Description);
        LW.Name('inputSchema');
        LArgs := ParseJson(FTools[I].InputSchema);
        try
          LW.WriteValue(LArgs);
        finally
          LArgs.Free;
        end;
        LW.EndObject;
      end;
      LW.EndArray;
      WriteServerMeta(LW);
      LW.EndObject;
      LW.EndObject;
      Exit(LW.ToString);
    end;

    if LMethod = 'tools/call' then
    begin
      LNameNode := LParams.Find('name');
      if (LNameNode = nil) or (LNameNode.Kind <> jkString) then
        Exit(Fail(400, ERR_INVALID_PARAMS, 'Invalid params: "name" is required'));
      if not DecodeHeaderValue(AHeaders.Name, LHeaderName) or (LHeaderName <> LNameNode.AsString) then
        Exit(Fail(400, ERR_HEADER_MISMATCH, 'Header mismatch: Mcp-Name header "' + AHeaders.Name +
          '" does not match the body''s "' + LNameNode.AsString + '"'));
      LTool := FindTool(LNameNode.AsString);
      if LTool = nil then
        Exit(Fail(400, ERR_INVALID_PARAMS, 'Unknown tool: ' + LNameNode.AsString));
      LArgs := LParams.Find('arguments');
      if (LArgs <> nil) and (LArgs.Kind = jkNull) then
        LArgs := nil;
      if (LArgs <> nil) and (LArgs.Kind <> jkObject) then
        Exit(Fail(400, ERR_INVALID_PARAMS, 'Invalid params: "arguments" must be an object'));
      LText := CallTool(LTool, LArgs, AForward, LIsError);
      StartResponse;
      LW.Name('result');
      LW.BeginObject;
      LW.Name('resultType');
      LW.WriteString('complete');
      LW.Name('content');
      LW.BeginArray;
      LW.BeginObject;
      LW.Name('type');
      LW.WriteString('text');
      LW.Name('text');
      LW.WriteString(LText);
      LW.EndObject;
      LW.EndArray;
      LW.Name('isError');
      LW.WriteBoolean(LIsError);
      WriteServerMeta(LW);
      LW.EndObject;
      LW.EndObject;
      Exit(LW.ToString);
    end;

    Result := Fail(404, ERR_METHOD_NOT_FOUND, 'Method not found: ' + LMethod);
  finally
    LRequest.Free;
    LW.Free;
  end;
end;

end.
