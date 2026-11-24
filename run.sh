#!/usr/bin/env bash
# Run the sandboxed-evaluation experiment on a flake (or a Nix expression) and print its row of the table:
# cold / warm sandboxed planner builds, and the same evaluator run outside the sandbox as the baseline.
set -euo pipefail
usage() { cat <<'USAGE'
usage: ./run.sh --flake REF#ATTR [options]              ATTR is a full attribute path, e.g. packages.x86_64-linux.hello
       ./run.sh --expr 'EXPR' --nixpkgs PATH [options]  nix-instantiate-style evaluators (Nix, Lix, iets, fix)
options:
  --evaluator PKG   nixpkgs attribute (nixVersions.latest, nix, lix, ...) or a store path          [nixVersions.latest]
  --kind KIND       nix | nix-instantiate | iets | fix | auto                                       [auto]
  --rpc-nix PKG     Nix >= 2.36 used inside the sandbox as the socket client                        [nixVersions.latest]
  --jobs N          parallel re-add workers                                                         [8]
  --system SYSTEM   the system the planner builds for                                               [current]
  --name NAME       the emitted derivation's basename without its hash (taken from the baseline run by default)
  --no-native       skip the outside-sandbox baseline (then --name is required)
  --no-consumer     skip the consumer (builtins.outputOf) build after the warm run
  --work DIR        work directory                                                                  [./work/<stamp>]
environment:
  NIX          the nix binary used for the outer builds and the input preparation                  [nix]
  NIX_OPTS     extra options for every nix call, e.g. "--store local?root=/tmp/s"
  BUILD_OPTS   extra options for the planner and consumer builds only
  REMOTE_STORE build the planner and consumer in a remote store (e.g. "ssh-ng://builder") with the local store as
               the eval store: the evaluated graph then lives on the builder (see README: why not `builders =`)
  NIXPKGS      the nixpkgs tree planner.nix takes its tools from       [the flake's nixpkgs input, else <nixpkgs>]
USAGE
}
HERE=$(cd "$(dirname "$0")" && pwd)
MODE=; REF=; ATTR=; EXPR=; NIXPKGS_ARG=; EVALUATOR=nixVersions.latest; KIND=auto; RPC=nixVersions.latest; JOBS=8; SYSTEM=; NAME=; NATIVE=1; CONSUMER=1; WORK=
while [ $# -gt 0 ]; do
  case $1 in
    --flake) MODE=flake; REF=${2%%#*}; ATTR=${2#*#}; shift 2 ;;
    --expr) MODE=expr; EXPR=$2; shift 2 ;;
    --nixpkgs) NIXPKGS_ARG=$2; shift 2 ;;
    --evaluator) EVALUATOR=$2; shift 2 ;;
    --kind) KIND=$2; shift 2 ;;
    --rpc-nix) RPC=$2; shift 2 ;;
    --jobs) JOBS=$2; shift 2 ;;
    --system) SYSTEM=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;;
    --no-native) NATIVE=; shift ;;
    --no-consumer) CONSUMER=; shift ;;
    --work) WORK=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] || { usage >&2; exit 2; }
[ "$MODE" = expr ] && [ -z "$NIXPKGS_ARG" ] && { echo "--expr needs --nixpkgs PATH" >&2; exit 2; }
[ -z "$NATIVE" ] && [ -z "$NAME" ] && { echo "--no-native needs --name NAME" >&2; exit 2; }
NIX=${NIX:-nix}; read -ra NIX_OPTS_ARR <<<"${NIX_OPTS:-}"; eval "BUILD_OPTS_ARR=(${BUILD_OPTS:-})"
XP=(--extra-experimental-features "nix-command flakes ca-derivations dynamic-derivations")
nix() { "$NIX" "${NIX_OPTS_ARR[@]}" "${XP[@]}" "$@"; }
LOCAL_STORE=auto; NIX_OPTS_NO_STORE=()
for ((i = 0; i < ${#NIX_OPTS_ARR[@]}; i++)); do
  if [ "${NIX_OPTS_ARR[$i]}" = --store ]; then LOCAL_STORE=${NIX_OPTS_ARR[$((i+1))]}; i=$((i+1)); else NIX_OPTS_NO_STORE+=("${NIX_OPTS_ARR[$i]}"); fi
done
build() {  # the planner and consumer builds: locally (through `builders =` if configured) or in REMOTE_STORE
  if [ -n "${REMOTE_STORE:-}" ]; then "$NIX" "${NIX_OPTS_NO_STORE[@]}" "${XP[@]}" build --store "$REMOTE_STORE" --eval-store "$LOCAL_STORE" "$@" "${BUILD_OPTS_ARR[@]}"
  else nix build "$@" "${BUILD_OPTS_ARR[@]}"; fi
}
WORK=${WORK:-$HERE/work/$(date +%Y%m%d-%H%M%S)}; mkdir -p "$WORK"
now() { date +%s.%N; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN{printf "%.1f", b-a}'; }
since2() { awk -v a="$1" -v b="$(now)" 'BEGIN{printf "%.2f", b-a}'; }
secs() { awk -F: '{ if (NF == 3) print $1*3600+$2*60+$3; else print $1*60+$2 }' <<<"$1"; }   # GNU time's h:mm:ss or m:ss.ss

# 1. inputs
if [ "$MODE" = flake ]; then
  echo "== pinning the inputs of $REF" >&2
  NIX="$NIX" NIX_OPTS="${NIX_OPTS:-}" python3 "$HERE/prepare-inputs.py" "$REF" "$WORK" >&2
  mapfile -t OVERRIDES < <(python3 - "$WORK/inputs.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); enc = lambda s: s.replace("+", "%2B").replace("=", "%3D")
for o in m["overrides"]: print("--override-input"); print(o["name"]); print(f"path:{o['path']}?narHash={enc(o['narHash'])}")
print(f"path:{m['self']}?lastModified={m['lastModified']}&narHash={enc(m['selfNarHash'])}" + (f"&dir={m['dir']}" if m.get("dir") else ""))
PY
)
  FLAKE=${OVERRIDES[-1]}; unset 'OVERRIDES[-1]'
  NP=${NIXPKGS:-$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(next((o["path"] for o in m["overrides"] if o["name"]=="nixpkgs"), ""))' "$WORK/inputs.json")}
else
  NP=${NIXPKGS:-}
  NIXPKGS_ARG=$(nix store add --name source "$NIXPKGS_ARG")   # a store path already: returned unchanged
fi
[ -n "$NP" ] || NP=$(nix eval --impure --raw --expr 'toString <nixpkgs>')
NIXPKGS_I=(-I "nixpkgs=$NP")

# 2. the evaluator and the in-sandbox client as store paths
resolve() {  # nixpkgs attribute or store path -> store path
  case $1 in /nix/store/*) echo "$1" ;;
    *) nix build --impure "${NIXPKGS_I[@]}" --expr "(import <nixpkgs> { ${SYSTEM:+system = \"$SYSTEM\";} }).$1" --no-link --print-out-paths | grep -vE -- '-(man|doc|dev|debug|info)$' | head -n 1 ;;
  esac
}
EV=$(resolve "$EVALUATOR"); RPCP=$(resolve "$RPC")
echo "evaluator: $EV" >&2; echo "in-sandbox client: $RPCP ($("$RPCP/bin/nix" --version))" >&2

# 3. the outside-sandbox baseline: the same evaluator, same inputs, cold then warm (eval cache off)
NATIVE_DRV=; NATIVE_COLD=; NATIVE_WARM=
if [ -n "$NATIVE" ]; then
  echo "== baseline outside the sandbox" >&2
  K=$KIND
  if [ "$K" = auto ]; then
    if [ "$MODE" = flake ]; then K=nix; elif [ -x "$EV/bin/nix-instantiate" ]; then K=nix-instantiate; elif [ -x "$EV/bin/iets" ]; then K=iets; elif [ -x "$EV/bin/fix" ]; then K=fix; else echo "cannot tell what kind of evaluator $EV is; pass --kind" >&2; exit 2; fi
  fi
  STORE_OPT=(); [ "$LOCAL_STORE" != auto ] && STORE_OPT=(--store "$LOCAL_STORE")
  SOCK=; case $K in iets|fix)
    SOCK=$(mktemp -d)/sock   # short path: fix's client cannot open a socket path longer than 108 bytes
    NIX_DAEMON_SOCKET_PATH=$SOCK "$RPCP/bin/nix" "${STORE_OPT[@]}" "${XP[@]}" daemon > "$WORK/native-daemon.log" 2>&1 & DPID=$!
    for i in $(seq 1 100); do [ -S "$SOCK" ] && break; sleep 0.1; done ;;
  esac
  native() {
    case $K in
      nix) "$EV/bin/nix" "${STORE_OPT[@]}" --extra-experimental-features "nix-command flakes" --option eval-cache false eval --offline --no-write-lock-file "${OVERRIDES[@]}" --raw "$FLAKE#$ATTR.drvPath" ;;
      nix-instantiate) "$EV/bin/nix-instantiate" "${STORE_OPT[@]}" -I "nixpkgs=$NIXPKGS_ARG" -E "$EXPR" ;;
      iets) "$EV/bin/iets" nix-instantiate --store "unix://$SOCK" -I "nixpkgs=$NIXPKGS_ARG" -E "$EXPR" ;;
      fix) "$EV/bin/fix" instantiate --store "unix://$SOCK" -I "nixpkgs=$NIXPKGS_ARG" -E "$EXPR" ;;
    esac
  }
  for run in cold warm; do
    t=$(now); native > "$WORK/native-$run.out" 2> "$WORK/native-$run.err" || { echo "the baseline run failed:" >&2; tail -n 5 "$WORK/native-$run.err" >&2; exit 1; }
    w=$(since2 "$t"); [ $run = cold ] && NATIVE_COLD=$w || NATIVE_WARM=$w
    NATIVE_DRV=$(grep -o '/nix/store/[a-z0-9]\{32\}-[^"'"'"' ]*\.drv' "$WORK/native-$run.out" | tail -n 1)
    echo "   native $run ${w}s $NATIVE_DRV" >&2
  done
  [ -n "${DPID:-}" ] && kill "$DPID" 2>/dev/null || true
  [ -n "$NAME" ] || NAME=$(basename "$NATIVE_DRV" | cut -c34-)
fi

# 4. the sandboxed planner: cold, then warm with a fresh salt
ARGS=(--impure "${NIXPKGS_I[@]}" -f "$HERE/planner.nix" --argstr mode "$MODE" --argstr evaluator "$EV" --argstr evaluatorKind "$KIND" --argstr rpcNix "$RPCP" --argstr name "$NAME" --arg jobs "$JOBS")
[ -n "$SYSTEM" ] && ARGS+=(--argstr system "$SYSTEM")
if [ "$MODE" = flake ]; then ARGS+=(--arg inputs "$WORK/inputs.json" --arg register "$WORK/register.sql" --argstr target "$ATTR")
else ARGS+=(--argstr target "$EXPR" --argstr nixpkgsPath "$NIXPKGS_ARG"); fi
declare -A PLANNER EVAL RSS READD
for run in cold warm; do
  SALT=$(date +%s%N); log=$WORK/planner-$run.log
  echo "== sandboxed planner, $run" >&2
  t=$(now)
  build "${ARGS[@]}" --argstr salt "$SALT" planner -L --no-link --print-out-paths > "$WORK/planner-$run.out" 2> "$log" \
    || { echo "the planner build failed:" >&2; grep -vE '^copying path' "$log" | grep -iE 'error|FAILED|MISMATCH|not allowed' | head -n 8 >&2; exit 1; }
  PLANNER[$run]=$(since "$t")
  m=$(grep -o 'METRIC .*' "$log" | tail -n 1); r=$(grep -o 'READD .*' "$log" | tail -n 1)
  EVAL[$run]=$(secs "$(sed -n 's/.* wall=\([^ ]*\).*/\1/p' <<<"$m")"); RSS[$run]=$(sed -n 's/.* maxrss_kb=\([^ ]*\).*/\1/p' <<<"$m"); READD[$run]=$r
  DRV=$(sed -n 's/.* drv=\([^ ]*\).*/\1/p' <<<"$m")
  echo "   planner ${PLANNER[$run]}s | in-sandbox eval ${EVAL[$run]}s, max RSS $(( ${RSS[$run]:-0} / 1024 )) MB | $r | $DRV" >&2
done
if [ -n "$CONSUMER" ]; then
  echo "== consumer (builtins.outputOf), on the warm planner" >&2
  t=$(now); build "${ARGS[@]}" --argstr salt "$SALT" consumer -L --no-link --print-out-paths > "$WORK/consumer.out" 2> "$WORK/consumer.log" \
    || { echo "the consumer build failed:" >&2; tail -n 8 "$WORK/consumer.log" >&2; exit 1; }
  CONSUMER_WALL=$(since "$t"); echo "   consumer ${CONSUMER_WALL}s: $(cat "$WORK/consumer.out")" >&2
fi

# 5. the row
same="n/a"; [ -n "$NATIVE_DRV" ] && { [ "$DRV" = "$NATIVE_DRV" ] && same=yes || same="NO ($NATIVE_DRV)"; }
objects=$(sed -n 's/READD paths=\([0-9]*\).*/\1/p' <<<"${READD[warm]}"); readd_wall=$(sed -n 's/.* wall=\([^ ]*\).*/\1/p' <<<"${READD[warm]}")
echo
echo "evaluator $EV ($MODE mode)${REMOTE_STORE:+, planner built in $REMOTE_STORE}; emitted $DRV; identical to the baseline: $same; re-added $objects objects in ${readd_wall} with $JOBS workers (warm run)${CONSUMER:+; consumer built in ${CONSUMER_WALL}s}"
echo
echo "| evaluator | cold | warm | outside sandbox baseline (cold / warm) |"
echo "|---|---|---|---|"
printf '| %s | %s s (eval %.2f s) | %s s (eval %.2f s) | %s |\n' "$(basename "$EV" | cut -c34-)" "${PLANNER[cold]}" "${EVAL[cold]}" "${PLANNER[warm]}" "${EVAL[warm]}" "${NATIVE_COLD:+$NATIVE_COLD s / $NATIVE_WARM s}"
echo
echo "logs: $WORK"
