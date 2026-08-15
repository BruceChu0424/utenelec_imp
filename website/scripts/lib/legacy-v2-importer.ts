import { createHash, randomUUID } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { constants as fsConstants } from 'node:fs';
import {
  access,
  copyFile,
  lstat,
  link,
  mkdir,
  open,
  readFile,
  realpath,
  rename,
  rm,
  stat,
  unlink,
  writeFile,
} from 'node:fs/promises';
import path from 'node:path';
import { Prisma, PrismaClient } from '@prisma/client';
import { legacySeriesContentRepair } from './legacy-series-content';

export const SOURCE_SYSTEM = 'ch-uten-v2';
export const SOURCE_SCHEMA_VERSION = 'uten-legacy-catalog/v2';
export const IMPORT_PLAN_SCHEMA_VERSION = 'uten-legacy-import-plan/v1';

const FULL_BASELINE = {
  products: { zh: 1121, en: 1036 },
  productDetails: { zh: 1121, en: 1036 },
  productListPages: { zh: 94, en: 87 },
  productLeafSortIds: { zh: 60, en: 58 },
  nonEmptyDescriptions: { zh: 814, en: 801 },
  emptyDescriptions: { zh: 307, en: 235 },
  news: { zh: 19, en: 3 },
  staticPages: { zh: 17, en: 7 },
  newsAssetUrls: { zh: 118, en: 1 },
  productAssetUrls: { zh: 2137, en: 2025 },
  productIdIntersection: 1035,
  zhOnlyProductIds: 86,
  enOnlyProductIds: 1,
  identitySortPathSha256: {
    zh: '6bbb72644226577cd6a79b3b825c1a2e67cb9647e30b92d4bc42013ad4c8652b',
    en: '977455e76c25712c0f2741a867b599defa0078b4c381caff3b7ae80fee60a752',
  },
  productImagesSha256: {
    zh: '868677193cb0d021e797f2832e51738dda53a1ddd8b4c57ec9c93118dfbd98f5',
    en: '1605428754c660b16729117cf2eb576fbe0d8de4077389b689df0565207f0fb4',
  },
} as const;

const REQUIRED_FULL_QA_CHECKS = [
  'unique-product-identity',
  'unique-category-identity',
  'source-provenance',
  'exact-product-id-relationship',
  'exact-product-identity-sortpath-zh',
  'exact-product-identity-sortpath-en',
  'exact-product-images-zh',
  'exact-product-images-en',
  'detail-url-identity',
  'unique-detail-source-pages',
  'legacy-html-safety-label',
  'per-product-image-completeness',
  'prices-remain-unset',
  'no-replacement-characters',
  'no-page-fetch-errors',
  'no-parse-errors',
  'no-media-errors',
  'no-forbidden-request-attempts',
] as const;

const SAFE_RASTER = {
  jpeg: { extension: '.jpg', mimeTypes: new Set(['image/jpeg', 'image/pjpeg']) },
  png: { extension: '.png', mimeTypes: new Set(['image/png']) },
  gif: { extension: '.gif', mimeTypes: new Set(['image/gif']) },
  webp: { extension: '.webp', mimeTypes: new Set(['image/webp']) },
} as const;

type JsonRecord = Record<string, unknown>;
type Locale = 'zh' | 'en';
type CheckStatus = 'pass' | 'fail';

export interface ImportCheck {
  id: string;
  status: CheckStatus;
  severity: 'error' | 'warning' | 'info';
  message: string;
  actual?: unknown;
  expected?: unknown;
}

export interface LegacyImportPlan {
  schemaVersion: typeof IMPORT_PLAN_SCHEMA_VERSION;
  mode: 'dry-run';
  createdAt: string;
  inputRoot: string;
  sourceSchemaVersion: string;
  digests: {
    catalogSha256: string;
    mediaSha256: string;
    qaReportSha256: string;
    checkpointSha256: string;
    bundleSha256: string;
  };
  status: CheckStatus;
  qa: { status: string; expectFull: boolean };
  applyGate: { eligible: boolean; reasons: string[] };
  summary: ImportSummary;
  checks: ImportCheck[];
}

interface ImportSummary {
  localizedProductRecords: number;
  canonicalProducts: number;
  bilingualProducts: number;
  zhOnlyProducts: number;
  enOnlyProducts: number;
  duplicateNameGroupsPreserved: number;
  localizedCategoryRecords: number;
  canonicalSeries: number;
  variants: number;
  explicitVariants: number;
  mediaAssets: number;
  publicRasterAssets: number;
  unpublishableRawRecords: number;
}

interface NormalizedMedia {
  sha256: string;
  mimeType: string;
  extension: string;
  bytes: number;
  width: number | null;
  height: number | null;
  sourcePath: string;
  absoluteSourcePath: string;
  publicPath: string | null;
  sourceUrls: string[];
  sourceRefs: string[];
}

interface NormalizedSeries {
  sourceId: string;
  sourceIdentity: string;
  code: string;
  parentSourceId: string | null;
  i18n: Record<string, JsonRecord>;
  sortOrder: number;
}

interface NormalizedVariant {
  sourceId: string;
  sourceIdentity: string;
  i18n: Record<string, JsonRecord>;
  sku: string | null;
  swatchHex: string | null;
  image: string | null;
  gallery: string[];
  finish: string | null;
  widthMm: number | null;
  heightMm: number | null;
  depthMm: number | null;
  sortOrder: number;
  explicit: boolean;
}

interface NormalizedProduct {
  sourceId: string;
  sourceIdentity: string;
  slug: string;
  seriesSourceId: string | null;
  category: string | null;
  i18n: Record<string, JsonRecord>;
  image: string | null;
  gallery: string[];
  sortOrder: number;
  variants: NormalizedVariant[];
}

interface NormalizedMediaLink {
  productSourceIdentity: string;
  variantSourceIdentity: string | null;
  assetSha256: string;
  role: 'thumbnail' | 'main' | 'gallery';
  locale: Locale;
  sourceUrl: string | null;
  sortOrder: number;
}

interface NormalizedSourceRecord {
  entityType: 'series' | 'product' | 'variant' | 'news' | 'page';
  sourceId: string;
  locale: Locale;
  identityKey: string;
  sourceUrl: string;
  finalUrl: string | null;
  sourceHash: string;
  rawHtmlPath: string | null;
  scrapedAt: Date | null;
  rawPayload: string;
  targetSourceIdentity: string | null;
}

export interface PreparedLegacyImport {
  inputRoot: string;
  plan: LegacyImportPlan;
  series: NormalizedSeries[];
  products: NormalizedProduct[];
  media: NormalizedMedia[];
  mediaLinks: NormalizedMediaLink[];
  sourceRecords: NormalizedSourceRecord[];
}

export interface ApplyOptions {
  inputRoot: string;
  planPath: string;
  databasePath: string;
  publicDir: string;
  backupDir?: string;
}

export interface ApplyResult {
  status: 'applied' | 'already-applied';
  importRunId: string;
  backupPath: string;
  copiedMedia: number;
  summary: ImportSummary;
}

function isRecord(value: unknown): value is JsonRecord {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function record(value: unknown, label: string): JsonRecord {
  if (!isRecord(value)) throw new Error(`${label} must be a JSON object.`);
  return value;
}

function array(value: unknown, label: string): unknown[] {
  if (!Array.isArray(value)) throw new Error(`${label} must be a JSON array.`);
  return value;
}

function requiredString(value: unknown, label: string): string {
  if (typeof value !== 'string' || !value.trim()) throw new Error(`${label} must be a non-empty string.`);
  return value.trim();
}

function optionalString(value: unknown): string | null {
  return typeof value === 'string' && value.trim() ? value.trim() : null;
}

function localeOf(value: unknown, label: string): Locale {
  if (value !== 'zh' && value !== 'en') throw new Error(`${label} must be zh or en.`);
  return value;
}

function nonNegativeNumber(value: unknown, label: string): number | null {
  if (value === null || value === undefined || value === '') return null;
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) {
    throw new Error(`${label} must be a non-negative number or null.`);
  }
  return value;
}

function integer(value: unknown, label: string): number {
  if (typeof value === 'number' && Number.isSafeInteger(value)) return value;
  if (typeof value === 'string' && /^-?\d+$/.test(value)) return Number.parseInt(value, 10);
  throw new Error(`${label} must be an integer.`);
}

function numericIdentity(value: unknown, label: string): string {
  const result = requiredString(value, label);
  if (!/^\d+$/.test(result)) throw new Error(`${label} must be a numeric legacy ID.`);
  return result;
}

function strings(value: unknown, label: string): string[] {
  return array(value ?? [], label).map((item, index) => requiredString(item, `${label}[${index}]`));
}

function sha256Buffer(value: Buffer | string): string {
  return createHash('sha256').update(value).digest('hex');
}

async function sha256File(filename: string): Promise<string> {
  const hash = createHash('sha256');
  await new Promise<void>((resolve, reject) => {
    const stream = createReadStream(filename);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('error', reject);
    stream.on('end', resolve);
  });
  return hash.digest('hex');
}

async function readJsonFile(filename: string, label: string): Promise<{ raw: Buffer; value: JsonRecord }> {
  const raw = await readFile(filename);
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw.toString('utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid UTF-8 JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
  return { raw, value: record(parsed, label) };
}

function check(
  checks: ImportCheck[],
  id: string,
  ok: boolean,
  message: string,
  options: Partial<Pick<ImportCheck, 'severity' | 'actual' | 'expected'>> = {},
): void {
  checks.push({
    id,
    status: ok ? 'pass' : 'fail',
    severity: options.severity ?? 'error',
    message,
    ...(options.actual !== undefined ? { actual: options.actual } : {}),
    ...(options.expected !== undefined ? { expected: options.expected } : {}),
  });
}

function sanitizePlainText(value: unknown, maximumLength: number): string {
  if (typeof value !== 'string') return '';
  return value
    .replace(/<[^>]*>/g, ' ')
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
    .normalize('NFC')
    .slice(0, maximumLength);
}

function sourceOrigin(value: unknown): { kind: 'production' | 'fixture'; origin: string } | null {
  if (typeof value !== 'string') return null;
  try {
    const parsed = new URL(value);
    if (parsed.protocol !== 'http:' || parsed.username || parsed.password) return null;
    if (parsed.hostname.toLowerCase() === 'www.ch-uten.com' && !parsed.port) {
      return { kind: 'production', origin: parsed.origin };
    }
    if (parsed.hostname === '127.0.0.1' || parsed.hostname === 'localhost' || parsed.hostname === '[::1]') {
      return { kind: 'fixture', origin: parsed.origin };
    }
  } catch {
    return null;
  }
  return null;
}

function legacyUrl(value: unknown, label: string, expectedOrigin: string): string {
  const url = requiredString(value, label);
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new Error(`${label} is not an absolute URL.`);
  }
  const approved = sourceOrigin(parsed.origin);
  if (!approved) throw new Error(`${label} must remain on the legacy origin or loopback fixture.`);
  if (approved.origin !== expectedOrigin) throw new Error(`${label} must use the same origin as catalog.sourceBaseUrl.`);
  return url;
}

function isWithin(parent: string, child: string): boolean {
  const relative = path.relative(parent, child);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

async function safeInputFile(root: string, relativePath: string, label: string): Promise<string> {
  if (path.isAbsolute(relativePath) || relativePath.includes('\0')) {
    throw new Error(`${label} must be a relative path inside the crawler output.`);
  }
  const absolute = path.resolve(root, relativePath);
  if (!isWithin(root, absolute)) throw new Error(`${label} escapes the crawler output directory.`);
  const [realRoot, realFile] = await Promise.all([realpath(root), realpath(absolute)]);
  if (!isWithin(realRoot, realFile)) throw new Error(`${label} resolves outside the crawler output directory.`);
  const metadata = await stat(realFile);
  if (!metadata.isFile()) throw new Error(`${label} is not a regular file.`);
  return realFile;
}

async function mapLimit<T, R>(values: T[], limit: number, mapper: (value: T, index: number) => Promise<R>): Promise<R[]> {
  const results = new Array<R>(values.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, Math.max(values.length, 1)) }, async () => {
    while (true) {
      const index = next;
      next += 1;
      if (index >= values.length) return;
      results[index] = await mapper(values[index], index);
    }
  });
  await Promise.all(workers);
  return results;
}

function detectRaster(header: Buffer): keyof typeof SAFE_RASTER | null {
  if (header.length >= 3 && header[0] === 0xff && header[1] === 0xd8 && header[2] === 0xff) return 'jpeg';
  if (header.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'png';
  const six = header.subarray(0, 6).toString('ascii');
  if (six === 'GIF87a' || six === 'GIF89a') return 'gif';
  if (header.subarray(0, 4).toString('ascii') === 'RIFF' && header.subarray(8, 12).toString('ascii') === 'WEBP') return 'webp';
  // BMP/TIFF source evidence may remain in the crawl bundle, but those
  // formats are never copied into the production uploads namespace.  They
  // require an explicit reviewed decode/re-encode step with a new WebP hash.
  return null;
}

async function atomicWriteJson(filename: string, value: unknown): Promise<void> {
  const absolute = path.resolve(filename);
  await mkdir(path.dirname(absolute), { recursive: true });
  const temporary = `${absolute}.${process.pid}.${Date.now()}.tmp`;
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { encoding: 'utf8', flag: 'wx' });
  await rename(temporary, absolute);
}

function sourceIdentity(entity: 'series' | 'product' | 'variant', sourceId: string): string {
  return `${SOURCE_SYSTEM}:${entity}:${sourceId}`;
}

function safeDate(value: unknown, label: string): Date | null {
  if (value === null || value === undefined || value === '') return null;
  const parsed = new Date(requiredString(value, label));
  if (Number.isNaN(parsed.getTime())) throw new Error(`${label} is not a valid timestamp.`);
  return parsed;
}

function stableNumericSort(left: JsonRecord, right: JsonRecord): number {
  const leftId = String(left.oldSiteId ?? '');
  const rightId = String(right.oldSiteId ?? '');
  const leftNumeric = /^\d+$/.test(leftId) ? Number.parseInt(leftId, 10) : Number.MAX_SAFE_INTEGER;
  const rightNumeric = /^\d+$/.test(rightId) ? Number.parseInt(rightId, 10) : Number.MAX_SAFE_INTEGER;
  return leftNumeric - rightNumeric || leftId.localeCompare(rightId);
}

function fingerprint(products: JsonRecord[], locale: Locale, kind: 'identity' | 'images'): string {
  const lines = products
    .filter((product) => product.locale === locale)
    .sort(stableNumericSort)
    .map((product) => kind === 'identity'
      ? `${String(product.oldSiteId ?? '')}\t${String(product.sortId ?? '')}\t${String(product.sortPath ?? '')}`
      : `${String(product.oldSiteId ?? '')}\t${String(product.thumbnailSourceUrl ?? '')}\t${String(product.mainImageSourceUrl ?? '')}`);
  return sha256Buffer(`${lines.join('\n')}\n`);
}

function localeCounts(items: JsonRecord[]): Record<Locale, number> {
  return {
    zh: items.filter((item) => item.locale === 'zh').length,
    en: items.filter((item) => item.locale === 'en').length,
  };
}

function countAssetUrls(items: JsonRecord[], locale: Locale, productMode: boolean): number {
  const urls = new Set<string>();
  for (const item of items) {
    if (item.locale !== locale) continue;
    const candidates = productMode
      ? [item.thumbnailSourceUrl, item.mainImageSourceUrl, ...array(item.assetUrls ?? [], 'assetUrls')]
      : array(item.assetUrls ?? [], 'assetUrls');
    for (const candidate of candidates) if (typeof candidate === 'string' && candidate) urls.add(candidate);
  }
  return urls.size;
}

function fullBaselineReasons(catalog: JsonRecord, products: JsonRecord[], news: JsonRecord[], pages: JsonRecord[]): string[] {
  const reasons: string[] = [];
  const productCounts = localeCounts(products);
  const detailCounts = {
    zh: products.filter((item) => item.locale === 'zh' && item.detailStatus === 'ok').length,
    en: products.filter((item) => item.locale === 'en' && item.detailStatus === 'ok').length,
  };
  const nonEmpty = {
    zh: products.filter((item) => item.locale === 'zh' && sanitizePlainText(item.descriptionText, Number.MAX_SAFE_INTEGER)).length,
    en: products.filter((item) => item.locale === 'en' && sanitizePlainText(item.descriptionText, Number.MAX_SAFE_INTEGER)).length,
  };
  const leafCounts = {
    zh: new Set(products.filter((item) => item.locale === 'zh').map((item) => item.sortId).filter(Boolean)).size,
    en: new Set(products.filter((item) => item.locale === 'en').map((item) => item.sortId).filter(Boolean)).size,
  };
  const ids = {
    zh: new Set(products.filter((item) => item.locale === 'zh').map((item) => String(item.oldSiteId))),
    en: new Set(products.filter((item) => item.locale === 'en').map((item) => String(item.oldSiteId))),
  };
  const intersection = [...ids.zh].filter((id) => ids.en.has(id)).length;
  const zhOnly = [...ids.zh].filter((id) => !ids.en.has(id)).length;
  const enOnly = [...ids.en].filter((id) => !ids.zh.has(id)).length;
  const progress = isRecord(catalog.scope) && isRecord(catalog.scope.progress) ? catalog.scope.progress : {};

  const compare = (label: string, actual: unknown, expected: unknown) => {
    if (JSON.stringify(actual) !== JSON.stringify(expected)) reasons.push(`${label} does not match the frozen v2 baseline.`);
  };
  compare('product counts', productCounts, FULL_BASELINE.products);
  compare('detail counts', detailCounts, FULL_BASELINE.productDetails);
  compare('leaf category counts', leafCounts, FULL_BASELINE.productLeafSortIds);
  compare('non-empty description counts', nonEmpty, FULL_BASELINE.nonEmptyDescriptions);
  compare('empty description counts', { zh: detailCounts.zh - nonEmpty.zh, en: detailCounts.en - nonEmpty.en }, FULL_BASELINE.emptyDescriptions);
  compare('news counts', localeCounts(news), FULL_BASELINE.news);
  compare('static page counts', localeCounts(pages), FULL_BASELINE.staticPages);
  compare('news asset URL counts', { zh: countAssetUrls(news, 'zh', false), en: countAssetUrls(news, 'en', false) }, FULL_BASELINE.newsAssetUrls);
  compare('product asset URL counts', { zh: countAssetUrls(products, 'zh', true), en: countAssetUrls(products, 'en', true) }, FULL_BASELINE.productAssetUrls);
  compare('product ID language relationship', { intersection, zhOnly, enOnly }, {
    intersection: FULL_BASELINE.productIdIntersection,
    zhOnly: FULL_BASELINE.zhOnlyProductIds,
    enOnly: FULL_BASELINE.enOnlyProductIds,
  });
  compare('zh identity/sort-path fingerprint', fingerprint(products, 'zh', 'identity'), FULL_BASELINE.identitySortPathSha256.zh);
  compare('en identity/sort-path fingerprint', fingerprint(products, 'en', 'identity'), FULL_BASELINE.identitySortPathSha256.en);
  compare('zh image fingerprint', fingerprint(products, 'zh', 'images'), FULL_BASELINE.productImagesSha256.zh);
  compare('en image fingerprint', fingerprint(products, 'en', 'images'), FULL_BASELINE.productImagesSha256.en);
  for (const locale of ['zh', 'en'] as const) {
    const localeProgress = isRecord(progress[locale]) ? progress[locale] : {};
    compare(`${locale} completed product list pages`, localeProgress.productCompleted, FULL_BASELINE.productListPages[locale]);
  }
  return reasons;
}

interface ProvenanceFile {
  rawHtmlPath: string;
  sourceHash: string;
  label: string;
}

function collectProvenance(value: unknown, label: string, found: Map<string, ProvenanceFile>): void {
  if (Array.isArray(value)) {
    value.forEach((item, index) => collectProvenance(item, `${label}[${index}]`, found));
    return;
  }
  if (!isRecord(value)) return;
  if (typeof value.rawHtmlPath === 'string' || typeof value.sourceHash === 'string') {
    const rawHtmlPath = requiredString(value.rawHtmlPath, `${label}.rawHtmlPath`);
    const sourceHash = requiredString(value.sourceHash, `${label}.sourceHash`).toLowerCase();
    if (!/^[a-f0-9]{64}$/.test(sourceHash)) throw new Error(`${label}.sourceHash must be a SHA-256 digest.`);
    found.set(`${rawHtmlPath}\0${sourceHash}`, { rawHtmlPath, sourceHash, label });
  }
  for (const [key, child] of Object.entries(value)) collectProvenance(child, `${label}.${key}`, found);
}

async function verifyProvenance(root: string, catalog: JsonRecord): Promise<number> {
  const found = new Map<string, ProvenanceFile>();
  for (const key of ['categories', 'products', 'news', 'pages'] as const) {
    collectProvenance(catalog[key], `catalog.${key}`, found);
  }
  await mapLimit([...found.values()], 8, async (entry) => {
    const filename = await safeInputFile(root, entry.rawHtmlPath, `${entry.label}.rawHtmlPath`);
    const actual = await sha256File(filename);
    if (actual !== entry.sourceHash) {
      throw new Error(`${entry.label}.rawHtmlPath does not match sourceHash (${actual} != ${entry.sourceHash}).`);
    }
  });
  return found.size;
}

async function verifyCheckpoint(
  root: string,
  checkpoint: JsonRecord,
  expectedBaseUrl: unknown,
  expectedOrigin: string,
): Promise<number> {
  if (checkpoint.checkpointVersion !== 1) throw new Error('checkpoint.json checkpointVersion must be 1.');
  if (checkpoint.baseUrl !== expectedBaseUrl) throw new Error('checkpoint.json baseUrl does not match catalog.sourceBaseUrl.');
  if (!sourceOrigin(checkpoint.baseUrl)) throw new Error('checkpoint.json has an unsafe baseUrl.');
  for (const field of ['fetchErrors', 'parseErrors', 'conflicts'] as const) {
    const diagnostics = isRecord(checkpoint.diagnostics) ? checkpoint.diagnostics : {};
    const issues = array(diagnostics[field] ?? [], `checkpoint.diagnostics.${field}`);
    if (issues.length) throw new Error(`checkpoint.json contains ${issues.length} ${field}.`);
  }
  const refused = array(checkpoint.refusedUrls ?? [], 'checkpoint.refusedUrls');
  if (refused.length) throw new Error(`checkpoint.json contains ${refused.length} refused URL attempts.`);

  const pages = record(checkpoint.pages, 'checkpoint.pages');
  const found = new Map<string, ProvenanceFile>();
  for (const [key, value] of Object.entries(pages)) {
    const page = record(value, `checkpoint.pages[${JSON.stringify(key)}]`);
    if (page.status !== 'ok') throw new Error(`Checkpoint page ${key} is not successful.`);
    legacyUrl(page.sourceUrl, `checkpoint.pages[${JSON.stringify(key)}].sourceUrl`, expectedOrigin);
    collectProvenance(page, `checkpoint.pages[${JSON.stringify(key)}]`, found);
  }
  await mapLimit([...found.values()], 8, async (entry) => {
    const filename = await safeInputFile(root, entry.rawHtmlPath, `${entry.label}.rawHtmlPath`);
    if (await sha256File(filename) !== entry.sourceHash) throw new Error(`${entry.label} does not match sourceHash.`);
  });

  const checkpointMedia = record(checkpoint.media, 'checkpoint.media');
  await mapLimit(Object.entries(checkpointMedia), 8, async ([key, value]) => {
    const item = record(value, `checkpoint.media[${JSON.stringify(key)}]`);
    if (item.status !== 'ok') throw new Error(`Checkpoint media ${key} is not successful.`);
    legacyUrl(item.sourceUrl, `checkpoint.media[${JSON.stringify(key)}].sourceUrl`, expectedOrigin);
    const digest = requiredString(item.sha256, `checkpoint.media[${JSON.stringify(key)}].sha256`).toLowerCase();
    if (!/^[a-f0-9]{64}$/.test(digest)) throw new Error(`Checkpoint media ${key} has an invalid SHA-256.`);
    const filename = await safeInputFile(root, requiredString(item.localPath, `checkpoint.media[${JSON.stringify(key)}].localPath`), `checkpoint media ${key}`);
    if (await sha256File(filename) !== digest) throw new Error(`Checkpoint media ${key} does not match sha256.`);
  });
  return found.size + Object.keys(checkpointMedia).length;
}

async function normalizeMedia(root: string, mediaManifest: JsonRecord, expectedOrigin: string): Promise<NormalizedMedia[]> {
  const assets = array(mediaManifest.assets, 'media.assets').map((item, index) => record(item, `media.assets[${index}]`));
  const seen = new Set<string>();
  return mapLimit(assets, 8, async (asset, index) => {
    const label = `media.assets[${index}]`;
    const digest = requiredString(asset.sha256, `${label}.sha256`).toLowerCase();
    if (!/^[a-f0-9]{64}$/.test(digest)) throw new Error(`${label}.sha256 must be a SHA-256 digest.`);
    if (seen.has(digest)) throw new Error(`${label}.sha256 duplicates ${digest}.`);
    seen.add(digest);
    const sourcePath = requiredString(asset.localPath, `${label}.localPath`);
    const absoluteSourcePath = await safeInputFile(root, sourcePath, `${label}.localPath`);
    const metadata = await stat(absoluteSourcePath);
    const declaredBytes = integer(asset.bytes, `${label}.bytes`);
    if (declaredBytes < 0 || metadata.size !== declaredBytes) {
      throw new Error(`${label}.bytes does not match the media file (${declaredBytes} != ${metadata.size}).`);
    }
    const actual = await sha256File(absoluteSourcePath);
    if (actual !== digest) throw new Error(`${label}.localPath does not match sha256.`);

    const mimeType = requiredString(asset.mimeType, `${label}.mimeType`).toLowerCase();
    const declaredExtension = requiredString(asset.extension, `${label}.extension`).toLowerCase();
    const handle = await open(absoluteSourcePath, 'r');
    const header = Buffer.alloc(16);
    try {
      await handle.read(header, 0, header.length, 0);
    } finally {
      await handle.close();
    }
    const detected = detectRaster(header);
    let publicPath: string | null = null;
    let extension = declaredExtension.startsWith('.') ? declaredExtension : `.${declaredExtension}`;
    if (detected) {
      const definition = SAFE_RASTER[detected];
      if (!definition.mimeTypes.has(mimeType as never)) {
        throw new Error(`${label} declares ${mimeType} but its magic bytes identify ${detected}.`);
      }
      if (!asset.width || !asset.height || integer(asset.width, `${label}.width`) <= 0 || integer(asset.height, `${label}.height`) <= 0) {
        throw new Error(`${label} safe raster image must have positive decoded dimensions.`);
      }
      extension = definition.extension;
      publicPath = `/uploads/legacy-v2/${digest.slice(0, 2)}/${digest}${extension}`;
    } else if (mimeType !== 'image/svg+xml' && mimeType.startsWith('image/')) {
      throw new Error(`${label} claims to be an image but has no approved raster signature.`);
    }

    const sourceUrls = strings(asset.sourceUrls ?? [], `${label}.sourceUrls`).map((url, urlIndex) =>
      legacyUrl(url, `${label}.sourceUrls[${urlIndex}]`, expectedOrigin));
    const sourceRefs = strings(asset.sourceRefs ?? [], `${label}.sourceRefs`);
    return {
      sha256: digest,
      mimeType,
      extension,
      bytes: declaredBytes,
      width: typeof asset.width === 'number' ? asset.width : null,
      height: typeof asset.height === 'number' ? asset.height : null,
      sourcePath,
      absoluteSourcePath,
      publicPath,
      sourceUrls,
      sourceRefs,
    };
  });
}

function topLevelSourceRecord(
  item: JsonRecord,
  label: string,
  entityType: NormalizedSourceRecord['entityType'],
  sourceId: string,
  locale: Locale,
  targetSourceIdentity: string | null,
  expectedOrigin: string,
): NormalizedSourceRecord {
  const sourceUrl = legacyUrl(item.sourceUrl, `${label}.sourceUrl`, expectedOrigin);
  const finalUrl = item.finalUrl ? legacyUrl(item.finalUrl, `${label}.finalUrl`, expectedOrigin) : null;
  const sourceHash = requiredString(item.sourceHash, `${label}.sourceHash`).toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(sourceHash)) throw new Error(`${label}.sourceHash must be a SHA-256 digest.`);
  return {
    entityType,
    sourceId,
    locale,
    identityKey: optionalString(item.identityKey) ?? `${locale}:${sourceId}`,
    sourceUrl,
    finalUrl,
    sourceHash,
    rawHtmlPath: optionalString(item.rawHtmlPath),
    scrapedAt: safeDate(item.scrapedAt, `${label}.scrapedAt`),
    rawPayload: JSON.stringify(item),
    targetSourceIdentity,
  };
}

function publicPathForHash(hash: unknown, mediaByHash: Map<string, NormalizedMedia>, label: string): string | null {
  if (hash === null || hash === undefined || hash === '') return null;
  const digest = requiredString(hash, label).toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(digest)) throw new Error(`${label} must be a SHA-256 digest.`);
  const media = mediaByHash.get(digest);
  if (!media) throw new Error(`${label} references missing media hash ${digest}.`);
  return media.publicPath;
}

function mediaHashes(item: JsonRecord, label: string): string[] {
  return strings(item.mediaSha256 ?? [], `${label}.mediaSha256`).map((digest, index) => {
    const normalized = digest.toLowerCase();
    if (!/^[a-f0-9]{64}$/.test(normalized)) throw new Error(`${label}.mediaSha256[${index}] is not SHA-256.`);
    return normalized;
  });
}

function addUnique<T>(values: T[], value: T | null): void {
  if (value !== null && !values.includes(value)) values.push(value);
}

function variantSourceId(productId: string, variantId: string): string {
  return `${productId}:${variantId}`;
}

function optionalVariantId(item: JsonRecord, label: string): string {
  const candidate = item.sourceVariantId ?? item.legacyVariantId ?? item.oldSiteId;
  const value = requiredString(candidate, `${label}.sourceVariantId`);
  if (!/^[A-Za-z0-9._:-]+$/.test(value)) {
    throw new Error(`${label}.sourceVariantId contains unsafe characters.`);
  }
  return value;
}

function validSwatch(value: unknown, label: string): string | null {
  const swatch = optionalString(value);
  if (swatch && !/^#[0-9a-fA-F]{6}$/.test(swatch)) throw new Error(`${label} must be #RRGGBB or null.`);
  return swatch?.toUpperCase() ?? null;
}

function normalizeCatalog(
  catalog: JsonRecord,
  media: NormalizedMedia[],
  expectedOrigin: string,
): {
  series: NormalizedSeries[];
  products: NormalizedProduct[];
  mediaLinks: NormalizedMediaLink[];
  sourceRecords: NormalizedSourceRecord[];
  duplicateNameGroupsPreserved: number;
  bilingualProducts: number;
  zhOnlyProducts: number;
  enOnlyProducts: number;
  explicitVariants: number;
} {
  const rawCategories = array(catalog.categories, 'catalog.categories').map((item, index) => record(item, `catalog.categories[${index}]`));
  const rawProducts = array(catalog.products, 'catalog.products').map((item, index) => record(item, `catalog.products[${index}]`));
  const rawNews = array(catalog.news, 'catalog.news').map((item, index) => record(item, `catalog.news[${index}]`));
  const rawPages = array(catalog.pages, 'catalog.pages').map((item, index) => record(item, `catalog.pages[${index}]`));
  const mediaByHash = new Map(media.map((item) => [item.sha256, item]));
  const sourceRecords: NormalizedSourceRecord[] = [];
  const useReviewedProductionSeriesContent = expectedOrigin === 'http://www.ch-uten.com';

  const categoryKeys = new Set<string>();
  const categoryGroups = new Map<string, Array<{ item: JsonRecord; locale: Locale; index: number }>>();
  rawCategories.forEach((item, index) => {
    const locale = localeOf(item.locale, `catalog.categories[${index}].locale`);
    const sourceId = numericIdentity(item.sortId, `catalog.categories[${index}].sortId`);
    const key = `${locale}:${sourceId}`;
    if (categoryKeys.has(key)) throw new Error(`Duplicate category identity ${key}.`);
    categoryKeys.add(key);
    const group = categoryGroups.get(sourceId) ?? [];
    group.push({ item, locale, index });
    categoryGroups.set(sourceId, group);
    sourceRecords.push(topLevelSourceRecord(
      item,
      `catalog.categories[${index}]`,
      'series',
      sourceId,
      locale,
      sourceIdentity('series', sourceId),
      expectedOrigin,
    ));
  });

  const series = [...categoryGroups.entries()].map(([sourceId, entries]) => {
    const i18n: Record<string, JsonRecord> = {};
    const contentRepair = useReviewedProductionSeriesContent
      ? legacySeriesContentRepair(sourceId)
      : null;
    for (const entry of entries) {
      const sourceName = sanitizePlainText(entry.item.name, 240);
      if (contentRepair && !contentRepair.allowedSourceNames[entry.locale].includes(sourceName || null)) {
        throw new Error(
          `Category ${entry.locale}:${sourceId} no longer matches the reviewed legacy content evidence; `
          + `found ${JSON.stringify(sourceName)}.`,
        );
      }
      const name = contentRepair?.publicNames[entry.locale] ?? sourceName;
      if (!name) throw new Error(`Category ${entry.locale}:${sourceId} has no usable name.`);
      i18n[entry.locale] = { name };
    }
    if (contentRepair) {
      i18n.zh ??= { name: contentRepair.publicNames.zh };
      i18n.en ??= { name: contentRepair.publicNames.en };
    }
    const preferred = entries.find((entry) => entry.locale === 'zh') ?? entries[0];
    const parentSourceId = preferred.item.parentSortId === null || preferred.item.parentSortId === undefined || preferred.item.parentSortId === ''
      ? null
      : numericIdentity(preferred.item.parentSortId, `category ${preferred.locale}:${sourceId}.parentSortId`);
    return {
      sourceId,
      sourceIdentity: sourceIdentity('series', sourceId),
      code: `legacy-v2-${sourceId}`,
      parentSourceId,
      i18n,
      sortOrder: Number.parseInt(sourceId, 10),
    };
  }).sort((left, right) => left.sortOrder - right.sortOrder);

  for (const item of series) {
    if (item.parentSourceId && !categoryGroups.has(item.parentSourceId)) {
      throw new Error(`Series ${item.sourceId} references missing parent ${item.parentSourceId}.`);
    }
  }

  const productKeys = new Set<string>();
  const productGroups = new Map<string, Array<{ item: JsonRecord; locale: Locale; index: number }>>();
  const names = new Map<string, Set<string>>();
  rawProducts.forEach((item, index) => {
    const label = `catalog.products[${index}]`;
    const locale = localeOf(item.locale, `${label}.locale`);
    const sourceId = numericIdentity(item.oldSiteId, `${label}.oldSiteId`);
    const key = `${locale}:${sourceId}`;
    if (productKeys.has(key)) throw new Error(`Duplicate product identity ${key}; names are never dedupe keys.`);
    productKeys.add(key);
    const sortId = numericIdentity(item.sortId, `${label}.sortId`);
    if (!categoryKeys.has(`${locale}:${sortId}`)) throw new Error(`${key} references missing locale category ${locale}:${sortId}.`);
    const price = record(item.price, `${label}.price`);
    if (price.status !== 'UNSET' || price.amount !== null || price.publicationApproved !== false) {
      throw new Error(`${key} contains a price or price publication approval; import is refused.`);
    }
    legacyUrl(item.sourceUrl, `${label}.sourceUrl`, expectedOrigin);
    if (item.finalUrl) legacyUrl(item.finalUrl, `${label}.finalUrl`, expectedOrigin);
    const group = productGroups.get(sourceId) ?? [];
    group.push({ item, locale, index });
    productGroups.set(sourceId, group);
    const name = sanitizePlainText(item.authoritativeName ?? item.name ?? item.listingName, 240).toLocaleLowerCase(locale === 'zh' ? 'zh-CN' : 'en-US');
    const sameName = names.get(`${locale}:${name}`) ?? new Set<string>();
    sameName.add(sourceId);
    names.set(`${locale}:${name}`, sameName);
    sourceRecords.push(topLevelSourceRecord(
      item,
      label,
      'product',
      sourceId,
      locale,
      sourceIdentity('product', sourceId),
      expectedOrigin,
    ));
  });

  const productIds = {
    zh: new Set(rawProducts.filter((item) => item.locale === 'zh').map((item) => String(item.oldSiteId))),
    en: new Set(rawProducts.filter((item) => item.locale === 'en').map((item) => String(item.oldSiteId))),
  };
  const mediaLinks: NormalizedMediaLink[] = [];
  let explicitVariants = 0;
  const products = [...productGroups.entries()].map(([sourceId, entries]) => {
    const i18n: Record<string, JsonRecord> = {};
    const gallery: string[] = [];
    let image: string | null = null;
    let sortOrder = Number.MAX_SAFE_INTEGER;
    const explicitById = new Map<string, Array<{ item: JsonRecord; locale: Locale; label: string }>>();

    for (const entry of entries.sort((left, right) => left.locale === 'zh' ? -1 : right.locale === 'zh' ? 1 : 0)) {
      const label = `catalog.products[${entry.index}]`;
      const name = sanitizePlainText(entry.item.authoritativeName ?? entry.item.name ?? entry.item.listingName, 240);
      if (!name) throw new Error(`${entry.locale}:${sourceId} has no usable product name.`);
      i18n[entry.locale] = {
        name,
        description: sanitizePlainText(entry.item.descriptionText, 20_000),
      };
      const sequence = entry.item.sequence === null || entry.item.sequence === undefined || entry.item.sequence === ''
        ? Number.parseInt(sourceId, 10)
        : integer(entry.item.sequence, `${label}.sequence`);
      sortOrder = Math.min(sortOrder, sequence);
      const thumbnail = publicPathForHash(entry.item.thumbnailSha256, mediaByHash, `${label}.thumbnailSha256`);
      const main = publicPathForHash(entry.item.mainImageSha256, mediaByHash, `${label}.mainImageSha256`);
      addUnique(gallery, main);
      addUnique(gallery, thumbnail);
      if (!image) image = main ?? thumbnail;
      for (const digest of mediaHashes(entry.item, label)) addUnique(gallery, publicPathForHash(digest, mediaByHash, `${label}.mediaSha256`));

      const link = (digestValue: unknown, role: NormalizedMediaLink['role'], sourceUrlValue: unknown, order: number) => {
        if (!digestValue) return;
        const digest = requiredString(digestValue, `${label}.${role}Sha256`).toLowerCase();
        const asset = mediaByHash.get(digest);
        if (!asset) throw new Error(`${label}.${role}Sha256 references missing media ${digest}.`);
        if (!asset.publicPath) return;
        mediaLinks.push({
          productSourceIdentity: sourceIdentity('product', sourceId),
          variantSourceIdentity: null,
          assetSha256: digest,
          role,
          locale: entry.locale,
          sourceUrl: sourceUrlValue ? legacyUrl(sourceUrlValue, `${label}.${role}SourceUrl`, expectedOrigin) : null,
          sortOrder: order,
        });
      };
      link(entry.item.thumbnailSha256, 'thumbnail', entry.item.thumbnailSourceUrl, 0);
      link(entry.item.mainImageSha256, 'main', entry.item.mainImageSourceUrl, 0);
      mediaHashes(entry.item, label).forEach((digest, index) => link(digest, 'gallery', null, index));

      const rawVariants = entry.item.variants === undefined ? [] : array(entry.item.variants, `${label}.variants`);
      rawVariants.forEach((rawVariant, variantIndex) => {
        const variant = record(rawVariant, `${label}.variants[${variantIndex}]`);
        const variantLabel = `${label}.variants[${variantIndex}]`;
        const localId = optionalVariantId(variant, variantLabel);
        const compositeId = variantSourceId(sourceId, localId);
        const group = explicitById.get(compositeId) ?? [];
        if (group.some((candidate) => candidate.locale === entry.locale)) {
          throw new Error(`${variantLabel} duplicates stable variant identity ${entry.locale}:${compositeId}.`);
        }
        group.push({ item: variant, locale: entry.locale, label: variantLabel });
        explicitById.set(compositeId, group);
      });
    }

    const variants: NormalizedVariant[] = [];
    if (explicitById.size === 0) {
      const baseId = variantSourceId(sourceId, 'base');
      variants.push({
        sourceId: baseId,
        sourceIdentity: sourceIdentity('variant', baseId),
        i18n: Object.fromEntries(Object.entries(i18n).map(([locale, value]) => [locale, { name: value.name }])),
        sku: null,
        swatchHex: null,
        image,
        gallery: [...gallery],
        finish: null,
        widthMm: null,
        heightMm: null,
        depthMm: null,
        sortOrder: 0,
        explicit: false,
      });
      for (const link of mediaLinks) {
        if (link.productSourceIdentity === sourceIdentity('product', sourceId) && !link.variantSourceIdentity) {
          link.variantSourceIdentity = sourceIdentity('variant', baseId);
        }
      }
    } else {
      for (const [compositeId, variantsForLocale] of explicitById) {
        explicitVariants += 1;
        const variantI18n: Record<string, JsonRecord> = {};
        const variantGallery: string[] = [];
        let variantImage: string | null = null;
        const first = variantsForLocale[0]?.item;
        variantsForLocale.forEach((entry, index) => {
          const name = sanitizePlainText(entry.item.name ?? entry.item.colorName ?? entry.item.materialName, 240);
          if (!name) throw new Error(`${entry.label} has no usable name/color/material label.`);
          variantI18n[entry.locale] = {
            name,
            ...(sanitizePlainText(entry.item.colorName, 120) ? { colorName: sanitizePlainText(entry.item.colorName, 120) } : {}),
            ...(sanitizePlainText(entry.item.materialName, 120) ? { materialName: sanitizePlainText(entry.item.materialName, 120) } : {}),
          };
          const mainDigest = entry.item.imageSha256 ?? entry.item.mainImageSha256;
          const mainPath = publicPathForHash(mainDigest, mediaByHash, `${entry.label}.imageSha256`);
          addUnique(variantGallery, mainPath);
          if (!variantImage) variantImage = mainPath;
          const digests = strings(entry.item.gallerySha256 ?? entry.item.mediaSha256 ?? [], `${entry.label}.gallerySha256`);
          digests.forEach((digestValue, mediaIndex) => {
            const digest = digestValue.toLowerCase();
            addUnique(variantGallery, publicPathForHash(digest, mediaByHash, `${entry.label}.gallerySha256[${mediaIndex}]`));
            const asset = mediaByHash.get(digest);
            if (asset?.publicPath) mediaLinks.push({
              productSourceIdentity: sourceIdentity('product', sourceId),
              variantSourceIdentity: sourceIdentity('variant', compositeId),
              assetSha256: digest,
              role: 'gallery',
              locale: entry.locale,
              sourceUrl: null,
              sortOrder: mediaIndex,
            });
          });
          if (mainDigest) {
            const digest = requiredString(mainDigest, `${entry.label}.imageSha256`).toLowerCase();
            const asset = mediaByHash.get(digest);
            if (asset?.publicPath) mediaLinks.push({
              productSourceIdentity: sourceIdentity('product', sourceId),
              variantSourceIdentity: sourceIdentity('variant', compositeId),
              assetSha256: digest,
              role: 'main',
              locale: entry.locale,
              sourceUrl: entry.item.imageSourceUrl || entry.item.mainImageSourceUrl
                ? legacyUrl(
                  entry.item.imageSourceUrl ?? entry.item.mainImageSourceUrl,
                  `${entry.label}.imageSourceUrl`,
                  expectedOrigin,
                )
                : null,
              sortOrder: 0,
            });
          }
          sourceRecords.push(topLevelSourceRecord(
            { ...entries.find((productEntry) => productEntry.locale === entry.locale)?.item, ...entry.item },
            entry.label,
            'variant',
            compositeId,
            entry.locale,
            sourceIdentity('variant', compositeId),
            expectedOrigin,
          ));
        });
        if (!first) throw new Error(`Variant group ${compositeId} is empty.`);
        variants.push({
          sourceId: compositeId,
          sourceIdentity: sourceIdentity('variant', compositeId),
          i18n: variantI18n,
          sku: optionalString(first.sku),
          swatchHex: validSwatch(first.swatchHex, `variant ${compositeId}.swatchHex`),
          image: variantImage,
          gallery: variantGallery,
          finish: sanitizePlainText(first.finish, 240) || null,
          widthMm: nonNegativeNumber(first.widthMm, `variant ${compositeId}.widthMm`),
          heightMm: nonNegativeNumber(first.heightMm, `variant ${compositeId}.heightMm`),
          depthMm: nonNegativeNumber(first.depthMm, `variant ${compositeId}.depthMm`),
          sortOrder: first.sortOrder === undefined ? variants.length : integer(first.sortOrder, `variant ${compositeId}.sortOrder`),
          explicit: true,
        });
      }
    }

    const preferred = entries.find((entry) => entry.locale === 'zh') ?? entries[0];
    const seriesSourceId = numericIdentity(preferred.item.sortId, `product ${sourceId}.sortId`);
    return {
      sourceId,
      sourceIdentity: sourceIdentity('product', sourceId),
      slug: `legacy-v2-${sourceId}`,
      seriesSourceId,
      category: `${SOURCE_SYSTEM}:series:${seriesSourceId}`,
      i18n,
      image,
      gallery,
      sortOrder: sortOrder === Number.MAX_SAFE_INTEGER ? Number.parseInt(sourceId, 10) : sortOrder,
      variants,
    };
  }).sort((left, right) => Number.parseInt(left.sourceId, 10) - Number.parseInt(right.sourceId, 10));

  rawNews.forEach((item, index) => {
    const locale = localeOf(item.locale, `catalog.news[${index}].locale`);
    const id = numericIdentity(item.oldSiteId, `catalog.news[${index}].oldSiteId`);
    sourceRecords.push(topLevelSourceRecord(item, `catalog.news[${index}]`, 'news', id, locale, null, expectedOrigin));
  });
  rawPages.forEach((item, index) => {
    const locale = localeOf(item.locale, `catalog.pages[${index}].locale`);
    const id = optionalString(item.key) ?? sha256Buffer(requiredString(item.sourceUrl, `catalog.pages[${index}].sourceUrl`)).slice(0, 24);
    sourceRecords.push(topLevelSourceRecord(item, `catalog.pages[${index}]`, 'page', id, locale, null, expectedOrigin));
  });

  const sourceRecordKeys = new Set<string>();
  for (const source of sourceRecords) {
    const key = `${source.entityType}:${source.locale}:${source.sourceId}`;
    if (sourceRecordKeys.has(key)) throw new Error(`Duplicate provenance record ${key}.`);
    sourceRecordKeys.add(key);
  }

  return {
    series,
    products,
    mediaLinks,
    sourceRecords,
    duplicateNameGroupsPreserved: [...names.values()].filter((ids) => ids.size > 1).length,
    bilingualProducts: [...productIds.zh].filter((id) => productIds.en.has(id)).length,
    zhOnlyProducts: [...productIds.zh].filter((id) => !productIds.en.has(id)).length,
    enOnlyProducts: [...productIds.en].filter((id) => !productIds.zh.has(id)).length,
    explicitVariants,
  };
}

export async function prepareLegacyV2Input(inputRoot: string): Promise<PreparedLegacyImport> {
  const root = path.resolve(inputRoot);
  const metadata = await stat(root);
  if (!metadata.isDirectory()) throw new Error(`Crawler output is not a directory: ${root}`);
  const catalogFile = path.join(root, 'catalog.json');
  const mediaFile = path.join(root, 'media.json');
  const qaFile = path.join(root, 'qa-report.json');
  const checkpointFile = path.join(root, 'checkpoint.json');
  const [catalogInput, mediaInput, qaInput, checkpointInput] = await Promise.all([
    readJsonFile(catalogFile, 'catalog.json'),
    readJsonFile(mediaFile, 'media.json'),
    readJsonFile(qaFile, 'qa-report.json'),
    readJsonFile(checkpointFile, 'checkpoint.json'),
  ]);
  const catalog = catalogInput.value;
  const mediaManifest = mediaInput.value;
  const qaReport = qaInput.value;
  const checkpoint = checkpointInput.value;
  const checks: ImportCheck[] = [];

  const schemaMatches = catalog.schemaVersion === SOURCE_SCHEMA_VERSION
    && mediaManifest.schemaVersion === SOURCE_SCHEMA_VERSION
    && qaReport.schemaVersion === SOURCE_SCHEMA_VERSION;
  check(checks, 'schema-version', schemaMatches, 'catalog.json, media.json and qa-report.json use the supported v2 schema.', {
    actual: [catalog.schemaVersion, mediaManifest.schemaVersion, qaReport.schemaVersion],
    expected: SOURCE_SCHEMA_VERSION,
  });
  if (!schemaMatches) throw new Error('Crawler output schema versions do not match uten-legacy-catalog/v2.');
  const approvedOrigin = sourceOrigin(catalog.sourceBaseUrl);
  const originKind = approvedOrigin?.kind ?? null;
  check(
    checks,
    'source-origin',
    originKind !== null,
    'The catalog is bound to the approved legacy origin or a loopback-only fixture.',
    { actual: catalog.sourceBaseUrl, expected: 'http://www.ch-uten.com/ or loopback fixture' },
  );
  if (!approvedOrigin) throw new Error('Unexpected crawler sourceBaseUrl.');
  if (mediaManifest.sourceBaseUrl !== catalog.sourceBaseUrl) {
    throw new Error('media.json sourceBaseUrl does not match catalog.sourceBaseUrl.');
  }

  const [provenanceFileCount, checkpointFileCount, normalizedMedia] = await Promise.all([
    verifyProvenance(root, catalog),
    verifyCheckpoint(root, checkpoint, catalog.sourceBaseUrl, approvedOrigin.origin),
    normalizeMedia(root, mediaManifest, approvedOrigin.origin),
  ]);
  check(checks, 'source-provenance-files', true, 'Every catalog provenance path stays inside the output and matches its SHA-256.', {
    actual: { catalogFiles: provenanceFileCount, checkpointFiles: checkpointFileCount },
  });
  check(checks, 'media-integrity', true, 'Every media file stays inside the output and matches manifest bytes, hash and raster magic.', {
    actual: normalizedMedia.length,
  });

  const normalized = normalizeCatalog(catalog, normalizedMedia, approvedOrigin.origin);
  check(checks, 'stable-source-identity', true, 'Products and categories are unique by locale plus numeric legacy ID; names were not used for identity.', {
    actual: {
      productRecords: array(catalog.products, 'catalog.products').length,
      canonicalProducts: normalized.products.length,
      duplicateNameGroupsPreserved: normalized.duplicateNameGroupsPreserved,
    },
  });
  check(checks, 'prices-remain-unset', true, 'No amount or publishable price enters the CMS import model.');
  check(checks, 'raw-html-isolation', true, 'Only sanitized descriptionText reaches product i18n; raw payloads are audit-only and publishable=false.');

  const qaStatus = requiredString(qaReport.status, 'qa-report.status');
  const expectFull = qaReport.expectFull === true;
  check(checks, 'crawler-qa-status', qaStatus === 'pass', 'Crawler QA status must be pass even for an inspect-only dry-run.', {
    actual: qaStatus,
    expected: 'pass',
  });
  const mediaFailures = array(mediaManifest.failures ?? [], 'media.failures');
  if (mediaFailures.length) {
    check(checks, 'media-failures', false, 'Crawler media failures make the input unusable.', { actual: mediaFailures.length });
  }

  const gateReasons: string[] = [];
  if (qaStatus !== 'pass') gateReasons.push('qa-report.json status is not pass.');
  if (!expectFull) gateReasons.push('qa-report.json expectFull is false; partial/fixture output is inspect-only.');
  if (originKind !== 'production') gateReasons.push('loopback fixture output is never eligible for apply.');
  const scope = record(catalog.scope, 'catalog.scope');
  if (scope.fullRequested !== true) gateReasons.push('catalog.scope.fullRequested is not true.');
  if (scope.downloadMedia !== true) gateReasons.push('catalog.scope.downloadMedia is not true.');
  if (mediaFailures.length) gateReasons.push('media.json contains failed assets.');
  const diagnosticFields = ['fetchErrors', 'parseErrors', 'conflicts'] as const;
  for (const field of diagnosticFields) {
    const issues = array(qaReport[field] ?? [], `qa-report.${field}`);
    if (issues.length) gateReasons.push(`qa-report.json contains ${issues.length} ${field}.`);
  }
  const qaChecks = array(qaReport.checks, 'qa-report.checks').map((item, index) => record(item, `qa-report.checks[${index}]`));
  const qaCheckIds = qaChecks.map((item, index) => requiredString(item.id, `qa-report.checks[${index}].id`));
  const duplicateQaIds = qaCheckIds.filter((id, index) => qaCheckIds.indexOf(id) !== index);
  const failedQaChecks = qaChecks.filter((item) => item.status !== 'pass').map((item) => String(item.id));
  check(checks, 'qa-check-consistency', duplicateQaIds.length === 0 && (qaStatus !== 'pass' || failedQaChecks.length === 0),
    'QA check IDs are unique and a pass report contains no failed child checks.', {
      actual: { duplicateQaIds: [...new Set(duplicateQaIds)], failedQaChecks },
    });
  if (duplicateQaIds.length) gateReasons.push('qa-report.json contains duplicate check IDs.');
  if (qaStatus === 'pass' && failedQaChecks.length) gateReasons.push('qa-report.json says pass but contains failed child checks.');
  if (expectFull) {
    const qaById = new Map(qaChecks.map((item) => [String(item.id), item]));
    for (const id of REQUIRED_FULL_QA_CHECKS) {
      if (qaById.get(id)?.status !== 'pass') gateReasons.push(`required crawler QA check ${id} is missing or not pass.`);
    }
    gateReasons.push(...fullBaselineReasons(
      catalog,
      array(catalog.products, 'catalog.products').map((item, index) => record(item, `catalog.products[${index}]`)),
      array(catalog.news, 'catalog.news').map((item, index) => record(item, `catalog.news[${index}]`)),
      array(catalog.pages, 'catalog.pages').map((item, index) => record(item, `catalog.pages[${index}]`)),
    ));
  }

  const catalogSha256 = sha256Buffer(catalogInput.raw);
  const mediaSha256 = sha256Buffer(mediaInput.raw);
  const qaReportSha256 = sha256Buffer(qaInput.raw);
  const checkpointSha256 = sha256Buffer(checkpointInput.raw);
  const bundleSha256 = sha256Buffer(
    `${SOURCE_SCHEMA_VERSION}\n${catalogSha256}\n${mediaSha256}\n${qaReportSha256}\n${checkpointSha256}\n`,
  );
  const sourceProductRecords = array(catalog.products, 'catalog.products').length;
  const sourceCategoryRecords = array(catalog.categories, 'catalog.categories').length;
  const summary: ImportSummary = {
    localizedProductRecords: sourceProductRecords,
    canonicalProducts: normalized.products.length,
    bilingualProducts: normalized.bilingualProducts,
    zhOnlyProducts: normalized.zhOnlyProducts,
    enOnlyProducts: normalized.enOnlyProducts,
    duplicateNameGroupsPreserved: normalized.duplicateNameGroupsPreserved,
    localizedCategoryRecords: sourceCategoryRecords,
    canonicalSeries: normalized.series.length,
    variants: normalized.products.reduce((total, item) => total + item.variants.length, 0),
    explicitVariants: normalized.explicitVariants,
    mediaAssets: normalizedMedia.length,
    publicRasterAssets: normalizedMedia.filter((item) => item.publicPath).length,
    unpublishableRawRecords: normalized.sourceRecords.length,
  };
  const status: CheckStatus = checks.some((item) => item.status === 'fail' && item.severity === 'error') ? 'fail' : 'pass';
  if (status !== 'pass') gateReasons.unshift('one or more importer integrity checks failed.');
  const plan: LegacyImportPlan = {
    schemaVersion: IMPORT_PLAN_SCHEMA_VERSION,
    mode: 'dry-run',
    createdAt: new Date().toISOString(),
    inputRoot: root,
    sourceSchemaVersion: SOURCE_SCHEMA_VERSION,
    digests: { catalogSha256, mediaSha256, qaReportSha256, checkpointSha256, bundleSha256 },
    status,
    qa: { status: qaStatus, expectFull },
    applyGate: { eligible: status === 'pass' && gateReasons.length === 0, reasons: [...new Set(gateReasons)] },
    summary,
    checks,
  };
  return {
    inputRoot: root,
    plan,
    series: normalized.series,
    products: normalized.products,
    media: normalizedMedia,
    mediaLinks: normalized.mediaLinks,
    sourceRecords: normalized.sourceRecords,
  };
}

export async function dryRunLegacyV2(inputRoot: string, reportPath?: string): Promise<LegacyImportPlan> {
  const prepared = await prepareLegacyV2Input(inputRoot);
  if (reportPath) await atomicWriteJson(reportPath, prepared.plan);
  return prepared.plan;
}

function sqliteUrl(databasePath: string): string {
  return `file:${path.resolve(databasePath).replaceAll('\\', '/')}`;
}

function parseI18n(value: string): Record<string, JsonRecord> {
  try {
    const parsed = JSON.parse(value);
    if (!isRecord(parsed)) return {};
    return Object.fromEntries(Object.entries(parsed).filter((entry): entry is [string, JsonRecord] => isRecord(entry[1])));
  } catch {
    return {};
  }
}

function mergeI18n(existing: string, incoming: Record<string, JsonRecord>): string {
  const merged = parseI18n(existing);
  for (const [locale, fields] of Object.entries(incoming)) {
    const current = merged[locale] ?? {};
    merged[locale] = { ...fields, ...current };
  }
  return JSON.stringify(merged);
}

function mergeJsonStringArray(existing: string, incoming: string[]): string {
  let current: string[] = [];
  try {
    const parsed = JSON.parse(existing);
    if (Array.isArray(parsed)) current = parsed.filter((item): item is string => typeof item === 'string');
  } catch {
    current = [];
  }
  return JSON.stringify([...new Set([...current, ...incoming])]);
}

function mediaLinkId(link: NormalizedMediaLink): string {
  return `pm-${sha256Buffer([
    link.productSourceIdentity,
    link.variantSourceIdentity ?? '',
    link.assetSha256,
    link.role,
    link.locale,
    String(link.sortOrder),
  ].join('\0'))}`;
}

async function createBackup(client: PrismaClient, databasePath: string, backupDir: string, bundleSha256: string): Promise<string> {
  const absoluteDatabase = path.resolve(databasePath);
  await access(absoluteDatabase);
  const absoluteBackupDir = path.resolve(backupDir);
  await mkdir(absoluteBackupDir, { recursive: true });
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const backupPath = path.join(
    absoluteBackupDir,
    `${path.basename(absoluteDatabase)}.${timestamp}.${bundleSha256.slice(0, 12)}.${randomUUID().slice(0, 8)}.sqlite`,
  );
  const escaped = backupPath.replaceAll('\\', '/').replaceAll("'", "''");
  await client.$executeRawUnsafe(`VACUUM INTO '${escaped}'`);
  const backupMetadata = await stat(backupPath);
  if (!backupMetadata.isFile() || backupMetadata.size === 0) throw new Error(`SQLite backup was not created correctly: ${backupPath}`);
  return backupPath;
}

async function copyPublicMedia(media: NormalizedMedia[], publicDir: string): Promise<string[]> {
  const absolutePublic = path.resolve(publicDir);
  await mkdir(absolutePublic, { recursive: true });
  const realPublic = await realpath(absolutePublic);
  const created: string[] = [];
  const errors: Error[] = [];
  const verifyExisting = async (filename: string, item: NormalizedMedia) => {
    const existing = await lstat(filename);
    if (!existing.isFile() || existing.isSymbolicLink()) {
      throw new Error(`Refusing an existing non-regular or symlinked media path: ${filename}`);
    }
    const actual = await sha256File(filename);
    if (actual !== item.sha256) throw new Error(`Refusing to overwrite hash path with different content: ${filename}`);
  };
  await mapLimit(media.filter((item) => item.publicPath), 8, async (item) => {
    try {
      const relative = requiredString(item.publicPath, `media ${item.sha256}.publicPath`).replace(/^\/+/, '').split('/').join(path.sep);
      const destination = path.resolve(absolutePublic, relative);
      if (!isWithin(absolutePublic, destination)) throw new Error(`Generated public media path escaped public/: ${destination}`);
      await mkdir(path.dirname(destination), { recursive: true });
      const realDirectory = await realpath(path.dirname(destination));
      if (!isWithin(realPublic, realDirectory)) throw new Error(`A symlink makes the media destination escape public/: ${destination}`);
      const safeDestination = path.join(realDirectory, path.basename(destination));
      try {
        await verifyExisting(safeDestination, item);
        return;
      } catch (error) {
        const code = isRecord(error) ? error.code : undefined;
        if (code !== 'ENOENT') throw error;
      }

      const temporary = path.join(realDirectory, `.${item.sha256}.${process.pid}.${randomUUID()}.tmp`);
      try {
        await copyFile(item.absoluteSourcePath, temporary, fsConstants.COPYFILE_EXCL);
        const copied = await stat(temporary);
        const copiedHash = await sha256File(temporary);
        if (copied.size !== item.bytes || copiedHash !== item.sha256) {
          throw new Error(`Media source changed after dry-run for ${item.sha256}; copied bytes were not published.`);
        }
        try {
          await link(temporary, safeDestination);
          created.push(safeDestination);
        } catch (error) {
          const code = isRecord(error) ? error.code : undefined;
          if (code !== 'EEXIST') throw error;
          await verifyExisting(safeDestination, item);
        }
      } finally {
        await unlink(temporary).catch((error) => {
          const code = isRecord(error) ? error.code : undefined;
          if (code !== 'ENOENT') throw error;
        });
      }
    } catch (error) {
      errors.push(error instanceof Error ? error : new Error(String(error)));
    }
  });
  if (errors.length) {
    await cleanupCreatedMedia(created);
    const details = errors.map((error) => error.message).join('; ');
    throw new AggregateError(
      errors,
      `Failed to verify/copy ${errors.length} public media asset(s): ${details}`,
    );
  }
  return created;
}

async function cleanupCreatedMedia(files: string[]): Promise<void> {
  await Promise.all(files.map(async (filename) => {
    try {
      await unlink(filename);
    } catch (error) {
      const code = isRecord(error) ? error.code : undefined;
      if (code !== 'ENOENT') throw error;
    }
  }));
}

function assertExistingLegacyIdentity(
  entity: string,
  identity: { legacySource: string | null; legacyId: string | null },
  expectedId: string,
): void {
  if (identity.legacySource && identity.legacySource !== SOURCE_SYSTEM) {
    throw new Error(`${entity} has conflicting legacySource ${identity.legacySource}; expected ${SOURCE_SYSTEM}.`);
  }
  if (identity.legacyId && identity.legacyId !== expectedId) {
    throw new Error(`${entity} has conflicting legacyId ${identity.legacyId}; expected ${expectedId}.`);
  }
}

async function importTransaction(
  client: PrismaClient,
  prepared: PreparedLegacyImport,
  backupPath: string,
): Promise<string> {
  const runId = `import-${prepared.plan.digests.bundleSha256}`;
  await client.$transaction(async (tx) => {
    await tx.legacyImportRun.create({
      data: {
        id: runId,
        sourceSystem: SOURCE_SYSTEM,
        schemaVersion: SOURCE_SCHEMA_VERSION,
        catalogSha256: prepared.plan.digests.catalogSha256,
        mediaSha256: prepared.plan.digests.mediaSha256,
        qaReportSha256: prepared.plan.digests.qaReportSha256,
        checkpointSha256: prepared.plan.digests.checkpointSha256,
        bundleSha256: prepared.plan.digests.bundleSha256,
        qaStatus: prepared.plan.qa.status,
        expectFull: prepared.plan.qa.expectFull,
        inputRoot: prepared.inputRoot,
        backupPath,
        stats: JSON.stringify(prepared.plan.summary),
      },
    });

    const assetIds = new Map<string, string>();
    for (const item of prepared.media) {
      if (item.publicPath) {
        const ledger = await tx.websiteMediaObject.findUnique({ where: { publicPath: item.publicPath } });
        if (ledger && (
          ledger.authorityId !== 'production'
          || ledger.sha256 !== item.sha256
          || ledger.sizeBytes !== item.bytes
          || ledger.state !== 'COMMITTED'
        )) {
          throw new Error(`Existing website media ledger disagrees with imported bytes ${item.publicPath}.`);
        }
        if (!ledger) {
          await tx.websiteMediaObject.create({
            data: {
              publicPath: item.publicPath,
              authorityId: 'production',
              sha256: item.sha256,
              sizeBytes: item.bytes,
              state: 'COMMITTED',
            },
          });
        }
      }
      const existing = await tx.legacyMediaAsset.findUnique({ where: { sha256: item.sha256 } });
      if (existing) {
        if (existing.bytes !== item.bytes || existing.mimeType !== item.mimeType || existing.extension !== item.extension) {
          throw new Error(`Existing media metadata disagrees with immutable hash ${item.sha256}.`);
        }
        if (existing.publicPath && existing.publicPath !== item.publicPath) {
          throw new Error(`Existing public media path disagrees with canonical hash path for ${item.sha256}.`);
        }
        const updated = await tx.legacyMediaAsset.update({
          where: { id: existing.id },
          data: {
            width: existing.width ?? item.width,
            height: existing.height ?? item.height,
            publicPath: existing.publicPath ?? item.publicPath,
            sourceUrls: mergeJsonStringArray(existing.sourceUrls, item.sourceUrls),
            sourceRefs: mergeJsonStringArray(existing.sourceRefs, item.sourceRefs),
          },
        });
        assetIds.set(item.sha256, updated.id);
      } else {
        const created = await tx.legacyMediaAsset.create({
          data: {
            sha256: item.sha256,
            mimeType: item.mimeType,
            extension: item.extension,
            bytes: item.bytes,
            width: item.width,
            height: item.height,
            sourcePath: item.sourcePath,
            publicPath: item.publicPath,
            sourceUrls: JSON.stringify(item.sourceUrls),
            sourceRefs: JSON.stringify(item.sourceRefs),
          },
        });
        assetIds.set(item.sha256, created.id);
      }
    }

    const seriesIds = new Map<string, { id: string; parentId: string | null }>();
    for (const item of prepared.series) {
      const existing = await tx.series.findUnique({ where: { sourceIdentity: item.sourceIdentity } });
      if (existing) {
        assertExistingLegacyIdentity(`Series ${item.sourceIdentity}`, existing, item.sourceId);
        const updated = await tx.series.update({
          where: { id: existing.id },
          data: {
            i18n: mergeI18n(existing.i18n, item.i18n),
            legacySource: existing.legacySource ?? SOURCE_SYSTEM,
            legacyId: existing.legacyId ?? item.sourceId,
          },
        });
        seriesIds.set(item.sourceIdentity, { id: updated.id, parentId: updated.parentId });
      } else {
        const codeCollision = await tx.series.findUnique({ where: { code: item.code } });
        if (codeCollision) {
          throw new Error(`Series code ${item.code} belongs to a non-matching record; name-based merging is forbidden.`);
        }
        const created = await tx.series.create({
          data: {
            code: item.code,
            i18n: JSON.stringify(item.i18n),
            sortOrder: item.sortOrder,
            published: false,
            sourceIdentity: item.sourceIdentity,
            legacySource: SOURCE_SYSTEM,
            legacyId: item.sourceId,
          },
        });
        seriesIds.set(item.sourceIdentity, { id: created.id, parentId: created.parentId });
      }
    }
    for (const item of prepared.series) {
      if (!item.parentSourceId) continue;
      const current = seriesIds.get(item.sourceIdentity);
      const parent = seriesIds.get(sourceIdentity('series', item.parentSourceId));
      if (!current || !parent) throw new Error(`Could not resolve series hierarchy for ${item.sourceId}.`);
      if (!current.parentId) {
        await tx.series.update({ where: { id: current.id }, data: { parentId: parent.id } });
        current.parentId = parent.id;
      }
    }

    const productIds = new Map<string, string>();
    for (const item of prepared.products) {
      const seriesId = item.seriesSourceId ? seriesIds.get(sourceIdentity('series', item.seriesSourceId))?.id ?? null : null;
      const existing = await tx.product.findUnique({ where: { sourceIdentity: item.sourceIdentity } });
      if (existing) {
        assertExistingLegacyIdentity(`Product ${item.sourceIdentity}`, existing, item.sourceId);
        const updated = await tx.product.update({
          where: { id: existing.id },
          data: {
            i18n: mergeI18n(existing.i18n, item.i18n),
            seriesId: existing.seriesId ?? seriesId,
            category: existing.category ?? item.category,
            image: existing.image ?? item.image,
            gallery: existing.gallery ? mergeJsonStringArray(existing.gallery, item.gallery) : JSON.stringify(item.gallery),
            legacySource: existing.legacySource ?? SOURCE_SYSTEM,
            legacyId: existing.legacyId ?? item.sourceId,
          },
        });
        productIds.set(item.sourceIdentity, updated.id);
      } else {
        const slugCollision = await tx.product.findUnique({ where: { slug: item.slug } });
        if (slugCollision) {
          throw new Error(`Product slug ${item.slug} belongs to a non-matching record; name-based merging is forbidden.`);
        }
        const created = await tx.product.create({
          data: {
            slug: item.slug,
            seriesId,
            model: null,
            category: item.category,
            image: item.image,
            gallery: JSON.stringify(item.gallery),
            specs: null,
            i18n: JSON.stringify(item.i18n),
            minOrderQty: null,
            sceneEnabled: false,
            featured: false,
            sortOrder: item.sortOrder,
            published: false,
            sourceIdentity: item.sourceIdentity,
            legacySource: SOURCE_SYSTEM,
            legacyId: item.sourceId,
          },
        });
        productIds.set(item.sourceIdentity, created.id);
      }
    }

    const variantIds = new Map<string, string>();
    for (const product of prepared.products) {
      const productId = productIds.get(product.sourceIdentity);
      if (!productId) throw new Error(`Could not resolve product ${product.sourceIdentity}.`);
      for (const item of product.variants) {
        const existing = await tx.productVariant.findUnique({ where: { sourceIdentity: item.sourceIdentity } });
        if (existing) {
          if (existing.productId !== productId) throw new Error(`Variant ${item.sourceIdentity} is attached to another product.`);
          assertExistingLegacyIdentity(`Variant ${item.sourceIdentity}`, existing, item.sourceId);
          const updated = await tx.productVariant.update({
            where: { id: existing.id },
            data: {
              i18n: mergeI18n(existing.i18n, item.i18n),
              sku: existing.sku ?? item.sku,
              swatchHex: existing.swatchHex ?? item.swatchHex,
              image: existing.image ?? item.image,
              gallery: existing.gallery ? mergeJsonStringArray(existing.gallery, item.gallery) : JSON.stringify(item.gallery),
              finish: existing.finish ?? item.finish,
              widthMm: existing.widthMm ?? item.widthMm,
              heightMm: existing.heightMm ?? item.heightMm,
              depthMm: existing.depthMm ?? item.depthMm,
              legacySource: existing.legacySource ?? SOURCE_SYSTEM,
              legacyId: existing.legacyId ?? item.sourceId,
            },
          });
          variantIds.set(item.sourceIdentity, updated.id);
        } else {
          const created = await tx.productVariant.create({
            data: {
              productId,
              sku: item.sku,
              i18n: JSON.stringify(item.i18n),
              swatchHex: item.swatchHex,
              image: item.image,
              gallery: JSON.stringify(item.gallery),
              finish: item.finish,
              widthMm: item.widthMm,
              heightMm: item.heightMm,
              depthMm: item.depthMm,
              published: false,
              sortOrder: item.sortOrder,
              sourceIdentity: item.sourceIdentity,
              legacySource: SOURCE_SYSTEM,
              legacyId: item.sourceId,
            },
          });
          variantIds.set(item.sourceIdentity, created.id);
        }
      }
    }

    for (const link of prepared.mediaLinks) {
      const productId = productIds.get(link.productSourceIdentity);
      const variantId = link.variantSourceIdentity ? variantIds.get(link.variantSourceIdentity) ?? null : null;
      const assetId = assetIds.get(link.assetSha256);
      if (!productId || !assetId) throw new Error(`Could not resolve product/media link ${mediaLinkId(link)}.`);
      if (link.variantSourceIdentity && !variantId) throw new Error(`Could not resolve variant ${link.variantSourceIdentity}.`);
      await tx.productMedia.upsert({
        where: { id: mediaLinkId(link) },
        update: { sourceUrl: link.sourceUrl },
        create: {
          id: mediaLinkId(link),
          productId,
          variantId,
          assetId,
          role: link.role,
          locale: link.locale,
          sourceUrl: link.sourceUrl,
          sortOrder: link.sortOrder,
        },
      });
    }

    const sourceData = prepared.sourceRecords.map((item) => ({
      importRunId: runId,
      sourceSystem: SOURCE_SYSTEM,
      entityType: item.entityType,
      sourceId: item.sourceId,
      locale: item.locale,
      identityKey: item.identityKey,
      sourceUrl: item.sourceUrl,
      finalUrl: item.finalUrl,
      sourceHash: item.sourceHash,
      rawHtmlPath: item.rawHtmlPath,
      scrapedAt: item.scrapedAt,
      rawPayload: item.rawPayload,
      publishable: false,
      seriesId: item.entityType === 'series' && item.targetSourceIdentity
        ? seriesIds.get(item.targetSourceIdentity)?.id ?? null
        : null,
      productId: item.entityType === 'product' && item.targetSourceIdentity
        ? productIds.get(item.targetSourceIdentity) ?? null
        : null,
      variantId: item.entityType === 'variant' && item.targetSourceIdentity
        ? variantIds.get(item.targetSourceIdentity) ?? null
        : null,
    }));
    for (let offset = 0; offset < sourceData.length; offset += 200) {
      await tx.legacySourceRecord.createMany({ data: sourceData.slice(offset, offset + 200) });
    }
  }, { maxWait: 30_000, timeout: 900_000, isolationLevel: Prisma.TransactionIsolationLevel.Serializable });
  return runId;
}

interface HeldImportLock {
  filename: string;
  handle: Awaited<ReturnType<typeof open>>;
}

async function acquireImportLock(filename: string, label: string): Promise<HeldImportLock> {
  let handle: Awaited<ReturnType<typeof open>> | null = null;
  try {
    handle = await open(filename, 'wx');
    await handle.writeFile(JSON.stringify({ pid: process.pid, label, startedAt: new Date().toISOString() }), 'utf8');
    return { filename, handle };
  } catch (error) {
    if (handle) {
      await handle.close().catch(() => undefined);
      await rm(filename, { force: true }).catch(() => undefined);
    }
    const code = isRecord(error) ? error.code : undefined;
    if (code === 'EEXIST') throw new Error(`Another legacy import may be active; ${label} lock exists: ${filename}`);
    throw error;
  }
}

async function releaseImportLocks(locks: HeldImportLock[]): Promise<void> {
  const errors: unknown[] = [];
  for (const lock of [...locks].reverse()) {
    try {
      await lock.handle.close();
    } catch (error) {
      errors.push(error);
    }
    try {
      await rm(lock.filename, { force: true });
    } catch (error) {
      errors.push(error);
    }
  }
  if (errors.length) throw new AggregateError(errors, 'Failed to release one or more legacy import locks.');
}

async function performPreparedImport(
  prepared: PreparedLegacyImport,
  options: Omit<ApplyOptions, 'inputRoot' | 'planPath'>,
): Promise<ApplyResult> {
  const databasePath = path.resolve(options.databasePath);
  const publicDir = path.resolve(options.publicDir);
  const backupDir = path.resolve(options.backupDir ?? path.join(path.dirname(databasePath), 'backups', 'legacy-v2'));
  await Promise.all([mkdir(publicDir, { recursive: true }), mkdir(backupDir, { recursive: true })]);
  const [realPublic, realDatabase, realBackupDir] = await Promise.all([
    realpath(publicDir),
    realpath(databasePath),
    realpath(backupDir),
  ]);
  if (isWithin(realPublic, realDatabase)) throw new Error('SQLite database must not be stored inside public/.');
  if (isWithin(realPublic, realBackupDir)) throw new Error('SQLite backups must not be stored inside public/.');
  const locks: HeldImportLock[] = [];
  try {
    locks.push(await acquireImportLock(`${databasePath}.legacy-v2-import.lock`, 'database'));
    locks.push(await acquireImportLock(`${realPublic}.legacy-v2-import.lock`, 'public media'));
  } catch (error) {
    await releaseImportLocks(locks);
    throw error;
  }

  let client: PrismaClient | null = null;
  let createdMedia: string[] = [];
  let backupPath = '';
  try {
    client = new PrismaClient({ datasources: { db: { url: sqliteUrl(databasePath) } } });
    backupPath = await createBackup(client, databasePath, backupDir, prepared.plan.digests.bundleSha256);
    const existingRun = await client.legacyImportRun.findUnique({
      where: { bundleSha256: prepared.plan.digests.bundleSha256 },
    });
    createdMedia = await copyPublicMedia(prepared.media, publicDir);
    if (existingRun) {
      return {
        status: 'already-applied',
        importRunId: existingRun.id,
        backupPath,
        copiedMedia: createdMedia.length,
        summary: prepared.plan.summary,
      };
    }
    try {
      const importRunId = await importTransaction(client, prepared, backupPath);
      return {
        status: 'applied',
        importRunId,
        backupPath,
        copiedMedia: createdMedia.length,
        summary: prepared.plan.summary,
      };
    } catch (error) {
      await cleanupCreatedMedia(createdMedia);
      throw new Error(
        `Import transaction rolled back; the pre-import backup remains at ${backupPath}. ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  } finally {
    try {
      if (client) await client.$disconnect();
    } finally {
      await releaseImportLocks(locks);
    }
  }
}

export async function applyLegacyV2(options: ApplyOptions): Promise<ApplyResult> {
  const [prepared, storedPlanInput] = await Promise.all([
    prepareLegacyV2Input(options.inputRoot),
    readJsonFile(path.resolve(options.planPath), 'dry-run plan'),
  ]);
  const storedPlan = storedPlanInput.value;
  if (storedPlan.schemaVersion !== IMPORT_PLAN_SCHEMA_VERSION || storedPlan.mode !== 'dry-run') {
    throw new Error('Apply requires an importer dry-run plan with schema uten-legacy-import-plan/v1.');
  }
  if (path.resolve(requiredString(storedPlan.inputRoot, 'plan.inputRoot')) !== prepared.inputRoot) {
    throw new Error('Dry-run plan inputRoot does not match --input. Run dry-run again.');
  }
  const storedDigests = record(storedPlan.digests, 'plan.digests');
  for (const [key, value] of Object.entries(prepared.plan.digests)) {
    if (storedDigests[key] !== value) throw new Error(`Dry-run plan ${key} no longer matches crawler output. Run dry-run again.`);
  }
  const storedGate = record(storedPlan.applyGate, 'plan.applyGate');
  if (storedPlan.status !== 'pass' || storedGate.eligible !== true) {
    throw new Error('Stored dry-run plan is not eligible for apply.');
  }
  if (!prepared.plan.applyGate.eligible || !prepared.plan.qa.expectFull || prepared.plan.qa.status !== 'pass') {
    throw new Error(`Current crawler output is not eligible for apply: ${prepared.plan.applyGate.reasons.join(' ')}`);
  }
  return performPreparedImport(prepared, options);
}

/**
 * Exercises backup/media/transaction behavior with the crawler's partial fixture.
 * It is deliberately unavailable outside NODE_ENV=test and a clearly named temp DB;
 * the public applyLegacyV2 entry point never bypasses the full QA gate.
 */
export async function applyPreparedImportForTest(
  prepared: PreparedLegacyImport,
  options: Omit<ApplyOptions, 'inputRoot' | 'planPath'>,
): Promise<ApplyResult> {
  const testRoot = path.resolve(prepared.inputRoot);
  const rootMetadata = await lstat(testRoot);
  const databasePath = path.resolve(options.databasePath);
  const publicDir = path.resolve(options.publicDir);
  const backupDir = path.resolve(options.backupDir ?? path.join(path.dirname(databasePath), 'backups', 'legacy-v2'));
  if (
    process.env.NODE_ENV !== 'test'
    || !path.basename(testRoot).startsWith('.tmp-legacy-import-test-')
    || !rootMetadata.isDirectory()
    || rootMetadata.isSymbolicLink()
    || !path.basename(databasePath).includes('legacy-import-test')
    || !isWithin(testRoot, databasePath)
    || !isWithin(testRoot, publicDir)
    || !isWithin(testRoot, backupDir)
  ) {
    throw new Error('The partial-fixture transaction hook is test-only.');
  }
  await Promise.all([mkdir(publicDir, { recursive: true }), mkdir(backupDir, { recursive: true })]);
  const [realRoot, realDatabase, realPublic, realBackup] = await Promise.all([
    realpath(testRoot),
    realpath(databasePath),
    realpath(publicDir),
    realpath(backupDir),
  ]);
  if (
    !isWithin(realRoot, realDatabase)
    || !isWithin(realRoot, realPublic)
    || !isWithin(realRoot, realBackup)
  ) {
    throw new Error('The partial-fixture transaction hook refuses symlinked paths outside its temp root.');
  }
  return performPreparedImport(prepared, options);
}
