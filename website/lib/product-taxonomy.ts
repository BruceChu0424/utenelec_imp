/**
 * Stable catalog vocabulary shared by the public catalog, CMS and migration
 * tooling. Legacy source categories remain untouched; these fields describe
 * how a product should be presented after an editor has reviewed it.
 */

export const PRODUCT_FUNCTION_TYPES = [
  'switches',
  'power-sockets',
  'usb-charging',
  'data-media',
  'smart-controls',
  'hospitality',
  'accessories',
  'other',
] as const;

export type ProductFunctionType = (typeof PRODUCT_FUNCTION_TYPES)[number];

export const SERIES_CATALOG_ROLES = [
  'FAMILY',
  'COLLECTION',
  'CONTAINER',
  'ARCHIVE',
  'UNCLASSIFIED',
] as const;

export type SeriesCatalogRole = (typeof SERIES_CATALOG_ROLES)[number];

export const PRODUCT_CLASSIFICATION_STATUSES = [
  'VERIFIED',
  'INFERRED',
  'NEEDS_REVIEW',
] as const;

export type ProductClassificationStatus = (typeof PRODUCT_CLASSIFICATION_STATUSES)[number];

export type InferredProductTaxonomy = {
  functionType: ProductFunctionType;
  gangCount: number | null;
  controlMode: string | null;
  status: ProductClassificationStatus;
};

const includesAny = (value: string, words: readonly string[]) =>
  words.some((word) => value.includes(word));

/**
 * Produces a review candidate only. It must never be used to merge products,
 * create SKUs, invent electrical ratings or mark imported data as verified.
 */
export function inferProductTaxonomy(
  localizedNames: Array<string | null | undefined>,
  legacyCollectionNames: Array<string | null | undefined> = [],
): InferredProductTaxonomy {
  const value = [...localizedNames, ...legacyCollectionNames]
    .filter((item): item is string => Boolean(item?.trim()))
    .join(' ')
    .normalize('NFKC')
    .toLocaleLowerCase();

  let functionType: ProductFunctionType = 'other';
  if (includesAny(value, ['请勿打扰', '请即清理', '插卡取电', '门铃', '剃须刀插', 'sos', 'insert card', 'door bell', 'do not disturb', 'please clean', 'shaver socket'])) {
    functionType = 'hospitality';
  } else if (includesAny(value, ['感应', '调光', '调速', '声光', '延时', '触摸', '风量', '定时', 'sensor', 'motion', 'dimmer', 'speed', 'delay', 'airflow', 'touch'])) {
    functionType = 'smart-controls';
  } else if (includesAny(value, ['电视', '电脑', '电话', '音响', '卫星', 'tv socket', 'computer socket', 'telephone', 'data socket', 'network', 'rj45', 'speaker', 'audio socket'])) {
    functionType = 'data-media';
  } else if (includesAny(value, ['usb', 'type-c', 'type c', 'charging'])) {
    functionType = 'usb-charging';
  } else if (includesAny(value, ['插座', '二极', '三极', '三孔', '五孔', '七孔', 'socket', 'receptacle'])) {
    functionType = 'power-sockets';
  } else if (includesAny(value, [
    '开关', '跷板', '一开', '二开', '三开', '四开', '五开', '六开',
    '单控', '双控', '多控', '中途', 'rocker', 'switch',
  ])) {
    functionType = 'switches';
  } else if (includesAny(value, ['空白', '线盒', '脚灯', '地脚灯', '面板', 'blank', 'junction box', 'foot light', 'panel'])) {
    functionType = 'accessories';
  }

  const gangPatterns: Array<[number, RegExp]> = [
    [6, /(?:六开|六位|6\s*(?:gang|way))/i],
    [5, /(?:五开|五位|5\s*(?:gang|way))/i],
    [4, /(?:四开|四位|4\s*(?:gang|way))/i],
    [3, /(?:三开|三位|3\s*(?:gang|way))/i],
    [2, /(?:二开|二位|双开|2\s*(?:gang|way))/i],
    [1, /(?:一开|一位|单开|1\s*(?:gang|way)|single\s+(?:gang|switch))/i],
  ];
  const gangCount = gangPatterns.find(([, pattern]) => pattern.test(value))?.[0] ?? null;

  let controlMode: string | null = null;
  if (includesAny(value, ['中途', '中间', 'intermediate', 'intermedia'])) controlMode = 'INTERMEDIATE';
  else if (includesAny(value, ['多控', 'multi-way', 'multiway'])) controlMode = 'MULTIWAY';
  else if (includesAny(value, ['双控', 'two-way', '2 way'])) controlMode = 'TWO_WAY';
  else if (includesAny(value, ['单控', 'one-way', '1 way'])) controlMode = 'ONE_WAY';

  return {
    functionType,
    gangCount,
    controlMode,
    status: functionType === 'other' ? 'NEEDS_REVIEW' : 'INFERRED',
  };
}

export function isProductFunctionType(value: unknown): value is ProductFunctionType {
  return typeof value === 'string' && (PRODUCT_FUNCTION_TYPES as readonly string[]).includes(value);
}

export function isSeriesCatalogRole(value: unknown): value is SeriesCatalogRole {
  return typeof value === 'string' && (SERIES_CATALOG_ROLES as readonly string[]).includes(value);
}

export function isProductClassificationStatus(value: unknown): value is ProductClassificationStatus {
  return typeof value === 'string' && (PRODUCT_CLASSIFICATION_STATUSES as readonly string[]).includes(value);
}

export function normalizedPublicSlug(value: string): string {
  return value
    .normalize('NFKD')
    .toLocaleLowerCase()
    .replace(/白/g, '-white')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .replace(/-{2,}/g, '-')
    .slice(0, 80);
}
