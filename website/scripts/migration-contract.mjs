export const websiteMigrationTables = [
  'websiteStateAuthority', 'websiteMediaObject', 'series', 'seriesMedia', 'product', 'productVariant', 'scenePreset',
  'news', 'caseItem', 'job', 'setting', 'user', 'legacyImportRun', 'legacySourceRecord', 'legacyMediaAsset', 'productMedia',
  'inquiry', 'inquiryDelivery', 'impPortalAuthorization', 'impPortalSession', 'cmsRevision', 'cmsAuditEvent', 'websiteDocumentAsset', 'resourceDocument',
];
export function assertMigrationModelCoverage(schema) {
  const models = [...schema.matchAll(/^model\s+(\w+)\s*\{/gm)].map(m => m[1][0].toLowerCase() + m[1].slice(1));
  const missing = models.filter(model => !websiteMigrationTables.includes(model));
  const unknown = websiteMigrationTables.filter(model => !models.includes(model));
  if (missing.length || unknown.length || new Set(websiteMigrationTables).size !== websiteMigrationTables.length) {
    throw new Error(`Migration model coverage mismatch: missing=${missing.join(',')}; unknown=${unknown.join(',')}`);
  }
  return models.length;
}
