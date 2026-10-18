unit PascalApi.Horse.Tenancy;

{$I pascalapi.inc}

{ The tenant of a request, for Horse (docs/multitenancy-design.md): after
  TJwtMiddleware, TTenantMiddleware reads the token's tenant claim, checks it
  against the catalog, and either answers (401 no tenant or a removed one,
  403 suspended: PascalApi.Tenancy.TenantRejection) or marks the request and
  passes it on. A handler asks TTenantMiddleware.Current(AReq) and builds its
  repository from ITenantDataResolver.ScopeFor.

  The claim is the only source: a header or a body field naming another
  tenant is ignored. Paths TJwtMiddleware excludes need no tenant either
  (health, metrics, the application's login route), so TJwtMiddleware must
  be configured first.

  The mark is TPascalApiRequestState.TenantId, in the request's scope
  (THorseRequest.Services), which no client can write. Until 0.16.0 it was
  a request header named ':pascalapi-tenant' plus a line feed. The
  middleware clears it before deciding and sets it only on the requests it
  lets through. TenantIdOf reads it for the access log and the server span
  (TLoggerMiddleware.AddField).

  Horse's FPC callbacks are plain procedures, so the settings live in this
  unit: one tenant configuration per process (as the other middlewares). }

interface

uses
  SysUtils,
  Horse,
  Horse.Callback,
  PascalApi.Tenancy;

type
  ETenantContextError = class(Exception);

  TTenantMiddleware = class
  public
    /// The tenant from the claim tenant_id.
    class function New(const ACatalog: ITenantCatalog): THorseCallback; overload; static;
    class function New(const ACatalog: ITenantCatalog;
      const AClaimName: string): THorseCallback; overload; static;
    /// The tenant the middleware let through. ETenantContextError (a 500)
    /// when there is none: the route is excluded from the token, or the
    /// middleware isn't registered.
    class function Current(AReq: THorseRequest): TTenantInfo; static;
    /// Current without raising.
    class function TryCurrent(AReq: THorseRequest; out AInfo: TTenantInfo): Boolean; static;
    /// New was called.
    class function Configured: Boolean; static;
  end;

/// The id of the tenant the middleware let through, '' otherwise: for
/// TLoggerMiddleware.AddField('tenant.id', TenantIdOf), which puts it in
/// the access log and on the server span.
function TenantIdOf(AReq: THorseRequest): string;

implementation

uses
  PascalJsonMapper.Json,
  PascalApi.Http,
  PascalApi.Horse.Middlewares;

var
  GCatalog: ITenantCatalog;
  GClaim: string;

function AsCallback(AProc: THorseCallbackProc): THorseCallback;
begin
  // FPC: THorseCallback is a record; "Result := AProc" would read as a call.
  {$IFDEF FPC}
  Result := @AProc;
  {$ELSE}
  Result := AProc;
  {$ENDIF}
end;

procedure TenantHandler(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LClaims: TJsonValue;
  LId, LBody: string;
  LInfo: TTenantInfo;
  LCheck: TTenantCheck;
  LStatus: Integer;
  LState: TPascalApiRequestState;
begin
  // Cleared first, so TenantIdOf (the access log) shows no tenant on an
  // excluded path or a refused request.
  LState := TPascalApiRequestState.Get(AReq);
  LState.TenantId := '';
  if TJwtMiddleware.Excludes(AReq.PathInfo) then
  begin
    ANext();
    Exit;
  end;
  LClaims := TJwtMiddleware.Claims(AReq);
  try
    LId := TenantIdFromClaims(LClaims, GClaim);
  finally
    LClaims.Free;
  end;
  LCheck := CheckTenant(GCatalog, LId, LInfo);
  if LCheck <> tcOk then
  begin
    LBody := TenantRejection(LCheck, LStatus);
    // A valid token naming no usable tenant: the client should log in again.
    if LStatus = 401 then
      ARes.AddHeader('WWW-Authenticate', BearerChallenge(True));
    TJsonSend.Send(ARes, LBody, LStatus);
    Exit;
  end;
  LState.TenantId := LInfo.Id;
  ANext();
end;

class function TTenantMiddleware.New(const ACatalog: ITenantCatalog): THorseCallback;
begin
  Result := New(ACatalog, TENANT_DEFAULT_CLAIM);
end;

class function TTenantMiddleware.New(const ACatalog: ITenantCatalog;
  const AClaimName: string): THorseCallback;
begin
  if ACatalog = nil then
    raise EArgumentException.Create('TTenantMiddleware.New: no catalog');
  if AClaimName = '' then
    raise EArgumentException.Create('TTenantMiddleware.New: the claim name is empty');
  GCatalog := ACatalog;
  GClaim := AClaimName;
  Result := AsCallback(TenantHandler);
end;

class function TTenantMiddleware.TryCurrent(AReq: THorseRequest; out AInfo: TTenantInfo): Boolean;
begin
  Result := (GCatalog <> nil) and (TenantIdOf(AReq) <> '') and
    GCatalog.Find(TenantIdOf(AReq), AInfo);
  if not Result then
    AInfo := Default(TTenantInfo);
end;

class function TTenantMiddleware.Current(AReq: THorseRequest): TTenantInfo;
begin
  if not TryCurrent(AReq, Result) then
    raise ETenantContextError.Create(
      'No tenant on this request: is the route excluded from the token, or TTenantMiddleware not registered?');
end;

function TenantIdOf(AReq: THorseRequest): string;
var
  LState: TPascalApiRequestState;
begin
  LState := TPascalApiRequestState.Find(AReq);
  if LState <> nil then
    Result := LState.TenantId
  else
    Result := '';
end;

class function TTenantMiddleware.Configured: Boolean;
begin
  Result := GCatalog <> nil;
end;

// Delphi refuses a finalization without an initialization before it (FPC
// accepts it): this empty section is on purpose.
initialization

finalization
  GCatalog := nil;

end.
