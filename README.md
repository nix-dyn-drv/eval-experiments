# Evaluation as a dynamic derivation

Run a Nix evaluator *inside a build* and hand the derivation graph it produces back to the outer
store, with no changes to the Nix daemon. This repository holds the planner, the harness and the
examples behind the blog post *Dynamic Derivations Enable Custom and Remote Evaluators*, so you can
reproduce its tables on your own flake, with your own evaluator, and on your own remote builders.

## How it works

The *planner* is a text-hashed, content-addressed derivation that requires the `builder-rpc-v0`
system feature. Nix opens a limited daemon socket inside its sandbox (`NIX_REMOTE` points at it) that
accepts store additions and `SubmitOutput`, but no queries of the outer store. Inside the sandbox the
builder:

1. opens a private store whose directory is the sandbox's own `/nix/store` (sqlite state under
   `$TMPDIR`), and registers the input trees the sandbox mounted as valid, with their real hashes for
   the flake inputs, so nothing is copied;
2. runs the evaluator against that store (`nix eval --offline` with every flake input pinned to a store
   path, or `nix-instantiate`, `iets`, `fix` for an expression);
3. walks the emitted derivation's closure, references first, and re-adds every object into the outer
   store through the socket with the operations it already allows: `nix store add` for sources,
   `nix derivation add` for derivations (`readd.py`, one `nix` process per object, one dependency
   level at a time in parallel);
4. submits the top-level derivation with `nix store submit-output`.

A *consumer* derivation depends on the result through `builtins.outputOf`, so the target is never
evaluated outside a build. Because the planner is an ordinary derivation, it is dispatched like any
other build: with `builders = …` it runs on a remote builder and the graph lands in that builder's
store.

## Requirements

- Nix >= 2.36 as the client (`nix store submit-output` and `nix derivation add` exist from 2.36), with
  `experimental-features = nix-command flakes ca-derivations dynamic-derivations`. The harness passes
  the features on the command line, but a daemon you build through needs them in its own `nix.conf`.
- The builder (local daemon or remote machine) on Nix >= 2.36 or Determinate Nix >= 3.24 with the same
  features and `sandbox = true`.
- A nixpkgs with `nixVersions.latest` >= 2.36 (nixos-unstable), or `--rpc-nix /nix/store/…-nix-2.36.x`
  for the in-sandbox client.

## Quick start

```sh
git clone https://github.com/nix-dyn-drv/eval-experiments
cd eval-experiments
./run.sh --flake ./examples/hello#packages.x86_64-linux.hello
```

For your own flake, give the harness a flake reference and a full attribute path:

```sh
./run.sh --flake github:you/your-flake#packages.x86_64-linux.default
./run.sh --flake /path/to/checkout#checks.x86_64-linux.integration --evaluator lix --jobs 16
```

The harness pins every locked input of the flake to a store path (`prepare-inputs.py`), runs the
evaluator outside the sandbox twice as the baseline (cold, then warm; eval cache off), builds the
planner twice (cold, then warm with a fresh salt), builds the consumer, checks that the sandboxed run
emitted the same derivation path as the baseline, and prints one row of the table:

```
| evaluator | cold | warm | outside sandbox baseline (cold / warm) |
|---|---|---|---|
| nix-2.36.0 | 7.8 s (eval 0.54 s) | 7.4 s (eval 0.55 s) | 0.50 s / 0.31 s |
```

`cold` and `warm` are the whole planner build (registration, evaluation, re-add, submit); the
evaluation alone is in parentheses. Logs and the pinned inputs land under `work/<stamp>/`.

### Expression mode

`nix-instantiate`-style evaluators take an expression and a nixpkgs tree instead of a flake. This is
the mode for evaluators without flake support, such as [iets](https://github.com/numtide/iets) and
[fix](https://github.com/zimbatm/fix); they are run against a private `nix daemon` inside the sandbox.

```sh
./run.sh --expr 'with import <nixpkgs> { }; hello' --nixpkgs /nix/store/…-source --evaluator nix
./run.sh --expr 'with import <nixpkgs> { }; hello' --nixpkgs /nix/store/…-source --evaluator /nix/store/…-iets-0.2.0 --kind iets
```

### Remote building

The planner is an ordinary derivation, so your normal `builders` configuration dispatches it, provided
the machine advertises the `builder-rpc-v0` and `ca-derivations` features (the planner is a
content-addressed derivation, so Nix requires both). `BUILD_OPTS` applies to the planner and consumer
builds only; the input preparation and the baseline stay local:

```sh
BUILD_OPTS="--builders 'ssh-ng://builder x86_64-linux - 8 1 builder-rpc-v0,ca-derivations' --max-jobs 0" \
  ./run.sh --flake ./examples/hello#packages.x86_64-linux.hello
```

This works as long as the evaluated graph already exists in your local store (for example because a
baseline run put it there). When it does not, the build fails after the planner succeeded on the
builder, with `store path '…-something.drv' does not exist`: `build-remote` copies only the output
paths of a remote build back to the local store (`src/nix/build-remote/build-remote.cc`, `copyPaths`
of the missing outputs), and the planner's output is a `.drv` whose references, the rest of the
graph, were created on the builder and exist nowhere else. Ordinary derivations never hit this,
because their outputs only reference inputs the client already had. Until `build-remote` copies the
closure of an output back, use the builder's store directly for the planner and consumer builds,
with your local store as the evaluation store; the graph then stays on the builder and the consumer
builds there:

```sh
REMOTE_STORE="ssh-ng://builder" ./run.sh --flake ./examples/hello#packages.x86_64-linux.hello
```

In both forms the cold run includes copying the evaluator's closure, the flake inputs and the
planner's tools to the builder; the warm run copies nothing. For the baseline on the builder itself,
run the same evaluator natively on that machine. The builder must run Nix >= 2.36 or Determinate Nix
>= 3.24 (for a Determinate builder, `ssh-ng://builder?remote-program=/bin/nix-daemon&remote-store=daemon`).

### Choosing the evaluator

`--evaluator` takes a nixpkgs attribute (`nixVersions.latest`, `nix`, `lix`, …) or a store path. Flake
mode needs an evaluator with `nix eval`, flakes and `--override-input` (Nix, Lix, Determinate Nix);
expression mode works with anything that prints a derivation path for `-E` (`--kind` picks the command
line when the harness cannot tell from `bin/`). Evaluators that only print a path and never write a
derivation into a store (brix, snix, gonix) cannot hand a graph over with this method.

## Environment

| variable | meaning |
|---|---|
| `NIX` | the nix binary for the outer builds and the input preparation (default `nix`) |
| `NIX_OPTS` | options for every nix call, for example `--store local?root=/tmp/s` for a private outer store |
| `BUILD_OPTS` | options for the planner and consumer builds only, for example `--builders … --max-jobs 0` |
| `REMOTE_STORE` | build the planner and consumer in this store (`ssh-ng://builder`), with the local store as the eval store |
| `NIXPKGS` | the nixpkgs tree `planner.nix` takes its tools from (default: the flake's `nixpkgs` input, else `<nixpkgs>`) |

## Layout

- `planner.nix` — the planner and consumer derivations (`nix build --impure -f planner.nix planner --argstr …` works without the harness).
- `readd.py` — the level-parallel re-add walk over the limited socket.
- `prepare-inputs.py` — pins a flake's inputs to store paths and writes the registration rows.
- `run.sh` — the harness that produces a table row.
- `examples/hello` — a small flake to start from.

## Caveats

- The re-add walk is the naive cost of the method: ~60 ms of process spawn per object. A client that
  kept one connection open for the whole closure would collapse it; this repository leaves it naive on
  purpose so the cost is visible. `--jobs` only parallelises within a dependency level.
- `nix derivation add` reads input derivations from the filesystem, which is why the private store has
  to live in the sandbox's `/nix/store` rather than in a scratch directory.
- The submitted output must carry the emitted derivation's name; the harness takes it from the baseline
  run, so `--no-native` needs `--name`.
- `fix`'s client cannot open a unix socket path longer than 108 bytes; the harness keeps the socket
  paths short.
