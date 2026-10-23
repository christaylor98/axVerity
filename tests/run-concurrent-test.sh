#!/usr/bin/env bash
# REQ-14 (amended, f18532f): connections are served concurrently; an idle open connection never blocks another.
# (a) conn2 is answered while conn1 is still open; (b) 9 sockets all accepted; (c) server still serves afterwards.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AXSHIM="$ROOT/shim/bin/axshim"
[ -x "$AXSHIM" ] || { echo "FAIL: $AXSHIM not built" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
python3 - "$T" "$AXSHIM" <<'PY'
import subprocess, sys, time, socket
store, exe = sys.argv[1], sys.argv[2]
# Bounded retry (3 attempts): the probed port can be taken before the server binds it.
# Startup is retried up to 3 times, each on a fresh port; if all attempts fail the
# script exits non-zero with "FAIL: server never became ready after 3 attempts".
for attempt in range(1, 4):
    t = socket.socket(); t.bind(("127.0.0.1", 0)); port = t.getsockname()[1]; t.close()
    p = subprocess.Popen([exe, store, str(port)], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    ready = False
    for _ in range(100):
        if p.poll() is not None: break
        try: socket.create_connection(("127.0.0.1", port), 1).close(); ready = True; break
        except OSError: time.sleep(0.1)
    if ready:
        time.sleep(0.05)  # a foreign listener may have answered; our server would have exited by now
        ready = p.poll() is None
    if ready: break
    print(f"startup failed: port {port} attempt {attempt}/3", file=sys.stderr)
    if p.poll() is None: p.kill()
    p.wait()
else:
    print(f"FAIL: server never became ready after 3 attempts (last port {port})", file=sys.stderr); sys.exit(1)
fails = 0
def chk(ok, msg):
    global fails
    print(("ok   " if ok else "FAIL ") + msg); fails += not ok
try:
    c1 = socket.create_connection(("127.0.0.1", port), 3)
    c2 = socket.create_connection(("127.0.0.1", port), 3)
    c2.sendall(bytes([2, 1, 0x30]))  # QUERY mask '0'
    c2.settimeout(5.0); t0 = time.time()
    try: got = c2.recv(64)
    except socket.timeout: got = b""
    # REQ-14: conn2 is accepted and queued; no reply while conn1 is open, answered once conn1 closes.
    chk(got == b"", f"conn2 NOT answered while conn1 open (queued): {got!r}")
    c1.close()
    c2.settimeout(5.0)
    try: got2 = c2.recv(64)
    except socket.timeout: got2 = b""
    chk(len(got2) > 0, f"conn2 answered after conn1 closed: {got2!r}")
    c2.close()
    socks = []
    try:
        for _ in range(9): socks.append(socket.create_connection(("127.0.0.1", port), 3))
        chk(len(socks) == 9, "9 sockets accepted")
    except OSError as e:
        chk(False, f"9 sockets: {e}")
    for s in socks: s.close()
    time.sleep(0.3)
    c = socket.create_connection(("127.0.0.1", port), 3); c.settimeout(5)
    c.sendall(bytes([2, 1, 0x30]))
    try: got = c.recv(64)
    except socket.timeout: got = b""
    chk(len(got) > 0, f"server still serves after 9 closed: {got!r}")
finally:
    p.kill()
sys.exit(1 if fails else 0)
PY
