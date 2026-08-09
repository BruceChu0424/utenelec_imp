import { PrismaClient } from '@prisma/client';

const APPLY_CONFIRMATION = 'INTERNATIONAL_SETTINGS_V1';

const settings = [
  {
    key: 'capabilities',
    zh: {
      title: '从市场需求，到可确认的产品方案。',
      subtitle: '面向国际经销商、工程团队与自有品牌采购方，提供选型、开发协同和型号级资料核对支持。',
      intro: '围绕目标市场、安装体系、产品功能、样品和资料要求，形成清晰、可复核的项目范围。',
      qualityBody: '质量与合规资料按具体型号和当前版本确认，不以单一文件代表全部产品。',
      oemBody: '支持围绕产品、表面工艺、标识和包装要求开展 OEM / ODM 可行性评审。',
      documentsBody: '可按型号申请规格、尺寸、安装及适用合规资料。',
    },
    en: {
      title: 'From a market brief to a product decision.',
      subtitle: 'Selection, development coordination and model-specific document support for international distributors, project teams and private-label buyers.',
      intro: 'We define a reviewable scope around the target market, installation system, product functions, samples and document requirements.',
      qualityBody: 'Quality and compliance documents are confirmed by exact model and current revision; no single file represents the whole catalogue.',
      oemBody: 'OEM / ODM feasibility can cover product scope, finish, marking and packaging requirements.',
      documentsBody: 'Request current specifications, dimensions, installation information and applicable compliance documents by model.',
    },
  },
  {
    key: 'partners',
    zh: {
      title: '围绕项目，建立合适的国际合作方式。',
      subtitle: '面向经销、工程选型、设计施工与 OEM / ODM 采购需求。',
      intro: '目标市场、安装体系、产品范围、数量、时间计划与资料要求越清晰，项目响应越准确。',
      processBody: '需求提交后，依次进行商务与技术评审、产品清单与样品计划、规格与条款确认。',
      cta: '提交项目需求',
    },
    en: {
      title: 'Build the right cooperation model around the project.',
      subtitle: 'For distribution, project specification, design and OEM / ODM sourcing.',
      intro: 'A clear target market, installation system, product scope, volume, schedule and document requirement helps the team respond accurately.',
      processBody: 'Each brief moves through commercial and technical review, product and sample planning, then specification and terms confirmation.',
      cta: 'Submit a project brief',
    },
  },
  {
    key: 'resources',
    zh: {
      title: '让信息帮助产品从感兴趣，走向可审批。',
      subtitle: '通过采购指南准备需求、比较系列，并索取型号级资料。',
      intro: '先理解市场、安装体系与产品结构，再进入型号和资料确认。',
      documentsBody: '请提供型号、目标市场和文件用途，由团队确认当前适用的文件版本。',
      faqIntro: '以下答案用于准备首次咨询；商业与技术条件以具体项目确认为准。',
    },
    en: {
      title: 'Information that helps a product move from interest to approval.',
      subtitle: 'Prepare a brief, compare a series and request the right model-specific evidence.',
      intro: 'Start with the market, installation system and product structure before confirming a model and its documents.',
      documentsBody: 'Provide the model, target market and document purpose so the team can confirm the current applicable revision.',
      faqIntro: 'These answers help prepare an initial enquiry; commercial and technical conditions are confirmed by project.',
    },
  },
] as const;

async function main() {
  const apply = process.argv.includes('--apply');
  const confirmation = process.argv.find((argument) => argument.startsWith('--confirm='))?.slice('--confirm='.length);

  if (!apply) {
    console.log('DRY RUN: no database connection or write was performed.');
    console.log(`Planned missing-setting inserts: ${settings.map((setting) => setting.key).join(', ')}`);
    console.log(`To apply: add --apply --confirm=${APPLY_CONFIRMATION}`);
    return;
  }
  if (confirmation !== APPLY_CONFIRMATION) {
    throw new Error(`Apply refused. Pass --confirm=${APPLY_CONFIRMATION} together with --apply.`);
  }

  const prisma = new PrismaClient();
  try {
    const existing = await prisma.setting.findMany({
      where: { key: { in: settings.map((setting) => setting.key) } },
      select: { key: true },
    });
    await prisma.$transaction(
      settings.map((setting) => prisma.setting.upsert({
        where: { key: setting.key },
        create: { key: setting.key, i18n: JSON.stringify({ zh: setting.zh, en: setting.en }) },
        // Never overwrite text that an administrator has already maintained.
        update: {},
      })),
    );
    console.log(`International settings complete: ${settings.length - existing.length} created, ${existing.length} preserved.`);
  } finally {
    await prisma.$disconnect();
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
