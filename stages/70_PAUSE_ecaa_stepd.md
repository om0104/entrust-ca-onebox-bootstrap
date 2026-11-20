# Stage 70 (manual) — ECAA Step D: create the CAGW admin identity

ECA 10.2's control shell has no user/role commands, so this one step is done in the
**Entrust Certificate Authority Administration (ECAA) 10.2 GUI** on Windows. It takes ~10
clicks. When you finish you will have a **reference number** and an **activation code** —
paste those into `bootstrap.env` and re-run `./bootstrap.sh`.

## Prerequisites on the Windows box

* ECAA **10.2.14** installed (`EntrustCertificateAuthorityAdministration.10.2.14.40.msi`)
  plus the **VC++ 2015–2022 x64** redistributable.
* The CA's `First Officer.epf` (created during stage 50) and a client `entrust.ini` pointing at
  this host — copy them from the CA host:
  * EPF: `/opt/entrust/authdata/CA/manager/epf/First Officer.epf`
  * the First Officer unlock password: `secrets/eca.env` → `ECA_FIRST_OFFICER_PW`
  * `entrust.ini`: point `Authority`/`Manager` at `<ECA_FQDN>` with ports
    `PKIX=<PKIX_PORT>`, `ASH=<ASH_PORT>`, `XAP=<XAP_PORT>`, SearchBase `<CA_OU_DN>`.
* Network: the Windows box must reach this host on the ASH/XAP/LDAP ports.

## Procedure

1. **Launch ECAA**, connect with `First Officer.epf` (+ its `entrust.ini`), unlock with the
   First Officer password.

2. **Create the CAGW admin user.**
   `Users` → `New User`.
   * Common name: `cagw xapv2` (DN becomes `cn=cagw xapv2,<CA_OU_DN>`).
   * **Certificate type: `Admin Services User Management`** (`ent_admsrvcs_usrmgmt`).
     This is the type that carries the XAP policy OID **`2.16.840.1.114027.10.4`**
     (`id-Entrust-AdminServicesClients`).
     Do **not** pick `Admin Services User Management **Administrator**` (OID `…10.21` — wrong)
     and there is **no "XAP Client" type** in 10.2 (`XAP Server` is OID `…10.5` — also wrong).
   * Finish. ECAA shows **Reference number** and **Authorization code** — record both.

3. **Give the user the right role + permissions.**
   * Assign role **`User Administrator`** (or a least-privilege custom role).
   * Edit that role → category **Users** → tab **User - Advanced** → tick:
     * **`Perform PKIX requests`**  ← without this the CA rejects CAGW's RA-signed CMP
       (`(-2207) … EntrustProofOfRA … insufficient permissions`).
     * **`Create user profile`**
     * `Change user's role` (usually already ticked)
   * Category **Users** → tick **`View activation codes`**. Without it, ECA returns every
     activation code masked as `****-****-****`, and every enrolment fails with
     `cagw-5501 "Authorization code contained invalid characters"`. `User Administrator` has it
     by default; a least-privilege custom role does **not**.
   * Check the role's **Summary** tab: `Perform PKIX requests`, `Create user profile` and
     `View activation codes` must all read **Yes**.
   * **Commit the security policy** (`Security Policy` → `Commit`), wait for it to propagate.

4. **(Optional, verify)** After the directory publishes the user's cert, confirm the policy OID:
   `openssl x509 -in <user cert> -noout -ext certificatePolicies` → must list `2.16.840.1.114027.10.4`.

## Resume

Put the two values in `bootstrap.env`:

```
CAGW_ADMIN_REF=<reference number>
CAGW_ADMIN_AUTHCODE=<activation / authorization code>
```

then:

```
./bootstrap.sh          # continues from stage 75_cagw_admin_epf
```
