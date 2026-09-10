#!/usr/bin/env bash
# 75_cagw_admin_epf — turn the ECAA Step D reference number + activation code into
# the CAGW admin EPF (admin.epf) using the Profile Creation Utility (pcu.sh).
set -euo pipefail
. "$BOOTSTRAP_ROOT/lib/common.sh"; load_env
guard 75_cagw_admin_epf || exit 0

: "${CAGW_ADMIN_REF:=}" ; : "${CAGW_ADMIN_AUTHCODE:=}"
if [ -z "$CAGW_ADMIN_REF" ] || [ -z "$CAGW_ADMIN_AUTHCODE" ]; then
  cat "$BOOTSTRAP_ROOT/stages/70_PAUSE_ecaa_stepd.md"
  echo
  die "CAGW_ADMIN_REF / CAGW_ADMIN_AUTHCODE not set — do the ECAA Step D above, put them in bootstrap.env, and re-run."
fi

: "${CAGW_PCU_ZIP:?set CAGW_PCU_ZIP to the cagw-profilecreationutility zip}"
[ -f "$CAGW_PCU_ZIP" ] || die "not found: $CAGW_PCU_ZIP"
require_cmd unzip; require_cmd expect
have_cmd java || die "java not found (stage 10 installs java-11-openjdk-headless)"

EPF_PW="$(secret_get cagw.env CAGW_ADMIN_EPF_PW gen_pw 22)"

# a client entrust.ini for pcu (points at this host's ASH listener)
INI="$CONFIG_DIR/entrust.ini"
if [ ! -f "$INI" ]; then
  install -m644 /dev/null "$INI"
  cat > "$INI" <<EOF
[Entrust Settings]
DefaultManager=${ECA_FQDN}+${ASH_PORT}
[Manager0]
Manager=${ECA_FQDN}+${ASH_PORT}
CA=${ECA_FQDN}+${PKIX_PORT}
[Groups]
Enterprise=${CA_OU_DN}
EOF
fi

WORK="$(mktemp -d)"
unzip -oq "$CAGW_PCU_ZIP" -d "$WORK"
PCU="$(find "$WORK" -name pcu.sh -path '*/bin/*' | head -1)"
[ -x "$PCU" ] || { chmod +x "$PCU" 2>/dev/null; }
[ -f "$PCU" ] || die "pcu.sh not found inside $CAGW_PCU_ZIP"

info "running pcu.sh (menu 3 → file-on-disk profile) to build admin.epf"
cat > "$WORK/pcu.exp" <<EXP
#!/usr/bin/expect -f
set ref  [lindex \$argv 0]
set auth [lindex \$argv 1]
set ini  [lindex \$argv 2]
set pw   [lindex \$argv 3]
set outdir [lindex \$argv 4]
set timeout 180
spawn bash $PCU
expect {
  -re {Enter option|selection|choice} { send -- "3\r"; exp_continue }
  -re {Press ENTER|Press return}       { send -- "\r"; exp_continue }
  -re {use.*entrust\.ini|Use an existing} { send -- "y\r"; exp_continue }
  -re {entrust\.ini}                    { send -- "\$ini\r"; exp_continue }
  -nocase -re {reference number}        { send -- "\$ref\r"; exp_continue }
  -nocase -re {authorization code|activation code} { send -- "\$auth\r"; exp_continue }
  -nocase -re {profile name}            { send -- "admin\r"; exp_continue }
  -nocase -re {profile directory}       { send -- "\$outdir\r"; exp_continue }
  -nocase -re {password}                { send -- "\$pw\r"; exp_continue }
  -re {created|success|Success}         { puts "@@PCU_OK@@"; exp_continue }
  -re {ERROR|error|failed|Failed}       { puts "@@PCU_ERR@@"; exp_continue }
  eof {}
}
EXP
chmod +x "$WORK/pcu.exp"
"$WORK/pcu.exp" "$CAGW_ADMIN_REF" "$CAGW_ADMIN_AUTHCODE" "$INI" "$EPF_PW" "$CONFIG_DIR"

rm -rf "$WORK"
[ -f "$CONFIG_DIR/admin.epf" ] || die "admin.epf was not created — inspect $LOG_DIR/75_cagw_admin_epf.log"
chmod 600 "$CONFIG_DIR/admin.epf"
ok "admin.epf created ($(stat -c%s "$CONFIG_DIR/admin.epf") bytes); EPF password in secrets/cagw.env"

mark_stage_done 75_cagw_admin_epf
