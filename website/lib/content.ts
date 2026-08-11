import { routing } from '@/i18n/routing';

export const LOCALES = routing.locales as readonly string[];
export const DEFAULT_LOCALE = routing.defaultLocale;

export { formatDate } from './utils';

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

/** Merge localized content without allowing empty translated fields to erase useful fallbacks. */
function mergeContent(base: unknown, overlay: unknown): unknown {
  if (overlay === null || overlay === undefined || overlay === '') return base;
  if (Array.isArray(overlay)) return overlay.length ? overlay : base;
  if (isRecord(base) && isRecord(overlay)) {
    const merged: Record<string, unknown> = { ...base };
    for (const [key, value] of Object.entries(overlay)) merged[key] = mergeContent(merged[key], value);
    return merged;
  }
  return overlay;
}

/**
 * Resolve an i18n JSON field. Chinese is the source fallback; all other
 * locales layer English over Chinese and then the requested locale over both.
 * This operates per field, so an empty translated description cannot blank a
 * valid source description.
 */
export function pick<T = Record<string, unknown>>(
  i18nField: string | null | undefined,
  locale: string,
): T | null {
  if (!i18nField) return null;
  try {
    const parsed: unknown = JSON.parse(i18nField);
    if (!isRecord(parsed)) return parsed as T;

    const first = Object.values(parsed).find((value) => value !== null && value !== undefined);
    let resolved = mergeContent(first, parsed.zh);
    if (locale !== 'zh') resolved = mergeContent(resolved, parsed.en);
    resolved = mergeContent(resolved, parsed[locale]);
    return (resolved ?? null) as T | null;
  } catch {
    return null;
  }
}

/**
 * Read only the requested locale from a localized JSON field. This is useful
 * when the caller has a fully translated UI fallback and must not silently
 * replace it with a different language from the CMS.
 */
export function pickLocale<T = Record<string, unknown>>(
  i18nField: string | null | undefined,
  locale: string,
): T | null {
  if (!i18nField) return null;
  try {
    const parsed: unknown = JSON.parse(i18nField);
    if (!isRecord(parsed) || !Object.prototype.hasOwnProperty.call(parsed, locale)) return null;
    const value = parsed[locale];
    return (value === null || value === undefined ? null : value) as T | null;
  } catch {
    return null;
  }
}

export function tr<T = Record<string, unknown>>(i18nField: string | null | undefined, locale: string): T {
  return (pick<T>(i18nField, locale) ?? {}) as T;
}

type SeriesForLabel = {
  i18n: string | null;
  sourceIdentity?: string | null;
  parent?: { i18n: string | null } | null;
};

/**
 * The legacy site truncates many Chinese leaf labels in its own HTML (for
 * example "大跷板&…") and contains several English typos. Normalize those
 * presentation labels without changing the immutable source/audit records.
 */
export function seriesDisplayName(series: SeriesForLabel, locale: string): string {
  const localized = tr<{ name?: string }>(series.i18n, locale).name?.trim() || '';
  const english = pickLocale<{ name?: string }>(series.i18n, 'en')?.name?.trim() || '';
  const key = english.toLocaleLowerCase();
  const isChinese = locale === 'zh';
  let leaf = localized;

  if (/rocker switch|big button switch/.test(key)) leaf = isChinese ? '大跷板开关' : 'Rocker switch';
  else if (/mirco-point|micro-point/.test(key)) leaf = isChinese ? 'LED 微点开关' : 'LED micro-point switch';
  else if (/electroic electronic|electronic swotcj|universal electronic socket/.test(key)) leaf = isChinese ? '通用开关插座' : 'Universal switch & socket';
  else if (/function parts of electric switch socket/.test(key)) leaf = isChinese ? '开关插座功能件' : 'Switch & socket modules';
  else if (/function parts of electric socket/.test(key)) leaf = isChinese ? '插座功能件' : 'Socket modules';
  else if (/flat screen siwtch/.test(key)) leaf = isChinese ? '纯平开关' : 'Flat-panel switch';
  else if (/export product/.test(key)) leaf = isChinese ? '出口产品' : 'Export products';
  else if (/[&…\u0980]/u.test(leaf)) {
    const sourceId = series.sourceIdentity?.split(':').pop();
    leaf = isChinese ? (sourceId === '53' ? '其他产品' : '产品系列') : (english || 'Product series');
  }

  const parent = series.parent
    ? tr<{ name?: string }>(series.parent.i18n, locale).name?.trim()
    : '';
  return parent && parent !== leaf ? `${parent} · ${leaf}` : (leaf || parent || 'UTEN');
}

export function trArr<T = unknown>(i18nField: string | null | undefined, locale: string, fallback: T[] = []): T[] {
  const value = pick<T[]>(i18nField, locale);
  return Array.isArray(value) ? value : fallback;
}

/**
 * Remove navigation, breadcrumb and editor chrome accidentally captured from
 * legacy news pages. The raw import stays untouched for audit purposes; this
 * sanitizer is only used at the public rendering boundary.
 */
export function cleanLegacyArticleText(text: string | null | undefined, title?: string): string {
  if (!text) return '';
  let cleaned = text.replace(/\u00a0/g, ' ').replace(/\r\n?/g, '\n').trim();

  const hasLegacyChrome = /中文\s*\|\s*ENGLISH|COMPANY NEWS|INDUSTRY NEWS|首页\s*\|\s*新闻资讯/i.test(cleaned);
  if (hasLegacyChrome && title) {
    const repeatedTitle = cleaned.indexOf(title, Math.max(1, cleaned.indexOf(title) + title.length));
    if (repeatedTitle >= 0) cleaned = cleaned.slice(repeatedTitle + title.length);
  }

  cleaned = cleaned
    .replace(/^\s*编辑[：:]\s*.*?\s+时间[：:]\s*\d{1,2}\/\d{1,2}\/\d{4}\s+\d{1,2}:\d{2}(?::\d{2})?\s*(?:AM|PM)?\s*/i, '')
    .replace(/^[『』\s]+|[『』\s]+$/g, '')
    .replace(/[ \t]{2,}/g, ' ')
    .replace(/\n{3,}/g, '\n\n')
    .trim();

  return cleaned;
}

export function articleParagraphs(text: string | null | undefined, title?: string): string[] {
  const cleaned = cleanLegacyArticleText(text, title);
  if (!cleaned) return [];

  const explicit = cleaned.split(/\n+/).map((part) => part.trim()).filter(Boolean);
  if (explicit.length > 1) return explicit;

  const sentences = cleaned.match(/[^。！？!?；;]+[。！？!?；;]?/g)?.map((part) => part.trim()).filter(Boolean) ?? [cleaned];
  const paragraphs: string[] = [];
  let current = '';
  for (const sentence of sentences) {
    if (current && current.length + sentence.length > 180) {
      paragraphs.push(current);
      current = sentence;
    } else {
      current += sentence;
    }
  }
  if (current) paragraphs.push(current);
  return paragraphs;
}

export function articleExcerpt(
  summary: string | null | undefined,
  content: string | null | undefined,
  title?: string,
  maxLength = 160,
): string {
  const cleanSummary = cleanLegacyArticleText(summary, title);
  const source = /中文\s*\|\s*ENGLISH|联系我们\s*人才招聘|COMPANY NEWS/i.test(cleanSummary)
    ? cleanLegacyArticleText(content, title)
    : (cleanSummary || cleanLegacyArticleText(content, title));
  if (source.length <= maxLength) return source;
  return `${source.slice(0, maxLength).replace(/[，、；;\s]+$/u, '')}…`;
}

const LEGACY_COMPANY_ACTIVITY_SLUGS = new Set([
  'rongqiao-jincheng-project',
  'quanzhou-dealer-conference',
  'chongqing-shantou-tour',
]);

/** Unverified legacy company/project records kept only in the public archive,
 * never presented as current reference projects. */
export function isLegacyCompanyActivity(slug: string): boolean {
  return LEGACY_COMPANY_ACTIVITY_SLUGS.has(slug);
}
