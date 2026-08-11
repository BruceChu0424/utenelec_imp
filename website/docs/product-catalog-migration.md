# Product Catalog Migration Playbook (P0)

This document covers the current production-safe migration chain for catalog normalization.

## 1. Scope

- Move legacy flat products into FAMILY/COLLECTION view model
- Keep raw source as immutable for traceability
- Add publish guards and variant trust flags
- Repair broken legacy series naming where crawler evidence is authoritative

## 2. Preflight (must do in order)

1. Stop all CMS writes or set CMS maintenance window.
2. Backup:
   - `prisma/dev.db` (or target database)
   - `public/uploads`
3. Verify `.env` and `DATABASE_URL`.
4. Confirm code version matches scripts below.

## 3. Normalize dry-run

```bash
npm run catalog:normalize -- --report D:\audit\catalog-plan.json
```

Review:

- family count and publish count
- legacy ids mapped to FAMILY/COLLECTION
- issues list (must be empty or acceptable for next apply)
- `lineage` and `publicSlug` proposal

## 4. Apply (explicitly confirm)

```powershell
$env:UTEN_CATALOG_NORMALIZATION_CONFIRM='APPLY_REVIEWED_CATALOG_NORMALIZATION'
npm run catalog:normalize:apply -- --report D:\audit\catalog-plan.json --backup-dir D:\backups\catalog-normalization
```

Apply behavior:

- creates backup with `VACUUM INTO`
- runs inside one DB transaction
- validates identity (`sourceIdentity`, `legacyId`) before write
- increments `rowVersion`
- keeps all raw source records
- second apply should return `already clean` and create no second meaningful changes

## 5. Verify after apply

- re-run `npm run catalog:normalize -- --report ...` should output zero changes
- run contract checks:
  - `npm run test:catalog-normalization`
  - `npm run test:catalog-public`
  - `npm run test:publication-guards`
- perform CMS UAT:
  - stale `rowVersion` conflict
  - publish guard on orphaned items
  - synthetic variant behavior

## 6. Legacy naming repair (if needed)

Legacy names with truncation / typo are repaired by:

```bash
npm run catalog:repair-content -- --report D:\audit\series-repair-plan.json
```

Apply only by confirmation env:

```powershell
$env:UTEN_LEGACY_SERIES_CONTENT_CONFIRM='APPLY_REVIEWED_LEGACY_SERIES_CONTENT'
npm run catalog:repair-content:apply -- --report D:\audit\series-repair-plan.json --backup-dir D:\backups\legacy-series-content
```

This only touches `Series.i18n` and `Series.rowVersion` under strict id/hash checks.

## 7. Rollback

- keep generated backup path from apply output
- if UAT fails after apply, restore by your normal DB restore process from that backup
- keep raw source hash tables untouched for later audit

## 8. Not in this phase

- Full model/price/spec master migration
- Full ERP integration and workflow approval chain
- Multi-instance inquiry limiter upgrade (see `inquiry-security.md`)
