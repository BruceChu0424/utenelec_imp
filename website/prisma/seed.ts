/* eslint-disable @typescript-eslint/no-explicit-any */
import { PrismaClient } from '@prisma/client';
import bcrypt from 'bcryptjs';
import * as fs from 'fs';
import * as path from 'path';

const prisma = new PrismaClient();
// 读取爬虫解析出的真实数据
const extracted = JSON.parse(
  fs.readFileSync(path.join(process.cwd(), '.scrape', 'seed', 'extracted.json'), 'utf-8'),
) as { series: Record<string, string>; products: any[]; news: any[] };

const i18n = (zh: any, en: any) => JSON.stringify({ zh, en });

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
    zh: '环保塑料土豪金面框，香槟金功能件，散发出金色尊贵的气息，材质感得到极度彰显，精心选材设计，充分展示现代精工制造的魅力。',
    en: 'Premium gold ABS faceplate with champagne-gold functional parts, radiating nobility and refined material quality — a showcase of modern precision manufacturing.',
  },
  s300: {
    zh: '贵族气质的土豪金拉丝面框与时尚靓丽的功能件相搭配，透露出您的品味和格调，整体外观美观、大方、和谐。',
    en: 'Aristocratic brushed-gold faceplate paired with stylish functional parts — reflecting taste and elegance in a harmonious, dignified look.',
  },
  q7: {
    zh: '经典与时尚、尊贵与简雅的完美融合。不锈钢拉丝面板，翘板按钮，时尚纯美结合设计。',
    en: 'A perfect fusion of classic and modern, noble and elegant. Stainless steel brushed panel with rocker button — pure, stylish design.',
  },
  q9: {
    zh: '微点时尚开关，触动家居精简生活；精湛工艺，臻于完美，一体化成型；LED指示灯，仿佛黑夜灯塔，引领光明前行。',
    en: 'Micro-point fashion switch for refined living. Masterful one-piece molding with LED indicator — a beacon in the night guiding the light.',
  },
  q3: {
    zh: '100%纯平点控，鼠标点触全新体验；纯平设计，使灰尘无处藏身，高效防尘。利落金属线条勾勒简洁造型。',
    en: '100% flat point-control, a mouse-click touch experience. Flush design leaves dust nowhere to hide. Clean metal lines define a minimalist form.',
  },
  'v4-white': {
    zh: '纯平超薄，点击复位、时尚纯美结合设计，开关按键与面板始终保持在同一平面，使灰尘无处落脚，从而达到防尘效果。',
    en: 'Ultra-slim flat design with click-reset. Button and panel stay flush — dust has nowhere to settle, achieving an effective dust-proof result.',
  },
  a5: {
    zh: '纯平超薄外观设计，优质金属质感材料；安装牢固，省心安全；钛铝合金拉丝面板，手感舒适，经久耐用。',
    en: 'Ultra-slim flat design in premium metal. Secure installation, worry-free safety. Titanium-aluminum brushed panel — comfortable, durable touch.',
  },
  a8: {
    zh: '钛铝合金拉丝面板，超薄外观设计；真正意义上的点动开关模块化封装，结构可靠、稳定，品质优良。',
    en: 'Titanium-aluminum brushed panel, ultra-slim profile. True modular point-action switching — reliable structure, stable, premium quality.',
  },
  export: {
    zh: '专为海外市场研发的出口产品系列，符合国际电工标准，满足不同国家和地区的用电安全规范。',
    en: 'Export series engineered for overseas markets, compliant with international electrical standards and regional safety regulations.',
  },
  'floor-socket': {
    zh: '地插座表面经拉丝工艺处理，具有较高的抗压强度和防护功能，可起到很好的装饰效果，美观高雅，品质卓越。',
    en: 'Floor socket with brushed surface treatment, high compressive strength and protection — fine decoration, elegant and outstanding quality.',
  },
};

const seriesDescDefault = {
  zh: '优腾精工制造系列，选用优质材料，工艺精湛，安全可靠，为您提供高品质的电气面板产品。',
  en: 'A Uten precision-manufactured series — premium materials, masterful craftsmanship, safe and reliable high-quality electrical panels.',
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

async function main() {
  console.log('🧹 清空旧数据...');
  await prisma.inquiry.deleteMany();
  await prisma.product.deleteMany();
  await prisma.series.deleteMany();
  await prisma.news.deleteMany();
  await prisma.caseItem.deleteMany();
  await prisma.job.deleteMany();
  await prisma.setting.deleteMany();
  await prisma.user.deleteMany();

  // 1. 管理员
  const adminPass = process.env.ADMIN_PASSWORD || 'uten2024';
  await prisma.user.create({
    data: {
      username: process.env.ADMIN_USERNAME || 'admin',
      password: await bcrypt.hash(adminPass, 10),
      name: '管理员',
    },
  });
  console.log('✓ 管理员创建: admin');

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
  for (const p of extracted.products) {
    const sid = p.series_name ? seriesRecs[p.series_name] : null;
    const enName = toEnName(p.name);
    await prisma.product.create({
      data: {
        slug: `${slug(p.name)}-${pOrder++}`.slice(0, 80),
        seriesId: sid,
        image: p.image || null,
        sortOrder: pOrder,
        featured: false,
        i18n: i18n(
          { name: p.name, description: p.desc || (p.series_name ? `${p.series_name}系列` : '') },
          { name: /[一-龥]/.test(enName) ? p.name : enName, description: '' },
        ),
      },
    });
  }
  console.log(`✓ 产品: ${extracted.products.length} 个`);

  // 4. 新闻
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
        i18n: i18n(
          { title: n.title, summary: (n.content || '').slice(0, 80), content: n.content || n.title },
          { title: n.title, summary: '', content: '' },
        ),
      },
    });
  }
  console.log(`✓ 新闻: ${extracted.news.length} 条`);

  // 5. 站点设置
  await prisma.setting.createMany({
    data: [
      { key: 'hero', i18n: i18n(
        { title: '安全用电 · 始于优腾', subtitle: '25年专注安全墙壁开关与插座，高新技术企业，产品远销海外',
          cta1: '了解产品', cta2: '联系我们' },
        { title: 'Safe Power · Starts with Uten', subtitle: '25 years focused on safe wall switches and sockets. Hi-tech enterprise. Exported worldwide.',
          cta1: 'Explore Products', cta2: 'Contact Us' }) },
      { key: 'stats', i18n: i18n(
        [{ value: '25+', label: '年行业深耕' }, { value: '高新技术', label: '企业认证' },
         { value: '20+', label: '产品系列' }, { value: '全球', label: '产品出口' }],
        [{ value: '25+', label: 'Years of Expertise' }, { value: 'Hi-Tech', label: 'Certified Enterprise' },
         { value: '20+', label: 'Product Series' }, { value: 'Global', label: 'Worldwide Export' }]) },
      { key: 'about', i18n: i18n(
        { title: '走进优腾', subtitle: '中山市优腾电器有限公司',
          body: '中山市优腾电器有限公司，多年专注于研发、生产安全墙壁开关、插座。是一家致力于为客户提供高品质通用面板产品，集研发、生产和销售于一体的高新技术企业。公司创建25年来，深耕面板研发领域，自主研发的金属不锈钢拉丝面板、PC拉丝面板、真空镀膜面板、高强度钢化玻璃面板，工艺和性能位居行业前列。',
          cta: '了解更多' },
        { title: 'About Uten', subtitle: 'Zhongshan Uten Electrical Co., Ltd.',
          body: 'Zhongshan Uten Electrical Co., Ltd. has focused on R&D and manufacturing of safe wall switches and sockets for years. A high-tech enterprise integrating R&D, production and sales of premium electrical panels. Over 25 years of deep cultivation in panel R&D — our self-developed stainless steel brushed, PC brushed, vacuum-coated and tempered glass panels lead the industry in craftsmanship and performance.',
          cta: 'Learn More' }) },
      { key: 'craft', i18n: i18n(
        [{ title: '不锈钢拉丝面板', desc: '细腻拉丝工艺，金属质感，经久耐用' },
         { title: 'PC拉丝面板', desc: '高强度PC材质，抗冲击，阻燃安全' },
         { title: '真空镀膜面板', desc: '真空镀膜工艺，色泽均匀，质感尊贵' },
         { title: '钢化玻璃面板', desc: '高强度钢化玻璃，防爆易清洁，高端大气' }],
        [{ title: 'Stainless Steel Brushed', desc: 'Fine brushed finish, metallic, durable' },
         { title: 'PC Brushed Panel', desc: 'High-strength PC, impact-resistant, flame-retardant' },
         { title: 'Vacuum Coated Panel', desc: 'Vacuum coating, even tone, premium feel' },
         { title: 'Tempered Glass Panel', desc: 'High-strength tempered glass, safe and premium' }]) },
      { key: 'contact', i18n: i18n(
        { phone: '0760-22125999', phone2: '0760-221256', email: 'sales@ch-uten.com',
          address: '广东省中山市', icp: '粤ICP备2024341039号', company: '中山市优腾电器有限公司' },
        { phone: '+86-760-22125999', phone2: '+86-760-221256', email: 'sales@ch-uten.com',
          address: 'Zhongshan, Guangdong, China', icp: '', company: 'Zhongshan Uten Electrical Co., Ltd.' }) },
      { key: 'join', i18n: i18n(
        { title: '招商加盟', subtitle: '携手优腾，共赢未来',
          advantages: ['品牌优势 — 25年行业积淀，高新技术企业', '产品优势 — 自主研发，工艺领先', '政策优势 — 区域保护，全方位扶持', '服务优势 — 完善的售前售后体系'],
          cta: '立即申请' },
        { title: 'Partner With Us', subtitle: 'Grow together with Uten',
          advantages: ['Brand — 25 years of industry heritage', 'Product — Self-developed, leading craft', 'Policy — Regional protection, full support', 'Service — Complete pre/post-sales system'],
          cta: 'Apply Now' }) },
      { key: 'careers', i18n: i18n(
        { title: '人才招聘', subtitle: '精英团队，人均行业经验5年以上', body: '公司架构清晰，建立了生产、研发、检验检测、销售、企划及客户服务等完备部门，精英团队成员高学历高素质，是一支开拓创新、积极进取的团队。' },
        { title: 'Careers', subtitle: 'Elite team with 5+ years average experience', body: 'Clear structure with complete departments across production, R&D, testing, sales, planning and customer service — an innovative, driven team.' }) },
      { key: 'footer', i18n: i18n(
        { about: '中山市优腾电器有限公司 — 专注安全墙壁开关与插座，高新技术企业，产品远销海外。', copyright: '版权所有' },
        { about: 'Zhongshan Uten Electrical Co., Ltd. — focused on safe wall switches and sockets. Hi-tech enterprise, exported worldwide.', copyright: 'All rights reserved' }) },
    ],
  });
  console.log('✓ 站点设置: 8 项');

  // 6. 样板工程 (示例)
  const cases = [
    { zh: { title: '融侨锦城项目', location: '湖北武汉', content: '优腾电工在武汉房地产项目融侨锦城列为指定产品。' }, en: { title: 'Rongqiao Jincheng Project', location: 'Wuhan, Hubei', content: 'Uten products designated for the Rongqiao Jincheng real estate project in Wuhan.' } },
    { zh: { title: '泉州经销商大会', location: '福建泉州', content: '优腾Q9新品上市暨电工孵化工程泉州站圆满举行。' }, en: { title: 'Quanzhou Dealer Conference', location: 'Quanzhou, Fujian', content: 'Uten Q9 launch and electrician incubation program — Quanzhou station concluded successfully.' } },
    { zh: { title: '重庆汕头巡回活动', location: '重庆 / 汕头', content: '2017优腾电工孵化工程重庆站、汕头站圆满成功。' }, en: { title: 'Chongqing & Shantou Tour', location: 'Chongqing / Shantou', content: '2017 Uten electrician incubation tour — Chongqing and Shantou stations concluded with success.' } },
  ];
  for (const c of cases) {
    await prisma.caseItem.create({ data: { slug: slug(c.en.title), i18n: i18n(c.zh, c.en) } });
  }
  console.log(`✓ 样板工程: ${cases.length} 个`);

  // 7. 招聘岗位 (示例)
  const jobs = [
    { zh: { title: '外贸业务员', requirements: '本科以上学历，英语流利，有外贸经验优先', description: '负责海外市场开拓与客户维护' }, en: { title: 'Foreign Trade Sales', requirements: "Bachelor's degree, fluent English, trade experience preferred", description: 'Develop overseas markets and maintain client relationships' }, dept: '海外销售' },
    { zh: { title: '产品研发工程师', requirements: '电气或机械相关专业，熟悉面板产品设计', description: '负责新产品的研发与工艺改进' }, en: { title: 'R&D Engineer', requirements: 'Electrical/mechanical background, panel product design', description: 'New product R&D and process improvement' }, dept: '研发中心' },
    { zh: { title: '区域销售经理', requirements: '3年以上建材/电工行业销售经验', description: '负责区域经销商管理与市场拓展' }, en: { title: 'Regional Sales Manager', requirements: '3+ years in building materials / electrical sales', description: 'Manage regional dealers and expand the market' }, dept: '销售中心' },
  ];
  for (const j of jobs) {
    await prisma.job.create({ data: { slug: slug(j.en.title), department: j.dept, i18n: i18n(j.zh, j.en) } });
  }
  console.log(`✓ 招聘岗位: ${jobs.length} 个`);

  console.log('\n🎉 Seed 完成!');
}

main().catch((e) => { console.error(e); process.exit(1); }).finally(() => prisma.$disconnect());
