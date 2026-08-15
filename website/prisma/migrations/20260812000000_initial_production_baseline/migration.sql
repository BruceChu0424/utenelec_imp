-- CreateTable
CREATE TABLE "Series" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "code" TEXT NOT NULL,
    "publicSlug" TEXT,
    "catalogRole" TEXT NOT NULL DEFAULT 'UNCLASSIFIED',
    "rowVersion" INTEGER NOT NULL DEFAULT 1,
    "i18n" TEXT NOT NULL,
    "coverImage" TEXT,
    "sortOrder" INTEGER NOT NULL DEFAULT 0,
    "published" BOOLEAN NOT NULL DEFAULT true,
    "sourceIdentity" TEXT,
    "legacySource" TEXT,
    "legacyId" TEXT,
    "parentId" TEXT,
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" DATETIME NOT NULL,
    CONSTRAINT "Series_parentId_fkey" FOREIGN KEY ("parentId") REFERENCES "Series" ("id") ON DELETE SET NULL ON UPDATE CASCADE
);

-- CreateTable
CREATE TABLE "SeriesMedia" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "seriesId" TEXT NOT NULL,
    "role" TEXT NOT NULL,
    "image" TEXT NOT NULL,
    "i18n" TEXT NOT NULL DEFAULT '{}',
    "sortOrder" INTEGER NOT NULL DEFAULT 0,
    "published" BOOLEAN NOT NULL DEFAULT true,
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" DATETIME NOT NULL,
    CONSTRAINT "SeriesMedia_seriesId_fkey" FOREIGN KEY ("seriesId") REFERENCES "Series" ("id") ON DELETE CASCADE ON UPDATE CASCADE
);

-- CreateTable
CREATE TABLE "Product" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "seriesId" TEXT,
    "slug" TEXT NOT NULL,
    "model" TEXT,
    "category" TEXT,
    "functionType" TEXT,
    "gangCount" INTEGER,
    "controlMode" TEXT,
    "configuration" TEXT,
    "classificationStatus" TEXT NOT NULL DEFAULT 'NEEDS_REVIEW',
    "rowVersion" INTEGER NOT NULL DEFAULT 1,
    "image" TEXT,
    "gallery" TEXT,
    "specs" TEXT,
    "i18n" TEXT NOT NULL,
    "minOrderQty" INTEGER,
    "sceneEnabled" BOOLEAN NOT NULL DEFAULT false,
    "featured" BOOLEAN NOT NULL DEFAULT false,
    "sortOrder" INTEGER NOT NULL DEFAULT 0,
    "published" BOOLEAN NOT NULL DEFAULT true,
    "sourceIdentity" TEXT,
    "legacySource" TEXT,
    "legacyId" TEXT,
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" DATETIME NOT NULL,
    CONSTRAINT "Product_seriesId_fkey" FOREIGN KEY ("seriesId") REFERENCES "Series" ("id") ON DELETE SET NULL ON UPDATE CASCADE
);

-- CreateTable
CREATE TABLE "ProductVariant" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "productId" TEXT NOT NULL,
    "sku" TEXT,
    "i18n" TEXT NOT NULL,
    "swatchHex" TEXT,
    "image" TEXT,
    "gallery" TEXT,
    "finish" TEXT,
    "widthMm" REAL,
    "heightMm" REAL,
    "depthMm" REAL,
    "legacySynthetic" BOOLEAN NOT NULL DEFAULT false,
    "dataStatus" TEXT NOT NULL DEFAULT 'NEEDS_REVIEW',
    "isDefault" BOOLEAN NOT NULL DEFAULT false,
    "published" BOOLEAN NOT NULL DEFAULT true,
    "sortOrder" INTEGER NOT NULL DEFAULT 0,
    "sourceIdentity" TEXT,
    "legacySource" TEXT,
    "legacyId" TEXT,
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" DATETIME NOT NULL,
    CONSTRAINT "ProductVariant_productId_fkey" FOREIGN KEY ("productId") REFERENCES "Product" ("id") ON DELETE CASCADE ON UPDATE CASCADE
);

-- CreateTable
CREATE TABLE "ScenePreset" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "slug" TEXT NOT NULL,
    "i18n" TEXT NOT NULL,
    "backgroundImage" TEXT NOT NULL,
    "config" TEXT NOT NULL,
    "defaultVariantId" TEXT,
    "published" BOOLEAN NOT NULL DEFAULT true,
    "sortOrder" INTEGER NOT NULL DEFAULT 0,
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" DATETIME NOT NULL,
    CONSTRAINT "ScenePreset_defaultVariantId_fkey" FOREIGN KEY ("defaultVariantId") REFERENCES "ProductVariant" ("id") ON DELETE SET NULL ON UPDATE CASCADE
);

-- CreateTable
CREATE TABLE "LegacyImportRun" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "sourceSystem" TEXT NOT NULL,
    "schemaVersion" TEXT NOT NULL,
    "catalogSha256" TEXT NOT NULL,
    "mediaSha256" TEXT NOT NULL,
    "qaReportSha256" TEXT NOT NULL,
    "checkpointSha256" TEXT NOT NULL,
    "bundleSha256" TEXT NOT NULL,
    "qaStatus" TEXT NOT NULL,
    "expectFull" BOOLEAN NOT NULL,
    "inputRoot" TEXT NOT NULL,
    "backupPath" TEXT NOT NULL,
    "stats" TEXT NOT NULL,
    "appliedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- CreateTable
CREATE TABLE "LegacySourceRecord" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "importRunId" TEXT NOT NULL,
    "sourceSystem" TEXT NOT NULL,
    "entityType" TEXT NOT NULL,
    "sourceId" TEXT NOT NULL,
    "locale" TEXT NOT NULL,
    "identityKey" TEXT NOT NULL,
    "sourceUrl" TEXT NOT NULL,
    "finalUrl" TEXT,
    "sourceHash" TEXT NOT NULL,
    "rawHtmlPath" TEXT,
    "scrapedAt" DATETIME,
    "rawPayload" TEXT NOT NULL,
    "publishable" BOOLEAN NOT NULL DEFAULT false,
    "seriesId" TEXT,
    "productId" TEXT,
    "variantId" TEXT,
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "LegacySourceRecord_importRunId_fkey" FOREIGN KEY ("importRunId") REFERENCES "LegacyImportRun" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT "LegacySourceRecord_seriesId_fkey" FOREIGN KEY ("seriesId") REFERENCES "Series" ("id") ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT "LegacySourceRecord_productId_fkey" FOREIGN KEY ("productId") REFERENCES "Product" ("id") ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT "LegacySourceRecord_variantId_fkey" FOREIGN KEY ("variantId") REFERENCES "ProductVariant" ("id") ON DELETE SET NULL ON UPDATE CASCADE
);

-- CreateTable
CREATE TABLE "LegacyMediaAsset" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "sha256" TEXT NOT NULL,
    "mimeType" TEXT NOT NULL,
    "extension" TEXT NOT NULL,
    "bytes" INTEGER NOT NULL,
    "width" INTEGER,
    "height" INTEGER,
    "sourcePath" TEXT NOT NULL,
    "publicPath" TEXT,
    "sourceUrls" TEXT NOT NULL,
    "sourceRefs" TEXT NOT NULL,
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" DATETIME NOT NULL
);

-- CreateTable
CREATE TABLE "ProductMedia" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "productId" TEXT NOT NULL,
    "variantId" TEXT,
    "assetId" TEXT NOT NULL,
    "role" TEXT NOT NULL,
    "locale" TEXT,
    "sourceUrl" TEXT,
    "sortOrder" INTEGER NOT NULL DEFAULT 0,
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "ProductMedia_productId_fkey" FOREIGN KEY ("productId") REFERENCES "Product" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT "ProductMedia_variantId_fkey" FOREIGN KEY ("variantId") REFERENCES "ProductVariant" ("id") ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT "ProductMedia_assetId_fkey" FOREIGN KEY ("assetId") REFERENCES "LegacyMediaAsset" ("id") ON DELETE RESTRICT ON UPDATE CASCADE
);

-- CreateTable
CREATE TABLE "News" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "slug" TEXT NOT NULL,
    "category" TEXT NOT NULL DEFAULT 'company',
    "coverImage" TEXT,
    "i18n" TEXT NOT NULL,
    "publishedAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "published" BOOLEAN NOT NULL DEFAULT true,
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" DATETIME NOT NULL
);

-- CreateTable
CREATE TABLE "CaseItem" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "slug" TEXT NOT NULL,
    "coverImage" TEXT,
    "i18n" TEXT NOT NULL,
    "sortOrder" INTEGER NOT NULL DEFAULT 0,
    "published" BOOLEAN NOT NULL DEFAULT true,
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" DATETIME NOT NULL
);

-- CreateTable
CREATE TABLE "Job" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "slug" TEXT NOT NULL,
    "location" TEXT,
    "department" TEXT,
    "i18n" TEXT NOT NULL,
    "sortOrder" INTEGER NOT NULL DEFAULT 0,
    "published" BOOLEAN NOT NULL DEFAULT true,
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" DATETIME NOT NULL
);

-- CreateTable
CREATE TABLE "Setting" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "key" TEXT NOT NULL,
    "i18n" TEXT NOT NULL
);

-- CreateTable
CREATE TABLE "User" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "username" TEXT NOT NULL,
    "password" TEXT NOT NULL,
    "name" TEXT,
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- CreateTable
CREATE TABLE "Inquiry" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "name" TEXT NOT NULL,
    "phone" TEXT,
    "email" TEXT,
    "company" TEXT,
    "market" TEXT,
    "customerType" TEXT,
    "requiredStandard" TEXT,
    "productInterest" TEXT,
    "requestType" TEXT,
    "estimatedQuantity" TEXT,
    "targetSchedule" TEXT,
    "preferredContact" TEXT,
    "message" TEXT NOT NULL,
    "source" TEXT NOT NULL DEFAULT 'contact',
    "locale" TEXT,
    "consentAt" DATETIME,
    "consentPolicyVersion" TEXT,
    "handled" BOOLEAN NOT NULL DEFAULT false,
    "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- CreateIndex
CREATE UNIQUE INDEX "Series_code_key" ON "Series"("code");

-- CreateIndex
CREATE UNIQUE INDEX "Series_publicSlug_key" ON "Series"("publicSlug");

-- CreateIndex
CREATE UNIQUE INDEX "Series_sourceIdentity_key" ON "Series"("sourceIdentity");

-- CreateIndex
CREATE INDEX "Series_parentId_idx" ON "Series"("parentId");

-- CreateIndex
CREATE INDEX "Series_legacySource_legacyId_idx" ON "Series"("legacySource", "legacyId");

-- CreateIndex
CREATE INDEX "SeriesMedia_seriesId_role_published_idx" ON "SeriesMedia"("seriesId", "role", "published");

-- CreateIndex
CREATE UNIQUE INDEX "Product_slug_key" ON "Product"("slug");

-- CreateIndex
CREATE UNIQUE INDEX "Product_sourceIdentity_key" ON "Product"("sourceIdentity");

-- CreateIndex
CREATE INDEX "Product_seriesId_idx" ON "Product"("seriesId");

-- CreateIndex
CREATE INDEX "Product_featured_idx" ON "Product"("featured");

-- CreateIndex
CREATE INDEX "Product_category_idx" ON "Product"("category");

-- CreateIndex
CREATE INDEX "Product_sceneEnabled_idx" ON "Product"("sceneEnabled");

-- CreateIndex
CREATE INDEX "Product_legacySource_legacyId_idx" ON "Product"("legacySource", "legacyId");

-- CreateIndex
CREATE UNIQUE INDEX "ProductVariant_sourceIdentity_key" ON "ProductVariant"("sourceIdentity");

-- CreateIndex
CREATE INDEX "ProductVariant_productId_idx" ON "ProductVariant"("productId");

-- CreateIndex
CREATE INDEX "ProductVariant_published_idx" ON "ProductVariant"("published");

-- CreateIndex
CREATE INDEX "ProductVariant_legacySource_legacyId_idx" ON "ProductVariant"("legacySource", "legacyId");

-- CreateIndex
CREATE UNIQUE INDEX "ScenePreset_slug_key" ON "ScenePreset"("slug");

-- CreateIndex
CREATE INDEX "ScenePreset_published_idx" ON "ScenePreset"("published");

-- CreateIndex
CREATE INDEX "ScenePreset_sortOrder_idx" ON "ScenePreset"("sortOrder");

-- CreateIndex
CREATE INDEX "ScenePreset_defaultVariantId_idx" ON "ScenePreset"("defaultVariantId");

-- CreateIndex
CREATE UNIQUE INDEX "LegacyImportRun_bundleSha256_key" ON "LegacyImportRun"("bundleSha256");

-- CreateIndex
CREATE INDEX "LegacySourceRecord_sourceSystem_entityType_sourceId_idx" ON "LegacySourceRecord"("sourceSystem", "entityType", "sourceId");

-- CreateIndex
CREATE INDEX "LegacySourceRecord_seriesId_idx" ON "LegacySourceRecord"("seriesId");

-- CreateIndex
CREATE INDEX "LegacySourceRecord_productId_idx" ON "LegacySourceRecord"("productId");

-- CreateIndex
CREATE INDEX "LegacySourceRecord_variantId_idx" ON "LegacySourceRecord"("variantId");

-- CreateIndex
CREATE UNIQUE INDEX "LegacySourceRecord_importRunId_entityType_sourceId_locale_key" ON "LegacySourceRecord"("importRunId", "entityType", "sourceId", "locale");

-- CreateIndex
CREATE UNIQUE INDEX "LegacyMediaAsset_sha256_key" ON "LegacyMediaAsset"("sha256");

-- CreateIndex
CREATE UNIQUE INDEX "LegacyMediaAsset_publicPath_key" ON "LegacyMediaAsset"("publicPath");

-- CreateIndex
CREATE INDEX "ProductMedia_productId_sortOrder_idx" ON "ProductMedia"("productId", "sortOrder");

-- CreateIndex
CREATE INDEX "ProductMedia_variantId_idx" ON "ProductMedia"("variantId");

-- CreateIndex
CREATE INDEX "ProductMedia_assetId_idx" ON "ProductMedia"("assetId");

-- CreateIndex
CREATE UNIQUE INDEX "News_slug_key" ON "News"("slug");

-- CreateIndex
CREATE INDEX "News_category_idx" ON "News"("category");

-- CreateIndex
CREATE INDEX "News_publishedAt_idx" ON "News"("publishedAt");

-- CreateIndex
CREATE UNIQUE INDEX "CaseItem_slug_key" ON "CaseItem"("slug");

-- CreateIndex
CREATE UNIQUE INDEX "Job_slug_key" ON "Job"("slug");

-- CreateIndex
CREATE UNIQUE INDEX "Setting_key_key" ON "Setting"("key");

-- CreateIndex
CREATE UNIQUE INDEX "User_username_key" ON "User"("username");

-- CreateIndex
CREATE INDEX "Inquiry_handled_idx" ON "Inquiry"("handled");

-- CreateIndex
CREATE INDEX "Inquiry_createdAt_idx" ON "Inquiry"("createdAt");

-- CreateIndex
CREATE INDEX "Inquiry_source_locale_idx" ON "Inquiry"("source", "locale");
