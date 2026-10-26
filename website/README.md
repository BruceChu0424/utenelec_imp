# UTEN Website (Next.js)

<!-- WEBSITE-DEPLOYMENT-DEFERRED-20260812 -->
> **Deployment decision (2026-08-12): deferred.** The corporate website will not be installed on the
> current internal ERP server. It may be commissioned later on a separate cloud host with its own
> DNS/TLS, Linux identity, database/media authority, signing keys, backup, monitoring and approval.
> Until that future project is explicitly resumed, do not upload a website release, render a website
> vhost, install/enable website services or timers, or configure ERP inquiry forwarding on the ERP host.
> Local development and source tests may continue; they are not deployment authorization.

A full CMS-driven public website and international inquiry portal built with Next.js App Router.

The project now uses a family-first catalog model and strict publish guards so only safe, intentional content is exposed.

UI changes and related design documentation follow [AGENTS.md](AGENTS.md): use `frontend-design` by default, preserve Uten branding and business constraints, and use `ui-ux-pro-max` only when explicitly requested.

## What is in this repo

- Public pages (zh/en multi-locale, plus locale detection)
- Product catalog (series-first browsing, family pages, product pages, Studio)
- Admin CMS pages for content, products, media links and publication toggles
- Inquiry form with anti-abuse limits and consent capture
- Data tools for catalog normalization, legacy content repair, and seed tasks
- Nginx-ready deployment setup for cloud server

## Current implementation

- Product browsing is organized by `FAMILY` → `COLLECTION` → `PRODUCT` → `VARIANT`.
- Legacy slug compatibility is kept with permanent redirects (e.g. `/zh/products/legacy-v2-80` → `/zh/products/s300`).
- I18n and locale-specific SEO are enabled (`10` locale files).
- Non-verifiable content is marked and handled with care in trust flags.
- This is a company and product showcase. Customers can contact sales; there is no cart, checkout, payment or online order flow.
- Inquiries and delivery records commit together in the website database. IMP pulls pending records, imports them idempotently, and acknowledges only committed ERP records; a disconnected ERP does not lose an accepted inquiry.
- IMP's website workbench checks the configured connection and opens the CMS using a single-use PKCE authorization bound to the employee's original IMP session. Short leases are renewed only while that session and its current permissions remain valid.
- Homepage settings, products, series, scenes, news, cases, jobs and PDF resources share the same draft, frozen-preview, publish and rollback service. Permission checks, optimistic concurrency and audit records remain authoritative on the server.
- PDF resources are stored privately and downloads recheck publication and product scope. Sales claim and follow-up remain in IMP; the website only displays delivery receipts.
- These source capabilities are separate from deployment approval. Current local verification and remaining acceptance work are recorded in [`docs/website-imp-implementation.md`](docs/website-imp-implementation.md).

## Stack

- Next.js 16.4.2 App Router, with Webpack for development and production builds
- React 19.3.1 + TypeScript
- next-intl 4.13.5
- Prisma 5.22 with SQLite compatibility and a generated PostgreSQL schema/client; `DATABASE_URL` selects the runtime client
- Tailwind CSS
- Server Actions + HttpOnly Cookie auth model

## Quick start

```bash
cd website
npm ci
copy .env.example .env
```

Use Node `>=22.13.1 <23` or `>=24.11.0 <25` (the CI workflow pins 22.13.1). Set a unique random `AUTH_SECRET` and the local `SITE_URL` in `.env`, then apply migrations to a new local SQLite database:

```bash
npx prisma migrate deploy --schema prisma/schema.prisma
```

Import a reviewed catalog or use the explicitly destructive seed only against a disposable local database. Do not run seed or `db push` against an existing content or production database. Installation generates both Prisma clients from the single SQLite compatibility schema; never maintain the PostgreSQL schema independently.

Run the site:

```bash
npm run dev
npm run build
npm run start
```

Local pages:
- `http://localhost:3000/zh`
- `http://localhost:3000/en`
- `http://localhost:3000/admin/login`

IMP users enter the CMS from the website management area of the IMP workbench. The independent admin login remains available for separately configured website administrators; it does not grant an IMP employee additional rights.

### PostgreSQL local validation

Create a separate empty PostgreSQL database and set its `DATABASE_URL`, then run `npm run db:migrate:postgresql`. For existing SQLite content, use `scripts/migrate-sqlite-to-postgresql.mjs --source <absolute-offline-backup>` for a dry run. Only an empty destination is accepted; application requires `--apply --confirm WEBSITE_POSTGRESQL_MIGRATION`. The tool verifies counts and hashes for every application model in one transaction and refuses a repeat merge. Back up and migrate images and private documents separately; database-path verification does not prove file bytes were transferred.

The checked-in signed-release packaging and paired-recovery scripts still describe the SQLite runtime contract. PostgreSQL runtime support and local tests do not authorize installing a PostgreSQL deployment with that SQLite release bundle. A cloud database/storage plan and its recovery evidence must be prepared and approved before deployment.

## Environment variables

- `DATABASE_URL`
- `UPLOADS_DIR` (optional locally; production is pinned to `/var/lib/uten-website/runtime/uploads`)
- `DOCUMENTS_DIR` (optional locally, defaults to private `.local-state/documents`; production is pinned to `/var/lib/uten-website/runtime/documents`)
- `AUTH_SECRET` (must be long random string)
- `SITE_URL` (site origin)
- `ADMIN_USERNAME`, `ADMIN_PASSWORD` (only when explicitly creating/resetting an independent website administrator; never commit credentials)
- `ALLOW_DESTRUCTIVE_SEED` (keep `false`; enable only for a disposable database whose deletion is intended)
- `ADMIN_TRUSTED_CLIENT_IP_HEADER` (optional, for admin logs)
- `INQUIRY_TRUSTED_CLIENT_IP_HEADER` (must match your proxy, e.g. `x-real-ip`)
- `INQUIRY_RATE_CLIENT_MINUTE` (default 3)
- `INQUIRY_RATE_CLIENT_HOUR` (default 15)
- `INQUIRY_RATE_GLOBAL_MINUTE` (default 30)
- `INQUIRY_RATE_GLOBAL_HOUR` (default 300)
- `WEB_SITE_ID` (defaults to `uten`; must match IMP's configured site identity)
- `UTEN_WEBSITE_BRIDGE_TOKEN` (43–512-character random server-to-server secret, shared with the IMP backend; blank disables bridge access while the public site continues to accept durable inquiries)

The previous `IMP_INGEST_URL` / `IMP_INGEST_TOKEN` push settings are no longer used by the website. Follow the fixed-origin allowlist, connection configuration, permission and session contracts in [`../server/docs/website-management-bridge.md`](../server/docs/website-management-bridge.md). An accepted website receipt proves durable acceptance; only the exact ERP acknowledgment proves delivery. Neither means a salesperson has read or followed up the inquiry.

## Useful scripts

### Development

- `npm run dev`
- `npm run build`
- `npm run start`
- `npm run lint`

### Runtime data tasks

- `npm run catalog:normalize`
- `npm run catalog:normalize:apply`
- `npm run catalog:repair-content`
- `npm run catalog:repair-content:apply`
- `npm run content:guides`
- `npm run content:guides -- --apply --confirm=INTERNATIONAL_GUIDES_V1`
- `npm run content:international-settings`
- `npm run content:international-settings -- --apply --confirm=INTERNATIONAL_SETTINGS_V1`
- `npm run content:public-claims`
- `npm run content:public-claims -- --apply --confirm=PUBLIC_CLAIMS_V1`
- `npm run db:push`
- `npm run db:seed`
- `npm run db:upgrade`
- `npm run admin:reset-password`

### Tests and checks

- `node scripts/quality-gate.mjs` — the same complete gate used by Quality Gate and signed website release: locked install, fresh migrations, Next route type generation, lint, typecheck, all behavior tests, formal migration verification, dependency audits and a production build against another empty migrated database. Requires a supported Node version and Python 3; CI pins Node 22.13.1. With a standalone Node runtime, set `npm_execpath` to its compatible `npm-cli.js` and put the chosen Node/Python executables on `PATH`.
- `npm run test:all`
- `npm run test:prisma-migrations`
- `npm run test:admin-guardrails`
- `npm run test:catalog-normalization`
- `npm run test:catalog-public`
- `npm run test:legacy-series-content`
- `npm run test:publication-guards`
- `npm run test:inquiry-security`
- `npm run test:news-content`
- `npm run test:seo-localization`
- `npm run test:legacy-import`

Catalog normalization and the 50-series repair integration tests create private disposable SQLite databases from the checked-in Prisma migrations and seed synthetic catalog/source-audit records. They do not read or copy `prisma/dev.db`. Build validation uses another fresh empty migrated database and does not write the production uploads path.

The complete raw-breadcrumb evidence check reads all legacy product HTML files under `.scrape/v2/output`; when the archive is absent, the runner reports a skip rather than claiming source coverage. Its 120-second budget accommodates cold archive reads; it is not a website performance target. PostgreSQL CMS and nonempty-gallery migration tests are opt-in with `UTEN_TEST_POSTGRESQL=1`. `UTEN_TEST_POSTGRESQL_CONFIG` may select an absolute local private JSON configuration with `databaseUser`/`databasePassword` (otherwise the previous `.local-artifacts/website-imp/local-config.json` location is used). These tests only connect to `127.0.0.1:55439`, create uniquely named test databases, verify ownership, and drop those databases afterward; they never migrate the running website database. Keep credentials out of source and reports.

Production builds intentionally disable Webpack's filesystem cache: the pinned `next-intl` formatter loader contains a runtime import whose dependencies Webpack cannot reliably snapshot. Development keeps incremental caching. The complete gate runs ESLint and TypeScript separately before the production build; `next build` itself does not replace lint. `tests/production-build-cache.test.ts` verifies both cache modes and the i18n alias.

Lint uses supported ESLint 10.13.0 and keeps the complete Next.js 16.4.2 Core Web Vitals configuration. The official `@eslint/compat` adapter preserves the existing React, import and accessibility rules while their three pinned plugin releases still declare ESLint 9 peer ranges. Version-specific npm overrides bind only those plugins to the direct ESLint dependency; no `--force`, `--legacy-peer-deps` or warning suppression is used. `npm run lint` rejects every warning, and `tests/eslint-compat.test.ts` checks that representative negative fixtures still produce the original diagnostics. Remove the adapters and overrides together only after all three plugins publish compatible peer declarations and the regression checks pass.

The 2026-09-29 lockfile security update changes only the transitive `brace-expansion` patches to `1.1.21` and `5.0.12`. These cover the upstream parsing and recursion advisories [GHSA-q2hr-2g5m-vwhr](https://github.com/juliangruber/brace-expansion/security/advisories/GHSA-q2hr-2g5m-vwhr), [GHSA-qhr7-859c-m2p7](https://github.com/juliangruber/brace-expansion/security/advisories/GHSA-qhr7-859c-m2p7) and [GHSA-6j4f-fj2g-mc7p](https://github.com/juliangruber/brace-expansion/security/advisories/GHSA-6j4f-fj2g-mc7p); application dependencies and major versions remain unchanged.

## Docs map

- [`docs/cloud-server-deployment.md`](docs/cloud-server-deployment.md)
- [`docs/aliyun-local-erp-integration.md`](docs/aliyun-local-erp-integration.md) — Aliyun ECS website and company-local IMP connection, operator steps and acceptance boundaries
- [`deploy/README.md`](deploy/README.md) — signed release, manual activation,
  paired recovery and remaining production NO-GO gates
- [`docs/product-catalog-architecture.md`](docs/product-catalog-architecture.md)
- [`docs/product-catalog-migration.md`](docs/product-catalog-migration.md)
- [`docs/legacy-series-content-repair.md`](docs/legacy-series-content-repair.md)
- [`docs/international-content-strategy.md`](docs/international-content-strategy.md)
- [`docs/international-guides-seed.md`](docs/international-guides-seed.md)
- [`docs/inquiry-security.md`](docs/inquiry-security.md)
- [`docs/website-imp-implementation.md`](docs/website-imp-implementation.md) — shared CMS and durable inquiry contracts, local acceptance status
- [`docs/quality-acceptance-20261026.md`](docs/quality-acceptance-20261026.md) — local quality checkpoint, full source-evidence/PG tests and empty-database production build
- [`docs/homepage-apple-style-content-spec.md`](docs/homepage-apple-style-content-spec.md)

## Notes

- Keep paired backups of the active database, image uploads and private documents before any content migration or deployment. Local SQLite defaults to `prisma/dev.db` plus `public/uploads` and `.local-state/documents`; PostgreSQL uses its own independently backed-up database. The existing SQLite production package uses `/var/lib/uten-website/runtime/website.db`, `/var/lib/uten-website/runtime/uploads` and the separately provisioned documents directory.
- The public website runs independently of IMP availability. A local database, a production build, and a successful synthetic inquiry are distinct evidence; none by itself proves cloud delivery, sales UAT or a recoverable deployment.
