unit ApiSample.Auth;

{ The login's DTOs of sample 01: the tokens a login or a refresh answers
  (a short access token and a refresh token, PascalApi.RefreshTokens) and
  the body of /auth/refresh and /auth/logout. The handlers are in
  ApiSample.dpr; docs/guide/refresh-tokens.md quotes both. }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  PascalApi.Dto;

type
  IRefreshRequest = interface(IInsertDTOBase)
    ['{095243E4-248A-4281-841C-CF2EEB35DA01}']
    function GetRefreshToken: string;
    property RefreshToken: string read GetRefreshToken;
  end;

  ITokens = interface(IResponseDTOBase)
    ['{C7CFA840-32B9-446C-9362-E2A8E46F3FD4}']
    function GetToken: string;
    function GetExpiresIn: Int64;
    function GetRefreshToken: string;
    function GetRefreshExpiresIn: Int64;
    property Token: string read GetToken;
    property ExpiresIn: Int64 read GetExpiresIn;
    property RefreshToken: string read GetRefreshToken;
    property RefreshExpiresIn: Int64 read GetRefreshExpiresIn;
  end;

{$M+}
  TRefreshRequest = class(TInsertDTOBase, IRefreshRequest)
  private
    FRefreshToken: string;
  public
    function GetRefreshToken: string;
  published
    property RefreshToken: string read FRefreshToken write FRefreshToken;
  end;

  TTokens = class(TResponseDTOBase, ITokens)
  private
    FToken: string;
    FExpiresIn: Int64;
    FRefreshToken: string;
    FRefreshExpiresIn: Int64;
  public
    function GetToken: string;
    function GetExpiresIn: Int64;
    function GetRefreshToken: string;
    function GetRefreshExpiresIn: Int64;
  published
    property Token: string read FToken write FToken;
    property ExpiresIn: Int64 read FExpiresIn write FExpiresIn;
    property RefreshToken: string read FRefreshToken write FRefreshToken;
    property RefreshExpiresIn: Int64 read FRefreshExpiresIn write FRefreshExpiresIn;
  end;
{$M-}

implementation

uses
  PascalJsonMapper.Mapper,
  PascalApi.OpenApi;

{ TRefreshRequest }

function TRefreshRequest.GetRefreshToken: string;
begin
  Result := FRefreshToken;
end;

{ TTokens }

function TTokens.GetToken: string;
begin
  Result := FToken;
end;

function TTokens.GetExpiresIn: Int64;
begin
  Result := FExpiresIn;
end;

function TTokens.GetRefreshToken: string;
begin
  Result := FRefreshToken;
end;

function TTokens.GetRefreshExpiresIn: Int64;
begin
  Result := FRefreshExpiresIn;
end;

initialization
  TJsonMapper.Shared.RegisterMapping<IRefreshRequest, TRefreshRequest>;
  TJsonMapper.Shared.RegisterMapping<ITokens, TTokens>;
  TApiSchema.Describe(TypeInfo(IRefreshRequest), 'A refresh token')
    .Prop('RefreshToken').Desc('As the login or the last refresh returned it; used once');
  TApiSchema.Describe(TypeInfo(ITokens), 'An access token and the next refresh token')
    .Prop('Token').Desc('The access token (JWT, HS256), for Authorization: Bearer')
    .Prop('ExpiresIn').Desc('Seconds the access token is valid').Example('900')
    .Prop('RefreshToken').Desc('Exchanged once at /auth/refresh for the next pair')
    .Prop('RefreshExpiresIn').Desc('Seconds the refresh token is valid').Example('2592000');

end.
