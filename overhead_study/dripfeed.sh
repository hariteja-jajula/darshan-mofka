#!/bin/bash
# dripfeed.sh -- submit every overhead-study arm-job under Polaris's
# max_queued=1-per-user-per-queue limit (both `debug` AND `debug-scaling` enforce
# it; you cannot bulk-submit -- PBS rejects the 2nd queued job).
#
# Strategy: keep exactly ONE job in Q state per queue. Each cycle, for each queue
# with 0 of my jobs in Q, submit the next pending arm-job for that queue. `debug`
# (1wl files, 2 total nodes) and `debug-scaling` (2wl/4wl, 3/5 total) advance
# independently. A job leaves Q when it starts RUNNING, so throughput ~= 1 job per
# job-runtime per queue; the scheduler may run several of mine at once (that only
# frees the Q slot sooner). Proven workloads first; python-ml 2wl/4wl are HELD.
#
# Resumable: completed submissions are recorded in .dripfeed_state (file arm jobid).
# Re-running skips them. Progress is appended to .dripfeed.log.
#
# Usage:
#   nohup bash overhead_study/dripfeed.sh >/dev/null 2>&1 &
#   tail -f overhead_study/.dripfeed.log
# Env: POLL_S=30 (cycle sleep), MAXCYCLES=100000, DRYRUN=1 (print, don't submit).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${DRIPFEED_STATE:-$HERE/.dripfeed_state}"
LOG="${DRIPFEED_LOG:-$HERE/.dripfeed.log}"
# per-arm rep counts (study design: 1 baseline + 1 runtimeonly + 3 streaming reps)
BASE_REPS="${BASE_REPS:-1}"; RUNTIME_REPS="${RUNTIME_REPS:-1}"; STREAM_REPS="${STREAM_REPS:-3}"
POLL_S="${POLL_S:-30}"
MAXCYCLES="${MAXCYCLES:-100000}"
ME="$(whoami)"
touch "$STATE"

log(){ echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }

# --- work list: "<file-basename> <arm>", in submission priority order. ---
# debug queue (1wl = 2 total nodes): proven I/O first, python-ml last.
# debug-scaling (2wl/4wl): all 2wl, then all 4wl; python-ml HELD (see below).
WORK=(
  # -- debug (1wl = 2 total nodes): 5 workloads x 3 arms --
  "1wlnode_1srvnode_iobench_1rnkpernd_cxi.sh baseline"
  "1wlnode_1srvnode_iobench_1rnkpernd_cxi.sh runtimeonly"
  "1wlnode_1srvnode_iobench_1rnkpernd_cxi.sh streaming"
  "1wlnode_1srvnode_iobenchpy_1rnkpernd_cxi.sh baseline"
  "1wlnode_1srvnode_iobenchpy_1rnkpernd_cxi.sh runtimeonly"
  "1wlnode_1srvnode_iobenchpy_1rnkpernd_cxi.sh streaming"
  "1wlnode_1srvnode_pythonml_1rnkpernd_cxi.sh baseline"
  "1wlnode_1srvnode_pythonml_1rnkpernd_cxi.sh runtimeonly"
  "1wlnode_1srvnode_pythonml_1rnkpernd_cxi.sh streaming"
  "1wlnode_1srvnode_mpi_32rnkpernd_tcp.sh baseline"
  "1wlnode_1srvnode_mpi_32rnkpernd_tcp.sh runtimeonly"
  "1wlnode_1srvnode_mpi_32rnkpernd_tcp.sh streaming"
  "1wlnode_1srvnode_dlio_32rnkpernd_tcp.sh baseline"
  "1wlnode_1srvnode_dlio_32rnkpernd_tcp.sh runtimeonly"
  "1wlnode_1srvnode_dlio_32rnkpernd_tcp.sh streaming"
  # -- debug-scaling (4wl = 5 total nodes): 5 workloads x 3 arms --
  "4wlnode_1srvnode_iobench_1rnkpernd_cxi.sh baseline"
  "4wlnode_1srvnode_iobench_1rnkpernd_cxi.sh runtimeonly"
  "4wlnode_1srvnode_iobench_1rnkpernd_cxi.sh streaming"
  "4wlnode_1srvnode_iobenchpy_1rnkpernd_cxi.sh baseline"
  "4wlnode_1srvnode_iobenchpy_1rnkpernd_cxi.sh runtimeonly"
  "4wlnode_1srvnode_iobenchpy_1rnkpernd_cxi.sh streaming"
  "4wlnode_1srvnode_pythonml_1rnkpernd_cxi.sh baseline"
  "4wlnode_1srvnode_pythonml_1rnkpernd_cxi.sh runtimeonly"
  "4wlnode_1srvnode_pythonml_1rnkpernd_cxi.sh streaming"
  "4wlnode_1srvnode_mpi_32rnkpernd_tcp.sh baseline"
  "4wlnode_1srvnode_mpi_32rnkpernd_tcp.sh runtimeonly"
  "4wlnode_1srvnode_mpi_32rnkpernd_tcp.sh streaming"
  "4wlnode_1srvnode_dlio_32rnkpernd_tcp.sh baseline"
  "4wlnode_1srvnode_dlio_32rnkpernd_tcp.sh runtimeonly"
  "4wlnode_1srvnode_dlio_32rnkpernd_tcp.sh streaming"
)

queue_of(){ case "$1" in 1wlnode_*) echo debug ;; *) echo debug-scaling ;; esac; }

# count MY jobs in Q state in a given queue
qcount_Q(){
  local q="$1"
  qstat -wu "$ME" 2>/dev/null | awk -v q="$q" '
    $1 ~ /^[0-9]/ && $3==q && $10=="Q" {n++} END{print n+0}'
}
done_already(){ grep -qF "$1 $2 " "$STATE"; }

# reps for a given arm (baseline 1 / runtimeonly 1 / streaming 3 by default)
reps_for(){ case "$1" in baseline) echo "$BASE_REPS";; runtimeonly) echo "$RUNTIME_REPS";; streaming) echo "$STREAM_REPS";; *) echo 1;; esac; }

# submit exactly one arm of one file; echo jobid on success, empty on reject/fail.
submit_one(){
  local file="$1" arm="$2" out jid reps
  reps="$(reps_for "$arm")"
  out="$(cd "$HERE/.." && ARMS="$arm" REPS="$reps" DRYRUN="${DRYRUN:-0}" bash "overhead_study/$file" 2>&1)"
  if [ "${DRYRUN:-0}" = 1 ]; then echo "$out" >>"$LOG"; echo "DRYRUN"; return 0; fi
  jid="$(grep -oE '^[0-9]+\.polaris[^ ]*' <<<"$out" | head -1)"
  if [ -n "$jid" ]; then echo "$jid"; else
    grep -qi 'exceed.*per-user limit' <<<"$out" || log "  submit note: $(tr '\n' ' ' <<<"$out" | tail -c 200)"
    echo ""
  fi
}

log "=== dripfeed start: ${#WORK[@]} arm-jobs, poll=${POLL_S}s, state=$STATE ==="
cyc=0
while :; do
  cyc=$((cyc+1)); [ "$cyc" -gt "$MAXCYCLES" ] && { log "max cycles reached"; break; }
  pending=0
  # one submission attempt per queue per cycle (respects the 1-in-Q limit)
  for q in debug debug-scaling; do
    inq="$(qcount_Q "$q")"
    [ "${inq:-0}" -ge 1 ] && { : ; } # queue busy in Q; skip this cycle for it
    for unit in "${WORK[@]}"; do
      file="${unit% *}"; arm="${unit##* }"
      [ "$(queue_of "$file")" = "$q" ] || continue
      done_already "$file" "$arm" && continue
      pending=$((pending+1))
      # only submit if this queue has no job of mine waiting in Q
      if [ "${inq:-0}" -lt 1 ]; then
        jid="$(submit_one "$file" "$arm")"
        if [ -n "$jid" ]; then
          echo "$file $arm ${jid:-DRYRUN}" >>"$STATE"
          log "SUBMIT[$q] $file $arm -> $jid"
          inq=1   # we now occupy this queue's Q slot; stop submitting to it this cycle
        else
          log "HOLD[$q] $file $arm (queue reject/err); retry next cycle"
        fi
      fi
      break  # move to next queue; one attempt per queue per cycle
    done
  done
  # recount remaining pending across all units
  remaining=0
  for unit in "${WORK[@]}"; do
    file="${unit% *}"; arm="${unit##* }"
    done_already "$file" "$arm" || remaining=$((remaining+1))
  done
  [ "$remaining" -eq 0 ] && { log "=== all ${#WORK[@]} arm-jobs submitted. done. ==="; break; }
  [ "${DRYRUN:-0}" = 1 ] && { log "DRYRUN: would continue ($remaining pending); exiting dry-run."; break; }
  sleep "$POLL_S"
done
