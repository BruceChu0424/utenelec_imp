# Cloud Server Deployment Design and NO-GO Checklist (Website + Admin CMS)

<!-- WEBSITE-DEPLOYMENT-DEFERRED-20260812 -->
> **Owner decision (2026-08-12): deployment is deferred.** This website is not part of the current
> internal ERP-server work. It must not be installed, staged, activated, proxied or commissioned on
> that host. A future task may restart this document only for a separate cloud server after a fresh
> read-only audit and explicit write approval; no ERP-host GO, key, account, database, Nginx, backup
> repository or evidence may be inherited.

This document records the intended isolated, single-node boundary. It is not a
complete installer or production runbook and does **not** authorize a cutover.

> **Current status (2026-08-12): production remains NO-GO.** Source now includes
> an independent signed website workflow, offline Prisma migrator, root
> installer/two-step activator/recovery tool, read-only OSS stager, paired
> SQLite/uploads backup and restore drill, health gates, and a production Prisma
> baseline. Local tests do not prove the real host, TLS, RAM/OSS, immutable
> off-site repository, alert delivery, restore drill, load test or business UAT.
> The ERP release workflow, keys and cloud roles remain separate and do not
> publish this Next.js website.

## 1. Deployment boundary

The website and ERP are separate security domains and must use separate
hosts or VMs in the production topology. The ERP commissioning script owns an
exact, exclusive Nginx listener set on its internal host, so stacking this
website vhost on that host is explicitly **NO-GO**. A future shared reverse
proxy would require a separately reviewed combined configuration and does not
authorize co-locating either application runtime or state:

- Linux identity: `uten-website` only; never run as `root` or the ERP user.
- Runtime: loopback `127.0.0.1:3000`; expose only Nginx ports 80/443.
- Release root: `/opt/uten-website/releases/<release-id>` with an atomic
  `/opt/uten-website/current` symlink.
- State: `/var/lib/uten-website`; cache: `/var/cache/uten-website`.
- Secrets: `/etc/uten-website/website.env`, owner `root:uten-website`, mode
  `0640`. Never place it in a release, log, Git repository, or CI artifact.
- Database credentials, storage credentials, backups, rate-limit namespaces,
  hostname and TLS certificate must not be shared with ERP.

The current Prisma provider is SQLite and CMS media is local. That topology is
safe only for **one website process on one node** with a persistent volume. A
multi-instance/HA release is NO-GO until the website is migrated to PostgreSQL
and private object storage (or another shared durable media service).

## 2. Required runtime configuration

Create `/etc/uten-website/website.env` directly on the server with at least:

```dotenv
DATABASE_URL=file:/var/lib/uten-website/runtime/website.db
UPLOADS_DIR=/var/lib/uten-website/runtime/uploads
AUTH_SECRET=__GENERATE_A_NEW_HIGH_ENTROPY_VALUE_ON_THE_SERVER__
SITE_URL=https://__WEBSITE_HOST__
INQUIRY_TRUSTED_CLIENT_IP_HEADER=x-real-ip
ADMIN_TRUSTED_CLIENT_IP_HEADER=x-real-ip
INQUIRY_RATE_CLIENT_MINUTE=3
INQUIRY_RATE_CLIENT_HOUR=15
INQUIRY_RATE_GLOBAL_MINUTE=30
INQUIRY_RATE_GLOBAL_HOUR=300
ALLOW_DESTRUCTIVE_SEED=false
```

Optional inquiry forwarding to the IMP platform (sales' unified inbox; see
`backend-consolidation-analysis.md`). Both keys must appear as a pair or not at
all; when absent the website only writes its local inbox:

```dotenv
IMP_INGEST_URL=https://__IMP_HOST__/api/website-inquiries/ingest
IMP_INGEST_TOKEN=__SAME_RANDOM_TOKEN_AS_UTEN_WEBSITE_INQUIRY_INGEST_TOKEN__
```

The token must match the IMP server property `uten.website.inquiry-ingest-token`
(`UTEN_WEBSITE_INQUIRY_INGEST_TOKEN`, fail closed when unset). Forwarding is
one-way and fire-and-forget: a failed push never affects the customer submit,
and `/admin/inquiries` remains the fallback inbox. Reachability note: when IMP
runs `site=local`, its local-network guard covers the ingest path too, so the
website host must sit inside `UTEN_LOCAL_ALLOWED_CIDRS` (same LAN / VPN / a
single-path reverse-proxy rule) — decide this before enabling the pair.

Replace every placeholder before starting. Generate `AUTH_SECRET` on the
server; do not paste it into a ticket or deployment transcript. The Nginx
template deliberately overwrites client-supplied forwarding headers. If a WAF,
CDN or load balancer is later added, first configure Nginx `real_ip` with only
that provider's exact egress CIDRs.

The root-owned runtime validator accepts exactly the eleven required keys above,
plus the optional `IMP_INGEST_URL` / `IMP_INGEST_TOKEN` pair (validated as one
HTTPS URL pinned to the exact ingest path and a non-placeholder token). It pins
the SQLite file to `/var/lib/uten-website/runtime/website.db`, requires one canonical
HTTPS origin and strong secret, and rejects duplicate, quoted, expanded or
unknown assignments. Do not weaken that parser to make an ad-hoc `.env` work.
The SQLite file is pinned to `/var/lib/uten-website/runtime/website.db`; the
state-volume root and `control/` stay root-owned while only `runtime/` is owned
by the application. The initial service cgroup uses `MemoryHigh=1G`,
`MemoryMax=1536M` and a two-CPU
quota; production remains NO-GO until the real 8 MiB/40 MP media path and
concurrent CMS/inquiry workload pass a soak test with alerts enabled.

## 3. Build and immutable artifact

Use Node.js `22.13+` LTS and a dedicated, non-production build database with the
current schema. `next build` currently reads published catalogue aliases while
building redirects, so CI must not receive the production database secret.

```bash
npm ci
npm run build
```

`output: 'standalone'` creates `.next/standalone`. Next 15 also copies all of
`public/` and may copy build-time `.env` into that raw intermediate, so **never
archive or publish the raw directory**. Use the guarded assembler to create a
new release; it refuses an existing destination, rejects symlinks, and excludes
databases, uploads and secret-like files:

```bash
RELEASE_DIR=/a/root-reviewed/staging/path/__RELEASE_ID__
npm run deploy:assemble -- "$RELEASE_DIR"

test ! -e "$RELEASE_DIR/public/uploads"
if find "$RELEASE_DIR" -type f \( -name '*.db' -o -name '*.db-*' -o -name '*.sqlite' -o -name '*.sqlite-*' -o -name '*.sqlite3' -o -name '*.sqlite3-*' \) -print -quit | grep -q .; then
  echo 'Refusing release containing SQLite data' >&2
  exit 1
fi
if find "$RELEASE_DIR" -type f \( -name '.env' -o -name '.env.*' -o -name '*.key' -o -name '*.pem' -o -name '*.p12' -o -name '*.pfx' -o -name '*.jks' \) -print -quit | grep -q .; then
  echo 'Refusing release containing secret-like files' >&2
  exit 1
fi

# The reviewed root activator copies this clean tree into a new immutable
# /opt/uten-website/releases/<release-id> directory. Do not build as root.
```

The `dev.db` file and `public/uploads` directory are runtime data and are Git
ignored. They must never enter a release archive.
`.github/workflows/website-release.yml` publishes only the assembler output,
generates a CycloneDX SBOM and canonical migration inventory, signs the manifest
and channel with the website-only Ed25519 key, and assumes only the
`ALIYUN_WEBSITE_RELEASE_ROLE_ARN` role. Its protected environment is
`website-production-release`; none of those trust objects may be reused by ERP.

## 4. Fresh-host installer and immutable runtime contract

`deploy/website.env.example` is the canonical production key template; the root
`.env.example` remains a quoted local-development/seed example and is expected
to fail the strict production validator.

`deploy/install-website-host.sh` is the fresh-host-only root installer. It
requires a reviewed website public allowed-signers file and the exact typed
confirmation, refuses any existing database/current link, and additionally
requires distinct empty state and local-backup filesystems mounted at exactly
`/var/lib/uten-website` and `/var/backups/uten-website`. Their stable UUID,
ext4/xfs type and `rw,nodev,nosuid,noexec` options are pinned in root-only
`/etc/uten-website/storage.env`; this fails closed instead of writing into a
root-filesystem shadow directory when a data disk does not mount.
The two expected UUID/type pairs must come from an out-of-band console/cloud
disk review and are mandatory installer arguments; the typed confirmation binds
both UUIDs. A root-only final install receipt records the observed source,
UUID/type and signing-root digest, preventing trust-on-first-use of whichever
empty disks happened to be mounted when the command ran. It installs
the helpers root-owned, enables and starts only Nginx plus the fail-closed boot
gate, and explicitly leaves the website service, entry watchdog, staging,
backup and full monitoring timers disabled. The first successful signed
activation commissions the website service and entry watchdog and records
their durable enabled state; failed first activation disables them again. Run
the installer only after a real read-only host audit and a separately approved
write plan. Existing hosts need a
different migration plan; never force this script past its empty-host refusal.

- Copy `deploy/uten-website.service.example` to
  `/etc/systemd/system/uten-website.service`, then run `systemd-analyze verify`
  before enabling it.
- Install `deploy/validate-runtime.sh` as the root-owned, non-writable
  `/usr/local/libexec/uten-website/validate-runtime` helper referenced by the
  service. Never execute a validator from the switchable release. The host must
  provide `setfacl`/`getfacl` (normally the distribution's `acl` package).
- The boot gate is ordered before both Nginx and the application. Every start
  closes ingress first; `ExecStopPost` closes it again on any process exit.
  `Restart=always` handles normal/transient exits with a bounded start limit,
  while the five-minute entry watchdog reconciles later recovery. This core
  watchdog never stages, migrates or activates a release.
- Before Node starts, the root guard re-verifies every installed release byte
  against its signed publication, requires exact signed Prisma migration names
  and checksums, and performs SQLite integrity plus a fixed-budget uploads
  metadata sample. Full media hashing belongs to activation/backup/restore
  evidence so a large media tree cannot cause a boot start-limit storm.
- All website root locks and the one-time activation start grant are under
  `/run/uten-website-release` (`root:root 0700`). Lock creation uses
  `O_NOFOLLOW` and exact inode/owner/mode checks; the Node user cannot traverse
  that control directory.
- Render `deploy/nginx-website.conf.example` into a separate website vhost,
  replace all placeholders, then run `nginx -t` before reload.
- Keep a default-deny Nginx vhost for unknown hostnames.

Before linking a release, create the exact persistent targets and the cache
symlink as root. `__NGINX_WORKER_USER__` must be replaced with the read-only
worker identity observed in the rendered Nginx configuration:

```bash
sudo install -d -m 0755 -o root -g root \
  /opt/uten-website /opt/uten-website/releases \
  /usr/local/libexec/uten-website
sudo install -d -m 0750 -o uten-website -g uten-website \
  /var/lib/uten-website/runtime /var/cache/uten-website
sudo groupadd --system uten-website-media
sudo usermod --append --groups uten-website-media __NGINX_WORKER_USER__
sudo setfacl -m g:uten-website-media:--x /var/lib/uten-website/runtime
sudo install -d -m 2750 -o uten-website -g uten-website-media \
  /var/lib/uten-website/runtime/uploads
sudo install -m 0755 -o root -g root deploy/validate-runtime.sh \
  /usr/local/libexec/uten-website/validate-runtime

# Restore the separately approved website.db + matching uploads snapshot here.
# Do not create an empty database and do not copy website/prisma/dev.db.
sudo test -f /var/lib/uten-website/runtime/website.db
sudo chown uten-website:uten-website /var/lib/uten-website/runtime/website.db
sudo chmod 0600 /var/lib/uten-website/runtime/website.db

RELEASE_DIR=/opt/uten-website/releases/__RELEASE_ID__
sudo test ! -e "$RELEASE_DIR/public/uploads"
sudo ln -s /var/cache/uten-website "$RELEASE_DIR/.next/cache"
sudo /usr/local/libexec/uten-website/validate-runtime
```

Every restored media directory must be `uten-website:uten-website-media` mode
`2750`; every media file must be a non-empty, single-link regular
`gif/jpg/jpeg/png/webp` file owned by that pair at mode `0640`. Entry names are
limited to ASCII letters, digits, dot, underscore and hyphen and may not begin
with punctuation. Boot checks this contract within a fixed metadata budget;
activation, backup and restore evidence performs the complete byte inventory.
Any sampled violation rejects the start. The Nginx worker receives only group
read/traverse access and must not
be added to the `uten-website` group, which protects the database and runtime
secret. After changing group membership, restart/reload Nginx only after
`nginx -t`, then verify the worker can read a restored media file but cannot
read `/var/lib/uten-website/runtime/website.db` or `/etc/uten-website/website.env`.

The source chain is now executable, but the first production cutover remains
**NO-GO** until an approved `website.db` plus its
matching `uploads` snapshot have recorded checksums, business-content
acceptance evidence and a successful restore drill. `prisma db push`, an empty
auto-created SQLite file and the developer `website/prisma/dev.db` are not
production initialization procedures.

The last command requires `current` to point to a fully installed candidate.
After signed staging, run `uten-website-activate plan VERSION`, review the plan,
then pass its exact SHA and typed confirmation to `apply`. The activator closes
the Nginx gate, stops writes, creates a paired snapshot, runs the bundled
`prisma migrate deploy`, switches `current`, and reopens only after the same
signed boot guard, NTP, exact database history and readiness gates pass. The
single Node start inside the transaction requires and atomically consumes a
root-only grant bound to the current boot, in-progress marker, current target,
signed manifest, SQLite bytes and paired snapshot manifest.
On failure it restores the pair and previous release but leaves ingress closed;
only `uten-website-recover assess/apply` can archive the marker and reopen it.
The activator also fsyncs `activation-in-progress.json` after the paired snapshot
and before the first release/database mutation. If power is lost in that window,
boot remains closed and `uten-website-recover-interrupted assess/apply` provides
the separate evidence-bound restoration step. SQLite WAL/SHM/journal sidecars
are preserved with the incident and never mixed with the restored main file.

Runtime boot handling is intentionally selective:

- process exit, reboot, temporary network loss and later NTP recovery are
  automatic and do not need an operator start command;
- an intentional `systemctl disable --now uten-website.service` is respected:
  the watchdog closes entry and does not restart or reopen the service;
- OSS/DNS unavailability cannot mutate `current`; staging fails independently
  and the last signed local release continues when the public network returns;
- wrong/unmounted storage, critical free space/inodes, SQLite integrity or
  foreign-key failure, incomplete Prisma history, unsafe uploads, repeated
  crash loops and interrupted activation are fail-closed and require evidence;
- automatic Prisma migration and automatic root activation remain forbidden.

Backup and health timers are commissioned only after real alert delivery,
capacity, power-loss, seven-point retention and restore evidence is accepted by
two named reviewers. The two-step `uten-website-commission-automation` tool
binds those files and unit hashes to a reviewed plan, enables only backup and
health, and writes the final job-enable marker last. If power is lost mid-step,
both jobs remain blocked by `automation-in-progress.json`; its typed `recover`
action disables partial timers and archives that marker. Staging stays disabled.
Before this commissioning, each accepted recovery point must be created during
a reviewed maintenance window with
`uten-website-paired-backup --precommission --confirmation CREATE-PRECOMMISSION-WEBSITE-RECOVERY-POINT`.
That root-only path requires the timer to remain inactive and disabled and does
not create commissioning authority or enable automatic activation. If no
`current` release exists yet, it additionally requires the app/watchdog disabled
and ingress exactly closed, backs up only the already restored paired state,
uploads it append-only, and deliberately does not start Node afterward. This
breaks the first-activation backup bootstrap loop without bypassing the backup
gate or running an unsigned migration.

Backup, activation and recovery serialize every SQLite/uploads/current mutation
with one root-only `state-mutation.lock`. Backup releases it only after the
stopped paired snapshot is complete and before Node restarts; a separate
repository lock remains held through restic upload to exclude retention.

The upload boundary is intentional:

- ordinary public requests: `256 KiB`;
- `/admin` and `/admin/*`: `10 MiB` request envelope;
- application file limit: `8 MiB`;
- Next Server Action limit: `10 MiB`.

The extra Nginx headroom covers multipart metadata without globally increasing
the public request limit. The application still validates image type, decoded
pixel count and converts accepted files to WebP.

The CMS now requires `UPLOADS_DIR=/var/lib/uten-website/runtime/uploads` in production,
creates opaque WebP files there with exclusive mode `0640`, and returns a URL
only after the file is synced and closed. Nginx serves `/uploads/` directly from
that same fixed directory with `alias`, read-only methods and symlink blocking;
no mutable media path exists inside an immutable release. Local development
still defaults to `public/uploads`. This closes the source-level restart/404
defect, but production remains **NO-GO** until a rendered server configuration
passes a real authenticated CMS upload followed immediately by an HTTPS GET
without restarting either Next or Nginx.

## 5. Atomic rollout and rollback

1. Back up database and media and verify the backup completed off-host.
2. Build and scan the clean immutable artifact.
3. Create the state directories and cache symlink shown above.
4. Smoke test against an isolated restored copy of SQLite and media. Do not run
   a second process against live SQLite; if isolation is unavailable, use a
   maintenance stop-the-world cutover instead.
5. Atomically switch `current`, restart the service, and reload Nginx only after
   both configuration tests pass.
6. Verify `/api/health`, representative locale/catalogue pages, CMS login and a
   real upload/read-back.
7. Observe 5xx, latency, process restarts, disk space, database lock errors and
   media 404s. Roll back by switching `current` to the previous immutable
   release; do not roll back the database without a separately approved restore.

Minimum smoke routes: `/zh`, `/zh/products`, a real family/product route,
`/zh/news`, `/zh/careers`, `/admin/login`, and `/api/health`.

## 6. Backup and restore boundary

For the current SQLite transition topology:

- create a transactionally consistent SQLite backup using the SQLite backup
  API/CLI, not a raw copy while the process is writing;
- snapshot or back up `/var/lib/uten-website/runtime/uploads` in the same backup run;
- run daily, retain the latest 7 daily recovery points, and delete an old point
  only after the new point and its checksum are verified;
- encrypt backups and copy them to a separate account/region or offline target;
- alert on failed/missing backups and low space;
- perform and record a restore drill before GO and at least quarterly.

Do not combine website and ERP backup credentials or retention jobs. A database
backup without its matching media snapshot is not a complete website recovery
point.

## 7. Production GO blockers still requiring cloud resources

- DNS, valid TLS certificate, firewall/security-group rules and optional WAF;
- protected GitHub website environment, website-only signing key ceremony,
  RAM/OIDC trust acceptance and real OSS versioning/WORM evidence;
- monitored persistent state volume with capacity and inode alerts;
- provisioned append-only encrypted restic repository, seven successful daily
  receipts, enabled jobs, external alert routing and a tested restore host;
- secret manager or root-managed environment file rotation procedure;
- uptime, 5xx, latency, restart, disk and backup monitoring/alert routing;
- VPN/IAP plus MFA for `/admin`, shared login/session rate limiting, upload
  concurrency limits, media quota and 8 MiB/40 MP soak/OOM testing;
- recorded server evidence that a new CMS upload is immediately readable over
  HTTPS without a Next/Nginx restart;
- PostgreSQL plus private object storage before horizontal scaling/HA;
- reconciliation/baselining approval for any existing website database before
  applying the checked-in initial Prisma migration (never `migrate resolve`
  against unproven production state);
- a signed canonical `sqlite_schema` fingerprint checked at boot, so unchanged
  Prisma history cannot hide out-of-band table/index/trigger DDL drift;
- a database-backed media ledger (path, expected hash/size and lifecycle state),
  referenced-file completeness and orphan reconciliation; the bounded boot
  metadata probe and full restore hash test do not prove this live invariant;
- staging UAT, recovery drill, security review and named release approval.

## 8. CMS and ERP integration

The website currently uses independent Next.js admin authentication. If ERP SSO
is added later, use an OIDC authorization-code flow or a server-side token
exchange. Never share ERP database roles, browser secrets, session cookies or
filesystem mounts with the website. All CMS writes must remain authenticated
and auditable.
