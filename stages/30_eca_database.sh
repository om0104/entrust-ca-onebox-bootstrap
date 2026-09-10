#!/usr/bin/env bash
# 30_eca_database — Entrust CA embedded PostgreSQL 15.
set -euo pipefail
. "$BOOTSTRAP_ROOT/lib/common.sh"; load_env
guard 30_eca_database || exit 0
require_sudo

GPG="$MEDIA_DIR/EC-RPM-GPG-KEY-2031-03-15.asc"
PG_RPM="$(ls "$MEDIA_DIR"/Entrust-Certificate-Authority-PostgreSQL-15-*.el9.x86_64.rpm 2>/dev/null | head -1)"
[ -f "$PG_RPM" ] || die "PostgreSQL RPM not found in $MEDIA_DIR"

info "import + verify Entrust RPM signing key"
r rpm --import "$GPG"
r rpm -K "$PG_RPM" | grep -qi "signatures OK\|digests signatures OK\|pgp.*OK" || warn "rpm -K did not report OK for $PG_RPM"

if ! rpm -q Entrust-Certificate-Authority-PostgreSQL-15 >/dev/null 2>&1; then
  info "installing $PG_RPM  (native OL9 — no ENT_RPM_FLAGS)"
  r rpm -ivh "$PG_RPM"
else
  ok "PostgreSQL RPM already installed"
fi

# ---- passwords (generated once) ----
OSPW="$(secret_get db_accounts.env EASM_PG_OS_USER_PWD   gen_pw 26)"
SUPW="$(secret_get db_accounts.env EASM_PG_SUPERUSER_PWD gen_pw 26)"
APPW="$(secret_get db_accounts.env EASM_APP_USER_PWD     gen_pw 26)"
BKPW="$(secret_get db_accounts.env EASM_BACKUP_USER_PWD  gen_pw 26)"

if systemctl is-active --quiet pgsql; then
  ok "pgsql already running — skipping setup_easm_DB.sh"
else
  CFG="$(mktemp)"
  cat > "$CFG" <<EOF
DATABASE_DEPLOYMENT_MODEL = embedded
PG_PROG_PARENT_DIR = /opt/entrust
PG_DATA_PARENT_DIR = /var/pgsql/eca_pg_data
PG_WAL_PARENT_DIR = /var/pgsql/eca_pg_wal
PG_BACKUP_DIR = /entbkup
PG_PORT = 5432
PG_OS_USER_HOMEDIR = /home/easm_entrust_pg
PROMPT_FOR_PWD = false
PG_OS_USER_PWD = ${OSPW}
PG_INTERNAL_SUPER_USER_PWD = ${SUPW}
PG_INTERNAL_ENT_USER_PWD = ${APPW}
PG_INTERNAL_ENTBACKUP_USER_PWD = ${BKPW}
EOF
  r install -m600 -o root -g root "$CFG" /root/eca_db_silent.cfg
  rm -f "$CFG"
  info "running setup_easm_DB.sh (silent; needs a PTY)"
  r script -qec 'cd /opt/entrust/easm_postgresql_15/dbserver/bin && TERM=xterm ./setup_easm_DB.sh -s -f /root/eca_db_silent.cfg -ddm embedded -d postgres' /dev/null
  r shred -u /root/eca_db_silent.cfg
  r systemctl enable --now pgsql
fi

info "verify"
systemctl is-active pgsql && systemctl is-enabled pgsql
r ss -tlnp | grep -q ':5432' && ok "listening on 127.0.0.1:5432"
r -u easm_entrust_pg env PGPASSWORD="$SUPW" \
  /opt/entrust/easm_postgresql_15/dbserver/bin/psql -h 127.0.0.1 -U easm_entrust_pg -d easm_DB \
  -tAc "select rolname from pg_roles where rolname like 'easm%' order by 1;" | tr '\n' ' '
echo

mark_stage_done 30_eca_database
