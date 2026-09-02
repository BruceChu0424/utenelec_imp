// legacy-series-content-repair 测试的夹具准备脚本（静态内容）。
// 由测试以 `node 本文件 fixture.json` 方式调用；fixture 数据通过 argv 传入，
// 不再把数据内嵌进 node -e 的脚本文本。
const { PrismaClient } = require('@prisma/client');

const client = new PrismaClient({ datasources: { db: { url: process.env.DATABASE_URL } } });
const fixture = JSON.parse(process.argv[2] || '[]');

client.$transaction(async (tx) => {
  for (const item of fixture) {
    const row = await tx.series.findUnique({ where: { sourceIdentity: item.sourceIdentity } });
    if (!row) throw new Error('missing copied fixture Series ' + item.sourceIdentity);
    const i18n = JSON.parse(row.i18n);
    i18n.zh = { ...(i18n.zh || {}), name: item.zh };
    if (item.en === null) delete i18n.en;
    else i18n.en = { ...(i18n.en || {}), name: item.en };
    await tx.series.update({ where: { id: row.id }, data: { i18n: JSON.stringify(i18n) } });
  }
}).finally(() => client.$disconnect());
