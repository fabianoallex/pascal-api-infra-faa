unit PascalApi.QueryParams;

{$I pascalapi.inc}

{ A Find DTO filled from the query string, by the same members the OpenAPI
  document lists for it.

  TRouteDoc's QueryParams<IFind> documents a list route's parameters from
  the DTO's published members (PascalApi.OpenApi); before 0.19.0 every
  handler then copied each one back by hand, ParseQueryInt('page', ...),
  ParseQueryStr(...) and a parser of its own for each filter: pascal-agenda-
  faa, the first application on the library, had five list routes doing it.
  TQueryParams.Read<IFind> does it from the DTO:

    LFind := TQueryParams.Read<IServiceFind>(TJsonMapper.Shared, AReq.Query.Content);
    // or, in a Horse handler: THorseQueryParams.Read<IServiceFind>(AReq)

  How: each member the document would list (ApiQueryParamType: strings,
  integers, numbers, booleans, enumerations, dates, and pascal-common-faa's
  optionals of those) is looked up by its JSON name and written into a JSON
  object, and the mapper creates the DTO from it. So a value goes through the
  same rules as a body: an IOptInteger is absent or a number, an integer out
  of range is refused, a TUtcDateTime needs its zone, a converter applies.

  - Absent or empty ("?search=") is an absent member: the DTO keeps its
    default (an optional stays Undefined).
  - A value of the wrong kind is a 400 naming the parameter, with
    TApiMessages' InvalidQueryInteger, InvalidQueryNumber or
    InvalidQueryBoolean; booleans are "true" or "false". What the mapper
    refuses (out of range, a bad date) is a 400 too, its "$.name: reason"
    told as "name: reason".
  - Parameters the DTO doesn't have are ignored: a query string often
    carries others (a cache buster, a tracking tag), unlike a JSON body.
  - Names are matched as JSON names are, ignoring case.
  - Objects and arrays are skipped, as the document skips them. }

interface

uses
  Classes,
  PascalJsonMapper.Mapper;

type
  TQueryParams = class
  public
    /// The JSON object the query values AValues (Name=Value lines, as
    /// THorseCoreParam.Content holds them) give ADtoClass's members.
    /// EValidationException (400) for a value of the wrong kind.
    class function ToJson(AMapper: TJsonMapper; ADtoClass: TClass;
      AValues: TStrings): string; static;
    /// The DTO interface I, its class registered in AMapper
    /// (RegisterMapping), filled from AValues. EValidationException (400)
    /// for a value that doesn't fit its member.
    class function Read<I: IInterface>(AMapper: TJsonMapper; AValues: TStrings): I; static;
  end;

implementation

uses
  SysUtils,
  TypInfo,
  PascalJsonMapper.Json,
  PascalCommon.Validators,
  PascalApi.OpenApi,
  PascalApi.Http;

// The JSON integer for AText ("-0012" -> "-12"); False unless an optional
// '-' and digits. The range is the mapper's to check, against the member.
function TryIntegerText(const AText: string; out AJson: string): Boolean;
var
  I, LStart: Integer;
  LNegative: Boolean;
begin
  AJson := '';
  LNegative := (AText <> '') and (AText[1] = '-');
  LStart := 1 + Ord(LNegative);
  Result := Length(AText) >= LStart;
  if not Result then
    Exit;
  for I := LStart to Length(AText) do
    if (AText[I] < '0') or (AText[I] > '9') then
      Exit(False);
  I := LStart;
  while (I < Length(AText)) and (AText[I] = '0') do
    Inc(I);
  AJson := Copy(AText, I, MaxInt);
  if LNegative and (AJson <> '0') then
    AJson := '-' + AJson;
end;

// True when AText is a JSON number (RFC 8259): -?int(.digits)?([eE][+-]?digits)?
function IsJsonNumber(const AText: string): Boolean;
var
  I, N: Integer;

  function Digits: Integer;
  begin
    Result := 0;
    while (I <= N) and (AText[I] >= '0') and (AText[I] <= '9') do
    begin
      Inc(I);
      Inc(Result);
    end;
  end;

begin
  N := Length(AText);
  I := 1;
  if (I <= N) and (AText[I] = '-') then
    Inc(I);
  if (I <= N) and (AText[I] = '0') then
    Inc(I)
  else if Digits = 0 then
    Exit(False);
  if (I <= N) and (AText[I] = '.') then
  begin
    Inc(I);
    if Digits = 0 then
      Exit(False);
  end;
  if (I <= N) and ((AText[I] = 'e') or (AText[I] = 'E')) then
  begin
    Inc(I);
    if (I <= N) and ((AText[I] = '+') or (AText[I] = '-')) then
      Inc(I);
    if Digits = 0 then
      Exit(False);
  end;
  Result := I > N;
end;

function ValueOf(AValues: TStrings; const AName: string; out AValue: string): Boolean;
var
  I: Integer;
begin
  AValue := '';
  Result := False;
  if AValues = nil then
    Exit;
  for I := 0 to AValues.Count - 1 do
    if SameText(AValues.Names[I], AName) then
    begin
      AValue := AValues.ValueFromIndex[I];
      Exit(AValue <> '');
    end;
end;

class function TQueryParams.ToJson(AMapper: TJsonMapper; ADtoClass: TClass;
  AValues: TStrings): string;
var
  LMembers: TJsonMemberArray;
  LWriter: TJsonWriter;
  LType: TApiParamType;
  LOptional: Boolean;
  LName, LText, LJson: string;
  I: Integer;
begin
  LMembers := AMapper.Members(ADtoClass);
  LWriter := TJsonWriter.Create;
  try
    LWriter.BeginObject;
    for I := 0 to High(LMembers) do
    begin
      if not LMembers[I].Writable then
        Continue;
      if not ApiQueryParamType(LMembers[I].TypeInfo, LType, LOptional) then
        Continue;
      LName := LMembers[I].JsonName;
      if not ValueOf(AValues, LName, LText) then
        Continue;
      case LType of
        ptInteger:
          begin
            if not TryIntegerText(LText, LJson) then
              raise EValidationException.Create(
                Format(TApiMessages.Current.InvalidQueryInteger, [LName]));
            LWriter.Name(LName);
            LWriter.WriteNumberText(LJson);
          end;
        ptNumber:
          begin
            if not IsJsonNumber(LText) then
              raise EValidationException.Create(
                Format(TApiMessages.Current.InvalidQueryNumber, [LName]));
            LWriter.Name(LName);
            LWriter.WriteNumberText(LText);
          end;
        ptBoolean:
          begin
            if (LText <> 'true') and (LText <> 'false') then
              raise EValidationException.Create(
                Format(TApiMessages.Current.InvalidQueryBoolean, [LName]));
            LWriter.Name(LName);
            LWriter.WriteBoolean(LText = 'true');
          end;
      else
        LWriter.Name(LName);
        LWriter.WriteString(LText);
      end;
    end;
    LWriter.EndObject;
    Result := LWriter.ToString;
  finally
    LWriter.Free;
  end;
end;

class function TQueryParams.Read<I>(AMapper: TJsonMapper; AValues: TStrings): I;
var
  LClass: TClass;
  LJson: string;
  LCheck: TPcValidation;
begin
  LClass := AMapper.FindImplClass(TypeInfo(I));
  if LClass = nil then
    raise EJsonMapperError.CreateFmt('TQueryParams.Read: %s has no class registered ' +
      '(call RegisterMapping first)', [string(PTypeInfo(TypeInfo(I))^.Name)]);
  LJson := ToJson(AMapper, LClass, AValues);
  try
    Result := AMapper.FromJson<I>(LJson);
  except
    // "$.limit: 99999999999 is out of range ..." -> "limit: ...": a query
    // parameter, not a JSON path.
    on E: EJsonInputError do
      if Copy(E.Message, 1, 2) = '$.' then
        raise EValidationException.Create(Copy(E.Message, 3, MaxInt))
      else
        raise EValidationException.Create(E.Message);
  end;
  // The limits the document declares for these parameters (0.20.0).
  LCheck := TPcValidation.Create;
  TApiSchema.Check(TypeInfo(I), Result, LCheck, AMapper);
  LCheck.RaiseIfAny;
end;

end.
