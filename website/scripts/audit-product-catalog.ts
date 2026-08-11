import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

export const AUDIT_SCHEMA_VERSION = "uten-product-catalog-audit/v1";
export const REVIEW_STATUS = "needs review" as const;

type Nullable<T> = T | null | undefined;

export interface SeriesAuditRow {
  id: string;
  code: string;
  i18n?: unknown;
  parentId?: Nullable<string>;
  published?: Nullable<boolean>;
  catalogRole?: Nullable<string>;
  publicSlug?: Nullable<string>;
}

export interface ProductAuditRow {
  id: string;
  seriesId?: Nullable<string>;
  slug: string;
  model?: Nullable<string>;
  category?: Nullable<string>;
  image?: Nullable<string>;
  gallery?: unknown;
  specs?: unknown;
  i18n?: unknown;
  published?: Nullable<boolean>;
  functionType?: Nullable<string>;
  gangCount?: Nullable<number>;
  controlMode?: Nullable<string>;
  classificationStatus?: Nullable<string>;
}

export interface VariantAuditRow {
  id: string;
  productId: string;
  sku?: Nullable<string>;
  i18n?: unknown;
  swatchHex?: Nullable<string>;
  image?: Nullable<string>;
  gallery?: unknown;
  finish?: Nullable<string>;
  widthMm?: Nullable<number>;
  heightMm?: Nullable<number>;
  depthMm?: Nullable<number>;
  published?: Nullable<boolean>;
  sourceIdentity?: Nullable<string>;
  legacySynthetic?: Nullable<boolean>;
  dataStatus?: Nullable<string>;
  isDefault?: Nullable<boolean>;
}

export interface MediaAuditRow {
  productId: string;
  variantId?: Nullable<string>;
  role: string;
  locale?: Nullable<string>;
  assetId?: Nullable<string>;
  sha256?: Nullable<string>;
  publicPath?: Nullable<string>;
  sourceUrl?: Nullable<string>;
}

export interface CatalogFieldAvailability {
  series: Record<string, boolean>;
  product: Record<string, boolean>;
  variant: Record<string, boolean>;
}

export interface CatalogAuditInput {
  series: SeriesAuditRow[];
  products: ProductAuditRow[];
  variants: VariantAuditRow[];
  media?: MediaAuditRow[];
  fieldAvailability?: CatalogFieldAvailability;
}

interface CompletenessMetric {
  available: boolean;
  total: number;
  present: number;
  missing: number | null;
  unknown: number;
  ratio: number | null;
}

interface EntityReference {
  id: string;
  key: string;
}

interface ReviewCandidate {
  reviewStatus: typeof REVIEW_STATUS;
  reason: string;
}

interface SameNameCandidate extends ReviewCandidate {
  familyId: string;
  normalizedName: string;
  products: Array<{
    id: string;
    slug: string;
    seriesId: string | null;
    model: string | null;
  }>;
}

interface SameModelCandidate extends ReviewCandidate {
  normalizedModel: string;
  productIds: string[];
  familyIds: string[];
  imagePaths: string[];
}

interface DuplicateGalleryCandidate extends ReviewCandidate {
  ownerType: "product" | "variant";
  ownerId: string;
  normalizedValue: string;
  occurrences: Array<{
    source: string;
    value: string;
    role?: string;
    locale?: string | null;
    assetId?: string | null;
  }>;
}

const CONTRACT_FIELDS = {
  series: ["catalogRole", "publicSlug"],
  product: [
    "functionType",
    "gangCount",
    "controlMode",
    "classificationStatus",
  ],
  variant: ["legacySynthetic", "dataStatus", "isDefault"],
} as const;

const BASE_FIELDS = {
  series: ["id", "code", "i18n", "parentId", "published"],
  product: [
    "id",
    "seriesId",
    "slug",
    "model",
    "category",
    "image",
    "gallery",
    "specs",
    "i18n",
    "published",
  ],
  variant: [
    "id",
    "productId",
    "sku",
    "i18n",
    "swatchHex",
    "image",
    "gallery",
    "finish",
    "widthMm",
    "heightMm",
    "depthMm",
    "published",
    "sourceIdentity",
  ],
} as const;

function nonBlank(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function finiteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function roundRatio(value: number): number {
  return Number(value.toFixed(4));
}

function parseJson(value: unknown): unknown {
  if (typeof value !== "string") {
    return value;
  }

  const trimmed = value.trim();
  if (!trimmed) {
    return null;
  }

  try {
    return JSON.parse(trimmed) as unknown;
  } catch {
    return null;
  }
}

function meaningfulJson(value: unknown): boolean {
  const parsed = parseJson(value);
  if (Array.isArray(parsed)) {
    return parsed.length > 0;
  }
  return Boolean(parsed && typeof parsed === "object" && Object.keys(parsed).length);
}

function localizedName(value: unknown): string | null {
  const parsed = parseJson(value);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return null;
  }

  const record = parsed as Record<string, unknown>;
  const preferredLocales = ["zh", "zh-CN", "zh_CN", "en", "en-US", "en_US"];
  const localeValues = [
    ...preferredLocales.map((locale) => record[locale]),
    ...Object.values(record),
  ];

  for (const localeValue of localeValues) {
    if (localeValue && typeof localeValue === "object" && !Array.isArray(localeValue)) {
      const localeRecord = localeValue as Record<string, unknown>;
      for (const key of ["name", "title", "colorName"]) {
        if (nonBlank(localeRecord[key])) {
          return localeRecord[key].trim();
        }
      }
    }
  }

  for (const key of ["name", "title", "colorName"]) {
    if (nonBlank(record[key])) {
      return record[key].trim();
    }
  }
  return null;
}

function galleryPaths(value: unknown): string[] {
  const parsed = parseJson(value);
  if (!Array.isArray(parsed)) {
    return [];
  }

  return parsed.flatMap((entry) => {
    if (nonBlank(entry)) {
      return [entry.trim()];
    }
    if (entry && typeof entry === "object" && !Array.isArray(entry)) {
      const record = entry as Record<string, unknown>;
      for (const key of ["path", "url", "src", "image"]) {
        if (nonBlank(record[key])) {
          return [record[key].trim()];
        }
      }
    }
    return [];
  });
}

export function normalizeProductName(value: string): string {
  return value
    .normalize("NFKC")
    .toLocaleLowerCase("en-US")
    .replace(/[\p{P}\p{S}\s_]+/gu, "")
    .trim();
}

export function normalizeModel(value: string): string {
  return value
    .normalize("NFKC")
    .toLocaleUpperCase("en-US")
    .replace(/[\s_]+/g, "")
    .trim();
}

export function normalizeMediaPath(value: string): string {
  let normalized = value.trim().replace(/\\/g, "/");
  try {
    const url = new URL(normalized);
    normalized = url.pathname;
  } catch {
    normalized = normalized.split(/[?#]/, 1)[0] ?? normalized;
  }
  return normalized
    .normalize("NFKC")
    .replace(/\/{2,}/g, "/")
    .replace(/\/$/, "")
    .toLocaleLowerCase("en-US");
}

function normalizedRole(value: unknown): "family" | "collection" | "other" | "missing" {
  if (!nonBlank(value)) {
    return "missing";
  }
  const normalized = value.trim().toLocaleLowerCase("en-US").replace(/[\s_-]+/g, "");
  if (normalized === "family" || normalized === "productfamily") {
    return "family";
  }
  if (normalized === "collection" || normalized === "series" || normalized === "productcollection") {
    return "collection";
  }
  return "other";
}

function availabilityFor(
  input: CatalogAuditInput,
  entity: keyof CatalogFieldAvailability,
  field: string,
): boolean {
  return input.fieldAvailability?.[entity]?.[field] ?? true;
}

function completeness<T>(
  rows: T[],
  available: boolean,
  predicate: (row: T) => boolean,
): CompletenessMetric {
  if (!available) {
    return {
      available: false,
      total: rows.length,
      present: 0,
      missing: null,
      unknown: rows.length,
      ratio: null,
    };
  }

  const present = rows.filter(predicate).length;
  return {
    available: true,
    total: rows.length,
    present,
    missing: rows.length - present,
    unknown: 0,
    ratio: rows.length === 0 ? 1 : roundRatio(present / rows.length),
  };
}

function missingReferences<T>(
  rows: T[],
  available: boolean,
  predicate: (row: T) => boolean,
  reference: (row: T) => EntityReference,
): EntityReference[] | null {
  return available ? rows.filter((row) => !predicate(row)).map(reference) : null;
}

function productReference(product: ProductAuditRow): EntityReference {
  return { id: product.id, key: product.slug };
}

function variantReference(variant: VariantAuditRow): EntityReference {
  return { id: variant.id, key: variant.sku?.trim() || variant.productId };
}

function hasDimensions(variant: VariantAuditRow): boolean {
  return (
    finiteNumber(variant.widthMm) &&
    variant.widthMm > 0 &&
    finiteNumber(variant.heightMm) &&
    variant.heightMm > 0 &&
    finiteNumber(variant.depthMm) &&
    variant.depthMm > 0
  );
}

function hasColor(variant: VariantAuditRow): boolean {
  if (nonBlank(variant.swatchHex) || nonBlank(variant.finish)) {
    return true;
  }
  const parsed = parseJson(variant.i18n);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return false;
  }
  return Object.values(parsed as Record<string, unknown>).some((localeValue) => {
    if (!localeValue || typeof localeValue !== "object" || Array.isArray(localeValue)) {
      return false;
    }
    const record = localeValue as Record<string, unknown>;
    return nonBlank(record.colorName) || nonBlank(record.materialName);
  });
}

function productHasImage(product: ProductAuditRow, variants: VariantAuditRow[]): boolean {
  if (nonBlank(product.image) || galleryPaths(product.gallery).length > 0) {
    return true;
  }
  return variants.some(
    (variant) =>
      variant.published === true &&
      (nonBlank(variant.image) || galleryPaths(variant.gallery).length > 0),
  );
}

function resolveFamilyId(
  seriesId: Nullable<string>,
  seriesById: Map<string, SeriesAuditRow>,
): { familyId: string | null; status: "resolved" | "missing" | "unclassified" | "cycle" } {
  if (!seriesId) {
    return { familyId: null, status: "missing" };
  }

  const visited = new Set<string>();
  let currentId: string | null | undefined = seriesId;
  while (currentId) {
    if (visited.has(currentId)) {
      return { familyId: null, status: "cycle" };
    }
    visited.add(currentId);
    const current = seriesById.get(currentId);
    if (!current) {
      return { familyId: null, status: "missing" };
    }
    if (normalizedRole(current.catalogRole) === "family") {
      return { familyId: current.id, status: "resolved" };
    }
    currentId = current.parentId;
  }
  return { familyId: null, status: "unclassified" };
}

function buildSameNameCandidates(
  products: ProductAuditRow[],
  seriesById: Map<string, SeriesAuditRow>,
): { candidates: SameNameCandidate[]; familyResolution: Record<string, number> } {
  const grouped = new Map<string, { familyId: string; normalizedName: string; products: ProductAuditRow[] }>();
  const familyResolution = { resolved: 0, missing: 0, unclassified: 0, cycle: 0 };

  for (const product of products) {
    const resolution = resolveFamilyId(product.seriesId, seriesById);
    familyResolution[resolution.status] += 1;
    if (!resolution.familyId) {
      continue;
    }
    const name = localizedName(product.i18n) ?? product.slug;
    const normalizedName = normalizeProductName(name);
    if (!normalizedName) {
      continue;
    }
    const key = `${resolution.familyId}\u0000${normalizedName}`;
    const entry = grouped.get(key) ?? {
      familyId: resolution.familyId,
      normalizedName,
      products: [],
    };
    entry.products.push(product);
    grouped.set(key, entry);
  }

  const candidates = [...grouped.values()]
    .filter((entry) => entry.products.length > 1)
    .map((entry) => ({
      reviewStatus: REVIEW_STATUS,
      reason: "same declared family and normalized product name",
      familyId: entry.familyId,
      normalizedName: entry.normalizedName,
      products: entry.products
        .map((product) => ({
          id: product.id,
          slug: product.slug,
          seriesId: product.seriesId ?? null,
          model: product.model?.trim() || null,
        }))
        .sort((left, right) => left.id.localeCompare(right.id)),
    }))
    .sort((left, right) =>
      `${left.familyId}:${left.normalizedName}`.localeCompare(
        `${right.familyId}:${right.normalizedName}`,
      ),
    );

  return { candidates, familyResolution };
}

function buildSameModelCandidates(
  products: ProductAuditRow[],
  variants: VariantAuditRow[],
  seriesById: Map<string, SeriesAuditRow>,
): SameModelCandidate[] {
  const variantsByProduct = new Map<string, VariantAuditRow[]>();
  for (const variant of variants) {
    const rows = variantsByProduct.get(variant.productId) ?? [];
    rows.push(variant);
    variantsByProduct.set(variant.productId, rows);
  }

  const grouped = new Map<string, ProductAuditRow[]>();
  for (const product of products) {
    if (!nonBlank(product.model)) {
      continue;
    }
    const model = normalizeModel(product.model);
    if (!model) {
      continue;
    }
    const rows = grouped.get(model) ?? [];
    rows.push(product);
    grouped.set(model, rows);
  }

  return [...grouped.entries()]
    .flatMap(([normalizedModel, modelProducts]) => {
      if (modelProducts.length < 2) {
        return [];
      }
      const imagePaths = new Set<string>();
      for (const product of modelProducts) {
        const values = [
          ...(nonBlank(product.image) ? [product.image] : []),
          ...galleryPaths(product.gallery),
          ...(variantsByProduct.get(product.id) ?? []).flatMap((variant) => [
            ...(nonBlank(variant.image) ? [variant.image] : []),
            ...galleryPaths(variant.gallery),
          ]),
        ];
        values.map(normalizeMediaPath).filter(Boolean).forEach((path) => imagePaths.add(path));
      }
      if (imagePaths.size < 2) {
        return [];
      }
      const familyIds = new Set<string>();
      for (const product of modelProducts) {
        const resolution = resolveFamilyId(product.seriesId, seriesById);
        if (resolution.familyId) {
          familyIds.add(resolution.familyId);
        }
      }
      return [
        {
          reviewStatus: REVIEW_STATUS,
          reason: "same normalized model appears on multiple products with different image paths",
          normalizedModel,
          productIds: modelProducts.map((product) => product.id).sort(),
          familyIds: [...familyIds].sort(),
          imagePaths: [...imagePaths].sort(),
        },
      ];
    })
    .sort((left, right) => left.normalizedModel.localeCompare(right.normalizedModel));
}

interface MediaOccurrence {
  ownerType: "product" | "variant";
  ownerId: string;
  source: string;
  value: string;
  role?: string;
  locale?: string | null;
  assetId?: string | null;
  containsGallery: boolean;
}

function duplicateCandidatesFromOccurrences(
  occurrences: MediaOccurrence[],
  normalizedValue: (occurrence: MediaOccurrence) => string,
  reason: string,
): DuplicateGalleryCandidate[] {
  const grouped = new Map<string, MediaOccurrence[]>();
  for (const occurrence of occurrences) {
    const normalized = normalizedValue(occurrence);
    if (!normalized) {
      continue;
    }
    const key = `${occurrence.ownerType}\u0000${occurrence.ownerId}\u0000${normalized}`;
    const rows = grouped.get(key) ?? [];
    rows.push(occurrence);
    grouped.set(key, rows);
  }

  return [...grouped.values()]
    .filter((rows) => rows.length > 1 && rows.some((row) => row.containsGallery))
    .map((rows) => ({
      reviewStatus: REVIEW_STATUS,
      reason,
      ownerType: rows[0].ownerType,
      ownerId: rows[0].ownerId,
      normalizedValue: normalizedValue(rows[0]),
      occurrences: rows
        .map((row) => ({
          source: row.source,
          value: row.value,
          ...(row.role ? { role: row.role } : {}),
          ...(row.locale !== undefined ? { locale: row.locale } : {}),
          ...(row.assetId !== undefined ? { assetId: row.assetId } : {}),
        }))
        .sort((left, right) => left.source.localeCompare(right.source)),
    }))
    .sort((left, right) =>
      `${left.ownerType}:${left.ownerId}:${left.normalizedValue}`.localeCompare(
        `${right.ownerType}:${right.ownerId}:${right.normalizedValue}`,
      ),
    );
}

function buildDuplicateGalleryCandidates(
  products: ProductAuditRow[],
  variants: VariantAuditRow[],
  media: MediaAuditRow[],
): { paths: DuplicateGalleryCandidate[]; hashes: DuplicateGalleryCandidate[] } {
  const pathOccurrences: MediaOccurrence[] = [];
  for (const product of products) {
    if (nonBlank(product.image)) {
      pathOccurrences.push({
        ownerType: "product",
        ownerId: product.id,
        source: "Product.image",
        value: product.image,
        containsGallery: false,
      });
    }
    galleryPaths(product.gallery).forEach((path, index) => {
      pathOccurrences.push({
        ownerType: "product",
        ownerId: product.id,
        source: `Product.gallery[${index}]`,
        value: path,
        containsGallery: true,
      });
    });
  }
  for (const variant of variants) {
    if (nonBlank(variant.image)) {
      pathOccurrences.push({
        ownerType: "variant",
        ownerId: variant.id,
        source: "ProductVariant.image",
        value: variant.image,
        containsGallery: false,
      });
    }
    galleryPaths(variant.gallery).forEach((path, index) => {
      pathOccurrences.push({
        ownerType: "variant",
        ownerId: variant.id,
        source: `ProductVariant.gallery[${index}]`,
        value: path,
        containsGallery: true,
      });
    });
  }

  const hashOccurrences: MediaOccurrence[] = [];
  for (const row of media) {
    const ownerType = row.variantId ? "variant" : "product";
    const ownerId = row.variantId ?? row.productId;
    const containsGallery = row.role.trim().toLocaleLowerCase("en-US") === "gallery";
    if (nonBlank(row.publicPath)) {
      pathOccurrences.push({
        ownerType,
        ownerId,
        source: "ProductMedia.publicPath",
        value: row.publicPath,
        role: row.role,
        locale: row.locale ?? null,
        assetId: row.assetId ?? null,
        containsGallery,
      });
    }
    if (nonBlank(row.sha256)) {
      hashOccurrences.push({
        ownerType,
        ownerId,
        source: "LegacyMediaAsset.sha256",
        value: row.sha256,
        role: row.role,
        locale: row.locale ?? null,
        assetId: row.assetId ?? null,
        containsGallery,
      });
    }
  }

  return {
    paths: duplicateCandidatesFromOccurrences(
      pathOccurrences,
      (row) => normalizeMediaPath(row.value),
      "same owner has the same normalized media path more than once, including a gallery occurrence",
    ),
    hashes: duplicateCandidatesFromOccurrences(
      hashOccurrences,
      (row) => row.value.trim().toLocaleLowerCase("en-US"),
      "same owner has the same asset hash more than once, including a gallery occurrence",
    ),
  };
}

export function auditProductCatalog(
  input: CatalogAuditInput,
  options: { generatedAt?: string } = {},
) {
  const seriesById = new Map(input.series.map((series) => [series.id, series]));
  const variantsByProduct = new Map<string, VariantAuditRow[]>();
  for (const variant of input.variants) {
    const variants = variantsByProduct.get(variant.productId) ?? [];
    variants.push(variant);
    variantsByProduct.set(variant.productId, variants);
  }

  const contractFields = Object.entries(CONTRACT_FIELDS).flatMap(([entity, fields]) =>
    fields.map((field) => ({
      entity,
      field,
      available: availabilityFor(input, entity as keyof CatalogFieldAvailability, field),
    })),
  );
  const missingContractFields = contractFields
    .filter((field) => !field.available)
    .map((field) => `${field.entity}.${field.field}`);

  const declaredRoleCounts = { family: 0, collection: 0, other: 0, missing: 0 };
  const declaredRoleValues: Record<string, number> = {};
  for (const series of input.series) {
    declaredRoleCounts[normalizedRole(series.catalogRole)] += 1;
    const value = nonBlank(series.catalogRole) ? series.catalogRole.trim() : "(missing)";
    declaredRoleValues[value] = (declaredRoleValues[value] ?? 0) + 1;
  }

  const productFields = {
    name: completeness(input.products, true, (row) => localizedName(row.i18n) !== null),
    model: completeness(input.products, availabilityFor(input, "product", "model"), (row) => nonBlank(row.model)),
    specs: completeness(input.products, availabilityFor(input, "product", "specs"), (row) => meaningfulJson(row.specs)),
    functionType: completeness(
      input.products,
      availabilityFor(input, "product", "functionType"),
      (row) => nonBlank(row.functionType),
    ),
    gangCount: completeness(
      input.products,
      availabilityFor(input, "product", "gangCount"),
      (row) => finiteNumber(row.gangCount) && Number.isInteger(row.gangCount) && row.gangCount > 0,
    ),
    controlMode: completeness(
      input.products,
      availabilityFor(input, "product", "controlMode"),
      (row) => nonBlank(row.controlMode),
    ),
    classificationStatus: completeness(
      input.products,
      availabilityFor(input, "product", "classificationStatus"),
      (row) => nonBlank(row.classificationStatus),
    ),
  };

  const variantCompleteness = (rows: VariantAuditRow[]) => ({
    name: completeness(rows, true, (row) => localizedName(row.i18n) !== null),
    sku: completeness(rows, availabilityFor(input, "variant", "sku"), (row) => nonBlank(row.sku)),
    dimensions: completeness(rows, true, hasDimensions),
    color: completeness(rows, true, hasColor),
    dataStatus: completeness(
      rows,
      availabilityFor(input, "variant", "dataStatus"),
      (row) => nonBlank(row.dataStatus),
    ),
    isDefault: completeness(
      rows,
      availabilityFor(input, "variant", "isDefault"),
      (row) => typeof row.isDefault === "boolean",
    ),
  });

  const syntheticFieldAvailable = availabilityFor(input, "variant", "legacySynthetic");
  const realVariants = syntheticFieldAvailable
    ? input.variants.filter((variant) => variant.legacySynthetic === false)
    : [];
  const legacySynthetic = syntheticFieldAvailable
    ? {
        available: true,
        true: input.variants.filter((variant) => variant.legacySynthetic === true).length,
        false: realVariants.length,
        unknown: input.variants.filter((variant) => typeof variant.legacySynthetic !== "boolean").length,
      }
    : { available: false, true: 0, false: 0, unknown: input.variants.length };

  const missing = {
    product: {
      model: missingReferences(
        input.products,
        availabilityFor(input, "product", "model"),
        (row) => nonBlank(row.model),
        productReference,
      ),
      specs: missingReferences(
        input.products,
        availabilityFor(input, "product", "specs"),
        (row) => meaningfulJson(row.specs),
        productReference,
      ),
      functionType: missingReferences(
        input.products,
        availabilityFor(input, "product", "functionType"),
        (row) => nonBlank(row.functionType),
        productReference,
      ),
      gangCount: missingReferences(
        input.products,
        availabilityFor(input, "product", "gangCount"),
        (row) => finiteNumber(row.gangCount) && Number.isInteger(row.gangCount) && row.gangCount > 0,
        productReference,
      ),
      controlMode: missingReferences(
        input.products,
        availabilityFor(input, "product", "controlMode"),
        (row) => nonBlank(row.controlMode),
        productReference,
      ),
      classificationStatus: missingReferences(
        input.products,
        availabilityFor(input, "product", "classificationStatus"),
        (row) => nonBlank(row.classificationStatus),
        productReference,
      ),
    },
    variant: {
      sku: missingReferences(
        input.variants,
        availabilityFor(input, "variant", "sku"),
        (row) => nonBlank(row.sku),
        variantReference,
      ),
      dimensions: missingReferences(input.variants, true, hasDimensions, variantReference),
      color: missingReferences(input.variants, true, hasColor, variantReference),
      dataStatus: missingReferences(
        input.variants,
        availabilityFor(input, "variant", "dataStatus"),
        (row) => nonBlank(row.dataStatus),
        variantReference,
      ),
      isDefault: missingReferences(
        input.variants,
        availabilityFor(input, "variant", "isDefault"),
        (row) => typeof row.isDefault === "boolean",
        variantReference,
      ),
    },
  };

  const publishedProducts = input.products.filter((product) => product.published === true);
  const productsMissingSeries = publishedProducts
    .filter((product) => !product.seriesId || !seriesById.has(product.seriesId))
    .map(productReference);
  const productsWithUnavailableSeries = publishedProducts
    .filter((product) => {
      if (!product.seriesId) return false;
      const series = seriesById.get(product.seriesId);
      return !series || series.published !== true;
    })
    .map(productReference);
  const productsMissingImage = publishedProducts
    .filter(
      (product) => !productHasImage(product, variantsByProduct.get(product.id) ?? []),
    )
    .map(productReference);
  const productsWithoutPublishedVariant = publishedProducts
    .filter(
      (product) =>
        !(variantsByProduct.get(product.id) ?? []).some(
          (variant) => variant.published === true,
        ),
    )
    .map(productReference);

  const sameName = buildSameNameCandidates(input.products, seriesById);
  const duplicateGallery = buildDuplicateGalleryCandidates(
    input.products,
    input.variants,
    input.media ?? [],
  );

  return {
    schemaVersion: AUDIT_SCHEMA_VERSION,
    generatedAt: options.generatedAt ?? new Date().toISOString(),
    mode: "read-only",
    reviewPolicy: {
      autoMerge: false,
      databaseWrites: false,
      candidateStatus: REVIEW_STATUS,
      note: "All duplicate findings are candidates only; a human must review source identity and imagery before any merge.",
    },
    schema: {
      contractFields,
      missingContractFields,
    },
    totals: {
      series: input.series.length,
      products: input.products.length,
      variants: input.variants.length,
      mediaRelations: input.media?.length ?? 0,
      publishedProducts: publishedProducts.length,
      publishedVariants: input.variants.filter((variant) => variant.published === true).length,
    },
    seriesRoles: {
      source: "Series.catalogRole only; hierarchy and names are not used to invent roles.",
      available: availabilityFor(input, "series", "catalogRole"),
      counts: declaredRoleCounts,
      rawValues: Object.fromEntries(
        Object.entries(declaredRoleValues).sort(([left], [right]) => left.localeCompare(right)),
      ),
      publicSlug: completeness(
        input.series,
        availabilityFor(input, "series", "publicSlug"),
        (row) => nonBlank(row.publicSlug),
      ),
    },
    completeness: {
      products: {
        scope: "all products",
        total: input.products.length,
        fields: productFields,
      },
      variants: {
        all: {
          scope: "all variants",
          total: input.variants.length,
          fields: variantCompleteness(input.variants),
        },
        realMaster: {
          scope: "variants explicitly marked legacySynthetic=false",
          available: syntheticFieldAvailable,
          total: realVariants.length,
          excludedSynthetic: legacySynthetic.true,
          excludedUnknown: legacySynthetic.unknown,
          fields: variantCompleteness(realVariants),
        },
        legacySynthetic,
      },
    },
    missing,
    publicIntegrity: {
      productsMissingSeries,
      productsWithUnavailableSeries,
      productsMissingImage,
      productsWithoutPublishedVariant,
    },
    candidates: {
      sameFamilyNormalizedName: sameName.candidates,
      sameModelMultipleImages: buildSameModelCandidates(
        input.products,
        input.variants,
        seriesById,
      ),
      duplicateGalleryPath: duplicateGallery.paths,
      duplicateGalleryHash: duplicateGallery.hashes,
    },
    diagnostics: {
      familyResolutionForProducts: sameName.familyResolution,
      notes: [
        "A missing contract field is reported as unavailable/unknown, not as missing data.",
        "Image-path normalization strips URL origins, query strings, fragments, slash differences, and case; every match still requires review.",
        "Published integrity uses Product.published and ProductVariant.published; it does not infer publication from dataStatus.",
      ],
    },
  };
}

interface ReadOnlyPrismaClient {
  $queryRawUnsafe<T = unknown>(query: string): Promise<T>;
  $disconnect(): Promise<void>;
}

interface SqliteColumnRow {
  name: unknown;
}

function quoteIdentifier(identifier: string): string {
  if (!/^[A-Za-z][A-Za-z0-9_]*$/.test(identifier)) {
    throw new Error(`Unsafe SQL identifier: ${identifier}`);
  }
  return `"${identifier}"`;
}

async function tableColumns(
  prisma: ReadOnlyPrismaClient,
  table: string,
): Promise<Set<string>> {
  const rows = await prisma.$queryRawUnsafe<SqliteColumnRow[]>(
    `PRAGMA table_info(${quoteIdentifier(table)})`,
  );
  return new Set(rows.flatMap((row) => (nonBlank(row.name) ? [row.name] : [])));
}

function selectList(columns: Set<string>, fields: readonly string[]): string {
  return fields
    .map((field) =>
      columns.has(field)
        ? quoteIdentifier(field)
        : `NULL AS ${quoteIdentifier(field)}`,
    )
    .join(", ");
}

function asString(value: unknown, fallback = ""): string {
  return typeof value === "string" ? value : fallback;
}

function asNullableString(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function asNullableNumber(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "bigint") return Number(value);
  return null;
}

function asNullableBoolean(value: unknown): boolean | null {
  if (typeof value === "boolean") return value;
  if (value === 1 || value === 1n || value === "1") return true;
  if (value === 0 || value === 0n || value === "0") return false;
  return null;
}

async function readCatalogSnapshot(prisma: ReadOnlyPrismaClient): Promise<CatalogAuditInput> {
  const [seriesColumns, productColumns, variantColumns] = await Promise.all([
    tableColumns(prisma, "Series"),
    tableColumns(prisma, "Product"),
    tableColumns(prisma, "ProductVariant"),
  ]);

  const seriesFields = [...BASE_FIELDS.series, ...CONTRACT_FIELDS.series];
  const productFields = [...BASE_FIELDS.product, ...CONTRACT_FIELDS.product];
  const variantFields = [...BASE_FIELDS.variant, ...CONTRACT_FIELDS.variant];
  const [seriesRaw, productsRaw, variantsRaw] = await Promise.all([
    prisma.$queryRawUnsafe<Array<Record<string, unknown>>>(
      `SELECT ${selectList(seriesColumns, seriesFields)} FROM "Series" ORDER BY "id"`,
    ),
    prisma.$queryRawUnsafe<Array<Record<string, unknown>>>(
      `SELECT ${selectList(productColumns, productFields)} FROM "Product" ORDER BY "id"`,
    ),
    prisma.$queryRawUnsafe<Array<Record<string, unknown>>>(
      `SELECT ${selectList(variantColumns, variantFields)} FROM "ProductVariant" ORDER BY "id"`,
    ),
  ]);

  const tableRows = await prisma.$queryRawUnsafe<Array<{ name: unknown }>>(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('ProductMedia', 'LegacyMediaAsset')",
  );
  const tableNames = new Set(tableRows.flatMap((row) => (nonBlank(row.name) ? [row.name] : [])));
  const mediaRaw =
    tableNames.has("ProductMedia") && tableNames.has("LegacyMediaAsset")
      ? await prisma.$queryRawUnsafe<Array<Record<string, unknown>>>(
          `SELECT pm."productId", pm."variantId", pm."role", pm."locale", pm."assetId", pm."sourceUrl", asset."sha256", asset."publicPath"
             FROM "ProductMedia" AS pm
             INNER JOIN "LegacyMediaAsset" AS asset ON asset."id" = pm."assetId"
            ORDER BY pm."productId", pm."variantId", pm."sortOrder", pm."id"`,
        )
      : [];

  return {
    series: seriesRaw.map((row) => ({
      id: asString(row.id),
      code: asString(row.code),
      i18n: row.i18n,
      parentId: asNullableString(row.parentId),
      published: asNullableBoolean(row.published),
      catalogRole: asNullableString(row.catalogRole),
      publicSlug: asNullableString(row.publicSlug),
    })),
    products: productsRaw.map((row) => ({
      id: asString(row.id),
      seriesId: asNullableString(row.seriesId),
      slug: asString(row.slug),
      model: asNullableString(row.model),
      category: asNullableString(row.category),
      image: asNullableString(row.image),
      gallery: row.gallery,
      specs: row.specs,
      i18n: row.i18n,
      published: asNullableBoolean(row.published),
      functionType: asNullableString(row.functionType),
      gangCount: asNullableNumber(row.gangCount),
      controlMode: asNullableString(row.controlMode),
      classificationStatus: asNullableString(row.classificationStatus),
    })),
    variants: variantsRaw.map((row) => ({
      id: asString(row.id),
      productId: asString(row.productId),
      sku: asNullableString(row.sku),
      i18n: row.i18n,
      swatchHex: asNullableString(row.swatchHex),
      image: asNullableString(row.image),
      gallery: row.gallery,
      finish: asNullableString(row.finish),
      widthMm: asNullableNumber(row.widthMm),
      heightMm: asNullableNumber(row.heightMm),
      depthMm: asNullableNumber(row.depthMm),
      published: asNullableBoolean(row.published),
      sourceIdentity: asNullableString(row.sourceIdentity),
      legacySynthetic: asNullableBoolean(row.legacySynthetic),
      dataStatus: asNullableString(row.dataStatus),
      isDefault: asNullableBoolean(row.isDefault),
    })),
    media: mediaRaw.map((row) => ({
      productId: asString(row.productId),
      variantId: asNullableString(row.variantId),
      role: asString(row.role),
      locale: asNullableString(row.locale),
      assetId: asNullableString(row.assetId),
      sha256: asNullableString(row.sha256),
      publicPath: asNullableString(row.publicPath),
      sourceUrl: asNullableString(row.sourceUrl),
    })),
    fieldAvailability: {
      series: Object.fromEntries(seriesFields.map((field) => [field, seriesColumns.has(field)])),
      product: Object.fromEntries(productFields.map((field) => [field, productColumns.has(field)])),
      variant: Object.fromEntries(variantFields.map((field) => [field, variantColumns.has(field)])),
    },
  };
}

async function runCli(): Promise<void> {
  const { loadEnvConfig } = await import("@next/env");
  loadEnvConfig(process.cwd());
  const { PrismaClient } = await import("@prisma/client");
  const prisma = new PrismaClient() as unknown as ReadOnlyPrismaClient;
  try {
    const snapshot = await readCatalogSnapshot(prisma);
    process.stdout.write(`${JSON.stringify(auditProductCatalog(snapshot), null, 2)}\n`);
  } finally {
    await prisma.$disconnect();
  }
}

function isMainModule(): boolean {
  const entry = process.argv[1];
  return Boolean(entry && pathToFileURL(resolve(entry)).href === import.meta.url);
}

if (isMainModule()) {
  runCli().catch((error: unknown) => {
    const message = error instanceof Error ? error.stack ?? error.message : String(error);
    process.stderr.write(`Product catalog audit failed: ${message}\n`);
    process.exitCode = 1;
  });
}
