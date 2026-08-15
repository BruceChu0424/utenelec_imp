# Website production chain operator notes

<!-- WEBSITE-DEPLOYMENT-DEFERRED-20260812 -->
> **Paused by owner decision (2026-08-12).** Do not execute the host sequence, stage a release,
> commission automation, install units, or enable timers on the current ERP server. The website is a
> future, separate cloud-host project. The commands below are retained for design review and tests,
> not as current authorization.

This directory is a security domain independent from ERP. It has its own
GitHub Environment (`website-production-release`), Ed25519 allowed-signers
file, Aliyun OIDC provider/role variables, OSS `website/` prefix, Linux users,
state, backup credentials and timers. Never substitute an ERP key, role,
database, service account or backup repository.

## Source acceptance

Run from `website/`:

```bash
npm ci
npm run lint
npx tsc --noEmit
npm run test:all
npm run test:prisma-migrations
python3 -m unittest discover -s deploy/tests -p 'test_*.py'
find deploy -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
```

CI also migrates a disposable SQLite database, builds the standalone server,
assembles a clean release, produces a CycloneDX SBOM, inventories every Prisma
migration, and signs only after the protected website environment is approved.
The release tag is `website-vX.Y.Z`. A local working directory is never a
production artifact.

Required website-only GitHub configuration:

- secret `WEBSITE_RELEASE_SIGNING_KEY`;
- variable `WEBSITE_RELEASE_ALLOWED_SIGNERS` containing exactly
  `uten-website-release ssh-ed25519 ...`;
- variables `ALIYUN_WEBSITE_OIDC_PROVIDER_ARN`,
  `ALIYUN_WEBSITE_RELEASE_ROLE_ARN`, `ALIYUN_WEBSITE_OSS_BUCKET`, and
  `ALIYUN_WEBSITE_OSS_ENDPOINT`;
- environment `website-production-release` with required reviewers;
- protected `website-v*` tag policy.

## Host sequence

Do not run these commands until the host has passed a read-only audit and each
write phase has an approved target, backup evidence and rollback plan.

1. Before the installer, attach two distinct persistent filesystems at exactly
   `/var/lib/uten-website` and `/var/backups/uten-website`. Both must expose a
   stable UUID, use ext4/xfs, and be mounted `rw,nodev,nosuid,noexec`; the
   operator must compare both UUID/type pairs with console/cloud-disk evidence
   out of band. The installer requires those expected values, compares them to
   the live mounts, and records them in root-only `storage.env` plus a durable
   host-install receipt.
   This prevents a failed mount from silently creating a new SQLite/uploads or
   backup tree on the root filesystem.
2. On an empty dedicated website host only, run
   `install-website-host.sh --allowed-signers FILE --nginx-worker-user OBSERVED_USER --expected-state-uuid STATE_UUID --expected-state-fstype ext4 --expected-backup-uuid BACKUP_UUID --expected-backup-fstype ext4 --confirmation PREPARE-EMPTY-WEBSITE-HOST-STATE-STATE_UUID-BACKUP-BACKUP_UUID`.
   Substitute the actual lowercase reviewed UUIDs and actual ext4/xfs types in
   both the arguments and confirmation.
   It refuses an existing database/current link, starts only the root boot gate
   and Nginx in the closed state, and deliberately leaves the app and entry
   watchdog disabled until the first signed activation succeeds.
3. Privately create `website.env`, `oss-read.env`, append-only restic settings,
   TLS files and the rendered Nginx vhost with the documented ownership. Never
   send those secrets through chat or CI logs.
4. Restore the approved paired `website.db` and `uploads` recovery point. For an
   existing unmanaged SQLite database, reconcile schema/content and approve a
   baseline plan first; do not use `prisma db push` or `migrate resolve`.
5. Invoke the unprivileged staging service manually. It reads only the signed
   `website/channels/candidate` pointer, downloads the exact website namespace,
   verifies both signatures and bytes, and never activates.
6. As root, run `uten-website-activate plan VERSION`. Review the publication,
   state digest, migration inventory, paired backup destination and plan SHA.
   Apply only in the approved window with the exact SHA and
   `--confirmation ACTIVATE-WEBSITE-VERSION`.
7. If activation fails, do not delete `activation-failed.json`. The previous
   release/state may be restored but ingress stays closed. Use
   `uten-website-recover assess`, review its evidence, then `apply` with the
   exact evidence SHA and `--confirmation REOPEN-RESTORED-WEBSITE`.

## Boot, crash and entry behavior

The installer initially enables only Nginx and
`uten-website-boot-gate.service`. A successful first signed activation enables
the website service and core entry watchdog, proves both are durable, and binds
that fact into the activation receipt; a failed first activation disables them
again. These normal host-runtime units never stage, migrate or activate a
release. On every later boot and process start they:

- close and durably reload the Nginx gate before starting the application;
- require the exact state/backup filesystem UUID, mount target/type/options,
  emergency free bytes and inode headroom;
- before Node executes, reverify the installed bytes against the signed
  publication and require the exact signed Prisma name/checksum history;
- validate runtime paths, secret shape, SQLite crash recovery/quick check,
  foreign keys and a fixed-budget uploads metadata sample (full media hashes
  remain in activation, backup, restore and reconciliation evidence);
- reopen only after NTP synchronization and the local database-backed readiness
  endpoint passes;
- close immediately from `ExecStopPost` whenever the process exits;
- restart clean/transient exits with bounded systemd backoff, while a five-minute
  watchdog recovers after a later network/time/process recovery. Its monotonic
  schedule is recreated 90 seconds after every boot; it intentionally has no
  misleading calendar catch-up/Persistent setting.
- honor intentional `systemctl disable`: watchdog reconciliation closes the
  gate and neither starts the app nor reopens entry until the app, Nginx, boot
  gate and watchdog have all been explicitly commissioned again.

It is deliberately not an infinite crash loop. SQLite corruption, a missing or
wrong persistent volume, critical capacity, unsafe runtime files, an activation
marker or repeated startup failure keeps ingress closed. The last case is
retried only at the bounded watchdog interval and remains visible in the journal.

Activation persists `activation-in-progress.json` after the paired snapshot and
before any extraction, Prisma migration or current switch. A hard power loss in
that interval therefore cannot become an unrecorded successful boot. Run
`uten-website-recover-interrupted assess`, review the exact state/snapshot/current
fingerprints, then apply with its evidence SHA and version-bound confirmation.
It restores the pair and previous release, moves SQLite WAL/SHM/journal sidecars
into the incident directory, creates the normal failure marker and leaves
ingress closed. The only permitted Node start inside that transaction consumes
a root-only, boot-bound one-time grant which binds the marker, current release,
signed manifest, SQLite bytes and paired snapshot manifest. Use
`uten-website-recover assess/apply` for the final reopening. Recovery progress
is phase-marked and can finish idempotently after another interruption; no
marker is to be deleted by hand.
For an interrupted first-ever activation there is no previous service to reopen;
the latter tool archives the proved marker with
`ACKNOWLEDGE-RESTORED-FIRST-WEBSITE-ACTIVATION`, keeps ingress closed and requires
a new reviewed activation.

The installer leaves the app/watchdog plus `uten-website-stage.timer`,
`uten-website-backup.timer` and `uten-website-health.timer` disabled. The first
successful activation commissions only the app/watchdog. That entry watchdog
only reconciles the already-approved current release and Nginx gate; it cannot
download, migrate or activate. Do not create the disabled timers' enable-marker
files or enable timers until real OSS/RAM renewal, capacity, seven recovery
points, append-only off-site storage, alert routing, power-loss tests and
restore drills are accepted. Root activation is intentionally manual even when
remote staging is later enabled.

After those checks have two named reviewers and hash-bound evidence, use
`uten-website-commission-automation plan`, review its exact plan SHA, then run
`apply` with `ENABLE-WEBSITE-BACKUP-AND-HEALTH-TIMERS`. It enables only backup
and health; staging stays disabled. Scheduled jobs require the final canonical
commissioning receipt/marker and refuse an in-progress marker. A power loss
during enablement therefore cannot run a half-commissioned job; use the typed
`recover --confirmation DISABLE-INCOMPLETE-WEBSITE-AUTOMATION` action to disable
both partial timers and archive the evidence before replanning.

Before commissioning, build the required real recovery-point history only with
the explicit root-only maintenance command
`uten-website-paired-backup --precommission --confirmation CREATE-PRECOMMISSION-WEBSITE-RECOVERY-POINT`.
It refuses to run if the backup timer is active/enabled or any commissioning
marker exists. This exception creates and uploads one verified recovery point;
it does not enable a timer or authorize automatic activation. On the first host
with no `current` release, it accepts only a previously restored paired state,
an exact closed gate and disabled app/watchdog, then keeps both app and ingress
closed after the append-only upload. This is the bootstrap evidence needed by
the first signed activation; it never runs Prisma or application code.

All root maintenance locks and activation grants live below the boot-gate-owned
`/run/uten-website-release` directory (`root:root 0700`). The fixed lock helper
uses `O_NOFOLLOW`, exact inode/owner/mode checks and refuses pre-positioned
symlinks. Application code cannot traverse this directory.

## Backup evidence

`uten-website-paired-backup` briefly closes ingress and stops the single writer,
then uses SQLite's backup API and a no-symlink media copy to create one canonical
recovery point. It reopens only after readiness and uploads the verified pair to
an encrypted append-only restic repository. A receipt is written only after the
off-site snapshot succeeds. `uten-website-health` requires a fresh successful
receipt and seven distinct daily successes. `uten-website-restore-drill` restores
to an isolated directory and rechecks SQLite integrity, Prisma history and every
media hash; it never mutates live state. The daily writer has no delete rights.
`uten-website-backup-retention` uses a separate root-only credential, refuses to
prune before eight distinct successful days exist, keeps seven daily points and
requires an explicit typed confirmation; it has no timer and should run only
after the append-only/WORM and capacity controls pass their real acceptance.
Backup, activation and both recovery tools share `state-mutation.lock`; no
Prisma migration, paired restore or `current` switch can overlap the stopped
SQLite/uploads snapshot. The backup releases that lock before restarting Node
but retains a separate repository lock until restic finishes, so retention also
cannot prune during an upload.

Source tests do not establish production GO. DNS/TLS, Nginx rendering, ECS RAM
role renewal, OSS immutability, restic append-only enforcement, external alerts,
real restart/power-loss/update-failure drills, authenticated CMS upload/readback,
load/OOM tests and named business UAT still require evidence from the real host.
Two integrity contracts are also deliberately still NO-GO: signed Prisma
migration-name/checksum history does not yet include a signed canonical
`sqlite_schema` fingerprint that detects out-of-band DDL, and the bounded boot
uploads check does not yet provide a database-backed media ledger with expected
hash/size/reference state. Full paired snapshot verification remains mandatory
for recovery, but it is not a substitute for those live-state controls.
