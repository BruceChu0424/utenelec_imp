import { PrismaClient } from '@prisma/client';
import { loadEnvConfig } from '@next/env';
import bcrypt from 'bcryptjs';
import * as fs from 'fs';
import * as path from 'path';
import { requireDestructiveSeedApproval, requireStrongAdminSeedPassword } from '../lib/admin-security';

loadEnvConfig(process.cwd());

const prisma = new PrismaClient();
// 读取爬虫解析出的真实数据
const extracted = JSON.parse(
  fs.readFileSync(path.join(process.cwd(), '.scrape', 'seed', 'extracted.json'), 'utf-8'),
) as { series: Record<string, string>; products: any[]; news: any[] };

const i18n = (zh: any, en?: any) => JSON.stringify(en ? { zh, en } : { zh });

// 系列 中文名 -> code(英文 slug)
const nameToCode: Record<string, string> = {
  Z9: 'z9', S300: 's300', Q7: 'q7', Q9: 'q9', Q3: 'q3', 'V4白': 'v4-white',
  A5: 'a5', A8: 'a8', 'A6.0': 'a6', 出口产品: 'export', 液压缓冲式地面插座: 'floor-socket',
  大跷板开关系列: 'rocker-switch', LED微点开关系列: 'led-micro-switch',
  通用电子插座系列: 'universal-socket', 通用电子插座功能件: 'universal-socket-module',
  开关功能件系列: 'switch-module', 纯平开关系列: 'flat-switch',
};

// 系列描述 (首页真实文案)
const seriesDesc: Record<string, { zh: string; en: string }> = {
  z9: {
    zh: 'Z9 以统一的面板比例整合开关、插座与功能件；具体材料、颜色和表面工艺以当前型号资料与实物样板为准。',
    en: 'Z9 brings switches, sockets and functional modules into one coordinated panel language. Confirm material, colour and finish against the current model record and physical sample.',
  },
  s300: {
    zh: 'S300 通过克制的面板轮廓组合多类开关、插座与酒店功能；颜色、材料和可用功能按具体型号确认。',
    en: 'S300 combines a restrained panel profile with switching, socket and hospitality functions. Confirm colours, materials and available functions by exact model.',
  },
  q7: {
    zh: 'Q7 以清晰的翘板比例和利落边框形成统一设计语言，适合在系列内组合不同功能。',
    en: 'Q7 uses a clear rocker proportion and precise frame to keep different functions visually coordinated within the series.',
  },
  q9: {
    zh: 'Q9 以微点控制语言呈现简洁的面板外观；指示、控制与功能配置按具体产品确认。',
    en: 'Q9 presents a concise panel around a micro-control design language. Confirm indication, control and functional configuration by product.',
  },
  q3: {
    zh: 'Q3 采用纯平视觉与点控布局，以简洁线条统一系列外观；结构与性能以具体型号资料为准。',
    en: 'Q3 uses a flush visual treatment and point-control layout to create a consistent, minimal series. Confirm construction and performance by exact model.',
  },
  'v4-white': {
    zh: 'V4 白色系列强调纯平视觉和简洁的面板关系；具体功能、尺寸与表面效果以型号和样板确认。',
    en: 'The white V4 series emphasises a flush visual treatment and a clean panel relationship. Confirm function, dimensions and finish by model and sample.',
  },
  a5: {
    zh: 'A5 以纤薄外观和金属质感为主要设计特征；材料、安装方式与性能参数按具体型号资料确认。',
    en: 'A5 is defined by a slim profile and a metallic visual character. Confirm material, mounting method and performance data by exact model.',
  },
  a8: {
    zh: 'A8 以纤薄面板和模块化功能组合形成系列外观；材料、结构与可用配置按具体型号确认。',
    en: 'A8 combines a slim panel with modular functions in one series language. Confirm material, construction and available configuration by exact model.',
  },
  export: {
    zh: '面向国际项目展示的产品范围；适用市场、安装体系、额定参数与合规资料必须按具体型号确认。',
    en: 'A product range presented for international project enquiries. Destination market, installation system, ratings and compliance documents must be confirmed by exact model.',
  },
  'floor-socket': {
    zh: '地面插座将接口收纳进地面空间；表面工艺、承载、防护与安装条件以具体型号资料为准。',
    en: 'Floor sockets integrate connection points into the floor plane. Confirm finish, load performance, protection and installation conditions by exact model.',
  },
};

const seriesDescDefault = {
  zh: '优腾墙壁开关、插座与功能面板系列；具体材料、功能、尺寸和适用资料按型号确认。',
  en: 'A Uten range of wall switches, sockets and functional panels. Confirm material, function, dimensions and applicable documents by model.',
};

// 产品名 中->英 简易词典
const enDict: [RegExp, string][] = [
  [/一位|一开/g, '1-Gang'], [/二位|二开/g, '2-Gang'], [/三位|三开/g, '3-Gang'],
  [/四位|四开/g, '4-Gang'], [/空白/g, 'Blank'], [/报警/g, 'Alarm'], [/红外|感应/g, 'Sensor'],
  [/电脑|网络/g, 'Network'], [/电视/g, 'TV'], [/空调/g, 'AC'], [/USB/g, 'USB'],
  [/充电/g, 'Charge'], [/取电/g, 'Card-Power'], [/多控/g, 'Multi-Way'], [/双控/g, '2-Way'],
  [/开关/g, 'Switch'], [/插座/g, 'Socket'], [/功能件/g, 'Module'],
];
function toEnName(s: string): string {
  let r = s;
  for (const [re, en] of enDict) r = r.replace(re, en);
  return r;
}

function slug(s: string): string {
  return s.toString().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 80)
    || 'item';
}

function extractModel(description: unknown): string | null {
  const match = String(description || '').match(/型号[：:]\s*([A-Za-z0-9][A-Za-z0-9._/-]*)/);
  return match?.[1] || null;
}

async function main() {
  // Both guardrails fail before the first deleteMany. The explicit approval is
  // separate from the password policy so ordinary app credentials can never
  // accidentally authorize a destructive reset.
  requireDestructiveSeedApproval(process.env.ALLOW_DESTRUCTIVE_SEED);
  const adminPass = requireStrongAdminSeedPassword(process.env.ADMIN_PASSWORD);
  const adminUsername = process.env.ADMIN_USERNAME?.trim() || 'admin';

  console.log('🧹 清空旧数据...');
  await prisma.inquiry.deleteMany();
  await prisma.scenePreset.deleteMany();
  await prisma.productVariant.deleteMany();
  await prisma.product.deleteMany();
  await prisma.series.deleteMany();
  await prisma.news.deleteMany();
  await prisma.caseItem.deleteMany();
  await prisma.job.deleteMany();
  await prisma.setting.deleteMany();
  await prisma.user.deleteMany();

  // 1. 管理员
  await prisma.user.create({
    data: {
      username: adminUsername,
      password: await bcrypt.hash(adminPass, 12),
      name: '管理员',
    },
  });
  console.log(`✓ 管理员创建: ${adminUsername}`);

  // 2. 产品系列: 先建主系列(首页展示), 再建产品涉及的类型系列
  const seriesRecs: Record<string, string> = {}; // name -> id
  let order = 0;
  const mainSeries: [string, string][] = [
    ['Z9', 'z9'], ['S300', 's300'], ['Q7', 'q7'], ['Q9', 'q9'], ['Q3', 'q3'],
    ['V4白', 'v4-white'], ['A5', 'a5'], ['A8', 'a8'], ['A6.0', 'a6'],
    ['出口产品', 'export'], ['液压缓冲式地面插座', 'floor-socket'],
  ];
  for (const [name, code] of mainSeries) {
    const desc = seriesDesc[code] || seriesDescDefault;
    const s = await prisma.series.create({
      data: {
        code, sortOrder: order++,
        i18n: i18n({ name, subtitle: '', description: desc.zh },
                    { name, subtitle: '', description: desc.en }),
      },
    });
    seriesRecs[name] = s.id;
  }
  const seriesNames = new Set<string>();
  for (const p of extracted.products) if (p.series_name) seriesNames.add(p.series_name);
  for (const name of seriesNames) {
    if (seriesRecs[name]) continue;
    let code = nameToCode[name];
    if (!code) {
      const vm = name.match(/V\s*(\d+(?:\.\d)?)/);
      code = vm ? `v${vm[1].replace('.', '-')}` : `series-${++order}`;
    }
    const desc = seriesDesc[code] || seriesDescDefault;
    const s = await prisma.series.create({
      data: {
        code, sortOrder: order++,
        i18n: i18n({ name, subtitle: '', description: desc.zh },
                    { name, subtitle: '', description: desc.en }),
      },
    });
    seriesRecs[name] = s.id;
  }
  console.log(`✓ 系列: ${Object.keys(seriesRecs).length} 个`);

  // 3. 产品
  let pOrder = 0;
  const seedVariantIds: string[] = [];
  for (const p of extracted.products) {
    const sid = p.series_name ? seriesRecs[p.series_name] : null;
    const enName = toEnName(p.name);
    const verifiedEnglishName = /[一-龥]/.test(enName) ? null : enName;
    const product = await prisma.product.create({
      data: {
        slug: `${slug(p.name)}-${pOrder++}`.slice(0, 80),
        seriesId: sid,
        model: extractModel(p.desc),
        category: p.series_name || null,
        image: p.image || null,
        sortOrder: pOrder,
        featured: false,
        sceneEnabled: p.series_name !== '液压缓冲式地面插座',
        i18n: i18n(
          { name: p.name, description: p.desc || (p.series_name ? `${p.series_name}系列` : '') },
          verifiedEnglishName ? { name: verifiedEnglishName, description: '' } : null,
        ),
        variants: {
          create: {
            i18n: i18n({ name: '标准款' }, { name: 'Standard' }),
            image: p.image,
            gallery: JSON.stringify([]),
            published: true,
            sortOrder: 0,
          },
        },
      },
      include: { variants: true },
    });
    seedVariantIds.push(product.variants[0].id);
  }
  console.log(`✓ 产品: ${extracted.products.length} 个`);

  // 4. 场景试装预设。默认款式引用本次 seed 创建的真实产品款式。
  const scenePresets = [
    {
      slug: 'warm-plaster',
      backgroundImage: '/images/scenes/warm-plaster.webp',
      zh: { name: '暖灰艺术墙', description: '柔和暖灰粉刷墙面，适合现代住宅与轻奢空间。' },
      en: { name: 'Warm Plaster', description: 'Soft warm plaster for modern residential and refined interiors.' },
      placement: { x: 50, y: 52, scale: 1, rotation: 0 },
    },
    {
      slug: 'mineral-gallery',
      backgroundImage: '/images/scenes/mineral-gallery.webp',
      zh: { name: '矿物质感展廊', description: '克制的矿物涂层墙面，突出面板材质与轮廓。' },
      en: { name: 'Mineral Gallery', description: 'Restrained mineral texture that emphasizes the panel silhouette.' },
      placement: { x: 50, y: 50, scale: 1, rotation: 0 },
    },
    {
      slug: 'walnut-suite',
      backgroundImage: '/images/scenes/walnut-suite.webp',
      zh: { name: '胡桃木套房', description: '温润胡桃木墙面，适合酒店套房与沉稳家居。' },
      en: { name: 'Walnut Suite', description: 'Warm walnut wall treatment for suites and composed interiors.' },
      placement: { x: 50, y: 51, scale: 1, rotation: 0 },
    },
  ];
  for (let index = 0; index < scenePresets.length; index++) {
    const scene = scenePresets[index];
    await prisma.scenePreset.create({
      data: {
        slug: scene.slug,
        i18n: i18n(scene.zh, scene.en),
        backgroundImage: scene.backgroundImage,
        defaultVariantId: seedVariantIds[index] || seedVariantIds[0] || null,
        config: JSON.stringify({ placement: scene.placement }),
        published: true,
        sortOrder: index,
      },
    });
  }
  console.log(`✓ 场景预设: ${scenePresets.length} 个`);

  // 5. 新闻
  let nIdx = 0;
  for (const n of extracted.news) {
    const d = n.date ? new Date(n.date) : new Date();
    if (isNaN(d.getTime())) continue;
    await prisma.news.create({
      data: {
        slug: `news-${nIdx++}`,
        category: 'company',
        coverImage: n.image || null,
        publishedAt: d,
        // Legacy articles are an audit archive, not current international
        // claims. Editors may republish a reviewed rewrite explicitly.
        published: false,
        i18n: i18n(
          { title: n.title, summary: (n.content || '').slice(0, 80), content: n.content || n.title },
          null,
        ),
      },
    });
  }
  console.log(`✓ 新闻: ${extracted.news.length} 条`);

  // 6. 站点设置
  await prisma.setting.createMany({
    data: [
      { key: 'hero', i18n: i18n(
        { title: '安全用电 · 始于优腾', subtitle: '专注安全墙壁开关与插座的研发制造，为海内外项目提供产品与选型支持',
          cta1: '了解产品', cta2: '联系我们' },
        { title: 'Safe Power · Starts with Uten', subtitle: 'Focused on developing and manufacturing wall switches and sockets, with product and specification support for global projects.',
          cta1: 'Explore Products', cta2: 'Contact Us' }) },
      { key: 'stats', i18n: i18n(
        [{ value: 'R&D', label: '产品研发' }, { value: 'SUPPORT', label: '项目与渠道' },
         { value: '20+', label: '产品系列' }, { value: 'GLOBAL', label: '国际合作' }],
        [{ value: 'R&D', label: 'Product Development' }, { value: 'SUPPORT', label: 'Projects & Channels' },
         { value: '20+', label: 'Product Series' }, { value: 'GLOBAL', label: 'International Enquiries' }]) },
      { key: 'about', i18n: i18n(
        { title: '走进优腾', subtitle: '中山市优腾电器有限公司',
          body: '中山市优腾电器有限公司专注墙壁开关、插座与面板的产品开发和制造。网站所示系列涵盖金属拉丝、PC、镀膜与玻璃等外观方向；具体材质、结构及适用型号以当前样品和型号级资料为准。',
          cta: '了解更多' },
        { title: 'About Uten', subtitle: 'Zhongshan Uten Electrical Co., Ltd.',
          body: 'Zhongshan Uten Electrical Co., Ltd. focuses on product development and manufacturing for wall switches, sockets and panels. The website presents brushed-metal, PC, coated and glass design directions; exact materials, construction and applicable models are confirmed by current samples and model-specific documents.',
          cta: 'Learn More' }) },
      { key: 'craft', i18n: i18n(
        [{ title: '金属拉丝外观', desc: '呈现金属与拉丝纹理；具体基材和表面参数按型号确认' },
         { title: 'PC 面板外观', desc: 'PC 面板配合纹理设计；颜色与适用型号按项目确认' },
         { title: '镀膜外观', desc: '镀膜色调与表面效果以当前系列和确认样品为准' },
         { title: '玻璃面板外观', desc: '玻璃材质、结构与边缘细节以具体型号和技术资料为准' }],
        [{ title: 'Brushed-metal appearance', desc: 'Metal and brushed textures; substrate and surface parameters are confirmed by model' },
         { title: 'PC panel appearance', desc: 'PC panels with textured design; colours and applicable models are confirmed by project' },
         { title: 'Coated appearance', desc: 'Coating tone and surface effect follow the current series and approved sample' },
         { title: 'Glass panel appearance', desc: 'Glass material, construction and edge details are confirmed by exact model and technical documents' }]) },
      { key: 'contact', i18n: i18n(
        { phone: '0760-22125999', phone2: '0760-22125666', email: 'uten002@ch-uten.com',
          address: '广东省中山市小榄镇泰围路8号B幢一楼之一', icp: '粤ICP备2024341039号', company: '中山市优腾电器有限公司' },
        { phone: '+86-760-22125999', phone2: '+86-760-22125666', email: 'uten002@ch-uten.com',
          address: 'Building B, No. 8 Taiwei Road, Xiaolan Town, Zhongshan, Guangdong, China', icp: '', company: 'Zhongshan Uten Electrical Co., Ltd.' }) },
      { key: 'join', i18n: i18n(
        { title: '招商加盟', subtitle: '携手优腾，共赢未来',
          advantages: ['品牌优势 — 多年行业积累，专注电工产品', '产品优势 — 持续研发，覆盖多类面板工艺', '政策优势 — 区域合作与渠道支持', '服务优势 — 提供售前选型与售后对接'],
          cta: '立即申请' },
        { title: 'Partner With Us', subtitle: 'Grow together with Uten',
          advantages: ['Brand — established experience in electrical products', 'Product — continued development across multiple panel finishes', 'Policy — regional cooperation and channel support', 'Service — product selection and after-sales coordination'],
          cta: 'Apply Now' }) },
      { key: 'capabilities', i18n: i18n(
        { title: '从市场需求，到可确认的产品方案。', subtitle: '面向国际经销商、工程团队与自有品牌采购方，提供选型、开发协同和型号级资料核对支持。',
          intro: '围绕目标市场、安装体系、产品功能、样品和资料要求，形成清晰、可复核的项目范围。',
          qualityBody: '质量与合规资料按具体型号和当前版本确认，不以单一文件代表全部产品。',
          oemBody: '支持围绕产品、表面工艺、标识和包装要求开展 OEM / ODM 可行性评审。',
          documentsBody: '可按型号申请规格、尺寸、安装及适用合规资料。' },
        { title: 'From a market brief to a product decision.', subtitle: 'Selection, development coordination and model-specific document support for international distributors, project teams and private-label buyers.',
          intro: 'We define a reviewable scope around the target market, installation system, product functions, samples and document requirements.',
          qualityBody: 'Quality and compliance documents are confirmed by exact model and current revision; no single file represents the whole catalogue.',
          oemBody: 'OEM / ODM feasibility can cover product scope, finish, marking and packaging requirements.',
          documentsBody: 'Request current specifications, dimensions, installation information and applicable compliance documents by model.' }) },
      { key: 'partners', i18n: i18n(
        { title: '围绕项目，建立合适的国际合作方式。', subtitle: '面向经销、工程选型、设计施工与 OEM / ODM 采购需求。',
          intro: '目标市场、安装体系、产品范围、数量、时间计划与资料要求越清晰，项目响应越准确。',
          processBody: '需求提交后，依次进行商务与技术评审、产品清单与样品计划、规格与条款确认。', cta: '提交项目需求' },
        { title: 'Build the right cooperation model around the project.', subtitle: 'For distribution, project specification, design and OEM / ODM sourcing.',
          intro: 'A clear target market, installation system, product scope, volume, schedule and document requirement helps the team respond accurately.',
          processBody: 'Each brief moves through commercial and technical review, product and sample planning, then specification and terms confirmation.', cta: 'Submit a project brief' }) },
      { key: 'resources', i18n: i18n(
        { title: '让信息帮助产品从感兴趣，走向可审批。', subtitle: '通过采购指南准备需求、比较系列，并索取型号级资料。',
          intro: '先理解市场、安装体系与产品结构，再进入型号和资料确认。',
          documentsBody: '请提供型号、目标市场和文件用途，由团队确认当前适用的文件版本。',
          faqIntro: '以下答案用于准备首次咨询；商业与技术条件以具体项目确认为准。' },
        { title: 'Information that helps a product move from interest to approval.', subtitle: 'Prepare a brief, compare a series and request the right model-specific evidence.',
          intro: 'Start with the market, installation system and product structure before confirming a model and its documents.',
          documentsBody: 'Provide the model, target market and document purpose so the team can confirm the current applicable revision.',
          faqIntro: 'These answers help prepare an initial enquiry; commercial and technical conditions are confirmed by project.' }) },
      { key: 'careers', i18n: i18n(
        { title: '人才招聘', subtitle: '与务实、协作的团队一起成长', body: '我们围绕产品、制造、质量、销售与客户服务开展协作。具体开放岗位与任职要求，以网站当前发布信息为准。' },
        { title: 'Careers', subtitle: 'Grow with a practical, collaborative team', body: 'Our teams collaborate across product, manufacturing, quality, sales and customer support. Open roles and requirements are published here when confirmed.' }) },
      { key: 'footer', i18n: i18n(
        { about: '中山市优腾电器有限公司 — 专注墙壁开关、插座与面板的研发制造，为项目与渠道提供选型支持。', copyright: '版权所有' },
        { about: 'Zhongshan Uten Electrical Co., Ltd. develops and manufactures wall switches, sockets and panels, with product selection support for projects and channels.', copyright: 'All rights reserved' }) },
    ],
  });
  console.log('✓ 站点设置: 11 项');

  // 7. 样板工程 (示例)
  const cases = [
    { zh: { title: '融侨锦城项目', location: '湖北武汉', content: '优腾电工在武汉房地产项目融侨锦城列为指定产品。' }, en: { title: 'Rongqiao Jincheng Project', location: 'Wuhan, Hubei', content: 'Uten products designated for the Rongqiao Jincheng real estate project in Wuhan.' } },
    { zh: { title: '泉州经销商大会', location: '福建泉州', content: '优腾Q9新品上市暨电工孵化工程泉州站圆满举行。' }, en: { title: 'Quanzhou Dealer Conference', location: 'Quanzhou, Fujian', content: 'Uten Q9 launch and electrician incubation program — Quanzhou station concluded successfully.' } },
    { zh: { title: '重庆汕头巡回活动', location: '重庆 / 汕头', content: '2017优腾电工孵化工程重庆站、汕头站圆满成功。' }, en: { title: 'Chongqing & Shantou Tour', location: 'Chongqing / Shantou', content: '2017 Uten electrician incubation tour — Chongqing and Shantou stations concluded with success.' } },
  ];
  for (const c of cases) {
    await prisma.caseItem.create({ data: { slug: slug(c.en.title), i18n: i18n(c.zh, c.en), published: false } });
  }
  console.log(`✓ 样板工程: ${cases.length} 个`);

  // 8. 招聘岗位 (示例)
  const jobs = [
    { zh: { title: '外贸业务员', requirements: '本科以上学历，英语流利，有外贸经验优先', description: '负责海外市场开拓与客户维护' }, en: { title: 'Foreign Trade Sales', requirements: "Bachelor's degree, fluent English, trade experience preferred", description: 'Develop overseas markets and maintain client relationships' }, dept: '海外销售' },
    { zh: { title: '产品研发工程师', requirements: '电气或机械相关专业，熟悉面板产品设计', description: '负责新产品的研发与工艺改进' }, en: { title: 'R&D Engineer', requirements: 'Electrical/mechanical background, panel product design', description: 'New product R&D and process improvement' }, dept: '研发中心' },
    { zh: { title: '区域销售经理', requirements: '3年以上建材/电工行业销售经验', description: '负责区域经销商管理与市场拓展' }, en: { title: 'Regional Sales Manager', requirements: '3+ years in building materials / electrical sales', description: 'Manage regional dealers and expand the market' }, dept: '销售中心' },
  ];
  for (const j of jobs) {
    await prisma.job.create({ data: { slug: slug(j.en.title), department: j.dept, i18n: i18n(j.zh, j.en), published: false } });
  }
  console.log(`✓ 招聘岗位: ${jobs.length} 个`);

  console.log('\n🎉 Seed 完成!');
}

main().catch((e) => { console.error(e); process.exit(1); }).finally(() => prisma.$disconnect());
