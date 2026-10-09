unit PascalApi.Horse.OpenApi;

{$I pascalapi.inc}

(* Routes registered in Horse and documented in OpenAPI in one call, and the
  document served with Swagger UI.

    TRouteDoc.Get('/cities')
      .Summary('List cities').Tag('cities')
      .QueryParam('state', 'Two-letter state')
      .ResponsePaged<ICity>(200, 'A page of cities')
      .Register(GetCities);
    ...
    TRouteDoc.Serve('/swagger', 'Cities API', '1.0.0');   // after every route

  Each builder frees itself in Register, which registers the handler in
  Horse and the operation in TRouteDoc.Document; a chain that never reaches
  Register leaks its builder. Handlers are named procedures (FPC 3.2.2 has
  no anonymous methods), the same ones THorse.Get takes.

  Serve writes the document once and registers two routes: <base>/doc.json
  (the OpenAPI 3.0.3 document) and <base> (Swagger UI, loaded by the browser
  from unpkg, swagger-ui-dist pinned to SWAGGER_UI_VERSION: the page needs
  internet, the API doesn't). The document stays in TRouteDoc.Document for
  other readers (the MCP server, phase 5).

  The model and the schemas are PascalApi.OpenApi, tested without a server.
  Design: docs/openapi-design.md. *)

interface

uses
  SysUtils,
  TypInfo,
  Horse,
  Horse.Callback,
  PascalApi.OpenApi;

const
  SWAGGER_UI_VERSION = '5.17.14';

type
  TRouteDocBuilder = class
  private
    FOp: TApiOperation;
    procedure AddParam(const AName, ADescription: string; ALocation: TApiParamLocation;
      AType: TApiParamType; ARequired: Boolean);
    procedure AddResponse(ACode: Integer; const ADescription: string; AKind: TApiResponseKind;
      ASchema: PTypeInfo);
  public
    constructor Create(const AMethod, APath: string);
    destructor Destroy; override;
    function Summary(const AText: string): TRouteDocBuilder;
    function Descr(const AText: string): TRouteDocBuilder;
    function Tag(const ATag: string): TRouteDocBuilder;
    /// The operationId; also the MCP tool name (phase 5).
    function OperationId(const AId: string): TRouteDocBuilder;
    /// Documented, but left out of the MCP tools (phase 5).
    function NoMcp: TRouteDocBuilder;
    /// Path parameters in the path but not declared are documented as strings.
    function PathParam(const AName: string; const ADescription: string = '';
      AType: TApiParamType = ptString): TRouteDocBuilder;
    function QueryParam(const AName: string; const ADescription: string = '';
      AType: TApiParamType = ptString; ARequired: Boolean = False): TRouteDocBuilder;
    /// One query parameter per published property of the DTO I (a paged
    /// search's Find DTO), named as the mapper names it; descriptions from
    /// TApiSchema.Describe(TypeInfo(I)).
    function QueryParams<I: IInterface>: TRouteDocBuilder;
    function Body<I: IInterface>(const ADescription: string = ''): TRouteDocBuilder;
    function Response<I: IInterface>(ACode: Integer; const ADescription: string = ''): TRouteDocBuilder;
    function ResponseArray<I: IInterface>(ACode: Integer; const ADescription: string = ''): TRouteDocBuilder;
    /// PascalApi.Pagination's envelope, with an array of I in "items".
    function ResponsePaged<I: IInterface>(ACode: Integer; const ADescription: string = ''): TRouteDocBuilder;
    function NoContent(ACode: Integer = 204; const ADescription: string = ''): TRouteDocBuilder;
    /// An error response: the {"error": "..."} body of the error handler.
    function Error(ACode: Integer; const ADescription: string = ''): TRouteDocBuilder;
    /// Registers AHandler in Horse and the operation in TRouteDoc.Document,
    /// then frees the builder.
    procedure Register(const AHandler: THorseCallback);
  end;

  TRouteDoc = class
  public
    class function Get(const APath: string): TRouteDocBuilder; static;
    class function Post(const APath: string): TRouteDocBuilder; static;
    class function Put(const APath: string): TRouteDocBuilder; static;
    class function Patch(const APath: string): TRouteDocBuilder; static;
    class function Delete(const APath: string): TRouteDocBuilder; static;
    /// The document every Register adds to (created at unit initialization).
    class function Document: TApiDocument; static;
    /// Writes the document and registers <ABasePath>/doc.json and <ABasePath>.
    class procedure Serve(const ABasePath, ATitle, AVersion: string;
      const ADescription: string = ''); static;
  end;

implementation

uses
  PascalApi.Text,
  PascalApi.Horse.Middlewares;

var
  GDocument: TApiDocument;
  GDocJson: string;
  GUiHtml: string;

{ TRouteDocBuilder }

constructor TRouteDocBuilder.Create(const AMethod, APath: string);
begin
  inherited Create;
  FOp := TApiOperation.Create;
  FOp.Method := AMethod;
  FOp.Path := APath;
end;

destructor TRouteDocBuilder.Destroy;
begin
  FOp.Free; // nil once Register handed it to the document
  inherited;
end;

procedure TRouteDocBuilder.AddParam(const AName, ADescription: string;
  ALocation: TApiParamLocation; AType: TApiParamType; ARequired: Boolean);
var
  LParam: TApiParam;
begin
  LParam.Name := AName;
  LParam.Description := ADescription;
  LParam.Location := ALocation;
  LParam.ParamType := AType;
  LParam.Required := ARequired;
  SetLength(FOp.Params, Length(FOp.Params) + 1);
  FOp.Params[High(FOp.Params)] := LParam;
end;

procedure TRouteDocBuilder.AddResponse(ACode: Integer; const ADescription: string;
  AKind: TApiResponseKind; ASchema: PTypeInfo);
var
  LResponse: TApiResponse;
begin
  LResponse.Code := ACode;
  LResponse.Description := ADescription;
  LResponse.Kind := AKind;
  LResponse.Schema := ASchema;
  SetLength(FOp.Responses, Length(FOp.Responses) + 1);
  FOp.Responses[High(FOp.Responses)] := LResponse;
end;

function TRouteDocBuilder.Summary(const AText: string): TRouteDocBuilder;
begin
  FOp.Summary := AText;
  Result := Self;
end;

function TRouteDocBuilder.Descr(const AText: string): TRouteDocBuilder;
begin
  FOp.Description := AText;
  Result := Self;
end;

function TRouteDocBuilder.Tag(const ATag: string): TRouteDocBuilder;
begin
  SetLength(FOp.Tags, Length(FOp.Tags) + 1);
  FOp.Tags[High(FOp.Tags)] := ATag;
  Result := Self;
end;

function TRouteDocBuilder.OperationId(const AId: string): TRouteDocBuilder;
begin
  FOp.OperationId := AId;
  Result := Self;
end;

function TRouteDocBuilder.NoMcp: TRouteDocBuilder;
begin
  FOp.NoMcp := True;
  Result := Self;
end;

function TRouteDocBuilder.PathParam(const AName, ADescription: string;
  AType: TApiParamType): TRouteDocBuilder;
begin
  AddParam(AName, ADescription, plPath, AType, True);
  Result := Self;
end;

function TRouteDocBuilder.QueryParam(const AName, ADescription: string; AType: TApiParamType;
  ARequired: Boolean): TRouteDocBuilder;
begin
  AddParam(AName, ADescription, plQuery, AType, ARequired);
  Result := Self;
end;

function TRouteDocBuilder.QueryParams<I>: TRouteDocBuilder;
begin
  FOp.QueryDto := TypeInfo(I);
  Result := Self;
end;

function TRouteDocBuilder.Body<I>(const ADescription: string): TRouteDocBuilder;
begin
  FOp.Body := TypeInfo(I);
  FOp.BodyDescription := ADescription;
  Result := Self;
end;

function TRouteDocBuilder.Response<I>(ACode: Integer; const ADescription: string): TRouteDocBuilder;
begin
  AddResponse(ACode, ADescription, rkObject, TypeInfo(I));
  Result := Self;
end;

function TRouteDocBuilder.ResponseArray<I>(ACode: Integer; const ADescription: string): TRouteDocBuilder;
begin
  AddResponse(ACode, ADescription, rkArray, TypeInfo(I));
  Result := Self;
end;

function TRouteDocBuilder.ResponsePaged<I>(ACode: Integer; const ADescription: string): TRouteDocBuilder;
begin
  AddResponse(ACode, ADescription, rkPaged, TypeInfo(I));
  Result := Self;
end;

function TRouteDocBuilder.NoContent(ACode: Integer; const ADescription: string): TRouteDocBuilder;
begin
  AddResponse(ACode, ADescription, rkNone, nil);
  Result := Self;
end;

function TRouteDocBuilder.Error(ACode: Integer; const ADescription: string): TRouteDocBuilder;
begin
  AddResponse(ACode, ADescription, rkError, nil);
  Result := Self;
end;

procedure TRouteDocBuilder.Register(const AHandler: THorseCallback);
var
  LMethod, LPath: string;
begin
  try
    LMethod := FOp.Method;
    LPath := FOp.Path;
    GDocument.Add(FOp);
    FOp := nil;
    if LMethod = 'get' then
      THorse.Get(LPath, AHandler)
    else if LMethod = 'post' then
      THorse.Post(LPath, AHandler)
    else if LMethod = 'put' then
      THorse.Put(LPath, AHandler)
    else if LMethod = 'patch' then
      THorse.Patch(LPath, AHandler)
    else
      THorse.Delete(LPath, AHandler);
  finally
    Free;
  end;
end;

{ TRouteDoc }

class function TRouteDoc.Get(const APath: string): TRouteDocBuilder;
begin
  Result := TRouteDocBuilder.Create('get', APath);
end;

class function TRouteDoc.Post(const APath: string): TRouteDocBuilder;
begin
  Result := TRouteDocBuilder.Create('post', APath);
end;

class function TRouteDoc.Put(const APath: string): TRouteDocBuilder;
begin
  Result := TRouteDocBuilder.Create('put', APath);
end;

class function TRouteDoc.Patch(const APath: string): TRouteDocBuilder;
begin
  Result := TRouteDocBuilder.Create('patch', APath);
end;

class function TRouteDoc.Delete(const APath: string): TRouteDocBuilder;
begin
  Result := TRouteDocBuilder.Create('delete', APath);
end;

class function TRouteDoc.Document: TApiDocument;
begin
  Result := GDocument;
end;

procedure SendDocJson(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  TJsonSend.Send(ARes, GDocJson);
end;

procedure SendUi(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  ARes.Status(200).ContentType('text/html; charset=utf-8').Send(PaStringToUtf8Bytes(GUiHtml));
end;

class procedure TRouteDoc.Serve(const ABasePath, ATitle, AVersion, ADescription: string);
var
  LCdn: string;
begin
  GDocument.Title := ATitle;
  GDocument.Version := AVersion;
  GDocument.Description := ADescription;
  GDocJson := GDocument.ToJson;
  LCdn := 'https://unpkg.com/swagger-ui-dist@' + SWAGGER_UI_VERSION;
  GUiHtml :=
    '<!DOCTYPE html><html><head><meta charset="utf-8"/><title>' + ATitle + '</title>' +
    '<link rel="stylesheet" href="' + LCdn + '/swagger-ui.css"></head>' +
    '<body><div id="swagger-ui"></div>' +
    '<script src="' + LCdn + '/swagger-ui-bundle.js"></script>' +
    '<script>window.onload=function(){SwaggerUIBundle({url:"' + ABasePath + '/doc.json",' +
    'dom_id:"#swagger-ui"})}</script></body></html>';
  THorse.Get(ABasePath + '/doc.json', SendDocJson);
  THorse.Get(ABasePath, SendUi);
end;

initialization
  GDocument := TApiDocument.Create;

finalization
  GDocument.Free;

end.
