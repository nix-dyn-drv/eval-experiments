"""Cut the fragment of a source tree that an evaluation actually read, for a granular evaluation cache.

Trace a native evaluation with an EMPTY fetcher cache (a warm cache skips re-hashing subtrees it already knows):

    XDG_CACHE_HOME=$(mktemp -d) strace -f -y -qq -e trace=%file,getdents64 -o trace.txt \
        nix eval --option eval-cache false ... "path:/nix/store/...-source#packages.x86_64-linux.foo.drvPath"
    python3 fragment.py trace.txt /nix/store/...-source fragment/

The fragment holds every path the evaluator opened or stat'ed, in full, and a placeholder (empty file, empty directory
or symlink) for every entry of a directory it listed, so it depends on nothing the evaluation did not read. Add it to
the store (`nix store add --mode nar --name source fragment/`) and point prepare-inputs.py / planner.nix at it as the
flake's self: the planner then caches on exactly those files. On a cache miss, trace the full tree again; a changed
evaluation may read files the old trace never saw.

usage: fragment.py <trace> <tree-in-trace> <out-dir> [tree-to-copy-from]
(the last lets a trace taken on one tree cut the same fragment out of another copy of it, e.g. one with an unrelated change)"""
import os, re, shutil, sys
trace, base, out = sys.argv[1:4]
src_base = sys.argv[4] if len(sys.argv) > 4 else base
pat = re.compile(r'\((?:(?:AT_FDCWD|\d+<([^>]*)>), )?"([^"]*)"')   # fd-relative (openat, newfstatat, statx, faccessat2, ...) or plain path (access, readlink, ...)
listed = re.compile(r'getdents64\(\d+<([^>]*)>')
files, dirs = set(), set()
for line in open(trace, errors='replace'):
    m = listed.search(line)
    if m and (m.group(1) == base or m.group(1).startswith(base + '/')):
        dirs.add(m.group(1)[len(base):].lstrip('/'))
    m = pat.search(line)
    if not m: continue
    d, name = m.group(1), m.group(2)
    p = name if name.startswith('/') else os.path.normpath(os.path.join(d or '', name))
    if p.startswith(base + '/'):
        files.add(p[len(base) + 1:])
def copy(rel):
    src, dst = os.path.join(src_base, rel), os.path.join(out, rel)
    if os.path.isdir(src) and not os.path.islink(src): os.makedirs(dst, exist_ok=True)
    elif os.path.lexists(src):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if not os.path.lexists(dst): shutil.copy2(src, dst, follow_symlinks=False)
n_files = 0
for rel in sorted(files):
    if os.path.lexists(os.path.join(src_base, rel)): copy(rel); n_files += 1
n_entries = 0
for d in sorted(dirs):
    src = os.path.join(src_base, d)
    if not os.path.isdir(src): continue
    os.makedirs(os.path.join(out, d), exist_ok=True)
    for e in os.listdir(src):
        rel = os.path.join(d, e) if d else e
        if rel in files: continue
        sp, dp = os.path.join(src_base, rel), os.path.join(out, rel)   # listed but never read: a placeholder keeps the listing identical
        if os.path.isdir(sp) and not os.path.islink(sp): os.makedirs(dp, exist_ok=True)
        elif os.path.islink(sp): os.makedirs(os.path.dirname(dp), exist_ok=True); os.path.lexists(dp) or os.symlink(os.readlink(sp), dp)
        else: os.makedirs(os.path.dirname(dp), exist_ok=True); os.path.lexists(dp) or open(dp, 'w').close()
        n_entries += 1
total = sum(len(f) for _, _, f in os.walk(out))
print(f"{n_files} touched paths, {len(dirs)} listed directories (+{n_entries} entries), fragment holds {total} files")
