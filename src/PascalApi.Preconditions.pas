unit PascalApi.Preconditions;

{$I pascalapi.inc}

{ Optimistic concurrency over HTTP (0.23.0): an entity tag made from a row's
  version, and the If-Match check (RFC 9110, section 13.1.1; 428 from
  RFC 6585). A client reads a resource and its ETag, then sends the change
  with If-Match: that ETag; a change that landed in between is a 412, not a
  lost update.

    RequireIfMatchSent(AReq.Headers['If-Match']);       // before the read: 428, 400
    LRow := Repo.Read(AId);                            // 404
    RequireIfMatch(AReq.Headers['If-Match'], VersionETag(LRow.Version)); // 412
    if Repo.UpdateWhereVersion(AId, LRow.Version, ...) = 0 then
      RaisePreconditionFailed;                         // changed after the check

  - The tag is the version in quotes, a strong validator: "3". A client
    that read the version in a body can build it too.
  - If-Match is "*" or a list of entity tags (blanks and empty elements
    allowed, RFC 9110 section 5.6.1). It matches when one of them is
    strongly equal to the current tag: a weak tag (W/"3") never matches.
  - The policy RequireIfMatch applies: a change needs If-Match (absent:
    428 precondition_required), with the tag the client read; "*" only
    when the caller accepts it (AAcceptAny: it says nothing about which
    version was read, so it is a 428 by default). A header that isn't the
    RFC's syntax is a 400 (invalid_if_match); a tag that isn't the current
    one, a 412 (precondition_failed). Messages from TApiMessages.

  No middleware: the check needs the resource's current version, which
  only the handler reads. The write that follows names the version read
  (UPDATE ... WHERE VERSION = :VERSION), so a change between the check and
  the write matches no row: RaisePreconditionFailed.

  Its own unit, not PascalApi.Http: that unit holds the middlewares'
  decisions (over a thousand lines); this is a handler's, with its own RFC.
  From pascal-agenda-faa (Agenda.Preconditions), where it guards changing
  and cancelling an appointment. }

interface

const
  API_CODE_PRECONDITION_REQUIRED = 'precondition_required';
  API_CODE_PRECONDITION_FAILED = 'precondition_failed';
  API_CODE_INVALID_IF_MATCH = 'invalid_if_match';

type
  TIfMatchResult = (
    imAbsent,   // no header, or only blanks
    imAny,      // "*"
    imMatch,    // a tag strongly equal to the current one
    imNoMatch,  // valid, but no tag matches
    imInvalid   // not the RFC's syntax
  );

/// '"<version>"': a strong entity tag.
function VersionETag(AVersion: Int64): string;

/// What AHeader (If-Match's value) says about ACurrentETag (a strong tag,
/// quotes included). ACurrentETag '' only checks the syntax: imMatch never.
function EvaluateIfMatch(const AHeader, ACurrentETag: string): TIfMatchResult;

/// Before reading the row: 428 when AHeader is absent (or "*" and not
/// AAcceptAny), 400 when it isn't valid. EHttpException.
procedure RequireIfMatchSent(const AHeader: string; AAcceptAny: Boolean = False);

/// RequireIfMatchSent, then 412 unless AHeader matches ACurrentETag.
procedure RequireIfMatch(const AHeader, ACurrentETag: string; AAcceptAny: Boolean = False);

/// The 412 for a write guarded by the version read that matched no row:
/// the resource changed after the check.
procedure RaisePreconditionFailed;

implementation

uses
  SysUtils,
  PascalApi.Http;

function VersionETag(AVersion: Int64): string;
begin
  Result := '"' + IntToStr(AVersion) + '"';
end;

function IsBlank(C: Char): Boolean;
begin
  Result := (C = ' ') or (C = #9);
end;

// etagc: %x21 / %x23-7E / obs-text (%x80-FF; any non-ASCII character here).
function IsETagChar(C: Char): Boolean;
begin
  Result := (C = #$21) or ((C >= #$23) and (C <= #$7E)) or (Ord(C) >= $80);
end;

function EvaluateIfMatch(const AHeader, ACurrentETag: string): TIfMatchResult;
var
  P, N, LStart: Integer;
  LWeak, LMatched, LAny: Boolean;
begin
  N := Length(AHeader);
  P := 1;
  while (P <= N) and IsBlank(AHeader[P]) do
    Inc(P);
  if P > N then
    Exit(imAbsent);
  if Trim(AHeader) = '*' then
    Exit(imAny);
  LMatched := False;
  LAny := False;
  // #entity-tag: elements separated by commas, blanks around them, empty
  // elements allowed (RFC 9110, section 5.6.1).
  while P <= N do
  begin
    while (P <= N) and (IsBlank(AHeader[P]) or (AHeader[P] = ',')) do
      Inc(P);
    if P > N then
      Break;
    LWeak := False;
    if (P + 1 <= N) and (AHeader[P] = 'W') and (AHeader[P + 1] = '/') then
    begin
      LWeak := True;
      Inc(P, 2);
    end;
    if (P > N) or (AHeader[P] <> '"') then
      Exit(imInvalid);
    LStart := P;
    Inc(P);
    while (P <= N) and IsETagChar(AHeader[P]) do
      Inc(P);
    if (P > N) or (AHeader[P] <> '"') then
      Exit(imInvalid);
    Inc(P);
    LAny := True;
    if not LWeak and (ACurrentETag <> '') and
      (Copy(AHeader, LStart, P - LStart) = ACurrentETag) then
      LMatched := True;
    while (P <= N) and IsBlank(AHeader[P]) do
      Inc(P);
    if (P <= N) and (AHeader[P] <> ',') then
      Exit(imInvalid);
  end;
  if not LAny then
    Exit(imInvalid); // only commas
  if LMatched then
    Result := imMatch
  else
    Result := imNoMatch;
end;

procedure RequireIfMatchSent(const AHeader: string; AAcceptAny: Boolean);
begin
  case EvaluateIfMatch(AHeader, '') of
    imAbsent:
      raise EHttpException.Create(428, TApiMessages.Current.PreconditionRequired,
        API_CODE_PRECONDITION_REQUIRED);
    imAny:
      if not AAcceptAny then
        raise EHttpException.Create(428, TApiMessages.Current.PreconditionAnyRefused,
          API_CODE_PRECONDITION_REQUIRED);
    imInvalid:
      raise EHttpException.Create(400, TApiMessages.Current.InvalidIfMatch,
        API_CODE_INVALID_IF_MATCH);
  end;
end;

procedure RequireIfMatch(const AHeader, ACurrentETag: string; AAcceptAny: Boolean);
begin
  RequireIfMatchSent(AHeader, AAcceptAny);
  case EvaluateIfMatch(AHeader, ACurrentETag) of
    imMatch, imAny:
      ;
  else
    raise EHttpException.Create(412, Format(TApiMessages.Current.PreconditionFailedETag,
      [ACurrentETag]), API_CODE_PRECONDITION_FAILED);
  end;
end;

procedure RaisePreconditionFailed;
begin
  raise EHttpException.Create(412, TApiMessages.Current.PreconditionFailed,
    API_CODE_PRECONDITION_FAILED);
end;

end.
