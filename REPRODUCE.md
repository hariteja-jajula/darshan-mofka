# Reproduce the result

Build everything from a clean clone on LCRC/Improv and run the pipeline end to end.
It finishes with an exact check you can compare against, so you know it worked.

The native software stack (Mofka, Mochi, Bedrock) is built from source by the setup
script, so you do not need a pre-existing install.

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
not come up on login nodes). It sizes the allocation from `topology.nodes` and the
`pbs:` block in `workloads/workload.config`. Results land in
`results/<TAG>_<N>NODE_<P>PROC_<B>Broker-<placement>/RUN<n>/`; the folder name is
built from your topology, so a default single-node C run is
`results/C_1NODE_1PROC_1Broker-colocated/RUN1/`.

## What success looks like

The job output contains these lines:

```text
INGEST: PASS
modules: {'POSIX': 4, 'STDIO': 9}
VERDICT: PASS
```

And the run's `compare.txt` shows the rebuilt log matching the real one:

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

The workload is chosen by the `workload:` key in `workloads/workload.config`
(`c`, `python-ml`, or `mpi`). Set it there, then submit as above:

```yaml
workload: python-ml    # a small Python I/O workload
# workload: mpi        # MPI-IO across ranks
```

The C workload is the byte-exact reference. python-ml completes but its
reconstruction is approximate: interpreter-startup files (stdlib `.py`,
`lib-dynload/*.so`, `<STDIN>`/`<STDERR>`) are opened during the connector's
~215 ms init window, before the producer is up, so their records never reach the
stream and are missing from the rebuilt log. See RESULTS_LCRC.md for the detail.

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
