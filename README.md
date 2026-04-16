# Benchmark Toolkit

This repo contains the benchmark tooling used for the qlog thesis work.

## Recommended workflow

Use the manual one-case-at-a-time helpers:

- `run_case_by_index.sh`
- `print_manual_case_commands.sh`
- `run_cases_via_ssh.sh`

They enumerate the fixed benchmark matrix and let you run one case per `RUN_ID`,
which keeps server/client coordination simple and makes qlog cleanup and storage
control straightforward. This is the preferred mode for the RAM-backed qlog scenarios.

The current workload matrix contains two workloads:

- `small` (`16k.bin`, `m=1`)
- `bulk` (`1m.bin`, `m=1`)

If you have a third coordination machine, `run_cases_via_ssh.sh` can drive the
same indexed cases over SSH and keep a local manifest with per-case server and
client logs.

Low-level execution helpers:

- `run_server_measurement.sh`
- `run_h2load_matrix.sh`

Shared setup and analysis:

- `prepare_benchmark_vm.sh`
- `install_nginx_variants.sh`
- `generate_benchmark_configs.sh`
- `summarize_results.py`
- `plot_results.py`

## Result locations

Client-side results now default to:

```text
$HOME/bench-results/client
```

Server-side results still default to:

```text
$HOME/opt/nginx-bench/results/server
```

This keeps raw benchmark output out of the repo by default.

The SSH orchestrator keeps its own local metadata under:

```text
$PWD/results/orchestrator
```

## Manual case execution

`run_case_by_index.sh` is intended to be run on both VMs with the same case
index and the same `RUN_SET_ID`. A typical flow is:

```bash
RUN_SET_ID=thesis-main bench/run_case_by_index.sh server 17
RUN_SET_ID=thesis-main BASE_URI=https://84.17.61.47:8443 \
  CA_CERT_FILE=$HOME/bench-certs/server.crt \
  bench/run_case_by_index.sh client 17
```

If you prefer to keep a text checklist of all commands, use:

```bash
RUN_SET_ID=thesis-main bench/print_manual_case_commands.sh > manual-cases.txt
```

## Third-machine orchestration

A third machine can coordinate the benchmark over SSH while keeping the raw
server and client results on their respective VMs. This is the recommended
workflow when you do not want to start each side manually.

### 1. Prepare the server VM

The server VM typically has two separate checkouts:

- `"$HOME/nginx-qlog"`: the nginx source repository with the qlog branches
- `"$HOME/nginx-qlog-benchmark"`: this benchmark/orchestration repository

Clone both:

```bash
git clone <nginx-qlog-repo-url> "$HOME/nginx-qlog"
git clone <benchmark-repo-url> "$HOME/nginx-qlog-benchmark"
```

Do the one-time benchmark host setup from the benchmark repo:

```bash
cd "$HOME/nginx-qlog-benchmark"
sudo bash bench/prepare_benchmark_vm.sh
```

Build the nginx variants from inside the nginx source repo, invoking the script
from the benchmark repo:

```bash
cd "$HOME/nginx-qlog"
bash ../nginx-qlog-benchmark/bench/install_nginx_variants.sh
```

Then generate the benchmark configs from the benchmark repo:

```bash
cd "$HOME/nginx-qlog-benchmark"
bash bench/generate_benchmark_configs.sh
```

Confirm the generated server certificate exists. The client VM will need a copy
of this certificate:

```bash
ls -l "$HOME/opt/nginx-bench/certs/server.crt"
```

Optional quick checks on the server VM:

```bash
findmnt /mnt/qlog-ram
cd "$HOME/nginx-qlog-benchmark"
bash bench/run_case_by_index.sh --list | sed -n '1,12p'
```

### 2. Prepare the client VM

The client VM typically only needs the benchmark repo checkout used by the
orchestrator and runner scripts:

```bash
git clone <benchmark-repo-url> "$HOME/nginx-qlog-benchmark"
cd "$HOME/nginx-qlog-benchmark"
```

Install the client-side benchmark helper packages and make sure `h2load` is
available as `h2load` or via `H2LOAD_BIN`. In the standard setup the helper
packages are installed with:

```bash
sudo bash bench/prepare_benchmark_vm.sh
```

Then verify the actual load generator is present:

```bash
h2load --version
```

Copy the server certificate from the server VM onto the client VM. The
orchestrator passes `CA_CERT_FILE` to the client over SSH, so this path must be
valid on the client VM, not on the third machine:

```bash
mkdir -p "$HOME/bench-certs"
scp user@server:"$HOME/opt/nginx-bench/certs/server.crt" "$HOME/bench-certs/server.crt"
```

Optional quick checks on the client VM:

```bash
ls -l "$HOME/bench-certs/server.crt"
h2load --version
bash bench/run_case_by_index.sh --list | sed -n '1,12p'
```

### 3. Prepare the third machine

Clone this benchmark repo on the coordinator machine. It does not need the
`nginx-qlog` source repo unless you also want to build there:

```bash
git clone <benchmark-repo-url> "$HOME/nginx-qlog-benchmark"
cd "$HOME/nginx-qlog-benchmark"
```

By default, the orchestrator writes its own local manifest and SSH logs under
the current working directory, so running it from the repo root keeps that
metadata in this repo under `results/orchestrator`:

```text
$PWD/results/orchestrator
```

Make sure SSH access works in both directions before starting a run:

```bash
ssh user@server 'hostname && test -d "$HOME/nginx-qlog" && test -d "$HOME/nginx-qlog-benchmark"'
ssh user@client 'hostname && test -d "$HOME/nginx-qlog-benchmark"'
```

List the indexed benchmark matrix locally:

```bash
bash bench/run_cases_via_ssh.sh --list | column -ts $'\t'
```

### 4. Run the orchestrator

Start with a small case subset first:

```bash
cd "$HOME/nginx-qlog-benchmark"
RUN_SET_ID=thesis-main \
SERVER_SSH=user@84.17.61.47 \
CLIENT_SSH=user@89.222.113.26 \
BASE_URI=https://84.17.61.47:8443 \
CA_CERT_FILE=/home/user/bench-certs/server.crt \
bash bench/run_cases_via_ssh.sh run 1 2 3
```

The important detail is that `CA_CERT_FILE` above is a path on the client VM.
Do not pass a coordinator-local path like `/Users/...`.

Once the small smoke test passes, run a range or the full matrix:

```bash
cd "$HOME/nginx-qlog-benchmark"
RUN_SET_ID=thesis-main \
SERVER_SSH=user@84.17.61.47 \
CLIENT_SSH=user@89.222.113.26 \
BASE_URI=https://84.17.61.47:8443 \
CA_CERT_FILE=/home/user/bench-certs/server.crt \
bash bench/run_cases_via_ssh.sh range 1 12

RUN_SET_ID=thesis-main \
SERVER_SSH=user@84.17.61.47 \
CLIENT_SSH=user@89.222.113.26 \
BASE_URI=https://84.17.61.47:8443 \
CA_CERT_FILE=/home/user/bench-certs/server.crt \
bash bench/run_cases_via_ssh.sh all
```

Useful overrides while iterating:

- `SERVER_REPO_DIR` and `CLIENT_REPO_DIR` if the remote benchmark repo clones are not at `$HOME/nginx-qlog-benchmark`
- `SERVER_RESULTS_ROOT` if you changed the server result root from `$HOME/opt/nginx-bench/results/server`
- `CLIENT_RESULTS_ROOT` if you changed the client result root from `$HOME/bench-results/client`
- `STOP_ON_FAILURE=0` if you want the orchestrator to continue after a failed case
- `BETWEEN_CASE_DELAY=<seconds>` if you want a pause between cases

The coordinator writes only orchestration metadata and SSH logs under:

```text
$PWD/results/orchestrator/run_sets/$RUN_SET_ID
```

The key file there is:

`$PWD/results/orchestrator/run_sets/$RUN_SET_ID/manifest.tsv`

### 5. Collect the results onto the third machine

The orchestrator does not automatically copy raw benchmark data back from the
VMs. After the run, collect the server and client result trees onto the third
machine into a combined root such as `$HOME/bench-results`:

```bash
mkdir -p "$HOME/bench-results/server" "$HOME/bench-results/client"

rsync -av user@84.17.61.47:"$HOME/opt/nginx-bench/results/server/" "$HOME/bench-results/server/"
rsync -av user@89.222.113.26:"$HOME/bench-results/client/" "$HOME/bench-results/client/"
```

The orchestrator metadata is already local on the third machine because that is
where `run_cases_via_ssh.sh` was executed. You should already have:

```text
$PWD/results/orchestrator
```

At that point the third machine has:

```text
$HOME/bench-results/server
$HOME/bench-results/client
$PWD/results/orchestrator
```

Only `server` and `client` need to be under `BENCH_RESULTS_DIR` for the
analysis scripts. The orchestrator manifest and SSH logs stay separate.

### 6. Analyze the collected results

Run the analysis scripts on the third machine against the merged external
results root:

```bash
cd "$HOME/nginx-qlog-benchmark"
BENCH_RESULTS_DIR=$HOME/bench-results python3 bench/summarize_results.py
BENCH_RESULTS_DIR=$HOME/bench-results python3 bench/plot_results.py
```

The generated summaries will be written under:

```text
$HOME/bench-results/analysis
```

## Analysis

The analysis scripts can still process a checked-in `results/` tree in the repo.
If you keep results elsewhere, point them at the external root:

```bash
BENCH_RESULTS_DIR=$HOME/bench-results python3 bench/summarize_results.py
BENCH_RESULTS_DIR=$HOME/bench-results python3 bench/plot_results.py
```

The default analysis baseline is the upstream `master` variant. Normalized
comparison tables and plots are therefore expressed relative to `master`,
while `qlog-off` remains available in the summaries as a secondary comparison.
