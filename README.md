# entrust-ca-onebox-bootstrap

Unattended bootstrap scripts for a **single-host PKI**:

* **Entrust Certificate Authority (ECA) 10.2** — root CA, embedded PostgreSQL 15, 389-ds
  directory, signing key in an **nShield softcard**.
* **Entrust CA Gateway (CAGW) 3.8** — REST issuance API, running **co-resident** on the same
  host as a rootless Podman (Quadlet) service.

End state: `POST /cagw/v1/certificate-authorities/<id>/enrollments` issues a certificate that
chains to the local CA, and the whole box comes back after a reboot with **no operator action**.

> **This repository contains only scripts.** No Entrust or nShield software, installers,
> container images, licence files, or documentation are included or redistributed. You supply
> those from your own Entrust entitlement (see [Media you provide](#media-you-provide)).
> See [`LICENSE`](LICENSE).

📊 **Overview / slides:** [`presentation/index.html`](presentation/index.html) — open in a browser.
🏗  **Architecture + the device-identity API:** [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

---

## Why

CA Gateway 3.8's supported-CA matrix is ECA **8.3 / 10.1.1 / 10.2**, so this bundle builds
**CAGW 3.8 + a supported ECA 10.2 CA**. For a lab or a small deployment there is no reason to
spread it across hosts.

> **Note (corrected 2026-11-20):** an earlier version of this README said CAGW 3.8 cannot issue
> against a newer ECA (`cagw-5501`, "activation-code format rejected"). That was wrong. The
> `cagw-5501` came from the CAGW admin's role lacking **View activation codes**, so the CA masked
> the code. With that permission, CAGW 3.8 issued against ECA 11.0.1 in our lab. That pairing is
> still outside the published support matrix. See `stages/70_PAUSE_ecaa_stepd.md` step 3. This bundle stands the whole
thing up on one VM, unattended, and makes it survive reboots.

It was built from a working reference deployment and captures the parts that are easy to get
wrong: the OL9 + UEK kernel requirement, the `net-tools` prerequisite, the "no pure
module-protection" nShield rule (softcard + held `preload … pause`), the 10.2-only autologin
syntax, the stock-`entca.service`-no-drop-ins rule under SELinux, the X.500 root-first CSR
subject order the SecurityManager connector needs, and the certificate type / role permissions
CAGW's admin identity must have.

---

## The one manual step

Everything is automated **except one GUI action**. ECA 10.2's control shell has no user/role
commands, so the CAGW admin identity is created in the CA through the **Entrust Certificate
Authority Administration (ECAA) 10.2** Windows GUI — about ten clicks. The bootstrap pauses,
prints the exact procedure ([`stages/70_PAUSE_ecaa_stepd.md`](stages/70_PAUSE_ecaa_stepd.md)),
and you paste back a reference number + activation code to continue. Provide those up front in
`bootstrap.env` and it never stops.

---

## Host prerequisites

Run **on the target VM**. Stage `00_preflight` verifies all of this and refuses to proceed
otherwise — it changes nothing.

| Requirement | Check / note |
|---|---|
| **Oracle Linux 9.x** (9.2+ ; 9.8 tested) | `cat /etc/os-release`. The ECA 10.2 engine RPM is `.el9` and its pre-install check is "RHEL/OL 9 only". |
| **UEK kernel** — `uname -r` ends `…el9uek` | For `ID=ol` the engine RPM **requires** `kernel-uek`. The OL9 KVM cloud image boots it by default; otherwise `grubby --set-default` a `kernel-uek` entry and reboot. |
| **Lowercase FQDN**, forward + reverse DNS | `hostname -f` lowercase and resolvable; `getent hosts <fqdn>` returns the real IP (not loopback); PTR agrees. |
| **≥ 30 GB free** across `/opt` + `/var` | ECA + PostgreSQL + the CAGW image (~2 GB) + working space. |
| **Root or passwordless sudo** | Every stage except the CAGW-config ones needs root. |
| **SELinux Enforcing is fine** | The scripts do the `chcon` / `semodule` fixups. |
| **Outbound to the OS repos** | `dnf` installs the packages below. No Entrust repo needed. |
| **NTP in sync** | `chronyc tracking`. |
| **An nShield Security World** reachable | See [HSM](#hsm). |
| **A Windows box with ECAA 10.2.14** | For the one manual step. Not provisioned here. |

### OS packages (installed by `10_os_prereqs`)

```
net-tools gawk libnsl tar unzip pciutils gcc make chrony
readline openssl zlib libxml2 libxslt
policycoreutils-python-utils
389-ds-base openldap-clients
podman
java-11-openjdk-headless
expect
```

Plus: `chronyd`, `firewalld` (opens ASH/PKIX/XAP + the CAGW port), `fstrim.timer`,
`loginctl enable-linger` for the rootless-container user, and `subuid`/`subgid` ranges for it.

* `net-tools` is required by the ECA 10.2 installer.
* `gawk` + `libnsl` are the documented ECA prerequisites.
* `java-11-openjdk-headless` is only for the profile utility — ECA and CAGW ship their own JRE.
  Do **not** use Java 21 for that tool.
* **Optional: a JDK 17+** (e.g. `java-17-openjdk-devel`) for `helpers/cagw_role_check.sh`,
  the read-only CAGW admin role check that stage 95 runs. The Entrust toolkit jars are Java 17
  class files. The helper finds the JDK under `/usr/lib/jvm` (or `JDK_HOME`) by full path and never
  uses the default `java`. If installing it switches the default, set it back to 11 for `pcu.sh`:
  `alternatives --config java`. Without a JDK 17+, stage 95 skips the check with a warning.

---

## HSM

The CA signing key lives in an nShield **softcard** (default name `eca-ca3`), created by
stage 20 with an auto-generated passphrase. There is **no pure module-protection path** for
ECA on nShield — a softcard (or OCS) with a held `preload … pause` session is mandatory; stage
60 installs that as a systemd unit so it survives reboots.

Two ways to attach the HSM (`HSM_MODE` in `bootstrap.env`):

* **`nethsm`** (default) — the VM enrols to a remote hardserver that exports a module
  (nShield Connect / 5c, or a 5s in another host acting as a NetHSM). Set `HSM_NETHSM_ADDR`,
  `HSM_NETHSM_ESN`, `HSM_NETHSM_KNETI`. **The client must be authorised on the HSM first** —
  on a managed HSM your HSM admin does this; for a module in a host you control, run
  [`helpers/hsm_authorize_client.sh`](helpers/hsm_authorize_client.sh) **on that host** (it
  backs up the hardserver config and refuses to modify existing client records).
* **`rfs`** — the Security World is delivered by an RFS you can `rfs-sync` from
  (`HSM_RFS_ADDR`) and a module is already visible to `enquiry`.

`NSHIELD_SW_SRC` points at the Security World Software installer (a mounted ISO or an unpacked
tree containing `linux/amd64/{hwsp,ctls,raserv}.tar.gz`).

---

## Media you provide

Drop into `./media/` (or set `MEDIA_DIR`). Stage `00` checks presence and verifies SHA-256 for
any file you list in `media.sha256`.

| File | Purpose |
|---|---|
| ECA 10.2.x engine RPM (`…​.el9.x86_64.rpm`) | the CA engine |
| ECA 10.2 embedded PostgreSQL 15 RPM (`…​.el9.x86_64.rpm`) | the database |
| Entrust RPM signing key (`.asc`) | `rpm --import` + `rpm -K` |
| ECA 10.2 "Directory Files" zip | contains the 389-ds schema LDIF |
| CAGW 3.8 container image (`…docker.tar.gz`) | `podman load` — or set `CAGW_IMAGE_TAR=""` to pull |
| CAGW Profile Creation Utility zip (Linux) | builds the CAGW admin `.epf` |
| signed CAGW licence bundle (`.lic`) | required by the container |
| Security World Software ISO/tree | nShield client (see [HSM](#hsm)) |
| ECAA 10.2.14 MSI (on the Windows box) | the one manual step |

None of these are in this repo. Filenames referenced by the scripts are matched by glob so
minor version differences are tolerated.

---

## Run it

```bash
git clone https://github.com/om0104/entrust-ca-onebox-bootstrap.git
cd entrust-ca-onebox-bootstrap
cp bootstrap.env.example bootstrap.env
$EDITOR bootstrap.env            # identity, HSM, media paths, licence values

./bootstrap.sh                   # runs stages 00 → 95; resumes at the last failed/unrun stage
```

* **Secrets are generated on first run** into `./secrets/*.env` (mode 0600) and reused on
  re-runs. **Back up `./secrets/` — there is no other copy of the CA Master User passwords.**
* Logs: `./logs/<stage>.log`. Stage markers: `./.state/<stage>.done`
  (`FORCE=1 ./bootstrap.sh --only <n>` re-runs one stage).
* The run pauses before stage 75 unless `CAGW_ADMIN_REF` / `CAGW_ADMIN_AUTHCODE` are set.

| Stage | Does |
|---|---|
| `00_preflight` | verify OS, kernel, DNS, hostname, disk, sudo, media, HSM reachability. No changes. |
| `10_os_prereqs` | packages, users/groups, firewalld + ports, chrony, fstrim, linger. |
| `20_nshield_client` | Security World install, enrol module (`nethsm`/`rfs`), create softcard, `cknfastrc`. |
| `30_eca_database` | GPG import + verify, install PostgreSQL RPM, silent DB setup. |
| `40_eca_directory` | `dscreate from-file`, load the directory schema, create the CA entry + ACIs. |
| `50_eca_engine` | install the CA engine, silent `config_authority.sh`, first-time `init` under a held `preload` (expect). |
| `60_eca_systemd` | autologin, boot-persistent softcard preload unit, stock CA service, enable, verify. |
| *70 (manual)* | ECAA Step D — create the CAGW admin user, capture reference # + activation code. |
| `75_cagw_admin_epf` | Profile Creation Utility (expect) → `admin.epf`. |
| `80_cagw_config` | generate CAGW mTLS CA/server/client, render `application.yml`, place the licence. |
| `85_cagw_run` | `podman load`, rootless Quadlet `cagw.container`, `enable-linger`, start. |
| `95_verify` | `/status` all UP → `POST enrollments` → `openssl verify` to the CA root. `REBOOT=1` optional. |

---

## What you get

* CA root cert + CRL published in the directory; listeners on the ASH / PKIX-CMP / XAP ports.
* CA service + softcard-preload service enabled — the CA returns unattended after reboot.
* `cagw.service` (rootless, linger on) — REST API with mutual-TLS.
* Two enrolment profiles: `profileId "0"` device-generated key (PKCS#10 → X.509) and
  `profileId "1"` CA-generated key (→ PKCS#12; needs one ECAA policy toggle, documented in
  [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)).
* `secrets/cagw-client.env` — a ready-made mTLS client identity for smoke tests.

---

## Safety

* Every stage is guarded by a `.state/<stage>.done` marker and is safe to re-invoke.
* Stage 20 never re-initialises a Security World and skips softcard creation if it exists.
* `helpers/hsm_authorize_client.sh` backs up the hardserver config and aborts if any existing
  client record would change.
* `helpers/cagw_role_check.sh` is read-only: it logs in with `admin.epf`, reads the CAGW
  admin's own role by ID, and reports OK/MISS for Perform PKIX requests, Create user profile,
  Change user's role and View activation codes. Exit 0 = pass, 1 = missing, 2 = could not check.
* No stage deletes data. To start over, remove the CA / PostgreSQL / directory instances by hand.

---

## Status & contributions

Built and reboot-verified against one reference deployment (OL 9.8 + UEK, nShield 5s as
NetHSM, ECA 10.2.16, CAGW 3.8.0). Treat version-specific globs and `expect` prompt patterns as
the fragile parts — issues and PRs welcome, especially for other ECA 10.2.x point releases and
other nShield topologies.
