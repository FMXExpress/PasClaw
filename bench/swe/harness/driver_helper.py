#!/usr/bin/env python3
"""
driver_helper.py - reader / writer helpers for the blocking-stub queue.

When a subagent (or human) drives a cell live, provider_stub.py runs in
--blocking mode against a queue directory. Each turn lands in the queue
as req_N.json; the driver writes resp_N.json with the assistant's reply.

This helper hides the bookkeeping so the driver only has to think about
content, not about which sequence number is current or whether to use
atomic-rename for the publish.

Subcommands:

  next-request --queue <dir> [--wait-s S]
      Block until req_N.json exists for the next sequence number, print
      its body to stdout. Exits 2 if the timeout elapses, 3 if the queue
      dir is gone.

  send-reply --queue <dir> [--seq N]
      Read a JSON response body from stdin, write it atomically to
      resp_N.json (N = the seq of the request that hasn't been answered
      yet, or --seq if explicit).

  status --queue <dir>
      Print { "pending": [...], "answered": [...], "next_seq": N }.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time


def _scan(queue: str) -> tuple[list[int], list[int]]:
    pending: list[int] = []
    answered: list[int] = []
    if not os.path.isdir(queue):
        return pending, answered
    for name in os.listdir(queue):
        m = re.match(r"req_(\d+)\.json$", name)
        if m:
            n = int(m.group(1))
            if os.path.exists(os.path.join(queue, "resp_%d.json" % n)):
                answered.append(n)
            else:
                pending.append(n)
    pending.sort()
    answered.sort()
    return pending, answered


def cmd_status(args) -> int:
    pending, answered = _scan(args.queue)
    next_seq = (max(pending + answered) + 1) if (pending or answered) else 1
    sys.stdout.write(json.dumps({
        "pending": pending,
        "answered": answered,
        "next_seq": next_seq,
    }) + "\n")
    return 0


def cmd_next_request(args) -> int:
    deadline = time.monotonic() + args.wait_s
    while time.monotonic() < deadline:
        if not os.path.isdir(args.queue):
            sys.stderr.write("queue dir disappeared: %s\n" % args.queue)
            return 3
        pending, _ = _scan(args.queue)
        if pending:
            seq = pending[0]
            with open(os.path.join(args.queue, "req_%d.json" % seq), "rb") as fh:
                sys.stdout.buffer.write(fh.read())
            sys.stderr.write("[helper] served seq=%d\n" % seq)
            return 0
        time.sleep(0.5)
    sys.stderr.write("[helper] timeout after %ds with no pending request\n"
                     % args.wait_s)
    return 2


def cmd_send_reply(args) -> int:
    if args.seq is None:
        pending, _ = _scan(args.queue)
        if not pending:
            sys.stderr.write("[helper] no pending request to reply to\n")
            return 4
        seq = pending[0]
    else:
        seq = args.seq
    body = sys.stdin.read()
    # Validate that the body parses as JSON before publishing -- saves the
    # stub from returning a 500 on a typo'd response.
    try:
        json.loads(body)
    except json.JSONDecodeError as e:
        sys.stderr.write("[helper] response is not valid JSON: %s\n" % e)
        return 5
    final = os.path.join(args.queue, "resp_%d.json" % seq)
    tmp = final + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(body)
    os.rename(tmp, final)
    sys.stderr.write("[helper] published seq=%d (%d bytes)\n" % (seq, len(body)))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("next-request")
    p.add_argument("--queue", required=True)
    p.add_argument("--wait-s", type=int, default=300)
    p.set_defaults(func=cmd_next_request)

    p = sub.add_parser("send-reply")
    p.add_argument("--queue", required=True)
    p.add_argument("--seq", type=int, default=None,
                   help="explicit sequence number; defaults to the oldest pending")
    p.set_defaults(func=cmd_send_reply)

    p = sub.add_parser("status")
    p.add_argument("--queue", required=True)
    p.set_defaults(func=cmd_status)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
