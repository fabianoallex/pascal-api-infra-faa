program PipesJsonSample;

(* The Pipes part of docs/guide/dtos-json.md: JSON DTOs between two
  processes through pascal-pipes-faa, with pascal-jsonmapper-faa on both
  ends (one JSON library, the same text on Delphi and FPC). The server and
  the client live in one program here, to keep it in one file; in an
  application they are two processes on the same machine.

    PipesJsonSample      (no arguments; prints what each call returned)

  - Request/reply: the server reads the request into an IOrder and answers
    an IOrderReply. A request it can't read raises in OnRequest, and the
    client's RequestText raises EPipeError with the server's message.
  - Fire and forget: an exception in OnMessage goes to the server's OnError
    (pascal-pipes-faa 0.2.0 or later; with 0.1.1 it reached nobody,
    measured), so OnMessage has no try and OnError logs.

  FPC only here, built by build_fpc.sh with PIPES_FAA (pascal-pipes-faa's
  clone, 0.2.0 or later); measured on FPC 3.2.2/Windows on 2026-10-15.
  Delphi wasn't tried. *)

{$MODE DELPHI}{$H+}

uses
  {$IFDEF UNIX}cthreads, cwstring,{$ENDIF}
  SysUtils, Classes, SyncObjs,
  PascalCommon.Utf8,
  PascalJsonMapper.Json, PascalJsonMapper.Mapper,
  PascalApi.Text,
  Pipes.Types, Pipes.Server, Pipes.Client;

type
  IOrder = interface
    ['{5FE33A96-8FA8-44AF-B011-48232C84B7A0}']
    function GetItem: string;
    function GetQuantity: Integer;
  end;

  IOrderReply = interface
    ['{BEE10F23-A8E8-47D8-B758-9BCCF384C430}']
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

  TOrderReply = class(TInterfacedObject, IOrderReply)
  private
    FAccepted: Boolean;
    FItem: string;
  published
    property Accepted: Boolean read FAccepted write FAccepted;
    property Item: string read FItem write FItem;
  end;
{$M-}

  TServerSide = class
  public
    procedure OnRequest(Sender: TObject; AConnId: TPipeConnectionId;
      const ARequest: TBytes; out AReply: TBytes);
    procedure OnMessage(Sender: TObject; AConnId: TPipeConnectionId; const AData: TBytes);
    procedure OnError(Sender: TObject; AConnId: TPipeConnectionId; const AError: string);
  end;

var
  GHandled: TEvent;

function TOrder.GetItem: string;
begin
  Result := FItem;
end;

function TOrder.GetQuantity: Integer;
begin
  Result := FQuantity;
end;

/// The bytes of a frame as text; they must be UTF-8.
function FrameText(const AData: TBytes): string;
begin
  if not PcTryUtf8BytesToString(AData, Result) then
    raise EJsonParseError.Create('The message is not UTF-8.');
end;

procedure TServerSide.OnRequest(Sender: TObject; AConnId: TPipeConnectionId;
  const ARequest: TBytes; out AReply: TBytes);
var
  LOrder: IOrder;
  LReply: TOrderReply;
  LReplyIntf: IOrderReply;
begin
  // An exception here goes back to the client as an error reply.
  LOrder := TJsonMapper.Shared.FromJson<IOrder>(FrameText(ARequest));
  LReply := TOrderReply.Create;
  LReplyIntf := LReply;
  LReply.Accepted := LOrder.GetQuantity > 0;
  LReply.Item := LOrder.GetItem;
  AReply := PaStringToUtf8Bytes(TJsonMapper.Shared.ToJson<IOrderReply>(LReplyIntf));
end;

procedure TServerSide.OnMessage(Sender: TObject; AConnId: TPipeConnectionId; const AData: TBytes);
var
  LOrder: IOrder;
begin
  // No try: an exception goes to OnError (pascal-pipes-faa 0.2.0).
  try
    LOrder := TJsonMapper.Shared.FromJson<IOrder>(FrameText(AData));
    Writeln('message: ', LOrder.GetQuantity, ' x ', LOrder.GetItem);
  finally
    GHandled.SetEvent; // only for this demo's ordering
  end;
end;

procedure TServerSide.OnError(Sender: TObject; AConnId: TPipeConnectionId; const AError: string);
begin
  // Runs on the same thread, right after the handler that failed; the
  // connection stays open (Server.DisconnectClient(AConnId) would close it).
  Writeln('error on connection ', AConnId, ': ', AError);
end;

procedure Request(AClient: TPipeClient; const ABody: string);
var
  LReply: string;
begin
  try
    LReply := AClient.RequestText(ABody, 3000);
    Writeln('request ', ABody, ' -> ', LReply);
  except
    on E: Exception do
      Writeln('request ', ABody, ' -> ', E.ClassName, ': ', E.Message);
  end;
end;

procedure Send(AClient: TPipeClient; const ABody: string);
begin
  GHandled.ResetEvent;
  AClient.SendText(ABody);
  if GHandled.WaitFor(3000) <> wrSignaled then
    Writeln('message ', ABody, ': not handled in 3 s');
end;

var
  GServer: TPipeServer;
  GClient: TPipeClient;
  GSide: TServerSide;

begin
  SetMultiByteConversionCodePage(CP_UTF8);
  TJsonMapper.Shared.RegisterMapping<IOrder, TOrder>;
  TJsonMapper.Shared.RegisterMapping<IOrderReply, TOrderReply>;
  TJsonMapper.Shared.UnknownMembers := umError;
  GHandled := TEvent.Create(nil, True, False, '');
  GSide := TServerSide.Create;
  GServer := TPipeServer.Create('pascal_api_dtos_json');
  GClient := TPipeClient.Create('pascal_api_dtos_json');
  try
    GServer.OnRequest := GSide.OnRequest;
    GServer.OnMessage := GSide.OnMessage;
    GServer.OnError := GSide.OnError;
    GServer.Listen;
    GClient.Connect(5000);
    Request(GClient, '{"item":"rice","quantity":2}');
    Request(GClient, '{"item":"rice","quantity":"two"}');
    Request(GClient, '{"item":"rice","quantity":2,"qty":3}');
    Send(GClient, '{"item":"beans","quantity":1}');
    Send(GClient, '{"item":"beans","quantity":"x"}');
    Request(GClient, '{"item":"still here","quantity":1}');
  finally
    GClient.Free;
    GServer.Free;
    GSide.Free;
    GHandled.Free;
  end;
end.
