// catalog-normalization 测试的快照查询脚本（静态内容）。
// 由测试以 `node 本文件 generatedClientPath` 方式调用；生成的 Prisma Client
// 入口路径通过 argv 传入并用 createRequire 定位加载，数据库 URL 走 DATABASE_URL。
const { createRequire } = require('node:module');

const generatedClientEntry = process.argv[2];
const generatedRequire = createRequire(generatedClientEntry);
const { PrismaClient } = generatedRequire('./index.js');

const client = new PrismaClient();

Promise.all([
  client.series.findMany({ orderBy: { id: 'asc' }, select: { id: true, sourceIdentity: true, parentId: true } }),
  client.product.findMany({ orderBy: { id: 'asc' }, select: { id: true, sourceIdentity: true, seriesId: true, published: true } }),
  client.productVariant.findMany({ orderBy: { id: 'asc' }, select: { id: true, sourceIdentity: true, productId: true } }),
]).then(([seriesRows, productRows, variantRows]) => {
  console.log(JSON.stringify({ seriesRows, productRows, variantRows }));
}).finally(() => client.$disconnect());
