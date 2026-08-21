# Uten IMP signed release and staging contract

<!-- CURRENT-ERP-TEST-SERVER-SCOPE-20260814 -->
> **Current execution scope (2026-08-15):** the intended host is an internal ERP test server only.
> PostgreSQL, the Spring backend, and Flutter ERP Web/Nginx are in scope after the reviewed 350 GiB
> LVM-on-NVMe `/data` transaction completes. The desktop SMR RAID leaves the ERP path and remains
> unmodified only as short-term rollback evidence. The corporate Next.js website is deferred to a separate future cloud
> host. Automatic staging remains disabled; this contract does not authorize deployment from the
> current dirty working tree. The last host facts are an unrefreshed 2026-08-12 read-only snapshot;
> there is no current authorization to run target-host write, enable/start, database, activation, or
> reboot commands. See `../current-test-server-status.zh-CN.md` for the controlled sequence.

Evidence layers are intentionally separate: the repository contains a source candidate, but no
reviewed commit/tag, CI-signed publication, immutable OSS read-back, target installation/activation,
or HTTPS/UAT/fault/reboot acceptance has been completed for this candidate. The target remains
**NO-GO**; a local build or script test must not be reported as any later layer.

## Single-maintainer internal-test offline exception

[`SINGLE_MAINTAINER_INTERNAL_TEST_RUNBOOK.zh-CN.md`](SINGLE_MAINTAINER_INTERNAL_TEST_RUNBOOK.zh-CN.md)
and [ADR-044](../../docs/99-决策记录-ADR/ADR-044-单维护者内部测试离线发布例外.md)
define an independent compensating control for the current one-maintainer private repository.
It does not pretend that a second reviewer exists, does not require making the ERP repository public,
and does not weaken this signed production workflow.

The new `unsigned-release-candidate.yml` is dispatch-only and can only read repository, Actions, and
Checks data. Its reusable builder has no Environment, secret, OIDC, OSS, signing, staging, or activation
capability. It binds exact main CI, emits the existing seven-member unsigned candidate for one day,
and reads the raw artifact ZIP back by artifact ID/service digest/size/run/head SHA. The manifest keeps
the existing `refs/tags/<version>` and updater schema contract even though the workflow runs from main.

The candidate then leaves GitHub. A pre-reviewed, digest-pinned stdlib-only verifier does not execute
candidate content. Separate offline authorities verify the signed annotated tag object and sign the
manifest, channel, updater-wheelhouse attestation, and single-maintainer decision. Tag bundles are
verified and fetched in a brand-new empty bare repository so a thin bundle cannot borrow local objects.
Both offline verification and online planning bind the artifact sidecar and standalone backend/Flutter
SBOMs back to the signed manifest, and the attestation back to signed lineage evidence; recomputing an
unsigned inventory or receipt cannot substitute those bytes.
An online management machine may later use short-lived credentials, verify the old signed
pointer/sequence, claim one permanent create-only transition record for that old pointer, publish to
the existing updater-compatible object keys, read back every uploaded byte with explicit size bounds,
and advance `LATEST` last. The offline machine has no GitHub, OSS, or server credentials. Git tag,
Release artifact, Admin A, Admin B, and server Host keys remain separate.
`ossPublicationAuthorized=false` in the single-maintainer decision is intentional: that record never
grants cloud-write authority. A later apply needs a separate approved plan digest, exact confirmation,
change authorization, and short-lived STS.

Merging the framework does not run the workflow or create an unsigned candidate. No tag, GitHub Release,
signature, OSS object, staging operation, activation, UAT, or recovery evidence is produced by the PR.
H01-H12 and project-specific `known_hosts` remain prerequisites even for read-only SSH; updater/retention
timers remain disabled and all staging/root activation remains manual.

This directory defines the first phase of the production release chain. A release is built only
after the full backend and Flutter test gates pass. The build job has no release or cloud secrets.
It uploads one unsigned candidate whose GitHub artifact-service ID and SHA-256 are bound to the
workflow run and protected commit. A fresh, environment-approved publish job has no checkout and
does not execute repository scripts or project dependencies; it downloads that exact artifact,
re-verifies its service digest, inner inventory, manifest contract, Flyway checksums, and SBOMs,
then signs immutable metadata and uploads it to OSS. The unprivileged staging service can download,
authenticate, safely extract, and stage a candidate, but it cannot modify `/opt`, read `server.env`, call
`systemctl`, or activate a release.

The current implementation is install-only: operators may start one reviewed staging oneshot, but
the timer remains disabled. The repository now contains a separately reviewed retention/quota/alert
control, but there is no supported `--enable-staging` path until it is commissioned and accepted on
the real Linux filesystems with power-loss fault injection and external alert-delivery evidence.

Activation is a separate, explicit root operation. It re-verifies the Ed25519 signatures, signed
channel, manifest, archive, staged marker, payload inventory, release sequence, Flyway metadata,
and installed-file ownership before switching `current`.

CI also stamps the built `index.html` release meta exactly once and creates signed-payload
`web/version.json` with the canonical version, sequence, and full commit SHA. Flutter 3.44.2 first
generates its fixed `uten_imp` package-metadata `version.json`; the stamper captures that exact
single-link preimage through a stable directory/file descriptor and rejects missing, old-schema,
forged, linked, or replaced evidence before rewriting it. The `index.html` and `version.json`
rewrite is bound by an exclusive, fsynced transaction marker: an interrupted build may resume only
from the marker's exact preimage/final digests, and the marker is removed durably only after a joint
stable-descriptor verification of both final files. A missing/duplicate
`__UTEN_RELEASE_VERSION__` token fails publication. The browser can therefore compare its initial
signed release identity with a cache-bypassed `version.json`, rather than treating the first remote
response as an unknown baseline.

The signed payload contains exactly two server executables:
`server/uten-imp-server.jar` and `server/uten-imp-migrator.jar`. The manifest names each fixed
path, SHA-256, and byte size explicitly, and its signed `SHA256SUMS` digest covers both again. CI
opens both JARs and requires their complete `db/migration/**` filename/content inventory to equal
the Flyway-generated signed migration inventory; the migrator must also name
`com.uten.imp.migration.UtenImpMigrator` as its executable Main-Class. Missing, extra, empty, or
disagreeing server JARs fail before signing. The isolated publish job independently opens the
release archive without executing it and repeats the exact-set, size, inventory, and JAR digest
checks.

## GitHub and signing prerequisites

Production publication is fail-closed unless all of the following are configured:

1. The final repository owner, organization, visibility, and GitHub plan are frozen before OIDC is
   rendered. For a private repository, GitHub's current documentation limits Environment required
   reviewers on Free/Pro/Team to public repositories. This contract therefore requires a plan that
   supports private-environment required reviewers, or a separately implemented and reviewed
   external/offline approval design. Do not make the ERP repository public to bypass this gate.
2. `main` has branch protection or a ruleset with non-author review, current required quality
   checks, conversation resolution, signed commits, no force-push/deletion, and no unreviewed
   bypass. Human Git commit/tag signing uses a dedicated account signing key; it is not the Release
   artifact key and is never an administrator SSH login key.
3. release tags matching `v*` are covered by a tag ruleset. A release tag is a signed annotated tag,
   is independently verified, and points exactly at the current `origin/main` commit. CI re-queries
   protected `main` immediately before signing and again before publication; if `main` advances,
   the release fails closed and must use the next immutable version counter. Versions use
   `vYYYY.MM.DD-N`, where `N` is `1..999`. The current workflow enforces tag protection and source
   equality but does not yet verify the tag-object signature; retain `git verify-tag` and GitHub
   `Verified` evidence until that check is added to CI.
4. the independent `production-release-publisher` and `production-release-bootstrap` environments
   have required reviewers, prevent self-review, and allow deployments only from protected release
   tags matching `v*`; an empty Environment without those available controls is not an approval
   boundary. Listing multiple required reviewers does not make every reviewer mandatory, so any
   stronger two-approval policy must also be enforced by PR review or an external change system.
   The interim signing private key exists only as the publisher environment's
   `RELEASE_SIGNING_PRIVATE_KEY` secret, never as a repository
   secret available to build/test jobs. The publish job runs on a new GitHub-hosted runner, has no
   checkout, and removes the key from its environment before starting any child process.
5. Actions are pinned by full commit SHA, and repository/organization Actions policy enforces that
   rule where available. Do not replace them with floating tags.
6. Both environments define non-secret variables `ALIYUN_OIDC_PROVIDER_ARN`,
   `ALIYUN_OSS_BUCKET`, `ALIYUN_OSS_ENDPOINT`, and `ALIYUN_OSS_REGION`, plus
   `RELEASE_ALLOWED_SIGNERS` containing canonical three-field
   `uten-imp-release ssh-ed25519 BASE64` lines for every currently authorized release key. The
   publisher environment defines only `ALIYUN_RELEASE_PUBLISHER_ROLE_ARN`; bootstrap defines only
   `ALIYUN_RELEASE_BOOTSTRAP_ROLE_ARN`. Aliyun trust must bind the exact issuer, audience, repository,
   and corresponding Environment subject. Repository transfer/rename and GitHub immutable
   repository-ID subject formats can change `sub`; always capture the actual non-secret `iss/aud/sub`
   from the acceptance job and render trust from that evidence. Because an Environment subject does
   not itself prove the tag ref, protected-tag rules, selected `v*` Environment deployment rules,
   and workflow ref checks enforce the tag together.

The four key roles are deliberately separate: human Git commit/tag signing, Release manifest/channel
signing, administrator SSH Key A/B, and the server's own SSH Host Key. The same private key must never
cross those roles. Follow
[`GITHUB_SIGNING_AND_PROTECTION_SETUP.zh-CN.md`](GITHUB_SIGNING_AND_PROTECTION_SETUP.zh-CN.md) for
the screen-by-screen configuration and retained evidence. GitHub feature availability and UI labels
can change; re-check the official
[deployment-environment documentation](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
on the commissioning date rather than relying on an old screenshot.

<!-- ALIYUN-OIDC-PUBLISHER-POLICY-NO-GO -->
The repository now contains a strictly rendered and tested policy bundle under
`deploy/aliyun-oidc`, but it deliberately has no automatic production apply helper. Commissioning
CI publication remains **NO-GO** until Security/Cloud Ops independently reviews the rendered
issuer/audience/subjects and OSS resources/actions, applies them through a controlled change,
records exact RAM/OSS read-back plus positive/wrong-subject OIDC evidence, and verifies live
Versioning and locked COMPLIANCE WORM. RAM still cannot enforce create-only/CAS for PutObject;
client `forbid-overwrite`, GitHub concurrency, byte read-back, Versioning, and WORM mitigate but do
not erase that limitation. Do not improvise a broader role to make the workflow pass.

The workflow deliberately does not call the environments-administration API with `github.token`:
the token has no safe environment-settings permission that should be granted to build code. The
the two exact Environment declarations are enforcement points. Verify required reviewers,
prevent-self-review, and protected release-tag deployment policy during commissioning and retain
that settings review as release evidence.

Create a dedicated Ed25519 **Release artifact** signing key on a trusted administration machine.
The private key must never be copied to the server, committed, logged, reused for human Git signing,
or reused for SSH login. The current CI interface
expects a non-interactive key held only in the protected `RELEASE_SIGNING_PRIVATE_KEY` environment
secret; use an offline/HSM signing job instead if organizational policy forbids that model.

```bash
umask 077
ssh-keygen -t ed25519 -a 100 -C uten-imp-release -f ./uten-imp-release-ed25519
ssh-keygen -E sha256 -lf ./uten-imp-release-ed25519.pub
```

The protected secret is an interim interface, not the long-term preferred custody model. Move
production signing to KMS/HSM or an offline signing service whose key cannot be exported, while
preserving the same manifest/channel namespace and public-key fingerprint checks. The current
publish job keeps the exportable key only under a private `/dev/shm` directory, clears the secret
environment variable before invoking `ssh-keygen`, and removes the private file immediately after
both signatures are created. Runner isolation and environment approval are still required.

The server receives only an `allowed_signers` line built from the public key:

```text
uten-imp-release ssh-ed25519 AAAA_REPLACE_WITH_THE_REAL_PUBLIC_KEY
```

Install it as `/etc/uten-imp-updater/release-allowed-signers`, owned
`root:uten-imp-updater`, mode `0640`.
The current bootstrap and Phase 4 installers accept exactly one release key and do not implement a
reviewed overlap-rotation transaction. Key rotation therefore remains **NO-GO** until a dedicated
procedure can preserve old-release and backup verification, bind both fingerprints to an approved
change, activate the new key, and remove the old key only after recovery evidence is complete.
Never edit either trust file by hand or remove the old key between staging and activation.

## OSS authorization boundary

Use separate principals:

- CI publisher: immutable create-only access to `releases/*` and versioned
  `channels/candidate/*`, read-back of those exact objects, plus overwrite access only to
  `channels/candidate/LATEST.txt`.
- server downloader: `GetObject` only for those prefixes; no `PutObject`, delete, ACL, policy, or
  credential-management permission.

The workflow does not accept static OSS publisher secrets. The pinned official Aliyun credentials
action exchanges GitHub OIDC for a 1,800-second STS session. That pinned action masks and exports
the standard `ALIBABA_CLOUD_*` variables; the upload step maps them to `OSS_ACCESS_KEY_ID`,
`OSS_ACCESS_KEY_SECRET`, and `OSS_SESSION_TOKEN` using shell builtins and removes compatibility
aliases before starting any child process. The workflow requires a non-empty STS security token
and removes the pinned action's predictable transient OIDC token file before invoking upload tools.
Configure the role so versioned objects are
create-only, and scope its only
overwrite permission to `channels/candidate/LATEST.txt`. The endpoint must be a plain HTTPS
origin. The publish job downloads official `ossutil` v2.3.0 directly and requires archive SHA-256
`3ae4d9fc85a7a6e9f5654d1599766f1a3a42a3692870887b5ae9338d582ef65a`; it does not run `pip` or
load a repository upload client. Rotate or revoke any older static CI publisher keys before this
workflow is commissioned. The server downloader remains a separate read-only principal.

All production tag runs share one global, non-cancelling concurrency lane. Before uploading any
new immutable release object, the publish job downloads `LATEST.txt` and its referenced signed
channel, selects the channel's claimed fingerprint from the protected `RELEASE_ALLOWED_SIGNERS`
trust set, verifies the Ed25519 signature, and requires the new `releaseSequence` to be strictly
higher. A missing or unreadable pointer fails closed. The very first pointer must therefore be
created by the separate `bootstrap-initial-candidate` job; the normal push workflow never treats a
read/network error as permission to reset channel history.

For the one-time bootstrap only, dispatch `release.yml` against the protected release **tag** that
points exactly to current protected `main`, and provide the exact confirmation string:

```bash
gh workflow run release.yml --ref "$VERSION" \
  -f confirm_initial_bootstrap=CREATE_INITIAL_CANDIDATE_POINTER
```

The signing job first repeats the ordinary clean build, isolated verification, and signing path,
then stores a short-lived GitHub artifact containing only the signed publication. A second fresh
`production-release-bootstrap` environment job has no checkout and no private signing key: it binds the
artifact ID and service SHA-256 to that same workflow run/commit, safely extracts an exact file
inventory, verifies manifest and channel signatures against the protected public-key trust set,
and rechecks every uploaded digest. It uploads all versioned objects with `forbid-overwrite`, creates
`LATEST.txt` last with the same create-only condition, reads back every uploaded artifact, checksum,
SBOM, attestation, manifest, channel and pointer, and byte-compares each one; it verifies signed
metadata again. If `LATEST.txt` or any
versioned object already exists, bootstrap fails closed. Do not grant delete permission to make a
failed bootstrap retry convenient; investigate partial writes and issue a new reviewed version.

## Phase 4 server installation contract

The existing legacy root updater/watchdog wiring must not be reused. Before installing the staging
service or allowing even one manual oneshot, the installation phase must create the following
ownership boundary; the timer itself remains disabled in this implementation:

```text
uten-imp-updater user: system account, /usr/sbin/nologin, dedicated primary group
supplementary groups: none; specifically not the uten-imp application group
/opt/uten-imp/updater: root:root 0755; scripts and Python modules root:root, not group/world writable
/var/lib/uten-imp-updater: uten-imp-updater:uten-imp-updater 0750
/var/lib/uten-imp-release: root:uten-imp-updater 0750, not writable by the group
/var/lib/uten-imp-release/operation.lock: root:uten-imp-updater 0660, one regular hard link
/etc/uten-imp-updater: root:uten-imp-updater 0750, not writable by the group
/etc/uten-imp-updater/oss-pull.env: root:uten-imp-updater 0640
/etc/uten-imp-updater/release-allowed-signers: root:uten-imp-updater 0640
/usr/local/libexec/uten-imp-release: root:root 0755
/usr/local/libexec/uten-imp-release/release_guard.py: root:root 0755
/etc/uten-imp-release-trust: root:root 0755
/etc/uten-imp-release-trust/release-allowed-signers: root:root 0640
/etc/uten-imp/server.env: root:uten-imp 0640 (or root:root 0600)
/opt/uten-imp/releases: root:root 0755 and on the same filesystem as /opt/uten-imp/current
```

The stable restore guard and trust policy are deliberately independent of
`/opt/uten-imp/updater`. Bootstrap/hardening may install only those two root-controlled restore
files before the legacy updater is retired. Phase 4 installs the updater's sibling guard separately
and must compare its reviewed SHA-256 and signer fingerprints to the stable trust copy; neither path
may replace the other at runtime.

On a legacy host, first revoke/rotate the old downloader identity out of band and run the reviewed
`deploy/setup/retire-legacy-updater.sh` with the independently recorded credential SHA-256 and a
non-secret change reference. Phase 4 replacement requires the exact printed
`/var/lib/uten-imp-legacy-evidence/retirement-*` directory and re-verifies its root-only
COMPLETE/CLOSED markers, manifest digest, step markers, quarantined credential digest, and absence
of all three live legacy credential/config/state paths. A syntactically plausible evidence path is
not sufficient. Fresh commissioning also refuses any pre-existing updater config or state.

The coordination lock must be created by the installer in its root-owned parent. Do not put it in
the updater-owned staging directory: the downloader could otherwise replace the path and defeat
mutual exclusion with root activation.

Staging fsyncs every verified candidate file and directory, atomically renames it into
`candidates/<version>`, and fsyncs both rename parents before advancing `high-water.json`. If a
power loss occurs after the candidate commit but before the high-water write, the next poll accepts
only the identical signed `STAGED.json` evidence and repairs the missing high-water value; it never
lowers an existing high-water mark.

Put `/var/lib/uten-imp-updater` and `/opt/uten-imp` on monitored project-quota filesystems sized for
at least three full staged/installed releases plus rollback evidence. Both staging and activation
fail before writing a signed payload unless the operation will leave at least 15% or 2 GiB free,
whichever reserve is larger. `install-release-retention.sh` installs, but never enables, the separate
root retention service/timer. It deliberately installs only `policy.json.example`: project IDs and
hard byte limits must be derived from read-only `findmnt` evidence and configured out of band in the
root-only fixed `policy.json`.

`/usr/local/sbin/uten-imp-retention audit` authenticates the policy and both project quotas through
`findmnt`, `FS_IOC_FSGETXATTR` (`PROJINHERIT`), and `quotactl`. It inventories candidates and installed
releases with signed manifest/payload verification. The plan protects `current`, `active.json`,
`high-water.json`, the optional strict `pending.json`, every known transaction/recovery reference,
the newest three verified candidates, the newest three verified installed releases, and one newest
verified installed predecessor. A transaction/recovery marker or live updater-UID process blocks all
pruning. Unknown JSON, damaged signatures, symlinks, hard links, special files, unsafe owners/modes,
project-ID escape, or cross-device quarantine are retained and reported rather than deleted.
Root-only database receipts and completed recovery transaction evidence are validated and every
referenced release version remains protected; an unknown, damaged, failed, or incomplete recovery
transaction is a global prune blocker.
Any non-empty retention quarantine is itself a prune blocker, even when a crash lost the live
transaction marker; audit records its inode-safe shape for a later evidence-driven recovery.

Manual `... retention prune` shares the fixed operation lock. Every eligible tree must pass the same
fd-based checks again, is renamed with `renameat` semantics into a same-device root-only quarantine,
the destination and source parents are fsynced in that order, and only then is recursively removed
through no-follow directory descriptors and fd-relative `unlinkat`/`rmdirat` calls. Audit/prune JSON
receipts and an in-progress marker make partial operations fail closed. A durable actions receipt is
written before the marker is archived, and the final receipt binds both action and transaction
evidence digests. Any later close failure restores the exact fixed-path marker. `OnFailure` durably queues a
minimal root-only alert and calls only the fixed root-controlled
`/usr/local/libexec/uten-imp-retention/alert-sink` interface. The sink is invoked with fixed
`--event-file` and `--receipt-file` arguments; exit zero alone is insufficient. It must create a
root-only receipt binding the exact alert ID, accepted status, delivery time, and provider message ID
before the event moves from pending to delivered. Interrupted receipt work is preserved and fails
closed instead of being deleted by the helper.

Alert before either filesystem reaches 30% free and page at 20%. The source implementation and local
policy applies the same headroom severities to each enforced project quota, so a full project cannot
hide behind free space elsewhere on the filesystem. Source and local fault-injection tests do **not**
prove the target mount, real project limits, alert delivery, cleanup
duration, or power-loss recovery. Both retention and staging timers remain disabled until those real
Linux/VM acceptance records are approved; there is still no supported automatic-staging enable path.

Every staging poll and explicit activation emits read-only `freeBytes`, `totalBytes`, and
`freePercent` records for both staging and installed-release filesystems to stdout/journald. The
retention audit adds durable capacity/quota/inventory receipts. Do not substitute a wildcard,
`find -delete`, or recursive operator command for the reviewed retention helper, and never remove a
retention/recovery marker or quarantine directory by hand.

The updater supply chain now starts from the single reviewed root `oss2==2.19.1` and an exact,
SHA-256-locked set of all 15 runtime distributions for Ubuntu 24.04 x86_64 / CPython 3.12. CI
downloads binary wheels only for packages that publish a compatible wheel. The three packages
without an acceptable upstream Linux wheel (`oss2`, `aliyun-python-sdk-core`, and `crcmod`) have
separate exact source-archive hashes and are built by a non-root process in the digest-pinned
`python:3.12.11-slim-bookworm` image with fixed `SOURCE_DATE_EPOCH`; source execution has no
network, repository, Docker socket, or secrets. Setuptools and wheel are themselves exact-pinned
and hash-locked. CI then performs a second install/test in an Ubuntu 24.04 container with
`--network none`, `--no-index`, `--no-deps`, `--only-binary=:all:`, and `--require-hashes`.
Before evidence is emitted, the builder regenerates the canonical runtime lock from the exact
wheel bytes and requires byte-for-byte equality with the reviewed lock.

The release payload retains the input, runtime/source/build locks, wheel-only directory, canonical
SHA256SUMS, CycloneDX 1.6 SBOM, and in-toto attestation under `sbom/updater/`. The SBOM records the
digest-pinned builder image plus exact SHA-256 digests of the builder script and supply-chain
verifier. The isolated signer anchors all four locks/inputs and both builder sources to exact
protected-commit GitHub blobs, independently validates the fixed distribution/hash/ABI/SBOM/
attestation contract, and signs the attestation under the dedicated
`uten-imp-updater-wheelhouse-v1` namespace. Phase 4 verifies that signature before installation,
checks the local verifier itself against the signed protected-source digest, rechecks
lock-wheel-SBOM-attestation parity, installs as the unprivileged updater account, checks
the resulting `dist-info`/`RECORD` tree byte-for-byte, rejects `.pth`, extra/missing/duplicate
distributions and sdists, and removes pip from the runtime venv. Production root must never run an
online `pip install` or manually add a wheel. A protected-tag CI run and server commissioning with
the resulting signed bytes are still required evidence; repository implementation alone is not a
production pass. The
unprivileged staging entrypoint resolves the normal Ubuntu venv Python symlink and accepts it only
when it ends at `/usr/bin/python3` or `/usr/bin/python3.N`; the complete directory chain and target
must remain root-owned and not group/world writable. Root activation never starts that venv, so an
`oss2` dependency or site-package `.pth` file cannot execute as root. It uses
`/usr/bin/python3 -I` and loads only the root-controlled standard-library updater and guard modules.

Install `uten-imp-updater.service` and `.timer`, and install `uten-imp-activate.sh` as
`/usr/local/sbin/uten-imp-activate` (`root:root 0755`). The service sandbox grants writes only to
its staging/runtime directories and the fixed coordination-lock file. It has no capabilities and
`/opt` is read-only. The systemd private socket and system D-Bus socket are inaccessible, so the
automatic job cannot ask systemd/polkit to manage services.

Install the retention controls separately with `install-release-retention.sh`. The installer leaves
both `uten-imp-retention.timer` and `uten-imp-updater.timer` disabled, preserves an existing safe live
policy, and never assigns a project ID/limit or installs an alert sink. Those are target-specific
production writes requiring the normal read-only review, approval, rollback, and acceptance stages.

All watchdog executables invoked by root must live under a root-controlled path such as
`/usr/local/libexec/uten-imp/`. If either watchdog unit still executes
`/opt/uten-imp/current/...`, the activator deliberately refuses to proceed. Phase 4 is install-only
and always leaves the staging timer disabled; this version has no supported enable path. A future
reviewed change may add one only after quota isolation, safe retention, capacity alerts, GET-only OSS
authorization, and one exact signed candidate have all passed. The backend, Nginx, and watchdog
timers remain disabled until first activation succeeds.

## Approval and activation

All command blocks in this section are interface shapes, not current target-host instructions. Before
using one, refresh the CMDB identity and out-of-band SSH host key, prove the approved network route,
tested console and two administrator keys, inspect the exact signed candidate, and obtain approval
for the displayed plan/risk/rollback. The current target has not passed those prerequisites.

First inspect an already-staged candidate. Inspection performs signature and payload checks; it does
not activate anything:

```bash
sudo -u uten-imp-updater /opt/uten-imp/updater/venv/bin/python \
  /opt/uten-imp/updater/release_updater.py inspect vYYYY.MM.DD-N
```

The internal-test source candidate now has an explicit first-activation path. It is valid only after
the existing-host DB commissioner has produced terminal onboarding for the exact authenticated
candidate and live database, the runtime/storage contracts still match, and the separate first-backup
commissioner has produced one unexpired, unconsumed full/WAL/check receipt for the same database
identity. An expired onboarding may be replaced only through the fixed activation-only
`reauthorize-activation` flow described in
`../setup/EXISTING_TEST_HOST_INTERNAL_TEST_ONBOARDING.zh-CN.md`; that flow does not change PostgreSQL,
install a release, or open ingress.

After those receipts and session clearance have been independently reviewed, the first activation
uses the exact values printed by `inspect` and requires both explicit flags:

```bash
sudo /usr/local/sbin/uten-imp-activate vYYYY.MM.DD-N \
  --confirm-version vYYYY.MM.DD-N \
  --confirm-flyway REPLACE_WITH_SIGNED_HEAD \
  --confirm-flyway-digest REPLACE_WITH_SIGNED_DIGEST \
  --confirm-session-clearance \
  --first-release \
  --enable-on-boot
```

This exact-target first activation sets `databaseChanged=false` and does not start the migration
unit: the commissioner and live verifier must already prove every signed Flyway row. Do not add
`--approve-database-change`. The onboarding and first-backup receipts are consumed only after the
active/runtime authority commits; interruption leaves evidence for the controlled recovery/adoption
path and must not be handled by rerunning ordinary activation or editing JSON.

For an established signed installation, a code-only release is allowed only when `active.json`,
runtime authority, archived first-backup authority, fixed live PostgreSQL identity, and full Flyway
history still match the signed current release and the target has the identical Flyway head and
migration-set digest. It uses the same confirmation values without `--first-release` or
`--enable-on-boot`. `--approve-database-change` is not migration authorization: a changed signed
Flyway target remains hard NO-GO until a separately reviewed signed-current from-to acceptance
producer is integrated and accepted. Supplying the flag for an unchanged target is rejected.

The target internal-test boot contract is schema v3 `lvm-linear-nvme`: the fixed verifier binds the
stable mapper path, LV/VG/PV/NVMe identities, filesystem UUID/type/options and effective PostgreSQL
data directory before any database write. The storage observer unit for this authority must contain
no md `DeviceAllow`; schema v2 `/dev/md*` observation is historical compatibility only and is not a
valid normal boot authority for this host. Nginx remains bound behind PostgreSQL, backend readiness,
static release identity and both watchdog probes, so storage, database or backend drift closes ingress.

If read-only refresh finds an unsigned legacy `current`, preserve it as evidence. Retirement is a
separate, explicit one-time first-release contract and may be used only when its exact preimage,
quiescence, onboarding, first-backup, no-rollback confirmation and reviewed plan all pass. There is no
permissive accept-legacy path. Do not hand-edit `current`, `active.json`, onboarding, backup, or
retirement evidence to manufacture eligibility.

Before maintenance, activation writes and fsyncs a temporary failure gate, durably disables every
boot-capable backend/nginx/watchdog unit, writes `activation-in-progress.json`, and only then removes
the temporary gate. The atomic `current` rename is followed by a parent-directory fsync. Full health
and watchdog verification must complete and `active.json` must be durable before the in-progress
marker can be committed. The activator first writes and fsyncs
`boot-enablement-in-progress.json`, then deletes the activation marker, restores the complete saved
enablement map, and fsyncs systemd's enablement directories. Only after every unit matches the
intended map does it delete and fsync the boot-enablement marker. The application, nginx, and both
watchdog services must reject that marker in `ExecStartPre`; the timer triggers are therefore also
fail-closed. A kill, kernel panic, or power loss before either commit leaves a start-blocking marker
or durably disabled units. A loss during the per-unit enable sequence leaves the boot marker, so a
partial enablement cannot reopen an incomplete stack after reboot. A subsequent activation refuses
to proceed until controlled recovery resolves any remaining transaction evidence.

The exact-target first-activation path and the established code-only path do not start
`uten-imp-migrate.service`; the fixed live verifier already proves the signed history before and after
`current` switches. The migration unit remains installed and contract-checked for a future
evidence-approved from-to path, but that path is currently hard NO-GO. If such a producer is later integrated, migration
must still run only after the atomic switch while backend/nginx remain stopped, never as root. The
reviewed unit is `Type=oneshot`, uses only the dedicated `uten-imp-migrate` account and
`/etc/uten-imp-migrator/migrator.env`, is never boot-enabled, accepts no CLI argument, and runs
`/opt/uten-imp/current/server/uten-imp-migrator.jar` behind the one-use root authorization. Its exact
fragment, Java argv, environment and terminal systemd result checks must remain mandatory. Neither a
future producer nor a human approval may introduce `flyway repair`, alter applied migrations, or
restart old code after a schema-changing failure.

The same activation preflight pins the application unit's non-root account, environment file,
root environment validator, Java server-JAR argv, every pre-start command and `+` prefix, and rejects
all drop-ins or extra command hooks. It also pins the packaged nginx fragment, exact start/reload/stop
commands, its single reviewed Uten drop-in, and the combined config-check/failure-marker pre-start
sequence. Any unit drift fails before downtime.

The manifest declares database rollback incompatible by default. If health fails after the Flyway
set changed, the activator does not start the old JAR and does not claim an automatic rollback; it
restores the old link only as evidence and leaves ingress/backend stopped for an operator-led
database recovery. Automatic old-code restart is attempted only when the signed migration-set
digest is identical.

After a path has passed every evidence gate and entered maintenance, a failed current-link restore or
failed previous-release health recovery atomically writes
`/var/lib/uten-imp-release/activation-failed.json` as `root:root 0600`. The marker records the
failed/previous signed release identities and the exact original enablement state, but no secret.
The activator then stops and disables the backend, nginx, and both watchdog boot timers and refuses
to return containment success unless every controlled unit is inactive and every boot unit is
disabled. Any later activation refuses to run while the marker exists. The same containment remains
mandatory for first activation and any future evidence-approved changed-Flyway path. A rejected
preflight before maintenance does not manufacture a failure marker; a failure after the
first-activation transaction starts must remain contained and follow evidence-bound recovery/adoption.

Phase 3/systemd adds the same fail-closed precondition to both application entry points:
`ExecStartPre=/usr/bin/test ! -e /var/lib/uten-imp-release/activation-failed.json` on
`uten-imp.service` and an nginx service override. It must also install the exact
`boot-enablement-in-progress.json` precondition required above on the app, nginx, and both watchdog
services. A final persistent failure marker is never cleared automatically (only the activator's
temporary preparation gate is transactionally removed) and must not be removed with a generic
operator `rm`.

`/usr/local/sbin/uten-imp-recover assess` is a fixed-path, root-only, operation-locked, read-only
assessment. It emits normalized JSON containing the original marker digest and parsed schema,
current/active state, verified installed manifests, unit active/enabled state, a deterministic plan
digest, and the exact confirmation phrase. `recover apply` requires that plan and marker digest,
the target version, a canonical approval reference, and a root-only database backup/restore receipt
under `/var/lib/uten-imp-release/database-receipts` together with its expected SHA-256. Unknown
schemas, unsafe ownership/modes/symlinks, signature drift, stale plans, or indeterminate
database/manifest state fail closed.

`recover apply` exposes four evidence-gated outcomes, and only an action reported as `allowed=true`
may run. `finish-activation` completes an already durable signed target. `restore-previous` requires
the still-verifiable signed predecessor plus an independently produced restore/PITR receipt and a
live database that matches that predecessor exactly. `abandon-candidate` is limited to a
preparation-only failure where `current`, `active.json`, and the live database still prove the signed
predecessor. `remain-contained` records a durable decision but never clears the marker, changes
`current`, or starts runtime. First release or unsigned legacy state without a signed predecessor
therefore remains contained. `retry-activation` is deliberately rejected because this helper does
not perform PITR, infer database restoration, run Flyway repair, or weakly re-enter formal activation
under the held lock.

If activation/recovery/boot transaction markers survive SIGKILL or reboot, operators first run
`recover interrupted-assess` and may use only its plan-bound `interrupted-apply --action contain`.
Containment durably binds and archives the original marker and one-use authorization before returning
to ordinary assessment; it never queries/migrates the database or starts runtime. PostgreSQL is
deliberately outside the transactional entry boot-enablement map and remains active/enabled during
activation and containment, preserving the read-only database evidence required by recovery while
ingress, application, and watchdog paths remain down. Formal activation and evidence recovery take
the fixed release lock and then `/var/lib/uten-imp-db-maintenance/operation.lock`, holding both through
terminal success or fail-closed containment so backup and Flyway work cannot overlap.
Any recovery exception restores the original failure gate. Production recovery remains a
commissioning NO-GO until these actions, the database receipt producer, SIGKILL/reboot/power-loss
behavior, and business recovery are exercised on the real target.

Every migration entry also contains the signed int32 `flywayChecksum` generated in CI by Flyway's
own `org.flywaydb.core.internal.resolver.ChecksumCalculator`, alongside its version, filename, and
source SHA-256. The release workflow obtains the canonical v1 TSV from the backend's
`FlywayChecksumManifestExporterTest` with `-Duten.exportFlywayChecksums=true`; publishing fails if
its header, row count, source files, or executable-JAR migrations disagree. Restore tooling must
derive its comparison rows from an authenticated manifest, never from a hand-copied TSV or an
independently supplied digest:

```bash
/usr/bin/python3 -I /usr/local/libexec/uten-imp-release/release_guard.py \
  verified-flyway-checksums \
  --manifest /ROOT_CONTROLLED_EVIDENCE/manifest.json \
  --signature /ROOT_CONTROLLED_EVIDENCE/manifest.sig \
  --allowed-signers /etc/uten-imp-release-trust/release-allowed-signers \
  --expected-version vYYYY.MM.DD-N
```

The output is canonical `version<TAB>filename<TAB>checksum`. The restore drill must compare every
row to `flyway_schema_history` before accepting the restored database. When run as root, this CLI
accepts only the installed guard path and fixed
`/etc/uten-imp-release-trust/release-allowed-signers` policy plus root-owned, non-symlink,
non-group/world-writable path chains for the guard, manifest, signature, and trust evidence. Signed
manifest/signature evidence must be retained with the corresponding off-host backup.

## Commissioning NO-GO conditions

Manual staging is permitted only as a reviewed, non-activating inspection step after the trust,
credential and free-space checks pass. Do not run production activation while any item below
remains true, and do not enable automatic staging at all in this implementation:

- the signing key/environment reviewers, protected `main`, or protected release-tag ruleset is not
  configured;
- the build/test job can access a signing/cloud secret, the publish job checks out the repository,
  the protected environment does not force a fresh reviewed job, or the GitHub artifact ID/digest
  gate is weakened;
- exportable signing-key custody is used beyond the approved interim period instead of the planned
  KMS/HSM or offline signer;
- GitHub OIDC subject/audience conditions or the 1,800-second Aliyun role session are broader than
  the intended repository, environment, workflow, and OSS object prefixes;
- the OSS downloader can write/delete objects, or CI can overwrite versioned objects;
- the dedicated user, root-owned lock, allowed-signers file, or credential modes differ from the
  contract above;
- the updater wheelhouse/lock omits hashes for any transitive dependency or requires online root
  package installation;
- the real staging/release mounts have not proven exact project-ID inheritance and hard quotas,
  same-device quarantine, accepted capacity thresholds, provider-bound alert delivery, cleanup
  duration, and VM power-loss recovery, or either retention/updater timer is enabled prematurely;
- the backend, nginx, or either watchdog service lacks the persistent activation-failure and
  boot-enablement-transaction `ExecStartPre` gates, or the controlled evidence-backed recovery
  command/reboot drill has not been completed;
- the explicit `uten-imp-migrate.service` is absent, boot-enabled, not the reviewed isolated
  oneshot, can read the application environment, or activation has not demonstrated its exact
  terminal-state gate before backend start;
- a root watchdog executes from the application release tree;
- TLS/nginx, firewall, PostgreSQL backup/retention, off-host copy, restore drill, monitoring, or
  alerting has not passed the separate production commissioning checklist;
- the target database migration baseline and current signed release evidence have not been
  reconciled.
- an ordinary reboot has not yet demonstrated a fixed root-owned verifier that binds `current`,
  `active.json`, the signed manifest and every live Flyway history row plus PostgreSQL
  system_identifier/timeline. The current unit guards prevent release-transaction replay but do not
  by themselves prove that an out-of-band database snapshot rollback is compatible; this remains a
  production P0 NO-GO until the normal/activation/recovery boot states share one reviewed verifier;
- durable external runtime readiness/StartLimit alert delivery and the receipt-bound one-time
  commissioning path for repo2 backup/health/alert-drain and updater/retention timers have not passed
  target-host tests. Timers must remain disabled before that commissioning; daily manual starts are
  not an acceptable production target.

This phase intentionally does not log in to a server, install credentials, enable a unit, publish a
release, or mutate production data.
