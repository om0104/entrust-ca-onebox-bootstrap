#!/usr/bin/env bash
# hsm_authorize_client.sh — RUN THIS ON THE nSHIELD HOST (the machine whose hardserver
# exports the module), not on the CA VM.
#
# Adds one client to [hs_clients] in the hardserver config so the CA VM may enrol as a
# NetHSM client. Safe: backs up the config, and ABORTS if any existing client record
# (address or keyhash) would change. Multiple records are separated by a line of exactly
# five dashes, which is the only separator the config parser accepts.
#
# On a managed HSM (nShield Connect / 5c with an HSM admin) you do NOT run this — your
# HSM administrator authorises the client through their own process. This helper exists
# for the lab pattern where the module lives in a host you control.
#
#   sudo ./hsm_authorize_client.sh <client-ip> <client-kneti-hash>
#
# client-kneti-hash: on the CA VM run  /opt/nfast/bin/anonkneti -m0 127.0.0.1
set -euo pipefail

CFG=/opt/nfast/kmdata/config/config
ADDR="${1:?usage: hsm_authorize_client.sh <client-ip> <client-kneti-hash>}"
KEYHASH="${2:?usage: hsm_authorize_client.sh <client-ip> <client-kneti-hash>}"
[ -f "$CFG" ] || { echo "no $CFG on this host — are you on the nShield host?" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

BAK="$CFG.bak.$(date +%s)"
cp -p "$CFG" "$BAK"
echo "backed up -> $BAK"

python3 - "$CFG" "$ADDR" "$KEYHASH" <<'PY'
import sys, re
cfg, addr, kh = sys.argv[1:4]
s = open(cfg).read()
lines = s.split('\n')

# capture existing hs_clients records for a safety diff
def records(text):
    out, cur, inblk = [], [], False
    for ln in text.split('\n'):
        if ln.strip() == '[hs_clients]':
            inblk = True; continue
        if inblk and re.match(r'^\[.+\]$', ln.strip()):
            if cur: out.append('\n'.join(cur))
            inblk = False; cur = []
            continue
        if inblk:
            if ln.strip() == '-----':
                if cur: out.append('\n'.join(cur))
                cur = []
            else:
                cur.append(ln)
    if cur: out.append('\n'.join(cur))
    return [r for r in out if r.strip()]

before = records(s)
if any(f'addr={addr}' in r for r in before):
    print(f'client addr={addr} already present — nothing to do'); sys.exit(0)

new_rec = ['-----', f'addr={addr}', 'clientperm=unpriv', f'keyhash={kh}', '']
out, i = [], 0
inserted = False
while i < len(lines):
    out.append(lines[i])
    if lines[i].strip() == '[hs_clients]':
        i += 1
        # copy the existing block verbatim
        while i < len(lines) and not re.match(r'^\[.+\]$', lines[i].strip()):
            out.append(lines[i]); i += 1
        out += new_rec
        inserted = True
        continue
    i += 1
if not inserted:
    out += ['', '[hs_clients]'] + new_rec[1:]

after_text = '\n'.join(out)
after = records(after_text)

# every record that existed before must still exist unchanged
norm = lambda r: '\n'.join(sorted(x.strip() for x in r.split('\n') if x.strip()))
b = {norm(r) for r in before}
a = {norm(r) for r in after}
missing = b - a
if missing:
    print('ABORT: an existing [hs_clients] record would change:', file=sys.stderr)
    for m in missing: print('  ---\n  ' + m.replace('\n', '\n  '), file=sys.stderr)
    sys.exit(2)

open(cfg, 'w').write(after_text)
print(f'added [hs_clients] record: addr={addr} keyhash={kh}')
print(f'existing records preserved: {len(before)} -> {len(after)}')
PY

echo "re-reading hardserver config..."
/opt/nfast/bin/cfg-reread
# nShield 5s NetHSM export path (harmless / no-op on other setups):
[ -x /opt/nfast/bin/hsc_nethsmexports ] && /opt/nfast/bin/hsc_nethsmexports || true
echo "done. If anything looks wrong: cp -p '$BAK' '$CFG' && /opt/nfast/bin/cfg-reread"
