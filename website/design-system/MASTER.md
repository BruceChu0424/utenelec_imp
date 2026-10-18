# Uten public website design system

The public website is a corporate product showroom. It supports product research,
company information, documents and direct contact with sales. It does not contain
a cart, selection basket, checkout, payment or shopping workflow.

Use `frontend-design` by default for public UI and design documentation. Preserve
Uten branding, source identity, publication controls and the website's languages.

## Visual direction

The visual reference is the product in an architectural space: a quiet wall,
precise product proportions and clear information. Product photography carries
the identity. Large scenes establish context; original low-resolution product
images remain at a restrained size. Generated room imagery represents a concept,
never a delivered project or a fabricated product.

| Role | Color |
|---|---|
| Main surface | `#FFFFFF` |
| Product stage | `#F3F5F4` |
| Main text | `#17292D` |
| Secondary text | `#657377` |
| Uten accent | `#0A707B` |
| Rules and controls | `#D7DFDF` |

Public tokens live under `.public-site`; admin pages retain their existing root
tokens. Do not change CMS contrast or layout to implement public-page styling.
Use the existing local system font stacks. Titles are restrained and readable;
body text is 16–18 px with generous line height. Avoid decorative all-caps labels,
continuous marquees, repeated gradient cards and animation on every section.

## Page structure

- Home: one product/space story, series discovery, a small featured product set,
  a published room preview and concrete routes to company, documents and sales.
- Catalog: family-first navigation and server-rendered, database-paginated
  product results. Filters and pages are URL state and work without JavaScript.
- Details: real product/gallery, reviewed attributes, a clearly separate legacy
  description, applicable published documents and a direct sales inquiry.
- Company, manufacturing, partners, resources and careers: editorial reading
  layouts with actual CMS content and clear next actions.
- News: real article dates, published content and readable long-form text.
- Cases: actual published records; concept room previews are not case studies.
- Contact: the server resolves stable product/variant/series IDs; the accepting
  action repeats authorization/publication checks before saving the inquiry.
- Privacy: explain the actual service and contact route, not prototype storage.

## Content and media

Family covers prefer published `SeriesMedia.role=combination`, then `coverImage`,
then a source-backed composition. Never turn navigation badges into covers.
Use `object-contain` for product images and preserve their proportions. Do not
fabricate materials, colors, stock, prices, certifications, ratings or dimensions.

`publicProductView` is the common card/detail/Studio boundary. Historical plain
text remains visible as historical material; it is not promoted into current
specifications or search snippets. Synthetic base variants are image fallbacks.
Reviewed dimensions/materials require the applicable product and variant review
states. Room preview additionally requires `sceneEnabled`; floor sockets do not
appear on a wall.

Files appear as downloads only through published resource records. File links
use the protected download endpoint and expose actual language/version/market
metadata. Missing documents lead to a sales request, not a fake download.

## Interaction and acceptance

Direct inquiries retain stable identity and a retry-stable submission key. A
successful submission shows the returned reference number and receipt status;
it never implies that a salesperson has already read or followed up.

Keep visible keyboard focus, 44 px touch targets, RTL support and reduced-motion
behavior. Check 375, 768, 1024 and 1440 px; long names, empty content, unavailable
records, form failures and published/unpublished changes are part of acceptance.
Verify all public page families and child routes, not just the homepage.
