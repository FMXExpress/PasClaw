#!/usr/bin/env python3
"""Side probe: poll /v1/relay/status every 10 ms and print timestamped
transitions of pending / inflight counts, so a turn's gap can be split into
  respond -> enqueue   (PasClaw: tool run + next prompt + enqueue)
  enqueue -> dequeue   (poll wake latency)
  dequeue -> worker    (write/flush + client read; from the worker's t_recv)
usage: probe.py <port> [seconds]
"""
import json, sys, time, urllib.request

port = sys.argv[1]
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 60
base = f"http://127.0.0.1:{port}"
tok = None
deadline = time.time() + secs
while tok is None and time.time() < deadline:
    try:
        d = json.load(urllib.request.urlopen(base + "/v1/relay/worker-token", timeout=1))
        tok = d.get("token") or d.get("worker_token") or list(d.values())[0]
    except Exception:
        time.sleep(0.1)
prev = None
while time.time() < deadline:
    try:
        req = urllib.request.Request(base + "/v1/relay/status")
        req.add_header("Authorization", "Bearer " + tok)
        s = json.load(urllib.request.urlopen(req, timeout=1))
        key = (s.get("pending_requests", s.get("pending")), s.get("inflight_requests", s.get("inflight")))
        if key != prev:
            print(f"{time.time():.3f} pending={key[0]} inflight={key[1]}", flush=True)
            prev = key
    except Exception as e:
        pass
    time.sleep(0.01)
