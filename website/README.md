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

## What is in this repo

- Public pages (zh/en multi-locale, plus locale detection)
- Product catalog (series-first browsing, family pages, product pages, Studio)
- Admin CMS pages for content, products, media links and publication toggles
- Inquiry form with anti-abuse limits and consent capture
- Data tools for catalog normalization, legacy content repair, and seed tasks
- Nginx-ready deployment setup for cloud server

## Current implementation state (2026-08-10)

- Product browsing is organized by `FAMILY` → `COLLECTION` → `PRODUCT` → `VARIANT`.
- Legacy slug compatibility is kept with permanent redirects (e.g. `/zh/products/legacy-v2-80` → `/zh/products/s300`).
- I18n and locale-specific SEO are enabled (`10` locale files).
- Non-verifiable content is marked and handled with care in trust flags.
- Inquiry flow includes strict validation, consent flag persistence, and rate limiting.
- Admin actions are protected by session-based auth and rowVersion concurrency checks.
- Security and production hardening docs are now included in `website/docs`.

## Stack

- Next.js 15 App Router
- React 18 + TypeScript
- next-intl
- Prisma + SQLite (current repository default)
- Tailwind CSS
- Server Actions + HttpOnly Cookie auth model

## Quick start

```bash
cd website
npm ci
copy .env.example .env
```

Install and run:

```bash
npm run dev
npm run build
npm run start
```

Local pages:
- `http://localhost:3000/zh`
- `http://localhost:3000/en`
- `http://localhost:3000/admin/login`

## Required environment variables

- `DATABASE_URL`
- `UPLOADS_DIR` (optional locally; production is pinned to `/var/lib/uten-website/runtime/uploads`)
- `AUTH_SECRET` (must be long random string)
- `SITE_URL` (site origin)
- `ADMIN_USERNAME`
- `ADMIN_PASSWORD`
- `ALLOW_DESTRUCTIVE_SEED` (`true`/`false`)
- `ADMIN_TRUSTED_CLIENT_IP_HEADER` (optional, for admin logs)
- `INQUIRY_TRUSTED_CLIENT_IP_HEADER` (must match your proxy, e.g. `x-real-ip`)
- `INQUIRY_RATE_CLIENT_MINUTE` (default 3)
- `INQUIRY_RATE_CLIENT_HOUR` (default 15)
- `INQUIRY_RATE_GLOBAL_MINUTE` (default 30)
- `INQUIRY_RATE_GLOBAL_HOUR` (default 300)
- `IMP_INGEST_URL` (optional pair with `IMP_INGEST_TOKEN`; forwards each inquiry to the IMP platform's unified inbox at `/api/website-inquiries/ingest`. Leave both empty to keep inquiries local only — `/admin/inquiries` remains the fallback. Forwarding is fire-and-forget and never blocks the customer submit. See `docs/backend-consolidation-analysis.md`)
- `IMP_INGEST_TOKEN` (shared secret, must match IMP `UTEN_WEBSITE_INQUIRY_INGEST_TOKEN`)

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

- `npm run test:admin-guardrails`
- `npm run test:catalog-normalization`
- `npm run test:catalog-public`
- `npm run test:legacy-series-content`
- `npm run test:publication-guards`
- `npm run test:inquiry-security`
- `npm run test:news-content`
- `npm run test:seo-localization`
- `npm run test:legacy-import`

## Docs map

- [`docs/cloud-server-deployment.md`](docs/cloud-server-deployment.md)
- [`deploy/README.md`](deploy/README.md) — signed release, manual activation,
  paired recovery and remaining production NO-GO gates
- [`docs/product-catalog-architecture.md`](docs/product-catalog-architecture.md)
- [`docs/product-catalog-migration.md`](docs/product-catalog-migration.md)
- [`docs/legacy-series-content-repair.md`](docs/legacy-series-content-repair.md)
- [`docs/international-content-strategy.md`](docs/international-content-strategy.md)
- [`docs/international-guides-seed.md`](docs/international-guides-seed.md)
- [`docs/inquiry-security.md`](docs/inquiry-security.md)
- [`docs/homepage-apple-style-content-spec.md`](docs/homepage-apple-style-content-spec.md)

## Notes

- Keep paired backups of the active database and media before any write command. Local development uses `prisma/dev.db` plus `public/uploads`; production uses `/var/lib/uten-website/runtime/website.db` plus `/var/lib/uten-website/runtime/uploads`.
- For multi-instance/cloud deployment, SQLite alone is not sufficient for concurrent writes; prefer PostgreSQL and shared cache/queue.
