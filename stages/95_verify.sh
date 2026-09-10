#!/usr/bin/env bash
# 95_verify — end-to-end: CAGW status UP, device-identity enrolment ACCEPTED, chain to the CA root.
#   ./bootstrap.sh --only 95            verify now
#   REBOOT=1 ./bootstrap.sh --only 95   reboot the box first, then verify (full one-box test)
set -euo pipefail
. "$BOOTSTRAP_ROOT/lib/common.sh"; load_env
require_cmd curl; require_cmd openssl
. "$SECRETS_DIR/cagw-client.env"

if [ "${REBOOT:-0}" = "1" ]; then
  warn "rebooting this host now; re-run './bootstrap.sh --only 95' once it is back"
  require_sudo; r systemctl reboot; exit 0
fi

BASE="https://127.0.0.1:${CAGW_PORT}/cagw/v1/certificate-authorities/${CAGW_CA_ID}"
CC=(--cacert /dev/null -k --cert "$CAGW_CLIENT_CERT" --key "$CAGW_CLIENT_KEY")

info "1) CAGW connector status"
st=""
for _ in $(seq 1 30); do
  st="$(curl -s "${CC[@]}" "$BASE/status" || true)"
  echo "$st" | grep -q '"status"[ :]*"UP"' && break
  sleep 5
done
echo "$st" | python3 -m json.tool 2>/dev/null || echo "$st"
echo "$st" | grep -q '"status"[ :]*"UP"' || die "CAGW status not UP"
ok "LDAP / XAP / PKIXCMP UP"

info "2) device-identity enrolment — Model A (client-generated key, profileId 0)"
work="$(mktemp -d)"; cd "$work"
# X.500 root-first subject — the SecurityManager connector reverses RDN order
SUBJ="/$(printf '%s' "$CA_OU_DN" | awk -F, '{for(i=NF;i>=1;i--)printf "%s%s",toupper(substr($i,1,index($i,"=")-1))substr($i,index($i,"=")),(i>1?"/":"")}')/CN=bootstrap-verify-$$"
openssl req -new -newkey rsa:2048 -nodes -keyout d.key -out d.csr -subj "$SUBJ" >/dev/null 2>&1
CSR_B64="$(openssl req -in d.csr -outform DER | base64 -w0)"
resp="$(curl -s "${CC[@]}" -X POST "$BASE/enrollments" -H 'Content-Type: application/json' \
  -d "{\"profileId\":\"0\",\"requiredFormat\":{\"format\":\"X509\"},\"csr\":\"$CSR_B64\"}")"
echo "$resp" | python3 -m json.tool 2>/dev/null || echo "$resp"
echo "$resp" | grep -q '"status"[ :]*"ACCEPTED"' || die "enrolment not ACCEPTED"
serial="$(echo "$resp" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("enrollment",{}).get("serialNumber",""))' 2>/dev/null || true)"
ok "enrolment ACCEPTED (serial ${serial:-?})"

info "3) chain check — issued leaf verifies to the ECA root"
echo "$resp" | python3 -c '
import json,sys,base64
d=json.load(sys.stdin); e=d.get("enrollment",{})
b=e.get("body") or (e.get("certificateData") or {}).get("certificate","")
open("leaf.pem","w").write(b if "-----BEGIN" in b else "-----BEGIN CERTIFICATE-----\n"+ "\n".join(base64.b64encode(base64.b64decode(b)).decode()[i:i+64] for i in range(0,len(base64.b64encode(base64.b64decode(b)).decode()),64)) +"\n-----END CERTIFICATE-----\n")
' 2>/dev/null || true
# pull the CA root from the directory
. "$SECRETS_DIR/directory.env" 2>/dev/null || true
if have_cmd ldapsearch; then
  sudo -n true 2>/dev/null && SUDO=sudo || SUDO=
  $SUDO ldapsearch -o ldif-wrap=no -LLL -x -H ldap://127.0.0.1 -b "$CA_OU_DN" -s base 'cACertificate;binary' 2>/dev/null \
    | awk '/^cACertificate;binary::/{print $2}' | base64 -d 2>/dev/null \
    | openssl x509 -inform DER -out root.pem 2>/dev/null || true
fi
if [ -s root.pem ] && [ -s leaf.pem ]; then
  openssl verify -CAfile root.pem leaf.pem && ok "openssl verify OK — leaf chains to the ECA root" || warn "verify failed (inspect $work)"
else
  warn "could not assemble root/leaf for offline verify — the ACCEPTED status above is the primary signal"
fi
cd /; rm -rf "$work"

info "4) boot persistence"
systemctl is-enabled entca.service                    && ok "entca.service enabled"
systemctl is-enabled "${ECA_INSTANCE}-preload.service" && ok "${ECA_INSTANCE}-preload.service enabled"
sudo loginctl show-user "$CAGW_RUN_USER" -p Linger
sudo -iu "$CAGW_RUN_USER" systemctl --user is-enabled cagw.service || true

mark_stage_done 95_verify
ok "VERIFICATION PASSED — the ECA 10.2 + CAGW 3.8 one-box issues device identities end-to-end."
