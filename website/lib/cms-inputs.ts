import {
  localeOrMissing,
  mergeAdminI18n,
  mergeAdminProductSpecs,
  readAdminI18nLocale,
  validateAdminEmail,
  validateAdminPhone,
  validateAdminPublicImagePath,
  validateAdminText,
  type ProductSpecItem,
} from '@/lib/admin-i18n';
import {
  PRODUCT_CLASSIFICATION_STATUSES,
  PRODUCT_FUNCTION_TYPES,
  SERIES_CATALOG_ROLES,
  isProductClassificationStatus,
  isProductFunctionType,
  isSeriesCatalogRole,
} from '@/lib/product-taxonomy';

// Shared pure form parsing. Public tables are mutated only by the revision publisher.
export class FormValidationError extends Error {}

export const PRODUCT_CONTROL_MODES = ['ONE_WAY', 'TWO_WAY', 'MULTIWAY', 'INTERMEDIATE'] as const;
export const SERIES_MEDIA_ROLES = ['hero', 'lineup', 'lifestyle', 'combination', 'detail'] as const;

export function cleanText(value: FormDataEntryValue | null, maxLength = 500): string {
  return String(value || '').trim().slice(0, maxLength);
}

export function strictText(value: FormDataEntryValue | null, label: string, maxLength: number): string {
  const text = String(value || '').trim();
  if (text.length > maxLength) throw new FormValidationError(`${label}不能超过 ${maxLength} 个字符`);
  return text;
}

export function expectedRowVersion(value: FormDataEntryValue | null, label: string): number {
  const raw = strictText(value, label, 20);
  if (!raw || !/^\d+$/.test(raw) || Number(raw) < 1 || !Number.isSafeInteger(Number(raw))) {
    throw new FormValidationError(`${label}无效，请刷新页面后重试`);
  }
  return Number(raw);
}

export function isSafePublicImagePath(value: string): boolean {
  return /^\/(?:uploads|images)\/[^\s?#\\]+$/u.test(value)
    && !value.split('/').includes('..');
}

export function optionalImagePath(value: FormDataEntryValue | null, label: string): string | null {
  const imagePath = cleanText(value, 500);
  if (!imagePath) return null;
  if (!isSafePublicImagePath(imagePath)) {
    throw new FormValidationError(`${label}仅允许 /uploads/ 或 /images/ 下的站内图片路径`);
  }
  return imagePath;
}

export function optionalNumber(
  value: FormDataEntryValue | null,
  label: string,
  options: { min?: number; max?: number; integer?: boolean } = {},
): number | null {
  const raw = cleanText(value, 50);
  if (!raw) return null;
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || (options.integer && !Number.isInteger(parsed))) {
    throw new FormValidationError(`${label}必须是${options.integer ? '整数' : '数字'}`);
  }
  if (options.min !== undefined && parsed < options.min) {
    throw new FormValidationError(`${label}不能小于 ${options.min}`);
  }
  if (options.max !== undefined && parsed > options.max) {
    throw new FormValidationError(`${label}不能大于 ${options.max}`);
  }
  return parsed;
}

export function requiredInteger(value: FormDataEntryValue | null, label: string, min = 0): number {
  return optionalNumber(value, label, { min, integer: true }) ?? min;
}

export function galleryJson(value: FormDataEntryValue | null): string {
  const raw = String(value || '').trim();
  if (!raw) return JSON.stringify([]);
  let paths: string[];
  if (raw.startsWith('[')) {
    try {
      const parsed = JSON.parse(raw) as unknown;
      if (!Array.isArray(parsed) || parsed.some((item) => typeof item !== 'string')) {
        throw new Error('invalid');
      }
      paths = parsed;
    } catch {
      throw new FormValidationError('款式图集格式不正确，请每行填写一个图片路径');
    }
  } else {
    paths = raw.split(/\r?\n/);
  }
  return JSON.stringify([
    ...new Set(paths.map((item) => optionalImagePath(item, '款式图集')).filter((item): item is string => Boolean(item))),
  ]);
}

export function parseProductSpecLocale(
  formData: FormData,
  locale: 'zh' | 'en',
  localeLabel: string,
): ProductSpecItem[] {
  const labels = formData.getAll(`spec_${locale}_label`);
  const values = formData.getAll(`spec_${locale}_value`);
  if (labels.length !== values.length) {
    throw new FormValidationError(`${localeLabel}规格数据不完整，请刷新页面后重试`);
  }
  if (labels.length > 40) throw new FormValidationError(`${localeLabel}规格最多填写 40 项`);

  const specs: ProductSpecItem[] = [];
  for (let index = 0; index < labels.length; index += 1) {
    const rawLabel = String(labels[index] || '').trim();
    const rawValue = String(values[index] || '').trim();
    if (!rawLabel && !rawValue) continue;
    if (!rawLabel || !rawValue) {
      throw new FormValidationError(`${localeLabel}第 ${index + 1} 项规格必须同时填写参数名称和值`);
    }
    if (rawLabel.length > 120) {
      throw new FormValidationError(`${localeLabel}第 ${index + 1} 项规格名称不能超过 120 个字符`);
    }
    if (rawValue.length > 500) {
      throw new FormValidationError(`${localeLabel}第 ${index + 1} 项规格值不能超过 500 个字符`);
    }
    specs.push({ label: rawLabel, value: rawValue });
  }

  const duplicate = specs.find((spec, index) => (
    specs.findIndex((item) => item.label.toLocaleLowerCase() === spec.label.toLocaleLowerCase()) !== index
  ));
  if (duplicate) throw new FormValidationError(`${localeLabel}规格名称“${duplicate.label}”重复`);
  return specs;
}

export function productSpecsJson(
  existing: string | null | undefined,
  zh: ProductSpecItem[],
  en: ProductSpecItem[],
): string | null {
  try {
    return mergeAdminProductSpecs(existing, {
      zh: zh.length ? zh : null,
      en: en.length ? en : null,
    });
  } catch {
    throw new FormValidationError('现有产品规格 JSON 格式异常；为避免丢失数据，本次未保存，请先核对原始记录');
  }
}

export type ProductVariantInput = {
  id: string | null;
  sku: string | null;
  zhName: string;
  enName: string;
  swatchHex: string | null;
  image: string | null;
  gallery: string;
  finish: string | null;
  widthMm: number | null;
  heightMm: number | null;
  depthMm: number | null;
  legacySynthetic: boolean;
  dataStatus: (typeof PRODUCT_CLASSIFICATION_STATUSES)[number];
  isDefault: boolean;
  published: boolean;
  sortOrder: number;
};

export function parseProductVariants(formData: FormData): ProductVariantInput[] {
  const keys = formData.getAll('variantKey').map((value) => cleanText(value, 80));
  const defaultVariantKey = cleanText(formData.get('defaultVariantKey'), 80);
  if (!keys.length) throw new FormValidationError('请至少保留一个产品款式');
  if (new Set(keys).size !== keys.length || keys.some((key) => !/^[a-zA-Z0-9_-]+$/.test(key))) {
    throw new FormValidationError('产品款式数据无效，请刷新页面后重试');
  }
  if (defaultVariantKey && !keys.includes(defaultVariantKey)) {
    throw new FormValidationError('默认款式数据无效，请刷新页面后重试');
  }

  const variants = keys.map((key, index) => {
    const field = (name: string) => formData.get(`variant_${key}_${name}`);
    const zhName = cleanText(field('zh_name'), 120);
    const enName = cleanText(field('en_name'), 120);
    if (!zhName) throw new FormValidationError(`第 ${index + 1} 个款式缺少中文名称`);

    const swatchHex = cleanText(field('swatchHex'), 20) || null;
    if (swatchHex && !/^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/.test(swatchHex)) {
      throw new FormValidationError(`第 ${index + 1} 个款式的色卡必须是 #RGB 或 #RRGGBB`);
    }

    const sku = strictText(field('sku'), `第 ${index + 1} 个款式的 SKU`, 120) || null;
    const legacySynthetic = field('legacySynthetic') === 'on';
    const dataStatusValue = strictText(field('dataStatus'), `第 ${index + 1} 个款式的数据状态`, 40) || 'NEEDS_REVIEW';
    if (!isProductClassificationStatus(dataStatusValue)) {
      throw new FormValidationError(`第 ${index + 1} 个款式的数据状态无效`);
    }
    if (legacySynthetic && sku) {
      throw new FormValidationError(`第 ${index + 1} 个款式是旧站合成占位，不得填写或伪装真实 SKU`);
    }
    if (legacySynthetic && dataStatusValue === 'VERIFIED') {
      throw new FormValidationError(`第 ${index + 1} 个款式是旧站合成占位，不能标记为已核实`);
    }

    return {
      id: cleanText(field('id'), 80) || null,
      sku,
      zhName,
      enName,
      swatchHex,
      image: optionalImagePath(field('image'), `第 ${index + 1} 个款式的正面图`),
      gallery: galleryJson(field('gallery')),
      finish: cleanText(field('finish'), 160) || null,
      widthMm: optionalNumber(field('widthMm'), `第 ${index + 1} 个款式的宽度`, { min: 0.1 }),
      heightMm: optionalNumber(field('heightMm'), `第 ${index + 1} 个款式的高度`, { min: 0.1 }),
      depthMm: optionalNumber(field('depthMm'), `第 ${index + 1} 个款式的厚度`, { min: 0.1 }),
      legacySynthetic,
      dataStatus: dataStatusValue,
      isDefault: defaultVariantKey === key,
      published: field('published') === 'on',
      sortOrder: requiredInteger(field('sortOrder'), `第 ${index + 1} 个款式的排序`),
    };
  });

  const defaultCount = variants.filter((variant) => variant.isDefault).length;
  if (defaultCount > 1) throw new FormValidationError('每个产品最多只能有一个默认款式');
  const seenSkus = new Set<string>();
  for (const variant of variants) {
    if (!variant.sku) continue;
    const key = variant.sku.normalize('NFKC').toLocaleLowerCase();
    if (seenSkus.has(key)) throw new FormValidationError(`SKU“${variant.sku}”在本产品中重复`);
    seenSkus.add(key);
  }
  return variants;
}

export function productVariantData(variant: ProductVariantInput, existingI18n?: string | null) {
  const { id: _id, zhName, enName, ...data } = variant;
  return {
    ...data,
    i18n: mergeAdminI18n(existingI18n, {
      zh: { name: zhName },
      en: localeOrMissing({ name: enName }),
    }),
  };
}


export type SeriesMediaInput = {
  id: string | null;
  role: (typeof SERIES_MEDIA_ROLES)[number];
  image: string;
  zhAlt: string;
  enAlt: string;
  sortOrder: number;
  published: boolean;
};

export function parseSeriesMedia(formData: FormData): SeriesMediaInput[] {
  const keys = formData.getAll('seriesMediaKey').map((value) => cleanText(value, 80));
  if (keys.length > 30) throw new FormValidationError('每个系列最多维护 30 张展示素材');
  if (new Set(keys).size !== keys.length || keys.some((key) => !/^[a-zA-Z0-9_-]+$/.test(key))) {
    throw new FormValidationError('系列素材数据无效，请刷新页面后重试');
  }
  return keys.map((key, index) => {
    const field = (name: string) => formData.get(`seriesMedia_${key}_${name}`);
    const role = strictText(field('role'), `第 ${index + 1} 张系列素材的角色`, 40);
    if (!(SERIES_MEDIA_ROLES as readonly string[]).includes(role)) {
      throw new FormValidationError(`第 ${index + 1} 张系列素材的角色无效`);
    }
    const image = optionalImagePath(field('image'), `第 ${index + 1} 张系列素材`) ?? '';
    if (!image) throw new FormValidationError(`第 ${index + 1} 张系列素材缺少图片`);
    return {
      id: cleanText(field('id'), 80) || null,
      role: role as SeriesMediaInput['role'],
      image,
      zhAlt: strictText(field('zh_alt'), `第 ${index + 1} 张系列素材的中文替代文字`, 240),
      enAlt: strictText(field('en_alt'), `第 ${index + 1} 张系列素材的英文替代文字`, 240),
      sortOrder: requiredInteger(field('sortOrder'), `第 ${index + 1} 张系列素材的排序`),
      published: field('published') === 'on',
    };
  });
}

export function seriesMediaData(media: SeriesMediaInput, existingI18n?: string | null) {
  return {
    role: media.role,
    image: media.image,
    sortOrder: media.sortOrder,
    published: media.published,
    i18n: mergeAdminI18n(existingI18n, {
      zh: localeOrMissing({ alt: media.zhAlt }),
      en: localeOrMissing({ alt: media.enAlt }),
    }),
  };
}


export const SITE_SETTING_KEYS = ['hero', 'contact', 'about', 'stats', 'craft', 'join', 'capabilities', 'partners', 'resources', 'careers', 'footer'] as const;
export type SiteSettingKey = (typeof SITE_SETTING_KEYS)[number];
export type SettingItem = Record<string, string>;

export function isSettingKey(value: string): value is SiteSettingKey {
  return (SITE_SETTING_KEYS as readonly string[]).includes(value);
}

export function settingText(
  formData: FormData,
  name: string,
  label: string,
  maxLength: number,
  required = false,
): string {
  try {
    return validateAdminText(formData.get(name), label, maxLength, required);
  } catch (error) {
    throw new FormValidationError(error instanceof Error ? error.message : `${label}格式不正确`);
  }
}

export function settingPhone(formData: FormData, name: string, label: string): string {
  try {
    return validateAdminPhone(formData.get(name), label);
  } catch (error) {
    throw new FormValidationError(error instanceof Error ? error.message : `${label}格式不正确`);
  }
}

export function settingEmail(formData: FormData, name: string, label: string): string {
  try {
    return validateAdminEmail(formData.get(name), label);
  } catch (error) {
    throw new FormValidationError(error instanceof Error ? error.message : `${label}格式不正确`);
  }
}

export function settingImage(formData: FormData, name: string, label: string): string {
  try {
    return validateAdminPublicImagePath(formData.get(name), label);
  } catch (error) {
    throw new FormValidationError(error instanceof Error ? error.message : `${label}格式不正确`);
  }
}

export function settingRows(
  formData: FormData,
  locale: 'zh' | 'en',
  group: 'stats' | 'craft',
  fields: readonly { name: string; label: string; maxLength: number }[],
): SettingItem[] {
  const columns = fields.map((field) => formData.getAll(`${locale}_${group}_${field.name}`));
  const rowCount = columns[0]?.length ?? 0;
  if (columns.some((column) => column.length !== rowCount)) {
    throw new FormValidationError(`${locale === 'zh' ? '中文' : '英文'}列表数据不完整，请刷新页面后重试`);
  }
  if (rowCount > 16) throw new FormValidationError(`${locale === 'zh' ? '中文' : '英文'}列表最多 16 项`);

  const rows: SettingItem[] = [];
  for (let index = 0; index < rowCount; index += 1) {
    const values = fields.map((field, fieldIndex) => {
      try {
        return validateAdminText(columns[fieldIndex][index], field.label, field.maxLength);
      } catch (error) {
        throw new FormValidationError(error instanceof Error ? error.message : `${field.label}格式不正确`);
      }
    });
    if (values.every((value) => !value)) continue;
    if (values.some((value) => !value)) {
      throw new FormValidationError(`${locale === 'zh' ? '中文' : '英文'}第 ${index + 1} 项必须填写完整`);
    }
    rows.push(Object.fromEntries(fields.map((field, fieldIndex) => [field.name, values[fieldIndex]])));
  }
  return rows;
}

export function settingList(
  formData: FormData,
  locale: 'zh' | 'en',
  name: string,
  label: string,
  maxLength: number,
): string[] {
  const values = formData.getAll(`${locale}_${name}`);
  if (values.length > 16) throw new FormValidationError(`${label}最多 16 项`);
  return values.flatMap((value, index) => {
    try {
      const text = validateAdminText(value, `${label}第 ${index + 1} 项`, maxLength);
      return text ? [text] : [];
    } catch (error) {
      throw new FormValidationError(error instanceof Error ? error.message : `${label}格式不正确`);
    }
  });
}

export function assertExistingSettingShape(key: SiteSettingKey, i18n: string | null | undefined) {
  try {
    for (const locale of ['zh', 'en'] as const) {
      const value = readAdminI18nLocale<unknown>(i18n, locale);
      if (value === null) continue;
      if ((key === 'stats' || key === 'craft') && !Array.isArray(value)) {
        throw new Error(`${locale} 内容应为列表`);
      }
      if (key !== 'stats' && key !== 'craft' && (!value || typeof value !== 'object' || Array.isArray(value))) {
        throw new Error(`${locale} 内容应为对象`);
      }
    }
  } catch (error) {
    const detail = error instanceof Error ? error.message : '格式异常';
    throw new FormValidationError(`现有 ${key} 多语言 JSON ${detail}；为避免丢失其他语言，本次未保存`);
  }
}

export function parseSiteSetting(formData: FormData, key: SiteSettingKey) {
  switch (key) {
    case 'hero': {
      const zh = {
        heroImage: settingImage(formData, 'heroImage', '首页展示图片'),
        heroSeriesId: settingText(formData, 'heroSeriesId', '首页展示系列', 100),
        title: settingText(formData, 'zh_title', '中文主标题', 160, true),
        subtitle: settingText(formData, 'zh_subtitle', '中文副标题', 500),
        cta1: settingText(formData, 'zh_cta1', '中文按钮 1', 120),
        cta2: settingText(formData, 'zh_cta2', '中文按钮 2', 120),
      };
      const en = {
        title: settingText(formData, 'en_title', 'English title', 160),
        subtitle: settingText(formData, 'en_subtitle', 'English subtitle', 500),
        cta1: settingText(formData, 'en_cta1', 'English button 1', 120),
        cta2: settingText(formData, 'en_cta2', 'English button 2', 120),
      };
      return { zh, en: localeOrMissing(en) };
    }
    case 'contact': {
      const locale = (prefix: 'zh' | 'en', label: string) => ({
        company: settingText(formData, `${prefix}_company`, `${label}公司名称`, 200),
        phone: settingPhone(formData, `${prefix}_phone`, `${label}电话`),
        phone2: settingPhone(formData, `${prefix}_phone2`, `${label}备用电话`),
        email: settingEmail(formData, `${prefix}_email`, `${label}邮箱`),
        address: settingText(formData, `${prefix}_address`, `${label}地址`, 500),
        icp: settingText(formData, `${prefix}_icp`, `${label}备案号`, 120),
      });
      const zh = locale('zh', '中文');
      const en = locale('en', '英文');
      return { zh, en: localeOrMissing(en) };
    }
    case 'about': {
      const images = {
        image1: settingImage(formData, 'image1', '关于我们图片 1'),
        image2: settingImage(formData, 'image2', '关于我们图片 2'),
        image3: settingImage(formData, 'image3', '关于我们图片 3'),
      };
      const locale = (prefix: 'zh' | 'en', label: string) => ({
        title: settingText(formData, `${prefix}_title`, `${label}标题`, 160, prefix === 'zh'),
        subtitle: settingText(formData, `${prefix}_subtitle`, `${label}副标题`, 240),
        body: settingText(formData, `${prefix}_body`, `${label}正文`, 5000),
        cta: settingText(formData, `${prefix}_cta`, `${label}按钮`, 120),
        ...images,
      });
      const zh = locale('zh', '中文');
      const en = locale('en', '英文');
      return { zh, en: localeOrMissing(en) };
    }
    case 'stats': {
      const fields = [
        { name: 'value', label: '统计数值', maxLength: 40 },
        { name: 'label', label: '统计说明', maxLength: 120 },
      ] as const;
      const zh = settingRows(formData, 'zh', 'stats', fields);
      const en = settingRows(formData, 'en', 'stats', fields);
      if (!zh.length) throw new FormValidationError('中文统计数据至少保留 1 项');
      return { zh, en: localeOrMissing(en) };
    }
    case 'craft': {
      const fields = [
        { name: 'title', label: '工艺标题', maxLength: 160 },
        { name: 'desc', label: '工艺说明', maxLength: 500 },
      ] as const;
      const zh = settingRows(formData, 'zh', 'craft', fields);
      const en = settingRows(formData, 'en', 'craft', fields);
      if (!zh.length) throw new FormValidationError('中文工艺内容至少保留 1 项');
      return { zh, en: localeOrMissing(en) };
    }
    case 'join': {
      const locale = (prefix: 'zh' | 'en', label: string) => ({
        title: settingText(formData, `${prefix}_title`, `${label}标题`, 160, prefix === 'zh'),
        subtitle: settingText(formData, `${prefix}_subtitle`, `${label}副标题`, 500),
        advantages: settingList(formData, prefix, 'advantages', `${label}合作优势`, 300),
        cta: settingText(formData, `${prefix}_cta`, `${label}按钮`, 120),
      });
      const zh = locale('zh', '中文');
      const en = locale('en', '英文');
      return { zh, en: localeOrMissing(en) };
    }
    case 'capabilities': {
      const locale = (prefix: 'zh' | 'en', label: string) => ({
        title: settingText(formData, `${prefix}_title`, `${label}标题`, 180, prefix === 'zh'),
        subtitle: settingText(formData, `${prefix}_subtitle`, `${label}副标题`, 700),
        intro: settingText(formData, `${prefix}_intro`, `${label}能力总述`, 3000),
        qualityBody: settingText(formData, `${prefix}_qualityBody`, `${label}质量说明`, 3000),
        oemBody: settingText(formData, `${prefix}_oemBody`, `${label}制造与定制说明`, 3000),
        documentsBody: settingText(formData, `${prefix}_documentsBody`, `${label}资料支持说明`, 3000),
      });
      const zh = locale('zh', '中文');
      const en = locale('en', '英文');
      return { zh, en: localeOrMissing(en) };
    }
    case 'partners': {
      const locale = (prefix: 'zh' | 'en', label: string) => ({
        title: settingText(formData, `${prefix}_title`, `${label}标题`, 180, prefix === 'zh'),
        subtitle: settingText(formData, `${prefix}_subtitle`, `${label}副标题`, 700),
        intro: settingText(formData, `${prefix}_intro`, `${label}合作说明`, 3000),
        processBody: settingText(formData, `${prefix}_processBody`, `${label}流程补充`, 2000),
        cta: settingText(formData, `${prefix}_cta`, `${label}按钮`, 120),
      });
      const zh = locale('zh', '中文');
      const en = locale('en', '英文');
      return { zh, en: localeOrMissing(en) };
    }
    case 'resources': {
      const locale = (prefix: 'zh' | 'en', label: string) => ({
        title: settingText(formData, `${prefix}_title`, `${label}标题`, 180, prefix === 'zh'),
        subtitle: settingText(formData, `${prefix}_subtitle`, `${label}副标题`, 700),
        intro: settingText(formData, `${prefix}_intro`, `${label}资料页说明`, 3000),
        documentsBody: settingText(formData, `${prefix}_documentsBody`, `${label}文件申请说明`, 3000),
        faqIntro: settingText(formData, `${prefix}_faqIntro`, `${label}常见问题说明`, 2000),
      });
      const zh = locale('zh', '中文');
      const en = locale('en', '英文');
      return { zh, en: localeOrMissing(en) };
    }
    case 'careers': {
      const locale = (prefix: 'zh' | 'en', label: string) => ({
        title: settingText(formData, `${prefix}_title`, `${label}标题`, 160, prefix === 'zh'),
        subtitle: settingText(formData, `${prefix}_subtitle`, `${label}副标题`, 500),
        body: settingText(formData, `${prefix}_body`, `${label}正文`, 5000),
      });
      const zh = locale('zh', '中文');
      const en = locale('en', '英文');
      return { zh, en: localeOrMissing(en) };
    }
    case 'footer': {
      const locale = (prefix: 'zh' | 'en', label: string) => ({
        about: settingText(formData, `${prefix}_about`, `${label}页脚简介`, 1000),
        copyright: settingText(formData, `${prefix}_copyright`, `${label}版权文字`, 240),
      });
      const zh = locale('zh', '中文');
      const en = locale('en', '英文');
      return { zh, en: localeOrMissing(en) };
    }
  }
}

