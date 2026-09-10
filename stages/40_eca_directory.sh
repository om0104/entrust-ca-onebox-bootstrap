#!/usr/bin/env bash
# 40_eca_directory — 389-ds instance, Entrust 10.2 schema, ou=CA entry + ACIs.
set -euo pipefail
. "$BOOTSTRAP_ROOT/lib/common.sh"; load_env
guard 40_eca_directory || exit 0
require_sudo

DIR_ZIP="$(ls "$MEDIA_DIR"/ECA_10_2_*_Directory_Files.zip 2>/dev/null | sort | tail -1)"
[ -f "$DIR_ZIP" ] || die "ECA Directory Files zip not found in $MEDIA_DIR"

DS_ROOT_PW="$(secret_get directory.env DS_ROOT_PW gen_pw 26)"
DS_CA_ENTRY_PW="$(secret_get directory.env DS_CA_ENTRY_PW gen_pw 26)"
secret_put directory.env DS_SUFFIX      "$DS_SUFFIX"
secret_put directory.env DS_INSTANCE    "$DS_INSTANCE"
secret_put directory.env DS_CA_ENTRY_DN "$CA_OU_DN"

# ---------------------------------------------------------------- instance
if r dsctl --list 2>/dev/null | grep -q "slapd-${DS_INSTANCE}\$"; then
  ok "389-ds instance '$DS_INSTANCE' already exists"
else
  info "creating 389-ds instance '$DS_INSTANCE'"
  INF="$(mktemp)"
  cat > "$INF" <<EOF
[general]
full_machine_name = ${ECA_FQDN}
strict_host_checking = False
[slapd]
instance_name = ${DS_INSTANCE}
root_password = ${DS_ROOT_PW}
port = 389
secure_port = 636
self_sign_cert = True
[backend-userroot]
suffix = ${DS_SUFFIX}
create_suffix_entry = True
sample_entries = no
EOF
  r install -m600 "$INF" /root/ds-eca.inf; rm -f "$INF"
  r dscreate from-file /root/ds-eca.inf
  r shred -u /root/ds-eca.inf
fi
r systemctl enable "dirsrv@${DS_INSTANCE}" >/dev/null 2>&1 || true
systemctl is-active "dirsrv@${DS_INSTANCE}" >/dev/null || r systemctl start "dirsrv@${DS_INSTANCE}"

LDAP="ldap://127.0.0.1"
BIND=(-x -H "$LDAP" -D "cn=Directory Manager" -w "$DS_ROOT_PW")

# ---------------------------------------------------------------- schema
info "applying Entrust 10.2 schema"
work="$(mktemp -d)"; ( cd "$work" && unzip -oq "$DIR_ZIP" )
SCHEMA="$(find "$work" -name 'ECA_RedHatDirectoryServer_schema.ldif' | head -1)"
[ -f "$SCHEMA" ] || die "ECA_RedHatDirectoryServer_schema.ldif not in $DIR_ZIP"
# The 10.2 schema LDIF is ldapmodify-format (dn: cn=schema / changetype: modify)
if ldapmodify "${BIND[@]}" -c -f "$SCHEMA" 2>&1 | tee /dev/stderr | grep -qiE 'adding new|modifying entry'; then
  ok "schema applied"
else
  warn "schema ldapmodify produced no 'modifying entry' lines — may already be present (continuing)"
fi
rm -rf "$work"

# ---------------------------------------------------------------- ou=CA + ACIs
if ldapsearch "${BIND[@]}" -b "$CA_OU_DN" -s base dn >/dev/null 2>&1; then
  ok "$CA_OU_DN already present"
else
  info "creating $CA_OU_DN + ACIs"
  OU_RDN_V="$(printf '%s' "$CA_OU_DN" | sed -E 's/^ou=([^,]+),.*/\1/')"
  ldapadd "${BIND[@]}" <<EOF
dn: ${CA_OU_DN}
objectClass: top
objectClass: organizationalUnit
objectClass: pkiCA
objectClass: entrustPolicyObject
ou: ${OU_RDN_V}
userPassword: ${DS_CA_ENTRY_PW}
aci: (targetattr != "userPassword")(version 3.0; acl "Anonymous read"; allow (read,search,compare) userdn = "ldap:///anyone";)
aci: (targetattr = "*")(version 3.0; acl "CA Entry write self"; allow (all) userdn = "ldap:///${CA_OU_DN}";)
EOF
  ok "$CA_OU_DN created"
fi

info "verify bind as ou=CA"
ldapwhoami -x -H "$LDAP" -D "$CA_OU_DN" -w "$DS_CA_ENTRY_PW"

mark_stage_done 40_eca_directory
