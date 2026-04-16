# Benchmark Toolkit

This directory contains the benchmark tooling used for the qlog thesis work.

## Recommended workflow

Use the manual one-case-at-a-time helpers:

- `run_case_by_index.sh`
- `print_manual_case_commands.sh`
- `run_cases_via_ssh.sh`

They enumerate the fixed benchmark matrix and let you run one case per `RUN_ID`,
which keeps server/client coordination simple and makes qlog cleanup and storage
control straightforward. This is the preferred mode for `qlog-on-ram`.

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
$HOME/bench-results/orchestrator
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

To run cases from a separate coordination host, use:

```bash
RUN_SET_ID=thesis-main \
SERVER_SSH=jakub@84.17.61.47 \
CLIENT_SSH=jakub@89.222.113.26 \
BASE_URI=https://84.17.61.47:8443 \
CA_CERT_FILE=$HOME/bench-certs/server.crt \
bash bench/run_cases_via_ssh.sh run 1 2 3
```

You can also run ranges or the full set:

```bash
bash bench/run_cases_via_ssh.sh range 1 12
bash bench/run_cases_via_ssh.sh all
```

To inspect the indexed case table without contacting the remote hosts:

```bash
bash bench/run_cases_via_ssh.sh --list | column -ts $'\t'
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
