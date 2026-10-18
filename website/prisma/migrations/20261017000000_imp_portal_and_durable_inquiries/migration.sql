ALTER TABLE "Inquiry" ADD COLUMN "submissionKey" TEXT;
ALTER TABLE "Inquiry" ADD COLUMN "submissionFingerprint" TEXT;
ALTER TABLE "Inquiry" ADD COLUMN "sourceContext" TEXT;
CREATE UNIQUE INDEX "Inquiry_submissionKey_key" ON "Inquiry"("submissionKey");
CREATE TABLE "InquiryDelivery" (
  "id" TEXT NOT NULL PRIMARY KEY, "inquiryId" TEXT NOT NULL, "state" TEXT NOT NULL DEFAULT 'PENDING',
  "erpInquiryId" TEXT, "acknowledgedAt" DATETIME, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "InquiryDelivery_inquiryId_fkey" FOREIGN KEY("inquiryId") REFERENCES "Inquiry"("id") ON DELETE RESTRICT ON UPDATE CASCADE
);
CREATE UNIQUE INDEX "InquiryDelivery_inquiryId_key" ON "InquiryDelivery"("inquiryId");
CREATE INDEX "InquiryDelivery_state_createdAt_idx" ON "InquiryDelivery"("state", "createdAt");
-- Legacy inquiries remain preserved. They are deliberately not forwarded
-- automatically: an operator must review consent and explicitly queue them.
CREATE TABLE "ImpPortalAuthorization" (
  "requestId" TEXT NOT NULL PRIMARY KEY, "codeHash" TEXT NOT NULL, "codeChallenge" TEXT NOT NULL,
  "actorId" TEXT NOT NULL, "employeeId" TEXT, "displayName" TEXT NOT NULL, "permissions" TEXT NOT NULL,
  "section" TEXT NOT NULL, "siteId" TEXT NOT NULL, "expiresAt" DATETIME NOT NULL,
  "leaseExpiresAt" DATETIME NOT NULL, "consumedAt" DATETIME, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX "ImpPortalAuthorization_codeHash_key" ON "ImpPortalAuthorization"("codeHash");
CREATE INDEX "ImpPortalAuthorization_actorId_expiresAt_idx" ON "ImpPortalAuthorization"("actorId", "expiresAt");
CREATE TABLE "ImpPortalSession" (
  "id" TEXT NOT NULL PRIMARY KEY, "actorId" TEXT NOT NULL, "employeeId" TEXT, "displayName" TEXT NOT NULL,
  "permissions" TEXT NOT NULL, "siteId" TEXT NOT NULL, "expiresAt" DATETIME NOT NULL,
  "revokedAt" DATETIME, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX "ImpPortalSession_actorId_expiresAt_idx" ON "ImpPortalSession"("actorId", "expiresAt");
CREATE TABLE "CmsRevision" (
  "id" TEXT NOT NULL PRIMARY KEY, "entityType" TEXT NOT NULL, "entityId" TEXT, "operation" TEXT NOT NULL,
  "title" TEXT NOT NULL, "payload" TEXT NOT NULL, "beforeState" TEXT, "afterState" TEXT,
  "baseVersion" INTEGER, "baseHash" TEXT NOT NULL DEFAULT '', "status" TEXT NOT NULL DEFAULT 'DRAFT', "createdBy" TEXT NOT NULL,
  "publishedBy" TEXT, "publishedAt" DATETIME, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX "CmsRevision_status_createdAt_idx" ON "CmsRevision"("status", "createdAt");
CREATE INDEX "CmsRevision_entityType_entityId_createdAt_idx" ON "CmsRevision"("entityType", "entityId", "createdAt");
CREATE TABLE "CmsAuditEvent" (
  "id" TEXT NOT NULL PRIMARY KEY, "actorId" TEXT NOT NULL, "action" TEXT NOT NULL,
  "entityType" TEXT NOT NULL, "entityId" TEXT, "revisionId" TEXT, "summary" TEXT NOT NULL,
  "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX "CmsAuditEvent_createdAt_idx" ON "CmsAuditEvent"("createdAt");
CREATE TABLE "WebsiteDocumentAsset" (
  "id" TEXT NOT NULL PRIMARY KEY, "storageKey" TEXT NOT NULL, "sha256" TEXT NOT NULL,
  "mimeType" TEXT NOT NULL, "originalName" TEXT NOT NULL, "sizeBytes" INTEGER NOT NULL,
  "createdBy" TEXT NOT NULL, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX "WebsiteDocumentAsset_storageKey_key" ON "WebsiteDocumentAsset"("storageKey");
CREATE INDEX "WebsiteDocumentAsset_createdAt_idx" ON "WebsiteDocumentAsset"("createdAt");
CREATE TABLE "ResourceDocument" (
  "id" TEXT NOT NULL PRIMARY KEY, "slug" TEXT NOT NULL, "i18n" TEXT NOT NULL,
  "language" TEXT NOT NULL, "version" TEXT NOT NULL, "market" TEXT, "assetId" TEXT NOT NULL,
  "seriesId" TEXT, "productId" TEXT, "published" BOOLEAN NOT NULL DEFAULT false,
  "rowVersion" INTEGER NOT NULL DEFAULT 1, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, "updatedAt" DATETIME NOT NULL,
  CONSTRAINT "ResourceDocument_assetId_fkey" FOREIGN KEY("assetId") REFERENCES "WebsiteDocumentAsset"("id") ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT "ResourceDocument_seriesId_fkey" FOREIGN KEY("seriesId") REFERENCES "Series"("id") ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT "ResourceDocument_productId_fkey" FOREIGN KEY("productId") REFERENCES "Product"("id") ON DELETE SET NULL ON UPDATE CASCADE
);
CREATE UNIQUE INDEX "ResourceDocument_slug_key" ON "ResourceDocument"("slug");
CREATE INDEX "ResourceDocument_published_language_idx" ON "ResourceDocument"("published", "language");
CREATE INDEX "ResourceDocument_productId_idx" ON "ResourceDocument"("productId");
CREATE INDEX "ResourceDocument_seriesId_idx" ON "ResourceDocument"("seriesId");
