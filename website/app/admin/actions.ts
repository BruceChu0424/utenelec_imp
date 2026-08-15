'use server';
import { prisma } from '@/lib/db';
import {
  clearSession,
  clearSuccessfulLoginAttempts,
  consumeLoginAttempt,
  getLoginClientIdentifier,
  setSession,
  verifyLoginPassword,
} from '@/lib/auth';
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
import { routing } from '@/i18n/routing';
import {
  PRODUCT_CLASSIFICATION_STATUSES,
  PRODUCT_FUNCTION_TYPES,
  SERIES_CATALOG_ROLES,
  isProductClassificationStatus,
  isProductFunctionType,
  isSeriesCatalogRole,
} from '@/lib/product-taxonomy';
import { getProductPublicationIssue, getSeriesPublicationIssue } from '@/lib/publication';
import { isNewsCategory } from '@/lib/news-content';
import {
  createUploadDescriptor,
  storeUploadedWebp,
} from '@/lib/upload-storage';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import sharp from 'sharp';

/* ============ 认证 ============ */
const LOGIN_FAILURE_MESSAGE = '用户名或密码错误，或尝试过于频繁，请稍后重试';
const MAX_PENDING_MEDIA = 64;
const MAX_PENDING_MEDIA_BYTES = 512 * 1024 * 1024;

export async function login(formData: FormData) {
  const username = cleanText(formData.get('username'), 128);
  const password = String(formData.get('password') || '').slice(0, 1024);
  const clientIdentifier = await getLoginClientIdentifier();
  if (!consumeLoginAttempt(clientIdentifier, username).allowed) {
    return { error: LOGIN_FAILURE_MESSAGE };
  }

  try {
    const user = await prisma.user.findUnique({ where: { username } });
    const passwordMatches = await verifyLoginPassword(password, user?.password);
    if (!user || !passwordMatches) return { error: LOGIN_FAILURE_MESSAGE };

    clearSuccessfulLoginAttempts(clientIdentifier, username);
    await setSession(user.username, user.password);
  } catch (error) {
    console.error('admin login failed', error);
    return { error: LOGIN_FAILURE_MESSAGE };
  }
  redirect('/admin');
}

export async function logout() {
  await clearSession();
  redirect('/admin/login');
}

/* ============ 图片上传 (生产 durable uploads / 本地 public/uploads) ============ */
export async function uploadImage(formData: FormData): Promise<{ url?: string; error?: string }> {
  const s = await getSessionSafe();
  if (!s) return { error: '未登录' };
  const file = formData.get('file');
  if (!(file instanceof File)) return { error: '未选择文件' };
  if (file.size > 8 * 1024 * 1024) return { error: '文件超过 8MB' };
  const buf = Buffer.from(await file.arrayBuffer());
  let processed: Buffer;
  try {
    const image = sharp(buf, { failOn: 'error', limitInputPixels: 40_000_000 });
    const metadata = await image.metadata();
    if (!metadata.width || !metadata.height || !metadata.format) throw new Error('missing metadata');
    if (!['jpeg', 'png', 'gif', 'webp'].includes(metadata.format)) throw new Error('unsupported format');
    if ((metadata.pages || 1) > 1) return { error: '暂不接受动画图片，请上传单帧 JPG、PNG 或 WebP' };
    if (metadata.width * metadata.height > 40_000_000) return { error: '图片总像素超过 4000 万' };
    processed = await image
      .rotate()
      .resize({ width: 3200, height: 3200, fit: 'inside', withoutEnlargement: true })
      .webp({ quality: 88, effort: 4 })
      .toBuffer();
  } catch {
    return { error: '图片无法完整解码，或不是有效的 JPG、PNG、GIF、WebP 文件' };
  }
  try {
    const descriptor = createUploadDescriptor(processed);
    await prisma.$transaction(async (tx) => {
      const authorities = await tx.websiteStateAuthority.findMany({
        select: { id: true, authorityUuid: true },
        take: 2,
      });
      if (authorities.length !== 1 || authorities[0].id !== 'production' || authorities[0].authorityUuid === 'UNBOUND') {
        throw new Error('website database authority is not initialized');
      }
      const pending = await tx.websiteMediaObject.aggregate({
        where: { state: 'PENDING' },
        _count: { _all: true },
        _sum: { sizeBytes: true },
      });
      if (
        pending._count._all >= MAX_PENDING_MEDIA
        || (pending._sum.sizeBytes ?? 0) + descriptor.sizeBytes > MAX_PENDING_MEDIA_BYTES
      ) {
        throw new Error('pending media quota is exhausted; operator recovery is required');
      }
      await tx.websiteMediaObject.create({
        data: {
          publicPath: descriptor.publicPath,
          authorityId: 'production',
          sha256: descriptor.sha256,
          sizeBytes: descriptor.sizeBytes,
          state: 'PENDING',
        },
      });
    });
    try {
      const url = await storeUploadedWebp(processed, {
        fileNameFactory: () => descriptor.fileName,
      });
      try {
        const committed = await prisma.websiteMediaObject.updateMany({
          where: {
            publicPath: descriptor.publicPath,
            authorityId: 'production',
            sha256: descriptor.sha256,
            sizeBytes: descriptor.sizeBytes,
            state: 'PENDING',
          },
          data: { state: 'COMMITTED' },
        });
        if (committed.count !== 1) throw new Error('media reservation compare-and-set failed');
      } catch (error) {
        const observed = await prisma.websiteMediaObject.findUnique({
          where: { publicPath: descriptor.publicPath },
        }).catch(() => null);
        if (!observed
          || observed.authorityId !== 'production'
          || observed.sha256 !== descriptor.sha256
          || observed.sizeBytes !== descriptor.sizeBytes
          || observed.state !== 'COMMITTED') {
          throw error;
        }
      }
      return { url };
    } catch (error) {
      // Once the durable reservation exists, never guess which side of a
      // filesystem/SQLite boundary committed.  The fixed root recovery tool
      // reconciles PENDING evidence idempotently; application cleanup could
      // otherwise turn an ambiguous success into COMMITTED-without-file.
      throw error;
    }
  } catch (error) {
    console.error('image upload storage failed', error);
    return { error: '图片保存失败，请稍后重试或联系管理员检查媒体存储' };
  }
}

async function getSessionSafe() {
  const { getSession } = await import('@/lib/auth');
  const session = await getSession();
  if (!session) return null;
  const user = await prisma.user.findUnique({ where: { username: session.username }, select: { id: true } });
  return user ? session : null;
}

async function requireAdmin() {
  if (!(await getSessionSafe())) throw new Error('未授权的后台操作');
}

class FormValidationError extends Error {}

const PRODUCT_CONTROL_MODES = ['ONE_WAY', 'TWO_WAY', 'MULTIWAY', 'INTERMEDIATE'] as const;
const SERIES_MEDIA_ROLES = ['hero', 'lineup', 'lifestyle', 'combination', 'detail'] as const;

function cleanText(value: FormDataEntryValue | null, maxLength = 500): string {
  return String(value || '').trim().slice(0, maxLength);
}

function strictText(value: FormDataEntryValue | null, label: string, maxLength: number): string {
  const text = String(value || '').trim();
  if (text.length > maxLength) throw new FormValidationError(`${label}不能超过 ${maxLength} 个字符`);
  return text;
}

function expectedRowVersion(value: FormDataEntryValue | null, label: string): number {
  const raw = strictText(value, label, 20);
  if (!raw || !/^\d+$/.test(raw) || Number(raw) < 1 || !Number.isSafeInteger(Number(raw))) {
    throw new FormValidationError(`${label}无效，请刷新页面后重试`);
  }
  return Number(raw);
}

function isSafePublicImagePath(value: string): boolean {
  return /^\/(?:uploads|images)\/[^\s?#\\]+$/u.test(value)
    && !value.split('/').includes('..');
}

function optionalImagePath(value: FormDataEntryValue | null, label: string): string | null {
  const imagePath = cleanText(value, 500);
  if (!imagePath) return null;
  if (!isSafePublicImagePath(imagePath)) {
    throw new FormValidationError(`${label}仅允许 /uploads/ 或 /images/ 下的站内图片路径`);
  }
  return imagePath;
}

function optionalNumber(
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

function requiredInteger(value: FormDataEntryValue | null, label: string, min = 0): number {
  return optionalNumber(value, label, { min, integer: true }) ?? min;
}

function galleryJson(value: FormDataEntryValue | null): string {
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

function parseProductSpecLocale(
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

function productSpecsJson(
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

type ProductVariantInput = {
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

function parseProductVariants(formData: FormData): ProductVariantInput[] {
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

function productVariantData(variant: ProductVariantInput, existingI18n?: string | null) {
  const { id: _id, zhName, enName, ...data } = variant;
  return {
    ...data,
    i18n: mergeAdminI18n(existingI18n, {
      zh: { name: zhName },
      en: localeOrMissing({ name: enName }),
    }),
  };
}

function revalidateProductContent() {
  for (const locale of routing.locales) {
    revalidatePath(`/${locale}`);
    revalidatePath(`/${locale}/products`, 'layout');
    revalidatePath(`/${locale}/studio`);
  }
  revalidatePath('/admin/products');
  revalidatePath('/admin/series');
  revalidatePath('/admin/scenes');
}

function revalidateSceneContent() {
  for (const locale of routing.locales) {
    revalidatePath(`/${locale}`);
    revalidatePath(`/${locale}/studio`);
  }
  revalidatePath('/admin/scenes');
}

function revalidateLocalizedContent(sections: string[] = []) {
  for (const locale of routing.locales) {
    revalidatePath(`/${locale}`);
    for (const section of sections) revalidatePath(`/${locale}/${section}`, 'layout');
  }
}

/* ============ 产品 ============ */
export async function saveProduct(formData: FormData) {
  if (!(await getSessionSafe())) return { error: '登录状态已失效，请重新登录' };

  const id = cleanText(formData.get('id'), 80);
  const seriesCode = cleanText(formData.get('seriesCode'), 80);
  const featured = formData.get('featured') === 'on';
  const published = formData.get('published') === 'on';
  const sceneEnabled = formData.get('sceneEnabled') === 'on';

  try {
    const version = id ? expectedRowVersion(formData.get('rowVersion'), '产品版本') : null;
    const model = strictText(formData.get('model'), '产品型号', 120) || null;
    const category = strictText(formData.get('category'), '产品分类', 120) || null;
    const functionTypeValue = strictText(formData.get('functionType'), '功能类型', 60) || null;
    if (functionTypeValue && !isProductFunctionType(functionTypeValue)) {
      throw new FormValidationError(`功能类型无效，只允许：${PRODUCT_FUNCTION_TYPES.join('、')}`);
    }
    const gangCount = optionalNumber(formData.get('gangCount'), '联数 / 位数', { min: 1, max: 12, integer: true });
    const controlMode = strictText(formData.get('controlMode'), '控制方式', 40) || null;
    if (controlMode && !(PRODUCT_CONTROL_MODES as readonly string[]).includes(controlMode)) {
      throw new FormValidationError('控制方式无效，请从下拉列表重新选择');
    }
    const configuration = strictText(formData.get('configuration'), '配置说明', 1000) || null;
    const classificationStatusValue = strictText(formData.get('classificationStatus'), '分类审核状态', 40)
      || 'NEEDS_REVIEW';
    if (!isProductClassificationStatus(classificationStatusValue)) {
      throw new FormValidationError(`分类审核状态无效，只允许：${PRODUCT_CLASSIFICATION_STATUSES.join('、')}`);
    }
    const zhName = strictText(formData.get('zh_name'), '产品中文名称', 160);
    const zhDesc = strictText(formData.get('zh_desc'), '产品中文描述', 5000);
    const enName = strictText(formData.get('en_name'), '产品英文名称', 160);
    const enDesc = strictText(formData.get('en_desc'), '产品英文描述', 5000);
    if (!zhName) throw new FormValidationError('请填写产品中文名称');
    const minOrderQty = optionalNumber(formData.get('minOrderQty'), '最小起订量', { min: 1, integer: true });
    const sortOrder = requiredInteger(formData.get('sortOrder'), '产品排序');
    const zhSpecs = parseProductSpecLocale(formData, 'zh', '中文');
    const enSpecs = parseProductSpecLocale(formData, 'en', '英文');
    const variants = parseProductVariants(formData);
    const displayableVariants = variants.filter((variant) => variant.published && variant.image);
    if (sceneEnabled && !displayableVariants.length) {
      throw new FormValidationError('启用场景试装时，至少需要一个已发布且有正面图的款式');
    }
    const defaultVariant = variants.find((variant) => variant.isDefault);
    if (published && !displayableVariants.length) {
      throw new FormValidationError('发布产品前，至少需要一个已发布且有图片的款式');
    }
    if (published && (!defaultVariant || !defaultVariant.published || !defaultVariant.image)) {
      throw new FormValidationError('发布产品前，请指定一个已发布且有图片的默认款式');
    }

    const image = optionalImagePath(formData.get('image'), '产品主图')
      || displayableVariants[0]?.image
      || null;
    const editedLocales = {
      zh: { name: zhName, description: zhDesc },
      en: localeOrMissing({ name: enName, description: enDesc }),
    };

    await prisma.$transaction(async (tx) => {
      const series = seriesCode
        ? await tx.series.findUnique({ where: { code: seriesCode }, include: { parent: true } })
        : null;
      if (seriesCode && !series) throw new FormValidationError('所选产品系列不存在，请刷新页面后重试');
      const publicationIssue = getProductPublicationIssue(published, series);
      if (publicationIssue === 'series-required') {
        throw new FormValidationError('发布产品前必须选择一个已发布系列');
      }
      if (publicationIssue === 'series-unpublished') {
        throw new FormValidationError('所选系列尚未发布，请先发布系列或暂时下架产品');
      }
      if (publicationIssue === 'collection-parent-required') {
        throw new FormValidationError('发布产品前，所选 COLLECTION 必须隶属于一个已发布的 FAMILY 系列');
      }
      if (publicationIssue === 'series-role-not-public') {
        throw new FormValidationError('发布产品前，所选系列必须是已发布的 FAMILY，或隶属于已发布 FAMILY 的 COLLECTION');
      }

      const skuKeys = new Set(variants.flatMap((variant) => (
        variant.sku ? [variant.sku.normalize('NFKC').toLocaleLowerCase()] : []
      )));
      if (skuKeys.size) {
        const otherVariants = await tx.productVariant.findMany({
          where: {
            sku: { not: null },
            ...(id ? { productId: { not: id } } : {}),
          },
          select: { sku: true },
        });
        const duplicate = otherVariants.find((variant) => (
          variant.sku && skuKeys.has(variant.sku.normalize('NFKC').toLocaleLowerCase())
        ));
        if (duplicate?.sku) throw new FormValidationError(`SKU“${duplicate.sku}”已被其他产品使用`);
      }

      const productData = {
        seriesId: series?.id ?? null,
        model,
        category,
        functionType: functionTypeValue,
        gangCount,
        controlMode,
        configuration,
        classificationStatus: classificationStatusValue,
        image,
        minOrderQty,
        sceneEnabled,
        featured,
        published,
        sortOrder,
      };
      if (!id) {
        await tx.product.create({
          data: {
            ...productData,
            i18n: mergeAdminI18n(null, editedLocales),
            specs: productSpecsJson(null, zhSpecs, enSpecs),
            slug: `p-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 7)}`,
            variants: { create: variants.map((variant) => productVariantData(variant)) },
          },
        });
        return;
      }

      const product = await tx.product.findUnique({
        where: { id },
        select: { id: true, i18n: true, specs: true },
      });
      if (!product) throw new FormValidationError('产品不存在，可能已被其他管理员删除');
      const existingVariants = await tx.productVariant.findMany({
        where: { productId: id },
        select: { id: true, i18n: true },
      });
      const existingIds = new Set(existingVariants.map((variant) => variant.id));
      const submittedIds = variants.flatMap((variant) => variant.id ? [variant.id] : []);
      if (submittedIds.some((variantId) => !existingIds.has(variantId))) {
        throw new FormValidationError('产品款式数据已变化，请刷新页面后重试');
      }

      const submittedById = new Map(variants.flatMap((variant) => variant.id ? [[variant.id, variant] as const] : []));
      const unavailableVariantIds = existingVariants
        .filter((variant) => {
          const submitted = submittedById.get(variant.id);
          return !submitted || !published || !sceneEnabled || !submitted.published || !submitted.image;
        })
        .map((variant) => variant.id);
      if (unavailableVariantIds.length) {
        await tx.scenePreset.updateMany({
          where: { defaultVariantId: { in: unavailableVariantIds } },
          data: { defaultVariantId: null },
        });
      }

      const updated = await tx.product.updateMany({
        where: { id, rowVersion: version as number },
        data: {
          ...productData,
          i18n: mergeAdminI18n(product.i18n, editedLocales),
          specs: productSpecsJson(product.specs, zhSpecs, enSpecs),
          rowVersion: { increment: 1 },
        },
      });
      if (updated.count !== 1) {
        throw new FormValidationError('产品已被其他管理员修改；本次未保存，请刷新后核对最新内容');
      }
      await tx.productVariant.deleteMany({
        where: submittedIds.length ? { productId: id, id: { notIn: submittedIds } } : { productId: id },
      });
      for (const variant of variants) {
        const variantId = variant.id;
        const existingI18n = variantId
          ? existingVariants.find((existing) => existing.id === variantId)?.i18n
          : null;
        const data = productVariantData(variant, existingI18n);
        if (variantId) await tx.productVariant.update({ where: { id: variantId }, data });
        else await tx.productVariant.create({ data: { ...data, productId: id } });
      }
    });
  } catch (error) {
    if (error instanceof FormValidationError) return { error: error.message };
    console.error('saveProduct failed', error);
    return { error: '产品保存失败，请检查填写内容后重试' };
  }

  revalidateProductContent();
  redirect('/admin/products');
}

export async function deleteProduct(id: string) {
  await requireAdmin();
  const product = await prisma.product.findUnique({ where: { id }, select: { published: true } });
  if (!product) return;
  if (product.published) redirect('/admin/products?error=unpublish-before-delete');
  await prisma.$transaction(async (tx) => {
    const variants = await tx.productVariant.findMany({ where: { productId: id }, select: { id: true } });
    if (variants.length) {
      await tx.scenePreset.updateMany({
        where: { defaultVariantId: { in: variants.map((variant) => variant.id) } },
        data: { defaultVariantId: null },
      });
    }
    const deleted = await tx.product.deleteMany({ where: { id, published: false } });
    if (deleted.count !== 1) throw new FormValidationError('产品状态已变化，请刷新后重试');
  });
  revalidateProductContent();
}

/* ============ 场景试装 ============ */
export async function saveScenePreset(formData: FormData) {
  if (!(await getSessionSafe())) return { error: '登录状态已失效，请重新登录' };

  const id = cleanText(formData.get('id'), 80);
  const slug = cleanText(formData.get('slug'), 120).toLowerCase();
  const zhName = cleanText(formData.get('zh_name'), 160);
  const zhDescription = cleanText(formData.get('zh_description'), 2000);
  const enName = cleanText(formData.get('en_name'), 160);
  const enDescription = cleanText(formData.get('en_description'), 2000);
  const backgroundImage = cleanText(formData.get('backgroundImage'), 500);
  const defaultVariantId = cleanText(formData.get('defaultVariantId'), 80) || null;
  const published = formData.get('published') === 'on';

  if (!slug || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug)) {
    return { error: '场景网址标识只能使用小写字母、数字和连字符' };
  }
  if (!zhName) return { error: '请填写场景中文名称' };
  if (!backgroundImage) return { error: '请上传或填写场景背景图' };
  if (!isSafePublicImagePath(backgroundImage)) return { error: '场景背景图仅允许站内图片路径' };

  try {
    const existing = id
      ? await prisma.scenePreset.findUnique({ where: { id }, select: { id: true, i18n: true } })
      : null;
    if (id && !existing) return { error: '场景不存在，可能已被其他管理员删除' };

    const sortOrder = requiredInteger(formData.get('sortOrder'), '场景排序');
    const placement = {
      x: optionalNumber(formData.get('positionX'), '水平位置', { min: 0, max: 100 }) ?? 50,
      y: optionalNumber(formData.get('positionY'), '垂直位置', { min: 0, max: 100 }) ?? 50,
      scale: optionalNumber(formData.get('scale'), '初始缩放', { min: 0.1, max: 4 }) ?? 1,
      rotation: optionalNumber(formData.get('rotation'), '初始旋转', { min: -180, max: 180 }) ?? 0,
    };
    if (defaultVariantId) {
      const variant = await prisma.productVariant.findFirst({
        where: {
          id: defaultVariantId,
          image: { not: null },
          ...(published ? { published: true } : {}),
          product: { sceneEnabled: true, ...(published ? { published: true } : {}) },
        },
        select: { id: true },
      });
      if (!variant) return { error: '默认款式不可用于场景试装，请重新选择' };
    }
    const duplicate = await prisma.scenePreset.findFirst({
      where: { slug, ...(id ? { id: { not: id } } : {}) },
      select: { id: true },
    });
    if (duplicate) return { error: '该场景网址标识已存在' };

    const data = {
      slug,
      backgroundImage,
      defaultVariantId,
      config: JSON.stringify({ schemaVersion: 1, placement }),
      published,
      sortOrder,
      i18n: mergeAdminI18n(existing?.i18n, {
        zh: { name: zhName, description: zhDescription },
        en: localeOrMissing({ name: enName, description: enDescription }),
      }),
    };
    if (id) {
      const result = await prisma.scenePreset.updateMany({ where: { id }, data });
      if (!result.count) return { error: '场景不存在，可能已被其他管理员删除' };
    } else {
      await prisma.scenePreset.create({ data });
    }
  } catch (error) {
    if (error instanceof FormValidationError) return { error: error.message };
    console.error('saveScenePreset failed', error);
    return { error: '场景保存失败，请检查填写内容后重试' };
  }

  revalidateSceneContent();
  redirect('/admin/scenes');
}

export async function deleteScenePreset(id: string) {
  await requireAdmin();
  await prisma.scenePreset.delete({ where: { id } });
  revalidateSceneContent();
}

/* ============ 系列 ============ */
type SeriesMediaInput = {
  id: string | null;
  role: (typeof SERIES_MEDIA_ROLES)[number];
  image: string;
  zhAlt: string;
  enAlt: string;
  sortOrder: number;
  published: boolean;
};

function parseSeriesMedia(formData: FormData): SeriesMediaInput[] {
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

function seriesMediaData(media: SeriesMediaInput, existingI18n?: string | null) {
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

export async function saveSeries(formData: FormData) {
  if (!(await getSessionSafe())) return { error: '登录状态已失效，请重新登录' };

  const id = cleanText(formData.get('id'), 80);
  const parentId = cleanText(formData.get('parentId'), 80) || null;
  const published = formData.get('published') === 'on';

  try {
    const version = id ? expectedRowVersion(formData.get('rowVersion'), '系列版本') : null;
    const code = strictText(formData.get('code'), '系列网址代号', 80);
    const publicSlug = strictText(formData.get('publicSlug'), '公开聚合网址', 80) || null;
    const catalogRole = strictText(formData.get('catalogRole'), '目录角色', 40) || 'UNCLASSIFIED';
    if (!code || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(code)) {
      throw new FormValidationError('系列网址代号只能使用小写字母、数字和连字符');
    }
    if (publicSlug && !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(publicSlug)) {
      throw new FormValidationError('公开聚合网址只能使用小写字母、数字和连字符');
    }
    if (!isSeriesCatalogRole(catalogRole)) {
      throw new FormValidationError(`目录角色无效，只允许：${SERIES_CATALOG_ROLES.join('、')}`);
    }
    if (published && (catalogRole === 'CONTAINER' || catalogRole === 'ARCHIVE')) {
      throw new FormValidationError('结构容器或归档系列不能发布，请先改为 FAMILY / COLLECTION 或保持下架');
    }
    const zhName = strictText(formData.get('zh_name'), '系列中文名称', 160);
    const zhSubtitle = strictText(formData.get('zh_subtitle'), '系列中文副标题', 240);
    const zhDescription = strictText(formData.get('zh_desc'), '系列中文描述', 5000);
    const enName = strictText(formData.get('en_name'), '系列英文名称', 160);
    const enSubtitle = strictText(formData.get('en_subtitle'), '系列英文副标题', 240);
    const enDescription = strictText(formData.get('en_desc'), '系列英文描述', 5000);
    if (!zhName) throw new FormValidationError('请填写系列中文名称');
    const sortOrder = requiredInteger(formData.get('sortOrder'), '系列排序');
    const coverImage = optionalImagePath(formData.get('coverImage'), '系列封面');
    const media = parseSeriesMedia(formData);

    await prisma.$transaction(async (tx) => {
      const existing = id
        ? await tx.series.findUnique({
            where: { id },
            select: {
              id: true,
              i18n: true,
              _count: {
                select: {
                  products: { where: { published: true } },
                  children: { where: { published: true, catalogRole: 'COLLECTION' } },
                },
              },
            },
          })
        : null;
      if (id && !existing) throw new FormValidationError('系列不存在，可能已被其他管理员删除');

      const duplicate = await tx.series.findFirst({
        where: { code, ...(id ? { id: { not: id } } : {}) },
        select: { id: true },
      });
      if (duplicate) throw new FormValidationError('该系列网址代号已存在');
      if (publicSlug) {
        const duplicateSlug = await tx.series.findFirst({
          where: { publicSlug, ...(id ? { id: { not: id } } : {}) },
          select: { id: true },
        });
        if (duplicateSlug) throw new FormValidationError('该公开聚合网址已被其他系列使用');
      }

      let selectedParent: { catalogRole: string; published: boolean } | null = null;
      if (parentId) {
        const visited = new Set<string>();
        let cursor: string | null = parentId;
        while (cursor) {
          if (visited.has(cursor)) throw new FormValidationError('现有系列层级存在循环，请先修复层级数据');
          if (id && cursor === id) throw new FormValidationError('上级系列不能选择当前系列或其下级系列');
          visited.add(cursor);
          const parent: { id: string; parentId: string | null; catalogRole: string; published: boolean } | null = await tx.series.findUnique({
            where: { id: cursor },
            select: { id: true, parentId: true, catalogRole: true, published: true },
          });
          if (!parent) throw new FormValidationError('所选上级系列不存在，请刷新页面后重试');
          if (cursor === parentId) selectedParent = parent;
          cursor = parent.parentId;
        }
      }

      const publicationIssue = getSeriesPublicationIssue(published, catalogRole, selectedParent, {
        publishedProducts: existing?._count.products ?? 0,
        publishedCollections: existing?._count.children ?? 0,
      });
      if (publicationIssue === 'collection-parent-required') {
        throw new FormValidationError('发布 COLLECTION 系列前，必须选择一个已发布的 FAMILY 上级系列');
      }
      if (publicationIssue === 'published-collections-require-family') {
        throw new FormValidationError('当前系列仍有已发布的 COLLECTION 下级；请先下架或迁移这些下级系列，再取消 FAMILY 发布或修改目录角色');
      }
      if (publicationIssue === 'published-products-require-public-series') {
        throw new FormValidationError('当前系列仍有已发布产品；请先下架或迁移这些产品，再取消系列发布或修改为非公开目录角色');
      }

      const i18n = mergeAdminI18n(existing?.i18n, {
        zh: { name: zhName, subtitle: zhSubtitle, description: zhDescription },
        en: localeOrMissing({ name: enName, subtitle: enSubtitle, description: enDescription }),
      });
      const data = { code, publicSlug, catalogRole, parentId, coverImage, sortOrder, published, i18n };

      if (id) {
        const existingMedia = await tx.seriesMedia.findMany({ where: { seriesId: id }, select: { id: true, i18n: true } });
        const existingMediaIds = new Set(existingMedia.map((item) => item.id));
        const submittedMediaIds = media.flatMap((item) => item.id ? [item.id] : []);
        if (submittedMediaIds.some((mediaId) => !existingMediaIds.has(mediaId))) {
          throw new FormValidationError('系列素材已变化，请刷新页面后重试');
        }
        const result = await tx.series.updateMany({
          where: { id, rowVersion: version as number },
          data: { ...data, rowVersion: { increment: 1 } },
        });
        if (!result.count) throw new FormValidationError('系列已被其他管理员修改；本次未保存，请刷新后核对最新内容');
        await tx.seriesMedia.deleteMany({
          where: submittedMediaIds.length ? { seriesId: id, id: { notIn: submittedMediaIds } } : { seriesId: id },
        });
        for (const item of media) {
          const existingI18n = item.id ? existingMedia.find((candidate) => candidate.id === item.id)?.i18n : null;
          const mediaData = seriesMediaData(item, existingI18n);
          if (item.id) await tx.seriesMedia.update({ where: { id: item.id }, data: mediaData });
          else await tx.seriesMedia.create({ data: { ...mediaData, seriesId: id } });
        }
      } else {
        await tx.series.create({
          data: { ...data, media: { create: media.map((item) => seriesMediaData(item)) } },
        });
      }
    });
  } catch (error) {
    if (error instanceof FormValidationError) return { error: error.message };
    if (error && typeof error === 'object' && 'code' in error && error.code === 'P2002') {
      return { error: '系列网址代号或公开聚合网址已存在，请换一个代号' };
    }
    console.error('saveSeries failed', error);
    return { error: '系列保存失败，请检查填写内容后重试' };
  }

  revalidateProductContent();
  redirect('/admin/series');
}

export async function deleteSeries(id: string) {
  await requireAdmin();
  const series = await prisma.series.findUnique({
    where: { id },
    select: { published: true, _count: { select: { products: true, children: true } } },
  });
  if (!series) return;
  if (series.published) redirect('/admin/series?error=unpublish-before-delete');
  if (series._count.products || series._count.children) redirect('/admin/series?error=series-not-empty');
  const deleted = await prisma.series.deleteMany({ where: { id, published: false } });
  if (deleted.count !== 1) redirect('/admin/series?error=series-state-changed');
  revalidateProductContent();
}

/* ============ 新闻 ============ */
export async function saveNews(formData: FormData) {
  await requireAdmin();
  const id = String(formData.get('id') || '');
  const category = String(formData.get('category') || 'company').trim();
  if (!isNewsCategory(category)) redirect('/admin/news?error=invalid-category');
  const coverImage = optionalImagePath(formData.get('coverImage'), '新闻封面');
  const dateStr = String(formData.get('publishedAt') || '');
  const publishedAt = dateStr ? new Date(dateStr) : new Date();
  const existing = id
    ? await prisma.news.findUnique({ where: { id }, select: { i18n: true } })
    : null;
  const en = {
    title: String(formData.get('en_title') || '').trim(),
    summary: String(formData.get('en_summary') || '').trim(),
    content: String(formData.get('en_content') || '').trim(),
  };
  const i18n = mergeAdminI18n(existing?.i18n, {
    zh: {
      title: String(formData.get('zh_title') || '').trim(),
      summary: String(formData.get('zh_summary') || '').trim(),
      content: String(formData.get('zh_content') || '').trim(),
    },
    en: localeOrMissing(en),
  });
  if (id) {
    await prisma.news.update({ where: { id }, data: { category, coverImage, publishedAt, i18n } });
  } else {
    await prisma.news.create({ data: { slug: `n-${Date.now().toString(36)}`, category, coverImage, publishedAt, i18n } });
  }
  revalidateLocalizedContent(['news']);
  redirect('/admin/news');
}

export async function deleteNews(id: string) {
  await requireAdmin();
  await prisma.news.delete({ where: { id } });
  revalidateLocalizedContent(['news']);
}

/* ============ 样板工程 ============ */
export async function saveCase(formData: FormData) {
  await requireAdmin();
  const id = String(formData.get('id') || '');
  const coverImage = optionalImagePath(formData.get('coverImage'), '案例封面');
  const existing = id
    ? await prisma.caseItem.findUnique({ where: { id }, select: { i18n: true } })
    : null;
  const en = {
    title: String(formData.get('en_title') || '').trim(),
    location: String(formData.get('en_location') || '').trim(),
    content: String(formData.get('en_content') || '').trim(),
  };
  const i18n = mergeAdminI18n(existing?.i18n, {
    zh: {
      title: String(formData.get('zh_title') || '').trim(),
      location: String(formData.get('zh_location') || '').trim(),
      content: String(formData.get('zh_content') || '').trim(),
    },
    en: localeOrMissing(en),
  });
  if (id) {
    await prisma.caseItem.update({ where: { id }, data: { coverImage, i18n } });
  } else {
    await prisma.caseItem.create({ data: { slug: `c-${Date.now().toString(36)}`, coverImage, i18n } });
  }
  revalidateLocalizedContent(['cases']);
  redirect('/admin/cases');
}

export async function deleteCase(id: string) {
  await requireAdmin();
  await prisma.caseItem.delete({ where: { id } });
  revalidateLocalizedContent(['cases']);
}

/* ============ 招聘 ============ */
export async function saveJob(formData: FormData) {
  await requireAdmin();
  const id = String(formData.get('id') || '');
  const department = String(formData.get('department') || '') || null;
  const location = String(formData.get('location') || '') || null;
  const existing = id
    ? await prisma.job.findUnique({ where: { id }, select: { i18n: true } })
    : null;
  const en = {
    title: String(formData.get('en_title') || '').trim(),
    requirements: String(formData.get('en_requirements') || '').trim(),
    description: String(formData.get('en_description') || '').trim(),
  };
  const i18n = mergeAdminI18n(existing?.i18n, {
    zh: {
      title: String(formData.get('zh_title') || '').trim(),
      requirements: String(formData.get('zh_requirements') || '').trim(),
      description: String(formData.get('zh_description') || '').trim(),
    },
    en: localeOrMissing(en),
  });
  if (id) {
    await prisma.job.update({ where: { id }, data: { department, location, i18n } });
  } else {
    await prisma.job.create({ data: { slug: `j-${Date.now().toString(36)}`, department, location, i18n } });
  }
  revalidateLocalizedContent(['careers']);
  redirect('/admin/jobs');
}

export async function deleteJob(id: string) {
  await requireAdmin();
  await prisma.job.delete({ where: { id } });
  revalidateLocalizedContent(['careers']);
}

/* ============ 站点设置 ============ */
const SITE_SETTING_KEYS = ['hero', 'contact', 'about', 'stats', 'craft', 'join', 'capabilities', 'partners', 'resources', 'careers', 'footer'] as const;
type SiteSettingKey = (typeof SITE_SETTING_KEYS)[number];
type SettingItem = Record<string, string>;

function isSettingKey(value: string): value is SiteSettingKey {
  return (SITE_SETTING_KEYS as readonly string[]).includes(value);
}

function settingText(
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

function settingPhone(formData: FormData, name: string, label: string): string {
  try {
    return validateAdminPhone(formData.get(name), label);
  } catch (error) {
    throw new FormValidationError(error instanceof Error ? error.message : `${label}格式不正确`);
  }
}

function settingEmail(formData: FormData, name: string, label: string): string {
  try {
    return validateAdminEmail(formData.get(name), label);
  } catch (error) {
    throw new FormValidationError(error instanceof Error ? error.message : `${label}格式不正确`);
  }
}

function settingImage(formData: FormData, name: string, label: string): string {
  try {
    return validateAdminPublicImagePath(formData.get(name), label);
  } catch (error) {
    throw new FormValidationError(error instanceof Error ? error.message : `${label}格式不正确`);
  }
}

function settingRows(
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

function settingList(
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

function assertExistingSettingShape(key: SiteSettingKey, i18n: string | null | undefined) {
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

function parseSiteSetting(formData: FormData, key: SiteSettingKey) {
  switch (key) {
    case 'hero': {
      const zh = {
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

export async function saveSiteSetting(formData: FormData): Promise<void> {
  if (!(await getSessionSafe())) redirect('/admin/login');
  const keyValue = cleanText(formData.get('settingKey'), 40);
  if (!isSettingKey(keyValue)) redirect('/admin/settings?setting=hero&error=unknown-setting#setting-hero');

  let failure = '';
  try {
    const existing = await prisma.setting.findUnique({ where: { key: keyValue }, select: { i18n: true } });
    assertExistingSettingShape(keyValue, existing?.i18n);
    const i18n = mergeAdminI18n(existing?.i18n, parseSiteSetting(formData, keyValue));
    await prisma.setting.upsert({
      where: { key: keyValue },
      update: { i18n },
      create: { key: keyValue, i18n },
    });
  } catch (error) {
    if (error instanceof FormValidationError) failure = error.message;
    else {
      console.error(`saveSiteSetting(${keyValue}) failed`, error);
      failure = '站点设置保存失败，请检查内容后重试';
    }
  }

  if (failure) {
    redirect(`/admin/settings?setting=${keyValue}&error=${encodeURIComponent(failure)}#setting-${keyValue}`);
  }

  const sections: Partial<Record<SiteSettingKey, string[]>> = {
    contact: ['contact'],
    about: ['about'],
    stats: ['about'],
    craft: ['about'],
    join: ['join'],
    capabilities: ['capabilities'],
    partners: ['partners'],
    resources: ['resources'],
    careers: ['careers'],
  };
  revalidateLocalizedContent(sections[keyValue] || []);
  revalidatePath('/admin/settings');
  redirect(`/admin/settings?saved=${keyValue}#setting-${keyValue}`);
}

export async function saveHero(formData: FormData): Promise<void> {
  formData.set('settingKey', 'hero');
  await saveSiteSetting(formData);
}

export async function saveContact(formData: FormData): Promise<void> {
  formData.set('settingKey', 'contact');
  await saveSiteSetting(formData);
}

/* ============ 留言 ============ */
export async function handleInquiry(id: string) {
  await requireAdmin();
  await prisma.inquiry.update({ where: { id }, data: { handled: true } });
  revalidatePath('/admin/inquiries');
}

export async function deleteInquiry(id: string) {
  await requireAdmin();
  await prisma.inquiry.delete({ where: { id } });
  revalidatePath('/admin/inquiries');
}
