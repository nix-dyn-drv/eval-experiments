"""Re-add a derivation's closure from the planner's private store into the outer store through the
builder-rpc-v0 socket, batched: the closure is streamed in dependency order in ONE AddMultipleToStore
operation on ONE connection, with the NARs produced in-process. Only operations the socket already
allows are used (IsValidPath, AddMultipleToStore); the worker protocol is spoken directly because
`nix copy` would first issue QueryValidPaths, which the socket refuses.

IsValidPath only answers for what the sandbox may see (its inputs and what it added itself), so the
one `nix-store --check-validity` call skips exactly those; the outer store decides the rest by itself,
restoring only the objects it does not hold yet and discarding the NARs of the ones it does.

READD_MODE=perobject  use the original one-process-per-object script instead (readd-perobject.py)
READD_VERBOSE=1       log each object
READD_SKIP=a:b        ignored (the validity check replaces it); kept for the old script

usage: readd.py <drv> <nix> <private-store-uri> <remote-store-uri>"""
import base64, hashlib, json, os, socket, stat, struct, subprocess, sys, threading, time
from urllib.parse import urlsplit, parse_qs

d, nix, store, remote = sys.argv[1:5]
verbose = bool(os.environ.get("READD_VERBOSE"))
if os.environ.get("READD_MODE") == "perobject":
    os.execv(sys.executable, [sys.executable, "-I", os.environ.get("READD_PEROBJECT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "readd-perobject.py")] + sys.argv[1:])

def run(*a, **k):
    r = subprocess.run(a, capture_output=True, text=True, **k)
    if r.returncode != 0:
        raise RuntimeError(f"FAILED {' '.join(a[:4])}: {r.stderr.strip()[-600:]}")
    return r.stdout

def log(*a):
    print(*a, file=sys.stderr, flush=True)

# ---- 1. the closure, with its metadata, from the private store ------------------------------------
t0 = time.time()
raw = json.loads(run(nix, "path-info", "--store", store, "--json", "-r", d))
info = raw if isinstance(raw, dict) else {e["path"]: e for e in raw}
q = parse_qs(urlsplit(store).query) if "?" in store else {}
root = (q.get("root") or [""])[0]
physical = lambda p: root + p if root else p

# ---- 2. skip what the sandbox can see is already there (IsValidPath, one process) -----------------
nix_store = os.path.join(os.path.dirname(nix), "nix-store")
paths = sorted(info)
missing = set()
for i in range(0, len(paths), 1000):
    missing |= set(run(nix_store, "--store", remote, "--check-validity", "--print-invalid", *paths[i:i + 1000]).split())
t1 = time.time()

# ---- 3. dependency order among the missing objects (references first) ----------------------------
refs = {p: {r for r in (info[p].get("references") or []) if r != p and r in missing} for p in missing}
order, done = [], set()
while len(order) < len(missing):
    level = sorted(p for p in missing if p not in done and refs[p] <= done)
    if not level:
        log(f"cycle among {len(missing) - len(order)} remaining paths"); sys.exit(1)
    order += level; done |= set(level)

# ---- 4. NARs, in-process -------------------------------------------------------------------------
def nstr(b):
    return struct.pack("<Q", len(b)) + b + b"\0" * ((8 - len(b) % 8) % 8)

def nar_node(p, out):
    st = os.lstat(p)
    out.append(nstr(b"("))
    if stat.S_ISREG(st.st_mode):
        out.append(nstr(b"type") + nstr(b"regular"))
        if st.st_mode & stat.S_IXUSR:
            out.append(nstr(b"executable") + nstr(b""))
        with open(p, "rb") as f:
            out.append(nstr(b"contents") + nstr(f.read()))
    elif stat.S_ISLNK(st.st_mode):
        out.append(nstr(b"type") + nstr(b"symlink") + nstr(b"target") + nstr(os.readlink(p)))
    elif stat.S_ISDIR(st.st_mode):
        out.append(nstr(b"type") + nstr(b"directory"))
        for name in sorted(os.listdir(p)):
            out.append(nstr(b"entry") + nstr(b"(") + nstr(b"name") + nstr(name) + nstr(b"node"))
            nar_node(os.path.join(p, name), out)
            out.append(nstr(b")"))
    else:
        raise RuntimeError(f"unsupported file type: {p!r}")
    out.append(nstr(b")"))

def nar(p):
    out = [nstr(b"nix-archive-1")]
    nar_node(os.fsencode(p), out)
    return b"".join(out)

NIX32 = "0123456789abcdfghijklmnpqrsvwxyz"
def nix32(h):
    n = len(h); out = []
    for i in range((n * 8 - 1) // 5, -1, -1):
        b = i * 5; j, k = divmod(b, 8)
        c = (h[j] >> k) | ((h[j + 1] << (8 - k)) if j + 1 < n else 0)
        out.append(NIX32[c & 0x1f])
    return "".join(out)

def sri_bytes(s):  # "sha256-<base64>" -> bytes
    algo, _, rest = s.partition("-")
    return base64.b64decode(rest)

def render_ca(ca):
    if not ca:
        return ""
    if isinstance(ca, str):
        return ca
    method = ca.get("method"); h = ca.get("hash")
    if isinstance(h, dict):
        hb = base64.b64decode(h["hash"]) if h.get("format") == "base64" else bytes.fromhex(h["hash"]) if h.get("format") == "base16" else None
        if hb is None: raise RuntimeError(f"unsupported hash format {h}")
        algo = h.get("algorithm", "sha256")
    else:
        hb = sri_bytes(h); algo = h.split("-", 1)[0]
    enc = f"{algo}:{nix32(hb)}"
    return {"text": f"text:{enc}", "nar": f"fixed:r:{enc}", "flat": f"fixed:{enc}", "git": f"fixed:git:{enc}"}[method]

# ---- 5. one AddMultipleToStore on one connection --------------------------------------------------
WORKER_MAGIC_1, WORKER_MAGIC_2 = 0x6e697863, 0x6478696f
STDERR_NEXT, STDERR_READ, STDERR_WRITE, STDERR_LAST, STDERR_ERROR = 0x6f6c6d67, 0x64617461, 0x64617416, 0x616c7473, 0x63787470
STDERR_START_ACTIVITY, STDERR_STOP_ACTIVITY, STDERR_RESULT = 0x53545254, 0x53544f50, 0x52534c54
OP_ADD_MULTIPLE = 44
LOCAL_VERSION = (1 << 8) | 39

u64 = lambda n: struct.pack("<Q", n)
wstr = lambda b: nstr(b if isinstance(b, bytes) else b.encode())
wstrs = lambda xs: u64(len(xs)) + b"".join(wstr(x) for x in xs)

class Conn:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(3600)
        self.s.connect(path)
        self.f = self.s.makefile("rb")
    def send(self, b): self.s.sendall(b)
    def rbytes(self, n):
        b = self.f.read(n)
        if len(b) != n: raise RuntimeError("daemon closed the connection")
        return b
    def ru64(self): return struct.unpack("<Q", self.rbytes(8))[0]
    def rstr(self):
        n = self.ru64(); b = self.rbytes(n); self.rbytes((8 - n % 8) % 8); return b
    def rstrs(self): return [self.rstr() for _ in range(self.ru64())]
    def rfields(self):
        for _ in range(self.ru64()):
            t = self.ru64()
            if t == 0: self.ru64()
            elif t == 1: self.rstr()
            else: raise RuntimeError(f"unknown field type {t}")
    def handshake(self):
        self.send(u64(WORKER_MAGIC_1) + u64(LOCAL_VERSION))
        if self.ru64() != WORKER_MAGIC_2: raise RuntimeError("not a nix daemon socket")
        dv = self.ru64(); proto = min(dv, LOCAL_VERSION)
        if proto >= (1 << 8) | 38:
            self.send(wstrs([])); self.rstrs()           # features
        self.send(u64(0) + u64(0))                       # obsolete cpu affinity, reserveSpace
        if proto >= (1 << 8) | 33: self.rstr()           # daemon nix version
        if proto >= (1 << 8) | 35: self.ru64()           # trust
        self.proto = proto
        err = self.drain_stderr()                        # the daemon's startup stderr, ends with LAST
        if err: raise RuntimeError(f"daemon startup error: {err}")
        return dv
    def drain_stderr(self):
        """Consume the daemon's stderr stream until LAST (or ERROR); returns the error text or None."""
        while True:
            m = self.ru64()
            if m == STDERR_NEXT:
                t = self.rstr().decode(errors="replace").strip()
                if verbose and t: log("daemon:", t)
            elif m == STDERR_START_ACTIVITY:
                self.ru64(); self.ru64(); self.ru64(); self.rstr(); self.rfields(); self.ru64()
            elif m == STDERR_STOP_ACTIVITY: self.ru64()
            elif m == STDERR_RESULT: self.ru64(); self.ru64(); self.rfields()
            elif m == STDERR_LAST: return None
            elif m == STDERR_ERROR:
                if self.rstr() != b"Error": return "unexpected error type"
                self.ru64(); self.rstr(); msg = self.rstr().decode(errors="replace")
                if self.ru64() != 0: return msg
                traces = [self.rstr().decode(errors="replace") for _ in range(self.ru64()) if self.ru64() == 0]
                return msg + "".join("\n  " + t for t in traces)
            elif m in (STDERR_READ, STDERR_WRITE): return "unexpected READ/WRITE from the daemon"
            else: return f"unknown message {m:#x} from the daemon"

def entry(p):
    i = info[p]
    data = nar(physical(p))
    h = hashlib.sha256(data).digest()
    if h != sri_bytes(i["narHash"]):
        raise RuntimeError(f"NAR hash mismatch for {p}: computed {h.hex()[:16]}..., store says {sri_bytes(i['narHash']).hex()[:16]}...")
    if int(i.get("narSize") or 0) not in (0, len(data)):
        raise RuntimeError(f"NAR size mismatch for {p}: {len(data)} vs {i['narSize']}")
    meta = (wstr(p) + wstr(i.get("deriver") or "") + wstr(h.hex()) + wstrs(sorted(i.get("references") or []))
            + u64(int(time.time())) + u64(len(data)) + u64(0) + wstrs([]) + wstr(render_ca(i.get("ca"))))
    return meta + data, len(data)

sock_path = remote.split("://", 1)[1] if remote.startswith("unix://") else parse_qs(urlsplit(remote).query).get("socket", [""])[0] if "socket=" in remote else remote
by = {"skipped": len(info) - len(missing), "drv": 0, "nar": 0, "text": 0}
nbytes = 0; t_nar = 0.0; err = None
if order:
    c = Conn(sock_path); dv = c.handshake()
    c.send(u64(OP_ADD_MULTIPLE) + u64(0) + u64(1))     # repair = no, dontCheckSigs = yes
    result = {}
    reader = threading.Thread(target=lambda: result.__setitem__("err", c.drain_stderr()), daemon=True); reader.start()
    FRAME = 1 << 20
    buf = bytearray(u64(len(order)))
    def flush(final=False):
        global buf
        while len(buf) >= FRAME or (final and buf):
            chunk, buf = bytes(buf[:FRAME]), buf[FRAME:]
            c.send(u64(len(chunk)) + chunk)
    try:
        for p in order:
            if not reader.is_alive(): break                 # the daemon already answered (an error): stop early
            ts = time.time(); e, n = entry(p); t_nar += time.time() - ts
            nbytes += n; buf += e
            kind = "drv" if p.endswith(".drv") else "text" if render_ca(info[p].get("ca")).startswith("text") else "nar"
            by[kind] += 1
            if verbose: log(f"ADD {p} ({n} bytes)")
            flush()
        flush(final=True)
    finally:
        c.send(u64(0))                                      # end of the framed stream
    reader.join()
    err = result.get("err")
    c.s.close()
    if err:
        log(f"AddMultipleToStore FAILED: {err}"); sys.exit(1)
t2 = time.time()
print(f"READD paths={len(info)} missing={len(order)} drvs={sum(1 for p in info if p.endswith('.drv'))} "
      f"sources={sum(1 for p in info if not p.endswith('.drv'))} by={by} levels=1 jobs=1 narbytes={nbytes} "
      f"check={t1 - t0:.2f}s nar={t_nar:.2f}s op={t2 - t1 - t_nar:.2f}s wall={t2 - t0:.2f}s", file=sys.stderr, flush=True)
