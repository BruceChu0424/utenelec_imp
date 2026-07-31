import { routing } from '@/i18n/routing';

export const LOCALES = routing.locales as readonly string[];
export const DEFAULT_LOCALE = routing.defaultLocale;

export { formatDate } from './utils';

/**
 * 从 i18n JSON 字段取指定语言的内容, 缺失时回退到默认语言, 再回退到首个可用语言。
 * i18n 字段结构: { zh: {...}, en: {...}, ... }
 */
export function pick<T = Record<string, unknown>>(
  i18nField: string | null | undefined,
  locale: string,
  fallback = DEFAULT_LOCALE,
): T | null {
  if (!i18nField) return null;
  try {
    const obj = JSON.parse(i18nField);
    if (obj && typeof obj === 'object' && !Array.isArray(obj)) {
      return (obj[locale] ?? obj[fallback] ?? Object.values(obj)[0] ?? null) as T;
    }
    return obj as T;
  } catch {
    return null;
  }
}

/** 取翻译对象 (永远返回对象, 便于解构) */
export function tr<T = Record<string, unknown>>(i18nField: string | null | undefined, locale: string): T {
  return (pick<T>(i18nField, locale) ?? {}) as T;
}

/** 取数组型 i18n (如 stats / craft / advantages) */
export function trArr<T = unknown>(i18nField: string | null | undefined, locale: string, fallback: T[] = []): T[] {
  const v = pick<T[]>(i18nField, locale);
  return Array.isArray(v) ? v : fallback;
}
