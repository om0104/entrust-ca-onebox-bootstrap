#!/usr/bin/env bash
# 00_preflight — verify every host prerequisite. Read-only: changes nothing.
set -euo pipefail
. "$BOOTSTRAP_ROOT/lib/common.sh"; load_env

fail=0
chk() { if "$@"; then ok "$*"; else warn "FAILED: $*"; fail=1; fi; }

info "OS + kernel"
. /etc/os-release
[ "${ID:-}" = "ol" ] && ok "ID=ol ($PRETTY_NAME)" || { warn "not Oracle Linux (ID=${ID:-?}) — engine RPM %pre will likely refuse"; fail=1; }
case "${VERSION_ID:-}" in 9.*|9) ok "VERSION_ID=$VERSION_ID" ;; *) warn "VERSION_ID=${VERSION_ID:-?} — need 9.x"; fail=1 ;; esac
kr="$(uname -r)"
case "$kr" in *el9uek*) ok "UEK kernel: $kr" ;; *) warn "kernel '$kr' is not UEK — ECA 10.2 %pre requires kernel-uek on OL. grubby --set-default a kernel-uek entry and reboot."; fail=1 ;; esac

info "hostname / DNS"
fqdn="$(hostname -f 2>/dev/null || true)"
[ -n "$fqdn" ] && [ "$fqdn" = "${fqdn,,}" ] && ok "FQDN is lowercase: $fqdn" || { warn "hostname -f = '$fqdn' — must be a lowercase FQDN"; fail=1; }
[ "$fqdn" = "$ECA_FQDN" ] || warn "hostname -f ($fqdn) != ECA_FQDN in bootstrap.env ($ECA_FQDN)"
ip="$(getent hosts "$fqdn" | awk 'NR==1{print $1}')"
if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ] && [ "$ip" != "::1" ]; then
  ok "forward: $fqdn -> $ip"
  rev="$(getent hosts "$ip" | awk 'NR==1{print $2}')"
  [ "$rev" = "$fqdn" ] && ok "reverse: $ip -> $fqdn" || warn "reverse for $ip is '$rev' (want $fqdn) — fix PTR / /etc/hosts"
else
  warn "$fqdn resolves to '$ip' — put the real IP (not loopback) in /etc/hosts, disable cloud-init manage_etc_hosts"; fail=1
fi

info "privilege"
if [ "$(id -u)" -eq 0 ]; then ok "running as root"
elif sudo -n true 2>/dev/null; then ok "passwordless sudo for $USER"
else warn "need root or passwordless sudo"; fail=1; fi

info "disk"
for m in /opt /var; do
  avail_kb="$(df -Pk "$m" | awk 'NR==2{print $4}')"
  gb=$(( avail_kb / 1024 / 1024 ))
  [ "$gb" -ge 15 ] && ok "$m has ${gb}G free" || { warn "$m has only ${gb}G free (want >=15G each, >=30G total)"; fail=1; }
done

info "time"
if have_cmd chronyc && chronyc tracking >/dev/null 2>&1; then
  off="$(chronyc tracking | awk -F'[: ]+' '/System time/{print $4}')"
  ok "chrony synced (offset ${off}s)"
else warn "chrony not tracking yet — stage 10 installs+enables it, but confirm NTP reachability"; fi

info "SELinux"
if have_cmd getenforce; then ok "SELinux: $(getenforce) (Enforcing is supported)"; fi

info "media ($MEDIA_DIR)"
media=(
  Entrust-Certificate-Authority-10.2.16-40.el9.x86_64.rpm
  Entrust-Certificate-Authority-PostgreSQL-15-15.18.0-49.el9.x86_64.rpm
  EC-RPM-GPG-KEY-2031-03-15.asc
  ECA_10_2_10_Directory_Files.zip
)
for f in "${media[@]}"; do
  [ -f "$MEDIA_DIR/$f" ] && ok "present: $f" || { warn "missing: $MEDIA_DIR/$f"; fail=1; }
done
for v in CAGW_IMAGE_TAR CAGW_LICENSE_FILE CAGW_PCU_ZIP; do
  p="${!v:-}"
  if [ -n "$p" ]; then [ -f "$p" ] && ok "present: $v=$p" || { warn "missing: $v=$p"; fail=1; }; fi
done
if [ -f "$BOOTSTRAP_ROOT/media.sha256" ]; then
  info "verifying checksums (media.sha256)"
  ( cd "$MEDIA_DIR" && sha256sum -c --ignore-missing "$BOOTSTRAP_ROOT/media.sha256" ) && ok "checksums OK" || { warn "checksum mismatch"; fail=1; }
else
  warn "no bootstrap/media.sha256 — skipping checksum verification (recommended: populate it from your download page)"
fi

info "SecWorld installer ($NSHIELD_SW_SRC)"
if [ -e "$NSHIELD_SW_SRC" ]; then ok "present: $NSHIELD_SW_SRC"; else warn "not found: $NSHIELD_SW_SRC (ISO or dir with linux/amd64/{hwsp,ctls,raserv}.tar.gz)"; fail=1; fi

info "HSM reachability (HSM_MODE=$HSM_MODE)"
case "$HSM_MODE" in
  nethsm)
    : "${HSM_NETHSM_ADDR:?}" "${HSM_NETHSM_ESN:?}" "${HSM_NETHSM_KNETI:?}"
    if wait_tcp "$HSM_NETHSM_ADDR" 9004 3; then ok "hardserver $HSM_NETHSM_ADDR:9004 reachable"
    else warn "cannot reach $HSM_NETHSM_ADDR:9004 — check the HSM / network"; fail=1; fi
    if have_cmd /opt/nfast/bin/anonkneti; then
      k="$(/opt/nfast/bin/anonkneti -m0 127.0.0.1 2>/dev/null | awk '{print $2}' || true)"
      [ -n "$k" ] && info "this client's KNETI hash = $k  (authorise it on the HSM if not already)"
    else
      info "SecWorld not installed yet — after stage 20 the client KNETI is: anonkneti -m0 127.0.0.1"
    fi ;;
  rfs)
    : "${HSM_RFS_ADDR:?}"
    wait_tcp "$HSM_RFS_ADDR" 9004 3 && ok "RFS $HSM_RFS_ADDR:9004 reachable" || { warn "cannot reach RFS $HSM_RFS_ADDR:9004"; fail=1; }
    if have_cmd /opt/nfast/bin/enquiry; then
      /opt/nfast/bin/enquiry -m1 2>/dev/null | grep -q operational && ok "a module is operational" || warn "no operational module visible to enquiry"
    fi ;;
  *) warn "HSM_MODE must be 'nethsm' or 'rfs'"; fail=1 ;;
esac

echo
[ "$fail" -eq 0 ] || die "preflight FAILED — resolve the items above and re-run. Nothing was changed."
mark_stage_done 00_preflight
