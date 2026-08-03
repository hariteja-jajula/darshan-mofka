#!/bin/bash
# cpu_probe.sh -- run a command and measure, over a FIXED wall-clock STEADY-STATE window,
# the CPU used by all threads vs the main thread:
#   cpu_self   = CPU seconds by ALL threads      (utime+stime, /proc/<pid>/stat)
#   cpu_thread = CPU seconds by the MAIN thread   (/proc/<pid>/task/<pid>/stat)
# Busy-poll signature:  cpu_self ~= 2*cpu_thread  (a full extra core burned by the progress
# thread). Yielding/asleep progress thread:  cpu_self ~= cpu_thread.
#
# Design goals (learned the hard way):
#  - DO NOT depend on stdout markers (python block-buffers through a pipe -> markers lost).
#  - DO NOT wait for clean exit (mercury/margo teardown can hang at atexit).
# Instead: let the workload get going (WARMUP), sample CPU deltas over WINDOW seconds, then
# KILL the pid (SIGTERM, then SIGKILL) so the arm always terminates regardless of teardown.
#
# Usage: cpu_probe.sh <tag> <warmup_s> <window_s> -- <command...>
# Prints: CPU_PROBE tag=<tag> wall=<window_s> cpu_self=<s> cpu_thread=<s> ratio=<self/thread> cpupct_self=<%> rc=<n>
set -uo pipefail

TAG="${1:?tag}"; shift
WARMUP="${1:?warmup_s}"; shift
WINDOW="${1:?window_s}"; shift
[ "${1:-}" = "--" ] && shift || { echo "cpu_probe: expected -- before command" >&2; exit 2; }

CLK=$(getconf CLK_TCK 2>/dev/null || echo 100)

read_cpu() {  # $1 = stat file -> echoes utime+stime (ticks)
    local line
    line=$(cat "$1" 2>/dev/null) || return 1
    line="${line#*) }"                 # drop "pid (comm) "
    # shellcheck disable=SC2086
    set -- $line
    local u="${12}" s="${13}"
    [ -n "$u" ] && [ -n "$s" ] && echo $(( u + s )) || return 1
}

alive() { kill -0 "$PID" 2>/dev/null; }

# launch in a fresh session/process group so we can kill the whole tree even if the
# workload forks or wedges (setsid makes the child a group leader; -PID hits the group).
setsid "$@" &
PID=$!
SELF="/proc/$PID/stat"; THR="/proc/$PID/task/$PID/stat"
# put the child in its own process group so we can signal the whole tree (setsid via
# the launch below); PID is the group leader, so -PID targets the group.

# --- warmup: let the process spin up (and the progress thread start) ---
w=0
while [ "$w" -lt "$WARMUP" ] && alive; do sleep 1; w=$((w+1)); done

if ! alive; then
    echo "CPU_PROBE tag=$TAG wall=0 cpu_self=0 cpu_thread=0 ratio=na cpupct_self=na rc=early_exit"
    wait "$PID" 2>/dev/null; exit 0
fi

# --- sample the steady-state window ---
s0=$(read_cpu "$SELF"  || echo 0)
t0=$(read_cpu "$THR"   || echo 0)
win=0
while [ "$win" -lt "$WINDOW" ] && alive; do sleep 1; win=$((win+1)); done
s1=$(read_cpu "$SELF"  || echo "$s0")
t1=$(read_cpu "$THR"   || echo "$t0")

# --- terminate (teardown may hang; NEVER block on wait) ---
# The workload can wedge in margo/mercury internals where even SIGKILL is slow to reap
# and a blocking `wait` would stall the whole run. Kill the process GROUP (the launched
# child may fork the real workload), then bounded-poll for death and move on regardless.
kill -TERM -"$PID" 2>/dev/null || kill -TERM "$PID" 2>/dev/null
g=0; while [ "$g" -lt 4 ] && alive; do sleep 1; g=$((g+1)); done
if alive; then
    kill -KILL -"$PID" 2>/dev/null || kill -KILL "$PID" 2>/dev/null
    g=0; while [ "$g" -lt 6 ] && alive; do sleep 1; g=$((g+1)); done
fi
if alive; then
    rc=wedged_uninterruptible   # stuck in D-state / margo internals; report and continue
else
    rc=killed
fi

cs=$(awk -v a="$s0" -v b="$s1" -v c="$CLK" 'BEGIN{printf "%.1f",(b-a)/c}')
ct=$(awk -v a="$t0" -v b="$t1" -v c="$CLK" 'BEGIN{printf "%.1f",(b-a)/c}')
ratio=$(awk -v a="$s0" -v b="$s1" -v c="$t0" -v d="$t1" 'BEGIN{dn=(d-c); if(dn>0) printf "%.2f",(b-a)/dn; else print "na"}')
cpupct=$(awk -v a="$s0" -v b="$s1" -v c="$CLK" -v w="$win" 'BEGIN{if(w>0) printf "%.0f",100*((b-a)/c)/w; else print "na"}')

echo "CPU_PROBE tag=$TAG wall=$win cpu_self=$cs cpu_thread=$ct ratio=$ratio cpupct_self=$cpupct rc=$rc"
