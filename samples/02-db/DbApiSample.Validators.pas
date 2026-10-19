unit DbApiSample.Validators;

(* The sample's validators, gathered in one factory (pascal-common-faa 1.21.0),
  the partner of DbApiSample.Normalizers.

  TValid inherits TPcStringValidators, so TValid.Required, MinLength,
  MaxLength, OneOf, FromFunc and All come from the library, and the editor
  lists the sample's own rules next to them. Only what the OpenAPI document
  can't say is here: the limits it declares (TApiSchema.Describe in
  DbApiSample.Cities: name at most 100 characters, state of 2, population not
  negative) are enforced at the edge by THorseBody.Read (pascal-api-infra-faa
  0.20.0), so a limit is written once.

  - Code: the document has its Pattern ('^[0-9]{7}$'), which isn't enforced
    (no regular expression dialect both compilers share), so the rule is
    written here once.
  - A name must have something besides blanks: MinLength(1) would count
    spaces; Required doesn't.

  This comment uses parenthesis-asterisk: it quotes the pattern, whose brace
  would close a brace comment. *)

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  PascalCommon.Validators;

type
  TValid = class(TPcStringValidators)
  public
    /// The IBGE code of a city: exactly 7 ASCII digits.
    class function IbgeCode: IPcStringValidator; static;
  end;

implementation

uses
  SysUtils;

/// True when AText is exactly ALength ASCII digits. StrToIntDef would also
/// take '+123456' or '-000001'.
function IsDigits(const AText: string; ALength: Integer): Boolean;
var
  I: Integer;
begin
  Result := Length(AText) = ALength;
  if Result then
    for I := 1 to Length(AText) do
      if not CharInSet(AText[I], ['0'..'9']) then
        Exit(False);
end;

function CheckIbgeCode(const AField, AValue: string; out AMessage: string): string;
begin
  Result := '';
  if not IsDigits(AValue, 7) then
  begin
    Result := 'invalid_ibge_code';
    AMessage := Format('"%s" must be the 7-digit IBGE code.', [AField]);
  end;
end;

class function TValid.IbgeCode: IPcStringValidator;
begin
  Result := FromFunc(CheckIbgeCode);
end;

end.
