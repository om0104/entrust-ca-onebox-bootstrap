#!/usr/bin/env bash
# 85_cagw_run — load the CAGW image and run it as a rootless Podman Quadlet service,
# co-resident with the CA, surviving reboots (linger).
set -euo pipefail
. "$BOOTSTRAP_ROOT/lib/common.sh"; load_env
guard 85_cagw_run || exit 0

RUN_USER="$CAGW_RUN_USER"
asuser() { sudo -iu "$RUN_USER" env BOOTSTRAP_QUIET=1 "$@"; }

# ---------------------------------------------------------------- 1. image
if asuser podman image exists "$CAGW_IMAGE"; then
  ok "image present in $RUN_USER's rootless store: $CAGW_IMAGE"
elif [ -n "${CAGW_IMAGE_TAR:-}" ] && [ -f "$CAGW_IMAGE_TAR" ]; then
  info "podman load < $CAGW_IMAGE_TAR"
  sudo -iu "$RUN_USER" bash -c "podman load -i '$CAGW_IMAGE_TAR'"
else
  info "podman pull $CAGW_IMAGE"
  asuser podman pull "$CAGW_IMAGE"
fi

# ---------------------------------------------------------------- 2. Quadlet unit
UNIT_DIR="/home/$RUN_USER/.config/containers/systemd"
sudo -iu "$RUN_USER" mkdir -p "$UNIT_DIR"
export CAGW_IMAGE CONFIG_DIR ECA_INSTANCE ECA_FQDN
tmp="$(mktemp)"
render "$TEMPLATES_DIR/cagw.container.tmpl" "$tmp"
sudo install -o "$RUN_USER" -g "$RUN_USER" -m 0644 "$tmp" "$UNIT_DIR/cagw.container"
rm -f "$tmp"

# ---------------------------------------------------------------- 3. linger + start
sudo loginctl enable-linger "$RUN_USER"
asuser systemctl --user daemon-reload
asuser systemctl --user start cagw.service
sleep 5
asuser systemctl --user is-active cagw.service || {
  asuser systemctl --user status cagw.service --no-pager | tail -30 || true
  asuser podman logs cagw 2>&1 | tail -40 || true
  die "cagw.service failed to start"
}
asuser podman ps --format '{{.Names}} {{.Status}}'

# ---------------------------------------------------------------- 4. firewall
require_sudo
r firewall-cmd --permanent --add-port="${CAGW_PORT}/tcp" 2>/dev/null || true
r firewall-cmd --reload || true

info "waiting for CAGW to answer on :$CAGW_PORT"
wait_tcp 127.0.0.1 "$CAGW_PORT" 45 && ok "CAGW listening on :$CAGW_PORT" || warn "no listener yet on :$CAGW_PORT (it may still be starting; stage 95 will retry)"

mark_stage_done 85_cagw_run
