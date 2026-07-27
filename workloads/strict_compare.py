#!/usr/bin/env python3
"""strict_compare.py -- STRICT comparison of reconstructed (streamed) vs native
.darshan logs. Replaces the old summed-4-op-totals rubber stamp.

Two modes (the workload class decides which; passed as argv[3]):

  perproc  (c / python-ml / dlio -- non-MPI, one process per log)
      Per-PROCESS (match logs by pid embedded in the filename), per-RECORD (match by
      darshan record id), per-COUNTER EXACT integer equality. This can be exact because
      darshan-mofka-reconstruct decodes each record's rec_hex VERBATIM into the native
      module struct (decode_hex rejects any size mismatch, darshan-mofka-reconstruct.c:437),
      so every integer counter is bit-identical to the runtime's value at the moment it was
      streamed. A difference is a real capture bug to surface, NOT to annotate.

  mpi  (mpi -- shared-file workload)
      Native MPI writes ONE shared log: all ranks are reduced to a single rank=-1 record by
      the shutdown collective reduction (darshan-core.c using_mpi path). The reconstructor
      instead emits one log per rank/pid (nprocs=1). A per-process compare is therefore the
      WRONG unit and would always MISMATCH. Instead we AGGREGATE the reconstructed per-rank
      records the same way Darshan's reduction does (posix/stdio/mpiio_record_reduction_op):
        - additive counters: sum across ranks
        - MAX_BYTE_* : max across ranks
        - assigned constants (MODE/*_ALIGNMENT): must agree across ranks, compared once
        - non-reproducible (see EXCLUDE): skipped
      then compare to native's single shared record.

Excluded counters in BOTH modes:
  * float counters (_F_*, pydarshan 'fcounters'): wall-clock times/timestamps, not
    reproducible from the stream.
  * shutdown-reduction-only integer counters *_FASTEST_RANK* / *_SLOWEST_RANK*: populated
    only by the collective reduction AFTER the last streamed op (the connector streams live
    per-op, final hook close() runs before reduction; FINAL_SWEEP disabled). Streamed
    snapshot has their pre-reduction value; only meaningful for shared MPI records anyway.
  * in mpi mode additionally: MAX_*_TIME_SIZE and STRIDE*/ACCESS* top-4 histograms -- the
    reduction merges these non-deterministically (which rank "wins" depends on timing), so
    they cannot be reproduced by aggregation. Documented, not silently dropped.

Excluded modules: HEATMAP (reconstructor rebuilds bins heuristically), DXT*, LUSTRE,
APMPI, APXC. POSIX/STDIO/MPI-IO/H5F/H5D integer counters are compared.

Exit codes: 0 = PASS, 3 = MISMATCH (real diff), 2 = load/usage/empty-native error.
"""
import os
import re
import sys

# Integer-counter modules we compare. H5F/H5D are byte-exact-reconstructable
# (expected_record_size handles them, darshan-mofka-reconstruct.c:474-475) and the runtime
# streams them (darshan-hdf5.c), so they must be compared, not silently skipped (else a
# broken HDF5 capture would false-PASS).
COMPARE_MODULES = ("POSIX", "STDIO", "MPI-IO", "H5F", "H5D")
# pydarshan spells MPI-IO with a hyphen (cffi_backend.py:59); the producer emits "MPIIO".
MODULE_ALIASES = {"MPIIO": "MPI-IO", "MPI-IO": "MPI-IO"}
# Skipped wholesale (rebuilt heuristically or not carried in the stream).
IGNORE_MODULES = {"HEATMAP", "DXT_POSIX", "DXT_MPIIO", "LUSTRE", "APMPI", "APXC"}
# Identity columns, not values.
KEY_COLS = {"id", "rank"}

# --- counter classes by shutdown-reduction semantics (posix.c:2196-2420, and the
#     analogous stdio/mpiio reduction ops). Names are exact log-format counter names. ---

# Populated ONLY by the collective reduction (after the last streamable op). Excluded in
# BOTH modes: for non-MPI single-proc logs they are 0 on both sides (no-op); for MPI shared
# records the streamed snapshot never carried the reduced value.
REDUCTION_ONLY_COUNTERS = set()
for _m in ("POSIX", "STDIO", "MPIIO"):
    for _c in ("FASTEST_RANK", "FASTEST_RANK_BYTES", "SLOWEST_RANK", "SLOWEST_RANK_BYTES"):
        REDUCTION_ONLY_COUNTERS.add("%s_%s" % (_m, _c))

# MAX across ranks in the reduction (not additive). Compared as max() in mpi mode.
MAX_COUNTERS = {"POSIX_MAX_BYTE_READ", "POSIX_MAX_BYTE_WRITTEN",
                "STDIO_MAX_BYTE_READ", "STDIO_MAX_BYTE_WRITTEN"}
# Assigned constants: identical on every rank, so the reduction just copies them. In mpi
# mode they must agree across ranks and match native; compared once.
CONST_COUNTERS = {"POSIX_MODE", "POSIX_MEM_ALIGNMENT", "POSIX_FILE_ALIGNMENT",
                  "POSIX_RENAMED_FROM"}
# Non-reproducible by aggregation in mpi mode (timing-dependent winner / top-4 merge).
# Excluded in mpi mode only (in perproc mode they're byte-exact and stay strict).
MPI_UNAGGREGATABLE = {"POSIX_MAX_READ_TIME_SIZE", "POSIX_MAX_WRITE_TIME_SIZE"}
for _i in (1, 2, 3, 4):
    for _base in ("STRIDE%d_STRIDE", "STRIDE%d_COUNT", "ACCESS%d_ACCESS", "ACCESS%d_COUNT"):
        MPI_UNAGGREGATABLE.add("POSIX_" + (_base % _i))

PID_RE = re.compile(r"id-?\d+-(\d+)_")


def die(msg, code=2):
    print("strict_compare: %s" % msg, file=sys.stderr)
    print("VERDICT: ERROR (%s)" % msg)
    sys.exit(code)


def pid_of(path):
    m = PID_RE.search(os.path.basename(path))
    return m.group(1) if m else None


def norm_mod(name):
    return MODULE_ALIASES.get(name, name)


def is_empty_std_stream(mod, name, counters):
    """Match native's stdio pruning (darshan-stdio.c): an unused <STD*> stream with no
    read/write activity. Applied to BOTH sides so a name-record that never reached the
    stream (reconstructor keeps the empty stream) doesn't cause a false 'only-reconstructed'."""
    if mod != "STDIO" or name not in ("<STDIN>", "<STDOUT>", "<STDERR>"):
        return False
    return counters.get("STDIO_READS", 0) == 0 and counters.get("STDIO_WRITES", 0) == 0


def load_log(path):
    """{module: {record_id: {counter: int}}} for one log, restricted to COMPARE_MODULES,
    integer counters only, REDUCTION_ONLY_COUNTERS removed. Also returns {record_id: name}
    so std-stream pruning can be applied by name."""
    import darshan
    out = {}
    names = {}
    with darshan.DarshanReport(path, read_all=True) as rpt:
        # name records: id -> filename (for std-stream pruning)
        try:
            for rid, nm in rpt.name_records.items():
                names[int(rid)] = nm
        except Exception:  # noqa: BLE001  -- name_records optional; pruning just won't apply
            pass
        for raw in list(rpt.modules.keys()):
            mod = norm_mod(raw)
            if mod in IGNORE_MODULES or mod not in COMPARE_MODULES:
                continue
            try:
                df = rpt.records[raw].to_df()
            except Exception as e:  # noqa: BLE001
                die("to_df failed for %s in %s: %s" % (raw, path, e))
            cdf = df.get("counters")
            if cdf is None:
                continue
            value_cols = [c for c in cdf.columns
                          if c not in KEY_COLS and c not in REDUCTION_ONLY_COUNTERS]
            recs = out.setdefault(mod, {})
            for _, row in cdf.iterrows():
                rid = int(row["id"])
                recs[rid] = {c: int(row[c]) for c in value_cols}
    # prune empty std streams on this side
    stdio = out.get("STDIO", {})
    for rid in list(stdio.keys()):
        if is_empty_std_stream("STDIO", names.get(rid, ""), stdio[rid]):
            del stdio[rid]
    return out


def load_side(dirpath):
    logs = sorted(f for f in os.listdir(dirpath) if f.endswith(".darshan"))
    side = {}
    for f in logs:
        p = os.path.join(dirpath, f)
        pid = pid_of(p) or ("_noidx_%d" % len(side))
        data = load_log(p)
        if pid in side:
            die("duplicate pid %s across logs in %s (%s)" % (pid, dirpath, f))
        side[pid] = data
    return side, logs


# ------------------------------- perproc mode -------------------------------

def compare_perproc(rec_side, nat_side):
    diffs = []
    rec_pids, nat_pids = set(rec_side), set(nat_side)
    if rec_pids == nat_pids:
        pairs = [(p, p) for p in sorted(nat_pids)]
    elif len(rec_side) == len(nat_side):
        diffs.append("NOTE: pid sets differ (rec=%s nat=%s); pairing by sorted order"
                     % (sorted(rec_pids), sorted(nat_pids)))
        pairs = list(zip(sorted(rec_side), sorted(nat_side)))
    else:
        diffs.append("FILE-COUNT MISMATCH: reconstructed=%d native=%d pids"
                     % (len(rec_side), len(nat_side)))
        return diffs
    for rpid, npid in pairs:
        rmods, nmods = rec_side[rpid], nat_side[npid]
        for mod in sorted(set(rmods) | set(nmods)):
            rrecs, nrecs = rmods.get(mod, {}), nmods.get(mod, {})
            if set(rrecs) != set(nrecs):
                diffs.append("[pid nat=%s] %s: record-id sets differ "
                             "(only-reconstructed=%s only-native=%s)"
                             % (npid, mod, sorted(set(rrecs) - set(nrecs)),
                                sorted(set(nrecs) - set(rrecs))))
            for rid in sorted(set(rrecs) & set(nrecs)):
                rc, nc = rrecs[rid], nrecs[rid]
                for c in sorted(set(rc) | set(nc)):
                    if rc.get(c) != nc.get(c):
                        diffs.append("[pid nat=%s] %s rec=%d %s: reconstructed=%s native=%s"
                                     % (npid, mod, rid, c, rc.get(c), nc.get(c)))
    return diffs


# --------------------------------- mpi mode ---------------------------------

def aggregate_reconstructed(rec_side):
    """Fold the N per-rank reconstructed logs into {module: {rid: {counter: value}}}
    mirroring Darshan's reduction: sum additive, max the MAX_* fields, and require the
    CONST_COUNTERS to agree across ranks (report a diff if not)."""
    agg = {}
    const_seen = {}   # (mod,rid,counter) -> value, to detect cross-rank disagreement
    disagreements = []
    for pid in sorted(rec_side):
        for mod, recs in rec_side[pid].items():
            amod = agg.setdefault(mod, {})
            for rid, counters in recs.items():
                arec = amod.setdefault(rid, {})
                for c, v in counters.items():
                    if c in MPI_UNAGGREGATABLE:
                        continue
                    if c in CONST_COUNTERS:
                        k = (mod, rid, c)
                        if k in const_seen and const_seen[k] != v:
                            disagreements.append(
                                "%s rec=%d %s: ranks disagree (%s vs %s)"
                                % (mod, rid, c, const_seen[k], v))
                        const_seen[k] = v
                        arec[c] = v
                    elif c in MAX_COUNTERS:
                        arec[c] = max(arec.get(c, v), v)
                    else:
                        arec[c] = arec.get(c, 0) + v
    return agg, disagreements


def compare_mpi(rec_side, nat_side):
    diffs = []
    if len(nat_side) != 1:
        diffs.append("NOTE: expected 1 native shared log for mpi, got %d" % len(nat_side))
    agg, disagreements = aggregate_reconstructed(rec_side)
    diffs.extend("[mpi] " + d for d in disagreements)
    # native shared record set (single log, rank=-1 records)
    nat = next(iter(nat_side.values())) if nat_side else {}
    for mod in sorted(set(agg) | set(nat)):
        arecs, nrecs = agg.get(mod, {}), nat.get(mod, {})
        if set(arecs) != set(nrecs):
            diffs.append("[mpi] %s: record-id sets differ "
                         "(only-reconstructed=%s only-native=%s)"
                         % (mod, sorted(set(arecs) - set(nrecs)),
                            sorted(set(nrecs) - set(arecs))))
        for rid in sorted(set(arecs) & set(nrecs)):
            ac, nc = arecs[rid], nrecs[rid]
            # compare only counters we actually aggregated (skip the ones native has but
            # we deliberately excluded as unaggregatable/reduction-only)
            for c in sorted(set(ac)):
                nv = nc.get(c)
                if c not in nc:
                    diffs.append("[mpi] %s rec=%d %s: native missing this counter" % (mod, rid, c))
                elif ac[c] != nv:
                    diffs.append("[mpi] %s rec=%d %s: aggregated=%s native=%s"
                                 % (mod, rid, c, ac[c], nv))
    return diffs


def main():
    if len(sys.argv) not in (3, 4):
        die("usage: strict_compare.py <streamed_dir> <native_dir> [perproc|mpi]")
    streamed_dir, native_dir = sys.argv[1], sys.argv[2]
    mode = sys.argv[3] if len(sys.argv) == 4 else "perproc"
    if mode not in ("perproc", "mpi"):
        die("mode must be perproc or mpi, got %r" % mode)
    for d in (streamed_dir, native_dir):
        if not os.path.isdir(d):
            die("not a directory: %s" % d)
    try:
        import darshan  # noqa: F401
    except Exception as e:  # noqa: BLE001
        die("pydarshan import failed: %s" % e)

    rec_side, rec_logs = load_side(streamed_dir)
    nat_side, nat_logs = load_side(native_dir)

    print("mode: %s" % mode)
    print("reconstructed logs: %d %s" % (len(rec_logs), rec_logs))
    print("native        logs: %d %s" % (len(nat_logs), nat_logs))
    print("modules compared (integer counters): %s" % (COMPARE_MODULES,))
    print("excluded modules: %s" % sorted(IGNORE_MODULES))
    print("excluded counters: floats(_F_) + reduction-only %s%s"
          % (sorted(REDUCTION_ONLY_COUNTERS),
             (" + mpi-unaggregatable %s" % sorted(MPI_UNAGGREGATABLE)) if mode == "mpi" else ""))

    # A run that produced no native logs is a harness failure, NOT a pass.
    if not nat_side:
        die("no native logs in %s -- cannot validate (harness/config failure)" % native_dir)
    if not rec_side:
        print("VERDICT: MISMATCH (no reconstructed logs produced from the stream)")
        sys.exit(3)

    diffs = (compare_mpi if mode == "mpi" else compare_perproc)(rec_side, nat_side)
    hard = [d for d in diffs if not d.startswith("NOTE:")]
    for d in diffs:
        print("  " + d)
    if hard:
        print("VERDICT: MISMATCH (%d difference(s) above -- each is a real capture bug to "
              "fix, not to annotate)" % len(hard))
        sys.exit(3)
    print("VERDICT: PASS (%s: every compared integer counter matches native)" % mode)
    sys.exit(0)


if __name__ == "__main__":
    main()
