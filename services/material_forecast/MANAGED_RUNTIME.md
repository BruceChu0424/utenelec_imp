# Managed market runtime and portable settings

This extends automatic v2: an employee links goods once. Installation/release
prepares the runtime automatically; portable behavior and goods bindings live in
the database. No machine-specific path, command, URL or Python installation is a
system setting. Existing source/forecast safety contracts remain applicable.

## Portable system settings

Use the existing system_settings registry, CAS batch update, step-up, superadmin +
authorization:manage, and audit. Existing PRESERVE applies. Forward migration V891
seeds keys with ON CONFLICT DO NOTHING; do not edit V890 or any applied migration.

| Key | Type/default | Range |
| --- | --- | --- |
| material_forecast.enabled | BOOL true | true/false |
| material_forecast.interval_minutes | INT 15 | 15..60 |
| material_forecast.history_days | INT 1200 | 3..3650 |
| material_forecast.backfill_budget | INT 30 | 0..1000 |

Category id is material_market. New installs are enabled because the user has
explicitly requested a configured automatic service; an existing false is never
overwritten. Only a local company business instance may launch collection; cloud
profile/site never does. Convert minutes to seconds only at the worker boundary.
Apply mode is NEXT_SCHEDULED_RUN. A successful save does not prove application.

Policy revision is SHA-256 over a canonical versioned representation of all four
effective values, stable across hosts and database restore. The backend owns its
exact serialization. The worker echoes, never invents, the supplied revision.

## Host layout and payload

Default state/snapshot root is a material-forecast child of the active durable
attachment storage root (internal or local). An explicit existing snapshot-dir
bootstrap override remains compatible, but no path is stored in DB. Never write
into an immutable release directory or place executable venvs on the noexec media
volume. Linux runtime cache uses /var/cache/uten-imp/material-forecast; Windows
uses an app-owned LocalAppData cache. Unit CacheDirectory/write permissions and
backup coverage must agree with these defaults.

Simple release adds server/material_forecast/ to its signed artifact. It contains
worker.py, forecast_worker/*.py, adjacent material-benchmarks.json, preparation
helpers, a platform runtime manifest, complete hash-pinned dependency lock and
offline wheelhouse. The active company platform is Ubuntu24.04/x86_64/Python3.12;
the helper also supports Windows x64 for the current workstation. Do not require
Codex runtimes or LibreOffice's python.exe. Use /usr/bin/python3 (validated 3.12)
on Ubuntu and discover/validate the installed PythonCore3.12 registry executable
on Windows. The one-time base OS Python/venv requirement belongs in existing app
installation, not an employee workflow. Production startup never contacts PyPI.

The payload preparation protocol (paths are operator/bootstrap data only):

```
python prepare_runtime.py --payload <absolute-payload> --cache <absolute-cache>
```

Success stdout is one JSON object:
`{schemaVersion:1,state:"READY",platform,pythonExecutable,workerScript,catalog,
lockDigest,workerVersion}`. Logs/errors are bounded and contain no server secrets.
Cache installations are keyed by platform/lock digest, OS locked, verified and
atomically marked ready. Use pip --no-index --require-hashes with payload wheels.
Do not trust a stale directory merely because python.exe exists. The Windows
prepare_runtime.ps1 wrapper discovers a valid base interpreter then calls this
helper with the same arguments and returns the same JSON. Linux invokes helper
with /usr/bin/python3. A launcher may supply a validated base executable override
for tests/bootstrap; this is not a portable database setting.

## Supervisor and heartbeat acknowledgement

Backend has a private asynchronous SmartLifecycle supervisor, not HTTP training
and not the platform-wide single scheduled-task thread. About every15s it reads
the DB policy, prepares runtime if necessary, starts/stops its own one worker,
and applies changed policy by graceful restart. A per-state-dir OS lease prevents
two JVMs launching duplicate collectors. Kill only owned processes/descendants;
never find-and-kill unrelated Java/Python processes. Unexpected exit uses bounded
backoff. Shutdown and config stop are graceful before bounded force termination.

All child environments are cleared and only minimal OS/TLS/temp/UTF8 and bounded
numerical thread variables are retained. Never pass DB/JWT/crypto/cloud secrets.
Arguments are a list, fixed trusted helper/worker paths, and validated numbers.

Worker accepts optional `--configuration-revision <64lowerhex>` and
`--run-id <canonical-uuid>`. Managed mode passes both. Health v1 adds these optional
fields: configRevision,runId. Manual legacy collectors can omit them. Admin
For an enabled policy, configurationApplied is true only for the owned live process
and fresh heartbeat generated after its start, matching both the desired revision
and current runId. For a disabled policy, it becomes true after reconciliation has
stopped owned collection and confirmed no other collector owns the state-dir lease;
appliedRevision then acknowledges the disabled policy without a live heartbeat.
An unknown external collector must yield COLLECTOR_BUSY, not a false disabled
acknowledgement. Old restored health/PIDs cannot assert an online/applied state.

Replace path-existence collector lock with real OS file locking (fcntl/msvcrt),
released even after crash. Existing leftover marker files cannot block reboot.
Control/config changes do not reset source cache, old predictions or bindings.

## Read-only administrative status

GET /api/admin/system-settings/material-forecast-status has the existing
superadmin/authorization:manage guard at both controller/service. Response:

```
{
  dataAsOf, expiresAt, refreshAfterSeconds:15,
  configuration:{enabled,intervalMinutes,historyDays,backfillBudget,revision},
  runtime:{state,available,processRunning,desiredRevision,appliedRevision,
           configurationApplied,startedAt,lastExitAt,lastExitCode,lastErrorCode},
  feeds:[{seriesId,name,sync,latestQuote,snapshotStatus,dataAsOf,historyRecordCount}]
}
```

States: DISABLED,PREPARING,STARTING,RUNNING,STOPPING,ERROR,UNAVAILABLE,NOT_LOCAL.
Error codes: BASE_PYTHON_UNAVAILABLE,RUNTIME_MISSING,PREPARATION_FAILED,START_FAILED,
PROCESS_EXITED,WORKER_UNRESPONSIVE,CONFIGURATION_PENDING,COLLECTOR_BUSY. Expose no
paths, process command, credentials or unbounded raw exceptions. A runtime is
RUNNING/applied only when actual acknowledgement is current; a saved policy is
not execution evidence. Reads never start a process. Neutral application ports
keep master pricing from importing admin setting/runtime classes.

The system settings page uses existing Uten settings/batch save/step-up. Add a
separate read-only status card, independently failing, with policy acknowledgement,
source phases, last success and safe errors. It must stop claiming live state
after expiresAt during a slow GET; background/ownership rules remain. No invented
progress percentage and no operator paths/commands in the employee UI.

## Move, backup, restore and validation

DB backup/restore preserves settings and goods bindings. The regular release
automatically recreates host runtime without an employee re-entering settings.
If cache is not migrated, data is refetched, not requested as CSV from employees.
Paired backup must explicitly include a stable market-state subtree (raw source
revisions, issued predictions, cache pointers/state, current snapshots/quotes).
Coordinate short file-write barriers or a validated stable export; existing media
backup only includes DB referenced attachment objects and does not suffice.
Exclude executable caches/venvs and live OS locks. Restore retains old health as
evidence but resets its online acknowledgement; never resurrect a PID/run lease.

Verify full API policy/step-up/CAS, process restart/disable/crash recovery and no
duplicate, real source/consumer contract, mapping version unchanged across price
updates, and DB restore to a fresh host directory carrying the same settings and
bindings. Source/code checks, local process activation, PR/main merge, package
build and company-host deployment are distinct reported evidence states.
