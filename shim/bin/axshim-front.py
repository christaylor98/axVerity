#!/usr/bin/env python3
"""axshim-front -- STOPGAP reload front for the axshim launcher (AX158).

The shim binary (build/axshim-bin) binds with plain tcp_listen, so two shims
cannot share a port; SO_REUSEPORT needs the bridge primitive tcp_listen_reuseport
(not yet in the bridge; adding it is the preferred follow-up). Until it is,
this front gives the same reload semantics from outside:

  * each launch starts its own shim backend on an ephemeral loopback port
    (port 0; the backend prints the bound port) and only then binds the PUBLIC
    port with SO_REUSEPORT, forwarding bytes to its backend;
  * SIGUSR1: close the public listener (new connections go to the other front),
    drain in-flight connections, stop the backend, exit 0;
  * SIGTERM/SIGINT: stop at once.

Failure rule: if the backend does not come up or the public bind fails, this
process exits non-zero and an already-running front keeps listening untouched.

Documented loss window: connections already sitting in the closing listener's
kernel accept queue (accepted by the kernel but not yet by this process) are
reset when the listener closes. The accept loop drains that queue continuously,
so the window is the accept latency (sub-millisecond when idle).

usage: axshim-front.py <store-root> <public-port> <writer> <axshim-bin>
"""
import os, signal, socket, subprocess, sys, threading

root, port, writer, binp = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]

backend = subprocess.Popen([binp, root, "0", writer], cwd=root,
                           stdout=subprocess.PIPE, text=True, bufsize=1)
line = backend.stdout.readline()
try:
    bport = int(line.split("port=")[1].split()[0])
    if bport == 0:
        raise ValueError("backend reported port 0")
except Exception:
    sys.stderr.write("axshim-front: backend did not report a port: %r\n" % line)
    backend.kill()
    sys.exit(3)
threading.Thread(target=lambda: [sys.stdout.write(l) or sys.stdout.flush()
                                 for l in backend.stdout], daemon=True).start()

lis = socket.socket()
lis.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
lis.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
try:
    lis.bind(("0.0.0.0", port))
    lis.listen(1024)
except OSError as e:
    sys.stderr.write("axshim-front: public bind %d failed: %s\n" % (port, e))
    backend.kill()
    sys.exit(4)

port = lis.getsockname()[1]  # public port 0 = ephemeral: announce the real bound port
sys.stdout.write(line.replace("port=%d" % bport, "port=%d" % port))
sys.stdout.flush()

draining = threading.Event()
inflight = 0
cv = threading.Condition()
one_at_a_time = threading.Lock()


def pump(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except OSError:
        pass
    try:
        b.shutdown(socket.SHUT_WR)
    except OSError:
        pass


def serve(c):
    global inflight
    try:
        with one_at_a_time:   # REQ-14: one connection runs to completion; others queue
            u = socket.create_connection(("127.0.0.1", bport))
            t = threading.Thread(target=pump, args=(u, c))
            t.start()
            pump(c, u)
            t.join()
            u.close()
    except OSError:
        pass
    finally:
        c.close()
        with cv:
            inflight -= 1
            cv.notify_all()


def on_usr1(*_):
    draining.set()
    try:
        lis.shutdown(socket.SHUT_RDWR)   # wakes accept()
    except OSError:
        pass


def on_term(*_):
    backend.kill()
    os._exit(0)


signal.signal(signal.SIGUSR1, on_usr1)
signal.signal(signal.SIGTERM, on_term)
signal.signal(signal.SIGINT, on_term)

while not draining.is_set():
    try:
        c, _ = lis.accept()
    except InterruptedError:
        continue
    except OSError:
        if draining.is_set():
            break
        continue
    with cv:
        inflight += 1
    threading.Thread(target=serve, args=(c,), daemon=True).start()

lis.close()
with cv:
    while inflight:
        cv.wait()
backend.terminate()
try:
    backend.wait(5)
except subprocess.TimeoutExpired:
    backend.kill()
sys.exit(0)
