# Reproduce the result

This walks you through building everything from a clean clone on LCRC/Improv and
running the demo end to end. It ends with an exact check you can compare against,
so you know it worked.

The whole native software stack (Mofka, Mochi, Bedrock) is built from source by
the setup script, so you do not need any pre-existing install.

## Steps

```bash
git clone https://github.com/hariteja-jajula/darshan-mofka.git
cd darshan-mofka
git submodule update --init --recursive

# Build the stack, MongoDB, the Python consumer, and the Darshan connector.
# Run this on a LOGIN node (it needs internet). It takes a while the first time
# because it compiles the full Mofka stack.
DARSHAN_MOFKA_PROFILE=lcrc bash install/setup.sh

# Run the pipeline on a COMPUTE node and check it.
PBS_ACCOUNT=<your_project> bash submit.sh
```

`submit.sh` sends the job to a compute node (the broker's network transport does
not come up on login nodes). When it finishes, look in `results/` for the newest
`c_<timestamp>/` folder.

## What success looks like

The job output contains these lines:

```text
INGEST: PASS
modules: {'POSIX': 4, 'STDIO': 9}
VERDICT: PASS
```

And `results/c_<timestamp>/compare.txt` shows the rebuilt log matching the real one:

```text
reconstructed modules: ['POSIX', 'STDIO']  op-totals: {'READS': 2, 'WRITES': 3, 'OPENS': 3}
native        modules: ['POSIX', 'STDIO']  op-totals: {'READS': 2, 'WRITES': 3, 'OPENS': 3}
VERDICT: PASS
```

`VERDICT: PASS` means the log rebuilt from the Mofka stream has the same modules
and the same open/read/write counts as the real Darshan log. Small differences are
expected and allowed: the mount label (`unknown` vs `rootfs`), timestamps, the pid,
and the synthetic job/exe metadata.

## Other workloads

```bash
PBS_ACCOUNT=<your_project> bash submit.sh python-ml     # a Python I/O workload
PBS_ACCOUNT=<your_project> bash submit.sh mpi           # MPI-IO across ranks
```

## If you already have the Mofka stack

If a working Mofka stack is already on the machine, setup reuses it instead of
building a new one, and everything above still applies. On LCRC the environment
scripts look for a repo-local build first (`install/_spack`) and fall back to an
existing one if present.

## Notes for this cluster

Two small things were needed to build the stack from scratch on an LCRC login node,
and the setup script already handles both:

- Mercury is built without its shared-memory plugin (`~sm`), because the login
  node's ptrace setting blocks the shared-memory self-test.
- Spack fetches sources with `curl`, because the login node's Python cannot verify
  the TLS certificate of some GNU mirrors. Source integrity is still checked by
  SHA-256.
