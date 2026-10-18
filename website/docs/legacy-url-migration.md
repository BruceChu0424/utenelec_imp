# Legacy URL migration

The frozen v2 archive records Chinese URLs at the root (for example Product.asp and productshow.asp?ID=607), and English URLs under /en. These paths are routed through /api/legacy/:legacyLocale/:legacyFile by a narrowly scoped Next rewrite. The existing proxy excludes paths containing a dot, so the old language is preserved without an Accept-Language redirect.

The resolver returns 308 with a same-origin relative Location and no-store after checking current publication state. Unknown IDs, unpublished products/articles, inactive parents and unsupported source locales return an actual HTTP 404 from the route handler. Legacy product details never fall back to the homepage.

- Product IDs use exact Product.sourceIdentity = ch-uten-v2:product:{ID}, plus an immutable source-locale record. Current editable translation fields do not establish whether an old Chinese/English URL existed. No raw source HTML is rendered.
- SortID uses exact Series.sourceIdentity and its source-locale record, then resolves the active canonical family; a source container is redirected only when it has one unambiguous public family child.
- Old news slugs were assigned by index in prisma/seed.ts. The checked map in lib/legacy-routes.ts was verified against .scrape/seed/extracted.json and .scrape/v2/output/catalog.json. ID 18 maps to news-6, not news-18. English source IDs 14 and 15 have no imported News target and remain 404; no article is guessed or auto-published.
- Known about, contact, partnership, careers, case, resource and news section IDs use explicit allowlists. News category links retain the corresponding company/industry filter. Job ID 1 points to the published regional-sales-manager anchor only if that job is public.

Query key casing is tolerated because the archive contains ID/id and SortID/Sortid; conflicting duplicate keys are rejected. Unknown detail IDs and source sections are not converted into generic catalog or homepage redirects. Legacy page-number and ordering parameters do not establish content identity.

Source checks are covered by tests/legacy-routes.test.ts with a disposable migrated database. Verify live HTTP status, Location, publication changes and both source languages before deployment. Existing /:locale/products/legacy-v2-* aliases retain their separate canonical-family redirect contract.
