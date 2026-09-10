#!/usr/bin/env bash
# 10_os_prereqs — OS packages, users/groups, firewall, chrony, fstrim, rootless-podman linger.
set -euo pipefail
. "$BOOTSTRAP_ROOT/lib/common.sh"; load_env
guard 10_os_prereqs || exit 0
require_sudo

PKGS=(
  net-tools gawk libnsl tar unzip pciutils gcc make chrony
  readline openssl zlib libxml2 libxslt
  policycoreutils-python-utils
  389-ds-base openldap-clients
  podman
  java-11-openjdk-headless
  expect
)
info "installing packages"
r dnf -y install "${PKGS[@]}"

info "entrust group/user (created by the ECA RPM too, but pre-create for HSM group membership)"
r getent group nfast   >/dev/null || true          # nShield install creates it
r getent group entrust >/dev/null || r groupadd -r entrust
r getent passwd entrust >/dev/null || r useradd -r -g entrust -d /opt/entrust -s /sbin/nologin entrust

info "chrony"
r systemctl enable --now chronyd

info "firewalld + ports"
if ! r systemctl is-enabled firewalld >/dev/null 2>&1; then r systemctl enable --now firewalld; fi
r firewall-cmd --permanent --add-service=ssh   || true
r firewall-cmd --permanent --add-service=dns   || true
r firewall-cmd --permanent --add-service=ldap  || true
r firewall-cmd --permanent --add-service=ldaps || true
for p in "${ASH_PORT}/tcp" "${PKIX_PORT}/tcp" "${XAP_PORT}/tcp" "${CAGW_PORT}/tcp"; do
  r firewall-cmd --permanent --add-port="$p"
done
r firewall-cmd --reload
r firewall-cmd --list-ports

info "fstrim.timer"
r systemctl enable --now fstrim.timer || true

info "rootless podman for $CAGW_RUN_USER"
id "$CAGW_RUN_USER" >/dev/null 2>&1 || die "CAGW_RUN_USER '$CAGW_RUN_USER' does not exist — create it (with a real shell + home) before running"
if ! grep -q "^${CAGW_RUN_USER}:" /etc/subuid; then
  r usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$CAGW_RUN_USER"
  ok "assigned subuid/subgid range to $CAGW_RUN_USER"
fi
r loginctl enable-linger "$CAGW_RUN_USER"
r loginctl show-user "$CAGW_RUN_USER" -p Linger

info "config dir $CONFIG_DIR (owned by $CAGW_RUN_USER for the rootless bind mount)"
r install -d -o "$CAGW_RUN_USER" -g "$CAGW_RUN_USER" -m 0755 "$CONFIG_DIR" "$CONFIG_DIR/plugins"

mark_stage_done 10_os_prereqs
