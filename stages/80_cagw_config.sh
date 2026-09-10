#!/usr/bin/env bash
# 80_cagw_config — CAGW mTLS material (self-signed local CA), application.yml, licence.
set -euo pipefail
. "$BOOTSTRAP_ROOT/lib/common.sh"; load_env
guard 80_cagw_config || exit 0
require_cmd openssl
. "$SECRETS_DIR/directory.env"
. "$SECRETS_DIR/cagw.env"

cd "$CONFIG_DIR"

# ---------------------------------------------------------------- 1. mTLS trust
# CAGW's REST API uses its own TLS chain, independent of the ECA CA.
P12PW="$(secret_get cagw.env CAGW_P12_PW gen_pw 24)"
CLIENTPW="$(secret_get cagw.env CAGW_CLIENT_P12_PW gen_pw 24)"

if [ ! -f server.p12 ]; then
  info "generating CAGW mTLS CA + server + client"
  openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
    -keyout _mtlsca.key -out _mtlsca.crt -subj "/O=onebox/CN=cagw mtls ca"
  # server
  openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr \
    -subj "/O=onebox/CN=${ECA_FQDN}"
  openssl x509 -req -in server.csr -CA _mtlsca.crt -CAkey _mtlsca.key -CAcreateserial \
    -days 1825 -out server.crt \
    -extfile <(printf 'subjectAltName=DNS:%s,DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth,clientAuth\n' "$ECA_FQDN")
  openssl pkcs12 -export -name cagw -inkey server.key -in server.crt -certfile _mtlsca.crt \
    -passout pass:"$P12PW" -out server.p12
  # client (for smoke tests + registered under cagw.clients)
  openssl req -newkey rsa:2048 -nodes -keyout cagw-client.key -out cagw-client.csr \
    -subj "/O=onebox/CN=onebox client 1"
  openssl x509 -req -in cagw-client.csr -CA _mtlsca.crt -CAkey _mtlsca.key -CAcreateserial \
    -days 1825 -out cagw-client.crt \
    -extfile <(printf 'extendedKeyUsage=clientAuth\n')
  openssl pkcs12 -export -name client -inkey cagw-client.key -in cagw-client.crt -certfile _mtlsca.crt \
    -passout pass:"$CLIENTPW" -out cagw-client.p12
  chmod 640 ./*.p12 ./*.key
  secret_put cagw-client.env CAGW_CLIENT_P12 "$CONFIG_DIR/cagw-client.p12"
  secret_put cagw-client.env CAGW_CLIENT_P12_PW "$CLIENTPW"
  secret_put cagw-client.env CAGW_CLIENT_CERT "$CONFIG_DIR/cagw-client.crt"
  secret_put cagw-client.env CAGW_CLIENT_KEY  "$CONFIG_DIR/cagw-client.key"
  ok "mTLS material generated"
else
  ok "server.p12 already present — reusing"
fi

# ---------------------------------------------------------------- 2. licence
: "${CAGW_LICENSE_FILE:?set CAGW_LICENSE_FILE}"
[ -f "$CAGW_LICENSE_FILE" ] || die "not found: $CAGW_LICENSE_FILE"
install -m644 "$CAGW_LICENSE_FILE" "$CONFIG_DIR/license.lic"

# ---------------------------------------------------------------- 3. application.yml
export CAGW_PORT CAGW_CA_ID ECA_FQDN PKIX_PORT XAP_PORT CA_OU_DN DS_SUFFIX \
       DS_ROOT_PW P12PW \
       CAGW_ADMIN_EPF_PW="$CAGW_ADMIN_EPF_PW" \
       DEVICE_CERT_TYPE="${DEVICE_CERT_TYPE:-ent_skp_dualusage}" \
       DEVICE_CERT_DEFINITION="${DEVICE_CERT_DEFINITION:-Dual Usage}" \
       CA_ISSUER_DN="$(printf '%s' "$CA_OU_DN" | awk -F, '{for(i=NF;i>=1;i--)printf "%s%s",$i,(i>1?",":"")}' | sed 's/dc=/DC=/g; s/ou=/OU=/g')"
render "$TEMPLATES_DIR/application.yml.tmpl" "$CONFIG_DIR/application.yml"
chmod 644 "$CONFIG_DIR/application.yml"
chown -R "$CAGW_RUN_USER":"$CAGW_RUN_USER" "$CONFIG_DIR" 2>/dev/null || \
  sudo chown -R "$CAGW_RUN_USER":"$CAGW_RUN_USER" "$CONFIG_DIR"
chmod 600 "$CONFIG_DIR/admin.epf"

info "application.yml written:"
grep -nE 'port:|sm-host:|ldap-host:|profileId|cert-type:|key-client-generated:|ca-id:|base-dn:' "$CONFIG_DIR/application.yml" || true

mark_stage_done 80_cagw_config
