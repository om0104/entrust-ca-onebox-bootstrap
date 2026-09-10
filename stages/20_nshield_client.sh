#!/usr/bin/env bash
# 20_nshield_client — Security World software, module enrolment, and the CA softcard.
# Never re-initialises a Security World. Never edits an HSM this host does not own
# (authorise the client on the HSM side first — see bootstrap/README.md §4).
set -euo pipefail
. "$BOOTSTRAP_ROOT/lib/common.sh"; load_env
guard 20_nshield_client || exit 0
require_sudo

NFAST=/opt/nfast
NFBIN=$NFAST/bin

# ---------------------------------------------------------------- 1. install SW
if [ ! -x "$NFBIN/enquiry" ]; then
  info "installing Security World Software from $NSHIELD_SW_SRC"
  src="$NSHIELD_SW_SRC" mnt=""
  if [ -f "$src" ]; then
    mnt="$(mktemp -d)"; r mount -o loop,ro "$src" "$mnt"; src="$mnt"
  fi
  [ -d "$src/linux/amd64" ] || die "expected $src/linux/amd64/{hwsp,ctls,raserv}.tar.gz"
  tmp="$(mktemp -d)"; cp "$src"/linux/amd64/{hwsp,ctls,raserv}.tar.gz "$tmp/"
  ( cd / && r tar -xf "$tmp/hwsp.tar.gz" && r tar -xf "$tmp/ctls.tar.gz" && r tar -xf "$tmp/raserv.tar.gz" )
  r "$NFAST/sbin/install"
  rm -rf "$tmp"
  [ -n "$mnt" ] && { r umount "$mnt"; rmdir "$mnt"; } || true
  ok "SecWorld installed"
else
  ok "SecWorld already installed ($($NFBIN/enquiry 2>/dev/null | awk -F': ' '/Version/{print $2; exit}'))"
fi
r usermod -aG nfast "$CAGW_RUN_USER" || true
r usermod -aG nfast entrust || true
r systemctl enable --now nc_hardserver

# ---------------------------------------------------------------- 2. attach module
case "$HSM_MODE" in
  nethsm)
    if ! r "$NFBIN/nfkminfo" 2>/dev/null | grep -q "n_modules  *[1-9]"; then
      info "enrolling to NetHSM $HSM_NETHSM_ADDR ($HSM_NETHSM_ESN)"
      r "$NFBIN/nethsmenroll" --module=1 --no-hkneti-confirmation \
        "$HSM_NETHSM_ADDR" "$HSM_NETHSM_ESN" "$HSM_NETHSM_KNETI"
      r "$NFBIN/hsc_nethsmimports"
    fi
    if ! r test -f "$NFAST/kmdata/local/world"; then
      warn "no Security World data present locally."
      warn "Copy 'world' + 'module_${HSM_NETHSM_ESN}*' from the HSM/RFS into $NFAST/kmdata/local/ (owner nfast, mode 0644), then re-run:  FORCE=1 ./bootstrap.sh --only 20"
      die  "Security World data required."
    fi ;;
  rfs)
    : "${HSM_RFS_ADDR:?}"
    info "rfs-sync from $HSM_RFS_ADDR"
    r "$NFBIN/rfs-sync" --setup --no-authenticate "$HSM_RFS_ADDR" || true
    r "$NFBIN/rfs-sync" --update ;;
esac

sleep 15
r "$NFBIN/enquiry" -m1 | grep -E 'mode|serial number' || true
r "$NFBIN/nfkminfo" | grep -E 'n_modules|state' || true

# ---------------------------------------------------------------- 3. cknfastrc (CA-init variant)
info "writing $NFAST/cknfastrc (forces softcard; hides module-only slot for CA init)"
r install -d -m 0770 -o nfast -g nfast "$NFAST/kmdata/local"
r tee "$NFAST/cknfastrc" >/dev/null <<EOF
# ECA CA-init variant — forces Softcard protection
CKNFAST_LOADSHARING=1
CKNFAST_NO_UNWRAP=1
CKNFAST_FAKE_ACCELERATOR_LOGIN=1
CKNFAST_NO_ACCELERATOR_SLOTS=1
CKNFAST_OVERRIDE_SECURITY_ASSURANCES=none
NFAST_NFKM_TOKENSFILE=$NFAST/entrustsmtoken
EOF
r touch "$NFAST/entrustsmtoken"
r chown root:nfast "$NFAST/entrustsmtoken"; r chmod 0660 "$NFAST/entrustsmtoken"
[ -f "$NFAST/toolkits/pkcs11/libcknfast.so" ] && r chmod a+rx "$NFAST/toolkits/pkcs11/libcknfast.so"
# SELinux: hand-created files under /opt/nfast get mislabelled on OL9
if have_cmd chcon; then r chcon -u unconfined_u -t usr_t "$NFAST/cknfastrc" "$NFAST/entrustsmtoken" 2>/dev/null || true; fi

# ---------------------------------------------------------------- 4. softcard
SC_PP="$(secret_get nshield.env SOFTCARD_PP gen_pw 28)"
if r "$NFBIN/nfkminfo" --softcard-list 2>/dev/null | grep -q "$SOFTCARD_NAME"; then
  ok "softcard '$SOFTCARD_NAME' already exists"
else
  info "creating softcard '$SOFTCARD_NAME'"
  r install -m 0600 /dev/null "$NFAST/kmdata/config/eca-sc.pp"
  printf '%s' "$SC_PP" | r tee "$NFAST/kmdata/config/eca-sc.pp" >/dev/null
  r bash -c "cat > /tmp/mk_sc.exp <<'EXP'
#!/usr/bin/expect -f
set pp [lindex \$argv 0]
set timeout 60
spawn $NFBIN/ppmk --new $SOFTCARD_NAME
expect { -nocase {passphrase} { send -- \"\$pp\r\"; exp_continue }
         -nocase {retype|again|confirm} { send -- \"\$pp\r\"; exp_continue }
         eof }
EXP
chmod +x /tmp/mk_sc.exp"
  r /tmp/mk_sc.exp "$SC_PP"
  r rm -f /tmp/mk_sc.exp
  r "$NFBIN/nfkminfo" --softcard-list | grep -q "$SOFTCARD_NAME" && ok "softcard created" || die "softcard creation failed"
fi
if have_cmd chcon; then r chcon -u unconfined_u -t usr_t "$NFAST/kmdata/config/eca-sc.pp" 2>/dev/null || true; fi

# ---------------------------------------------------------------- 5. functional test
info "PKCS#11 functional test (softcard-protected key, then delete)"
r bash -c "cat > /tmp/gk.exp <<'EXP'
#!/usr/bin/expect -f
set pp [lindex \$argv 0]
set timeout 120
spawn $NFBIN/preload -s $SOFTCARD_NAME -f $NFAST/entrustsmtoken $NFBIN/generatekey -b pkcs11 protect=softcard type=RSA size=2048 plainname=bootstrap_sctest
expect { -nocase {passphrase} { send -- \"\$pp\r\"; exp_continue } eof }
EXP
chmod +x /tmp/gk.exp"
r /tmp/gk.exp "$SC_PP" || warn "keygen test returned non-zero (inspect the log)"
r rm -f /tmp/gk.exp "$NFAST"/kmdata/local/key_pkcs11_*bootstrap_sctest* 2>/dev/null || true

mark_stage_done 20_nshield_client
