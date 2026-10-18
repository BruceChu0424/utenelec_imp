-- CreateTable
CREATE TABLE "WebsiteStateAuthority" (
    "id" TEXT NOT NULL,
    "authorityUuid" TEXT NOT NULL,
    "mediaGeneration" INTEGER NOT NULL DEFAULT 0,
    "initializedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "WebsiteStateAuthority_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "WebsiteMediaObject" (
    "publicPath" TEXT NOT NULL,
    "authorityId" TEXT NOT NULL,
    "sha256" TEXT NOT NULL,
    "sizeBytes" INTEGER NOT NULL,
    "state" TEXT NOT NULL DEFAULT 'PENDING',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "WebsiteMediaObject_pkey" PRIMARY KEY ("publicPath")
);

-- CreateTable
CREATE TABLE "Series" (
    "id" TEXT NOT NULL,
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
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Series_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "SeriesMedia" (
    "id" TEXT NOT NULL,
    "seriesId" TEXT NOT NULL,
    "role" TEXT NOT NULL,
    "image" TEXT NOT NULL,
    "i18n" TEXT NOT NULL DEFAULT '{}',
    "sortOrder" INTEGER NOT NULL DEFAULT 0,
    "published" BOOLEAN NOT NULL DEFAULT true,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "SeriesMedia_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Product" (
    "id" TEXT NOT NULL,
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
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Product_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "ProductVariant" (
    "id" TEXT NOT NULL,
    "productId" TEXT NOT NULL,
    "sku" TEXT,
    "i18n" TEXT NOT NULL,
    "swatchHex" TEXT,
    "image" TEXT,
    "gallery" TEXT,
    "finish" TEXT,
    "widthMm" DOUBLE PRECISION,
    "heightMm" DOUBLE PRECISION,
    "depthMm" DOUBLE PRECISION,
    "legacySynthetic" BOOLEAN NOT NULL DEFAULT false,
    "dataStatus" TEXT NOT NULL DEFAULT 'NEEDS_REVIEW',
    "isDefault" BOOLEAN NOT NULL DEFAULT false,
    "published" BOOLEAN NOT NULL DEFAULT true,
    "sortOrder" INTEGER NOT NULL DEFAULT 0,
    "sourceIdentity" TEXT,
    "legacySource" TEXT,
    "legacyId" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "ProductVariant_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "ScenePreset" (
    "id" TEXT NOT NULL,
    "slug" TEXT NOT NULL,
    "i18n" TEXT NOT NULL,
    "backgroundImage" TEXT NOT NULL,
    "config" TEXT NOT NULL,
    "defaultVariantId" TEXT,
    "published" BOOLEAN NOT NULL DEFAULT true,
    "sortOrder" INTEGER NOT NULL DEFAULT 0,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "ScenePreset_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "LegacyImportRun" (
    "id" TEXT NOT NULL,
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
    "appliedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "LegacyImportRun_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "LegacySourceRecord" (
    "id" TEXT NOT NULL,
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
    "scrapedAt" TIMESTAMP(3),
    "rawPayload" TEXT NOT NULL,
    "publishable" BOOLEAN NOT NULL DEFAULT false,
    "seriesId" TEXT,
    "productId" TEXT,
    "variantId" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "LegacySourceRecord_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "LegacyMediaAsset" (
    "id" TEXT NOT NULL,
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
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "LegacyMediaAsset_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "ProductMedia" (
    "id" TEXT NOT NULL,
    "productId" TEXT NOT NULL,
    "variantId" TEXT,
    "assetId" TEXT NOT NULL,
    "role" TEXT NOT NULL,
    "locale" TEXT,
    "sourceUrl" TEXT,
    "sortOrder" INTEGER NOT NULL DEFAULT 0,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "ProductMedia_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "News" (
    "id" TEXT NOT NULL,
    "slug" TEXT NOT NULL,
    "category" TEXT NOT NULL DEFAULT 'company',
    "coverImage" TEXT,
    "i18n" TEXT NOT NULL,
    "publishedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "published" BOOLEAN NOT NULL DEFAULT true,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "News_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "CaseItem" (
    "id" TEXT NOT NULL,
    "slug" TEXT NOT NULL,
    "coverImage" TEXT,
    "i18n" TEXT NOT NULL,
    "sortOrder" INTEGER NOT NULL DEFAULT 0,
    "published" BOOLEAN NOT NULL DEFAULT true,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "CaseItem_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Job" (
    "id" TEXT NOT NULL,
    "slug" TEXT NOT NULL,
    "location" TEXT,
    "department" TEXT,
    "i18n" TEXT NOT NULL,
    "sortOrder" INTEGER NOT NULL DEFAULT 0,
    "published" BOOLEAN NOT NULL DEFAULT true,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "Job_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Setting" (
    "id" TEXT NOT NULL,
    "key" TEXT NOT NULL,
    "i18n" TEXT NOT NULL,

    CONSTRAINT "Setting_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "User" (
    "id" TEXT NOT NULL,
    "username" TEXT NOT NULL,
    "password" TEXT NOT NULL,
    "name" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "User_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Inquiry" (
    "id" TEXT NOT NULL,
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
    "consentAt" TIMESTAMP(3),
    "consentPolicyVersion" TEXT,
    "handled" BOOLEAN NOT NULL DEFAULT false,
    "submissionKey" TEXT,
    "submissionFingerprint" TEXT,
    "sourceContext" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "Inquiry_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "InquiryDelivery" (
    "id" TEXT NOT NULL,
    "inquiryId" TEXT NOT NULL,
    "state" TEXT NOT NULL DEFAULT 'PENDING',
    "erpInquiryId" TEXT,
    "acknowledgedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "InquiryDelivery_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "ImpPortalAuthorization" (
    "requestId" TEXT NOT NULL,
    "codeHash" TEXT NOT NULL,
    "codeChallenge" TEXT NOT NULL,
    "actorId" TEXT NOT NULL,
    "authSessionId" TEXT,
    "employeeId" TEXT,
    "displayName" TEXT NOT NULL,
    "permissions" TEXT NOT NULL,
    "section" TEXT NOT NULL,
    "siteId" TEXT NOT NULL,
    "expiresAt" TIMESTAMP(3) NOT NULL,
    "leaseExpiresAt" TIMESTAMP(3) NOT NULL,
    "consumedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "ImpPortalAuthorization_pkey" PRIMARY KEY ("requestId")
);

-- CreateTable
CREATE TABLE "ImpPortalSession" (
    "id" TEXT NOT NULL,
    "actorId" TEXT NOT NULL,
    "authSessionId" TEXT,
    "employeeId" TEXT,
    "displayName" TEXT NOT NULL,
    "permissions" TEXT NOT NULL,
    "siteId" TEXT NOT NULL,
    "expiresAt" TIMESTAMP(3) NOT NULL,
    "revokedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "ImpPortalSession_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "CmsRevision" (
    "id" TEXT NOT NULL,
    "entityType" TEXT NOT NULL,
    "entityId" TEXT,
    "operation" TEXT NOT NULL,
    "title" TEXT NOT NULL,
    "payload" TEXT NOT NULL,
    "beforeState" TEXT,
    "afterState" TEXT,
    "baseVersion" INTEGER,
    "baseHash" TEXT NOT NULL DEFAULT '',
    "status" TEXT NOT NULL DEFAULT 'DRAFT',
    "createdBy" TEXT NOT NULL,
    "publishedBy" TEXT,
    "publishedAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "CmsRevision_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "CmsAuditEvent" (
    "id" TEXT NOT NULL,
    "actorId" TEXT NOT NULL,
    "action" TEXT NOT NULL,
    "entityType" TEXT NOT NULL,
    "entityId" TEXT,
    "revisionId" TEXT,
    "summary" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "CmsAuditEvent_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "WebsiteDocumentAsset" (
    "id" TEXT NOT NULL,
    "storageKey" TEXT NOT NULL,
    "sha256" TEXT NOT NULL,
    "mimeType" TEXT NOT NULL,
    "originalName" TEXT NOT NULL,
    "sizeBytes" INTEGER NOT NULL,
    "createdBy" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "WebsiteDocumentAsset_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "ResourceDocument" (
    "id" TEXT NOT NULL,
    "slug" TEXT NOT NULL,
    "i18n" TEXT NOT NULL,
    "language" TEXT NOT NULL,
    "version" TEXT NOT NULL,
    "market" TEXT,
    "assetId" TEXT NOT NULL,
    "seriesId" TEXT,
    "productId" TEXT,
    "published" BOOLEAN NOT NULL DEFAULT false,
    "rowVersion" INTEGER NOT NULL DEFAULT 1,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "ResourceDocument_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "WebsiteStateAuthority_authorityUuid_key" ON "WebsiteStateAuthority"("authorityUuid");

-- CreateIndex
CREATE INDEX "WebsiteMediaObject_authorityId_state_idx" ON "WebsiteMediaObject"("authorityId", "state");

-- CreateIndex
CREATE INDEX "WebsiteMediaObject_state_createdAt_idx" ON "WebsiteMediaObject"("state", "createdAt");

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
CREATE UNIQUE INDEX "Inquiry_submissionKey_key" ON "Inquiry"("submissionKey");

-- CreateIndex
CREATE INDEX "Inquiry_handled_idx" ON "Inquiry"("handled");

-- CreateIndex
CREATE INDEX "Inquiry_createdAt_idx" ON "Inquiry"("createdAt");

-- CreateIndex
CREATE INDEX "Inquiry_source_locale_idx" ON "Inquiry"("source", "locale");

-- CreateIndex
CREATE UNIQUE INDEX "InquiryDelivery_inquiryId_key" ON "InquiryDelivery"("inquiryId");

-- CreateIndex
CREATE INDEX "InquiryDelivery_state_createdAt_idx" ON "InquiryDelivery"("state", "createdAt");

-- CreateIndex
CREATE UNIQUE INDEX "ImpPortalAuthorization_codeHash_key" ON "ImpPortalAuthorization"("codeHash");

-- CreateIndex
CREATE INDEX "ImpPortalAuthorization_actorId_expiresAt_idx" ON "ImpPortalAuthorization"("actorId", "expiresAt");

-- CreateIndex
CREATE INDEX "ImpPortalSession_actorId_expiresAt_idx" ON "ImpPortalSession"("actorId", "expiresAt");

-- CreateIndex
CREATE INDEX "CmsRevision_status_createdAt_idx" ON "CmsRevision"("status", "createdAt");

-- CreateIndex
CREATE INDEX "CmsRevision_entityType_entityId_createdAt_idx" ON "CmsRevision"("entityType", "entityId", "createdAt");

-- CreateIndex
CREATE INDEX "CmsAuditEvent_createdAt_idx" ON "CmsAuditEvent"("createdAt");

-- CreateIndex
CREATE UNIQUE INDEX "WebsiteDocumentAsset_storageKey_key" ON "WebsiteDocumentAsset"("storageKey");

-- CreateIndex
CREATE INDEX "WebsiteDocumentAsset_createdAt_idx" ON "WebsiteDocumentAsset"("createdAt");

-- CreateIndex
CREATE UNIQUE INDEX "ResourceDocument_slug_key" ON "ResourceDocument"("slug");

-- CreateIndex
CREATE INDEX "ResourceDocument_published_language_idx" ON "ResourceDocument"("published", "language");

-- CreateIndex
CREATE INDEX "ResourceDocument_productId_idx" ON "ResourceDocument"("productId");

-- CreateIndex
CREATE INDEX "ResourceDocument_seriesId_idx" ON "ResourceDocument"("seriesId");

-- AddForeignKey
ALTER TABLE "WebsiteMediaObject" ADD CONSTRAINT "WebsiteMediaObject_authorityId_fkey" FOREIGN KEY ("authorityId") REFERENCES "WebsiteStateAuthority"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Series" ADD CONSTRAINT "Series_parentId_fkey" FOREIGN KEY ("parentId") REFERENCES "Series"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "SeriesMedia" ADD CONSTRAINT "SeriesMedia_seriesId_fkey" FOREIGN KEY ("seriesId") REFERENCES "Series"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Product" ADD CONSTRAINT "Product_seriesId_fkey" FOREIGN KEY ("seriesId") REFERENCES "Series"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ProductVariant" ADD CONSTRAINT "ProductVariant_productId_fkey" FOREIGN KEY ("productId") REFERENCES "Product"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ScenePreset" ADD CONSTRAINT "ScenePreset_defaultVariantId_fkey" FOREIGN KEY ("defaultVariantId") REFERENCES "ProductVariant"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "LegacySourceRecord" ADD CONSTRAINT "LegacySourceRecord_importRunId_fkey" FOREIGN KEY ("importRunId") REFERENCES "LegacyImportRun"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "LegacySourceRecord" ADD CONSTRAINT "LegacySourceRecord_seriesId_fkey" FOREIGN KEY ("seriesId") REFERENCES "Series"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "LegacySourceRecord" ADD CONSTRAINT "LegacySourceRecord_productId_fkey" FOREIGN KEY ("productId") REFERENCES "Product"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "LegacySourceRecord" ADD CONSTRAINT "LegacySourceRecord_variantId_fkey" FOREIGN KEY ("variantId") REFERENCES "ProductVariant"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ProductMedia" ADD CONSTRAINT "ProductMedia_productId_fkey" FOREIGN KEY ("productId") REFERENCES "Product"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ProductMedia" ADD CONSTRAINT "ProductMedia_variantId_fkey" FOREIGN KEY ("variantId") REFERENCES "ProductVariant"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ProductMedia" ADD CONSTRAINT "ProductMedia_assetId_fkey" FOREIGN KEY ("assetId") REFERENCES "LegacyMediaAsset"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "InquiryDelivery" ADD CONSTRAINT "InquiryDelivery_inquiryId_fkey" FOREIGN KEY ("inquiryId") REFERENCES "Inquiry"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ResourceDocument" ADD CONSTRAINT "ResourceDocument_assetId_fkey" FOREIGN KEY ("assetId") REFERENCES "WebsiteDocumentAsset"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ResourceDocument" ADD CONSTRAINT "ResourceDocument_seriesId_fkey" FOREIGN KEY ("seriesId") REFERENCES "Series"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ResourceDocument" ADD CONSTRAINT "ResourceDocument_productId_fkey" FOREIGN KEY ("productId") REFERENCES "Product"("id") ON DELETE RESTRICT ON UPDATE CASCADE;

