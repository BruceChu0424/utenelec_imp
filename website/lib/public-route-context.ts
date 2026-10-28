import { routing } from '@/i18n/routing';

/** Request-only context, rebuilt from the actual URL by the Node proxy. */
export const PUBLIC_CASE_SLUG_HEADER = 'x-uten-public-case-slug';
export const PUBLIC_ROUTE_LOCALE_HEADER = 'x-uten-public-route-locale';

export function publicLocaleForPathname(pathname: string): (typeof routing.locales)[number] {
  const candidate = pathname.split('/')[1];
  return routing.locales.includes(candidate as (typeof routing.locales)[number])
    ? candidate as (typeof routing.locales)[number] : routing.defaultLocale;
}

export function caseSlugForPathname(pathname: string): string | null {
  const match = pathname.match(/^\/([^/]+)\/cases\/([^/]+)\/?$/u);
  if (!match || !routing.locales.includes(match[1] as (typeof routing.locales)[number])) return null;
  try { return decodeURIComponent(match[2]); }
  catch { return ''; }
}
