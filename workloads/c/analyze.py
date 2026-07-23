#!/usr/bin/env python3
"""analyze.py -- parse DARSHAN_MOFKA_TIMING stderr for throughput + per-push latency.

Usage: analyze.py <err_file> <wall_seconds>

The connector prints 'darshan-mofka[timing] <fn> <us> us' per call (darshan-mofka.c).
Health gate is NOT send-count: a dead/again broker still prints N send lines at
~0 us, so a non-zero send count proves nothing. A run is healthy only if the
initialize AND finalize timing lines are present, there are no error lines, and
the mean push cost is > 0. Exit 0 on PASS, 2 on FAIL (so a PBS loop can react).
"""
import sys, statistics as st

err, wall = sys.argv[1], float(sys.argv[2])
sends, init_us, fin_us = [], None, None
bad = 0
for ln in open(err, errors="replace"):
    if "darshan-mofka[timing] send" in ln:
        sends.append(float(ln.split()[-2]))
    elif "darshan-mofka[timing] initialize" in ln:
        init_us = float(ln.split()[-2])
    elif "darshan-mofka[timing] finalize" in ln:
        fin_us = float(ln.split()[-2])
    if any(s in ln for s in ("push failed", "flush timed out", "flush error",
                             "records will not be streamed", "darshan-mofka:")):
        bad += 1
n = len(sends)
push_mean = st.fmean(sends) if n else 0.0
p50 = st.median(sends) if n else 0.0
p99 = sorted(sends)[int(0.99 * (n - 1))] if n else 0.0
ok = (init_us is not None) and (fin_us is not None) and bad == 0 and push_mean > 0.0
print(f"HEALTH={'PASS' if ok else 'FAIL'} bad={bad} init={init_us} fin={fin_us} "
      f"n_send={n} thr_evt_s={n/wall if wall > 0 else 0:.1f} "
      f"push_mean_us={push_mean:.3f} p50={p50:.3f} p99={p99:.3f} finalize_us={fin_us}")
sys.exit(0 if ok else 2)
