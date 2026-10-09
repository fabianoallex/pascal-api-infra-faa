unit PascalApi.OpenApi;

{$I pascalapi.inc}

(* An OpenAPI 3.0.3 document built from route descriptions and DTO types,
  without Horse: the model, the schema inference and the JSON.

  Schemas come from the published properties of the class registered for a
  DTO interface in pascal-jsonmapper-faa, through TJsonMapper.Members: the
  same members, names and order the mapper writes, so the document can't
  name a member the wire doesn't have. Types are recognized by PTypeInfo
  identity and kind, never by name (names differ between Delphi and FPC:
  Integer shows as LongInt there). pascal-common-faa's optional types map to
  their base type: IOptXxx is not required, INullXxx is nullable,
  IOptNullXxx both.

  Metadata the type can't tell (description, example, limits, enum,
  pattern) is registered in code, next to the DTO's RegisterMapping, because
  FPC 3.2.2 has no custom attributes:

    TApiSchema.Describe(TypeInfo(ICityInsert), 'A new city')
      .Prop('Code').Desc('IBGE code').Example('4205407').Pattern('^[0-9]{7}$')
      .Prop('State').Enum(['SP', 'RJ']);

  Prop takes the Pascal property name and raises EApiSchemaError at once if
  the class has no such published property.

  The Horse side (routes registered and documented together, Swagger UI) is
  src/horse/PascalApi.Horse.OpenApi. Design and decisions: docs/openapi-design.md. *)

interface

uses
  SysUtils,
  Classes,
  TypInfo,
  Generics.Collections,
  PascalJsonMapper.Json,
  PascalJsonMapper.Mapper;

type
  EApiSchemaError = class(Exception);

  TApiParamType = (ptString, ptInteger, ptNumber, ptBoolean);
  TApiParamLocation = (plPath, plQuery);
  TApiResponseKind = (rkNone, rkObject, rkArray, rkPaged, rkError);

  TApiParam = record
    Name: string;
    Description: string;
    Location: TApiParamLocation;
    ParamType: TApiParamType;
    Required: Boolean;
  end;

  TApiResponse = record
    Code: Integer;
    Description: string;
    Kind: TApiResponseKind;
    Schema: PTypeInfo; // the DTO interface (rkObject, rkArray, rkPaged)
  end;

  /// One documented operation. Path is in Horse's form ('/cities/:code');
  /// the document writes OpenAPI's ('/cities/{code}').
  TApiOperation = class
  public
    Method: string; // get, post, put, patch, delete
    Path: string;
    Summary: string;
    Description: string;
    OperationId: string;
    Tags: TArray<string>;
    Params: TArray<TApiParam>;
    Body: PTypeInfo;
    BodyDescription: string;
    Responses: TArray<TApiResponse>;
    /// Left out of the MCP tools (phase 5); still documented.
    NoMcp: Boolean;
    /// The path in OpenAPI's form.
    function OpenApiPath: string;
  end;

  TApiOperationList = TObjectList<TApiOperation>;

  TApiDocument = class
  private
    FMapper: TJsonMapper;
    FOperations: TApiOperationList;
  public
    Title: string;
    Version: string;
    Description: string;
    /// AMapper nil: TJsonMapper.Shared, where DTOs are usually registered.
    constructor Create(AMapper: TJsonMapper = nil);
    destructor Destroy; override;
    /// Takes ownership.
    procedure Add(AOperation: TApiOperation);
    function Operations: TApiOperationList;
    /// The document. AIndent > 0 indents (TJsonWriter).
    function ToJson(AIndent: Integer = 0): string;
  end;

  TApiPropMeta = class
  public
    Description: string;
    Example: string;
    HasExample: Boolean;
    Format: string;
    Pattern: string;
    EnumValues: TArray<string>;
    HasMinimum, HasMaximum: Boolean;
    Minimum, Maximum: Double;
    MinLength, MaxLength: Integer; // -1: not set
    constructor Create;
  end;

  TApiSchemaMeta = class
  private
    FProps: TObjectDictionary<string, TApiPropMeta>;
  public
    Description: string;
    ImplClass: TClass;
    constructor Create;
    destructor Destroy; override;
    function PropMeta(const APropertyName: string): TApiPropMeta; // nil if none
  end;

  TApiPropBuilder = record
  private
    FSchema: TApiSchemaMeta;
    FProp: TApiPropMeta;
  public
    function Desc(const AText: string): TApiPropBuilder;
    /// Written with the property's JSON type: '4205407' stays a string for a
    /// string property and becomes a number for an integer one.
    function Example(const AValue: string): TApiPropBuilder;
    function Format(const AFormat: string): TApiPropBuilder;
    function Pattern(const ARegex: string): TApiPropBuilder;
    function Enum(const AValues: array of string): TApiPropBuilder;
    function Minimum(AValue: Double): TApiPropBuilder;
    function Maximum(AValue: Double): TApiPropBuilder;
    function MinLength(AValue: Integer): TApiPropBuilder;
    function MaxLength(AValue: Integer): TApiPropBuilder;
    /// The next property of the same schema.
    function Prop(const APropertyName: string): TApiPropBuilder;
  end;

  TApiSchemaBuilder = record
  private
    FSchema: TApiSchemaMeta;
  public
    function Prop(const APropertyName: string): TApiPropBuilder;
  end;

  TApiSchema = class
  public
    /// Metadata for the DTO interface AInterface, registered with AMapper
    /// (nil: TJsonMapper.Shared) before this call. Calling it again for the
    /// same interface adds to what is there. Register at startup.
    class function Describe(AInterface: PTypeInfo; const ADescription: string = '';
      AMapper: TJsonMapper = nil): TApiSchemaBuilder; static;
    /// The schema name of a DTO interface: its name without the leading I
    /// (ICityInsert -> CityInsert).
    class function SchemaName(AInterface: PTypeInfo): string; static;
    /// Forgets every registered description (tests).
    class procedure Clear; static;
  end;

implementation

uses
  SyncObjs,
  PascalCommon.Optionals;

var
  GSchemaMetas: TObjectDictionary<PTypeInfo, TApiSchemaMeta>;
  GMetaLock: TCriticalSection;

type
  TOptionalKind = record
    TypeInfo: PTypeInfo;
    Base: string;      // string, integer, int64, float, double, currency, boolean, date-time, uuid
    Optional: Boolean; // not required
    Nullable: Boolean;
  end;

var
  GOptionals: array of TOptionalKind;

procedure AddOptional(ATypeInfo: PTypeInfo; const ABase: string; AOptional, ANullable: Boolean);
begin
  SetLength(GOptionals, Length(GOptionals) + 1);
  GOptionals[High(GOptionals)].TypeInfo := ATypeInfo;
  GOptionals[High(GOptionals)].Base := ABase;
  GOptionals[High(GOptionals)].Optional := AOptional;
  GOptionals[High(GOptionals)].Nullable := ANullable;
end;

procedure RegisterOptionals;
begin
  AddOptional(TypeInfo(IOptString), 'string', True, False);
  AddOptional(TypeInfo(INullString), 'string', False, True);
  AddOptional(TypeInfo(IOptNullString), 'string', True, True);
  AddOptional(TypeInfo(IOptInteger), 'integer', True, False);
  AddOptional(TypeInfo(INullInteger), 'integer', False, True);
  AddOptional(TypeInfo(IOptNullInteger), 'integer', True, True);
  AddOptional(TypeInfo(IOptInt64), 'int64', True, False);
  AddOptional(TypeInfo(INullInt64), 'int64', False, True);
  AddOptional(TypeInfo(IOptNullInt64), 'int64', True, True);
  AddOptional(TypeInfo(IOptSingle), 'float', True, False);
  AddOptional(TypeInfo(INullSingle), 'float', False, True);
  AddOptional(TypeInfo(IOptNullSingle), 'float', True, True);
  AddOptional(TypeInfo(IOptDouble), 'double', True, False);
  AddOptional(TypeInfo(INullDouble), 'double', False, True);
  AddOptional(TypeInfo(IOptNullDouble), 'double', True, True);
  AddOptional(TypeInfo(IOptCurrency), 'currency', True, False);
  AddOptional(TypeInfo(INullCurrency), 'currency', False, True);
  AddOptional(TypeInfo(IOptNullCurrency), 'currency', True, True);
  AddOptional(TypeInfo(IOptDateTime), 'date-time', True, False);
  AddOptional(TypeInfo(INullDateTime), 'date-time', False, True);
  AddOptional(TypeInfo(IOptNullDateTime), 'date-time', True, True);
  AddOptional(TypeInfo(IOptBoolean), 'boolean', True, False);
  AddOptional(TypeInfo(INullBoolean), 'boolean', False, True);
  AddOptional(TypeInfo(IOptNullBoolean), 'boolean', True, True);
  AddOptional(TypeInfo(IOptGuid), 'uuid', True, False);
  AddOptional(TypeInfo(INullGuid), 'uuid', False, True);
  AddOptional(TypeInfo(IOptNullGuid), 'uuid', True, True);
end;

function FindOptional(ATypeInfo: PTypeInfo; out AKind: TOptionalKind): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(GOptionals) do
    if GOptionals[I].TypeInfo = ATypeInfo then
    begin
      AKind := GOptionals[I];
      Exit(True);
    end;
  Result := False;
end;

function IsStringKind(AKind: TTypeKind): Boolean;
begin
  // FPC declares tkString as an alias of tkSString (pascal-jsonmapper-faa's rule).
  Result := AKind in [{$IFDEF FPC}tkSString, tkAString{$ELSE}tkString{$ENDIF},
    tkLString, tkWString, tkUString, tkChar, tkWChar{$IFDEF FPC}, tkUChar{$ENDIF}];
end;

function IsBooleanType(ATypeInfo: PTypeInfo): Boolean;
begin
  // Boolean is tkEnumeration on Delphi and tkBool on FPC: compare PTypeInfo.
  Result := (ATypeInfo = TypeInfo(Boolean)) or (ATypeInfo = TypeInfo(ByteBool)) or
    (ATypeInfo = TypeInfo(WordBool)) or (ATypeInfo = TypeInfo(LongBool))
    {$IFDEF FPC} or (ATypeInfo^.Kind = tkBool){$ENDIF};
end;

function DynArrayElementType(ATypeInfo: PTypeInfo): PTypeInfo;
begin
  // The same field, typed differently on each compiler (pascal-jsonmapper-faa).
  {$IFDEF FPC}
  Result := GetTypeData(ATypeInfo)^.ElType2;
  {$ELSE}
  Result := GetTypeData(ATypeInfo)^.elType2^;
  {$ENDIF}
end;

function TypeName(ATypeInfo: PTypeInfo): string;
begin
  Result := string(ATypeInfo^.Name);
end;

function ParamTypeName(AType: TApiParamType): string;
begin
  case AType of
    ptInteger: Result := 'integer';
    ptNumber: Result := 'number';
    ptBoolean: Result := 'boolean';
  else
    Result := 'string';
  end;
end;

{ TApiOperation }

function TApiOperation.OpenApiPath: string;
var
  I, J: Integer;
begin
  // ':code' segments become '{code}'.
  Result := '';
  I := 1;
  while I <= Length(Path) do
  begin
    if (Path[I] = ':') and ((I = 1) or (Path[I - 1] = '/')) then
    begin
      J := I + 1;
      while (J <= Length(Path)) and (Path[J] <> '/') do
        Inc(J);
      Result := Result + '{' + Copy(Path, I + 1, J - I - 1) + '}';
      I := J;
    end
    else
    begin
      Result := Result + Path[I];
      Inc(I);
    end;
  end;
end;

{ TApiPropMeta }

constructor TApiPropMeta.Create;
begin
  inherited Create;
  MinLength := -1;
  MaxLength := -1;
end;

{ TApiSchemaMeta }

constructor TApiSchemaMeta.Create;
begin
  inherited Create;
  FProps := TObjectDictionary<string, TApiPropMeta>.Create([doOwnsValues]);
end;

destructor TApiSchemaMeta.Destroy;
begin
  FProps.Free;
  inherited;
end;

function TApiSchemaMeta.PropMeta(const APropertyName: string): TApiPropMeta;
begin
  if not FProps.TryGetValue(UpperCase(APropertyName), Result) then
    Result := nil;
end;

{ TApiSchemaBuilder / TApiPropBuilder }

function PropBuilderFor(ASchema: TApiSchemaMeta; const APropertyName: string): TApiPropBuilder;
var
  LKey: string;
begin
  if GetPropInfo(ASchema.ImplClass, APropertyName) = nil then
    raise EApiSchemaError.CreateFmt('%s has no published property "%s"',
      [ASchema.ImplClass.ClassName, APropertyName]);
  LKey := UpperCase(APropertyName);
  if not ASchema.FProps.TryGetValue(LKey, Result.FProp) then
  begin
    Result.FProp := TApiPropMeta.Create;
    ASchema.FProps.Add(LKey, Result.FProp);
  end;
  Result.FSchema := ASchema;
end;

function TApiSchemaBuilder.Prop(const APropertyName: string): TApiPropBuilder;
begin
  Result := PropBuilderFor(FSchema, APropertyName);
end;

function TApiPropBuilder.Desc(const AText: string): TApiPropBuilder;
begin
  FProp.Description := AText;
  Result := Self;
end;

function TApiPropBuilder.Example(const AValue: string): TApiPropBuilder;
begin
  FProp.Example := AValue;
  FProp.HasExample := True;
  Result := Self;
end;

function TApiPropBuilder.Format(const AFormat: string): TApiPropBuilder;
begin
  FProp.Format := AFormat;
  Result := Self;
end;

function TApiPropBuilder.Pattern(const ARegex: string): TApiPropBuilder;
begin
  FProp.Pattern := ARegex;
  Result := Self;
end;

function TApiPropBuilder.Enum(const AValues: array of string): TApiPropBuilder;
var
  I: Integer;
begin
  FProp.EnumValues := nil;
  SetLength(FProp.EnumValues, Length(AValues));
  for I := 0 to High(AValues) do
    FProp.EnumValues[I] := AValues[I];
  Result := Self;
end;

function TApiPropBuilder.Minimum(AValue: Double): TApiPropBuilder;
begin
  FProp.Minimum := AValue;
  FProp.HasMinimum := True;
  Result := Self;
end;

function TApiPropBuilder.Maximum(AValue: Double): TApiPropBuilder;
begin
  FProp.Maximum := AValue;
  FProp.HasMaximum := True;
  Result := Self;
end;

function TApiPropBuilder.MinLength(AValue: Integer): TApiPropBuilder;
begin
  FProp.MinLength := AValue;
  Result := Self;
end;

function TApiPropBuilder.MaxLength(AValue: Integer): TApiPropBuilder;
begin
  FProp.MaxLength := AValue;
  Result := Self;
end;

function TApiPropBuilder.Prop(const APropertyName: string): TApiPropBuilder;
begin
  Result := PropBuilderFor(FSchema, APropertyName);
end;

{ TApiSchema }

function MapperOrShared(AMapper: TJsonMapper): TJsonMapper;
begin
  if Assigned(AMapper) then
    Result := AMapper
  else
    Result := TJsonMapper.Shared;
end;

class function TApiSchema.Describe(AInterface: PTypeInfo; const ADescription: string;
  AMapper: TJsonMapper): TApiSchemaBuilder;
var
  LClass: TClass;
begin
  if (AInterface = nil) or (AInterface^.Kind <> tkInterface) then
    raise EApiSchemaError.Create('TApiSchema.Describe: an interface type is required');
  LClass := MapperOrShared(AMapper).FindImplClass(AInterface);
  if LClass = nil then
    raise EApiSchemaError.CreateFmt('TApiSchema.Describe: %s has no class registered ' +
      '(call RegisterMapping first)', [TypeName(AInterface)]);
  GMetaLock.Enter;
  try
    if not GSchemaMetas.TryGetValue(AInterface, Result.FSchema) then
    begin
      Result.FSchema := TApiSchemaMeta.Create;
      GSchemaMetas.Add(AInterface, Result.FSchema);
    end;
  finally
    GMetaLock.Leave;
  end;
  Result.FSchema.ImplClass := LClass;
  if ADescription <> '' then
    Result.FSchema.Description := ADescription;
end;

class function TApiSchema.SchemaName(AInterface: PTypeInfo): string;
begin
  Result := TypeName(AInterface);
  if (Length(Result) > 1) and (Result[1] = 'I') and CharInSet(Result[2], ['A'..'Z']) then
    Result := Copy(Result, 2, MaxInt);
end;

class procedure TApiSchema.Clear;
begin
  GSchemaMetas.Clear;
end;

function SchemaMetaOf(AInterface: PTypeInfo): TApiSchemaMeta;
begin
  if not GSchemaMetas.TryGetValue(AInterface, Result) then
    Result := nil;
end;

{ TApiDocument }

constructor TApiDocument.Create(AMapper: TJsonMapper);
begin
  inherited Create;
  FMapper := MapperOrShared(AMapper);
  FOperations := TApiOperationList.Create(True);
  Title := 'API';
  Version := '1.0.0';
end;

destructor TApiDocument.Destroy;
begin
  FOperations.Free;
  inherited;
end;

procedure TApiDocument.Add(AOperation: TApiOperation);
begin
  FOperations.Add(AOperation);
end;

function TApiDocument.Operations: TApiOperationList;
begin
  Result := FOperations;
end;

type
  { Writes the document: collects the schemas the operations reference
    (transitively), then writes paths and components. }
  TApiDocWriter = class
  private
    FDoc: TApiDocument;
    FW: TJsonWriter;
    FSchemas: TList<PTypeInfo>; // interfaces, in first-reference order
    FNeedsError: Boolean;
    procedure Collect(AInterface: PTypeInfo);
    procedure CollectType(ATypeInfo: PTypeInfo);
    procedure WriteRef(AInterface: PTypeInfo);
    procedure WriteBaseType(const ABase: string);
    procedure WriteTypeSchema(ATypeInfo: PTypeInfo; AMeta: TApiPropMeta; out AOptional: Boolean);
    procedure WriteExample(const ABase, AExample: string);
    procedure WriteObjectSchema(AInterface: PTypeInfo);
    procedure WriteResponseSchema(const AResponse: TApiResponse);
    procedure WriteOperation(AOp: TApiOperation);
  public
    constructor Create(ADoc: TApiDocument; AIndent: Integer);
    destructor Destroy; override;
    function Run: string;
  end;

constructor TApiDocWriter.Create(ADoc: TApiDocument; AIndent: Integer);
begin
  inherited Create;
  FDoc := ADoc;
  FW := TJsonWriter.Create(AIndent);
  FSchemas := TList<PTypeInfo>.Create;
end;

destructor TApiDocWriter.Destroy;
begin
  FSchemas.Free;
  FW.Free;
  inherited;
end;

procedure TApiDocWriter.CollectType(ATypeInfo: PTypeInfo);
var
  LOpt: TOptionalKind;
begin
  case ATypeInfo^.Kind of
    tkInterface:
      if not FindOptional(ATypeInfo, LOpt) then
        Collect(ATypeInfo);
    tkDynArray:
      CollectType(DynArrayElementType(ATypeInfo));
  end;
end;

procedure TApiDocWriter.Collect(AInterface: PTypeInfo);
var
  LClass: TClass;
  LMembers: TJsonMemberArray;
  I: Integer;
begin
  if (AInterface = nil) or (FSchemas.IndexOf(AInterface) >= 0) then
    Exit;
  LClass := FDoc.FMapper.FindImplClass(AInterface);
  if LClass = nil then
    Exit; // written as a free-form object
  FSchemas.Add(AInterface);
  LMembers := FDoc.FMapper.Members(LClass);
  for I := 0 to High(LMembers) do
    CollectType(LMembers[I].TypeInfo);
end;

procedure TApiDocWriter.WriteRef(AInterface: PTypeInfo);
begin
  FW.BeginObject;
  if FDoc.FMapper.FindImplClass(AInterface) <> nil then
  begin
    FW.Name('$ref');
    FW.WriteString('#/components/schemas/' + TApiSchema.SchemaName(AInterface));
  end
  else
  begin
    FW.Name('type');
    FW.WriteString('object');
  end;
  FW.EndObject;
end;

// The "type"/"format" members for a base type name.
procedure TApiDocWriter.WriteBaseType(const ABase: string);

  procedure TypeAndFormat(const AType, AFormat: string);
  begin
    FW.Name('type');
    FW.WriteString(AType);
    if AFormat <> '' then
    begin
      FW.Name('format');
      FW.WriteString(AFormat);
    end;
  end;

begin
  if ABase = 'integer' then TypeAndFormat('integer', 'int32')
  else if ABase = 'int64' then TypeAndFormat('integer', 'int64')
  else if ABase = 'float' then TypeAndFormat('number', 'float')
  else if ABase = 'double' then TypeAndFormat('number', 'double')
  else if ABase = 'currency' then TypeAndFormat('number', '')
  else if ABase = 'boolean' then TypeAndFormat('boolean', '')
  else if ABase = 'date-time' then TypeAndFormat('string', 'date-time')
  else if ABase = 'date' then TypeAndFormat('string', 'date')
  else if ABase = 'time' then TypeAndFormat('string', 'time')
  else if ABase = 'uuid' then TypeAndFormat('string', 'uuid')
  else TypeAndFormat('string', '');
end;

function BaseOfType(ATypeInfo: PTypeInfo): string;
begin
  Result := '';
  if IsBooleanType(ATypeInfo) then
    Exit('boolean');
  if IsStringKind(ATypeInfo^.Kind) then
    Exit('string');
  case ATypeInfo^.Kind of
    tkInteger: Result := 'integer';
    tkInt64{$IFDEF FPC}, tkQWord{$ENDIF}: Result := 'int64';
    tkFloat:
      if ATypeInfo = TypeInfo(TDateTime) then Result := 'date-time'
      else if ATypeInfo = TypeInfo(TDate) then Result := 'date'
      else if ATypeInfo = TypeInfo(TTime) then Result := 'time'
      else
        case GetTypeData(ATypeInfo)^.FloatType of
          ftSingle: Result := 'float';
          ftCurr: Result := 'currency';
        else
          Result := 'double';
        end;
  end;
end;

procedure TApiDocWriter.WriteExample(const ABase, AExample: string);
var
  LInt: Int64;
  LFloat: Double;
begin
  FW.Name('example');
  if (ABase = 'integer') or (ABase = 'int64') then
  begin
    if TryStrToInt64(AExample, LInt) then
      FW.WriteInt64(LInt)
    else
      FW.WriteString(AExample);
  end
  else if (ABase = 'float') or (ABase = 'double') or (ABase = 'currency') then
  begin
    try
      LFloat := JsonStrToDouble(AExample);
      FW.WriteNumberText(JsonFloatToStr(LFloat));
    except
      on EJsonError do
        FW.WriteString(AExample);
    end;
  end
  else if ABase = 'boolean' then
    FW.WriteBoolean(SameText(AExample, 'true'))
  else
    FW.WriteString(AExample);
end;

// The schema object of a property of type ATypeInfo. AOptional tells the
// caller to leave it out of "required".
procedure TApiDocWriter.WriteTypeSchema(ATypeInfo: PTypeInfo; AMeta: TApiPropMeta;
  out AOptional: Boolean);
var
  LOpt: TOptionalKind;
  LBase: string;
  LNullable: Boolean;
  LData: PTypeData;
  I: Integer;
begin
  AOptional := False;
  LNullable := False;
  if (ATypeInfo^.Kind = tkInterface) and not FindOptional(ATypeInfo, LOpt) then
  begin
    WriteRef(ATypeInfo); // a nested DTO: no metadata on a $ref (OpenAPI 3.0 ignores siblings)
    Exit;
  end;

  FW.BeginObject;
  if ATypeInfo^.Kind = tkInterface then
  begin
    LBase := LOpt.Base;
    AOptional := LOpt.Optional;
    LNullable := LOpt.Nullable;
    WriteBaseType(LBase);
  end
  else if ATypeInfo^.Kind = tkDynArray then
  begin
    LBase := '';
    FW.Name('type');
    FW.WriteString('array');
    FW.Name('items');
    WriteTypeSchema(DynArrayElementType(ATypeInfo), nil, AOptional);
    AOptional := False;
  end
  else if (ATypeInfo^.Kind = tkEnumeration) and not IsBooleanType(ATypeInfo) then
  begin
    LBase := 'string';
    FW.Name('type');
    FW.WriteString('string');
    if (AMeta = nil) or (Length(AMeta.EnumValues) = 0) then
    begin
      LData := GetTypeData(ATypeInfo);
      FW.Name('enum');
      FW.BeginArray;
      for I := LData^.MinValue to LData^.MaxValue do
        FW.WriteString(GetEnumName(ATypeInfo, I));
      FW.EndArray;
    end;
  end
  else if ATypeInfo^.Kind = tkClass then
  begin
    LBase := '';
    FW.Name('type');
    FW.WriteString('object');
  end
  else
  begin
    LBase := BaseOfType(ATypeInfo);
    WriteBaseType(LBase);
  end;

  if LNullable then
  begin
    FW.Name('nullable');
    FW.WriteBoolean(True);
  end;
  if AMeta <> nil then
  begin
    if AMeta.Format <> '' then
    begin
      FW.Name('format');
      FW.WriteString(AMeta.Format);
    end;
    if AMeta.Description <> '' then
    begin
      FW.Name('description');
      FW.WriteString(AMeta.Description);
    end;
    if AMeta.HasExample then
      WriteExample(LBase, AMeta.Example);
    if AMeta.Pattern <> '' then
    begin
      FW.Name('pattern');
      FW.WriteString(AMeta.Pattern);
    end;
    if Length(AMeta.EnumValues) > 0 then
    begin
      FW.Name('enum');
      FW.BeginArray;
      for I := 0 to High(AMeta.EnumValues) do
        FW.WriteString(AMeta.EnumValues[I]);
      FW.EndArray;
    end;
    if AMeta.HasMinimum then
    begin
      FW.Name('minimum');
      FW.WriteNumberText(JsonFloatToStr(AMeta.Minimum));
    end;
    if AMeta.HasMaximum then
    begin
      FW.Name('maximum');
      FW.WriteNumberText(JsonFloatToStr(AMeta.Maximum));
    end;
    if AMeta.MinLength >= 0 then
    begin
      FW.Name('minLength');
      FW.WriteInt64(AMeta.MinLength);
    end;
    if AMeta.MaxLength >= 0 then
    begin
      FW.Name('maxLength');
      FW.WriteInt64(AMeta.MaxLength);
    end;
  end;
  FW.EndObject;
end;

procedure TApiDocWriter.WriteObjectSchema(AInterface: PTypeInfo);
var
  LClass: TClass;
  LMembers: TJsonMemberArray;
  LMeta: TApiSchemaMeta;
  LRequired: TArray<string>;
  LOptional: Boolean;
  I: Integer;
begin
  LClass := FDoc.FMapper.FindImplClass(AInterface);
  LMembers := FDoc.FMapper.Members(LClass);
  LMeta := SchemaMetaOf(AInterface);
  LRequired := nil;
  FW.BeginObject;
  FW.Name('type');
  FW.WriteString('object');
  if (LMeta <> nil) and (LMeta.Description <> '') then
  begin
    FW.Name('description');
    FW.WriteString(LMeta.Description);
  end;
  FW.Name('properties');
  FW.BeginObject;
  for I := 0 to High(LMembers) do
  begin
    FW.Name(LMembers[I].JsonName);
    if LMeta <> nil then
      WriteTypeSchema(LMembers[I].TypeInfo, LMeta.PropMeta(LMembers[I].PropertyName), LOptional)
    else
      WriteTypeSchema(LMembers[I].TypeInfo, nil, LOptional);
    if not LOptional then
    begin
      SetLength(LRequired, Length(LRequired) + 1);
      LRequired[High(LRequired)] := LMembers[I].JsonName;
    end;
  end;
  FW.EndObject;
  if Length(LRequired) > 0 then
  begin
    FW.Name('required');
    FW.BeginArray;
    for I := 0 to High(LRequired) do
      FW.WriteString(LRequired[I]);
    FW.EndArray;
  end;
  FW.EndObject;
end;

procedure TApiDocWriter.WriteResponseSchema(const AResponse: TApiResponse);

  procedure IntProp(const AName, AFormat: string);
  begin
    FW.Name(AName);
    FW.BeginObject;
    FW.Name('type');
    FW.WriteString('integer');
    FW.Name('format');
    FW.WriteString(AFormat);
    FW.EndObject;
  end;

  procedure BoolProp(const AName: string);
  begin
    FW.Name(AName);
    FW.BeginObject;
    FW.Name('type');
    FW.WriteString('boolean');
    FW.EndObject;
  end;

var
  LName: string;
begin
  case AResponse.Kind of
    rkObject:
      WriteRef(AResponse.Schema);
    rkArray:
      begin
        FW.BeginObject;
        FW.Name('type');
        FW.WriteString('array');
        FW.Name('items');
        WriteRef(AResponse.Schema);
        FW.EndObject;
      end;
    rkPaged:
      begin
        // The envelope of PascalApi.Pagination.PageEnvelopeJson.
        FW.BeginObject;
        FW.Name('type');
        FW.WriteString('object');
        FW.Name('properties');
        FW.BeginObject;
        IntProp('page', 'int32');
        IntProp('limit', 'int32');
        IntProp('total', 'int64');
        IntProp('totalPages', 'int64');
        BoolProp('hasNext');
        BoolProp('hasPrev');
        FW.Name('items');
        FW.BeginObject;
        FW.Name('type');
        FW.WriteString('array');
        FW.Name('items');
        WriteRef(AResponse.Schema);
        FW.EndObject;
        FW.EndObject;
        FW.Name('required');
        FW.BeginArray;
        for LName in TArray<string>.Create('page', 'limit', 'total', 'totalPages', 'hasNext',
          'hasPrev', 'items') do
          FW.WriteString(LName);
        FW.EndArray;
        FW.EndObject;
      end;
    rkError:
      begin
        FW.BeginObject;
        FW.Name('$ref');
        FW.WriteString('#/components/schemas/Error');
        FW.EndObject;
      end;
  end;
end;

function ResponseDescription(const AResponse: TApiResponse): string;
begin
  Result := AResponse.Description;
  if Result = '' then
    case AResponse.Code of
      200: Result := 'OK';
      201: Result := 'Created';
      204: Result := 'No Content';
      400: Result := 'Bad Request';
      401: Result := 'Unauthorized';
      404: Result := 'Not Found';
      409: Result := 'Conflict';
      422: Result := 'Unprocessable Entity';
      429: Result := 'Too Many Requests';
      500: Result := 'Internal Server Error';
      503: Result := 'Service Unavailable';
    else
      Result := 'Response';
    end;
end;

procedure TApiDocWriter.WriteOperation(AOp: TApiOperation);
var
  I, J, P: Integer;
  LPath, LSeg: string;
  LDeclared: Boolean;
  LParams: TArray<TApiParam>;
  LExtra: TApiParam;
begin
  // Path parameters present in the path but not declared get a plain string.
  LParams := Copy(AOp.Params, 0, Length(AOp.Params));
  LPath := AOp.OpenApiPath;
  P := Pos('{', LPath);
  while P > 0 do
  begin
    J := P + 1;
    while (J <= Length(LPath)) and (LPath[J] <> '}') do
      Inc(J);
    LSeg := Copy(LPath, P + 1, J - P - 1);
    LDeclared := False;
    for I := 0 to High(LParams) do
      if (LParams[I].Location = plPath) and SameText(LParams[I].Name, LSeg) then
        LDeclared := True;
    if not LDeclared then
    begin
      LExtra.Name := LSeg;
      LExtra.Description := '';
      LExtra.Location := plPath;
      LExtra.ParamType := ptString;
      LExtra.Required := True;
      SetLength(LParams, Length(LParams) + 1);
      LParams[High(LParams)] := LExtra;
    end;
    LPath := Copy(LPath, J + 1, MaxInt);
    P := Pos('{', LPath);
  end;

  FW.BeginObject;
  if Length(AOp.Tags) > 0 then
  begin
    FW.Name('tags');
    FW.BeginArray;
    for I := 0 to High(AOp.Tags) do
      FW.WriteString(AOp.Tags[I]);
    FW.EndArray;
  end;
  if AOp.Summary <> '' then
  begin
    FW.Name('summary');
    FW.WriteString(AOp.Summary);
  end;
  if AOp.Description <> '' then
  begin
    FW.Name('description');
    FW.WriteString(AOp.Description);
  end;
  if AOp.OperationId <> '' then
  begin
    FW.Name('operationId');
    FW.WriteString(AOp.OperationId);
  end;
  if Length(LParams) > 0 then
  begin
    FW.Name('parameters');
    FW.BeginArray;
    for I := 0 to High(LParams) do
    begin
      FW.BeginObject;
      FW.Name('name');
      FW.WriteString(LParams[I].Name);
      FW.Name('in');
      if LParams[I].Location = plPath then
        FW.WriteString('path')
      else
        FW.WriteString('query');
      if LParams[I].Description <> '' then
      begin
        FW.Name('description');
        FW.WriteString(LParams[I].Description);
      end;
      FW.Name('required');
      FW.WriteBoolean(LParams[I].Required or (LParams[I].Location = plPath));
      FW.Name('schema');
      FW.BeginObject;
      FW.Name('type');
      FW.WriteString(ParamTypeName(LParams[I].ParamType));
      FW.EndObject;
      FW.EndObject;
    end;
    FW.EndArray;
  end;
  if AOp.Body <> nil then
  begin
    FW.Name('requestBody');
    FW.BeginObject;
    if AOp.BodyDescription <> '' then
    begin
      FW.Name('description');
      FW.WriteString(AOp.BodyDescription);
    end;
    FW.Name('required');
    FW.WriteBoolean(True);
    FW.Name('content');
    FW.BeginObject;
    FW.Name('application/json');
    FW.BeginObject;
    FW.Name('schema');
    WriteRef(AOp.Body);
    FW.EndObject;
    FW.EndObject;
    FW.EndObject;
  end;
  FW.Name('responses');
  FW.BeginObject;
  for I := 0 to High(AOp.Responses) do
  begin
    FW.Name(IntToStr(AOp.Responses[I].Code));
    FW.BeginObject;
    FW.Name('description');
    FW.WriteString(ResponseDescription(AOp.Responses[I]));
    if AOp.Responses[I].Kind <> rkNone then
    begin
      FW.Name('content');
      FW.BeginObject;
      FW.Name('application/json');
      FW.BeginObject;
      FW.Name('schema');
      WriteResponseSchema(AOp.Responses[I]);
      FW.EndObject;
      FW.EndObject;
    end;
    FW.EndObject;
  end;
  if Length(AOp.Responses) = 0 then
  begin
    FW.Name('default');
    FW.BeginObject;
    FW.Name('description');
    FW.WriteString('Response');
    FW.EndObject;
  end;
  FW.EndObject;
  FW.EndObject;
end;

function TApiDocWriter.Run: string;
var
  LPaths: TStringList; // OpenAPI paths in first-registration order
  I, J: Integer;
  LOp: TApiOperation;
begin
  // Every schema referenced, transitively, before writing.
  FNeedsError := False;
  for LOp in FDoc.FOperations do
  begin
    if LOp.Body <> nil then
      Collect(LOp.Body);
    for I := 0 to High(LOp.Responses) do
      if LOp.Responses[I].Kind in [rkObject, rkArray, rkPaged] then
        Collect(LOp.Responses[I].Schema)
      else if LOp.Responses[I].Kind = rkError then
        FNeedsError := True;
  end;

  LPaths := TStringList.Create;
  try
    for LOp in FDoc.FOperations do
      if LPaths.IndexOf(LOp.OpenApiPath) < 0 then
        LPaths.Add(LOp.OpenApiPath);

    FW.BeginObject;
    FW.Name('openapi');
    FW.WriteString('3.0.3');
    FW.Name('info');
    FW.BeginObject;
    FW.Name('title');
    FW.WriteString(FDoc.Title);
    FW.Name('version');
    FW.WriteString(FDoc.Version);
    if FDoc.Description <> '' then
    begin
      FW.Name('description');
      FW.WriteString(FDoc.Description);
    end;
    FW.EndObject;
    FW.Name('paths');
    FW.BeginObject;
    for I := 0 to LPaths.Count - 1 do
    begin
      FW.Name(LPaths[I]);
      FW.BeginObject;
      for J := 0 to FDoc.FOperations.Count - 1 do
      begin
        LOp := FDoc.FOperations[J];
        if LOp.OpenApiPath = LPaths[I] then
        begin
          FW.Name(LowerCase(LOp.Method));
          WriteOperation(LOp);
        end;
      end;
      FW.EndObject;
    end;
    FW.EndObject;
    if (FSchemas.Count > 0) or FNeedsError then
    begin
      FW.Name('components');
      FW.BeginObject;
      FW.Name('schemas');
      FW.BeginObject;
      for I := 0 to FSchemas.Count - 1 do
      begin
        FW.Name(TApiSchema.SchemaName(FSchemas[I]));
        WriteObjectSchema(FSchemas[I]);
      end;
      if FNeedsError then
      begin
        // The body of every error PascalApi.Http.ErrorJson writes.
        FW.Name('Error');
        FW.BeginObject;
        FW.Name('type');
        FW.WriteString('object');
        FW.Name('properties');
        FW.BeginObject;
        FW.Name('error');
        FW.BeginObject;
        FW.Name('type');
        FW.WriteString('string');
        FW.EndObject;
        FW.EndObject;
        FW.Name('required');
        FW.BeginArray;
        FW.WriteString('error');
        FW.EndArray;
        FW.EndObject;
      end;
      FW.EndObject;
      FW.EndObject;
    end;
    FW.EndObject;
    Result := FW.ToString;
  finally
    LPaths.Free;
  end;
end;

function TApiDocument.ToJson(AIndent: Integer): string;
var
  LWriter: TApiDocWriter;
begin
  LWriter := TApiDocWriter.Create(Self, AIndent);
  try
    Result := LWriter.Run;
  finally
    LWriter.Free;
  end;
end;

initialization
  GSchemaMetas := TObjectDictionary<PTypeInfo, TApiSchemaMeta>.Create([doOwnsValues]);
  GMetaLock := TCriticalSection.Create;
  RegisterOptionals;

finalization
  GSchemaMetas.Free;
  GMetaLock.Free;

end.
