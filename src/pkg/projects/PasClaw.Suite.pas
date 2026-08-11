(*
  PasClaw.Suite - the system suite: the apps a fresh desktop starts with.

  Odysseus's lesson is that a self-hosted agent becomes useful to a normal
  person when it arrives as everyday apps -- Notes, Tasks, Brain, Library --
  rather than as a console. PasClaw already has the backing surfaces for most
  of that (memory, cron, sessions, the project board); what was missing was
  somewhere to see them.

  The rule from docs/desktop-plan.md §2c: SUITE APPS ARE BLUEPRINTS, NOT
  FIRMWARE. Each one is seeded as an ordinary project with an ordinary
  app.json, in the ordinary projects directory, built out of the same html
  kind and the same state store a user's own app would use. So the user can
  open Notes, look at its source, and ask the agent to add a word count --
  and it is not a special case when they do. Nothing on this desktop is
  closed software.

  Seeding is idempotent and additive: an existing project of the same name is
  left completely alone, so a user who has remade Notes never has it
  overwritten by an upgrade.
*)
unit PasClaw.Suite;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  TSuiteApp = record
    Name:        string;   { project slug }
    Title:       string;
    Description: string;
    Icon:        string;
  end;
  TSuiteApps = array of TSuiteApp;

{ The suite's catalogue. }
function SuiteApps: TSuiteApps;

{ Seed any suite app that isn't already present in the active workspace.
  Returns how many were created. Existing projects are never touched. }
function SeedSuite(out Err: string): Integer;

{ Seed one by name ('notes'). Returns False when the name isn't in the
  catalogue or the project already exists. }
function SeedSuiteApp(const Name: string; out Err: string): Boolean;

implementation

uses
  PasClaw.Utils,
  PasClaw.JSON,
  PasClaw.Projects.Store,
  PasClaw.Apps;

{ ---------------------------------------------------------------- sources -- }

(* Every app below is a single self-contained html document that persists
   through the desktop SDK (pasclaw.js -> the gateway's per-app state store).
   They are deliberately small and plainly written: the user is meant to read
   them. Shared chrome is inlined rather than factored out for the same
   reason -- one file you can understand beats two you have to cross-check. *)

const
  CommonCSS =
    '<style>' +
    'body{font:13px/1.5 "MS Sans Serif",Tahoma,Geneva,Verdana,sans-serif;' +
    'margin:0;padding:10px;background:#fff;color:#111}' +
    'h1{font-size:15px;margin:0 0 8px}' +
    '.row{display:flex;gap:6px;margin-bottom:8px}' +
    'input,textarea,select{font:inherit;padding:3px 4px;border:1px solid #7f7f7f;' +
    'border-top-color:#404040;border-left-color:#404040;background:#fff}' +
    'input[type=text],textarea{flex:1 1 auto}' +
    'button{font:inherit;padding:3px 10px;background:#c0c0c0;border:1px solid #000;' +
    'border-top-color:#fff;border-left-color:#fff;cursor:default}' +
    'button:active{border-color:#404040 #fff #fff #404040}' +
    'ul{list-style:none;margin:0;padding:0}' +
    'li{display:flex;gap:6px;align-items:flex-start;padding:3px 2px;' +
    'border-bottom:1px solid #e0e0e0}' +
    'li .txt{flex:1 1 auto;word-break:break-word}' +
    'li.done .txt{text-decoration:line-through;color:#808080}' +
    '.muted{color:#808080}' +
    '.x{cursor:default;color:#808080;padding:0 4px}' +
    'textarea{width:100%;min-height:120px;resize:vertical}' +
    '</style>';

  { Notes -- markdown files would be nicer, but the state store keeps this
    honest about what an html app can do unaided. }
  NotesHTML =
    '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
    '<title>Notes</title>' + CommonCSS + '</head><body>' +
    '<h1>Notes</h1>' +
    '<div class="row"><input type="text" id="t" placeholder="Note title">' +
    '<button id="add">New</button></div>' +
    '<div class="row"><select id="sel" style="flex:1 1 auto"></select>' +
    '<button id="del">Delete</button></div>' +
    '<textarea id="body" placeholder="Write here. Saves as you type."></textarea>' +
    '<div class="muted" id="status">&nbsp;</div>' +
    '<script src="pasclaw.js"></' + 'script>' +
    '<script>' +
    'let notes=[],cur=-1,timer=null;' +
    'const $=s=>document.querySelector(s);' +
    'function paint(){const sel=$("#sel");sel.innerHTML="";' +
    'notes.forEach((n,i)=>{const o=document.createElement("option");' +
    'o.value=i;o.textContent=n.title||"(untitled)";sel.appendChild(o);});' +
    'if(cur>=0&&cur<notes.length){sel.value=cur;$("#body").value=notes[cur].body||"";}' +
    'else $("#body").value="";}' +
    'async function save(){await pasclaw.setJSON("notes",notes);' +
    '$("#status").textContent="Saved "+new Date().toLocaleTimeString();}' +
    '$("#add").onclick=async()=>{const t=$("#t").value.trim()||"Untitled";' +
    'notes.push({title:t,body:""});cur=notes.length-1;$("#t").value="";paint();await save();};' +
    '$("#del").onclick=async()=>{if(cur<0)return;notes.splice(cur,1);' +
    'cur=Math.min(cur,notes.length-1);paint();await save();};' +
    '$("#sel").onchange=()=>{cur=parseInt($("#sel").value,10);paint();};' +
    '$("#body").oninput=()=>{if(cur<0)return;notes[cur].body=$("#body").value;' +
    'clearTimeout(timer);timer=setTimeout(save,600);};' +
    '(async()=>{notes=await pasclaw.getJSON("notes",[]);' +
    'if(notes.length)cur=0;paint();})();' +
    '</' + 'script></body></html>';

  { Todo -- the user's own list, separate from the agent's task board. }
  TodoHTML =
    '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
    '<title>To Do</title>' + CommonCSS + '</head><body>' +
    '<h1>To Do</h1>' +
    '<div class="row"><input type="text" id="t" placeholder="What needs doing?">' +
    '<button id="add">Add</button></div>' +
    '<ul id="list"></ul>' +
    '<div class="muted" id="count">&nbsp;</div>' +
    '<script src="pasclaw.js"></' + 'script>' +
    '<script>' +
    'let items=[];' +
    'const $=s=>document.querySelector(s);' +
    'async function save(){await pasclaw.setJSON("items",items);}' +
    'function paint(){const ul=$("#list");ul.innerHTML="";' +
    'items.forEach((it,i)=>{const li=document.createElement("li");' +
    'if(it.done)li.className="done";' +
    'const cb=document.createElement("input");cb.type="checkbox";cb.checked=!!it.done;' +
    'cb.onchange=async()=>{it.done=cb.checked;paint();await save();};' +
    'const sp=document.createElement("span");sp.className="txt";sp.textContent=it.text;' +
    'const x=document.createElement("span");x.className="x";x.textContent=String.fromCharCode(0x2715);' +
    'x.onclick=async()=>{items.splice(i,1);paint();await save();};' +
    'li.appendChild(cb);li.appendChild(sp);li.appendChild(x);ul.appendChild(li);});' +
    'const open=items.filter(i=>!i.done).length;' +
    '$("#count").textContent=items.length?open+" open of "+items.length:"Nothing yet.";}' +
    '$("#add").onclick=async()=>{const v=$("#t").value.trim();if(!v)return;' +
    'items.push({text:v,done:false});$("#t").value="";paint();await save();};' +
    '$("#t").addEventListener("keydown",e=>{if(e.key==="Enter")$("#add").click();});' +
    '(async()=>{items=await pasclaw.getJSON("items",[]);paint();})();' +
    '</' + 'script></body></html>';

  { Brain -- what the agent knows about you, as cards you can tear up. Reads
    the same memory the agent reads, through the gateway. }
  BrainHTML =
    '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
    '<title>Brain</title>' + CommonCSS + '</head><body>' +
    '<h1>Brain</h1>' +
    '<div class="muted">What PasClaw remembers. Notes you add here are ' +
    'written to workspace memory, so the agent can recall them.</div>' +
    '<div class="row" style="margin-top:8px">' +
    '<input type="text" id="t" placeholder="Something to remember">' +
    '<button id="add">Remember</button></div>' +
    '<ul id="list"></ul>' +
    '<script src="pasclaw.js"></' + 'script>' +
    '<script>' +
    'let facts=[];' +
    'const $=s=>document.querySelector(s);' +
    'async function save(){await pasclaw.setJSON("facts",facts);}' +
    'function paint(){const ul=$("#list");ul.innerHTML="";' +
    'if(!facts.length){const li=document.createElement("li");' +
    'li.className="muted";li.textContent="Nothing yet.";ul.appendChild(li);return;}' +
    'facts.forEach((f,i)=>{const li=document.createElement("li");' +
    'const sp=document.createElement("span");sp.className="txt";' +
    'sp.textContent=f.text+"  ";' +
    'const w=document.createElement("span");w.className="muted";w.textContent=f.when||"";' +
    'sp.appendChild(w);' +
    'const x=document.createElement("span");x.className="x";x.textContent=String.fromCharCode(0x2715);' +
    'x.title="Forget this";' +
    'x.onclick=async()=>{facts.splice(i,1);paint();await save();};' +
    'li.appendChild(sp);li.appendChild(x);ul.appendChild(li);});}' +
    '$("#add").onclick=async()=>{const v=$("#t").value.trim();if(!v)return;' +
    'facts.push({text:v,when:new Date().toISOString().slice(0,10)});' +
    '$("#t").value="";paint();await save();};' +
    '$("#t").addEventListener("keydown",e=>{if(e.key==="Enter")$("#add").click();});' +
    '(async()=>{facts=await pasclaw.getJSON("facts",[]);paint();})();' +
    '</' + 'script></body></html>';

function SuiteApps: TSuiteApps;
begin
  SetLength(Result, 3);

  Result[0].Name        := 'notes';
  Result[0].Title       := 'Notes';
  Result[0].Description := 'A notepad. Part of the system suite -- open its ' +
                           'project and ask PasClaw to change it.';
  Result[0].Icon        := 'page';

  Result[1].Name        := 'todo';
  Result[1].Title       := 'To Do';
  Result[1].Description := 'Your own list, separate from the agent''s task ' +
                           'board. Part of the system suite.';
  Result[1].Icon        := 'page';

  Result[2].Name        := 'brain';
  Result[2].Title       := 'Brain';
  Result[2].Description := 'What PasClaw remembers about you, as cards you ' +
                           'can tear up. Part of the system suite.';
  Result[2].Icon        := 'brain';
end;

function BodyFor(const Name: string): string;
begin
  if      Name = 'notes' then Result := NotesHTML
  else if Name = 'todo'  then Result := TodoHTML
  else if Name = 'brain' then Result := BrainHTML
  else Result := '';
end;

function SeedOne(const App: TSuiteApp; out Err: string): Boolean;
var
  Slug, AppDir, Body: string;
  Obj, Win: TJsonObject;
begin
  Err := '';
  Result := False;
  Body := BodyFor(App.Name);
  if Body = '' then
  begin
    Err := 'no such suite app: ' + App.Name;
    Exit;
  end;
  { Never overwrite: a user who has remade Notes keeps their version. }
  if ProjectExists(App.Name) then Exit;

  Slug := CreateProject(App.Title, App.Name, App.Description, Err);
  if Slug = '' then Exit;

  { Mark it as suite-seeded so the desktop can group it -- it changes nothing
    about how the project behaves. }
  UpdateProject(Slug, '', App.Description, App.Icon, Err);
  Err := '';

  AppDir := ProjectAppDir(Slug);
  EnsureDir(AppDir);
  WriteFileText(JoinPath(AppDir, 'index.html'), Body);

  Obj := TJsonObject.Create;
  try
    Obj.PutStr('name', App.Title);
    Obj.PutStr('kind', 'html');
    Obj.PutStr('entry', 'index.html');
    Win := TJsonObject.Create;
    Win.PutInt('width', 420);
    Win.PutInt('height', 400);
    Win.PutStr('icon', App.Icon);
    Obj.PutObject('window', Win);
    WriteFileText(JoinPath(AppDir, 'app.json'), Obj.ToJSON);
  finally
    Obj.Free;
  end;

  { The suite flag lives in project.json next to everything else. }
  Obj := nil;
  try
    Obj := TJsonObject.Parse(
      ReadFileText(JoinPath(ProjectDir(Slug), 'project.json')));
    Obj.PutBool('suite', True);
    WriteFileText(JoinPath(ProjectDir(Slug), 'project.json'), Obj.ToJSON);
  except
    { a missing or odd manifest is not worth failing the seed over }
  end;
  Obj.Free;

  Result := True;
end;

function SeedSuiteApp(const Name: string; out Err: string): Boolean;
var
  Apps: TSuiteApps;
  I: Integer;
begin
  Err := '';
  Apps := SuiteApps;
  for I := 0 to High(Apps) do
    if SameText(Apps[I].Name, Name) then
      Exit(SeedOne(Apps[I], Err));
  Err := 'no such suite app: ' + Name;
  Result := False;
end;

function SeedSuite(out Err: string): Integer;
var
  Apps: TSuiteApps;
  I: Integer;
  One: string;
begin
  Err := '';
  Result := 0;
  Apps := SuiteApps;
  for I := 0 to High(Apps) do
    if SeedOne(Apps[I], One) then
      Inc(Result)
    else if One <> '' then
      Err := One;
end;

end.
