#!/usr/bin/env python3
"""bench/teamboard/replay.py -- a team run, replayed through the real gateway.

The answers in duo-wordcount.json are a recorded live run (LIVE.md, run 2):
the `duo` team building wordcount.py with the model played by hand through
the relay provider. This replays them against the binary you built, each
answer sent the instant its job arrives, so the operator's think time is
gone and what is left is the harness's: how long handoffs wait, how many
provider calls and request bytes the same decisions cost.

It stops the moment a job does not look like the one it replaces (a
different message count): the harness changed what an agent saw, and the
recording no longer applies -- re-record it (LIVE.md says how) rather than
trusting the numbers.

    make bench-teamboard            # build/pasclaw, port 8300
    python3 bench/teamboard/replay.py --bin build/pasclaw --port 8300

Needs python3 and a free port; spawns `pasclaw serve`, so it is not part of
`make test`. Exit 0 = the board finished and its tests pass.
"""
import argparse, json, os, shutil, subprocess, sys, tempfile, threading, time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))


def who(job):
    sp = (job.get('options') or {}).get('system_prompt') or ''
    return sp.split('"')[1] if '"' in sp[:40] else '?'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bin', default=os.path.join(HERE, '..', '..', 'build', 'pasclaw'))
    ap.add_argument('--port', type=int, default=8300)
    ap.add_argument('--answers', default=os.path.join(HERE, 'duo-wordcount.json'))
    ap.add_argument('--keep', action='store_true', help='leave the run directory')
    a = ap.parse_args()
    rec = json.load(open(a.answers))
    queues = {}
    for r in rec['answers']:
        queues.setdefault(r['agent'], []).append(r)
    total = len(rec['answers'])
    base = 'http://127.0.0.1:%d' % a.port

    run = tempfile.mkdtemp(prefix='teamboard-replay-')
    home = os.path.join(run, 'home')
    os.makedirs(home)
    json.dump({'default_provider': 'relay', 'default_model': 'sim',
               'providers': [{'name': 'relay', 'kind': 'relay', 'model': 'sim'}],
               'gateway': {'bind_addr': '127.0.0.1', 'port': a.port},
               'relay_wait_timeout_ms': 600000,
               'desktop_tools_enabled': True, 'agent_tools_enabled': True,
               'auto_router': {'enabled': False}},
              open(os.path.join(home, 'config.json'), 'w'))
    env = {k: v for k, v in os.environ.items()
           if k not in ('PASCLAW_HOME', 'PASCLAW_CONFIG', 'NO_COLOR')}
    env.update(PASCLAW_HOME=home, NO_COLOR='1')
    binary = os.path.abspath(a.bin)
    log = open(os.path.join(run, 'gateway.log'), 'w')
    gw = subprocess.Popen([binary, 'serve', '--max-iter', '60'], cwd=run, env=env,
                          stdout=log, stderr=subprocess.STDOUT)
    jobs, lock, failed = [], threading.Lock(), []

    def poll():
        # One stream for the whole run: it is the worker's registration, and
        # closing it requeues whatever is in flight.
        while gw.poll() is None:
            try:
                req = urllib.request.Request(base + '/v1/relay/poll',
                                             headers={'X-Relay-Worker-Id': 'replay'})
                for raw in urllib.request.urlopen(req):
                    line = raw.decode('utf-8', 'replace').rstrip('\r\n')
                    if line.startswith('data: '):
                        job = json.loads(line[6:])
                        with lock:
                            jobs.append((time.time(), job))
            except Exception:
                time.sleep(0.2)

    try:
        for _ in range(100):
            try:
                urllib.request.urlopen(base + '/v1/relay/status', timeout=1).read()
                break
            except Exception:
                time.sleep(0.1)
        threading.Thread(target=poll, daemon=True).start()
        time.sleep(0.5)
        up = subprocess.run([binary, 'team', 'up', rec['team'], '--goal', rec['goal']],
                            cwd=run, env=env, capture_output=True, text=True)
        if up.returncode != 0:
            print(up.stdout + up.stderr)
            return 2
        # The recording was made at a 3-minute cadence; only cadence-driven
        # wakes depend on it, and with the board's notices there are none.
        state = os.path.join(home, 'workspace', 'teams', 'state', rec['team'] + '.json')
        st = json.load(open(state))
        st['wake_minutes'] = 3
        json.dump(st, open(state, 'w'))

        t0, done, calls, nbytes, waits, last_answer = None, 0, 0, 0, [], None
        deadline = time.time() + 600
        while done < total and time.time() < deadline:
            with lock:
                pending = list(jobs)
                del jobs[:]
            if not pending:
                time.sleep(0.02)
                continue
            for arrived, job in pending:
                agent = who(job)
                if not queues.get(agent):
                    print('no recorded answer left for %s' % agent)
                    return 1
                r = queues[agent].pop(0)
                if len(job['messages']) != r['messages']:
                    print('DIVERGED: %s call with %d messages, recorded %d -- re-record'
                          % (agent, len(job['messages']), r['messages']))
                    return 1
                if t0 is None:
                    t0 = arrived
                if job['messages'][-1].get('role') == 'user' and last_answer is not None:
                    waits.append(arrived - last_answer)   # a wake: answer -> next job
                calls += 1
                nbytes += len(json.dumps(job))
                body = json.dumps(r['answer']).encode()
                urllib.request.urlopen(urllib.request.Request(
                    base + '/v1/relay/respond/' + job['id'], data=body,
                    headers={'Content-Type': 'application/json'}, method='POST'),
                    timeout=30).read()
                last_answer = time.time()
                done += 1
        if done < total:
            print('timed out after %d of %d answers' % (done, total))
            return 1
        wall = last_answer - t0
        app = os.path.join(home, 'workspace', 'projects', 'wordcount-py', 'app')
        tests = subprocess.run([sys.executable, '-m', 'unittest'], cwd=app,
                               capture_output=True, text=True)
        ok = tests.returncode == 0
        print('replayed %d answers: kickoff -> last answer %.1fs' % (total, wall))
        print('handoff waits: %s s' % ', '.join('%.1f' % w for w in waits))
        print('provider calls %d, request bytes %d, board tests %s'
              % (calls, nbytes, 'pass' if ok else 'FAIL'))
        print(json.dumps({'wall_s': round(wall, 2), 'calls': calls, 'request_bytes': nbytes,
                          'handoff_wait_s': [round(w, 2) for w in waits],
                          'board_tests_pass': ok}))
        return 0 if ok else 1
    finally:
        gw.terminate()
        try:
            gw.wait(5)
        except Exception:
            gw.kill()
        if a.keep:
            print('run directory:', run)
        else:
            shutil.rmtree(run, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
