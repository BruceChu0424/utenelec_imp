# Material forecast v1 contract

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
