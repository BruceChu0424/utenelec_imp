import { PrismaClient } from '@prisma/client';

const APPLY_CONFIRMATION = 'INTERNATIONAL_GUIDES_V1';

type GuideSeed = {
  slug: string;
  publishedAt: Date;
  zh: { title: string; summary: string; content: string };
  en: { title: string; summary: string; content: string };
};

export const INTERNATIONAL_GUIDES: GuideSeed[] = [
  {
    slug: 'choosing-the-right-wiring-standard-for-your-market',
    publishedAt: new Date('2026-08-09T08:00:00.000Z'),
    zh: {
      title: '如何为目标市场选择正确的布线标准',
      summary: '采购开关插座时，应先确认目标市场、项目规范和适用文件，再讨论系列、功能与外观；界面语言不能代替市场合规判断。',
      content: `## 先确认市场，再选择产品

网站语言只决定内容如何显示，不代表产品适用于使用该语言的所有国家或地区。同一种设计可能包含不同的安装结构、额定参数、插座制式或文件组合。任何选型都应从安装所在地和项目规范开始。

## 采购前需要回答的五个问题

- 产品最终安装在哪个国家或地区？
- 项目要求采用哪一种插座制式、底盒尺寸和接线方式？
- 设计文件或招标文件列出了哪些额定参数、标准、测试报告或认证要求？
- 需要哪些功能，例如一位、二位、三位开关，调光、门铃、数据或其他模块？
- 项目是否指定颜色、表面处理、包装、标签或文件语言？

## 发询盘时应提供什么

请提供目标市场、项目类型、拟选系列、功能清单、预计数量、交付计划，以及项目方明确要求的标准或文件。若已有电气图、设备表、底盒图或招标条款，可一并提供，并标注文件版本。

## 最终确认以具体型号为单位

系列名称和效果图用于缩小选择范围，不能替代具体型号确认。下单或项目批准前，应逐项核对具体型号、变体、额定参数、尺寸、目标市场、文件编号、版本、签发日期与有效状态。样品外观也不能代替项目所需的技术或合规文件。`,
    },
    en: {
      title: 'Choosing the Right Wiring Standard for Your Market',
      summary: 'Start with the destination market, project specification and applicable documents before choosing a series, function or finish. Interface language is not a compliance decision.',
      content: `## Start with the market, not the product

Website language only changes how content is displayed. It does not mean that a product is suitable for every country where that language is used. A shared design can still involve different mounting formats, ratings, socket geometries or document sets. Selection should therefore begin with the installation location and the project specification.

## Five questions to answer before sourcing

- In which country or market will the product be installed?
- Which socket geometry, wall box dimensions and wiring method does the project require?
- Which ratings, standards, test reports or certificates are named in the design or tender documents?
- Which functions are required, such as one-gang, two-gang or three-gang switching, dimming, bell, data or other modules?
- Are colour, finish, packaging, labelling or document-language requirements specified?

## What to include in an enquiry

Provide the target market, project type, preferred series, function schedule, estimated quantity and target programme. State every standard or document explicitly requested by the project. If drawings, equipment schedules, wall-box details or tender clauses are available, include them with their revision numbers.

## Approve the exact model, not a family image

A series name and application image help narrow the search, but they do not approve a specific item. Before order or project approval, verify the exact model and variant, ratings, dimensions, destination market, document number, revision, issue date and current validity. A visual sample is not a substitute for the technical or compliance documents required by the project.`,
    },
  },
  {
    slug: 'how-the-uten-product-system-works',
    publishedAt: new Date('2026-08-08T08:00:00.000Z'),
    zh: {
      title: '如何理解 UTEN 产品体系',
      summary: '官网按系列、功能产品和颜色变体组织内容，帮助采购方先理解整体设计，再落实到可核对的具体型号。',
      content: `## 系列是选型入口

在本网站中，系列代表一套共同的设计语言和产品组合。系列封面可以展示多个功能件组合后的整体效果，适合用于设计沟通和初步选型；它并不代表系列中的每个型号具有完全相同的参数或文件。

## 从系列进入具体产品

- 第一层是系列，用于比较外观、组合方式和可用产品范围。
- 第二层是功能产品，例如不同位数的开关、插座或其他功能模块。
- 第三层是具体型号或变体，用于确认颜色、表面处理、图像、尺寸、额定参数及可提供文件。

## 颜色与功能应分开确认

同一功能可能提供多个颜色或表面效果，但并非每一种颜色都一定对应所有功能、市场或项目要求。效果图用于理解空间搭配，采购清单仍应记录具体功能、型号、颜色、数量和目标市场。

## 建立可审核的选型表

建议采购方以“系列—功能—具体型号—变体”的顺序建立清单，并为每一行记录目标市场、数量、文件版本和确认状态。若页面暂未提供完整型号、尺寸或文件，请提交项目资料申请，而不要根据相似图片推断。

## 批准前再次核对

网站内容用于产品发现和项目沟通。最终选型应以当次确认的具体型号、样品、技术资料、项目规范和适用于目标市场的有效文件为准。`,
    },
    en: {
      title: 'How the UTEN Product System Works',
      summary: 'The website organises content by series, functional product and colour variant, helping buyers move from a design system to an exact, reviewable model.',
      content: `## A series is the starting point

On this website, a series represents a shared design language and product grouping. A series cover can show several functions together to support design discussion and early selection. It does not mean that every model in the series has identical ratings or documentation.

## Move from the family to an exact item

- Level one is the series, used to compare appearance, combinations and the available product range.
- Level two is the functional product, such as different switch gangs, sockets or other modules.
- Level three is the exact model or variant, used to confirm colour, finish, imagery, dimensions, ratings and available documents.

## Confirm function and finish separately

A function may be shown in several colours or finishes, but every finish is not automatically available for every function, market or project requirement. Room images help evaluate visual coordination; the procurement schedule should still record the exact function, model, colour, quantity and destination market.

## Build a reviewable selection schedule

Structure the schedule as series, function, exact model and variant. Record the target market, quantity, document revision and approval status for every line. If a page does not yet show a complete model number, dimension or document, submit a project-document request instead of inferring it from a similar image.

## Recheck before approval

Website content supports discovery and project discussion. Final selection should rely on the exact model, approved sample, current technical documents, project specification and valid market-specific documents confirmed for that enquiry.`,
    },
  },
  {
    slug: 'oem-odm-project-brief-checklist',
    publishedAt: new Date('2026-08-07T08:00:00.000Z'),
    zh: {
      title: 'OEM/ODM 项目需求清单',
      summary: '一份结构清晰的项目需求书能减少往返沟通，并让功能、外观、文件、数量和时间计划在评估前保持一致。',
      content: `## 为什么需要项目需求书

“想做一款开关插座”不足以完成项目评估。清晰的需求书让双方在讨论方案前确认市场、功能、边界和交付物，也便于识别仍需测试、打样或第三方确认的事项。

## 建议提供的基本信息

- 目标国家或市场，以及项目使用场景。
- 客户类型和项目类型，例如品牌方、经销商、酒店、住宅或商业项目。
- 参考系列、功能清单、底盒或安装条件。
- 额定参数，以及项目明确要求的标准、测试报告或认证。
- 颜色、表面处理、标识、包装和说明书语言。
- 预计首单数量、年度预测、目标样品日期和目标交付日期。
- 需要的图纸、数据表、样品、包装稿或其他审批资料。

## 将“必须项”和“偏好项”分开

请区分不可变更的项目条件与可讨论的设计偏好。例如，安装尺寸和项目规定的标准可能是必须项，而颜色范围或包装形式可能存在多个方案。这样可以避免用外观选择掩盖关键技术条件。

## 建议的评估顺序

- 确认需求书是否完整，并列出未决问题。
- 逐项确认功能、目标市场和文件要求。
- 讨论可行方案、样品范围、验证步骤和计划节点。
- 在书面确认具体型号、变体、文件版本和商务条件后推进下一阶段。

## 询盘不等于承诺

提交需求书用于启动评估，不代表任何功能、认证、价格、最小数量或交付日期已经被接受。相关内容应在具体项目、型号和市场范围内另行书面确认。`,
    },
    en: {
      title: 'OEM/ODM Project Brief Checklist',
      summary: 'A structured brief reduces repeated clarification and keeps functions, appearance, documents, quantities and timing aligned before feasibility review.',
      content: `## Why a project brief matters

“We need a switch and socket range” is not enough for a project assessment. A clear brief aligns the market, functions, boundaries and expected deliverables before solution work begins. It also identifies items that still require sampling, testing or third-party confirmation.

## Information to include

- Destination country or market and the intended application.
- Customer and project type, such as brand owner, distributor, hospitality, residential or commercial project.
- Reference series, function schedule and wall-box or installation constraints.
- Required ratings and every standard, test report or certificate explicitly named by the project.
- Colour, finish, marking, packaging and instruction-language requirements.
- Estimated first order, annual forecast, target sample date and target delivery date.
- Required drawings, data sheets, samples, packaging artwork or other approval material.

## Separate requirements from preferences

Distinguish non-negotiable project conditions from design preferences. Mounting dimensions and specified standards may be mandatory, while finish range or packaging format may allow several approaches. This prevents an appearance choice from obscuring a critical technical condition.

## A practical review sequence

- Check that the brief is complete and list all open questions.
- Confirm functions, destination market and document requirements line by line.
- Discuss feasible options, sample scope, verification steps and programme gates.
- Proceed only after the exact model, variant, document revisions and commercial conditions are confirmed in writing.

## An enquiry is not an acceptance

Submitting a brief starts an assessment. It does not mean that any function, certificate, price, minimum quantity or delivery date has been accepted. Those points must be confirmed separately for the specific project, model and market scope.`,
    },
  },
  {
    slug: 'product-documents-before-approval',
    publishedAt: new Date('2026-08-06T08:00:00.000Z'),
    zh: {
      title: '产品批准前应核对哪些文件',
      summary: '把技术资料、图纸和合规文件绑定到具体型号、市场与版本，可以减少用错文件、过期文件或相似型号文件的风险。',
      content: `## 文件必须对应具体产品

系列目录或通用宣传页适合初步了解产品，但不能证明某一具体型号满足项目要求。采购和项目批准应建立“型号—变体—市场—文件”的对应关系。

## 常见的资料类别

- 产品数据表：功能、额定参数、材料说明及适用条件。
- 尺寸或安装图：外形、底盒、固定方式和安装空间。
- 接线或安装说明：接线方式、限制和安全提示。
- 测试报告、证书或声明：仅在项目要求且该具体型号可提供时纳入审核。
- 包装、标签和说明书样稿：用于确认型号、语言、标识和版本。

## 每份文件都应记录的字段

至少记录具体型号与变体、目标市场、适用标准、文件或报告编号、版本、签发日期、有效状态及签发机构。文件标题相似并不代表适用范围相同；如存在型号清单或附件，也应一并核对。

## 样品和文件承担不同作用

样品可以确认外观、手感、安装配合和部分功能，但不能自动证明合规范围。反过来，文件也不能替代项目方要求的样品确认、现场适配或验收流程。

## 做好版本与变更控制

在批准记录中保存所用文件版本和确认日期。若型号、材料、结构、标识、目标市场或项目规范发生变化，应重新评估受影响的资料，不要继续沿用旧的批准结论。

## 发现缺口时暂停批准

如果具体型号、市场范围、文件版本或有效状态无法确认，应将该项标记为待确认并申请资料。不要使用相似型号、旧目录截图或未经核实的第三方页面补齐批准记录。`,
    },
    en: {
      title: 'Product Documents Before Approval',
      summary: 'Bind technical, drawing and compliance documents to the exact model, market and revision to reduce the risk of using an expired or look-alike document.',
      content: `## Documents must match an exact product

A series catalogue or general marketing page is useful for discovery, but it does not prove that a specific model meets a project requirement. Procurement and project approval should maintain a model, variant, market and document relationship.

## Common document categories

- Product data sheet: function, ratings, material information and applicable conditions.
- Dimensional or installation drawing: envelope, wall box, fixing method and installation space.
- Wiring or installation instruction: connection method, limitations and safety notes.
- Test report, certificate or declaration: include only when required and available for the exact model under review.
- Packaging, label and instruction artwork: confirm model identity, language, markings and revision.

## Fields to record for every document

Record at least the exact model and variant, destination market, applicable standard, document or report number, revision, issue date, current validity and issuing body. Similar document titles do not guarantee an identical scope. Review any model schedule or annex attached to the document as well.

## Samples and documents serve different purposes

A sample can confirm appearance, feel, installation fit and selected functions, but it does not automatically prove a compliance scope. Likewise, documents do not replace any sample approval, site-fit check or acceptance process required by the project.

## Control revisions and changes

Keep the reviewed document revision and confirmation date in the approval record. If the model, material, construction, marking, destination market or project specification changes, reassess the affected evidence instead of carrying forward an old approval.

## Pause approval when evidence is incomplete

If the exact model, market scope, revision or validity cannot be confirmed, mark the item as pending and request the missing material. Do not complete the record with a similar model, an old catalogue screenshot or an unverified third-party page.`,
    },
  },
];

function guideData(guide: GuideSeed) {
  return {
    slug: guide.slug,
    category: 'guide',
    coverImage: null,
    i18n: JSON.stringify({ zh: guide.zh, en: guide.en }),
    publishedAt: guide.publishedAt,
    published: true,
  };
}

async function main() {
  const apply = process.argv.includes('--apply');
  const confirmation = process.argv.find((arg) => arg.startsWith('--confirm='))?.slice('--confirm='.length);

  if (!apply) {
    console.log('DRY RUN: no database connection or write was performed.');
    console.log(`Planned guide upserts: ${INTERNATIONAL_GUIDES.length}`);
    for (const guide of INTERNATIONAL_GUIDES) console.log(`- ${guide.slug}`);
    console.log(`To apply: add --apply --confirm=${APPLY_CONFIRMATION}`);
    return;
  }

  if (confirmation !== APPLY_CONFIRMATION) {
    throw new Error(`Apply refused. Pass --confirm=${APPLY_CONFIRMATION} together with --apply.`);
  }

  const prisma = new PrismaClient();
  try {
    const slugs = INTERNATIONAL_GUIDES.map((guide) => guide.slug);
    const existing = await prisma.news.findMany({
      where: { slug: { in: slugs } },
      select: { slug: true, category: true },
    });
    const conflicting = existing.filter((item) => item.category !== 'guide');
    if (conflicting.length) {
      throw new Error(`Refusing to reuse non-guide slug(s): ${conflicting.map((item) => item.slug).join(', ')}`);
    }

    await prisma.$transaction(
      INTERNATIONAL_GUIDES.map((guide) => {
        const data = guideData(guide);
        return prisma.news.upsert({
          where: { slug: guide.slug },
          create: data,
          // Preserve later CMS edits when the seed is run again.
          update: {},
        });
      }),
    );

    console.log(`Guide upsert complete: ${INTERNATIONAL_GUIDES.length - existing.length} created, ${existing.length} preserved.`);
  } finally {
    await prisma.$disconnect();
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
