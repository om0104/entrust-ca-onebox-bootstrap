#!/usr/bin/env bash
# 60_eca_systemd — autologin + boot-persistent softcard preload + stock entca.service.
set -euo pipefail
. "$BOOTSTRAP_ROOT/lib/common.sh"; load_env
guard 60_eca_systemd || exit 0
require_sudo

NFAST=/opt/nfast; NFBIN=$NFAST/bin
ECA_BIN=/opt/entrust/certificate_authority/bin
AUTHDIR=/opt/entrust/authdata/CA
. "$SECRETS_DIR/nshield.env"
. "$SECRETS_DIR/eca.env"

# ---------------------------------------------------------------- autologin (Master1)
if [ -f "$AUTHDIR/manager/authauto.ini" ]; then
  ok "autologin already configured"
else
  info "enabling autologin as Master1 (10.2 syntax: 'service autologin -enable')"
  r tee /tmp/autologin.exp >/dev/null <<EXP
#!/usr/bin/expect -f
set m1pw [lindex \$argv 0]
set timeout 120
spawn sudo -u entrust $ECA_BIN/entsh
expect -re {entsh.*>} { send -- "login\r" }
expect -nocase {Master User Name:} { send -- "Master1\r" }
expect -nocase {Password:} { send -- "\$m1pw\r" }
expect -re {entsh.*>} { send -- "service autologin -enable\r" }
expect -re {entsh.*>} { send -- "quit\r" }
expect eof
EXP
  r chmod +x /tmp/autologin.exp
  r /tmp/autologin.exp "$ECA_MASTER1_PW"
  r rm -f /tmp/autologin.exp
  [ -f "$AUTHDIR/manager/authauto.ini" ] && ok "authauto.ini written" || warn "authauto.ini not found — check entsh output"
fi

# ---------------------------------------------------------------- preload service
PRELOAD_EXP="$NFAST/preload-${ECA_INSTANCE}.exp"
PP_FILE="$NFAST/kmdata/config/eca-sc.pp"
if [ ! -f "$PP_FILE" ]; then printf '%s' "$SOFTCARD_PP" | r tee "$PP_FILE" >/dev/null; r chmod 0600 "$PP_FILE"; fi
r tee "$PRELOAD_EXP" >/dev/null <<EXP
#!/usr/bin/expect -f
set fh [open "$PP_FILE"]; set pp [string trim [read \$fh]]; close \$fh
set timeout 60
spawn $NFBIN/preload -s $SOFTCARD_NAME -f $NFAST/entrustsmtoken pause
expect { -nocase -re {passphrase} { send -- "\$pp\r" } timeout { exit 1 } }
expect { -re {pausing|Loading complete} {} timeout { exit 2 } }
set timeout -1
expect eof
EXP
r chmod 0750 "$PRELOAD_EXP"
have_cmd chcon && r chcon -u unconfined_u -t usr_t "$PRELOAD_EXP" 2>/dev/null || true

r tee "/etc/systemd/system/${ECA_INSTANCE}-preload.service" >/dev/null <<EOF
[Unit]
Description=nShield preload session for the ECA CA softcard (${SOFTCARD_NAME})
After=nc_hardserver.service network-online.target
Wants=nc_hardserver.service
Before=entca.service

[Service]
Type=simple
ExecStart=${PRELOAD_EXP}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
r systemctl daemon-reload
r systemctl enable "${ECA_INSTANCE}-preload.service"

# ---------------------------------------------------------------- entca (stock unit)
info "switching CA to systemd management (stock entca.service, no drop-ins)"
r "$ECA_BIN/ent_ca_ctl.sh" stop 2>/dev/null || true
sleep 3
r systemctl restart "${ECA_INSTANCE}-preload.service"
sleep 5
r systemctl enable --now entca.service
sleep 8

# SELinux back on if it was toggled during init
have_cmd semodule && r semodule -B 2>/dev/null || true

info "verify"
systemctl is-active entca.service
r "$ECA_BIN/ent_ca_ctl.sh" status | head -3
r ss -tlnp | grep -E ":${PKIX_PORT}|:${ASH_PORT}|:${XAP_PORT}" || true

mark_stage_done 60_eca_systemd

cat <<EOF

  ─────────────────────────────────────────────────────────────────────────
  MANUAL STEP REQUIRED before stage 75  —  ECAA Step D
  Follow  bootstrap/stages/70_PAUSE_ecaa_stepd.md
  Then set CAGW_ADMIN_REF and CAGW_ADMIN_AUTHCODE in bootstrap.env and
  re-run  ./bootstrap.sh   (it continues from stage 75).
  ─────────────────────────────────────────────────────────────────────────
EOF
