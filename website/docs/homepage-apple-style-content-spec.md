# Homepage and public navigation contract

The filename is retained for existing links. The current direction is the Uten
product showroom documented in `../design-system/MASTER.md`, developed using
`frontend-design`. The public site is a corporate showcase with direct sales
contact. No cart, shopping list, checkout or payment interaction is permitted.

## Homepage

Use one calm image/text composition with a real product and an explicitly
conceptual room image where appropriate. Keep original product images at a
natural size. `hero` settings retain title/subtitle/CTA fields and may provide a
site-local space-background `heroImage` and published `heroSeriesId`. Both media fields are shared under the Chinese settings entry; text remains localized. A source-backed product from the chosen series is layered over the space background. A selected family must never
be labeled over another family's product image.

Show a small featured set; `featured`, `sortOrder` and creation time are editorial
selection inputs, not proof that an imported product is newly launched. Do not
infer launch dates from import timestamps. The complete catalog is reached via
family pages with server-rendered database pagination.

Series cover precedence is published combination media, explicit cover image,
then real source-linked product composition. Legacy descriptions are retained
on product detail pages as historical information. They do not become verified
current specifications or homepage claims.

## Navigation

The desktop header exposes products, room preview, manufacturing/quality,
company and news, plus language selection and contact. The logo returns home.
The footer and mobile navigation expose partners, resources, cases, careers and
privacy as well. All links preserve locale. Catalog filters and pagination are
encoded in the URL, including when following an old family alias.

Header, footer and sitemap use the lightweight catalog navigation projection;
they do not load product image pools. Public publication state is read at request
time. Do not add caches that keep an unpublished record publicly available.

## Verification

Check each public page family, a real series, multiple catalog pages, a product
with historical description, an applicable document, and direct inquiry receipt.
Test mobile layout, long names, keyboard navigation, reduced motion, RTL,
unpublished parents, unknown IDs and failure/retry behavior. Source tests and a
local preview are not production deployment or external delivery evidence.
