// catalog-normalization 测试的快照查询脚本（静态内容）。
// 只访问测试通过 DATABASE_URL 指定的正式迁移临时库。
const { PrismaClient } = require('@prisma/client');
const { createHash } = require('node:crypto');

const client = new PrismaClient();

Promise.all([
  client.series.findMany({ orderBy: { id: 'asc' }, select: { id: true, sourceIdentity: true, parentId: true, i18n: true } }),
  client.product.findMany({ orderBy: { id: 'asc' }, select: { id: true, sourceIdentity: true, seriesId: true, published: true, i18n: true } }),
  client.productVariant.findMany({ orderBy: { id: 'asc' }, select: { id: true, sourceIdentity: true, productId: true, i18n: true, widthMm: true } }),
  client.legacySourceRecord.findMany({ orderBy: { id: 'asc' } }),
  client.series.count({ where: { catalogRole: 'FAMILY' } }),
  client.series.count({ where: { catalogRole: 'COLLECTION' } }),
  client.product.count({ where: { classificationStatus: 'INFERRED' } }),
  client.productVariant.count({ where: { legacySynthetic: true, dataStatus: 'NEEDS_REVIEW', isDefault: true } }),
]).then(([seriesRows, productRows, variantRows, sourceRows, families, collections, inferredProducts, syntheticVariants]) => {
  console.log(JSON.stringify({ seriesRows, productRows, variantRows,
    sourceAudit: { count: sourceRows.length, digest: createHash('sha256').update(JSON.stringify(sourceRows)).digest('hex') },
    normalized: { families, collections, inferredProducts, syntheticVariants } }));
}).finally(() => client.$disconnect());
