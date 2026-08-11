# Homepage Apple-style Content Specification (Website CMS Contract)

This document describes the homepage and navigation contract for the public site.

## 1. Homepage intent

The homepage should behave as a premium showroom, not a full catalog dump.

- Hero introduces the category family strategy in one clear story.
- Navigation priority is:
  - Series discovery (`/products`)
  - Featured latest products section
  - Studio / project style preview
  - Trust and inquiry entry

## 2. Layout model

### Desktop

- Two-column presentation on the first screen:
  - Left: headline + supporting value statements + primary CTAs
  - Right: full-height product/family scene visual
- Keep negative space in both columns; avoid text crowding at 1024–1400.

### Mobile

- Stacked layout
- One media hero first, then short blocks in order above the fold
- Keep one primary action per block for conversion clarity

## 3. “Latest products only” rule

- Homepage product zone must show only:
  - products/entries explicitly marked for homepage priority, or
  - latest-published fallback when no explicit selection exists.
- No automatic full catalog display on the first screen.
- Hard cap: 6–12 cards shown on first load.
- Add progressive exploration (`Load more` / filtered entry points), do not expose all items at once.

## 4. Family-first navigation

- Homepage calls must link to families (`/products/<familySlug>`), not legacy internal codes.
- Product cards should avoid showing family and product as flat identical rows.
- Each family card should include:
  - short family tag
  - 1 hero image
  - one-line positioning line
  - one explicit CTA

## 5. Series/collection image policy

For each family cover image:

1. Use `SeriesMedia.role=combination` when available
2. Fallback to `coverImage`
3. Fallback to CMS-generated curated collage

Do not use “navigation badge” or unrelated category banners as cover visuals.

## 6. Content quality rules

- Keep all claims data-aligned.
- If a statement is only `INFERRED`/`NEEDS_REVIEW`, mark as non-guaranteed copy.
- Do not mention price, MOQ, shipping, or certification data that is not in verified fields.
- Any non-verified multilingual content should be:
  - temporarily hidden in production search-sensitive placements, or
  - explicitly marked and localized as secondary supporting copy.

## 7. Navigation contract

The header must always expose:

- Home
- Products
- Cases/Projects (if applicable)
- News
- Contacts
- Join/Cooperation

Locale switch must keep route consistency (e.g. `/zh`, `/en`) and render correctly under current locale context.

## 8. Visual QA checkpoints

- Max first-screen height: stable with no abrupt jump from image decoding
- Typography:
  - no ultra-dense title collision
  - mobile readable size and line-height
- Cards:
  - no oversized single image blow-up
  - image rendered within natural scale
- Accessibility:
  - keyboard focus visible
  - contrast for essential text meets AA threshold

## 9. Release acceptance (homepage/doc only)

- CMS has at least one validated family highlight for homepage
- Latest section points to manually selected/high-confidence records
- Home route and one language sample pass smoke run
- No dead links in top 20 CTA targets
- SEO metadata and alternate links updated for locale routing
