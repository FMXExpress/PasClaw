(*
  PasClaw.Tools.Regex - thin cross-target wrapper around FPC's
  RegExpr and Delphi's System.RegularExpressions so the sandbox
  policy (and any future consumer) can take regex patterns from
  config.json without each callsite having to fork on compiler.

  Single function exposed:

    RegexMatch(const Pattern, S: string): Boolean

  PCRE-style syntax -- anchors (^ $), character classes ([...]),
  quantifiers (* + ? {n,m}), groups, alternation. Patterns are
  compiled fresh on each call; if the sandbox's match rate ever
  becomes a hot path the implementation should grow a per-pattern
  cache, but allow_*_paths lists are short and the call rate is
  tool-call frequency, not per-line frequency.

  Behaviour for invalid patterns: returns False rather than raising.
  A misconfigured regex in config.json should not crash the agent;
  the sandbox layer treats False the same as "no allowlist match"
  and falls through to the workspace boundary check.

  Backend notes:

    FPC   - uses Sorokin's RegExpr unit, bundled with fcl-regexpr
            in every FPC distribution since 2.x. No extra package
            install. TRegExpr.Exec is unanchored; we mimic
            TRegEx.IsMatch's "match anywhere" semantics, so callers
            wanting full-string match must anchor with ^ ... $.
    Delphi - uses System.RegularExpressions.TRegEx.IsMatch
            (PCRE-backed since XE).
*)
unit PasClaw.Tools.Regex;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function RegexMatch(const Pattern, S: string): Boolean;

implementation

uses
  SysUtils,
  {$IFDEF FPC}
    RegExpr
  {$ELSE}
    System.RegularExpressions
  {$ENDIF};

function RegexMatch(const Pattern, S: string): Boolean;
{$IFDEF FPC}
var
  R: TRegExpr;
begin
  Result := False;
  if Trim(Pattern) = '' then Exit;
  R := TRegExpr.Create;
  try
    try
      R.Expression := Pattern;
      Result := R.Exec(S);
    except
      Result := False;
    end;
  finally
    R.Free;
  end;
end;
{$ELSE}
begin
  Result := False;
  if Trim(Pattern) = '' then Exit;
  try
    Result := TRegEx.IsMatch(S, Pattern);
  except
    Result := False;
  end;
end;
{$ENDIF}

end.
