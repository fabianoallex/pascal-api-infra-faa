unit PascalApi.Dto;

{$I pascalapi.inc}

(* Base interfaces and classes for DTOs (request and response bodies).

  The marker interfaces add no methods: they state what a DTO is for
  (response, insert, update, delete, paged search), for typing and for tests
  that check every DTO of a kind.

  JSON goes through pascal-jsonmapper-faa, which maps only PUBLISHED
  properties, on both compilers (FPC 3.2.2's RTTI doesn't see public ones).
  That is the convention for every DTO built on these classes:

    IOrderResponse = interface(IResponseDTOBase)
      ['{...}']
      function GetStatus: string;
      function GetNote: INullString;
    end;

    {$M+}
    TOrderResponse = class(TResponseDTOBase, IOrderResponse)
    private
      FStatus: string;
      FNote: INullString;
    public
      function GetStatus: string;
      function GetNote: INullString;   // returns TOptionals.Safe(FNote)
    published
      property Status: string read FStatus write FStatus;
      property Note: INullString read FNote write FNote;
    end;
    {$M-}

    initialization
      TJsonMapper.Shared.RegisterMapping<IOrderResponse, TOrderResponse>;

  The optional types (IOptXxx/INullXxx/IOptNullXxx) are pascal-common-faa's;
  the program uses PascalCommon.JsonMapper.Optionals once to register their
  converter. Getters of optional fields return TOptionals.Safe(FField), so
  callers test HasValue/IsNull and never Assigned on a field.

  Ported from Common.DTO.Base (delphi-api-infra-faa). Differences: the
  properties are published (there they were public, read by Delphi's
  extended RTTI), the interfaces have their own GUIDs, and
  TResponsePaginationDTOBase.Total is Int64, like PascalDb.Paging's
  TPageMeta.Total. *)

interface

uses
  PascalCommon.Optionals,
  PascalCommon.Version;

// pascal-common-faa is not inside this library: the application provides
// the single copy (its own submodule and search path). This stops the build
// with a clear message if that copy is too old.
// 1.3.0: PascalCommon.SafeLog (PascalApi.FileLog); 1.4.0: PascalCommon.Utf8 (PascalApi.Text);
// 1.5.0: PascalCommon.TraceContext (PascalApi.Http).
{$IF PASCALCOMMON_VERSION < 10500}
  {$MESSAGE FATAL 'pascal-api-infra-faa needs pascal-common-faa 1.5.0 or later'}
{$IFEND}

type
  IDTOBase = interface
    ['{14932FC1-7718-447B-A867-C3C60243F9C2}']
  end;

  IResponseDTOBase = interface(IDTOBase)
    ['{89FBD864-D036-4C3E-BBAA-78623582A24C}']
  end;

  IInsertDTOBase = interface(IDTOBase)
    ['{B0239877-8136-45A2-85C8-588418EDE994}']
  end;

  IUpdateDTOBase = interface(IDTOBase)
    ['{5B5A6F94-378B-458B-B09B-15785283872D}']
  end;

  IDeleteDTOBase = interface(IDTOBase)
    ['{2CFA8414-DE3F-4BC4-B3C8-58FF9DAAC626}']
  end;

  /// A paged search: every member is optional, the client sends only what
  /// it needs. Page and Limit choose the page (see PascalApi.Pagination's
  /// PageRequestFrom); OrderBy follows PascalApi.OrderBy's syntax; Search is
  /// free text.
  IFindPaginationDTOBase = interface(IDTOBase)
    ['{4F147C24-8AF5-4067-92B5-230D131FA5DA}']
    function GetPage: IOptInteger;
    function GetLimit: IOptInteger;
    function GetOrderBy: IOptString;
    function GetSearch: IOptString;
    procedure SetPage(const AValue: IOptInteger);
    procedure SetLimit(const AValue: IOptInteger);
    procedure SetOrderBy(const AValue: IOptString);
    procedure SetSearch(const AValue: IOptString);
    property Page: IOptInteger read GetPage write SetPage;
    property Limit: IOptInteger read GetLimit write SetLimit;
    property OrderBy: IOptString read GetOrderBy write SetOrderBy;
    property Search: IOptString read GetSearch write SetSearch;
  end;

  /// Paging metadata of a response; the items are a member of the concrete
  /// DTO.
  IResponsePaginationDTOBase = interface(IResponseDTOBase)
    ['{903696C1-BD67-4ECB-8AB7-28B67A4061FB}']
    function GetPage: Integer;
    function GetLimit: Integer;
    function GetTotal: Int64;
    procedure SetPage(AValue: Integer);
    procedure SetLimit(AValue: Integer);
    procedure SetTotal(AValue: Int64);
    property Page: Integer read GetPage write SetPage;
    property Limit: Integer read GetLimit write SetLimit;
    property Total: Int64 read GetTotal write SetTotal;
  end;

{$M+}
  TDTOBase = class(TInterfacedObject, IDTOBase)
  end;

  TResponseDTOBase = class(TDTOBase, IResponseDTOBase)
  end;

  TInsertDTOBase = class(TDTOBase, IInsertDTOBase)
  end;

  TUpdateDTOBase = class(TDTOBase, IUpdateDTOBase)
  end;

  TDeleteDTOBase = class(TDTOBase, IDeleteDTOBase)
  end;

  TFindPaginationDTOBase = class(TDTOBase, IFindPaginationDTOBase)
  private
    FPage: IOptInteger;
    FLimit: IOptInteger;
    FOrderBy: IOptString;
    FSearch: IOptString;
  public
    function GetPage: IOptInteger;
    function GetLimit: IOptInteger;
    function GetOrderBy: IOptString;
    function GetSearch: IOptString;
    procedure SetPage(const AValue: IOptInteger);
    procedure SetLimit(const AValue: IOptInteger);
    procedure SetOrderBy(const AValue: IOptString);
    procedure SetSearch(const AValue: IOptString);
  published
    // Published here, on the class: the mapper reads the class, never the
    // interface, and descendants inherit them.
    property Page: IOptInteger read FPage write FPage;
    property Limit: IOptInteger read FLimit write FLimit;
    property OrderBy: IOptString read FOrderBy write FOrderBy;
    property Search: IOptString read FSearch write FSearch;
  end;

  TResponsePaginationDTOBase = class(TResponseDTOBase, IResponsePaginationDTOBase)
  private
    FPage: Integer;
    FLimit: Integer;
    FTotal: Int64;
  public
    function GetPage: Integer;
    function GetLimit: Integer;
    function GetTotal: Int64;
    procedure SetPage(AValue: Integer);
    procedure SetLimit(AValue: Integer);
    procedure SetTotal(AValue: Int64);
  published
    property Page: Integer read FPage write FPage;
    property Limit: Integer read FLimit write FLimit;
    property Total: Int64 read FTotal write FTotal;
  end;
{$M-}

implementation

{ TFindPaginationDTOBase }

function TFindPaginationDTOBase.GetPage: IOptInteger;
begin
  Result := TOptionals.Safe(FPage);
end;

function TFindPaginationDTOBase.GetLimit: IOptInteger;
begin
  Result := TOptionals.Safe(FLimit);
end;

function TFindPaginationDTOBase.GetOrderBy: IOptString;
begin
  Result := TOptionals.Safe(FOrderBy);
end;

function TFindPaginationDTOBase.GetSearch: IOptString;
begin
  Result := TOptionals.Safe(FSearch);
end;

procedure TFindPaginationDTOBase.SetPage(const AValue: IOptInteger);
begin
  FPage := AValue;
end;

procedure TFindPaginationDTOBase.SetLimit(const AValue: IOptInteger);
begin
  FLimit := AValue;
end;

procedure TFindPaginationDTOBase.SetOrderBy(const AValue: IOptString);
begin
  FOrderBy := AValue;
end;

procedure TFindPaginationDTOBase.SetSearch(const AValue: IOptString);
begin
  FSearch := AValue;
end;

{ TResponsePaginationDTOBase }

function TResponsePaginationDTOBase.GetPage: Integer;
begin
  Result := FPage;
end;

function TResponsePaginationDTOBase.GetLimit: Integer;
begin
  Result := FLimit;
end;

function TResponsePaginationDTOBase.GetTotal: Int64;
begin
  Result := FTotal;
end;

procedure TResponsePaginationDTOBase.SetPage(AValue: Integer);
begin
  FPage := AValue;
end;

procedure TResponsePaginationDTOBase.SetLimit(AValue: Integer);
begin
  FLimit := AValue;
end;

procedure TResponsePaginationDTOBase.SetTotal(AValue: Int64);
begin
  FTotal := AValue;
end;

end.
