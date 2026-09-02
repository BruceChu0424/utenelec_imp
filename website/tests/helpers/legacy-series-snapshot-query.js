// legacy-series-content-repair 测试的快照查询脚本（静态内容）。
// 由测试以 `node 本文件 identities.json` 方式调用；数据库 URL 走 DATABASE_URL，
// 关注的 sourceIdentity 列表通过 argv 传入，避免把它拼进脚本代码。
const crypto = require('node:crypto');
const { PrismaClient } = require('@prisma/client');

const client = new PrismaClient({ datasources: { db: { url: process.env.DATABASE_URL } } });
const identities = JSON.parse(process.argv[2] || '[]');

Promise.all([
  client.series.findMany({ orderBy: { id: 'asc' }, select: {
    id: true, sourceIdentity: true, legacySource: true, legacyId: true, code: true,
    parentId: true, published: true, catalogRole: true, publicSlug: true,
  }}),
  client.product.findMany({ orderBy: { id: 'asc' }, select: {
    id: true, sourceIdentity: true, legacyId: true, seriesId: true, published: true,
  }}),
  client.productVariant.findMany({ orderBy: { id: 'asc' }, select: {
    id: true, sourceIdentity: true, legacyId: true, productId: true, published: true,
  }}),
  client.legacySourceRecord.findMany({ orderBy: { id: 'asc' }, select: {
    id: true, importRunId: true, sourceSystem: true, entityType: true, sourceId: true,
    locale: true, identityKey: true, sourceUrl: true, finalUrl: true, sourceHash: true,
    rawHtmlPath: true, rawPayload: true, publishable: true, seriesId: true, productId: true,
    variantId: true,
  }}),
  client.series.findMany({ where: { sourceIdentity: { in: identities } }, select: { sourceIdentity: true, i18n: true } }),
]).then(([series, products, variants, sourceRecords, repaired]) => {
  const sourceAuditDigest = crypto.createHash('sha256').update(JSON.stringify(sourceRecords)).digest('hex');
  console.log(JSON.stringify({
    series, products, variants,
    sourceAudit: { count: sourceRecords.length, digest: sourceAuditDigest },
    repaired: repaired.map((row) => ({ sourceIdentity: row.sourceIdentity, i18n: JSON.parse(row.i18n) }))
      .sort((a, b) => a.sourceIdentity.localeCompare(b.sourceIdentity)),
  }));
}).finally(() => client.$disconnect());
