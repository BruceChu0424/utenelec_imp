export function catalogProductRedirectTarget({
  locale,
  requestedFamily,
  canonicalFamily,
  productSlug,
  variant,
}: {
  locale: string;
  requestedFamily: string;
  canonicalFamily: string;
  productSlug: string;
  variant?: string;
}): string | null {
  if (requestedFamily === canonicalFamily) return null;
  const target = `/${locale}/products/${canonicalFamily}/${productSlug}`;
  return variant ? `${target}?variant=${encodeURIComponent(variant)}` : target;
}

export function catalogSeriesRedirectTarget({
  locale,
  requestedFamily,
  canonicalFamily,
  query = '',
}: {
  locale: string;
  requestedFamily: string;
  canonicalFamily: string;
  query?: string;
}): string | null {
  if (requestedFamily === canonicalFamily) return null;
  return `/${locale}/products/${canonicalFamily}${query}`;
}
