# workloads/dlio/ -- DLIO benchmark workload

Run [DLIO](https://github.com/argonne-lcf/dlio_benchmark) under the Darshan-Mofka connector to
exercise the POSIX path with a realistic deep-learning I/O benchmark. DLIO is wired into the harness
(`WORKLOAD=dlio`), but it needs a dedicated Python venv because its dependency set does not resolve
against the main stack's Python 3.14. Status and the exact working recipe are below.

## Status (2026-07-26)

- **Integrated + streaming: yes.** With the venv below, `WORKLOAD=dlio` runs through
  `submit.sh`/`job.sh`, DLIO generates its dataset, and its POSIX I/O is captured by the LD_PRELOAD
  connector and streamed to Mofka over verbs (thousands of events observed, ~23-150 us/push, no
  attach errors, no backpressure).
- **Clean end-to-end (INGEST/VERDICT) in a short smoke: not yet.** DLIO's TF-based startup +
  dataset generation is slow (observed I/O-event rate ~5/s; generation is CPU-bound), and the
  connector's finalize flush times out (30 s) on DLIO's end-of-run event pattern, so 2-node smokes
  were killed at walltime (15-30 min) before the drain/reconstruct/INGEST step. It needs a generous
  walltime (>=1 h) and/or a smaller dataset; a 512-rank scale run is impractical because every rank
  pays the TensorFlow import. The 512-producer *scale* is already demonstrated by the
  C/python-ml/MPI workloads (see `docs/scaling/REPORT.md`).
- DLIO is Python-based, so it is expected to show the same interpreter init-window fidelity gap as
  python-ml (VERDICT MISMATCH), not byte-exact.

## Build the DLIO venv (one-time)

DLIO 2.0.0's PyPI deps hard-require `nvidia-dali-cuda110` (GPU-only) and `torch*`; its pinned
`pydftracer==1.0.2` bundles a `gotcha` CMake project that modern CMake rejects. On Improv (CPU,
no GPU) the working recipe is an isolated **Python 3.11** venv, `--no-deps` DLIO, `tensorflow-cpu`
(DLIO hard-imports TF via its profiler factory; torch/DALI stay lazy and are avoided by using the
`tensorflow` data loader), and the CMake-policy env var to build `pydftracer`:

```bash
module load python/3.11.6
python3.11 -m venv install/_dlio_venv
install/_dlio_venv/bin/pip install --upgrade pip
# pydftracer's bundled gotcha needs the pre-3.5 CMake policy shim:
CMAKE_POLICY_VERSION_MINIMUM=3.5 install/_dlio_venv/bin/pip install "pydftracer==1.0.2"
install/_dlio_venv/bin/pip install --no-deps dlio_benchmark
install/_dlio_venv/bin/pip install numpy h5py mpi4py hydra-core omegaconf pandas pyyaml pillow psutil tensorflow-cpu
```

The `dlio)` case in `workloads/job.sh` invokes `install/_dlio_venv/bin/dlio_benchmark` (generate_data
only, `framework=tensorflow`, `data_loader=tensorflow`, `format=npz`, `num_files_train=$EVENTS`).
mpi4py needs a system `libmpi` on `LD_LIBRARY_PATH`; the harness's mpirun path provides it via
`env/workload.sh`, so DLIO always runs through the launcher path (not the single-rank fast path).

## Run

```bash
# needs the venv above; give generous walltime (DLIO/TF startup + generation are slow)
PBS_ACCOUNT=<acct> QUEUE=debug WALLTIME=01:00:00 SKIP_BUILD=1 \
  WORKLOAD=dlio NODES=2 TASKS=4 PARTITIONS=4 CONSUMERS=4 EVENTS=8 bash submit.sh
```

## Verify

Point `EVENTS_JSONL` at the DLIO run's file and inspect it:

```bash
EVENTS_JSONL=results/DLIO_*/RUN*/events.jsonl
grep '"module":"POSIX"' "$EVENTS_JSONL" | head
grep -Ei '"op":"(open|read|write|close)"' "$EVENTS_JSONL" | head
```
