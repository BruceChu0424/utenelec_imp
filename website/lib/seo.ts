import type { Metadata } from 'next';
import { routing } from '@/i18n/routing';
import { pickLocale } from '@/lib/content';

const FALLBACK_SITE_URL = 'https://www.ch-uten.com';
const HTTP_PROTOCOLS = new Set(['http:', 'https:']);

/** Languages with reviewed, directly maintained company/product content.
 * Other UI translations remain available to visitors but are intentionally
 * noindex until a market reviewer approves the full page content. */
export const REVIEWED_SITE_LOCALES = ['zh', 'en'] as const;

/**
 * Resolve the public origin without allowing a malformed SITE_URL to leak
 * credentials, paths, queries, or unsupported protocols into canonical URLs.
 */
export function getSiteUrl(): URL {
  const configured = process.env.SITE_URL?.trim();
  if (!configured) return new URL(FALLBACK_SITE_URL);

  try {
    const hasProtocol = /^[a-z][a-z\d+.-]*:\/\//i.test(configured);
    if (hasProtocol && !/^https?:\/\//i.test(configured)) return new URL(FALLBACK_SITE_URL);
    const candidate = new URL(hasProtocol ? configured : `https://${configured}`);
    if (!HTTP_PROTOCOLS.has(candidate.protocol) || candidate.username || candidate.password) {
      return new URL(FALLBACK_SITE_URL);
    }
    candidate.pathname = '/';
    candidate.search = '';
    candidate.hash = '';
    return candidate;
  } catch {
    return new URL(FALLBACK_SITE_URL);
  }
}

function normalizePath(path: string): string {
  if (!path || path === '/') return '';
  const withoutOrigin = path.replace(/^[a-z][a-z\d+.-]*:\/\/[^/]+/i, '');
  return `/${withoutOrigin.split(/[?#]/, 1)[0].replace(/^\/+|\/+$/g, '')}`;
}

export function localizedUrl(locale: string, path: string): string {
  const safeLocale = routing.locales.includes(locale as (typeof routing.locales)[number])
    ? locale
    : routing.defaultLocale;
  return new URL(`/${safeLocale}${normalizePath(path)}`, getSiteUrl()).toString();
}

function preferredLocale(locales: readonly string[]): string {
  if (locales.includes(routing.defaultLocale)) return routing.defaultLocale;
  if (locales.includes('zh')) return 'zh';
  return locales[0] || routing.defaultLocale;
}

export function localizedAlternates(
  locale: string,
  path: string,
  availableLocales: readonly string[] = routing.locales,
): NonNullable<Metadata['alternates']> {
  const uniqueLocales = routing.locales.filter((candidate) => availableLocales.includes(candidate));
  if (!uniqueLocales.length) return { canonical: localizedUrl(locale, path) };
  const canonicalLocale = uniqueLocales.includes(locale as (typeof routing.locales)[number])
    ? locale
    : preferredLocale(uniqueLocales);
  const languages = Object.fromEntries(uniqueLocales.map((candidate) => [candidate, localizedUrl(candidate, path)]));
  languages['x-default'] = localizedUrl(preferredLocale(uniqueLocales), path);

  return {
    canonical: localizedUrl(canonicalLocale, path),
    languages,
  };
}

type PageMetadataOptions = {
  locale: string;
  path: string;
  title: string;
  description?: string | null;
  availableLocales?: readonly string[];
  index?: boolean;
  absoluteTitle?: boolean;
  image?: string | null;
};

export function buildPageMetadata({
  locale,
  path,
  title,
  description,
  availableLocales = REVIEWED_SITE_LOCALES,
  index,
  absoluteTitle = false,
  image,
}: PageMetadataOptions): Metadata {
  const cleanTitle = title.trim();
  const cleanDescription = description?.replace(/\s+/g, ' ').trim() || undefined;
  const alternates = localizedAlternates(locale, path, availableLocales);
  const url = typeof alternates.canonical === 'string' ? alternates.canonical : localizedUrl(locale, path);

  return {
    title: absoluteTitle ? { absolute: cleanTitle } : cleanTitle,
    description: cleanDescription,
    alternates,
    robots: { index: index ?? availableLocales.includes(locale), follow: true },
    openGraph: {
      title: cleanTitle,
      description: cleanDescription,
      url,
      locale,
      type: 'website',
      ...(image ? { images: [image] } : {}),
    },
  };
}

export function directContentLocales<T extends Record<string, unknown>>(
  i18nField: string | null | undefined,
  isMeaningful: (content: T) => boolean,
): string[] {
  return routing.locales.filter((locale) => {
    const content = pickLocale<T>(i18nField, locale);
    return Boolean(content && isMeaningful(content));
  });
}

export function hasText(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0;
}
