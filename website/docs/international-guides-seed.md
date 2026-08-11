# International Procurement Guides Seed

The four guide pages are used as SEO-safe, low-risk international entry content.

## Current guide set

1. `choosing-the-right-wiring-standard-for-your-market`
2. `how-the-uten-product-system-works`
3. `oem-odm-project-brief-checklist`
4. `product-documents-before-approval`

They are bilingual by design (zh/en), and are used as the only always-available procurement content in the current release.

## Default run

```bash
npm run content:guides
```

This mode:

- prints/validates target slugs
- does not write to DB

## Apply (explicit confirmation)

```bash
npx tsx prisma/seed-international-guides.ts --apply --confirm=INTERNATIONAL_GUIDES_V1
```

Apply behavior:

- creates only missing guides (idempotent)
- never deletes news records
- never overwrites an edited guide (CMS priority)
- category remains `guide`

## Publish/index rule

- For non-zh/en locales, guides default to fallback behavior until the locale has native content.
- Guide pages can be published independently without forcing other article types.
