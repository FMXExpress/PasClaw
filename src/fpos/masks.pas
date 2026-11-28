(*
  Masks for the FreePascalOS build of PasClaw: MatchesMask.

  The other FPC builds take Masks from Lazarus's lazutils, whose file
  helpers use the Unix unit on everything that is not Windows --
  FreePascalOS has none. PasClaw uses one routine of it (fs_grep's
  include filter, file listings), so this unit gives that routine:
  '*' any run of characters, '?' one character, '[abc]', '[a-z]' and
  '[!abc]' a set, case-insensitive unless asked, as Lazarus's and
  Delphi's MatchesMask are. Only `make fpos` puts src/fpos on the unit
  path.

  PasClaw's own code, MIT like the rest of it.
*)
unit masks;

{$MODE OBJFPC}
{$H+}

interface

function MatchesMask(const FileName, Mask: string; CaseSensitive: Boolean = False): Boolean;

implementation

uses
  SysUtils;

function MatchAt(const S, M: string; Si, Mi: Integer): Boolean;
var
  SetEnd, k: Integer;
  Negate, InSet: Boolean;
  Lo, Hi: Char;
begin
  while Mi <= Length(M) do
  begin
    case M[Mi] of
      '*':
        begin
          while (Mi <= Length(M)) and (M[Mi] = '*') do Inc(Mi);
          if Mi > Length(M) then Exit(True);
          for k := Si to Length(S) + 1 do
            if MatchAt(S, M, k, Mi) then Exit(True);
          Exit(False);
        end;
      '?':
        begin
          if Si > Length(S) then Exit(False);
          Inc(Si);
          Inc(Mi);
        end;
      '[':
        begin
          SetEnd := Mi + 1;
          while (SetEnd <= Length(M)) and (M[SetEnd] <> ']') do Inc(SetEnd);
          if SetEnd > Length(M) then
          begin
            { No closing bracket: a literal '['. }
            if (Si > Length(S)) or (S[Si] <> '[') then Exit(False);
            Inc(Si);
            Inc(Mi);
            Continue;
          end;
          if Si > Length(S) then Exit(False);
          k := Mi + 1;
          Negate := (k < SetEnd) and (M[k] = '!');
          if Negate then Inc(k);
          InSet := False;
          while k < SetEnd do
          begin
            Lo := M[k];
            Hi := Lo;
            if (k + 2 < SetEnd) and (M[k + 1] = '-') then
            begin
              Hi := M[k + 2];
              Inc(k, 2);
            end;
            if (S[Si] >= Lo) and (S[Si] <= Hi) then InSet := True;
            Inc(k);
          end;
          if InSet = Negate then Exit(False);
          Inc(Si);
          Mi := SetEnd + 1;
        end;
    else
      begin
        if (Si > Length(S)) or (S[Si] <> M[Mi]) then Exit(False);
        Inc(Si);
        Inc(Mi);
      end;
    end;
  end;
  Result := Si > Length(S);
end;

function MatchesMask(const FileName, Mask: string; CaseSensitive: Boolean): Boolean;
begin
  if CaseSensitive then
    Result := MatchAt(FileName, Mask, 1, 1)
  else
    Result := MatchAt(LowerCase(FileName), LowerCase(Mask), 1, 1);
end;

end.
