#!/bin/bash
# env/_profile.sh -- resolve ENV_PROFILE (lcrc|polaris) once, for all callers.
# Sets ENV_ROOT, ENV_PROFILE, DARSHAN_MOFKA_PROFILE. Honors an explicit
# --lcrc/--polaris arg, then $DARSHAN_MOFKA_PROFILE, then auto-detects.
ENV_ROOT="${ENV_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
case "${1:-}" in
    --lcrc) ENV_PROFILE=lcrc ;;
    --polaris) ENV_PROFILE=polaris ;;
    *) ENV_PROFILE="${DARSHAN_MOFKA_PROFILE:-}" ;;
esac
if [[ -z "$ENV_PROFILE" ]]; then
    { [[ -d /gpfs/fs1/soft/improv ]] || hostname 2>/dev/null | grep -qi 'ilogin\|improv'; } \
        && ENV_PROFILE=lcrc || ENV_PROFILE=polaris
fi
export ENV_ROOT ENV_PROFILE DARSHAN_MOFKA_PROFILE="$ENV_PROFILE"
