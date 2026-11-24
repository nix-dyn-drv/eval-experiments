"""Pin a flake's inputs as store paths for planner.nix (flake mode).

usage: prepare-inputs.py <flake-ref> <work-dir>

Archives the flake and every locked input into the store (`nix flake archive`), then writes into <work-dir>:
  inputs.json   self (store path, narHash, lastModified) + one override per locked input (name, store path, narHash)
  register.sql  validity rows with the real hashes, so the planner can declare the mounted input trees valid in
                its private store without copying them
  paths.txt     the store paths involved (the planner mounts them as inputs)
Environment: NIX (the nix binary, default "nix"), NIX_OPTS (extra options for every nix call, e.g. "--store ...")."""
import base64, json, os, shlex, subprocess, sys

ref, out = sys.argv[1], sys.argv[2]
NIX = [os.environ.get("NIX", "nix"), *shlex.split(os.environ.get("NIX_OPTS", ""))]
FEATURES = ["--extra-experimental-features", "nix-command flakes"]

def nix(*args):
    return subprocess.check_output([*NIX, *FEATURES, *args], text=True)

meta = json.loads(nix("flake", "metadata", "--json", ref))
archive = json.loads(nix("flake", "archive", "--json", ref))
nodes = meta["locks"]["nodes"]
overrides = []

def walk(node_id, path, archived):
    for name, locked in nodes[node_id].get("inputs", {}).items():
        if isinstance(locked, list):          # a `follows` entry: resolved through the node it follows
            continue
        child = (archived.get("inputs") or {}).get(name)
        if not child or "path" not in child:  # a relative path input lives inside its parent tree
            continue
        overrides.append({"name": "/".join(path + [name]), "path": child["path"]})
        walk(locked, path + [name], child)

walk(meta["locks"]["root"], [], archive)
paths = sorted({o["path"] for o in overrides} | {archive["path"]})
info = json.loads(nix("path-info", "--json", *paths))
if isinstance(info, list):
    info = {i["path"]: i for i in info}

def hex_hash(sri):
    return base64.b64decode(sri.split("-", 1)[1]).hex()

os.makedirs(out, exist_ok=True)
with open(f"{out}/register.sql", "w") as f:
    f.write("BEGIN;\n")
    for p in paths:
        i = info[p]
        f.write(f"INSERT OR IGNORE INTO ValidPaths(path, hash, registrationTime, narSize, ultimate) "
                f"VALUES ('{p}', 'sha256:{hex_hash(i['narHash'])}', strftime('%s','now'), {i['narSize']}, 1);\n")
    f.write("COMMIT;\n")
with open(f"{out}/paths.txt", "w") as f:
    f.write("".join(p + "\n" for p in paths))
for o in overrides:
    o["narHash"] = info[o["path"]]["narHash"]
json.dump({"self": archive["path"], "selfNarHash": info[archive["path"]]["narHash"],
           "lastModified": meta["lastModified"], "dir": meta.get("locked", {}).get("dir", ""),   # a flake in a subdirectory of its tree
           "overrides": overrides},
          open(f"{out}/inputs.json", "w"), indent=1)
print(f"{len(overrides)} inputs pinned, {len(paths)} store paths ({sum(info[p]['narSize'] for p in paths) / 2**20:.0f} MiB)")
