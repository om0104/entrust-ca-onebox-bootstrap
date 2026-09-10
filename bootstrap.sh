#!/usr/bin/env bash
# bootstrap.sh — unattended build of the ECA 10.2.16 + CA Gateway 3.8 one-box
# on a running Oracle Linux 9.8 (+UEK) VM.
#
#   ./bootstrap.sh                 run every stage in order (resumes where it left off)
#   ./bootstrap.sh --from 30       start at stage 30, run the rest
#   ./bootstrap.sh --only 95       run just stage 95
#   ./bootstrap.sh --list          list stages
#   FORCE=1 ./bootstrap.sh --only 40   re-run a stage that is already marked done
#
# Secrets are generated on first run into ./secrets/*.env (0600) — BACK THAT UP.
# Non-secret parameters come from ./bootstrap.env (copy bootstrap.env.example).
#
# The build pauses once, before stage 75, for the manual ECAA Step D
# (see stages/70_PAUSE_ecaa_stepd.md). Provide CAGW_ADMIN_REF / CAGW_ADMIN_AUTHCODE
# in the environment or bootstrap.env to run straight through without stopping.
set -euo pipefail

export BOOTSTRAP_ROOT
BOOTSTRAP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$BOOTSTRAP_ROOT/lib/common.sh"
load_env

STAGES=(
  00_preflight
  10_os_prereqs
  20_nshield_client
  30_eca_database
  40_eca_directory
  50_eca_engine
  60_eca_systemd
  75_cagw_admin_epf
  80_cagw_config
  85_cagw_run
  95_verify
)

usage() { sed -n '2,20p' "$BASH_SOURCE"; exit "${1:-0}"; }

FROM="" ; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from)  FROM="$2"; shift 2 ;;
    --only)  ONLY="$2"; shift 2 ;;
    --list)  printf '%s\n' "${STAGES[@]}"; exit 0 ;;
    -h|--help) usage 0 ;;
    *) die "unknown arg: $1 (see --help)" ;;
  esac
done

run_stage() {
  local s="$1" f="$BOOTSTRAP_ROOT/stages/$1.sh"
  [ -f "$f" ] || die "stage script missing: $f"
  info "───────── stage $s ─────────"
  # each stage runs in its own bash so `set -e` failures are contained + logged
  if bash "$f" 2>&1 | tee -a "$LOG_DIR/$s.log"; then
    return 0
  else
    die "stage $s FAILED — see $LOG_DIR/$s.log . Fix, then re-run (it resumes here)."
  fi
}

if [ -n "$ONLY" ]; then
  match="$(printf '%s\n' "${STAGES[@]}" | grep -E "^${ONLY}(_|$)" || true)"
  [ -n "$match" ] || die "no stage matches '$ONLY'"
  FORCE="${FORCE:-1}" run_stage "$match"
  exit 0
fi

started=0
for s in "${STAGES[@]}"; do
  if [ -n "$FROM" ] && [ "$started" -eq 0 ]; then
    [[ "$s" == "${FROM}"* ]] && started=1 || continue
  fi
  run_stage "$s"
done

ok "bootstrap complete — the ECA 10.2 + CAGW 3.8 one-box is up."
info "Verify again any time with:  ./bootstrap.sh --only 95"
info "Reboot-test the whole box with:  ./bootstrap.sh --only 95   (after 'sudo systemctl reboot')"
