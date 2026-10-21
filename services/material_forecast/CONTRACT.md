# Automatic material market contract v2

The main flow is one-time goods-to-benchmark association, followed by automatic
public SHFE daily/delayed data collection and CPU forecasts. No CSV is required.
No goods, staff, suppliers or ERP transaction facts leave the application.

## Built-in definitions and selection

The canonical built-in catalog is
`server/src/main/resources/pricing/material-benchmarks.json` (JSON array).
Fields: `seriesId,name,commodity,market,grade,region,currency,unit,priceBasis,
sourceName,sourceUrl,rollPolicy,provider,symbol,autoUpdate,selectable`.
Stable IDs: `shfe_cu_main_daily`, `shfe_al_main_daily`, `shfe_ag_main_daily`.
Provider is `SHFE_PUBLIC_DAILY`, symbols `cu/al/ag`. CU/AL are CNY/tonne;
AG is CNY/kilogram. These are futures benchmarks. PC must not use a PP/PVC proxy.
The catalog is selectable before any worker/snapshot exists. PUT may bind a
built-in definition even when data is pending. The database identity digest is
computed from definition semantics, never changing quote/model timestamps.

## Automatic collector

The independent Python daemon collects the three global series; its requests
contain no goods IDs. Only allowlisted official HTTPS SHFE hosts/paths are fetched.
No arbitrary URL input, eval, CAPTCHA bypass or retry storm. Time/size limits,
same-host redirects, bounded retries/backoff and atomic local cache are required.
Public free access is not a claim of unrestricted commercial redistribution rights.

Use official daily data and official annual archive download manifest. Read only
target commodity files, bounded archive sizes and no path extraction. First
publish the latest completed daily data, then backfill history and fit models.
Daily reference uses SETTLEMENTPRICE. Select the main contract using the previous
trading day's open interest (tie: nearest delivery month), with a valid current
settlement. Missing the previously selected contract must not introduce lookahead.
Use that same contract's previous/current settlement ratio for a forward chain,
removing artificial contract-roll jumps. Fit the chain, then convert forecast
values/intervals to the latest actual main-contract settlement level. Record the
actual contract and explicit basis; do not call this an exchange-published index.

Optional delayed quotes are separate from completed daily model training. They
use the selected contract, official market timestamp, fetched timestamp, correct
currency/unit and `delayMinutes:30`. Do not mix intraday last prices into daily
settlement labels or claim a paid real-time feed.

Raw downloaded revisions retain actual first-observed/fetched times. Historical
archives lack publication vintages: replay may use reconstructed daily availability
only when explicitly tagged `LATEST_HISTORY_REPLAY`. A replay pass may show
`RESEARCH_ONLY` estimates/direction but never active procurement advice or a
point-in-time validation claim. Failed baseline/coverage gates stay BASELINE_ONLY.

## Snapshot v2 additions

Keep all v1 fields below. schemaVersion=2 adds required fields:
`validationBasis` (`LATEST_HISTORY_REPLAY`),
`modelPriceBasis` (`CHAIN_LINKED_CURRENT_ANCHOR`), `quoteContract` (e.g. cu2611),
`sourceFetchedAt` (UTC ISO instant), `historyRecordCount` (integer).
RESEARCH_ONLY requires the same held-out MAE/fold/coverage gates as READY but has
procurementSignal=INSUFFICIENT. Direction still follows interval versus latest
settlement. Every v2 automatic replay remains barred from READY. Report MAE in
current-anchor price units and label that conversion explicitly in evidence.

`<seriesId>.quote.json` optional file:
`{schemaVersion:1,seriesId,contract,price,currency,unit,marketTime,fetchedAt,
delayMinutes:30,provider:"SHFE_PUBLIC_DAILY"}`. Service computes quote status and
expiresAt; missing quotes are not synthetic zeroes. Quote validity is bounded by
marketTime+2h and fetchedAt+1h; stale quote can be shown as dated/stale only.

`auto-feed-health.json`:
`{schemaVersion:1,workerVersion,generatedAt,autoUpdateEnabled,series:[
{seriesId,status,lastAttemptAt,lastSuccessAt,nextSyncAt,errorCode}]}`.
status is FETCHING/BACKFILLING/MODEL/IDLE/ERROR. Timestamps nullable UTC strings.
Only safe codes (NETWORK_ERROR/RATE_LIMITED/INVALID_SOURCE/MODEL_FAILED) are exposed.
A missing/older-than-10-minute heartbeat is OFFLINE, never 'syncing'. A one-shot
collector sets autoUpdateEnabled=false; daemon sets true while alive.

## ERP v2 endpoints and refresh

Existing GET/PUT routes stay. Catalog becomes List<Benchmark>, independent of
snapshots. Envelopes retain previous fields and add:
`benchmark` (definition or null),
`sync:{status,autoUpdateEnabled,lastAttemptAt,lastSuccessAt,nextSyncAt,errorCode}`,
`latestQuote` (quote file plus computed status CURRENT/STALE and expiresAt),
`refreshAfterSeconds:60`.
Missing built-in snapshot returns SYNC_PENDING, or SYNC_FAILED on fresh ERROR;
DISABLED remains when no snapshot directory is configured. The bound benchmark
is always returned so the user sees what was remembered and can unlink it.
Source failure retains valid previous evidence and separately reports failure.
The client refreshes GET at the earlier of server cadence/expiry; it never
repeats PUT. Respect foreground/selection/save/ownership guards. Lack of worker
heartbeat must not claim automatic updating is running.

The current UI uses frontend-design and existing Uten tokens/components. It shows
association, source/automatic update state, delayed quote, daily settlement, then
forecast/evidence. Research replay has an explicit label, no validated-accuracy
badge or active order signal. Remove CSV from the normal purchasing workflow.

## Legacy manually supplied v1 (optional diagnostic/custom input)

This is an offline, CPU, read-only market forecasting worker. Only operator supplied,
authorized CSV data enters it. It never fetches websites or receives ERP transactions.
The ERP preserves its existing historical transaction reference price.

## Worker input

CLI takes a JSON manifest and CSV, then atomically writes `<seriesId>.json` to an
operator configured snapshot directory. Manifest fields: `seriesId`, `name`,
`commodity` (COPPER/ALUMINIUM/SILVER/POLYCARBONATE), `market` (SPOT/FUTURES), `grade`,
`region`, `currency`, `unit`, `priceBasis`, `sourceName`, `sourceUrl`,
`authorized` (must be true), `rollPolicy` (required for FUTURES).
`sourceUrl` may be an empty string for an owned/offline source; when supplied,
it must be an HTTP(S) provenance URL without credentials. No URL is fetched.
Series IDs match `[a-z0-9][a-z0-9_-]{0,63}`. PC must use SPOT with an explicit grade and region. Currency/unit are labels,
never silently converted. CSV columns: `date,price,available_at`. All timestamps
are timezone aware; quote dates use Asia/Shanghai and generatedAt uses UTC.
Revisions are appended, never silently replaced.
Malformed/truncated quoted CSV is rejected. The import ledger is accepted only
with its exact supported fields and a digest matching the complete canonical
prefix of incoming rows; empty, shortened or incompatible ledgers cannot silently
reset import history. Failed imports retain the last complete snapshot.
Historical replay uses only the revision available at each forecast origin;
the latest revised series must not be sliced and called point-in-time backtesting.
Reject duplicate date+available_at, nonpositive/nonfinite price, future publication,
and implausible data. Missing sessions must never be filled with invented prices.

## Snapshot JSON (schemaVersion=1)

All decimal amounts/metrics are strings. Fields:

```
schemaVersion, seriesId, name, commodity, market, grade, region, currency, unit,
priceBasis, sourceName, sourceUrl, authorized, rollPolicy,
dataAsOf (date), generatedAt (UTC ISO instant), latestPrice,
status (READY/BASELINE_ONLY/INSUFFICIENT), reasonCodes,
modelVersion, libraryVersion, datasetDigest,
validation: {passed, baselineMAE, modelMAE, folds, coverage80,
             backtestStart, backtestEnd},
forecasts: [{horizon:1|5|20, price, lower80, upper80,
             direction:UP|DOWN|UNCERTAIN}],
procurementSignal (RISING/WATCH/INSUFFICIENT)
```

An optional `synthetic` boolean is for test artifacts only. Production readers
reject `synthetic:true`; tests explicitly opt in to generating synthetic artifacts.

Select among simple StatsForecast candidates using early chronological folds,
then evaluate on separate later folds against last-price Naive. READY requires
enough held-out folds, lower MAE than Naive, and tested interval coverage.
Validation failure keeps a baseline and no active purchase signal. Direction
requires the interval entirely above/below the latest price. Horizon counts
observations/trading sessions, not calendar dates; never fabricate future dates.
Market direction alone cannot decide an order without stock, lead time and quotes.
Conflicting horizons stay WATCH; RISING requires an UP at 5 or 20 observations
and no DOWN horizon. Production reader applies the same rule independently.

## ERP endpoints

`GET /api/master/goods/{goodsId}/price-analysis/market`:
`{status, seriesId, bindingVersion, current, canManage, reasonCodes, expiresAt}`.
Status also supports DISABLED/UNMAPPED/STALE/UNAVAILABLE. `current` is validated
snapshot above or null. Server rechecks staleness; old data never has READY status.
`expiresAt` is nullable UTC ISO instant; for a snapshot it is the earlier of
generatedAt + 36h and midnight Asia/Shanghai after its configured last usable
quote date. The client fails closed at this deadline even while a page stays
open, then refreshes. A missing/invalid deadline never enables an active signal.

`GET .../market/catalog`: list of valid snapshot objects, bounded, for selection.

`PUT .../market` body `{seriesId: string|null, expectedVersion: integer}`:
explicit save/unlink, returns the GET envelope. Use CAS and retain tombstone
version for unlink. Require goods:edit plus all existing purchase price analysis
permissions and current goods write scope at both controller and service.
Every read rechecks goods visibility and purchase price permissions. No category
permission is added. Do not expose arbitrary paths, URLs or raw parse errors.

Server owns the directory via `uten.material-forecast.snapshot-directory` (empty
means disabled). No training/network I/O runs in an HTTP request or Spring scheduler.
The frontend owns a staged local selection and only PUTs on explicit confirmation.
Catalog or snapshot failure cannot block or erase historical price analysis.
Account/permission/goods changes discard stale responses and clear data.
