import { PrismaClient } from '@prisma/client';

const prisma = new PrismaClient();
const confirmation = 'PUBLIC_CLAIMS_V1';
const exampleJobSlugs = ['foreign-trade-sales', 'r-d-engineer', 'regional-sales-manager'];

type LocaleMap = Record<string, unknown>;

const safeSettings: Record<string, { zh: unknown; en: unknown }> = {
  stats: {
    zh: [
      { value: 'R&D', label: '产品研发' },
      { value: 'SUPPORT', label: '项目与渠道' },
      { value: '20+', label: '产品系列' },
      { value: 'GLOBAL', label: '国际合作' },
    ],
    en: [
      { value: 'R&D', label: 'Product Development' },
      { value: 'SUPPORT', label: 'Projects & Channels' },
      { value: '20+', label: 'Product Series' },
      { value: 'GLOBAL', label: 'International Enquiries' },
    ],
  },
  about: {
    zh: {
      title: '走进优腾',
      subtitle: '中山市优腾电器有限公司',
      body: '中山市优腾电器有限公司专注墙壁开关、插座与面板的产品开发和制造。网站所示系列涵盖金属拉丝、PC、镀膜与玻璃等外观方向；具体材质、结构及适用型号以当前样品和型号级资料为准。',
      cta: '了解更多',
    },
    en: {
      title: 'About Uten',
      subtitle: 'Zhongshan Uten Electrical Co., Ltd.',
      body: 'Zhongshan Uten Electrical Co., Ltd. focuses on product development and manufacturing for wall switches, sockets and panels. The website presents brushed-metal, PC, coated and glass design directions; exact materials, construction and applicable models are confirmed by current samples and model-specific documents.',
      cta: 'Learn More',
    },
  },
  craft: {
    zh: [
      { title: '金属拉丝外观', desc: '呈现金属与拉丝纹理；具体基材和表面参数按型号确认' },
      { title: 'PC 面板外观', desc: 'PC 面板配合纹理设计；颜色与适用型号按项目确认' },
      { title: '镀膜外观', desc: '镀膜色调与表面效果以当前系列和确认样品为准' },
      { title: '玻璃面板外观', desc: '玻璃材质、结构与边缘细节以具体型号和技术资料为准' },
    ],
    en: [
      { title: 'Brushed-metal appearance', desc: 'Metal and brushed textures; substrate and surface parameters are confirmed by model' },
      { title: 'PC panel appearance', desc: 'PC panels with textured design; colours and applicable models are confirmed by project' },
      { title: 'Coated appearance', desc: 'Coating tone and surface effect follow the current series and approved sample' },
      { title: 'Glass panel appearance', desc: 'Glass material, construction and edge details are confirmed by exact model and technical documents' },
    ],
  },
  careers: {
    zh: {
      title: '人才招聘',
      subtitle: '与务实、协作的团队一起成长',
      body: '我们围绕产品、制造、质量、销售与客户服务开展协作。具体开放岗位与任职要求，以网站当前发布信息为准。',
    },
    en: {
      title: 'Careers',
      subtitle: 'Grow with a practical, collaborative team',
      body: 'Our teams collaborate across product, manufacturing, quality, sales and customer support. Open roles and requirements are published here when confirmed.',
    },
  },
};

function parseLocaleMap(raw: string, key: string): LocaleMap {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error(`Setting ${key} contains invalid JSON`);
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error(`Setting ${key} must contain a locale object`);
  }
  return parsed as LocaleMap;
}

function mergeSetting(raw: string | null | undefined, key: string): string {
  const current = raw ? parseLocaleMap(raw, key) : {};
  return JSON.stringify({ ...current, ...safeSettings[key] });
}

async function run() {
  const apply = process.argv.includes('--apply');
  const confirmArg = process.argv.find((value) => value.startsWith('--confirm='));
  const confirmed = confirmArg === `--confirm=${confirmation}`;

  const settings = await prisma.setting.findMany({
    where: { key: { in: Object.keys(safeSettings) } },
    select: { key: true, i18n: true },
  });
  const existing = new Map(settings.map((setting) => [setting.key, setting.i18n]));
  const settingChanges = Object.keys(safeSettings).filter(
    (key) => mergeSetting(existing.get(key), key) !== existing.get(key),
  );
  const legacyNews = await prisma.news.findMany({
    where: { published: true, category: { not: 'guide' } },
    select: { id: true, slug: true },
  });
  if (legacyNews.some((item) => !/^news-\d+$/.test(item.slug))) {
    throw new Error('Unexpected published non-guide article; review it manually');
  }
  const exampleJobs = await prisma.job.findMany({
    where: { published: true, slug: { in: exampleJobSlugs } },
    select: { id: true },
  });

  const plan = {
    mode: apply ? 'apply' : 'dry-run',
    settingChanges,
    legacyNewsToUnpublish: legacyNews.length,
    exampleJobsToUnpublish: exampleJobs.length,
  };
  console.log(JSON.stringify(plan, null, 2));
  if (!apply) return;
  if (!confirmed) {
    throw new Error(`Apply requires --confirm=${confirmation}`);
  }

  await prisma.$transaction(async (tx) => {
    for (const key of Object.keys(safeSettings)) {
      await tx.setting.upsert({
        where: { key },
        create: { key, i18n: mergeSetting(undefined, key) },
        update: { i18n: mergeSetting(existing.get(key), key) },
      });
    }
    if (legacyNews.length) {
      await tx.news.updateMany({
        where: { id: { in: legacyNews.map((item) => item.id) }, published: true },
        data: { published: false },
      });
    }
    if (exampleJobs.length) {
      await tx.job.updateMany({
        where: { id: { in: exampleJobs.map((item) => item.id) }, published: true },
        data: { published: false },
      });
    }
  });

  console.log(JSON.stringify({ status: 'applied', ...plan }, null, 2));
}

run()
  .catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
