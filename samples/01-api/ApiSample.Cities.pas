unit ApiSample.Cities;

{ The cities of sample 01, in memory: the request DTO, validation, ordering
  through TOrderBySpec's allow-list and paging, without a database.

  A real repository would put TOrderBySpec.Build into the SQL's ORDER BY and
  PdbPagingClause after it (pascal-db-faa); here the same validated
  expression only chooses how the list is sorted. Handlers run on several
  threads at once, so the list is under a lock. }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  PascalCommon.Optionals,
  PascalDb.Paging,
  PascalApi.Dto;

type
  ICityInsert = interface(IInsertDTOBase)
    ['{FD6E7D51-6C63-4083-A65E-50DDB992FE61}']
    function GetName: string;
    function GetState: string;
    function GetPopulation: IOptInteger;
  end;

{$M+}
  TCityInsert = class(TInsertDTOBase, ICityInsert)
  private
    FName: string;
    FState: string;
    FPopulation: IOptInteger;
  public
    function GetName: string;
    function GetState: string;
    function GetPopulation: IOptInteger;
  published
    property Name: string read FName write FName;
    property State: string read FState write FState;
    property Population: IOptInteger read FPopulation write FPopulation;
  end;
{$M-}

/// The page of cities as a JSON array, ordered by AOrderBy (client syntax);
/// ATotal is the number of cities. Raises EOrderByException for a field
/// not allowed.
function CityPageJson(const AOrderBy: string; const APage: TPageRequest; out ATotal: Int64): string;

/// The city as JSON; ENotFoundException if there is none with AId.
function CityJson(AId: Integer): string;

/// Validates, stores and returns the new city as JSON.
function AddCity(const ACity: ICityInsert): string;

/// {"<AName>":"<AValue>"}.
function JsonMember(const AName, AValue: string): string;

implementation

uses
  SysUtils,
  SyncObjs,
  PascalJsonMapper.Json,
  PascalJsonMapper.Mapper,
  PascalApi.OrderBy,
  PascalApi.Http;

type
  TCity = record
    Id: Integer;
    Name: string;
    State: string;
    Population: Integer; // 0 = unknown
  end;
  // A named type: on Delphi two "array of TCity" declarations are distinct,
  // incompatible types (E2008 assigning Copy(GCities) to a local); FPC
  // accepts it.
  TCityArray = array of TCity;

var
  GLock: TCriticalSection;
  GCities: TCityArray;

{ TCityInsert }

function TCityInsert.GetName: string;
begin
  Result := FName;
end;

function TCityInsert.GetState: string;
begin
  Result := FState;
end;

function TCityInsert.GetPopulation: IOptInteger;
begin
  Result := TOptionals.Safe(FPopulation);
end;

function OrderSpec: TOrderBySpec;
begin
  Result := TOrderBySpec.New
    .Allow('name', 'NAME')
    .Allow('state', 'STATE')
    .Default('name')
    .AlwaysLast('ID');
end;

function WriteCity(AWriter: TJsonWriter; const ACity: TCity): TJsonWriter;
begin
  AWriter.BeginObject;
  AWriter.Name('id');
  AWriter.WriteInt64(ACity.Id);
  AWriter.Name('name');
  AWriter.WriteString(ACity.Name);
  AWriter.Name('state');
  AWriter.WriteString(ACity.State);
  AWriter.Name('population');
  if ACity.Population > 0 then
    AWriter.WriteInt64(ACity.Population)
  else
    AWriter.WriteNull;
  AWriter.EndObject;
  Result := AWriter;
end;

function CityText(const ACity: TCity): string;
var
  LWriter: TJsonWriter;
begin
  LWriter := TJsonWriter.Create;
  try
    Result := WriteCity(LWriter, ACity).ToString;
  finally
    LWriter.Free;
  end;
end;

// True if A comes before B for the ORDER BY fragment AOrder.
function Before(const A, B: TCity; const AOrder: string): Boolean;
var
  C: Integer;
begin
  if Pos('STATE', AOrder) = 1 then
  begin
    C := CompareText(A.State, B.State);
    if Pos('STATE DESC', AOrder) = 1 then
      C := -C;
    if C = 0 then
      C := CompareText(A.Name, B.Name);
  end
  else
  begin
    C := CompareText(A.Name, B.Name);
    if Pos('NAME DESC', AOrder) = 1 then
      C := -C;
  end;
  if C = 0 then
    C := A.Id - B.Id; // the tiebreaker
  Result := C < 0;
end;

function CityPageJson(const AOrderBy: string; const APage: TPageRequest; out ATotal: Int64): string;
var
  LOrder: string;
  LSorted: TCityArray;
  LTemp: TCity;
  LWriter: TJsonWriter;
  I, J: Integer;
begin
  LOrder := OrderSpec.Build(AOrderBy); // raises EOrderByException -> 400
  GLock.Enter;
  try
    LSorted := Copy(GCities, 0, Length(GCities));
  finally
    GLock.Leave;
  end;
  for I := 1 to High(LSorted) do
  begin
    LTemp := LSorted[I];
    J := I - 1;
    while (J >= 0) and Before(LTemp, LSorted[J], LOrder) do
    begin
      LSorted[J + 1] := LSorted[J];
      Dec(J);
    end;
    LSorted[J + 1] := LTemp;
  end;

  ATotal := Length(LSorted);
  LWriter := TJsonWriter.Create;
  try
    LWriter.BeginArray;
    I := Integer(APage.Offset);
    while (I < Length(LSorted)) and (I < APage.Offset + APage.Limit) do
    begin
      WriteCity(LWriter, LSorted[I]);
      Inc(I);
    end;
    LWriter.EndArray;
    Result := LWriter.ToString;
  finally
    LWriter.Free;
  end;
end;

function CityJson(AId: Integer): string;
var
  I: Integer;
begin
  GLock.Enter;
  try
    for I := 0 to High(GCities) do
      if GCities[I].Id = AId then
        Exit(CityText(GCities[I]));
  finally
    GLock.Leave;
  end;
  raise ENotFoundException.Create(Format('City %d not found.', [AId]));
end;

function AddCity(const ACity: ICityInsert): string;
var
  LCity: TCity;
begin
  if Trim(ACity.GetName) = '' then
    raise EValidationException.Create('"name" is required.');
  if Length(ACity.GetState) <> 2 then
    raise EValidationException.Create('"state" must have 2 letters.');
  LCity.Name := Trim(ACity.GetName);
  LCity.State := UpperCase(ACity.GetState);
  if ACity.GetPopulation.HasValue then
    LCity.Population := ACity.GetPopulation.Value
  else
    LCity.Population := 0;
  GLock.Enter;
  try
    LCity.Id := Length(GCities) + 1;
    SetLength(GCities, Length(GCities) + 1);
    GCities[High(GCities)] := LCity;
  finally
    GLock.Leave;
  end;
  Result := CityText(LCity);
end;

function JsonMember(const AName, AValue: string): string;
var
  LWriter: TJsonWriter;
begin
  LWriter := TJsonWriter.Create;
  try
    LWriter.BeginObject;
    LWriter.Name(AName);
    LWriter.WriteString(AValue);
    LWriter.EndObject;
    Result := LWriter.ToString;
  finally
    LWriter.Free;
  end;
end;

procedure Seed(AId: Integer; const AName, AState: string; APopulation: Integer);
begin
  SetLength(GCities, Length(GCities) + 1);
  GCities[High(GCities)].Id := AId;
  GCities[High(GCities)].Name := AName;
  GCities[High(GCities)].State := AState;
  GCities[High(GCities)].Population := APopulation;
end;

initialization
  GLock := TCriticalSection.Create;
  Seed(1, 'São Paulo', 'SP', 11451999);
  Seed(2, 'Porto Alegre', 'RS', 1332845);
  Seed(3, 'Curitiba', 'PR', 1773718);
  Seed(4, 'Belém', 'PA', 1303403);
  Seed(5, 'Campinas', 'SP', 1139047);
  TJsonMapper.Shared.RegisterMapping<ICityInsert, TCityInsert>;

finalization
  GLock.Free;

end.
