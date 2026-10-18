-- A model-specific document must never become a global public document merely
-- because its product or series is deleted. Require deliberate revision first.
PRAGMA defer_foreign_keys=ON;
PRAGMA foreign_keys=OFF;
CREATE TABLE "new_ResourceDocument" (
  "id" TEXT NOT NULL PRIMARY KEY, "slug" TEXT NOT NULL, "i18n" TEXT NOT NULL,
  "language" TEXT NOT NULL, "version" TEXT NOT NULL, "market" TEXT, "assetId" TEXT NOT NULL,
  "seriesId" TEXT, "productId" TEXT, "published" BOOLEAN NOT NULL DEFAULT false,
  "rowVersion" INTEGER NOT NULL DEFAULT 1, "createdAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, "updatedAt" DATETIME NOT NULL,
  CONSTRAINT "ResourceDocument_assetId_fkey" FOREIGN KEY("assetId") REFERENCES "WebsiteDocumentAsset"("id") ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT "ResourceDocument_seriesId_fkey" FOREIGN KEY("seriesId") REFERENCES "Series"("id") ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT "ResourceDocument_productId_fkey" FOREIGN KEY("productId") REFERENCES "Product"("id") ON DELETE RESTRICT ON UPDATE CASCADE
);
INSERT INTO "new_ResourceDocument" SELECT * FROM "ResourceDocument";
DROP TABLE "ResourceDocument";
ALTER TABLE "new_ResourceDocument" RENAME TO "ResourceDocument";
CREATE UNIQUE INDEX "ResourceDocument_slug_key" ON "ResourceDocument"("slug");
CREATE INDEX "ResourceDocument_published_language_idx" ON "ResourceDocument"("published", "language");
CREATE INDEX "ResourceDocument_productId_idx" ON "ResourceDocument"("productId");
CREATE INDEX "ResourceDocument_seriesId_idx" ON "ResourceDocument"("seriesId");
PRAGMA foreign_keys=ON;
PRAGMA defer_foreign_keys=OFF;
