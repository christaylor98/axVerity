"""Start/stop a shim under test. The harness never inspects the store
directory: it only mkdir's a fresh root and rm -rf's it. No stat, no glob,
no read of any file inside."""
import os, socket, subprocess, shutil, time, itertools

SHIM = os.path.abspath("shim/bin/axshim")
_ports = itertools.count(29400)

def free_port():
    for p in _ports:
        s=socket.socket()
        try:
            s.bind(("127.0.0.1",p)); s.close(); return p
        except OSError:
            s.close()

class Shim:
    # A HARNESS THAT INHERITS DEFAULTS PROBES WHATEVER THEY HAPPEN TO BE.
    # `config` writes .axverity-store/config/<k> before the shim starts, so an
    # arm can state the deployment it is probing instead of assuming one. Two
    # arms needed this and were silently not probing without it: P5's status
    # map called a 20,000-byte record "oversize" (ordinary once max_record
    # reached 65536, so it was ADMITTED and the map recorded status 0), and any
    # size sweep is meaningless unless it knows where the limit is.
    #
    # This is a black-box harness, so nothing here reads a default out of the
    # implementation. An arm that cares about a boundary sets it.
    def __init__(self, store_root, fresh=True, cwd=None, config=None):
        self.root=os.path.abspath(store_root)
        if fresh:
            shutil.rmtree(self.root, ignore_errors=True)
        os.makedirs(self.root, exist_ok=True)
        if config:
            cfg=os.path.join(self.root,".axverity-store","config")
            os.makedirs(cfg, exist_ok=True)
            for k,v in config.items():
                with open(os.path.join(cfg,k),"w") as f: f.write(f"{v}\n")
        self.port=free_port()
        self.cwd=cwd or os.getcwd()
        self.proc=None
    def start(self, timeout=15.0):
        self.proc=subprocess.Popen([SHIM,self.root,str(self.port)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=self.cwd,
            # no reload front: P4 kills the shim's child and must hit the writer
            env=dict(os.environ, AXSHIM_DIRECT="1"))
        t0=time.time()
        while time.time()-t0<timeout:
            try:
                s=socket.create_connection(("127.0.0.1",self.port),timeout=0.5); s.close(); return self
            except OSError:
                if self.proc.poll() is not None:
                    raise RuntimeError(f"shim exited rc={self.proc.returncode} before listening")
                time.sleep(0.1)
        raise RuntimeError("shim never listened")
    def alive(self):
        return self.proc is not None and self.proc.poll() is None
    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try: self.proc.wait(3)
            except subprocess.TimeoutExpired:
                self.proc.kill(); self.proc.wait(3)
    def kill(self):
        if self.proc and self.proc.poll() is None:
            self.proc.kill(); self.proc.wait(3)
    def __enter__(self): return self.start()
    def __exit__(self,*a): self.stop()
