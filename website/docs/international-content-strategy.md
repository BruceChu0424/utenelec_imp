# International Content Strategy (Website Versioning and Localization)

This is the content strategy guide for building a truly global-facing marketing site with practical limits.

## 0) Goals

1. Make the catalog easy to scan for international buyers before technical qualification.
2. Keep copy concise and trustworthy across languages.
3. Improve SEO and discovery for country/industry keywords.
4. Avoid exposing inaccurate factual claims in languages with weak source data.

## 1) What belongs on the homepage

Homepage should prioritize three blocks:

1. **Hero + product map**
   - One-family hero image per section
   - Short problem-value statement
   - CTA to "Explore by Family"
2. **Latest products (high-confidence content first)**
   - Show only latest/recently selected products from admin `featured`/`latest` governance
   - Keep one product card per family when evidence is incomplete
3. **Studio and trust block**
   - Highlight combination visuals, material direction, certification/QA process and inquiry CTA

Recommended layout pattern (Apple-like):

- split left text block + right media block on desktop
- single-column with full-bleed media on mobile
- minimal scrolling above the fold

## 2) Recommended category model

Use one structure in both UI and CMS:

- **Family page** (S300, Q7, V4, etc.)
- **Collection page** (sub-groups under family)
- **Product page** (functional offering)
- **Variant view** (exact colour/finish options when data is verified)

### Rules

- Category pages are for selection context, not long descriptions.
- Product pages focus on function, application, and model lineage.
- Variant cards must not invent color/finish if it is not verified in data.
- `legacySynthetic` variants remain visual demos only.

## 3) Latest products section policy

To satisfy your “homepage only latest products” request:

- Use explicit admin order field for homepage order.
- If no manual order exists, use `createdAt desc` on confirmed published records.
- Use a cap (e.g. 6–12 cards) and lazy load for deeper exploration.
- Do not auto-append stale or unknown SKUs merely because they exist in database.

## 4) Product card and image policy

- **Do not let a single SKU blow up page height**
  - Use controlled thumbnail sizes
  - Reserve whitespace; avoid zooming low-res source assets to large cards
- **Family cover / combo image policy**
  - Primary: `SeriesMedia.role = combination`
  - Fallback: `coverImage`
  - Fallback fallback: curated editor-generated collage
- **Variant image**
  - Real photos if available
  - If only one source image exists, label as representative and avoid implying full detail

## 5) Internationalization content matrix

Given current source depth, use three levels:

- `verified`: full zh/en text with model-level evidence
- `shared`: same meaning translated text without unsupported model claims
- `needs-localization`: placeholder + editor action required

For non-zh/en locales:

- allow brand/corporate copy and key navigation first
- show factual fields only where safe
- mark unverified content as `noindex` if needed by SEO rules

## 6) Languages to publish now

- zh / en: standard pages + catalog fields + news
- ar / de / es / fr / ja / ko / pt / ru: pages can be visible for UI shell and selected marketing content

For long-term quality:

- add market-specific content owners
- set SLA: first draft and QA pass per language every quarter
- avoid machine-only output for compliance claims

## 7) News and article policy

Recommended publish set:

1. **Product system guides** (how-to style)
2. **Project readiness and specification guidance**
3. **OEM/ODM process**
4. **Document checklist and approval notes**

Article principles:

- one clear user journey per article
- avoid duplicate English copy across languages
- include actionable fields (`market`, `quantity`, `delivery`, `delivery window`, `documents`)
- each article should invite an inquiry step at the end

## 8) Legal and trust language

- No claims beyond published evidence.
- Keep installation capability, certifications, and standards tied to exact model data.
- Avoid saying “we are ISO certified” unless current, verifiable page or evidence exists.

## 9) CMS operating guide

- Centralize all global content through CMS settings and series/product pages.
- Keep static texts in `messages/*` minimal and structural.
- All marketing campaigns should be tied to CMS settings for quick edits and rollback.

## 10) Release gate for global content

Before public release:

1. Content check: localized pages, featured cards, and home banners have valid text for each intended locale.
2. SEO check: canonical/alternate and `noindex` labels align with data confidence.
3. Editorial check: no untranslated placeholders in visible hero or cards.
4. QA check: mobile/desktop rendering for major locales (zh/en + one RTL/LTR representative if applicable).
5. Governance check: admin role/permission records for content editors are current.

This strategy is intentionally conservative on factual claims and permissive on presentation quality. The site should look international, but facts must remain auditable.
