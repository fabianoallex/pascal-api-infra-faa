unit PascalApi.Config;

{$I pascalapi.inc}

{ Configuration from environment variables, with a .env file as fallback.

  Lookup order: environment variable, then the .env file, then the default.
  The default file is .env in the executable's folder. Format: KEY=VALUE, one
  per line; blank lines and lines starting with # are ignored; a value may
  be wrapped in single or double quotes. Keys are compared ignoring case in
  the file. The file is UTF-8 (see PascalApi.Text for the FPC code page rule)
  and is read again on every call, so editing it takes effect without a
  restart.

    LPort := TAppConfig.GetInt('SERVER_PORT', 9000);
    LDb := TAppConfig.Get('DB_PATH', 'app.fdb');

  Tests replace the file with SetEnvFile and the environment with
  SetEnvironmentReader. The second exists because changing the real process
  environment isn't portable: FPC's GetEnvironmentVariable on Unix reads the
  environment captured at startup, so a setenv afterwards isn't seen.

  Ported from Common.Config (delphi-api-infra-faa). Dropped: SetIniFile and
  IniPath, aliases kept there for backward compatibility. }

interface

type
  /// Returns the value of the environment variable AName, or '' if unset.
  TEnvironmentReader = function(const AName: string): string;

  TAppConfig = class
  private
    class var FEnvPath: string;
    class var FEnvReader: TEnvironmentReader;
    class function ReadFile(const AKey: string): string; static;
  public
    class procedure SetEnvFile(const APath: string); static;
    class function EnvFilePath: string; static;
    /// nil restores the process environment.
    class procedure SetEnvironmentReader(AReader: TEnvironmentReader); static;

    class function Get(const AKey: string; const ADefault: string = ''): string; static;
    class function GetInt(const AKey: string; ADefault: Integer = 0): Integer; static;
    /// 'true', '1' and 'yes' (any case) are True; any other value is False.
    class function GetBool(const AKey: string; ADefault: Boolean = False): Boolean; static;
  end;

implementation

uses
  Classes,
  SysUtils,
  PascalApi.Text;

function ProcessEnvironment(const AName: string): string;
begin
  Result := GetEnvironmentVariable(AName);
end;

function ReadFileBytes(const APath: string): TBytes;
var
  LStream: TFileStream;
begin
  LStream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    Result := nil;
    SetLength(Result, LStream.Size);
    if Length(Result) > 0 then
      LStream.ReadBuffer(Result[0], Length(Result));
  finally
    LStream.Free;
  end;
end;

function Unquote(const AValue: string): string;
var
  LLen: Integer;
begin
  Result := AValue;
  LLen := Length(AValue);
  if (LLen >= 2) and (((AValue[1] = '"') and (AValue[LLen] = '"')) or
    ((AValue[1] = '''') and (AValue[LLen] = ''''))) then
    Result := Copy(AValue, 2, LLen - 2);
end;

{ TAppConfig }

class procedure TAppConfig.SetEnvFile(const APath: string);
begin
  FEnvPath := APath;
end;

class function TAppConfig.EnvFilePath: string;
begin
  Result := FEnvPath;
end;

class procedure TAppConfig.SetEnvironmentReader(AReader: TEnvironmentReader);
begin
  if Assigned(AReader) then
    FEnvReader := AReader
  else
    FEnvReader := ProcessEnvironment;
end;

class function TAppConfig.ReadFile(const AKey: string): string;
var
  LLines: TStringList;
  LLine: string;
  I, LSep: Integer;
begin
  Result := '';
  if not FileExists(FEnvPath) then
    Exit;
  LLines := TStringList.Create;
  try
    LLines.Text := PaUtf8BytesToString(ReadFileBytes(FEnvPath), FEnvPath);
    for I := 0 to LLines.Count - 1 do
    begin
      LLine := Trim(LLines[I]);
      if (LLine = '') or (LLine[1] = '#') then
        Continue;
      LSep := Pos('=', LLine);
      if LSep <= 1 then
        Continue;
      if not SameText(Trim(Copy(LLine, 1, LSep - 1)), AKey) then
        Continue;
      Exit(Unquote(Copy(LLine, LSep + 1, MaxInt)));
    end;
  finally
    LLines.Free;
  end;
end;

class function TAppConfig.Get(const AKey, ADefault: string): string;
begin
  Result := FEnvReader(AKey);
  if Result = '' then
    Result := ReadFile(AKey);
  if Result = '' then
    Result := ADefault;
end;

class function TAppConfig.GetInt(const AKey: string; ADefault: Integer): Integer;
begin
  if not TryStrToInt(Get(AKey), Result) then
    Result := ADefault;
end;

class function TAppConfig.GetBool(const AKey: string; ADefault: Boolean): Boolean;
var
  LValue: string;
begin
  LValue := LowerCase(Get(AKey));
  if LValue = '' then
    Result := ADefault
  else
    Result := (LValue = 'true') or (LValue = '1') or (LValue = 'yes');
end;

initialization
  // Set here, not lazily: unit initialization runs once, before any thread
  // can call Get (a lazy default raced in pascal-common-faa's TClock).
  TAppConfig.FEnvPath := ExtractFilePath(ParamStr(0)) + '.env';
  TAppConfig.FEnvReader := ProcessEnvironment;

end.
