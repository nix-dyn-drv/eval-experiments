"""Re-add a derivation's closure from the planner's private store into the outer store through the
builder-rpc-v0 socket, using only operations the socket allows: `nix store add` for sources and
`nix derivation add` for derivations, one `nix` process per object.

READD_JOBS=N     add the objects of each dependency level in parallel (references are always added first)
READD_SKIP=a:b   paths the outer store already holds (the sandbox's mounted inputs)
READD_VERBOSE=1  log each add

usage: readd.py <drv> <nix> <private-store-uri> <remote-store-uri>"""
import json, os, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

d, nix, store, remote = sys.argv[1:5]
jobs = int(os.environ.get("READD_JOBS", "1"))
verbose = bool(os.environ.get("READD_VERBOSE"))

def run(*a, **k):
    r = subprocess.run(a, capture_output=True, text=True, **k)
    if r.returncode != 0:
        raise RuntimeError(f"FAILED {' '.join(a[:4])}: {r.stderr.strip()[-600:]}")
    return r.stdout

raw = json.loads(run(nix, "path-info", "--store", store, "--json", "-r", d))
info = raw if isinstance(raw, dict) else {e["path"]: e for e in raw}
skip = set(filter(None, os.environ.get("READD_SKIP", "").split(":")))
todo = {p for p in info if p not in skip}
refs = {p: {r for r in (info[p].get("references") or []) if r != p and r in todo} for p in todo}

def add(p):
    if p.endswith(".drv"):
        js = json.loads(run(nix, "derivation", "show", "--store", store, p))
        obj = js.get("derivations", js) if isinstance(js, dict) else js
        while isinstance(obj, dict) and "name" not in obj and len(obj) == 1:
            obj = next(iter(obj.values()))
        out = run(nix, "derivation", "add", "--store", remote, input=json.dumps(obj)).strip()
        mode = "drv"
    else:
        ca = info[p].get("ca") or ""
        if isinstance(ca, dict): ca = f"{ca.get('method')}:{ca.get('hash')}"
        mode = "text" if ca.startswith("text") else "nar" if (ca.startswith("fixed:r:") or ca.startswith("nar")) else "flat" if (ca.startswith("fixed:") or ca.startswith("flat")) else "nar"
        out = run(nix, "store", "add", "--store", remote, "--mode", mode, "--name", os.path.basename(p)[33:], p).strip()
    if out != p:
        raise RuntimeError(f"PATH MISMATCH {p} -> {out} (mode {mode})")
    if verbose: print(f"ADD {p}", file=sys.stderr)
    return mode

t0 = time.time(); n = 0; by = {"skipped": len(info) - len(todo)}; levels = 0
nbytes = sum(int(info[p].get("narSize") or 0) for p in todo)
done = set()
with ThreadPoolExecutor(max_workers=jobs) as pool:
    while todo:
        level = [p for p in todo if refs[p] <= done]
        if not level:
            print(f"cycle among {len(todo)} remaining paths", file=sys.stderr); sys.exit(1)
        levels += 1
        try:
            for mode in pool.map(add, level):
                n += 1; by[mode] = by.get(mode, 0) + 1
        except RuntimeError as e:
            print(e, file=sys.stderr); sys.exit(1)
        done.update(level); todo.difference_update(level)
print(f"READD paths={n} drvs={by.get('drv',0)} sources={n-by.get('drv',0)} by={by} levels={levels} jobs={jobs} narbytes={nbytes} wall={time.time()-t0:.2f}s", file=sys.stderr)
