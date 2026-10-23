#!/usr/bin/env bash
# AX158 R6: upgrade the shim under load; zero failed connections allowed.
# MODE=reload (default): start OLD, start NEW with the reuseport handover, signal OLD to drain.
# MODE=restart: baseline - kill OLD, start NEW (measures the refusal gap; failures expected).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=${SHIM_BIN:-$HERE/../bin/axshim}
PORT=${PORT:-29999}   # below ip_local_port_range (32768+)
MODE=${MODE:-reload}
STORE=$(mktemp -d)
cleanup() {
  local p
  for p in $(jobs -p); do kill "$p" 2>/dev/null || true; done
  for p in $(jobs -p); do wait "$p" 2>/dev/null || true; done   # reap: fronts have released the port on return
  rm -rf "$STORE"
}
trap cleanup EXIT
[ -x "$BIN" ] && [ -e "$HERE/../build/axshim-bin" ] || { echo "no built shim ($BIN, build/axshim-bin): run shim/build-shim.sh"; exit 2; }

"$BIN" "$STORE" "$PORT" & OLD=$!
for _ in $(seq 100); do python3 -c "import socket;socket.create_connection(('127.0.0.1',$PORT),1)" 2>/dev/null && break; sleep 0.1; done

python3 - "$PORT" <<'PY' &
import socket, sys, time
port=int(sys.argv[1]); ok=bad=0; end=time.time()+6
while time.time()<end:
    try:
        s=socket.create_connection(("127.0.0.1",port),1); s.close(); ok+=1
    except OSError: bad+=1
    time.sleep(0.001)
open(sys.argv[0]+".res" if False else "/tmp/shim-upg.res","w").write(f"{ok} {bad}\n")
PY
LOAD=$!
sleep 2
if [ "$MODE" = restart ]; then
  kill "$OLD"; wait "$OLD" 2>/dev/null || true
  "$BIN" "$STORE" "$PORT" &
else
  "$BIN" "$STORE" "$PORT" & NEW=$!
  sleep 1; kill -USR1 "$OLD"      # old: stop accepting, drain, exit
  wait "$OLD" 2>/dev/null || true
fi
wait "$LOAD"
read -r OK BAD < /tmp/shim-upg.res
echo "mode=$MODE ok=$OK dropped=$BAD"
[ "$MODE" = restart ] || [ "$BAD" -eq 0 ]
