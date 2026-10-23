# Bridge primitives required for AX158 live upgrade

`shim/tests/run-shim-upgrade.sh` starts OLD and NEW shims on the SAME fixed port while a client
probes that port for 6 s, then sends SIGUSR1 to OLD; zero failed connects allowed. Currently
NEW dies with `tcp_listen(47999): Address already in use` (net.rs:464), so the run fails
(`mode=reload ok=2684 failed=2721`, rc=1). A fresh/ephemeral port per listener cannot work (the
client probes one port); waiting for OLD to close is exactly the refusal gap the test forbids;
the shim (`shim.m1`) has no setsockopt/signal/FFI access. So all three primitives are needed in
`axis-codegen-bridge-rs/src/runtime/net.rs` (plus registry entries in axRegistry).

## 1. `tcp_listen_reuseport(port: Int) -> (handle: Int, port: Int)`
Like `tcp_listen`, but sets SO_REUSEPORT (and SO_REUSEADDR) before bind, so OLD and NEW share the port
and the kernel balances accepts across both. Sketch (needs `socket2` or libc):
```rust
#[track_caller]
pub fn tcp_listen_reuseport(n: i64) -> Value {
    let port = if (0..=65535).contains(&n) { n as u16 } else { panic!("tcp_listen_reuseport: port {} out of range", n) };
    let sock = socket2::Socket::new(socket2::Domain::IPV4, socket2::Type::STREAM, None).unwrap();
    sock.set_reuse_address(true).unwrap();
    sock.set_reuse_port(true).unwrap();
    sock.bind(&std::net::SocketAddr::from(([0,0,0,0], port)).into())
        .unwrap_or_else(|e| panic!("tcp_listen_reuseport({}): {}", port, e));
    sock.listen(1024).unwrap();
    let listener: TcpListener = sock.into();
    let bound = listener.local_addr().unwrap().port();
    Value::Tuple(vec![Value::Int(insert_listener(Sock::Listener(listener))), Value::Int(bound as i64)])
}
```

## 2. `tcp_accept_timeout(handle: Int, millis: Int) -> Int`
Like `tcp_accept` but returns the conn handle, or `-1` on timeout, so the accept loop can poll the
drain flag. Sketch: set the listener non-blocking, poll(2) the fd for `millis`, then accept;
`WouldBlock`/poll-timeout -> `Value::Int(-1)`; restore blocking mode afterwards (or keep non-blocking
and handle it in this fn only).
```rust
let fd = listener.as_raw_fd();
let mut p = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
if unsafe { libc::poll(&mut p, 1, millis as i32) } <= 0 { return Value::Int(-1); }
// then proceed exactly as tcp_accept
```

## 3. SIGUSR1 flag: `signal_flag_usr1(_: Unit) -> Bool`
Installs (once, idempotent) a SIGUSR1 handler that sets a process-global `AtomicBool`; returns the
current flag value (true after a signal was received; not cleared). Sketch:
```rust
static USR1: AtomicBool = AtomicBool::new(false);
extern "C" fn on_usr1(_: libc::c_int) { USR1.store(true, Ordering::SeqCst); }
pub fn signal_flag_usr1(_: Value) -> Value {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| unsafe { libc::signal(libc::SIGUSR1, on_usr1 as usize); });
    Value::Bool(USR1.load(Ordering::SeqCst))
}
```

## Shim wiring once available
In `shim.m1`: listen with `tcp_listen_reuseport`; accept loop uses `tcp_accept_timeout(h, 100)`;
each iteration checks `signal_flag_usr1`; on true: `tcp_close` the listener, finish in-flight
connections, exit. Rebuild with `shim/build-shim.sh`, rerun the test.

**The bridge repos (`~/dev/axis-codegen-bridge-rs`, `~/dev/axRegistry`)
need to be made writable (or this patch applied by a human).**
