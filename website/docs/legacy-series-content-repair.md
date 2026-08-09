# Legacy Series content repair

## Audited finding

The production-imported catalog contains 75 `Series` rows with
`legacySource=ch-uten-v2`. A read-only profile found:

- 50/75 Chinese names (66.7%) contain a literal ellipsis or malformed character.
- 25/75 English names (33.3%) contain the source typos `Mirco`, `Electroic`,
  `swotcj`, `spclet` or `siwtch`.
- The crawler output has 148 localized category records. Aligning every product
  detail `div.rtop` breadcrumb to its `SortPath` recovered evidence for all 148
  records with zero conflicting names for the same `(locale, sortId)`.

The cause is upstream parsing, not CSS truncation. The old site's left navigation
contains shortened/malformed anchor text, and the original crawler used that text
as `category.name`. The product detail breadcrumb contains the complete Chinese
hierarchy.

## Complete affected identity map

Identity is always `ch-uten-v2:series:<sourceId>`. The following groups enumerate
all 50 affected source IDs; names are never used as identity or deduplication keys.

| Raw Chinese label | Complete Chinese public label | Reviewed English public label | Source IDs | Count |
| --- | --- | --- | --- | ---: |
| `大跷板&…` | 大跷板开关系列 | Rocker Switches | 8, 16, 18, 23, 26, 29, 32, 35, 40, 43, 48, 55, 71 | 13 |
| `LED微点ঀ…` | LED微点开关系列 | LED Micro-Point Switches | 13, 15, 19, 24, 27, 30, 33, 36, 41, 44, 49 | 11 |
| `通用电&…` | 通用电子插座系列 | Electronic Switches & Sockets | 14, 17, 20, 25, 28, 31, 34, 37, 42, 45, 50, 56, 73 | 13 |
| `通用电&…` | 通用电子插座功能件 | Socket Function Modules | 21, 39, 47, 52, 57 | 5 |
| `开关功&…` | 开关功能件系列 | Switch Function Modules | 22, 38, 46, 51, 58 | 5 |
| `液压缓&…` | 液压缓冲式地面插座系列 | Hydraulic-Damped Floor Sockets | 53 | 1 |
| `纯平开&…` | 纯平开关系列 | Flat Switches | 59 | 1 |
| `出口产&…` | 出口产品 | Export Products | 60 | 1 |

Chinese targets are exact detail-breadcrumb labels. English source breadcrumbs
repeat the legacy typos, so the public English layer uses conservative reviewed
taxonomy. Source ID 53 has no English category record; its English name is a
reviewed translation of the exact Chinese breadcrumb. Raw listing and detail
evidence remain audit-only and are not rewritten.

The 25 spelling-polluted English records are:

- `LED Mirco-point switch`: 13, 15, 19, 24, 27, 30, 33, 36, 41, 44, 49.
- `Electroic electronic switch&socket` (including the `swotcj&spclet` variant at
  20): 14, 17, 20, 25, 28, 31, 34, 37, 42, 45, 50, 56, 73.
- `Flat screen siwtch series`: 59.

## Permanent ingestion fix

`parse_product_detail()` now emits category breadcrumb entries aligned to stable
`SortPath` IDs. The crawler updates a category from this evidence while retaining:

- `listingName`: the old navigation label;
- `detailBreadcrumbName`: the authoritative detail label;
- `detailBreadcrumbSource`: the detail page URL/hash/raw HTML path.

The importer uses the reviewed public-name manifest only for the production
`http://www.ch-uten.com` origin. It rejects an unexpected new source label instead
of silently applying a stale mapping. `LegacySourceRecord.rawPayload`, source
hashes, identities and raw HTML references remain unchanged and unpublishable.

## Existing database repair

The repair command is dry-run by default. It requires all 50 exact identities,
checks `legacySource` and `legacyId`, and only accepts known source names or an
already-repaired target. A different/manual CMS name is a blocking issue.

```powershell
npm run catalog:repair-content -- `
  --database D:\explicit\catalog.db `
  --report D:\audit\legacy-series-content-plan.json
```

Review these expected values before apply:

- `expectedSeries=50`
- `locatedSeries=50`
- `chineseAnomaliesBefore=50` on the original import
- `englishPollutionBefore=25` on the original import
- `issues=[]`

Apply only to an explicit database path during a CMS write freeze:

```powershell
$env:UTEN_LEGACY_SERIES_CONTENT_CONFIRM='APPLY_REVIEWED_LEGACY_SERIES_CONTENT'
npm run catalog:repair-content:apply -- `
  --database D:\explicit\catalog.db `
  --backup-dir D:\backups\legacy-series-content
```

Apply creates a `VACUUM INTO` SQLite backup, then updates only `Series.i18n` and
increments `Series.rowVersion` in one transaction. The update predicate includes
the exact ID, source identity, legacy fields, row version and pre-image i18n. A
concurrent change rolls back the transaction. A JSON audit is written beside the
backup.

Re-running apply after success returns `status=already-clean`, zero changes and
does not create another no-op backup.

## Verified invariants and release boundary

Automated integration runs only on a copied SQLite database. It applies twice and
asserts that Series/Product/ProductVariant counts, source identities, hierarchy,
publication, product ownership and immutable `LegacySourceRecord` count/digest do
not change. Raw breadcrumb tests cover all 50 Chinese corrections and found zero
conflicts.

This is not authorization to edit `prisma/dev.db` or a deployed database. The
operator must still review the target dry-run, retain the generated backup/audit,
perform Chinese and English catalog UAT, and verify rollback before production
release.
