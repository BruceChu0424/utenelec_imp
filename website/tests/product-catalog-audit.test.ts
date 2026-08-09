import assert from "node:assert/strict";
import test from "node:test";

import {
  REVIEW_STATUS,
  auditProductCatalog,
  normalizeMediaPath,
  normalizeModel,
  normalizeProductName,
  type CatalogAuditInput,
} from "../scripts/audit-product-catalog";

const allFieldsAvailable = {
  series: {
    id: true,
    code: true,
    i18n: true,
    parentId: true,
    published: true,
    catalogRole: true,
    publicSlug: true,
  },
  product: {
    id: true,
    seriesId: true,
    slug: true,
    model: true,
    category: true,
    image: true,
    gallery: true,
    specs: true,
    i18n: true,
    published: true,
    functionType: true,
    gangCount: true,
    controlMode: true,
    classificationStatus: true,
  },
  variant: {
    id: true,
    productId: true,
    sku: true,
    i18n: true,
    swatchHex: true,
    image: true,
    gallery: true,
    finish: true,
    widthMm: true,
    heightMm: true,
    depthMm: true,
    published: true,
    sourceIdentity: true,
    legacySynthetic: true,
    dataStatus: true,
    isDefault: true,
  },
};

function fixture(): CatalogAuditInput {
  return {
    fieldAvailability: structuredClone(allFieldsAvailable),
    series: [
      {
        id: "family-s300",
        code: "s300-family",
        i18n: JSON.stringify({ zh: { name: "S300 家族" } }),
        catalogRole: "FAMILY",
        publicSlug: "s300",
        published: true,
      },
      {
        id: "collection-glass",
        code: "s300-glass",
        i18n: JSON.stringify({ zh: { name: "玻璃系列" } }),
        catalogRole: "COLLECTION",
        publicSlug: "glass",
        parentId: "family-s300",
        published: true,
      },
      {
        id: "collection-metal",
        code: "s300-metal",
        i18n: JSON.stringify({ zh: { name: "金属系列" } }),
        catalogRole: "COLLECTION",
        publicSlug: "metal",
        parentId: "family-s300",
        published: true,
      },
      {
        id: "family-z9",
        code: "z9-family",
        i18n: JSON.stringify({ zh: { name: "Z9 家族" } }),
        catalogRole: "family",
        publicSlug: "z9",
        published: true,
      },
      {
        id: "collection-z9",
        code: "z9-main",
        i18n: JSON.stringify({ zh: { name: "Z9 主系列" } }),
        catalogRole: "series",
        publicSlug: "main",
        parentId: "family-z9",
        published: true,
      },
    ],
    products: [
      {
        id: "p1",
        seriesId: "collection-glass",
        slug: "s300-one-gang-glass",
        model: "M-100",
        image: "https://cdn.example.test/img/A.png?width=800",
        gallery: JSON.stringify(["/img/a.png", "/img/detail.png", "/img/detail.png"]),
        specs: JSON.stringify([{ label: "Voltage", value: "250V" }]),
        i18n: JSON.stringify({ zh: { name: "S300 一开" } }),
        published: true,
        functionType: "SWITCH",
        gangCount: 1,
        controlMode: "ONE_WAY",
        classificationStatus: "VERIFIED",
      },
      {
        id: "p2",
        seriesId: "collection-metal",
        slug: "s300-one-gang-metal",
        model: "M - 100",
        image: "/img/b.png",
        gallery: JSON.stringify([]),
        specs: JSON.stringify([{ label: "Voltage", value: "250V" }]),
        i18n: JSON.stringify({ zh: { name: "S300　-　一开" } }),
        published: true,
        functionType: "SWITCH",
        gangCount: 1,
        controlMode: "ONE_WAY",
        classificationStatus: "VERIFIED",
      },
      {
        id: "p3",
        seriesId: "collection-z9",
        slug: "z9-one-gang",
        model: "Z9-1",
        image: "/img/z9.png",
        gallery: JSON.stringify([]),
        specs: JSON.stringify([{ label: "Voltage", value: "250V" }]),
        i18n: JSON.stringify({ zh: { name: "S300 一开" } }),
        published: true,
        functionType: "SWITCH",
        gangCount: 1,
        controlMode: "ONE_WAY",
        classificationStatus: "VERIFIED",
      },
      {
        id: "p4",
        seriesId: null,
        slug: "unclassified-public-product",
        model: null,
        image: null,
        gallery: JSON.stringify([]),
        specs: JSON.stringify([]),
        i18n: JSON.stringify({ zh: { name: "待整理产品" } }),
        published: true,
        functionType: null,
        gangCount: null,
        controlMode: null,
        classificationStatus: "UNCLASSIFIED",
      },
    ],
    variants: [
      {
        id: "v1",
        productId: "p1",
        sku: "S300-M100-WH",
        i18n: JSON.stringify({ zh: { name: "白色", colorName: "白色" } }),
        swatchHex: "#ffffff",
        image: "/img/a.png",
        gallery: JSON.stringify([]),
        widthMm: 86,
        heightMm: 86,
        depthMm: 35,
        published: true,
        legacySynthetic: false,
        dataStatus: "VERIFIED",
        isDefault: true,
      },
      {
        id: "v2",
        productId: "p2",
        sku: null,
        i18n: JSON.stringify({ zh: { name: "旧站默认款" } }),
        image: "/img/b.png",
        gallery: JSON.stringify([]),
        widthMm: null,
        heightMm: null,
        depthMm: null,
        published: true,
        legacySynthetic: true,
        dataStatus: "LEGACY_PLACEHOLDER",
        isDefault: true,
      },
      {
        id: "v3",
        productId: "p3",
        sku: "Z9-1-BK",
        i18n: JSON.stringify({ zh: { name: "黑色", colorName: "黑色" } }),
        finish: "matte black",
        image: "/img/z9.png",
        gallery: JSON.stringify([]),
        widthMm: 86,
        heightMm: 86,
        depthMm: 35,
        published: true,
        legacySynthetic: false,
        dataStatus: "VERIFIED",
        isDefault: true,
      },
      {
        id: "v4",
        productId: "p4",
        sku: null,
        i18n: JSON.stringify({ zh: { name: "未发布款" } }),
        image: "/img/unpublished.png",
        gallery: JSON.stringify([]),
        widthMm: null,
        heightMm: null,
        depthMm: null,
        published: false,
        legacySynthetic: null,
        dataStatus: null,
        isDefault: null,
      },
    ],
    media: [
      {
        productId: "p1",
        role: "main",
        locale: "zh",
        assetId: "asset-a",
        sha256: "HASH-A",
        publicPath: "/img/a.png",
      },
      {
        productId: "p1",
        role: "gallery",
        locale: "en",
        assetId: "asset-a",
        sha256: "hash-a",
        publicPath: "https://cdn.example.test/img/A.png?locale=en",
      },
    ],
  };
}

test("audits declared hierarchy, master-data gaps, and public integrity without merging", () => {
  const report = auditProductCatalog(fixture(), {
    generatedAt: "2026-08-09T00:00:00.000Z",
  });

  assert.equal(report.mode, "read-only");
  assert.equal(report.reviewPolicy.autoMerge, false);
  assert.equal(report.reviewPolicy.databaseWrites, false);
  assert.equal(report.reviewPolicy.candidateStatus, REVIEW_STATUS);
  assert.deepEqual(report.schema.missingContractFields, []);

  assert.equal(report.seriesRoles.counts.family, 2);
  assert.equal(report.seriesRoles.counts.collection, 3);
  assert.equal(report.diagnostics.familyResolutionForProducts.resolved, 3);
  assert.equal(report.diagnostics.familyResolutionForProducts.missing, 1);

  assert.equal(report.completeness.products.fields.model.missing, 1);
  assert.equal(report.completeness.products.fields.specs.missing, 1);
  assert.equal(report.completeness.variants.legacySynthetic.true, 1);
  assert.equal(report.completeness.variants.legacySynthetic.false, 2);
  assert.equal(report.completeness.variants.legacySynthetic.unknown, 1);
  assert.equal(report.completeness.variants.realMaster.total, 2);
  assert.equal(report.completeness.variants.realMaster.fields.sku.missing, 0);

  assert.deepEqual(report.publicIntegrity.productsMissingSeries, [
    { id: "p4", key: "unclassified-public-product" },
  ]);
  assert.deepEqual(report.publicIntegrity.productsMissingImage, [
    { id: "p4", key: "unclassified-public-product" },
  ]);
  assert.deepEqual(report.publicIntegrity.productsWithoutPublishedVariant, [
    { id: "p4", key: "unclassified-public-product" },
  ]);
});

test("emits only needs-review duplicate candidates and keeps families separated", () => {
  const report = auditProductCatalog(fixture());

  assert.equal(report.candidates.sameFamilyNormalizedName.length, 1);
  assert.equal(report.candidates.sameFamilyNormalizedName[0].familyId, "family-s300");
  assert.deepEqual(
    report.candidates.sameFamilyNormalizedName[0].products.map((product) => product.id),
    ["p1", "p2"],
  );
  assert.equal(report.candidates.sameModelMultipleImages.length, 1);
  assert.equal(report.candidates.sameModelMultipleImages[0].normalizedModel, "M-100");
  assert.deepEqual(report.candidates.sameModelMultipleImages[0].productIds, ["p1", "p2"]);

  assert.ok(
    report.candidates.duplicateGalleryPath.some(
      (candidate) => candidate.ownerId === "p1" && candidate.normalizedValue === "/img/a.png",
    ),
  );
  assert.equal(report.candidates.duplicateGalleryHash.length, 1);
  assert.equal(report.candidates.duplicateGalleryHash[0].normalizedValue, "hash-a");

  const candidates = [
    ...report.candidates.sameFamilyNormalizedName,
    ...report.candidates.sameModelMultipleImages,
    ...report.candidates.duplicateGalleryPath,
    ...report.candidates.duplicateGalleryHash,
  ];
  assert.ok(candidates.length > 0);
  assert.ok(candidates.every((candidate) => candidate.reviewStatus === REVIEW_STATUS));
  assert.equal("mergedId" in candidates[0], false);
});

test("reports absent contract columns as unavailable instead of missing data", () => {
  const input = fixture();
  if (!input.fieldAvailability) {
    throw new Error("fixture must declare field availability");
  }
  input.fieldAvailability.series.catalogRole = false;
  input.fieldAvailability.product.functionType = false;
  input.fieldAvailability.variant.legacySynthetic = false;
  input.fieldAvailability.variant.dataStatus = false;

  const report = auditProductCatalog(input);

  assert.ok(report.schema.missingContractFields.includes("series.catalogRole"));
  assert.ok(report.schema.missingContractFields.includes("product.functionType"));
  assert.equal(report.seriesRoles.available, false);
  assert.equal(report.completeness.products.fields.functionType.available, false);
  assert.equal(report.completeness.products.fields.functionType.missing, null);
  assert.equal(report.completeness.products.fields.functionType.unknown, input.products.length);
  assert.equal(report.completeness.variants.legacySynthetic.available, false);
  assert.equal(report.completeness.variants.realMaster.available, false);
  assert.equal(report.completeness.variants.realMaster.total, 0);
  assert.equal(report.missing.variant.dataStatus, null);
});

test("normalizers collapse presentation-only differences but preserve model punctuation", () => {
  assert.equal(normalizeProductName(" S300　-　一开 "), normalizeProductName("s300 一开"));
  assert.equal(normalizeModel(" M - 100 "), "M-100");
  assert.equal(
    normalizeMediaPath("https://cdn.example.test/IMG\\A.PNG?width=800#hero"),
    "/img/a.png",
  );
});
