# Product catalog normalization P0

## Scope and safety boundary

This P0 adds reviewable catalog metadata and connects it to the family-first public catalog. It does not merge, delete, rename or reassign products, and it never infers SKU, electrical ratings, prices, translations or product claims.

The existing `Series.code`, `Product.slug`, flattened product/variant images and legacy provenance remain authoritative source evidence. Public family URLs use reviewed `Series.publicSlug`; legacy codes and collection URLs permanently redirect to the family URL. Reviewed or conservatively inferred taxonomy drives family-page navigation, while its status remains visible to the CMS. Series cards consume `coverImage` or enabled `combination` media as the reviewed cover source and otherwise compose a temporary cover from real product images.

## Added schema

- `Series.publicSlug`: reviewed family aggregation slug, independent from the current public `code` route.
- `Series.catalogRole`: `FAMILY`, `COLLECTION`, `CONTAINER`, `ARCHIVE` or `UNCLASSIFIED`.
- `Series.rowVersion`: optimistic-lock token for CMS updates.
- `SeriesMedia`: role-based `hero`, `lineup`, `lifestyle`, `combination` and `detail` media with localized alt text. `combination` is the recommended series cover role; use an approximately 16:11 image containing several representative products.
- `Product.functionType`, `gangCount`, `controlMode`, `configuration`, `classificationStatus`, `rowVersion`.
- `ProductVariant.legacySynthetic`, `dataStatus`, `isDefault`.

`Product.category` is retained unchanged because imported values are provenance-style identifiers, not a reviewed taxonomy. `ProductMedia` and flattened `image/gallery` fields are also retained; this P0 does not change public media reads.

## Administrator rules

- Publishing a product requires a selected, published series.
- Publishing a product requires at least one published variant with an image and one published, image-bearing default variant.
- A legacy synthetic variant may remain visible, but it cannot have an SKU or be marked `VERIFIED`.
- Submitted non-empty SKUs are checked case-insensitively against other products.
- Product and series updates require the posted `rowVersion`; stale forms fail without partial writes.
- Published products and series cannot be hard-deleted. A series with products or child series cannot be deleted even after unpublishing.
- `CONTAINER` and `ARCHIVE` series cannot be published from the CMS.
- Series media paths remain restricted to `/uploads/` and `/images/`.

## Normalization contract

The normalizer recognizes families only by exact `ch-uten-v2:series:<sourceId>` identity. It does not classify by name or `code`, so an old seed named S300 cannot replace or overwrite the imported S300 family.

Reviewed family source IDs and slugs:

| Source IDs | Public slugs |
| --- | --- |
| 1, 2, 3, 4, 5, 6, 7 | v1-0, v1-1, v2-0, v3-0, v4-0, v5-0, v6-0 |
| 9, 10, 11, 12 | v7-0, v8-0, v9-0, v9-1 |
| 53, 54, 61 | floor-socket, v1-2, a6-0 |
| 70, 75, 76, 77 | q7, q9, q3, v4-white |
| 78, 79, 80, 81 | a5, a8, s300, z9 |

- These exact nodes become `FAMILY`.
- Their direct product-bearing child nodes become `COLLECTION`; leaf publication state is preserved.
- Source ID 60 becomes a non-public `CONTAINER`.
- A confirmed family is published only when it already contains a published direct or descendant product. This creates navigation aggregation and does not publish any product.
- Other seed/archive/unclassified nodes keep their publication state.
- Missing product function/gang/control values may be inferred from existing localized names and collection names. Results are marked `INFERRED`; uncertain results remain `NEEDS_REVIEW`. `VERIFIED` products are never changed.
- Exact imported `...:variant:<productSourceId>:base` variants become `legacySynthetic`; a sole base variant also becomes the default. No SKU is created.

## Deployment order

1. Stop CMS writes or place the website in a maintenance window.
2. Back up the target database and uploaded assets using the normal production backup procedure.
3. Deploy code containing the new Prisma schema.
4. Apply the additive schema change to the explicitly selected target database. Do not run `db push` without confirming `DATABASE_URL`.
5. Run a dry-run and archive its full report:

   ```powershell
   npm run catalog:normalize -- --database D:\explicit\catalog.db --report D:\audit\catalog-plan.json
   ```

6. Review blocking issues, counts, `familiesToPublish`, target family slugs and sample product inferences.
7. Apply only after review:

   ```powershell
   $env:UTEN_CATALOG_NORMALIZATION_CONFIRM='APPLY_REVIEWED_CATALOG_NORMALIZATION'
   npm run catalog:normalize:apply -- --database D:\explicit\catalog.db --backup-dir D:\backups\catalog-normalization
   ```

8. The apply command creates a SQLite `VACUUM INTO` backup before a single transaction and writes a full audit JSON beside that backup.
9. Re-run dry-run. Change counts must be zero; target summary counts remain stable.
10. Perform CMS UAT: stale-form conflict, publish guard, synthetic variant guard, series media save, pagination/filtering and delete refusal.

## Legacy Series name repair

The formal legacy import contains 50 Chinese Series labels truncated by the old
navigation markup and 25 English labels with source spelling pollution. Run the
separate, identity-scoped content repair after schema/catalog normalization and
before public catalog UAT. Its complete source-ID map, evidence rules, commands and
rollback boundary are documented in
[`legacy-series-content-repair.md`](./legacy-series-content-repair.md).

The repair only changes the `zh/en` name fields and increments `Series.rowVersion`.
It preserves hierarchy, publication, product ownership and all raw source audit
records. A second apply must report zero changes.

Automated apply tests must never mutate `prisma/dev.db`: they first copy that database to a unique temporary directory, upgrade only the copy, apply twice, and verify all Series/Product/ProductVariant counts, identities and ownership relations remain unchanged. A real target may be upgraded only after that copy test passes, its own backup and dry-run have been reviewed, and the database path is explicit.

## Rollback

If apply fails, the database transaction rolls back and the pre-apply SQLite backup remains available. If post-apply UAT fails, stop writes and restore the generated backup using the normal database recovery procedure. Do not copy a live SQLite file while it is being written.

Schema rollback should not drop the new columns immediately. The public site does not read them, so leave them in place until data and audit reports have been retained and a separate destructive migration is reviewed.

## Future ERP / Spring boundary

The ERP/Spring service should eventually own catalog drafts, taxonomy, review status, publication, authorization, audit and the transactional outbox. Stable IDs, `sourceIdentity`, `publicSlug` and row versions are migration keys. Next.js should become a read-only consumer of a published catalog projection.

The ERP browser must not connect directly to the website database. ERP authorization should be enforced by the ERP backend, which calls a catalog administration API using a narrowly scoped service identity or short-lived delegated token. During migration, freeze the old Next CMS before enabling ERP writes; never run two uncontrolled writers against the same catalog.
