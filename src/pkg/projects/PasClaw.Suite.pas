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

  (* Notes -- markdown files under <workspace>/memory/notes.

     Deliberately NOT the state store. A note kept in app state is invisible
     to the agent; a note kept as markdown in the memory directory is
     indexed by memory_search the moment it is saved. So writing a note here
     is the cheapest way to tell PasClaw something durable, and that is the
     app's entire reason to exist. *)
  NotesHTML =
    '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
    '<title>Notes</title>' + CommonCSS + '</head><body>' +
    '<h1>Notes</h1>' +
    '<div class="muted">Saved as markdown in workspace memory -- ' +
    'PasClaw can read these.</div>' +
    '<div class="row" style="margin-top:8px">' +
    '<input type="text" id="t" placeholder="Note title">' +
    '<button id="add">New</button></div>' +
    '<div class="row"><select id="sel" style="flex:1 1 auto"></select>' +
    '<button id="del">Delete</button></div>' +
    '<textarea id="body" placeholder="Write here. Saves as you type."></textarea>' +
    '<div class="muted" id="status">&nbsp;</div>' +
    '<script src="pasclaw.js"></' + 'script>' +
    '<script>' +
    'let notes=[],cur=-1,timer=null;' +
    'const $=s=>document.querySelector(s);' +
    'async function load(sel){try{notes=await pasclaw.read("notes");}' +
    'catch(e){notes=[];}' +
    'cur=notes.length?Math.max(0,notes.findIndex(n=>n.name===sel)):-1;' +
    'if(cur<0&&notes.length)cur=0;paint();}' +
    'function paint(){const sel=$("#sel");sel.innerHTML="";' +
    'notes.forEach((n,i)=>{const o=document.createElement("option");' +
    'o.value=i;o.textContent=n.title||n.name;sel.appendChild(o);});' +
    'if(cur>=0&&cur<notes.length){sel.value=cur;$("#body").value=notes[cur].body||"";}' +
    'else $("#body").value="";}' +
    { The slug comes back from the server -- an app names a note, never a
      file -- so a new note has to adopt the name it was given. }
    'async function save(){if(cur<0)return;const n=notes[cur];' +
    'try{const r=await pasclaw.action("note-save",' +
    '{name:n.name||"",title:n.title||"",body:$("#body").value});' +
    'n.name=r.name;$("#status").textContent="Saved "+new Date().toLocaleTimeString();}' +
    'catch(e){$("#status").textContent="Could not save: "+e.message;}}' +
    '$("#add").onclick=async()=>{const t=$("#t").value.trim()||"Untitled";' +
    '$("#t").value="";' +
    'try{const r=await pasclaw.action("note-save",{title:t,body:""});' +
    'await load(r.name);}catch(e){$("#status").textContent=e.message;}};' +
    '$("#del").onclick=async()=>{if(cur<0)return;' +
    'try{await pasclaw.action("note-delete",{name:notes[cur].name});' +
    'await load(null);}catch(e){$("#status").textContent=e.message;}};' +
    '$("#sel").onchange=()=>{cur=parseInt($("#sel").value,10);paint();};' +
    '$("#body").oninput=()=>{if(cur<0)return;' +
    'clearTimeout(timer);timer=setTimeout(save,700);};' +
    'load(null);' +
    '</' + 'script></body></html>';

  (* To Do -- the user's list and the agent's board, unified.

     A task added here is an ordinary task in the todo project: it appears
     in the desktop tree, the agent can list it with the `task` tool, and
     closing it closes the same record. That is the point. A private list in
     app state would have been three lines shorter and would have left the
     user with two todo lists that know nothing about each other. *)
  TodoHTML =
    '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
    '<title>To Do</title>' + CommonCSS + '</head><body>' +
    '<h1>To Do</h1>' +
    '<div class="muted">The same list PasClaw sees -- ask it to work one ' +
    'and it knows which.</div>' +
    '<div class="row" style="margin-top:8px">' +
    '<input type="text" id="t" placeholder="What needs doing?">' +
    '<button id="add">Add</button></div>' +
    '<ul id="list"></ul>' +
    '<div class="muted" id="count">&nbsp;</div>' +
    '<script src="pasclaw.js"></' + 'script>' +
    '<script>' +
    'let items=[];' +
    'const $=s=>document.querySelector(s);' +
    'async function load(){try{items=await pasclaw.read("tasks");}' +
    'catch(e){items=[];$("#count").textContent="Could not read the board: "' +
    '+e.message;return;}paint();}' +
    'function paint(){const ul=$("#list");ul.innerHTML="";' +
    'items.forEach(it=>{const done=it.status==="done";' +
    'const li=document.createElement("li");if(done)li.className="done";' +
    'const cb=document.createElement("input");cb.type="checkbox";cb.checked=done;' +
    'cb.onchange=async()=>{try{await pasclaw.action("task-done",' +
    '{id:it.id,status:cb.checked?"done":"todo"});await load();}' +
    'catch(e){$("#count").textContent=e.message;}};' +
    'const sp=document.createElement("span");sp.className="txt";' +
    'sp.textContent=it.title;' +
    { The board has an "active" state the app has no checkbox for -- show
      it rather than flattening the agent's work into done/not-done. }
    'if(it.status==="active"){const w=document.createElement("span");' +
    'w.className="muted";w.textContent="  (PasClaw is on it)";' +
    'sp.appendChild(w);}' +
    'li.appendChild(cb);li.appendChild(sp);ul.appendChild(li);});' +
    'const open=items.filter(i=>i.status!=="done").length;' +
    '$("#count").textContent=items.length?open+" open of "+items.length' +
    ':"Nothing yet.";}' +
    '$("#add").onclick=async()=>{const v=$("#t").value.trim();if(!v)return;' +
    '$("#t").value="";' +
    'try{await pasclaw.action("task-add",{title:v});await load();}' +
    'catch(e){$("#count").textContent=e.message;}};' +
    '$("#t").addEventListener("keydown",e=>{if(e.key==="Enter")$("#add").click();});' +
    'load();' +
    '</' + 'script></body></html>';

  (* Brain -- the distilled facts the model is actually primed with.

     This reads the SAME fact store the agent reads, so a card on screen is
     a line in the system prompt. That equivalence is the whole app: tearing
     up a card supersedes the fact, and the next turn genuinely does not
     know it. A Brain over its own private list would be a notepad wearing
     the word "memory". *)
  BrainHTML =
    '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
    '<title>Brain</title>' + CommonCSS + '</head><body>' +
    '<h1>Brain</h1>' +
    '<div class="muted">What PasClaw remembers about you. These are the ' +
    'facts it carries into every conversation -- tear one up and it ' +
    'forgets.</div>' +
    '<div class="row" style="margin-top:8px">' +
    '<input type="text" id="t" placeholder="Something to remember">' +
    '<button id="add">Remember</button></div>' +
    '<ul id="list"></ul>' +
    '<div class="muted" id="note">&nbsp;</div>' +
    '<script src="pasclaw.js"></' + 'script>' +
    '<script>' +
    'let facts=[];' +
    'const $=s=>document.querySelector(s);' +
    'async function load(){try{facts=await pasclaw.read("memory");}' +
    'catch(e){facts=[];$("#note").textContent="Could not read memory: "' +
    '+e.message;}paint();}' +
    'function paint(){const ul=$("#list");ul.innerHTML="";' +
    'if(!facts.length){const li=document.createElement("li");' +
    'li.className="muted";' +
    'li.textContent="Nothing remembered yet. PasClaw fills this in as you ' +
    'talk to it, or you can add something above.";' +
    'ul.appendChild(li);return;}' +
    'facts.forEach(f=>{const li=document.createElement("li");' +
    'const sp=document.createElement("span");sp.className="txt";' +
    'sp.textContent=f.text+"  ";' +
    'const w=document.createElement("span");w.className="muted";' +
    'w.textContent=[f.scope,f.event_date||f.expires||""].' +
    'filter(Boolean).join(" ");' +
    'sp.appendChild(w);' +
    'const x=document.createElement("span");x.className="x";' +
    'x.textContent=String.fromCharCode(0x2715);x.title="Forget this";' +
    'x.onclick=async()=>{try{await pasclaw.action("memory-forget",{id:f.id});' +
    'await load();}catch(e){$("#note").textContent=e.message;}};' +
    'li.appendChild(sp);li.appendChild(x);ul.appendChild(li);});}' +
    '$("#add").onclick=async()=>{const v=$("#t").value.trim();if(!v)return;' +
    '$("#t").value="";' +
    'try{await pasclaw.action("memory-remember",{text:v});await load();' +
    '$("#note").textContent="";}' +
    'catch(e){$("#note").textContent=e.message;}};' +
    '$("#t").addEventListener("keydown",e=>{if(e.key==="Enter")$("#add").click();});' +
    'load();' +
    '</' + 'script></body></html>';

  { Calendar -- the agent's scheduled work, as a month you can read. Cron is
    already the mechanism; what was missing was somewhere to see it. }
  CalendarHTML =
    '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
    '<title>Calendar</title>' + CommonCSS +
    '<style>table.cal{border-collapse:collapse;width:100%;table-layout:fixed}' +
    'table.cal th{background:#c0c0c0;border:1px solid #808080;font-size:11px;padding:2px}' +
    'table.cal td{border:1px solid #c0c0c0;height:52px;vertical-align:top;' +
    'font-size:11px;padding:2px}' +
    'table.cal td.today{background:#ffffcc;border-color:#000080}' +
    'table.cal td.pad{background:#f4f4f4}' +
    '.ev{background:#000080;color:#fff;padding:0 2px;margin-top:1px;' +
    'overflow:hidden;white-space:nowrap}' +
    '</style></head><body>' +
    '<h1>Calendar</h1>' +
    '<div class="row"><button id="prev">&lt;</button>' +
    '<b id="mon" style="flex:1 1 auto;text-align:center"></b>' +
    '<button id="next">&gt;</button></div>' +
    '<table class="cal"><thead><tr>' +
    '<th>Mon</th><th>Tue</th><th>Wed</th><th>Thu</th><th>Fri</th>' +
    '<th>Sat</th><th>Sun</th></tr></thead><tbody id="grid"></tbody></table>' +
    '<h1 style="margin-top:10px">Scheduled</h1>' +
    '<ul id="jobs"></ul>' +
    '<div class="row">' +
    '<select id="sk" title="Which skill to run"></select>' +
    '<select id="wd" title="How often">' +
    '<option value="*">Every day</option>' +
    '<option value="1">Mondays</option><option value="2">Tuesdays</option>' +
    '<option value="3">Wednesdays</option><option value="4">Thursdays</option>' +
    '<option value="5">Fridays</option><option value="6">Saturdays</option>' +
    '<option value="0">Sundays</option></select>' +
    '<input type="time" id="tm" value="09:00" style="flex:0 0 auto">' +
    '<button id="sched">Schedule</button></div>' +
    '<div class="muted" id="snote">&nbsp;</div>' +
    '<div class="row" style="margin-top:8px">' +
    '<input type="text" id="t" placeholder="Note for the selected day">' +
    '<button id="add">Add</button></div>' +
    '<script src="pasclaw.js"></' + 'script>' +
    '<script>' +
    'let cur=new Date(),notes={},crons=[],sel=null;' +
    'const $=s=>document.querySelector(s);' +
    'const key=d=>d.toISOString().slice(0,10);' +
    'async function save(){await pasclaw.setJSON("notes",notes);}' +
    'function paintJobs(){const ul=$("#jobs");ul.innerHTML="";' +
    'if(!crons.length){const li=document.createElement("li");li.className="muted";' +
    'li.textContent="No scheduled agent jobs yet.";ul.appendChild(li);return;}' +
    'crons.forEach(c=>{const li=document.createElement("li");' +
    'const sp=document.createElement("span");sp.className="txt";' +
    'sp.textContent=c.spec+"   "+c.skill+(c.enabled?"":"  (disabled)");' +
    'li.appendChild(sp);ul.appendChild(li);});}' +
    'function paint(){' +
    'const y=cur.getFullYear(),m=cur.getMonth();' +
    '$("#mon").textContent=cur.toLocaleString(undefined,{month:"long",year:"numeric"});' +
    'const first=new Date(y,m,1);' +
    'const lead=(first.getDay()+6)%7;' +
    'const days=new Date(y,m+1,0).getDate();' +
    'const today=key(new Date());' +
    'const tb=$("#grid");tb.innerHTML="";' +
    'let row=document.createElement("tr");' +
    'for(let i=0;i<lead;i++){const td=document.createElement("td");' +
    'td.className="pad";row.appendChild(td);}' +
    'for(let d=1;d<=days;d++){' +
    'const date=new Date(y,m,d),k=key(date);' +
    'const td=document.createElement("td");' +
    'if(k===today)td.className="today";' +
    'const num=document.createElement("div");num.textContent=d;td.appendChild(num);' +
    '(notes[k]||[]).forEach(n=>{const e=document.createElement("div");' +
    'e.className="ev";e.textContent=n;e.title=n;td.appendChild(e);});' +
    'td.onclick=()=>{sel=k;document.querySelectorAll("td").forEach(x=>' +
    'x.style.outline="");td.style.outline="2px solid #000080";};' +
    'row.appendChild(td);' +
    'if((lead+d)%7===0){tb.appendChild(row);row=document.createElement("tr");}}' +
    'if(row.children.length)tb.appendChild(row);}' +
    '$("#prev").onclick=()=>{cur=new Date(cur.getFullYear(),cur.getMonth()-1,1);paint();};' +
    '$("#next").onclick=()=>{cur=new Date(cur.getFullYear(),cur.getMonth()+1,1);paint();};' +
    '$("#add").onclick=async()=>{const v=$("#t").value.trim();' +
    'if(!v)return;const k=sel||key(new Date());' +
    '(notes[k]=notes[k]||[]).push(v);$("#t").value="";paint();await save();};' +
    { A cron entry that names a skill nobody installed is an entry that
      silently never fires, so offer the installed set rather than a text
      box the user can get wrong. }
    'async function loadSkills(){let sk=[];' +
    'try{sk=await pasclaw.read("skills");}catch(e){}' +
    'const el=$("#sk");el.innerHTML="";' +
    'if(!sk.length){const o=document.createElement("option");' +
    'o.textContent="(no skills installed)";o.value="";el.appendChild(o);' +
    '$("#sched").disabled=true;return;}' +
    'sk.forEach(s=>{const o=document.createElement("option");' +
    'o.value=s.name;o.textContent=s.name;o.title=s.description||"";' +
    'el.appendChild(o);});}' +
    'async function loadCrons(){try{crons=await pasclaw.read("cron");}' +
    'catch(e){crons=[];}paintJobs();}' +
    { Build the 5-field spec from the two pickers. The server validates it
      again -- this is convenience, not the check. }
    '$("#sched").onclick=async()=>{const sk=$("#sk").value;if(!sk)return;' +
    'const t=($("#tm").value||"09:00").split(":");' +
    'const spec=parseInt(t[1],10)+" "+parseInt(t[0],10)+" * * "+$("#wd").value;' +
    'try{await pasclaw.action("cron-add",{spec:spec,skill:sk,args:""});' +
    '$("#snote").textContent="Scheduled "+sk+" ("+spec+")";await loadCrons();}' +
    'catch(e){$("#snote").textContent=e.message;}};' +
    '(async()=>{notes=await pasclaw.getJSON("notes",{});' +
    'await loadSkills();await loadCrons();paint();})();' +
    '</' + 'script></body></html>';

  { Library -- everything ever made, searchable: generated pages, past
    sessions, and the projects themselves. }
  LibraryHTML =
    '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
    '<title>Library</title>' + CommonCSS +
    '<style>.tabs{display:flex;gap:2px;margin-bottom:6px}' +
    '.tabs button.on{border-color:#404040 #fff #fff #404040;font-weight:bold}' +
    'li a{color:#000080}</style></head><body>' +
    '<h1>Library</h1>' +
    '<div class="tabs">' +
    '<button data-k="pages" class="on">Pages</button>' +
    '<button data-k="sessions">Sessions</button>' +
    '<button data-k="projects">Projects</button></div>' +
    '<div class="row"><input type="text" id="q" placeholder="Filter"></div>' +
    '<ul id="list"></ul>' +
    '<div class="muted" id="count">&nbsp;</div>' +
    '<script src="pasclaw.js"></' + 'script>' +
    '<script>' +
    'let kind="pages",items=[];' +
    'const $=s=>document.querySelector(s);' +
    'function label(it){' +
    'if(kind==="pages")return[it.title,(it.source_count||0)+" source(s)",it.created||""];' +
    'if(kind==="sessions")return[it.title||it.id,it.model||"",it.id];' +
    'return[it.title||it.name,(it.tasks||0)+" task(s)",it.has_app?"[app]":""];}' +
    'function paint(){const f=$("#q").value.toLowerCase();const ul=$("#list");' +
    'ul.innerHTML="";let n=0;' +
    'items.forEach(it=>{const p=label(it);' +
    'if(f&&!p.join(" ").toLowerCase().includes(f))return;n++;' +
    'const li=document.createElement("li");' +
    'const sp=document.createElement("span");sp.className="txt";' +
    'if(kind==="pages"){const a=document.createElement("a");' +
    'a.href="/pages/"+it.id+"/";a.target="_blank";a.rel="noopener";' +
    'a.textContent=p[0];sp.appendChild(a);' +
    'sp.appendChild(document.createTextNode("  "+p[1]));}' +
    'else sp.textContent=p[0]+"   "+p[1];' +
    'const m=document.createElement("span");m.className="muted";m.textContent=p[2]||"";' +
    'li.appendChild(sp);li.appendChild(m);ul.appendChild(li);});' +
    '$("#count").textContent=n+" of "+items.length;}' +
    'async function load(){try{items=await pasclaw.read(kind);}catch(e){items=[];}' +
    'paint();}' +
    'document.querySelectorAll(".tabs button").forEach(b=>{b.onclick=()=>{' +
    'document.querySelectorAll(".tabs button").forEach(x=>x.className="");' +
    'b.className="on";kind=b.dataset.k;load();};});' +
    '$("#q").oninput=paint;' +
    'load();' +
    '</' + 'script></body></html>';

  { Cookbook -- the provider catalog in plain language. The routing itself is
    real (fallback chains, the auto-router); this is the window onto it. }
  CookbookHTML =
    '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
    '<title>Cookbook</title>' + CommonCSS +
    '<style>.card{border:1px solid #808080;border-top-color:#fff;' +
    'border-left-color:#fff;padding:6px 8px;margin-bottom:6px;background:#f4f4f4}' +
    '.card h3{margin:0 0 2px;font-size:12px}.ok{color:#006000}.no{color:#a00}' +
    '</style></head><body>' +
    '<h1>Cookbook</h1>' +
    '<div class="muted">Which model answers, and what it costs you in speed ' +
    'or privacy. Change these with <b>pasclaw onboard</b>.</div>' +
    '<h1 style="margin-top:10px">Configured</h1>' +
    '<div id="list"></div>' +
    '<h1 style="margin-top:10px">Worth knowing</h1>' +
    '<div class="card"><h3>Fast and cheap</h3>' +
    '<div class="muted">Groq, Cerebras, DeepSeek, or a smaller model on the ' +
    'provider you already use. Good for routine turns.</div></div>' +
    '<div class="card"><h3>Most capable</h3>' +
    '<div class="muted">Anthropic Claude or OpenAI GPT flagships. Worth it ' +
    'when the task is genuinely hard.</div></div>' +
    '<div class="card"><h3>Private and local</h3>' +
    '<div class="muted">Ollama, LM Studio or vLLM on your own machine. ' +
    'Nothing leaves the house; you trade some capability for that.</div></div>' +
    '<script src="pasclaw.js"></' + 'script>' +
    '<script>' +
    'const $=s=>document.querySelector(s);' +
    '(async()=>{let ps=[];try{ps=await pasclaw.read("providers");}catch(e){}' +
    'const host=$("#list");' +
    'if(!ps.length){const d=document.createElement("div");d.className="muted";' +
    'd.textContent="No providers configured yet. Run pasclaw onboard.";' +
    'host.appendChild(d);return;}' +
    'ps.forEach(p=>{const d=document.createElement("div");d.className="card";' +
    'const h=document.createElement("h3");h.textContent=p.name;d.appendChild(h);' +
    'const m=document.createElement("div");m.className="muted";' +
    'm.textContent=(p.model||"(default model)")+"  -  "+(p.kind||p.name);' +
    'd.appendChild(m);' +
    'const k=document.createElement("div");' +
    'k.className=p.has_key?"ok":"no";' +
    'k.textContent=p.has_key?"key configured":"no key set";' +
    'd.appendChild(k);host.appendChild(d);});})();' +
    '</' + 'script></body></html>';

  { Mail -- an inbox the agent triages. The IMAP/SMTP channel already exists;
    this is where its output lands. Until that channel is configured it says
    so rather than pretending to be an email client. }
  MailHTML =
    '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
    '<title>Mail</title>' + CommonCSS +
    '<style>li.unread .txt{font-weight:bold}' +
    '.tag{font-size:10px;background:#000080;color:#fff;padding:0 3px;' +
    'margin-right:4px}</style></head><body>' +
    '<h1>Mail</h1>' +
    '<div class="muted" id="hint"></div>' +
    '<div class="row" style="margin-top:6px">' +
    '<input type="text" id="t" placeholder="Subject to triage">' +
    '<button id="add">Add</button>' +
    '<button id="sync" title="Fetch new mail from the configured IMAP inbox">' +
    'Sync</button></div>' +
    '<ul id="list"></ul>' +
    '<div class="muted" id="count">&nbsp;</div>' +
    '<script src="pasclaw.js"></' + 'script>' +
    '<script>' +
    'let items=[];' +
    'const $=s=>document.querySelector(s);' +
    'const TAGS=["FYI","Request","Decision","Deadline","Risk"];' +
    'async function save(){await pasclaw.setJSON("items",items);}' +
    'function paint(){const ul=$("#list");ul.innerHTML="";' +
    'if(!items.length){const li=document.createElement("li");li.className="muted";' +
    'li.textContent="Nothing here yet.";ul.appendChild(li);}' +
    'items.forEach((it,i)=>{const li=document.createElement("li");' +
    'if(!it.read)li.className="unread";' +
    'const sp=document.createElement("span");sp.className="txt";' +
    'const tg=document.createElement("span");tg.className="tag";' +
    'tg.textContent=it.tag||"FYI";sp.appendChild(tg);' +
    'sp.appendChild(document.createTextNode(it.subject));' +
    'if(it.from){const fr=document.createElement("span");fr.className="muted";' +
    'fr.textContent="  "+it.from;sp.appendChild(fr);}' +
    'sp.onclick=async()=>{it.read=!it.read;paint();await save();};' +
    'const cyc=document.createElement("span");cyc.className="x";cyc.textContent="#";' +
    'cyc.title="Change category";' +
    'cyc.onclick=async()=>{const n=(TAGS.indexOf(it.tag||"FYI")+1)%TAGS.length;' +
    'it.tag=TAGS[n];paint();await save();};' +
    'const x=document.createElement("span");x.className="x";' +
    'x.textContent=String.fromCharCode(0x2715);' +
    'x.onclick=async()=>{items.splice(i,1);paint();await save();};' +
    'li.appendChild(sp);li.appendChild(cyc);li.appendChild(x);ul.appendChild(li);});' +
    'const u=items.filter(i=>!i.read).length;' +
    '$("#count").textContent=items.length?u+" unread of "+items.length:"";}' +
    '$("#add").onclick=async()=>{const v=$("#t").value.trim();if(!v)return;' +
    'items.unshift({subject:v,tag:"FYI",read:false});$("#t").value="";' +
    'paint();await save();};' +
    '$("#t").addEventListener("keydown",e=>{if(e.key==="Enter")$("#add").click();});' +
    '$("#sync").onclick=async()=>{' +
    '$("#sync").disabled=true;$("#hint").textContent="Checking the inbox...";' +
    'try{const r=await pasclaw.action("mail-sync");' +
    'if(r&&r.error){$("#hint").textContent=r.error;}' +
    'else{items=await pasclaw.getJSON("items",[]);paint();' +
    '$("#hint").textContent=(r&&r.filed?("Filed "+r.filed+" new message(s)."):' +
    '"No new mail.");}}' +
    'catch(e){$("#hint").textContent=String(e.message||e);}' +
    '$("#sync").disabled=false;};' +
    '$("#hint").textContent="PasClaw can poll IMAP and send replies -- see the Email channel in docs/channels.md. Once it is configured, ask PasClaw in this project to file triaged mail here.";' +
    '(async()=>{items=await pasclaw.getJSON("items",[]);paint();})();' +
    '</' + 'script></body></html>';

function SuiteApps: TSuiteApps;
begin
  SetLength(Result, 7);

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

  Result[3].Name        := 'calendar';
  Result[3].Title       := 'Calendar';
  Result[3].Description := 'Your month, plus the agent''s scheduled jobs. ' +
                           'Part of the system suite.';
  Result[3].Icon        := 'page';

  Result[4].Name        := 'library';
  Result[4].Title       := 'Library';
  Result[4].Description := 'Every page, session and project, searchable. ' +
                           'Part of the system suite.';
  Result[4].Icon        := 'disk';

  Result[5].Name        := 'cookbook';
  Result[5].Title       := 'Cookbook';
  Result[5].Description := 'Which model answers, in plain language. ' +
                           'Part of the system suite.';
  Result[5].Icon        := 'gear';

  Result[6].Name        := 'mail';
  Result[6].Title       := 'Mail';
  Result[6].Description := 'An inbox the agent triages. Part of the system ' +
                           'suite.';
  Result[6].Icon        := 'Mail';
end;

function BodyFor(const Name: string): string;
begin
  if      Name = 'notes'    then Result := NotesHTML
  else if Name = 'todo'     then Result := TodoHTML
  else if Name = 'brain'    then Result := BrainHTML
  else if Name = 'calendar' then Result := CalendarHTML
  else if Name = 'library'  then Result := LibraryHTML
  else if Name = 'cookbook' then Result := CookbookHTML
  else if Name = 'mail'     then Result := MailHTML
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
