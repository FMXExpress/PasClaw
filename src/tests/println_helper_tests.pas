program println_helper_tests;
{ Light smoke test for the PasClaw.CliUI.Print* helpers. We can't easily
  assert on console rendering (the test runs as a captured subprocess in
  CI/local make), but we CAN verify that the symbols compile, link, and
  emit output without raising -- that catches dropped helpers, wrong
  signatures, or a missing platform branch. Output is funnelled through
  redirection on Linux to land in the file fallback path (UTF-8 bytes
  via Write/WriteLn on FPC), confirming the bytes round-trip. }

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.CliUI;

begin
  Print('print-no-newline');
  PrintLn;                           { bare-arg overload }
  PrintLn('printlinen-with-arg');
  PrintLn('utf8-roundtrip: é è ω 中 ✓');
  PrintErr('printerr-stderr');
  PrintLnErr;
  PrintLnErr('printlinen-stderr');
  PrintLn('println_helper_tests: OK');
end.
