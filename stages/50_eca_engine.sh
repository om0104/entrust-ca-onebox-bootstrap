#!/usr/bin/env bash
# 50_eca_engine — install ECA 10.2, run config_authority.sh -s -f, then first-time init
# under a held 'preload ... pause' softcard session (expect-driven).
set -euo pipefail
. "$BOOTSTRAP_ROOT/lib/common.sh"; load_env
guard 50_eca_engine || exit 0
require_sudo

ENG_RPM="$(ls "$MEDIA_DIR"/Entrust-Certificate-Authority-10.2.*.el9.x86_64.rpm 2>/dev/null | head -1)"
[ -f "$ENG_RPM" ] || die "ECA engine RPM not found in $MEDIA_DIR"
NFAST=/opt/nfast; NFBIN=$NFAST/bin
ECA_BIN=/opt/entrust/certificate_authority/bin
AUTHDIR=/opt/entrust/authdata/CA

# ---- credentials ----
. "$SECRETS_DIR/db_accounts.env"
. "$SECRETS_DIR/directory.env"
. "$SECRETS_DIR/nshield.env"
ECA_OS_USER_PWD="$(secret_get eca.env ECA_OS_USER_PWD gen_entrust_pw)"
ECA_MASTER_PWD="$(secret_get eca.env ECA_MASTER_PWD gen_entrust_pw)"
M1="$(secret_get eca.env ECA_MASTER1_PW gen_entrust_pw)"
M2="$(secret_get eca.env ECA_MASTER2_PW gen_entrust_pw)"
M3="$(secret_get eca.env ECA_MASTER3_PW gen_entrust_pw)"
FO="$(secret_get eca.env ECA_FIRST_OFFICER_PW gen_entrust_pw)"
: "${LIC_ENT_SERIAL_NUMBER:?export the Entrust CA licence Serial Number (or put it in bootstrap.env)}"
: "${LIC_ENT_USER_LIMIT:?export the Entrust CA licence User Limit}"
: "${LIC_ENT_LICENSE_KEY:?export the Entrust CA licence Key}"

# ---- install engine ----
if ! rpm -q Entrust-Certificate-Authority >/dev/null 2>&1; then
  r rpm -K "$ENG_RPM" || warn "rpm -K not OK for $ENG_RPM"
  info "installing $ENG_RPM  (native OL9/UEK — no ENT_RPM_FLAGS)"
  r rpm -ivh "$ENG_RPM"
  r usermod -aG nfast entrust || true
else
  ok "ECA engine already installed"
fi
r bash -c "id entrust >/dev/null 2>&1 && echo '${ECA_OS_USER_PWD}' | passwd --stdin entrust >/dev/null" || true

# ---- render silent config ----
export ENT_OS_USER_PWD="$ECA_OS_USER_PWD" EASM_APP_USER_PWD EASM_BACKUP_USER_PWD \
       CA_ENTRY_PW="$DS_CA_ENTRY_PW" DS_ROOT_PW MASTER_PWD="$ECA_MASTER_PWD" \
       LIC_ENT_SERIAL_NUMBER LIC_ENT_USER_LIMIT LIC_ENT_LICENSE_KEY \
       DIRECTORY_HOSTNAME="$ECA_FQDN" CA_DN="$CA_OU_DN" \
       FO_DN="cn=First Officer,${CA_OU_DN}" CA_SIG_RSA_KEY_LEN="$CA_RSA_BITS" \
       PKIX_PORT ASH_PORT XAP_PORT
CFG="$(mktemp)"
render "$TEMPLATES_DIR/eca_silent.cfg.tmpl" "$CFG"
r install -m600 -o root -g root "$CFG" /root/eca_silent.cfg
rm -f "$CFG"

if [ ! -f "$AUTHDIR/env_settings.sh" ]; then
  info "config_authority.sh -s -f  (SM_INIT=false)"
  r "$NFBIN/cklist" 2>/dev/null | grep -iE 'slot|token label' || true
  r script -qec "cd $ECA_BIN && TERM=xterm ./config_authority.sh -s -f /root/eca_silent.cfg" /dev/null
else
  ok "config_authority.sh already run (env_settings.sh present)"
fi
r shred -u /root/eca_silent.cfg 2>/dev/null || true

# ---- first-time init under a held preload session ----
if r "$ECA_BIN/ent_ca_ctl.sh" status 2>/dev/null | grep -q 'processes are running'; then
  ok "CA already initialised and running"
else
  info "first-time init (held preload + expect: softcard pp, Master1/2/3, First Officer)"
  # wrapper that sources the ECA env and runs FirstTimeInit
  r tee "$AUTHDIR/../ftinit_wrap.sh" >/dev/null <<EOF
#!/bin/bash
export AUTHDATDIR=$AUTHDIR
export NFAST_NFKM_TOKENSFILE=$NFAST/entrustsmtoken
. $AUTHDIR/env_settings.sh
exec $ECA_BIN/entsh -e 'source "$AUTHDIR/FirstTimeInit.tcl"'
EOF
  r chmod 0750 "$AUTHDIR/../ftinit_wrap.sh"; r chown entrust:entrust "$AUTHDIR/../ftinit_wrap.sh"

  r tee "$AUTHDIR/../ftinit.exp" >/dev/null <<'EXP'
#!/usr/bin/expect -f
set scpp [lindex $argv 0]; set m1 [lindex $argv 1]; set m2 [lindex $argv 2]
set m3 [lindex $argv 3]; set fo [lindex $argv 4]
set timeout 1200
spawn sudo -u entrust /opt/entrust/authdata/ftinit_wrap.sh
expect {
  -nocase -re {pass ?phrase|hardware security module|HSM.{0,4}:} { send -- "$scpp\r"; exp_continue }
  -nocase -re {Master1} { send -- "$m1\r"; exp_continue }
  -nocase -re {Master2} { send -- "$m2\r"; exp_continue }
  -nocase -re {Master3} { send -- "$m3\r"; exp_continue }
  -nocase -re {First Officer} { send -- "$fo\r"; exp_continue }
  -re {Initialization complete} { puts "@@INIT_COMPLETE@@"; exp_continue }
  -re {backup completed successfully} { puts "@@BACKUP_OK@@"; exp_continue }
  -re {Press return to exit} { send -- "\r"; exp_continue }
  -re {ERROR|error:|[Ff]ailed} { puts "@@ERRLINE@@"; exp_continue }
  eof { puts "@@EOF@@" }
}
EXP
  r chmod 0750 "$AUTHDIR/../ftinit.exp"

  # hold a preload session for the whole init
  SCPP="$SOFTCARD_PP"
  r bash -c "cat > /tmp/pl.exp <<'EXP'
#!/usr/bin/expect -f
set pp [lindex \$argv 0]
set timeout 60
spawn $NFBIN/preload -s $SOFTCARD_NAME -f $NFAST/entrustsmtoken pause
expect { -nocase {passphrase} { send -- \"\$pp\r\" } timeout { exit 1 } }
expect { -re {pausing|Loading complete} {} timeout { exit 2 } }
set timeout -1
expect eof
EXP
chmod +x /tmp/pl.exp"
  r systemd-run --unit=eca-bootstrap-preload --service-type=simple /tmp/pl.exp "$SCPP"
  sleep 5
  r "$AUTHDIR/../ftinit.exp" "$SCPP" "$M1" "$M2" "$M3" "$FO" || true
  r systemctl stop eca-bootstrap-preload 2>/dev/null || true
  r rm -f /tmp/pl.exp

  r "$ECA_BIN/ent_ca_ctl.sh" status | grep -q 'processes are running' || die "CA init did not complete — see the log"
fi

info "root CA cert"
r "$ECA_BIN/entsh" <<< "ca status" 2>/dev/null | head -20 || true
r ss -tlnp | grep -E ":${PKIX_PORT}|:${ASH_PORT}|:${XAP_PORT}" || true

mark_stage_done 50_eca_engine
