#!/usr/bin/env python3
"""pasclaw running inside FreePascalOS, in QEMU, against a fake model.

Boots FreePascalOS (https://github.com/xeons/FreePascalOS) headless with a
small system disk of its own -- the system's shell and a few commands,
its libraries, and the pasclaw built by `make fpos` -- drives the shell
over the serial port the way the system's own tests do
(scripts/test-input.py there), and checks what came back:

  - `pasclaw version` runs;
  - `pasclaw agent -m "say hi"` reaches an OpenAI-compatible server on
    this machine (10.0.2.2 from inside QEMU's user networking) over plain
    HTTP and prints its answer;
  - a turn whose model asks for tools runs them inside FreePascalOS:
    write_file, read_file, shell_exec (a child process through the
    system's /bin/sh), shell_exec of a command that outlives its
    timeout (ended, exit 124), and execute_code (a script run by sh, which
    calls back into the tools with `pasclaw __tool`), and the answer after
    them comes back;
  - the session that turn was told to keep is saved on the system's disk;
  - `pasclaw memory provision` against a stand-in for huggingface.co whose
    vocab.txt is cut off after a 200: the download fails and leaves no
    part of the file (fphttpclient over libhttp);
  - over HTTPS too, to a server whose certificate comes from a CA made
    for the run: refused without that CA (libtls checks the chain and
    the name), answered with it (SSL_CERT_FILE);
  - a command FreePascalOS cannot have (tui) says so;
  - `pasclaw acp`, typed at on the console: the reply streams (SSE,
    HTTP/1.1 chunked) and reaches the editor while the model is still
    writing -- the fake model holds the rest of its stream until the first
    piece has come out of the serial port;
  - `pasclaw gateway --addr 0.0.0.0` in the background (Indy's HTTP server
    on its FreePascalOS socket stack, src/fpos/indy), reached from this
    machine through a port QEMU forwards to it: /v1/health, the web UI at
    / (the embedded resource), /v1/config with its secrets masked, a
    request refused without the gateway token, the token taken from
    ?token= but not from ?to-ken= (exact string comparisons,
    src/fpos/PasClaw.Compare.FreePascalOS.pas), /v1/chat answered by the
    fake model, /v1/chat/completions streaming (SSE: the tool's line reaches
    this machine before the model is asked for the rest), the /v1/logs and
    /v1/desktop/events feeds, /v1/background, the web UI in headless
    Chromium sending a chat message whose turn runs `uname -s` inside the
    system (when node and Playwright are here, scripts/fpos-webui-chat.js;
    FPOS_WEBUI_SCREENSHOT=<prefix> saves the page), and `pasclaw agent
    --attach` inside the system talking to that gateway;
  - `pasclaw serve` in the background on a second forwarded port: its
    OpenAI-compatible /v1/chat/completions, and MCP's initialize and
    tools/list on /mcp.

usage: test-fpos-qemu.py <FPOS_DIR> <pasclaw-binary> <work-dir>

FPOS_DIR is a FreePascalOS checkout where `make esp` and the userland
libraries have been built (docs/freepascalos.md lists the commands);
this script builds the few programs it needs there. Prints SKIP and exits
0 when QEMU, OVMF, the disk tools or the FreePascalOS build are missing.
Exits 1 when a check fails, with the serial log kept in <work-dir>.

The system disk is made by FreePascalOS's own scripts/make-system-disk.sh
from a folder this script assembles; nothing in FPOS_DIR's build is
changed but the programs `make` adds there.
"""
import http.client
import http.server
import json
import os
import re
import shutil
import socket
import ssl
import subprocess
import sys
import threading
import time

PROGRAMS = ['sh', 'ls', 'cat', 'echo', 'pwd', 'true', 'env', 'uname', 'mkdir', 'sleep']
PROMPT = b'fpos:/$ '
FIRMWARE_CODE = ['/usr/share/edk2/x64/OVMF_CODE.4m.fd', '/usr/share/OVMF/x64/OVMF_CODE.4m.fd',
                 '/usr/share/OVMF/OVMF_CODE.fd', '/usr/share/OVMF/OVMF_CODE_4M.fd',
                 '/usr/share/ovmf/OVMF.fd']
FIRMWARE_VARS = ['/usr/share/edk2/x64/OVMF_VARS.4m.fd', '/usr/share/OVMF/x64/OVMF_VARS.4m.fd',
                 '/usr/share/OVMF/OVMF_VARS.fd', '/usr/share/OVMF/OVMF_VARS_4M.fd']


def skip(why):
    print('  skip: test-fpos-qemu: ' + why)
    sys.exit(0)


def section(text, begin, end):
    i = text.find(begin)
    if i < 0:
        return ''
    j = text.find(end, i + len(begin))
    return text[i:j if j >= 0 else len(text)]


def first_existing(paths):
    for p in paths:
        if os.path.exists(p):
            return p
    return None


class Model(http.server.BaseHTTPRequestHandler):
    """OpenAI chat completions. A prompt with TOOLS-PLEASE in it is answered
    with tool calls, one round each, then a closing answer that quotes the
    tools' results; "stream check" gets STREAMED, the rest of it held back
    until first_piece_seen; "gateway stream check" a write_file call, and
    GATEWAY_STREAMED after it only once gateway_piece_seen; anything else
    gets "hi from the fake model".
    Streams (SSE, chunked) when the request asks to."""
    protocol_version = 'HTTP/1.1'
    requests = []
    first_piece_seen = threading.Event()
    held_live = None
    gateway_piece_seen = threading.Event()
    gateway_held_live = None

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        Model.requests.append(body)
        msgs = body.get('messages') or []
        users = [m for m in msgs if m.get('role') == 'user']
        prompt = json.dumps(users[-1].get('content')) if users else ''
        tool_results = [m for m in msgs if m.get('role') == 'tool']
        if 'TOOLS-PLEASE' in prompt and len(tool_results) == 0:
            return self.answer(None, [('write_file', {'path': 'note.txt', 'content': 'written-inside-fpos\n'})])
        if 'TOOLS-PLEASE' in prompt and len(tool_results) == 1:
            return self.answer(None, [('read_file', {'path': 'note.txt'})])
        if 'TOOLS-PLEASE' in prompt and len(tool_results) == 2:
            return self.answer(None, [('shell_exec', {'command': 'uname -s'})])
        if 'TOOLS-PLEASE' in prompt and len(tool_results) == 3:
            return self.answer(None, [('shell_exec', {'command': 'sleep 60', 'timeout_sec': 2})])
        if 'TOOLS-PLEASE' in prompt and len(tool_results) == 4:
            # The script calls back into pasclaw's tools (`pasclaw __tool`,
            # a TCP connection to the parent's tool server).
            return self.answer(None, [('execute_code', {'code': (
                'echo from-execute-code\nuname -s\n'
                'pasclaw __tool write_file \'{"path": "rpc-note.txt", '
                '"content": "written-through-tool-rpc"}\'\n')})])
        if 'TOOLS-PLEASE' in prompt:
            seen = ' | '.join(str(m.get('content'))[:160].replace('\n', ' ') for m in tool_results)
            return self.answer('TOOLS-DONE: ' + seen, None)
        if 'from serve' in prompt:
            return self.answer(SERVE_REPLY, None)
        if not body.get('tools'):
            return self.answer('summary', None)
        if 'gateway stream check' in prompt and len(tool_results) == 0:
            return self.answer(None, [('write_file', {'path': 'gateway-note.txt',
                                                      'content': 'written through the gateway\n'})])
        if 'gateway stream check' in prompt:
            # The answer after the tool waits until the tool's line, which
            # the gateway streams as the call happens, has reached the
            # client on this machine: proof that it streamed.
            Model.gateway_held_live = Model.gateway_piece_seen.wait(60)
            return self.answer(GATEWAY_STREAMED, None)
        if 'stream check' in prompt:
            return self.answer(STREAMED, None, hold=True)
        if 'over https' in prompt:
            return self.answer('hi over https from the fake model', None)
        if 'attached' in prompt:
            return self.answer('hi to the attached terminal', None)
        if 'which system' in prompt and len(tool_results) == 0:
            return self.answer(None, [('shell_exec', {'command': 'uname -s'})])
        if 'which system' in prompt:
            # Said only when the command's output came back from inside
            # FreePascalOS: the browser check looks for this sentence.
            if 'FreePascalOS' in str(tool_results[-1].get('content')):
                return self.answer(BROWSER_REPLY, None)
            return self.answer('uname -s printed something else', None)
        return self.answer('hi from the fake model', None)

    def answer(self, text, calls, hold=False):
        tool_calls = None
        if calls:
            tool_calls = [{'id': 'call_%d_%d' % (len(Model.requests), i), 'type': 'function',
                           'function': {'name': n, 'arguments': json.dumps(a)}}
                          for i, (n, a) in enumerate(calls)]
        finish = 'tool_calls' if calls else 'stop'
        if Model.requests[-1].get('stream'):
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Cache-Control', 'no-cache')
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()

            def chunked(data):
                self.wfile.write(b'%x\r\n%s\r\n' % (len(data), data))
                self.wfile.flush()

            def event(delta, finish_reason=None, usage=None):
                chunk = {'id': 'c1', 'object': 'chat.completion.chunk', 'model': 'm',
                         'choices': [{'index': 0, 'delta': delta, 'finish_reason': finish_reason}]}
                if usage:
                    chunk['usage'] = usage
                chunked(b'data: ' + json.dumps(chunk).encode() + b'\n\n')
            event({'role': 'assistant'})
            if text:
                pieces = [text[i:i + 8] for i in range(0, len(text), 8)]
                event({'content': pieces[0]})
                if hold:
                    # The rest waits until the first piece is out of the
                    # serial port: proof that it streamed.
                    Model.held_live = Model.first_piece_seen.wait(120)
                for p in pieces[1:]:
                    event({'content': p})
                    time.sleep(0.01)
            if tool_calls:
                for i, c in enumerate(tool_calls):
                    event({'tool_calls': [dict(c, index=i)]})
            event({}, finish, {'prompt_tokens': 11, 'completion_tokens': 7})
            chunked(b'data: [DONE]\n\n')
            chunked(b'')
            return
        message = {'role': 'assistant', 'content': text}
        if tool_calls:
            message['tool_calls'] = tool_calls
        out = json.dumps({'id': 'c1', 'object': 'chat.completion', 'model': 'm',
                          'choices': [{'index': 0, 'finish_reason': finish, 'message': message}],
                          'usage': {'prompt_tokens': 11, 'completion_tokens': 7}}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


class Downloads(http.server.BaseHTTPRequestHandler):
    """Stands in for huggingface.co and github.com (over TLS on port 443,
    the names in the system's /etc/hosts): a vocab.txt is answered 200
    with a Content-Length its body never reaches -- the connection is cut
    after the first bytes; everything else is 404."""
    protocol_version = 'HTTP/1.1'
    cut = 0

    def do_GET(self):
        if self.path.endswith('/vocab.txt'):
            Downloads.cut += 1
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.send_header('Content-Length', '100000')
            self.end_headers()
            self.wfile.write(b'[PAD]\n[UNK]\n[CLS]\n[SEP]\n' * 4)
            self.wfile.flush()
            self.close_connection = True
            return
        self.send_response(404)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def log_message(self, *a):
        pass


STREAMED = 'Streaming works inside FreePascalOS: alpha beta gamma delta.'
GATEWAY_STREAMED = 'The gateway streams out of FreePascalOS: one two three four five.'
SERVE_REPLY = 'hi from the fake model, through pasclaw serve'
BROWSER_REPLY = 'This gateway runs inside FreePascalOS: `uname -s` printed **FreePascalOS** there.'

# `pasclaw gateway` inside FreePascalOS listens on GATEWAY_PORT; QEMU
# forwards a free port on this machine's loopback to it.
GATEWAY_PORT = 18790
# `pasclaw serve` inside, on a port of its own, forwarded the same way.
SERVE_PORT = 18791
GATEWAY_TOKEN = 'fpos-gateway-test-token-7d1e'


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Gateway:
    """The gateway inside FreePascalOS, reached from this machine through
    the forwarded port: plain http.client requests, and SSE streams read
    line by line as they arrive."""

    def __init__(self, port, pump):
        self.port = port
        self.pump = pump        # keeps the serial port drained meanwhile

    def request(self, method, path, body=None, token=GATEWAY_TOKEN, timeout=120):
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=timeout)
        headers = {}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers['Content-Type'] = 'application/json'
        try:
            conn.request(method, path, body=data, headers=headers)
            r = conn.getresponse()
            return r.status, r.getheader('Content-Type') or '', r.read()
        finally:
            conn.close()

    def wait_up(self, seconds):
        """Polls GET /v1/health until the gateway answers."""
        end = time.time() + seconds
        while time.time() < end:
            self.pump()
            try:
                status, _, body = self.request('GET', '/v1/health', token=None, timeout=5)
                if status == 200:
                    return body
            except (OSError, http.client.HTTPException):
                pass
            time.sleep(1)
        return None

    def open_stream(self, method, path, body=None, timeout=60):
        """Starts a request whose answer is an SSE stream; returns the
        connection and the response, headers read, body not yet."""
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=timeout)
        headers = {'Authorization': 'Bearer ' + GATEWAY_TOKEN, 'Accept': 'text/event-stream'}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers['Content-Type'] = 'application/json'
        conn.request(method, path, body=data, headers=headers)
        return conn, conn.getresponse()

    @staticmethod
    def events(response, limit_seconds):
        """The `data:` payloads of an SSE response, as they arrive."""
        end = time.time() + limit_seconds
        while time.time() < end:
            line = response.readline()
            if not line:
                return
            line = line.strip()
            if line.startswith(b'data:'):
                yield line[5:].strip()

    def stream_chat(self):
        """POST /v1/chat/completions with stream:true. The gateway streams
        each tool call and result as it happens, the answer at the end;
        the fake model asks for a tool, and answers after it only once the
        first piece (the tool's line) has reached this client. Returns
        (content type, the content deltas, [DONE] seen)."""
        conn, r = self.open_stream('POST', '/v1/chat/completions', {
            'model': 'm', 'stream': True,
            'messages': [{'role': 'user', 'content': 'gateway stream check'}]})
        deltas, done = [], False
        try:
            for payload in self.events(r, 120):
                if payload == b'[DONE]':
                    done = True
                    break
                try:
                    chunk = json.loads(payload)
                except ValueError:
                    continue
                for choice in chunk.get('choices') or []:
                    piece = (choice.get('delta') or {}).get('content')
                    if piece:
                        deltas.append(piece)
                        Model.gateway_piece_seen.set()
        finally:
            Model.gateway_piece_seen.set()
            conn.close()
        return r.getheader('Content-Type') or '', deltas, done

    def mcp(self, method, params, request_id):
        """A JSON-RPC request to /mcp (MCP over HTTP); the answer, from
        JSON or from the first SSE event."""
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=120)
        try:
            conn.request('POST', '/mcp', body=json.dumps({'jsonrpc': '2.0', 'id': request_id,
                                                          'method': method, 'params': params}).encode(),
                         headers={'Authorization': 'Bearer ' + GATEWAY_TOKEN,
                                  'Content-Type': 'application/json',
                                  'Accept': 'application/json, text/event-stream'})
            r = conn.getresponse()
            body = r.read()
            if b'data:' in body and not body.lstrip().startswith(b'{'):
                body = body.split(b'data:', 1)[1].split(b'\n', 1)[0]
            return r.status, json.loads(body or b'null')
        finally:
            conn.close()

    def first_event(self, path, seconds=30):
        """The content type and first `data:` event of an SSE feed that
        stays open (/v1/logs, /v1/desktop/events), then hangs up."""
        conn, r = self.open_stream('GET', path, timeout=seconds)
        try:
            for payload in self.events(r, seconds):
                return r.getheader('Content-Type') or '', payload
            return r.getheader('Content-Type') or '', None
        finally:
            conn.close()

SMOKE = r'''
PASCLAW_HOME=/tmp/pch
export PASCLAW_HOME
NO_COLOR=1
export NO_COLOR
mkdir -p /tmp/pch /tmp/ws
cat > /tmp/pch/config.json <<'EOF'
{"providers": [{"name": "fake", "kind": "openai", "api_base": "http://10.0.2.2:@PORT@/v1",
  "api_key": "sk-test", "model": "m"},
 {"name": "fakessl", "kind": "openai", "api_base": "https://fakemodel.test:@TLSPORT@/v1",
  "api_key": "sk-test", "model": "m"}],
 "default_provider": "fake", "default_model": "m",
 "sandbox": {"workspace": "/tmp/ws"}}
EOF
echo SMOKE-VERSION-BEGIN
pasclaw version
echo "SMOKE-VERSION-EXIT=$?"
echo SMOKE-HI-BEGIN
pasclaw agent -m "say hi" --quiet
echo "SMOKE-HI-EXIT=$?"
echo SMOKE-TOOLS-BEGIN
pasclaw agent -m "TOOLS-PLEASE write, read and run" --quiet --session fpos-smoke
echo "SMOKE-TOOLS-EXIT=$?"
cat /tmp/ws/note.txt
echo SMOKE-RPC-BEGIN
cat /tmp/ws/rpc-note.txt
echo SMOKE-RPC-END
ls /tmp/pch/workspace/sessions
echo "10.0.2.2 fakemodel.test" >> /etc/hosts
cat > /tmp/ca.pem <<'EOF'
@CAPEM@EOF
echo SMOKE-HTTPS-UNTRUSTED-BEGIN
pasclaw agent -m "say hi over https" --quiet --provider fakessl
echo "SMOKE-HTTPS-UNTRUSTED-EXIT=$?"
echo SMOKE-HTTPS-BEGIN
env SSL_CERT_FILE=/tmp/ca.pem pasclaw agent -m "say hi over https" --quiet --provider fakessl
echo "SMOKE-HTTPS-EXIT=$?"
echo "10.0.2.2 huggingface.co" >> /etc/hosts
echo "10.0.2.2 github.com" >> /etc/hosts
echo SMOKE-DOWNLOAD-BEGIN
env SSL_CERT_FILE=/tmp/ca.pem pasclaw memory provision
echo "SMOKE-DOWNLOAD-EXIT=$?"
echo SMOKE-DOWNLOAD-LS
ls /tmp/pch/cache/localvector/models/all-MiniLM-L6-v2
echo SMOKE-DOWNLOAD-END
echo SMOKE-UNAVAILABLE-BEGIN
pasclaw tui
echo "SMOKE-UNAVAILABLE-EXIT=$?"
echo SMOKE-END
'''


def gateway_checks(gw):
    """The checks of the gateway part, from what gateway_part() recorded."""
    def answer(name):
        got = gw.get(name)
        if isinstance(got, tuple) and len(got) == 3:
            return got
        return (None, '', b'')

    def as_json(body):
        try:
            return json.loads(body)
        except ValueError:
            return None
    webui = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                         'src', 'pkg', 'gateway', 'webui.html')
    with open(webui, 'rb') as f:
        webui_html = f.read()
    health = as_json(gw.get('health') or b'') or {}
    index, config, refused = answer('index'), answer('config'), answer('config-no-token')
    chat, background = answer('chat'), answer('background')
    query_token, near_token = answer('query-token'), answer('query-near-token')
    serve_chat = answer('serve-chat')
    serve_mcp = None
    got = gw.get('serve-mcp')
    if (isinstance(got, tuple) and len(got) == 2 and got[0][0] == 200 and got[1][0] == 200
            and 'result' in (got[0][1] or {})
            and len(((got[1][1] or {}).get('result') or {}).get('tools') or []) > 0):
        serve_mcp = got
    stream = gw.get('stream')
    if not (isinstance(stream, tuple) and len(stream) == 3):
        stream = ('', [], False)
    logs, desktop = gw.get('logs'), gw.get('desktop-events')
    browser = gw.get('browser')
    return [
        ('gateway: GET /v1/health through the forwarded port', health.get('status') == 'ok'),
        ('gateway: GET / serves the web UI (the embedded resource, byte for byte)',
         index[0] == 200 and 'text/html' in index[1] and index[2] == webui_html),
        ('gateway: GET /v1/config with the token, its secrets masked',
         config[0] == 200 and as_json(config[2]) is not None and b'sk-test' not in config[2]
         and GATEWAY_TOKEN.encode() not in config[2] and '•••'.encode() in config[2]),
        ('gateway: a request without the token is refused (401)', refused[0] == 401),
        ('gateway: parameters are looked up by exact name (?token= accepted, ?to-ken= refused)',
         query_token[0] == 200 and near_token[0] == 401),
        ('gateway: POST /v1/chat answered by the fake model on 10.0.2.2',
         chat[0] == 200 and (as_json(chat[2]) or {}).get('content') == 'hi from the fake model'),
        ('gateway: /v1/chat/completions streams (SSE): the tool, then the answer',
         'text/event-stream' in stream[0] and len(stream[1]) >= 3 and 'write_file' in stream[1][0]
         and ''.join(stream[1]).endswith(GATEWAY_STREAMED) and stream[2]),
        ('gateway: the tool\'s line reached this machine before the model answered',
         Model.gateway_held_live is True),
        ('gateway: GET /v1/logs streams the log (SSE)',
         isinstance(logs, tuple) and 'text/event-stream' in logs[0] and logs[1] is not None),
        ('gateway: GET /v1/desktop/events says hello',
         isinstance(desktop, tuple) and desktop[1] is not None and b'"hello"' in desktop[1]),
        ('gateway: GET /v1/background answers', background[0] == 200
         and as_json(background[2]) is not None),
        ('gateway: the web UI in Chromium runs a turn (uname -s inside FreePascalOS) and shows the reply',
         None if browser is None else (isinstance(browser, tuple) and browser[0] is True)),
        ('serve: GET /v1/health through its own forwarded port',
         (as_json(gw.get('serve-health') or b'') or {}).get('status') == 'ok'),
        ('serve: POST /v1/chat/completions (OpenAI API) answered through the fake model',
         serve_chat[0] == 200 and (((as_json(serve_chat[2]) or {}).get('choices') or [{}])[0]
                                   .get('message') or {}).get('content') == SERVE_REPLY),
        ('serve: /mcp answers initialize and lists its tools', serve_mcp is not None),
        ('agent --attach inside FreePascalOS: a turn through the gateway there',
         'hi to the attached terminal' in gw.get('attach', '')
         and 'ATTACH-EXIT=0' in gw.get('attach', '')),
    ]


def browser_chat(port):
    """The web UI the gateway serves, in headless Chromium (Playwright,
    scripts/fpos-webui-chat.js): a chat message sent from the page runs
    `uname -s` inside FreePascalOS, and the reply the fake model gives only
    when that printed FreePascalOS shows. True / False, or None when node
    or Playwright is not there. With FPOS_WEBUI_SCREENSHOT=<prefix> set,
    the page is also saved as <prefix>-dark.png and <prefix>-light.png."""
    if not shutil.which('node'):
        return None
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fpos-webui-chat.js')
    r = subprocess.run(['node', script, 'http://127.0.0.1:%d' % port, GATEWAY_TOKEN,
                        'which system is this gateway on?', BROWSER_REPLY.replace('`', '').replace('*', '')],
                       capture_output=True, text=True, timeout=600)
    out = (r.stdout + r.stderr).strip()
    if r.returncode == 0 and out.startswith('skip'):
        return None
    return (r.returncode == 0, out[:3000])


# `pasclaw agent --attach` inside FreePascalOS, against the gateway running
# there: Indy's client to Indy's server over the loopback interface. The
# gateway's run file (run/gateway.json) says where it listens.
ATTACH = r'''
PASCLAW_HOME=/tmp/pch
export PASCLAW_HOME
NO_COLOR=1
export NO_COLOR
echo ATTACH-BEGIN
env PASCLAW_GATEWAY_TOKEN=@TOKEN@ pasclaw agent --attach -m "say hi when attached" --quiet
echo "ATTACH-EXIT=$?"
echo ATTACH-END
'''


def make_tls_server(work):
    """A CA and a certificate for fakemodel.test it signed (openssl), and
    the model served over TLS with it. Returns (the CA's PEM, the server)."""
    tls = os.path.join(work, 'tls')
    os.makedirs(tls)

    def run(*argv):
        r = subprocess.run(['openssl'] + list(argv), cwd=tls, capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stderr)
            print('FAIL: openssl ' + ' '.join(argv))
            sys.exit(1)
    with open(os.path.join(tls, 'server.ext'), 'w') as f:
        f.write('subjectAltName=DNS:fakemodel.test,DNS:huggingface.co,DNS:github.com\n'
                'basicConstraints=CA:FALSE\n'
                'keyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n')
    run('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-subj', '/CN=PasClaw test CA',
        '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
        '-keyout', 'ca.key', '-out', 'ca.pem')
    run('req', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=fakemodel.test', '-keyout', 'server.key',
        '-out', 'server.csr')
    run('x509', '-req', '-in', 'server.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key', '-CAcreateserial',
        '-days', '2', '-extfile', 'server.ext', '-out', 'server.pem')
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(os.path.join(tls, 'server.pem'), os.path.join(tls, 'server.key'))
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Model)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    # The download hosts, where the system looks for them: port 443 (the
    # guest's 10.0.2.2:443 is this machine's loopback). None when that
    # port cannot be had here; the check is skipped then.
    try:
        downloads = http.server.ThreadingHTTPServer(('127.0.0.1', 443), Downloads)
        downloads.socket = context.wrap_socket(downloads.socket, server_side=True)
    except OSError:
        downloads = None
    with open(os.path.join(tls, 'ca.pem')) as f:
        return f.read(), server, downloads


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(2)
    fpos_dir, binary, work = sys.argv[1], os.path.abspath(sys.argv[2]), os.path.abspath(sys.argv[3])
    build = os.path.join(fpos_dir, 'build', 'amd64')
    esp = os.path.join(build, 'esp')
    for tool in ('qemu-system-x86_64', 'mke2fs', 'sfdisk', 'debugfs', 'openssl'):
        if not shutil.which(tool):
            skip('needs ' + tool)
    code, variables = first_existing(FIRMWARE_CODE), first_existing(FIRMWARE_VARS)
    if not code or not variables:
        skip('needs the OVMF firmware (apt: ovmf)')
    if not os.path.isfile(os.path.join(esp, 'EFI', 'BOOT', 'BOOTX64.EFI')):
        skip('needs the FreePascalOS loader and kernel (make esp in ' + fpos_dir + ')')
    if not os.path.isfile(binary):
        skip('needs ' + binary + ' (make fpos)')

    # The programs the shell session uses, built where FreePascalOS builds them.
    env = dict(os.environ)
    env.setdefault('FPC_SOURCE', '/usr/share/fpcsrc/3.2.2')
    targets = ['build/amd64/user/bin/' + p for p in PROGRAMS]
    r = subprocess.run(['make', '-C', fpos_dir] + targets, env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout[-2000:] + r.stderr[-2000:])
        print('FAIL: could not build the FreePascalOS programs the test uses')
        sys.exit(1)

    shutil.rmtree(work, ignore_errors=True)
    user = os.path.join(work, 'user')
    os.makedirs(os.path.join(user, 'bin'))
    os.makedirs(os.path.join(user, 'lib'))
    for p in PROGRAMS:
        shutil.copy(os.path.join(build, 'user', 'bin', p), os.path.join(user, 'bin', p))
    shutil.copy(binary, os.path.join(user, 'bin', 'pasclaw'))
    for lib in os.listdir(os.path.join(build, 'user', 'lib')):
        if lib.endswith('.so'):
            shutil.copy(os.path.join(build, 'user', 'lib', lib), os.path.join(user, 'lib', lib))

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Model)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    # The same model over TLS, with a certificate for fakemodel.test from
    # a CA made for this run (the smoke script puts the name in /etc/hosts
    # and the CA in /tmp/ca.pem).
    ca_pem, tls_server, downloads = make_tls_server(work)
    tls_port = tls_server.server_address[1]
    threading.Thread(target=tls_server.serve_forever, daemon=True).start()
    if downloads:
        threading.Thread(target=downloads.serve_forever, daemon=True).start()
    with open(os.path.join(user, 'bin', 'pasclaw-smoke'), 'w') as f:
        f.write(SMOKE.replace('@PORT@', str(port)).replace('@TLSPORT@', str(tls_port))
                .replace('@CAPEM@', ca_pem).lstrip())
    with open(os.path.join(user, 'bin', 'pasclaw-gateway-log'), 'w') as f:
        f.write('echo GW-LOG-BEGIN\ncat /tmp/gw.log\necho "---- pasclaw serve (/tmp/serve.log) ----"\n'
                'cat /tmp/serve.log\necho GW-LOG-END\n')
    with open(os.path.join(user, 'bin', 'pasclaw-attach'), 'w') as f:
        f.write(ATTACH.replace('@TOKEN@', GATEWAY_TOKEN).lstrip())

    disk = os.path.join(work, 'system.img')
    r = subprocess.run([os.path.join(fpos_dir, 'scripts', 'make-system-disk.sh'), user, disk],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout + r.stderr)
        print('FAIL: make-system-disk.sh failed')
        sys.exit(1)

    shutil.copytree(esp, os.path.join(work, 'esp'))
    # test-exit: QEMU ends when the first program does. init=/bin/sh: the
    # shell is that program, on the console (and the serial port).
    # netaddr: the kernel gives the network card QEMU's user-networking
    # address itself, as there is no network service on this disk.
    with open(os.path.join(work, 'esp', 'FreePascalOS', 'options.txt'), 'w') as f:
        f.write('test-exit init=/bin/sh netaddr=10.0.2.15/24,10.0.2.2\n')
    shutil.copy(variables, os.path.join(work, 'vars.fd'))
    serial = os.path.join(work, 'serial')
    for suffix in ('.in', '.out'):
        os.mkfifo(serial + suffix)
    accel = ['-accel', 'kvm', '-cpu', 'host'] if os.environ.get('ACCEL') == 'kvm' else ['-cpu', 'max']
    # The gateway's port inside, reached from here on host_port.
    host_port = free_port()
    serve_host_port = free_port()
    while serve_host_port == host_port:
        serve_host_port = free_port()
    qemu = subprocess.Popen(
        ['qemu-system-x86_64', '-machine', 'q35', *accel, '-m', '1G', '-smp', '2',
         '-drive', 'if=pflash,format=raw,readonly=on,file=' + code,
         '-drive', 'if=pflash,format=raw,file=' + os.path.join(work, 'vars.fd'),
         '-drive', 'format=raw,file=fat:rw:' + os.path.join(work, 'esp'),
         '-drive', 'format=raw,cache=unsafe,file=' + disk,
         '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04',
         '-netdev', 'user,id=net0,hostfwd=tcp:127.0.0.1:%d-:%d,hostfwd=tcp:127.0.0.1:%d-:%d'
         % (host_port, GATEWAY_PORT, serve_host_port, SERVE_PORT),
         '-device', 'virtio-net-pci,netdev=net0',
         '-serial', 'pipe:' + serial, '-display', 'none', '-no-reboot'],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        stderr=open(os.path.join(work, 'qemu-errors.log'), 'wb'))
    out_fd = os.open(serial + '.out', os.O_RDONLY | os.O_NONBLOCK)
    received = bytearray()
    deadline = time.time() + 60
    serial_in = None
    while time.time() < deadline and serial_in is None:
        if qemu.poll() is not None:
            break
        try:
            fd = os.open(serial + '.in', os.O_WRONLY | os.O_NONBLOCK)
            os.set_blocking(fd, True)
            serial_in = os.fdopen(fd, 'wb', buffering=0)
        except OSError:
            time.sleep(0.1)

    def collect(seconds):
        end = time.time() + seconds
        while time.time() < end:
            try:
                chunk = os.read(out_fd, 4096)
                if chunk:
                    received.extend(chunk)
                    continue
            except BlockingIOError:
                pass
            if qemu.poll() is not None:
                return
            time.sleep(0.05)

    def wait_for(text, seconds, start=0):
        end = time.time() + seconds
        while time.time() < end:
            collect(0.2)
            if text in received[start:]:
                return True
            if qemu.poll() is not None:
                return text in received[start:]
        return False

    def type_line(line):
        for byte in line.encode() + b'\r':
            serial_in.write(bytes([byte]))
            time.sleep(0.02)

    gateway = {}

    def serve_part(attempt):
        """`pasclaw serve` (the OpenAI-compatible server, MCP on /mcp) in
        the background inside FreePascalOS, with a home of its own, asked
        from this machine through the second forwarded port."""
        for line in ('mkdir -p /tmp/pcs', 'cat /tmp/pch/config.json > /tmp/pcs/config.json',
                     'env PASCLAW_HOME=/tmp/pcs NO_COLOR=1 PASCLAW_GATEWAY_TOKEN=%s '
                     'pasclaw serve --addr 0.0.0.0 --port %d > /tmp/serve.log 2>&1 &'
                     % (GATEWAY_TOKEN, SERVE_PORT)):
            start = len(received)
            type_line(line)
            wait_for(PROMPT, 30, start)
        sv = Gateway(serve_host_port, lambda: collect(0.05))
        attempt('serve-health', lambda: sv.wait_up(300))
        if gateway['serve-health'] is None:
            return
        attempt('serve-chat', lambda: sv.request('POST', '/v1/chat/completions', {
            'model': 'm', 'messages': [{'role': 'user', 'content': 'say hi from serve'}]}))
        attempt('serve-mcp', lambda: (
            sv.mcp('initialize', {'protocolVersion': '2025-03-26', 'capabilities': {},
                                  'clientInfo': {'name': 'test-fpos-qemu', 'version': '1'}}, 1),
            sv.mcp('tools/list', {}, 2)))

    def gateway_part():
        """`pasclaw gateway` in the background inside FreePascalOS (its
        output in /tmp/gw.log), asked from this machine through the
        forwarded port; then its log is shown on the console."""
        start = len(received)
        type_line('env PASCLAW_HOME=/tmp/pch NO_COLOR=1 PASCLAW_GATEWAY_TOKEN=%s '
                  'pasclaw gateway --addr 0.0.0.0 --port %d > /tmp/gw.log 2>&1 &'
                  % (GATEWAY_TOKEN, GATEWAY_PORT))
        wait_for(PROMPT, 30, start)
        gw = Gateway(host_port, lambda: collect(0.05))

        gateway['seconds'] = {}

        def attempt(name, fn):
            began = time.time()
            try:
                gateway[name] = fn()
            except Exception as e:      # recorded, and the check fails
                gateway[name] = ('error', repr(e))
            gateway['seconds'][name] = round(time.time() - began, 1)
            collect(0.05)
        attempt('health', lambda: gw.wait_up(300))
        if gateway['health'] is not None:
            attempt('index', lambda: gw.request('GET', '/', token=None))
            attempt('config', lambda: gw.request('GET', '/v1/config'))
            attempt('config-no-token', lambda: gw.request('GET', '/v1/config', token=None))
            # The token as a query parameter, then under a name that only
            # differs by punctuation: TStrings lookups (Params.Values) go
            # through AnsiCompareText, which PasClaw.Compare.FreePascalOS
            # makes exact there.
            attempt('query-token', lambda: gw.request('GET', '/v1/config?token=' + GATEWAY_TOKEN, token=None))
            attempt('query-near-token',
                    lambda: gw.request('GET', '/v1/config?to-ken=' + GATEWAY_TOKEN, token=None))
            attempt('chat', lambda: gw.request('POST', '/v1/chat', {'message': 'say hi'}))
            attempt('stream', gw.stream_chat)
            attempt('logs', lambda: gw.first_event('/v1/logs'))
            attempt('desktop-events', lambda: gw.first_event('/v1/desktop/events'))
            attempt('background', lambda: gw.request('GET', '/v1/background'))
            attempt('browser', lambda: browser_chat(host_port))
            attach_start, began = len(received), time.time()
            type_line('sh /bin/pasclaw-attach')
            wait_for(b'ATTACH-END', 300, attach_start)
            wait_for(PROMPT, 10, attach_start)
            gateway['seconds']['attach'] = round(time.time() - began, 1)
            gateway['attach'] = section(
                received[attach_start:].decode('utf-8', 'replace').replace('\r', ''),
                'ATTACH-BEGIN\n', 'ATTACH-END')
            serve_part(attempt)
        # (a script, so that the markers are not in the typing's echo)
        log_start = len(received)
        type_line('sh /bin/pasclaw-gateway-log')
        wait_for(b'GW-LOG-END', 60, log_start)
        wait_for(PROMPT, 10, log_start)
        gateway['log'] = section(received[log_start:].decode('utf-8', 'replace').replace('\r', ''),
                                 'GW-LOG-BEGIN\n', 'GW-LOG-END')

    log_path = os.path.join(work, 'serial.log')
    ok = serial_in is not None and wait_for(PROMPT, 600)
    acp = ''
    if ok:
        start = len(received)
        type_line('sh /bin/pasclaw-smoke')
        ok = wait_for(b'SMOKE-END', 900, start)
        collect(1)
    if ok:
        # pasclaw acp on the console: the requests are typed, the answers
        # come back on the serial port (with the typing's echo between).
        acp_start = len(received)
        type_line('env PASCLAW_HOME=/tmp/pch NO_COLOR=1 pasclaw acp')
        time.sleep(2)
        type_line(json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
                              'params': {'protocolVersion': 1, 'clientCapabilities': {}}}))
        wait_for(b'"protocolVersion"', 120, acp_start)
        type_line(json.dumps({'jsonrpc': '2.0', 'id': 2, 'method': 'session/new',
                              'params': {'cwd': '/tmp/ws', 'mcpServers': []}}))
        sid = None
        end = time.time() + 120
        while sid is None and time.time() < end:
            collect(0.2)
            m = re.search(rb'"result":\{"sessionId":"([^"]+)"', bytes(received[acp_start:]))
            if m is None:
                m = re.search(rb'"sessionId":"([^"]+)"', bytes(received[acp_start:]))
            if m:
                sid = m.group(1).decode()
        if sid:
            prompt_start = len(received)
            type_line(json.dumps({'jsonrpc': '2.0', 'id': 3, 'method': 'session/prompt',
                                  'params': {'sessionId': sid,
                                             'prompt': [{'type': 'text', 'text': 'stream check'}]}}))
            end = time.time() + 300
            while time.time() < end:
                collect(0.2)
                if b'agent_message_chunk' in received[prompt_start:]:
                    Model.first_piece_seen.set()
                if b'"stopReason"' in received[prompt_start:]:
                    break
        Model.first_piece_seen.set()
        acp = received[acp_start:].decode('utf-8', 'replace').replace('\r', '')
        serial_in.write(b'\x04')      # end of input: the agent exits
        if not wait_for(PROMPT, 60, len(received)):
            serial_in.write(b'\x03')
            wait_for(PROMPT, 30, len(received))
        gateway_part()
        type_line('exit')
        wait_for(b'\x00never', 30)
    if qemu.poll() is None:
        qemu.kill()
    qemu.wait()
    server.shutdown()
    tls_server.shutdown()
    if downloads:
        downloads.shutdown()
    with open(log_path, 'wb') as f:
        f.write(received)
    text = received.decode('utf-8', 'replace').replace('\r', '')
    if not ok:
        print(text[-3000:])
        print('FAIL: the shell or the smoke script did not finish (serial log: %s)' % log_path)
        sys.exit(1)

    smoke = text[text.rfind('SMOKE-VERSION-BEGIN'):]
    smoke = smoke[:smoke.find('SMOKE-END') + len('SMOKE-END')]
    tools = section(smoke, 'TOOLS-DONE', 'SMOKE-TOOLS-EXIT')
    download = section(smoke, 'SMOKE-DOWNLOAD-BEGIN', 'SMOKE-DOWNLOAD-LS')
    download_left = section(smoke, 'SMOKE-DOWNLOAD-LS', 'SMOKE-DOWNLOAD-END')
    chunks = re.findall(r'"sessionUpdate":"agent_message_chunk"', acp)
    checks = [
        ('pasclaw version', 'SMOKE-VERSION-EXIT=0' in smoke and 'PasClaw' in smoke),
        ('agent -m "say hi" over HTTP to 10.0.2.2', 'hi from the fake model' in smoke
         and 'SMOKE-HI-EXIT=0' in smoke),
        ('HTTPS without the CA is refused (certificate check)',
         'unknown authority' in section(smoke, 'SMOKE-HTTPS-UNTRUSTED-BEGIN', 'SMOKE-HTTPS-BEGIN')
         and 'hi over https' not in section(smoke, 'SMOKE-HTTPS-UNTRUSTED-BEGIN', 'SMOKE-HTTPS-BEGIN')),
        ('HTTPS with the CA (SSL_CERT_FILE) answers',
         'hi over https from the fake model' in section(smoke, 'SMOKE-HTTPS-BEGIN', 'SMOKE-HTTPS-EXIT')
         and 'SMOKE-HTTPS-EXIT=0' in smoke),
        ('write_file / read_file / shell_exec (uname -s) ran inside FreePascalOS',
         'TOOLS-DONE: wrote' in tools and 'written-inside-fpos' in tools
         and 'exit=0' in tools and 'FreePascalOS' in tools and 'SMOKE-TOOLS-EXIT=0' in smoke),
        ('shell_exec past its timeout is ended (exit=124)', 'exit=124' in tools),
        ('execute_code ran its script with sh', 'from-execute-code' in tools),
        ('execute_code\'s script called back into the tools (pasclaw __tool, TCP)',
         'written-through-tool-rpc' in section(smoke, 'SMOKE-RPC-BEGIN', 'SMOKE-RPC-END')),
        ('the session was saved', 'fpos-smoke.json' in smoke),
        ('a download cut off after its 200 fails (memory provision), no part of it left',
         None if downloads is None else
         (Downloads.cut >= 1 and 'did not arrive whole' in download
          and 'saved' not in download and 'vocab.txt' not in download_left)),
        ('tui says it is not available', 'not available on FreePascalOS' in smoke
         and 'SMOKE-UNAVAILABLE-EXIT=1' in smoke),
        ('acp: the model was asked to stream (SSE)',
         any(r.get('stream') for r in Model.requests)),
        ('acp: the reply came in pieces and the turn ended',
         len(chunks) >= 2 and '"stopReason":"end_turn"' in acp),
        ('acp: the first piece reached the console while the model was still writing',
         Model.held_live is True),
    ] + gateway_checks(gateway)
    failed = [name for name, good in checks if good is False]
    if failed or os.environ.get('FPOS_QEMU_VERBOSE'):
        print('---- inside FreePascalOS (serial console) ----')
        print(smoke)
        print('---- pasclaw acp, typed on the console ----')
        print(acp[:6000])
        print('---- pasclaw gateway, asked from this machine ----')
        for name in ('health', 'chat', 'stream', 'logs', 'desktop-events', 'browser', 'attach',
                     'serve-health', 'serve-chat', 'serve-mcp'):
            print('%s: %s' % (name, str(gateway.get(name))[:1500]))
        print('seconds: %s' % gateway.get('seconds'))
        print('---- its log (/tmp/gw.log) ----')
        print(gateway.get('log', '')[:6000])
        print('----------------------------------------------')
    for name, good in checks:
        print(('  ok    ' if good else '  skip  ' if good is None else '  FAIL  ') + name)
    if failed:
        print('FAIL: %d check(s) failed (serial log: %s)' % (len(failed), log_path))
        sys.exit(1)
    print('test-fpos-qemu: OK')


if __name__ == '__main__':
    main()
