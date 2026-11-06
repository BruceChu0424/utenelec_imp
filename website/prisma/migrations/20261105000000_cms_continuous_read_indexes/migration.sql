-- Match the existing CMS sort/filter contracts for bounded keyset snapshots.
-- No business rows, lifecycle rules or pre-existing indexes are changed.
CREATE INDEX "cms_product_order_idx" ON "Product" ("featured" DESC, "sortOrder", "id");
CREATE INDEX "cms_product_series_order_idx" ON "Product" ("seriesId", "featured" DESC, "sortOrder", "id");
CREATE INDEX "cms_series_order_idx" ON "Series" ("sortOrder", "id");
CREATE INDEX "cms_series_options_idx" ON "Series" ("sortOrder", "code", "id");
CREATE INDEX "cms_case_order_idx" ON "CaseItem" ("sortOrder", "id");
CREATE INDEX "cms_job_order_idx" ON "Job" ("sortOrder", "id");
CREATE INDEX "cms_scene_order_idx" ON "ScenePreset" ("sortOrder", "createdAt", "id");
CREATE INDEX "cms_news_order_idx" ON "News" ("publishedAt" DESC, "id");
CREATE INDEX "cms_inquiry_order_idx" ON "Inquiry" ("createdAt" DESC, "id");
CREATE INDEX "cms_resource_order_idx" ON "ResourceDocument" ("updatedAt" DESC, "id");
CREATE INDEX "cms_revision_order_idx" ON "CmsRevision" ("createdAt" DESC, "id");
CREATE INDEX "cms_revision_status_order_idx" ON "CmsRevision" ("status", "createdAt" DESC, "id");
CREATE INDEX "cms_pending_delete_lookup_idx" ON "CmsRevision" ("entityType", "entityId", "status", "operation", "createdBy", "baseHash", "createdAt", "id");
CREATE INDEX "cms_media_order_idx" ON "WebsiteMediaObject" ("state", "createdAt" DESC, "publicPath");
CREATE INDEX "cms_variant_preview_idx" ON "ProductVariant" ("productId", "isDefault" DESC, "sortOrder", "id");
