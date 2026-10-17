unit DbApiSample.Normalizers;

{ The sample's normalizers, gathered in one factory (pascal-common-faa 1.14.0).

  TNorm inherits TPcStringNormalizers, so TNorm.Trim, Upper, Lower, FromFunc
  and Chain come from the library, and the editor lists the sample's own
  normalizers next to them. The business rules (a city name, a state code)
  have a name and live here once; the repository only says which rule
  applies to which member. Inheritance, not a class helper: Delphi and
  FPC 3.2 see one helper per type, so two helpers would hide each other.

  A normalizer changes a present value and keeps the state (absent stays
  absent, null stays null). The limits ("name" not empty, at most 100
  characters) stay in the repository's checks: a normalizer that cut the
  name at 100 would hide a client's mistake instead of answering 400.

  PascalCommon.Normalizers doesn't depend on the optionals: the same TNorm
  rules also apply to a plain string (TNorm.CityName.Apply(S)). }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  PascalCommon.Normalizers;

type
  TNorm = class(TPcStringNormalizers)
  public
    /// Runs of spaces inside the text become one space.
    class function CollapseSpaces: IPcStringNormalizer; static;
    /// A city name: trimmed, inner runs of spaces collapsed.
    class function CityName: IPcStringNormalizer; static;
    /// A state code: trimmed and in upper case ('sp' becomes 'SP').
    class function StateCode: IPcStringNormalizer; static;
  end;

implementation

uses
  SysUtils;

function CollapseSpacesOf(const AValue: string): string;
begin
  Result := AValue;
  while Pos('  ', Result) > 0 do
    Result := StringReplace(Result, '  ', ' ', [rfReplaceAll]);
end;

class function TNorm.CollapseSpaces: IPcStringNormalizer;
begin
  Result := FromFunc(CollapseSpacesOf);
end;

class function TNorm.CityName: IPcStringNormalizer;
begin
  Result := Chain([Trim, CollapseSpaces]);
end;

class function TNorm.StateCode: IPcStringNormalizer;
begin
  Result := Chain([Trim, Upper]);
end;

end.
