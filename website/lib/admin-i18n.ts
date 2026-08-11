type JsonRecord = Record<string, unknown>;
type JsonArray = unknown[];

export type EditedLocale = JsonRecord | JsonArray | null;
export type ProductSpecItem = { label: string; value: string };

function isRecord(value: unknown): value is JsonRecord {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function parseI18n(value: string | null | undefined): JsonRecord {
  if (!value) return {};
  let parsed: unknown;
  try {
    parsed = JSON.parse(value);
  } catch {
    throw new Error('现有多语言内容不是有效的 JSON');
  }
  if (!isRecord(parsed)) throw new Error('现有多语言内容必须是按语言分组的对象');
  return parsed;
}

function parseProductSpecs(value: string | null | undefined): JsonRecord {
  if (!value) return {};

  let parsed: unknown;
  try {
    parsed = JSON.parse(value);
  } catch {
    throw new Error('产品规格不是有效的 JSON');
  }

  // The original site stored a locale-neutral array. Treat it as Chinese when
  // the CMS first edits it, while keeping the reader compatible with that data.
  if (Array.isArray(parsed)) return { zh: parsed };
  if (isRecord(parsed)) return parsed;
  throw new Error('产品规格必须是数组或按语言分组的对象');
}

function normalizedProductSpecs(value: unknown, locale: string): ProductSpecItem[] {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) throw new Error(`${locale} 产品规格必须是数组`);

  return value.map((item, index) => {
    if (!isRecord(item) || typeof item.label !== 'string' || typeof item.value !== 'string') {
      throw new Error(`${locale} 产品规格第 ${index + 1} 项缺少 label 或 value`);
    }
    return { label: item.label, value: item.value };
  });
}

function hasContent(value: unknown): boolean {
  if (typeof value === 'string') return value.trim().length > 0;
  if (Array.isArray(value)) return value.some(hasContent);
  if (isRecord(value)) return Object.values(value).some(hasContent);
  return value !== null && value !== undefined;
}

/**
 * Return a locale payload only when it contains real content. In particular,
 * a new record with an empty English form must not create an `en` locale that
 * only contains empty strings.
 */
export function localeOrMissing<T extends JsonRecord | JsonArray>(value: T): T | null {
  return hasContent(value) ? value : null;
}

/**
 * Read exactly one locale for an admin form. Unlike public fallbacks this is
 * strict: malformed stored JSON is surfaced so the form cannot overwrite it.
 */
export function readAdminI18nLocale<T = unknown>(
  existing: string | null | undefined,
  locale: string,
): T | null {
  const document = parseI18n(existing);
  if (!Object.prototype.hasOwnProperty.call(document, locale)) return null;
  const value = document[locale];
  return (value === null || value === undefined ? null : value) as T | null;
}

export function validateAdminText(
  value: unknown,
  label: string,
  maxLength: number,
  required = false,
): string {
  const text = String(value ?? '').trim();
  if (required && !text) throw new Error(`${label}不能为空`);
  if (text.length > maxLength) throw new Error(`${label}不能超过 ${maxLength} 个字符`);
  return text;
}

export function validateAdminEmail(value: unknown, label: string): string {
  const email = validateAdminText(value, label, 160);
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(email)) {
    throw new Error(`${label}格式不正确`);
  }
  return email;
}

export function validateAdminPhone(value: unknown, label: string): string {
  const phone = validateAdminText(value, label, 40);
  if (phone && !/^[+\d][\d\s().\-/]{4,39}$/u.test(phone)) {
    throw new Error(`${label}只能包含数字、空格及常用电话符号`);
  }
  return phone;
}

export function validateAdminPublicImagePath(value: unknown, label: string): string {
  const imagePath = validateAdminText(value, label, 500);
  if (!imagePath) return '';
  if (!/^\/(?:uploads|images)\/[^\s?#\\]+$/u.test(imagePath) || imagePath.split('/').includes('..')) {
    throw new Error(`${label}仅允许 /uploads/ 或 /images/ 下的站内图片路径`);
  }
  return imagePath;
}

/**
 * Merge the locales edited by the CMS into the latest stored JSON.
 *
 * - Locales not present in `edited` are preserved byte-for-value after JSON
 *   parsing (for example es/fr/de/ar translations).
 * - A locale object is shallow-merged so fields not exposed by the current
 *   form are retained.
 * - `null` explicitly removes a locale, which keeps an empty English section
 *   genuinely missing instead of manufacturing a Chinese pseudo-translation.
 */
export function mergeAdminI18n(
  existing: string | null | undefined,
  edited: Record<string, EditedLocale>,
): string {
  const merged = { ...parseI18n(existing) };

  for (const [locale, patch] of Object.entries(edited)) {
    if (patch === null) {
      delete merged[locale];
      continue;
    }

    if (Array.isArray(patch)) {
      merged[locale] = patch;
      continue;
    }

    const current = isRecord(merged[locale]) ? merged[locale] : {};
    merged[locale] = { ...current, ...patch };
  }

  return JSON.stringify(merged);
}

/**
 * Read one exact locale from Product.specs without falling back to another
 * locale. A legacy top-level array is interpreted as Chinese only.
 */
export function readAdminProductSpecs(
  existing: string | null | undefined,
  locale: string,
): ProductSpecItem[] {
  const document = parseProductSpecs(existing);
  return normalizedProductSpecs(document[locale], locale);
}

/**
 * Merge the locales edited by the product CMS into Product.specs.
 *
 * The canonical shape is `{ zh: [{label,value}], en: [...], ... }`. Locales
 * not represented in `edited` are preserved after JSON parsing, including
 * translations added outside this two-language form. `null` removes one
 * locale, while an empty document is stored as SQL null.
 */
export function mergeAdminProductSpecs(
  existing: string | null | undefined,
  edited: Record<string, ProductSpecItem[] | null>,
): string | null {
  const merged = { ...parseProductSpecs(existing) };

  for (const [locale, items] of Object.entries(edited)) {
    if (items === null || items.length === 0) {
      delete merged[locale];
      continue;
    }
    merged[locale] = normalizedProductSpecs(items, locale);
  }

  return Object.keys(merged).length ? JSON.stringify(merged) : null;
}
