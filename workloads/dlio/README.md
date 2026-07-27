# workloads/dlio/ -- DLIO benchmark workload

Run [DLIO](https://github.com/argonne-lcf/dlio_benchmark) under the Darshan-Mofka connector to
exercise the POSIX path with a realistic deep-learning I/O benchmark. DLIO is wired into the harness
(`WORKLOAD=dlio`) but needs a dedicated Python venv because its dependency set does not resolve
against the main stack's Python. Status and the exact working recipe are below.

## Status

- **Integrated + streaming: yes.** With the venv below, `WORKLOAD=dlio` runs through
  `submit.sh`/`job.sh`, DLIO generates its dataset, and its POSIX I/O is captured by the LD_PRELOAD
  connector and streamed to Mofka (thousands of events, no attach errors, no backpressure).
- **Clean end-to-end in a short smoke: not guaranteed.** DLIO's TF-based startup + dataset
  generation is slow (generation is CPU-bound) and the connector's finalize flush can time out on
  DLIO's end-of-run event pattern, so short (15-30 min) smokes may be killed at walltime before the
  drain/reconstruct/compare step. Give it a generous walltime (>=1 h) and/or a small dataset.
- DLIO is Python-based, so it is expected to show the same interpreter init-window fidelity gap as
  python-ml (strict compare MISMATCH on the pre-attach records), not byte-exact. That gap is a real
  capture limitation and the strict validator surfaces it deliberately (do not suppress it).

## Build the DLIO venv (one-time)

DLIO 2.0.0's PyPI deps hard-require `nvidia-dali-cuda110` (GPU-only) and `torch*`; its pinned
`pydftracer==1.0.2` bundles a `gotcha` CMake project that modern CMake rejects. On a CPU node the
working recipe is an isolated **Python 3.11** venv, `--no-deps` DLIO, `tensorflow-cpu` (DLIO
hard-imports TF via its profiler factory; torch/DALI stay lazy and are avoided by using the
`tensorflow` data loader), and the CMake-policy env var to build `pydftracer`.

**Polaris** (this port) uses `cray-python/3.11.7`:

```bash
module load cray-python/3.11.7
python3.11 -m venv install/_dlio_venv
install/_dlio_venv/bin/pip install --upgrade pip
# pydftracer's bundled gotcha needs the pre-3.5 CMake policy shim:
CMAKE_POLICY_VERSION_MINIMUM=3.5 install/_dlio_venv/bin/pip install "pydftracer==1.0.2"
install/_dlio_venv/bin/pip install --no-deps dlio_benchmark
install/_dlio_venv/bin/pip install numpy h5py mpi4py hydra-core omegaconf pandas pyyaml pillow psutil tensorflow-cpu
```

(On LCRC/Improv the only change is `module load python/3.11.6` instead of `cray-python/3.11.7`.)

The `dlio)` case in `workloads/job.sh` invokes `install/_dlio_venv/bin/dlio_benchmark` (generate_data
only, `framework=tensorflow`, `data_loader=tensorflow`, `format=npz`, `num_files_train=$EVENTS`).
mpi4py needs a system `libmpi` on `LD_LIBRARY_PATH`; the harness's launcher path provides it via
`env/workload.sh`, so DLIO always runs through the launcher (not the single-rank fast path -- the
fast-path guard in job.sh excludes `dlio`).

**Polaris note (mpi4py ABI):** the pip `mpi4py` is built against the MPICH ABI and dlopens
`libmpi.so.12`. cray-mpich's normal `lib/` ships `libmpi_gnu_123.so.12` (Cray-mangled soname), NOT
`libmpi.so.12` -- that ABI soname lives only under `$MPICH_DIR/lib-abi-mpich` (the `cray-mpich-abi`
module's dir). Without it, `from mpi4py import MPI` fails `libmpi.so.12: cannot open shared object
file`. `env/workload.sh` prepends `$MPICH_DIR/lib-abi-mpich` (module-derived) on the polaris profile
so DLIO's mpi4py binds cray-mpich at runtime. No extra module load needed.

## Run

```bash
# needs the venv above; give generous walltime (DLIO/TF startup + generation are slow)
PBS_ACCOUNT=<acct> QUEUE=debug WALLTIME=01:00:00 SKIP_BUILD=1 \
  WORKLOAD=dlio NODES=2 TASKS=4 PARTITIONS=4 CONSUMERS=4 EVENTS=8 bash submit.sh
```

## Verify

The run's strict compare (`workloads/strict_compare.py`, perproc mode) runs automatically. To
inspect the raw stream:

```bash
EVENTS_JSONL=results/DLIO_*/RUN*/events.jsonl
grep '"module":"POSIX"' "$EVENTS_JSONL" | head
grep -Ei '"op":"(open|read|write|close)"' "$EVENTS_JSONL" | head
```
