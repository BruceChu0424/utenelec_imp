# Product Catalog Architecture (Family-first)

## 1. Why this model

The website runs in family-first mode to make international users understand offerings quickly.

- FAMILY = public series group (example: S300, Q7, V4)
- COLLECTION = sub group or product group inside FAMILY
- Product = one offering in a collection
- ProductVariant = selectable appearance/variant for the offering

This avoids showing all items at once and keeps URLs meaningful.

## 2. Core entities

### Series

- `catalogRole`: `FAMILY | COLLECTION | CONTAINER | ARCHIVE | UNCLASSIFIED`
- `publicSlug`: public URL slug
- `coverImage`: fallback cover
- `SeriesMedia`: role-based assets (`combination`, `hero`, `lifestyle`, `detail`, `lineup`)
- `rowVersion`: optimistic-lock token for CMS edits

### Product

- `seriesId`: parent series
- `functionType`, `gangCount`, `controlMode`, `configuration`
- `classificationStatus`: `VERIFIED | INFERRED | NEEDS_REVIEW`
- `specs`: structured specs for future use
- `model`: nullable when not verified

### ProductVariant

- `legacySynthetic`: legacy placeholder variant marker
- `isDefault`: default selected variant
- `dataStatus`: `VERIFIED | INFERRED | NEEDS_REVIEW`
- `legacySynthetic` variants can display images but must not be treated as true model/sku/spec facts.

## 3. Routes

- `/[locale]/products` shows FAMILY cards
- `/[locale]/products/[familySlug]` shows family detail, filters and related products
- `/[locale]/products/[familySlug]/[productSlug]` shows product detail
- Legacy URLs are still accepted and redirected to canonical family/product routes (typically 308)

## 4. Publication guardrails

- FAMILY/COLLECTION must pass publish validation
- Published product cannot belong to unpublished parent collection/family
- Published container/archive nodes are blocked from public publishing
- `rowVersion` mismatch blocks stale writes
- Published items are protected from hard delete

## 5. Data trust policy

Public pages should respect status:

- `VERIFIED`: show as factual content
- `INFERRED`: show as "for navigation/reference only"
- `NEEDS_REVIEW`: do not elevate as sales claim

For example, `legacySynthetic` variant image is valid for visual trial, but SKU/spec fields are intentionally masked until verified.
