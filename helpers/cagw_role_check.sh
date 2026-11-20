#!/usr/bin/env bash
# cagw_role_check.sh — READ-ONLY check that the CA Gateway admin's ECA role has every
# permission CAGW needs: Perform PKIX requests, Create user profile, Change user's role
# and View activation codes. Without View activation codes the CA masks activation codes
# (****-****-****) and every enrolment fails cagw-5501 "invalid characters".
#
# Logs in with the CAGW admin EPF, reads the admin's own role BY ID and prints each
# required permission as OK / MISS. Never writes to the CA.
#
#   BOOTSTRAP_ROOT=<bootstrap dir> ./helpers/cagw_role_check.sh [role-id]
#
# Needs: a running CA, admin.epf in $CONFIG_DIR, the CAGW image in $CAGW_RUN_USER's
# rootless store (the toolkit jars are read from it), and a JDK 17+ (javac). The Entrust
# toolkit jars are Java 17 class files, so the java-11 runtime from stage 10 cannot load them:
# install java-17-openjdk-devel, or point JDK_HOME at any JDK 17+.
# Exit: 0 PASS, 1 permission(s) missing, 2 could not check.
set -euo pipefail
export BOOTSTRAP_ROOT="${BOOTSTRAP_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$BOOTSTRAP_ROOT/lib/common.sh"; BOOTSTRAP_QUIET=1 load_env >/dev/null 2>&1 || true
ROLE_ID="${1:-}"
SRC_DIR="$BOOTSTRAP_ROOT/helpers/cagw_role_check"
CACHE="${CAGW_JAR_CACHE:-$BOOTSTRAP_ROOT/.cache/cagw-role-check}"

# ---- a JDK 17+ -------------------------------------------------------------
jdk_ok() { [ -x "$1/bin/javac" ] && [ "$("$1/bin/javac" -version 2>&1 | sed -E 's/^javac ([0-9]+).*/\1/')" -ge 17 ] 2>/dev/null; }
if [ -z "${JDK_HOME:-}" ]; then
  for d in /usr/lib/jvm/*; do jdk_ok "$d" && { JDK_HOME="$d"; break; }; done
fi
[ -n "${JDK_HOME:-}" ] && jdk_ok "$JDK_HOME" \
  || { warn "no JDK 17+ found — install java-17-openjdk-devel or set JDK_HOME"; exit 2; }

# ---- toolkit jars from the CAGW image (cached) -----------------------------
if [ ! -d "$CACHE/lib" ]; then
  info "extracting toolkit jars from $CAGW_IMAGE"
  mkdir -p "$CACHE"; tmp="$(mktemp -d)"; chmod 755 "$tmp"
  cid="$(sudo -iu "$CAGW_RUN_USER" podman create "$CAGW_IMAGE")" \
    || { warn "cannot create a container from $CAGW_IMAGE as $CAGW_RUN_USER"; exit 2; }
  sudo -iu "$CAGW_RUN_USER" podman cp "$cid:/opt/entrust/cagw/lib/cagw-web.jar" "$tmp/" \
    && sudo -iu "$CAGW_RUN_USER" podman rm "$cid" >/dev/null
  (cd "$CACHE" && unzip -q -o "$tmp/cagw-web.jar" 'BOOT-INF/lib/*' && mv BOOT-INF/lib lib && rmdir BOOT-INF)
  rm -rf "$tmp"
fi
CP="$(printf '%s:' "$CACHE"/lib/*.jar)"

# ---- compile (only when the source is newer than the class) ----------------
mkdir -p "$CACHE/classes"
if [ ! -f "$CACHE/classes/CagwRoleCheck.class" ] || [ "$SRC_DIR/CagwRoleCheck.java" -nt "$CACHE/classes/CagwRoleCheck.class" ]; then
  "$JDK_HOME/bin/javac" -nowarn -cp "$CP" -d "$CACHE/classes" "$SRC_DIR/CagwRoleCheck.java" \
    || { warn "compile failed"; exit 2; }
fi

# ---- run (EPF password via environment only) ------------------------------
EPF="$CONFIG_DIR/admin.epf"
[ -r "$EPF" ] || { warn "cannot read $EPF (run as $CAGW_RUN_USER or root)"; exit 2; }
CAGW_ADMIN_EPF_PW="${CAGW_ADMIN_EPF_PW:-$(secret_get cagw.env CAGW_ADMIN_EPF_PW 2>/dev/null || true)}"
[ -n "$CAGW_ADMIN_EPF_PW" ] || { warn "CAGW_ADMIN_EPF_PW not set and not in $SECRETS_DIR/cagw.env"; exit 2; }
export CAGW_ADMIN_EPF_PW

set +e
"$JDK_HOME/bin/java" -cp "$CACHE/classes:$CP" CagwRoleCheck "$EPF" "https://${ECA_FQDN}:${XAP_PORT}/" $ROLE_ID \
  2> >(grep -vE 'jostle|^\s*at |WARNING' >&2)
rc=$?
set -e
exit $rc
