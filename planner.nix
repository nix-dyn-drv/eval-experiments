# Evaluation as a builder-rpc-v0 dynamic derivation, with no daemon changes.
#
# The planner is a text-hashed, content-addressed derivation that requires the `builder-rpc-v0` system
# feature. Inside the sandbox it evaluates the target into a private store that uses the sandbox's own
# /nix/store as its directory (a private sqlite database under $TMPDIR, the mounted inputs registered as
# valid, nothing copied), re-adds the resulting derivation closure into the outer store through the limited
# socket with the operations it already allows (`nix store add` for sources, `nix derivation add` for
# derivations), and submits the top-level derivation with `nix store submit-output`. The consumer depends on
# that derivation through builtins.outputOf, so the target is never evaluated outside a build.
{ system ? builtins.currentSystem
, pkgs ? import <nixpkgs> { inherit system; }   # the planner's tools are built for the system it runs on
, mode ? "flake"            # "flake": evaluate <self>#<target>.drvPath with the inputs pinned by prepare-inputs.py
                            # "expr":  evaluate the Nix expression <target> with -I nixpkgs=<nixpkgsPath>
, inputs ? null             # flake mode: the inputs.json written by prepare-inputs.py
, register ? null           # flake mode: the register.sql written by prepare-inputs.py
, target                    # flake mode: an attribute path such as "packages.x86_64-linux.hello"; expr mode: the expression
, nixpkgsPath ? null        # expr mode: the <nixpkgs> tree (a store path)
, evaluator ? pkgs.nixVersions.latest   # package or store path: bin/nix (flake mode); bin/nix-instantiate, bin/iets or bin/fix (expr mode)
, evaluatorKind ? "auto"    # "nix" | "nix-instantiate" | "iets" | "fix" | "auto"
, rpcNix ? pkgs.nixVersions.latest      # Nix >= 2.36: the in-sandbox client for the socket (store add, derivation add, submit-output)
, name                      # the emitted derivation's basename without its hash prefix; the submitted output must carry it
, salt ? ""                 # change to force a rebuild
, jobs ? 8                  # parallel re-add workers
}:
let
  storePathOf = p: if builtins.isString p && builtins.substring 0 11 p == "/nix/store/" then builtins.storePath p else p;
  ev = storePathOf evaluator;
  rpc = storePathOf rpcNix;
  inp = if inputs == null then null else builtins.fromJSON (builtins.readFile inputs);
  enc = s: builtins.replaceStrings [ "+" "=" ] [ "%2B" "%3D" ] s;
  overrideArgs = if inp == null then "" else builtins.concatStringsSep "\n"
    (pkgs.lib.concatMap (o: [ "--override-input" o.name "path:${builtins.storePath o.path}?narHash=${enc o.narHash}" ]) inp.overrides);
  inputPaths = if inp == null then [ ] else map (o: builtins.storePath o.path) inp.overrides ++ [ (builtins.storePath inp.self) ];
  kind =
    if evaluatorKind != "auto" then evaluatorKind
    else if mode == "flake" then "nix"
    else if builtins.pathExists "${ev}/bin/nix-instantiate" then "nix-instantiate"
    else if builtins.pathExists "${ev}/bin/iets" then "iets"
    else if builtins.pathExists "${ev}/bin/fix" then "fix"
    else throw "cannot tell what kind of evaluator ${ev} is; pass evaluatorKind";
  evalCmd = {
    nix = ''"$evaluator/bin/nix" --store "$store" --offline eval --no-write-lock-file "''${OVERRIDES[@]}" --raw "$flake#$target.drvPath"'';
    nix-instantiate = ''"$evaluator/bin/nix-instantiate" --store "$store" --option substituters "" -I nixpkgs=$nixpkgsPath -E "$target"'';
    iets = ''"$evaluator/bin/iets" nix-instantiate --store "unix://$NIX_DAEMON_SOCKET_PATH" -I nixpkgs=$nixpkgsPath -E "$target"'';
    fix = ''"$evaluator/bin/fix" instantiate --store "unix://$NIX_DAEMON_SOCKET_PATH" -I nixpkgs=$nixpkgsPath -E "$target"'';
  }.${kind};
  needsDaemon = kind == "iets" || kind == "fix";
  planner = derivation {
    inherit name system salt target kind mode evalCmd overrideArgs inputPaths;
    evaluator = ev;
    rpcNix = rpc;
    flake = if inp == null then "" else "path:${builtins.storePath inp.self}?lastModified=${toString inp.lastModified}&narHash=${enc inp.selfNarHash}"
      + (if (inp.dir or "") != "" then "&dir=${inp.dir}" else "");
    registration = if register == null then "" else builtins.readFile register;
    nixpkgsPath = if nixpkgsPath == null || nixpkgsPath == "" then "" else builtins.storePath nixpkgsPath;
    readd = builtins.path { path = ./readd.py; name = "readd.py"; };
    readdJobs = toString jobs;
    needsDaemon = if needsDaemon then "1" else "";
    passAsFile = [ "overrideArgs" "registration" ];
    requiredSystemFeatures = [ "builder-rpc-v0" ];
    builder = "${pkgs.bash}/bin/bash";
    PATH = "${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin:${pkgs.gawk}/bin:${pkgs.gnused}/bin:${pkgs.python3}/bin:${pkgs.sqlite}/bin";
    args = [ "-c" ''
      set -eu
      export HOME=$TMPDIR
      mkdir -p $TMPDIR/scratch/state $TMPDIR/scratch/log
      store="local?state=$TMPDIR/scratch/state&log=$TMPDIR/scratch/log"   # the sandbox's own /nix/store with a private database
      export NIX_CONFIG=$'experimental-features = nix-command flakes ca-derivations dynamic-derivations\nbuild-users-group ='
      echo "evaluator ($kind): $evaluator; rpc client: $($rpcNix/bin/nix --version); socket: $NIX_REMOTE" >&2
      r0=$(date +%s.%N)
      $rpcNix/bin/nix-store --store "$store" --gc --print-roots > /dev/null 2>&1 || true   # opens the store once: creates its database
      db=$TMPDIR/scratch/state/db/db.sqlite; test -f "$db" || { echo "no database at $db" >&2; exit 1; }
      [ -s "$registrationPath" ] && sqlite3 "$db" < "$registrationPath"   # the flake inputs, with their real hashes
      { echo "BEGIN;"; ls /nix/store | grep -vE '^(\.|tmp)' | while read -r e; do   # everything else the sandbox mounted
          echo "INSERT OR IGNORE INTO ValidPaths(path, hash, registrationTime, narSize, ultimate) VALUES ('/nix/store/$e', 'sha256:0000000000000000000000000000000000000000000000000000000000000000', strftime('%s','now'), 0, 1);"; done; echo "COMMIT;"; } | sqlite3 "$db"
      export READD_SKIP=$(ls /nix/store | grep -vE '^(\.|tmp)' | sed 's|^|/nix/store/|' | tr '\n' ':')
      echo "REGISTER paths=$(sqlite3 "$db" 'select count(*) from ValidPaths') wall=$(awk -v a=$r0 -v b=$(date +%s.%N) 'BEGIN{printf "%.2f", b-a}')s" >&2
      if [ -n "$needsDaemon" ]; then
        export NIX_DAEMON_SOCKET_PATH=$TMPDIR/daemon.sock
        $rpcNix/bin/nix --store "$store" daemon > $TMPDIR/daemon.log 2>&1 &
        dpid=$!; for i in $(seq 1 600); do [ -S "$NIX_DAEMON_SOCKET_PATH" ] && break; sleep 0.1; done
        [ -S "$NIX_DAEMON_SOCKET_PATH" ] || { cat $TMPDIR/daemon.log >&2; echo "no daemon socket" >&2; exit 1; }
      fi
      mapfile -t OVERRIDES < "$overrideArgsPath"
      export store evaluator flake target nixpkgsPath
      ( ${pkgs.time}/bin/time -v ${pkgs.bash}/bin/bash -c "$evalCmd" > $TMPDIR/drv.txt ) 2> $TMPDIR/time.txt || { cat $TMPDIR/time.txt >&2; exit 1; }
      d=$(grep -o '/nix/store/[a-z0-9]\{32\}-[^"'"'"' ]*\.drv' $TMPDIR/drv.txt | tail -n 1)
      [ -n "$d" ] || { echo "the evaluator printed no derivation path:" >&2; cat $TMPDIR/drv.txt >&2; exit 1; }
      wall=$(awk -F': ' '/Elapsed \(wall clock\)/{print $2}' $TMPDIR/time.txt)
      rss=$(awk -F': ' '/Maximum resident set size/{print $2}' $TMPDIR/time.txt)
      echo "METRIC kind=$kind wall=$wall maxrss_kb=$rss drv=$d" >&2
      [ -n "$needsDaemon" ] && { kill $dpid 2>/dev/null || true; }
      READD_JOBS=$readdJobs python3 -I $readd "$d" $rpcNix/bin/nix "$store" "$NIX_REMOTE"
      s0=$(date +%s.%N)
      $rpcNix/bin/nix store submit-output "$d" out
      echo "SUBMITTED $d wall=$(awk -v a=$s0 -v b=$(date +%s.%N) 'BEGIN{printf "%.2f", b-a}')s" >&2
    '' ];
    __contentAddressed = true;
    outputHashMode = "text";
    outputHashAlgo = "sha256";
  };
  consumer = derivation {
    name = "uses-${pkgs.lib.removeSuffix ".drv" name}";   # a name may end in .drv only for a derivation that produces one
    inherit system;
    builder = "${pkgs.bash}/bin/bash";
    PATH = "${pkgs.coreutils}/bin";
    args = [ "-c" ''
      set -eu
      echo "built from the derivation evaluated inside another build: ${builtins.outputOf planner.outPath "out"}" > $out
      ls -la ${builtins.outputOf planner.outPath "out"} >> $out
    '' ];
  };
in { inherit planner consumer; }
