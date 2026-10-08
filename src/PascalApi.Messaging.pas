unit PascalApi.Messaging;

{$I pascalapi.inc}

{ Messaging contracts, independent of protocol and broker, and the registry
  of adapters by name.

  Concrete adapters (AMQP through pascal-amqp-faa, STOMP...) implement
  IMessageConsumer and IMessagePublisher and register an IMessagingFactory
  under a name, in the initialization of their own unit. The application
  resolves the adapter by that name, without referencing it, and implements
  only IMessageHandler: what to do when a message arrives. The adapter owns
  connection, reconnection and the consuming thread.

    LFactory := TMessagingRegistry.GetFactory('rabbitmq');
    LConsumer := LFactory.CreateConsumer(LConfig);
    LConsumer.Subscribe('orders', TOrderHandler.Create(LService));
    LConsumer.Start;

  Same pattern as PascalDb.Registry's TDBRegistry (pascal-db-faa). Register
  at startup, then read from any thread: the registry has no lock.

  Ported from Messaging.Interfaces and Messaging.Adapters.Registry
  (delphi-api-infra-faa), merged into one unit. The interfaces have their
  own GUIDs; the registry's dictionary is created in the unit's
  initialization (there, a class constructor). }

interface

uses
  Generics.Collections;

type
  TMessagingConfig = class
  public
    Host: string;
    Port: Integer;
    User: string;
    Password: string;
    VHost: string;
    /// localhost:5672, guest/guest, vhost "/" (RabbitMQ's defaults).
    constructor Create;
  end;

  IMessagePayload = interface
    ['{61110F4D-FD59-4156-A454-04F589E5D211}']
    function GetBody: string;
    function GetRoutingKey: string;
    function GetHeader(const AKey: string): string;
    property Body: string read GetBody;
    property RoutingKey: string read GetRoutingKey;
  end;

  IMessageHandler = interface
    ['{E98A2326-894F-428D-9113-42B36FB8A9AC}']
    procedure Handle(const APayload: IMessagePayload);
  end;

  IMessageConsumer = interface
    ['{3AE16078-B8C4-47E7-9A6D-F3DFF3B9AFD1}']
    procedure Subscribe(const AQueue: string; const AHandler: IMessageHandler);
    procedure Start;
    procedure Stop;
    function IsRunning: Boolean;
  end;

  IMessagePublisher = interface
    ['{80A90681-EF7C-4F05-BDD2-2FBB7F895636}']
    procedure Publish(const AExchange, ARoutingKey, ABody: string);
  end;

  /// Implemented by the concrete adapter, outside this library.
  IMessagingFactory = interface
    ['{FDEE8F01-3CDC-442D-9D8E-6B377218CD9C}']
    function CreateConsumer(const AConfig: TMessagingConfig): IMessageConsumer;
    function CreatePublisher(const AConfig: TMessagingConfig): IMessagePublisher;
  end;

  TMessagingRegistry = class
  public
    /// Registers (or replaces) the factory under AName.
    class procedure RegisterFactory(const AName: string; const AFactory: IMessagingFactory); static;
    /// The factory registered under AName, or nil.
    class function GetFactory(const AName: string): IMessagingFactory; static;
  end;

implementation

var
  GFactories: TDictionary<string, IMessagingFactory>;

{ TMessagingConfig }

constructor TMessagingConfig.Create;
begin
  inherited Create;
  Host := 'localhost';
  Port := 5672;
  User := 'guest';
  Password := 'guest';
  VHost := '/';
end;

{ TMessagingRegistry }

class procedure TMessagingRegistry.RegisterFactory(const AName: string;
  const AFactory: IMessagingFactory);
begin
  GFactories.AddOrSetValue(AName, AFactory);
end;

class function TMessagingRegistry.GetFactory(const AName: string): IMessagingFactory;
begin
  if not GFactories.TryGetValue(AName, Result) then
    Result := nil;
end;

initialization
  GFactories := TDictionary<string, IMessagingFactory>.Create;

finalization
  GFactories.Free;

end.
