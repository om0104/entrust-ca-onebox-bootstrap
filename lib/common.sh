# shellcheck shell=bash
# bootstrap/lib/common.sh — shared helpers for the ECA 10.2 + CAGW 3.8 one-box bootstrap.
# Sourced by bootstrap.sh and every stages/*.sh. Not executable on its own.

set -euo pipefail

# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------
BOOTSTRAP_ROOT="${BOOTSTRAP_ROOT:?BOOTSTRAP_ROOT must be exported by bootstrap.sh}"
STATE_DIR="${STATE_DIR:-$BOOTSTRAP_ROOT/.state}"
LOG_DIR="${LOG_DIR:-$BOOTSTRAP_ROOT/logs}"
SECRETS_DIR="${SECRETS_DIR:-$BOOTSTRAP_ROOT/secrets}"
MEDIA_DIR="${MEDIA_DIR:-$BOOTSTRAP_ROOT/media}"
TEMPLATES_DIR="${TEMPLATES_DIR:-$BOOTSTRAP_ROOT/templates}"

mkdir -p "$STATE_DIR" "$LOG_DIR"
install -d -m 0700 "$SECRETS_DIR"

# --------------------------------------------------------------------------
# Logging
# --------------------------------------------------------------------------
_ts()  { date +'%Y-%m-%dT%H:%M:%S%z'; }
log()  { printf '%s  %s\n'      "$(_ts)" "$*" ; }
info() { printf '%s  \033[0;36m%s\033[0m\n' "$(_ts)" "$*" ; }
ok()   { printf '%s  \033[0;32m✓ %s\033[0m\n' "$(_ts)" "$*" ; }
warn() { printf '%s  \033[0;33m! %s\033[0m\n' "$(_ts)" "$*" >&2 ; }
die()  { printf '%s  \033[0;31m✗ %s\033[0m\n' "$(_ts)" "$*" >&2 ; exit 1 ; }

# --------------------------------------------------------------------------
# Stage markers  (idempotency / --resume)
# --------------------------------------------------------------------------
stage_done()      { [ -f "$STATE_DIR/$1.done" ]; }
mark_stage_done() { date +%s > "$STATE_DIR/$1.done"; ok "stage $1 complete"; }
clear_stage()     { rm -f "$STATE_DIR/$1.done"; }

# guard() NAME — call at the top of a stage body; skips if already done unless FORCE=1
guard() {
  local name="$1"
  if stage_done "$name" && [ "${FORCE:-0}" != "1" ]; then
    ok "stage $name already done — skipping (FORCE=1 to re-run)"
    return 1
  fi
  return 0
}

# --------------------------------------------------------------------------
# Privilege
# --------------------------------------------------------------------------
require_cmd()  { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
have_cmd()     { command -v "$1" >/dev/null 2>&1; }
require_sudo() {
  [ "$(id -u)" -eq 0 ] && return 0
  sudo -n true 2>/dev/null && return 0
  die "this stage needs root: run as root or give '$USER' passwordless sudo"
}
# run as root
r() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

# --------------------------------------------------------------------------
# Secrets
# --------------------------------------------------------------------------
# gen_pw [LEN] — URL-safe alphanumeric, guaranteed >=1 upper, >=1 lower, >=1 digit
gen_pw() {
  local len="${1:-26}" p
  while :; do
    p="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len")"
    [[ "$p" =~ [A-Z] && "$p" =~ [a-z] && "$p" =~ [0-9] ]] && { printf '%s' "$p"; return; }
  done
}
# gen_entrust_pw — Entrust Master/Officer rule: 8-20 chars, upper+lower+digit+special
gen_entrust_pw() {
  local core spec p
  core="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 13)"
  spec='!@#%^*_-+=' ; local s="${spec:$((RANDOM % ${#spec})):1}"
  # force one of each class deterministically, then shuffle-ish
  p="A${core}a9${s}"
  p="${p:0:15}"
  # ensure classes after truncation
  [[ "$p" =~ [A-Z] && "$p" =~ [a-z] && "$p" =~ [0-9] && "$p" =~ [\!\@\#\%\^\*_+=-] ]] || p="Ab3${core:0:9}${s}9"
  printf '%s' "${p:0:15}"
}

# secret_put FILE KEY VALUE   — idempotent KEY=VALUE into $SECRETS_DIR/FILE (0600) + denylist
secret_put() {
  local file="$SECRETS_DIR/$1" key="$2" val="$3"
  touch "$file"; chmod 600 "$file"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
  # denylist for a repo guard (harmless if unused)
  local dl="$SECRETS_DIR/.secret-denylist"; touch "$dl"; chmod 600 "$dl"
  grep -qxF "$val" "$dl" 2>/dev/null || printf '%s\n' "$val" >> "$dl"
}

# secret_get FILE KEY [GENERATOR...]  — read KEY; if absent, run generator, store, return it
secret_get() {
  local file="$SECRETS_DIR/$1" key="$2"; shift 2
  if [ -f "$file" ] && grep -q "^${key}=" "$file"; then
    grep "^${key}=" "$file" | head -1 | cut -d= -f2-
    return
  fi
  local val
  if [ "$#" -gt 0 ]; then val="$("$@")"; else die "secret $1/$key not set and no generator given"; fi
  secret_put "$1" "$key" "$val"
  printf '%s' "$val"
}

# load_env — source bootstrap.env (non-secret params) if present
load_env() {
  local f="${BOOTSTRAP_ENV:-$BOOTSTRAP_ROOT/bootstrap.env}"
  if [ -f "$f" ]; then set -a; # shellcheck disable=SC1090
    . "$f"; set +a; info "loaded $f"
  else
    warn "no bootstrap.env — using built-in defaults (copy bootstrap.env.example)"
  fi
  : "${ECA_INSTANCE:=eca}"
  : "${ECA_FQDN:=$(hostname -f 2>/dev/null || hostname)}"
  : "${DS_SUFFIX:=dc=example,dc=net}"
  : "${DS_INSTANCE:=eca}"
  : "${CA_OU_DN:=ou=CA,${DS_SUFFIX}}"
  : "${SOFTCARD_NAME:=eca-ca3}"
  : "${HSM_MODE:=nethsm}"
  : "${CA_RSA_BITS:=4096}"
  : "${PKIX_PORT:=829}"; : "${ASH_PORT:=710}"; : "${XAP_PORT:=443}"
  : "${CAGW_PORT:=8444}"
  : "${CAGW_CA_ID:=eca}"
  : "${CAGW_IMAGE:=docker.io/cagw/api:3.8.0}"
  : "${CAGW_RUN_USER:=$USER}"
  : "${CONFIG_DIR:=/opt/eca-cagw/config}"
  export ECA_INSTANCE ECA_FQDN DS_SUFFIX DS_INSTANCE CA_OU_DN SOFTCARD_NAME HSM_MODE \
         CA_RSA_BITS PKIX_PORT ASH_PORT XAP_PORT CAGW_PORT CAGW_CA_ID CAGW_IMAGE \
         CAGW_RUN_USER CONFIG_DIR
}

# render TEMPLATE OUT  — replace @@VAR@@ tokens from the current environment
render() {
  local tpl="$1" out="$2"
  [ -f "$tpl" ] || die "template not found: $tpl"
  python3 - "$tpl" "$out" <<'PY'
import os, re, sys
tpl, out = sys.argv[1], sys.argv[2]
s = open(tpl).read()
def sub(m):
    k = m.group(1)
    if k not in os.environ:
        sys.exit(f"render: template var @@{k}@@ not set in environment ({tpl})")
    return os.environ[k]
s = re.sub(r'@@([A-Z0-9_]+)@@', sub, s)
open(out, 'w').write(s)
PY
}

# wait_tcp HOST PORT [TRIES] — poll a TCP listener
wait_tcp() {
  local host="$1" port="$2" tries="${3:-30}"
  for _ in $(seq 1 "$tries"); do
    (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
    sleep 2
  done
  return 1
}
