# Multi-node broker on LCRC/Improv — how Polaris did it, why SSH is the wrong path, and what I need from you

## TL;DR

The Polaris multi-node broker worked because it launched with a **scheduler-integrated
launcher (Cray PALS `mpiexec`) against a system MPI** — **no SSH anywhere**. The LCRC
attempts fail because the spack Mofka stack built **its own Open MPI 5.0.10
`--without-tm`**, whose *only* launcher is SSH between compute nodes. You're right that
we should not be using SSH inside the job at all. This doc lays out the no-SSH options
on Improv and the decision I need from you before spending more node-hours.

---

## What actually happened (evidence)

- **Last night's blocker** was `Host key verification failed`. The overnight script tried
  to fix it with `OMPI_MCA_plm_rsh_args=...` — but that's the **Open MPI 4** name. This
  stack is **Open MPI 5.0.10 / PRRTE 4.1.0**, where the launcher component was renamed
  `plm_rsh_*` → `plm_ssh_*`. So the workaround was a **silent no-op**.
- **My job today (7670136)** set the correct `PRTE_MCA_plm_ssh_args`. Result: the host-key
  error disappeared (`Permanently added 'i002.lcrc.anl.gov' to known hosts`) and revealed
  the **next** layer: `Permission denied (publickey,hostbased)` — passwordless SSH between
  compute nodes is not set up. (I did create `~/.ssh/id_ed25519` + `authorized_keys` to test
  this, but per your steer we should abandon the SSH route — say the word and I'll remove them.)
- **Part B still passed** on a single-node broker (partition-count curve):
  1p → 37.8 µs/push, 2p → 36.2 µs/push, 4p → 91.6 µs/push (13 sends each). Consistent with
  Polaris's numbers. Only **Part A (multi-node)** is blocked.

## Why Polaris worked and Improv doesn't

| | Polaris (works) | LCRC/Improv (blocked) |
|---|---|---|
| MPI bedrock links | **system cray-mpich** 8.1.28 | **spack-built Open MPI 5.0.10** |
| Launcher | **system PALS `mpiexec`** (ALPS/PBS-integrated) | spack `mpirun` (PRRTE) |
| Remote spawn | scheduler, **no SSH** | **SSH only** (`--without-tm` in the build) |

The spack openmpi configure line (confirmed) contains: `--without-tm --without-slurm
--without-ofi --without-verbs`. So it cannot use a PBS-native launcher — it falls back to
SSH by construction. That is the whole problem.

## No-SSH options on Improv (all confirmed available)

Improv provides `pbsdsh` (`/opt/pbs/bin/pbsdsh`, PBS-native, no SSH) and PBS-integrated
system MPI modules: `openmpi/4.1.8`, `openmpi/5.0.7/gcc/14.2.0`, `hpcx/2.26`,
`intel-oneapi-mpi/2021.15`.

1. **Rebuild the spack Open MPI with `schedulers=tm`** (mirror-the-current-stack fix).
   - Pro: bedrock keeps linking the same MPI; `mpirun` then uses the PBS `tm` launcher — no
     SSH. Smallest *conceptual* change; the group-bootstrap code is unchanged.
   - Con: a spack rebuild of openmpi + anything that links it (the Mochi/Mofka stack may
     relink). ~login-node build time; no node-hours. One-line spack spec change
     (`openmpi ... schedulers=tm fabrics=...`).

2. **Build/point the Mofka stack at a system MPI module** (the true Polaris analogue).
   - Pro: exactly what Polaris does — system, scheduler-integrated MPI + its `mpirun`. Most
     "correct" for the site.
   - Con: biggest change — add the system openmpi as a spack `external` (or `develop` the
     mochi stack against it) and re-concretize. Higher risk of ABI/dep churn.

3. **Drop MPI bootstrap entirely; launch one bedrock per node with `pbsdsh` + a non-MPI
   flock bootstrap** (join by group file / known address).
   - Pro: no MPI launcher at all, no SSH, PBS-native.
   - Con: needs flock to support a non-MPI multi-node bootstrap (each bedrock joins an
     existing group rather than forming it via `MPI_COMM_WORLD`). I need to confirm flock
     exposes this; if it does, it's arguably the cleanest and most portable.

## What I need from you

1. **Which approach?** My recommendation: **(1) rebuild spack openmpi `schedulers=tm`**
   first — it's the minimal change that removes SSH while keeping everything else identical,
   and it's a free login-node rebuild. Fall back to (3) if you want zero MPI, or (2) if you
   want the full Polaris-style system-MPI setup.
2. **Is a spack rebuild of openmpi (and any relinked mochi deps) acceptable tonight?** It
   costs build time but no node-hours.
3. **Site policy check (you'd know better):** is there a preferred/blessed way to run
   multi-node MPI jobs on Improv (a specific module + `mpiexec` flags)? If the site has a
   canonical recipe, I'll just use it instead of guessing.
4. **Remove the SSH key I created for the abandoned test?** (`~/.ssh/id_ed25519` +
   `authorized_keys`.) Default: I'll remove it unless you want to keep SSH as a fallback.

Once you pick, I'll make the minimal change, resubmit a 2-node debug job, and get the real
multi-node broker + INGEST result (like Polaris Arm 3).
