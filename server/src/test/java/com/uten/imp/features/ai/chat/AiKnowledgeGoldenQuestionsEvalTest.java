package com.uten.imp.features.ai.chat;

import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * ADR-153 retrieval evaluation over a golden set of everyday questions (colloquial Chinese, typos kept on purpose)
 * across every business area. The index is built from the repository's docs/ exactly as production does (the same
 * include/exclude policy, chunker and BM25 index); each question is searched as a reader who holds only the question's
 * own domain (plus SELF), which is what a department user sees.
 *
 * <p>Three numbers per question:
 * <ul>
 *   <li>raw top-k: the ranked chunks before any threshold (hit@1/3/5 = an expected document among the first k);</li>
 *   <li>answer-time: the chunks {@link AiDocKnowledge#search} actually hands to the model (thresholds, relative floor,
 *       matched-term rule, per-document cap), and whether {@link AiChatDialogueSupport#dataLookup} skips the search;</li>
 *   <li>for NO_DOC questions (nothing in the design documents answered them when the set was written): how many
 *       unrelated chunks are still sent, which invites a confident answer built on the wrong rules. Chunks of the
 *       user-facing documents written for them since (the glossary, the assistant's guide, the access guide, the notice
 *       page's questions) are related, not unrelated.</li>
 * </ul>
 * The full table is written to {@code ai-knowledge-golden-eval.txt} in the build directory. The floors at the end are
 * regression guards: raise them when retrieval improves, never lower them to make a change pass.
 */
class AiKnowledgeGoldenQuestionsEvalTest {
    private static final Set<String> ALL = Set.of("SELF", "SALES", "PRODUCTION", "PURCHASE", "WAREHOUSE", "FINANCE",
            "ADMIN", "QUALITY", "SUBCONTRACT", "HR", "RD");

    /**
     * One golden question.
     *
     * @param domain   the reader's domain (SELF = every employee); the reader holds this domain and SELF only
     * @param kind     HOW / WHY / MEANING / STATUS / PERMISSION / WHERE / DATA
     * @param expected path fragments of the documents that answer it (any one is a hit); empty = NO_DOC
     * @param truth    for NO_DOC: where the truth lives instead
     * @param related  for NO_DOC: path fragments of user-facing documents written for it since; their chunks are related
     */
    record Golden(String id, String area, String domain, String kind, String question, List<String> expected, String truth,
                  List<String> related) {
        boolean noDoc() { return expected.isEmpty(); }
    }

    private static Golden q(String id, String area, String domain, String kind, String question, String... expected) {
        return new Golden(id, area, domain, kind, question, List.of(expected), "", List.of());
    }

    private static Golden none(String id, String area, String domain, String kind, String question, String truth,
                               String... related) {
        return new Golden(id, area, domain, kind, question, List.of(), truth, List.of(related));
    }

    private static final String GLOSSARY = "07-业务链路/00-业务术语与状态总表";
    private static final String ACCESS_GUIDE = "03-页面/我的权限与申请开通";
    private static final String ASSISTANT_GUIDE = "03-页面/AI工作助手使用说明";
    /** The NO_DOC questions that still got unrelated chunks when the set was written (qa-eval 3). */
    static final List<String> MEASURED_NO_DOC = List.of("X03", "B04", "G01", "D02");

    static final List<Golden> GOLDEN = List.of(
            // 销售
            q("S01", "销售", "SALES", "HOW", "报价单怎么转成订货单啊",
                    "ADR-139-", "ADR-134-", "07-业务链路/01-销售订货到发货", "03-页面/销售报价财务核价页",
                    "03-页面/销售报价单编辑页", "03-页面/销售订货单编辑页"),
            q("S02", "销售", "SALES", "STATUS", "出货单有几个状态 仓库那边要点几下才算出库",
                    "03-页面/销售出货仓库作业页", "ADR-084-"),
            q("S03", "销售", "SALES", "WHY", "客户退回来得货 退货单审完了能直接再卖吗",
                    "07-业务链路/06-销售退货", "03-页面/销售退货质检冻结处置页", "ADR-024-"),
            q("S04", "销售", "SALES", "HOW", "货不够的时候先给哪个客户发 谁说了算",
                    "03-页面/销售缺货仲裁页", "07-业务链路/05-销售现货预留"),
            q("S05", "销售", "SALES", "HOW", "送样品给客户不收钱 要走什么流程",
                    "03-页面/客户零星发货与出货财务审核", "07-业务链路/2026-09-07-客户零星发货"),
            // The answer is 销售订单财务审核页 §3.1 (销售侧驳回修订闭环); the SOP's 2.1 is about quotes, not orders.
            q("S06", "销售", "SALES", "HOW", "订货单被财务退回来了 改完怎么重新提交",
                    "03-页面/销售订单财务审核页", "ADR-040-", "03-页面/销售订货单编辑页"),
            q("S07", "销售", "SALES", "WHERE", "销售订单做到哪一步了在哪里看进度",
                    "03-页面/销售订单生产进度", "03-页面/销售订单进度详情页", "ADR-041-"),
            // 报价核价
            q("Q01", "报价核价", "FINANCE", "MEANING", "财务核价到底核啥 可以直接改单价吗",
                    "03-页面/销售报价财务核价页", "ADR-134-", "ADR-139-"),
            q("Q02", "报价核价", "SALES", "HOW", "客户发来的excel报价单能自动识别填进去吗 认错了货品咋办",
                    "ADR-134-", "ADR-136-", "07-业务链路/01-销售订货到发货", "03-页面/销售报价单编辑页"),
            q("Q03", "报价核价", "SALES", "STATUS", "报价议价以后要客户确认了才能转订货吗",
                    "ADR-139-", "03-页面/销售报价单编辑页"),
            q("Q04", "报价核价", "SALES", "WHERE", "这个货品以前给客户报过什么价 在哪里能看到",
                    "ADR-139-", "03-页面/销售报价财务核价页", "03-页面/销售报价单编辑页"),
            // 采购
            q("P01", "采购", "PURCHASE", "WHY", "供应商多送了一些货 能收吗 多出来的咋办",
                    "ADR-144-", "03-页面/仓库到货登记页"),
            q("P02", "采购", "PURCHASE", "STATUS", "到货以后是先入库还是先质检",
                    "ADR-090-", "03-页面/入库任务中心页", "03-页面/仓库到货登记页"),
            q("P03", "采购", "PURCHASE", "HOW", "采购单已经批准了还能改数量吗",
                    "ADR-072-", "03-页面/采购订货单编辑页"),
            q("P04", "采购", "PURCHASE", "HOW", "采购应付款月底怎么结账",
                    "ADR-047-", "03-页面/采购委外应付结算工作台"),
            q("P05", "采购", "PURCHASE", "MEANING", "采购订货单上的价格会自动带出上次的吗 学习模式是啥",
                    "ADR-068-", "03-页面/采购订货单编辑页"),
            // 委外
            q("C01", "委外", "SUBCONTRACT", "WHY", "为啥我下不了委外单 按钮是灰得",
                    "ADR-156-", "03-页面/委外申请页"),
            q("C02", "委外", "SUBCONTRACT", "HOW", "委外回来少了几个 算短交吗 怎么处理",
                    "ADR-098-", "03-页面/委外回厂短交判定页"),
            q("C03", "委外", "SUBCONTRACT", "HOW", "委外发料要发哪些料 怎么发",
                    "ADR-143-", "03-页面/委外发料单页", "07-业务链路/08-委外全链路"),
            q("C04", "委外", "SUBCONTRACT", "HOW", "委外的货分好几批回来 怎么登记",
                    "ADR-143-", "07-业务链路/08-委外全链路"),
            q("C05", "委外", "SUBCONTRACT", "HOW", "委外损耗怎么结清 会不会改订货数量",
                    "ADR-114-", "ADR-098-"),
            // 生产
            q("M01", "生产", "PRODUCTION", "HOW", "报工数量是填累计的还是这次做的",
                    "03-页面/生产执行分段与报工页"),
            q("M02", "生产", "PRODUCTION", "HOW", "生产做多了 超产的那部分怎么处理",
                    "03-页面/生产超产与追加处理说明", "ADR-118-"),
            q("M03", "生产", "PRODUCTION", "STATUS", "报工完了合格的成品怎么进仓库",
                    "ADR-054-", "ADR-058-", "03-页面/产成品待点收任务页", "ADR-148-", "ADR-090-"),
            q("M04", "生产", "PRODUCTION", "HOW", "生产完剩下的料怎么退回仓库",
                    "ADR-078-", "ADR-086-", "03-页面/生产执行分段与报工页"),
            // The file name says 一键生成 but its title (the indexed name) is 联合排产…; the current entry is the analysis page.
            q("M05", "生产", "PRODUCTION", "HOW", "生产计划能一键把子计划都生成吗",
                    "03-页面/生产计划单一键生成与全链路溯源设计", "ADR-081-", "03-页面/生产物料分析页"),
            // 物料分析
            q("A01", "物料分析", "PRODUCTION", "MEANING", "物料分析里面计划产出量是咋算得",
                    "ADR-099-"),
            q("A02", "物料分析", "PRODUCTION", "HOW", "物料分析那张表能直接下单吗 怎么下",
                    "ADR-102-", "03-页面/生产物料分析页"),
            q("A03", "物料分析", "PRODUCTION", "STATUS", "追加的自制会并到原来的生产计划里吗",
                    "ADR-104-"),
            q("A04", "物料分析", "PRODUCTION", "MEANING", "让料是什么意思",
                    "ADR-049-"),
            q("A05", "物料分析", "PRODUCTION", "WHY", "待排产里的数量为啥比订单数量少",
                    "ADR-088-", "03-页面/生产调度工作台"),
            // 车间
            q("W01", "车间", "PRODUCTION", "MEANING", "车间直送是啥 跟送仓库有啥区别",
                    "ADR-087-", "ADR-089-", "ADR-127-", "03-页面/生产执行分段与报工页"),
            q("W02", "车间", "PRODUCTION", "WHY", "为什么报工的时候转不了下一道工序",
                    "ADR-127-", "03-页面/生产执行分段与报工页"),
            q("W03", "车间", "PRODUCTION", "HOW", "车间内料仓怎么开通",
                    "ADR-147-", "03-页面/车间内料仓设置页", "07-业务链路/车间内料仓上线与使用说明", "03-页面/车间内料仓页"),
            q("W04", "车间", "PRODUCTION", "HOW", "内料仓月底盘点完 用量是怎么算出来的",
                    "ADR-131-", "03-页面/车间内料仓用量与结算页", "03-页面/车间内料仓盘点页", "07-业务链路/车间内料仓上线与使用说明"),
            q("W05", "车间", "PRODUCTION", "HOW", "开工前路线选错了还能换吗",
                    "ADR-095-", "ADR-096-", "ADR-091-", "03-页面/我的车间任务页"),
            // 仓库
            q("H01", "仓库", "WAREHOUSE", "PERMISSION", "盘点数对不上 谁来审核 审核之前库存会变吗",
                    "03-页面/库存盘点审核页", "03-页面/仓库任务中心页", "ADR-149-"),
            q("H02", "仓库", "WAREHOUSE", "MEANING", "不良品仓里的东西算不算可用库存",
                    "ADR-146-"),
            q("H03", "仓库", "WAREHOUSE", "HOW", "入库的时候没称重 单重是怎么算出来的",
                    "ADR-135-"),
            q("H04", "仓库", "WAREHOUSE", "WHY", "我为啥看不到别的仓库的单子",
                    "ADR-149-", "ADR-115-"),
            q("H05", "仓库", "WAREHOUSE", "MEANING", "即时库存里显示的金额是怎么来的",
                    "ADR-055-", "03-页面/即时库存页"),
            q("H06", "仓库", "WAREHOUSE", "MEANING", "主仓和分仓是啥关系 停用的仓库还能选吗",
                    "ADR-145-"),
            // 质检
            q("K01", "质检", "QUALITY", "STATUS", "待检的货能先领去用吗",
                    "ADR-090-", "03-页面/待检处置页"),
            q("K02", "质检", "QUALITY", "HOW", "成品质检不合格的怎么处理",
                    "ADR-054-", "ADR-076-", "03-页面/生产成品质检任务页", "03-页面/品质部检查结果页", "07-业务链路/生产品质恢复与反向约束"),
            q("K03", "质检", "QUALITY", "MEANING", "IQC合格待入库是什么意思",
                    "03-页面/采购委外IQC合格待入库任务页", "ADR-090-"),
            // 财务钱流
            q("F01", "财务钱流", "FINANCE", "HOW", "出货的时候汇率按哪天的算",
                    "ADR-097-"),
            q("F02", "财务钱流", "FINANCE", "HOW", "客户预付的钱怎么抵后面的订单",
                    "ADR-048-", "03-页面/钱流单据页"),
            q("F03", "财务钱流", "FINANCE", "HOW", "账户余额和银行对不上 怎么查",
                    "ADR-051-"),
            q("F04", "财务钱流", "FINANCE", "HOW", "资产待摊每个月是怎么摊的",
                    "ADR-018-", "03-页面/资产与待摊管理页"),
            q("F05", "财务钱流", "FINANCE", "MEANING", "待收和应收有啥区别",
                    "ADR-030-"),
            q("F06", "财务钱流", "FINANCE", "HOW", "外币收款银行扣了手续费 怎么记",
                    "ADR-053-"),
            q("F07", "财务钱流", "FINANCE", "HOW", "货品成本是怎么算出来的",
                    "ADR-138-", "03-页面/货品成本工作台", "ADR-055-"),
            // 人事
            q("R01", "人事", "HR", "HOW", "新员工入职 工号是怎么生成的",
                    "ADR-020-", "03-页面/入职流程页"),
            q("R02", "人事", "HR", "WHERE", "试用期快到了 转正提醒在哪看",
                    "ADR-021-", "03-页面/HR任务中心"),
            q("R03", "人事", "HR", "PERMISSION", "工资条怎么生成 生成完要谁审核",
                    "03-页面/工资条生成页", "03-页面/工资条审核页"),
            q("R04", "人事", "HR", "HOW", "员工离职了 他手上的客户怎么交接",
                    "ADR-050-", "03-页面/离职流程页"),
            // 证件核对
            q("I01", "证件核对", "HR", "WHY", "身份证号填错了还能给他开账号吗",
                    "ADR-154-"),
            q("I02", "证件核对", "HR", "MEANING", "证件核对任务是干嘛的 谁来处理",
                    "ADR-154-", "03-页面/HR任务中心"),
            // 报销 (every employee)
            q("E01", "报销", "SELF", "PERMISSION", "谁能审批报销啊",
                    "07-业务链路/员工报销全链路-SOP", "03-页面/报销审批列表页", "ADR-094-"),
            q("E02", "报销", "SELF", "HOW", "报销要交哪些票据",
                    "07-业务链路/员工报销合规依据与凭证清单", "07-业务链路/员工报销全链路-SOP", "ADR-094-"),
            // 权限
            q("X01", "权限", "FINANCE", "PERMISSION", "财务审批是谁来审 审核组是怎么回事",
                    "ADR-027-"),
            none("X02", "权限", "ADMIN", "PERMISSION", "怎么给新来的同事开权限",
                    "docs/03-页面/权限管理页.md, ADR-109, ADR-045 are excluded from packaging; code: features/authorization",
                    ACCESS_GUIDE, GLOSSARY),
            none("X03", "权限", "SELF", "PERMISSION", "我打不开采购页面 是没权限吗 找谁开",
                    "docs/03-页面/权限管理页.md and ADR-007/ADR-109 excluded; nothing packaged says who grants access",
                    ACCESS_GUIDE, GLOSSARY),
            // 工作台与通知
            q("B01", "工作台通知", "SELF", "MEANING", "红色数字和黄色数字有啥区别",
                    "00-项目准则/14-徽章与计数口径", "ADR-100-"),
            none("B02", "工作台通知", "SELF", "MEANING", "黄框是什么意思",
                    "AiChatKnowledge.UI_CONVENTIONS catalog entry; docs/02-组件库/UtenInput.md (not packaged); ADR-150 (excluded)",
                    GLOSSARY, "03-页面/订货单公共表头规范"),
            q("B03", "工作台通知", "SELF", "WHY", "工作台上为啥看不到别的部门的卡片",
                    "ADR-011-", "03-页面/工作台首页"),
            // ADR-063's 撤回 is the system withdrawing a review notice once the task is done, not a publisher's recall.
            none("B04", "工作台通知", "SELF", "HOW", "发出去的通知能撤回吗",
                    "NoticeController has no recall endpoint (only per-recipient batch-delete); no document says so",
                    "03-页面/通知发布页", "03-页面/通知列表页", "03-页面/通知详情页"),
            q("B05", "工作台通知", "SELF", "WHY", "登录的时候老弹审核待办的窗口 怎么关掉",
                    "ADR-063-"),
            // AI 助手自身
            none("G01", "AI助手", "SELF", "MEANING", "ai助手会把我得数据发给外面吗",
                    "AiChatKnowledge.AI_PRIVACY catalog entry; ADR-153 (excluded)", ASSISTANT_GUIDE),
            none("G02", "AI助手", "SELF", "HOW", "你能直接帮我下单吗",
                    "ADR-141/ADR-150 (excluded); AiChatActionProposalService confirmation cards", ASSISTANT_GUIDE, GLOSSARY),
            q("G03", "AI助手", "SALES", "MEANING", "ai识别客户文件会自己学习吗 学的什么",
                    "ADR-134-", "ADR-136-"),
            // 系统设置
            q("T01", "系统设置", "SELF", "HOW", "字太小了看不清 怎么调大",
                    "03-页面/设置页", "00-项目准则/13-适老化UX基线"),
            q("T02", "系统设置", "SELF", "HOW", "登录密码怎么改",
                    "03-页面/我的页", "03-页面/设置页"),
            q("T03", "系统设置", "ADMIN", "MEANING", "系统设置里的清空业务数据是干嘛的 会删掉客户资料吗",
                    "ADR-155-"),
            // 数据问题 (answered by tools, never by documents)
            none("D01", "数据", "SELF", "DATA", "我还有几个待办",
                    "workbench_tasks / my_workbench tools (WorkbenchAiChatTool, DashboardAiChatTool)"),
            none("D02", "数据", "SALES", "DATA", "SO-2026-0012这个订单发货了没",
                    "no sales-order or shipment lookup tool exists (sales order and shipment tables only)"));

    private static AiDocKnowledge docs;
    private static List<AiDocChunker.Chunk> chunks;

    @BeforeAll static void build() {
        docs = AiDocKnowledge.fromDirectory(Path.of("..", "docs"));
        chunks = docs.chunks();
    }

    static Set<String> reader(String domain) {
        return "SELF".equals(domain) ? Set.of("SELF") : Set.of("SELF", domain);
    }

    /** The raw ranking from the same index answering uses (its vocabulary, glossary and priors), before any threshold. */
    private static List<AiDocIndex.Hit> ranking(String question, Set<String> domains, int limit) {
        return docs.ranking(question, domains, limit);
    }

    private static boolean expected(Golden golden, AiDocChunker.Chunk chunk) {
        return golden.expected().stream().anyMatch(fragment -> chunk.path().contains(fragment));
    }

    /** 1-based rank of the first expected chunk, 0 when none is ranked. */
    private static int firstRank(Golden golden, List<AiDocIndex.Hit> hits) {
        for (int i = 0; i < hits.size(); i++) if (expected(golden, chunks.get(hits.get(i).chunk()))) return i + 1;
        return 0;
    }

    private static String shortPath(String path) {
        String name = path.substring(path.lastIndexOf('/') + 1).replaceFirst("\\.md$", "");
        if (name.startsWith("ADR-")) return name.length() > 7 ? name.substring(0, 7) : name;
        String dir = path.contains("/") ? path.substring(0, path.indexOf('/')) : "";
        return dir.replaceFirst("-.*", "") + "/" + (name.length() > 18 ? name.substring(0, 18) : name);
    }

    private static String section(AiDocChunker.Chunk chunk) {
        String value = chunk.section().isEmpty() ? "(intro)" : chunk.section();
        return value.length() > 40 ? value.substring(0, 40) + "…" : value;
    }

    record Outcome(Golden golden, int rank, int rankAll, boolean answered, boolean answerHit, int answerChunks,
                   boolean searched, boolean inIndex, boolean visibleToReader, int unrelated) {}

    /** Chunks sent for a NO_DOC question that come from none of the documents written for it. */
    private static int unrelated(Golden golden, List<AiDocChunker.Chunk> picked) {
        return (int) picked.stream().filter(chunk -> golden.related().stream().noneMatch(chunk.path()::contains)).count();
    }

    @Test void goldenQuestionsReport() throws IOException {
        StringBuilder out = new StringBuilder();
        out.append(String.format(Locale.ROOT, "AI knowledge golden eval: %d chunks from %d documents, %d questions%n%n",
                chunks.size(), chunks.stream().map(AiDocChunker.Chunk::path).distinct().count(), GOLDEN.size()));
        List<Outcome> outcomes = new ArrayList<>();
        for (Golden golden : GOLDEN) {
            Set<String> domains = reader(golden.domain());
            List<AiDocIndex.Hit> full = ranking(golden.question(), domains, Integer.MAX_VALUE);
            List<AiDocIndex.Hit> fullAll = ranking(golden.question(), ALL, Integer.MAX_VALUE);
            boolean searched = !AiChatDialogueSupport.dataLookup(golden.question());
            List<AiDocChunker.Chunk> picked = searched ? docs.search(golden.question(), domains) : List.of();
            boolean inIndex = chunks.stream().anyMatch(chunk -> expected(golden, chunk));
            boolean visible = chunks.stream().anyMatch(chunk -> expected(golden, chunk) && AiDocKnowledge.visible(chunk, domains));
            Outcome outcome = new Outcome(golden, firstRank(golden, full), firstRank(golden, fullAll), !picked.isEmpty(),
                    picked.stream().anyMatch(chunk -> expected(golden, chunk)), picked.size(), searched, inIndex, visible,
                    golden.noDoc() ? unrelated(golden, picked) : 0);
            outcomes.add(outcome);

            out.append(String.format(Locale.ROOT, "[%s] %s/%s/%s 「%s」%n", golden.id(), golden.area(), golden.domain(),
                    golden.kind(), golden.question()));
            out.append("   expect: ").append(golden.noDoc() ? "NO_DOC - " + golden.truth()
                            + (golden.related().isEmpty() ? "" : "; written since: " + String.join(", ", golden.related()))
                            : String.join(", ", golden.expected()))
                    .append(String.format(Locale.ROOT, "  inIndex=%s visible=%s searched=%s%n", inIndex, visible, searched));
            out.append("   terms: ").append(docs.keyTerms(golden.question())).append('\n');
            for (int i = 0; i < Math.min(5, full.size()); i++) {
                AiDocChunker.Chunk chunk = chunks.get(full.get(i).chunk());
                out.append(String.format(Locale.ROOT, "   %d. %6.2f m%d %s %s | %s%n", i + 1, full.get(i).score(),
                        full.get(i).matched(), expected(golden, chunk) ? "*" : " ", shortPath(chunk.path()), section(chunk)));
            }
            out.append(String.format(Locale.ROOT, "   rank(reader)=%s rank(all)=%s answer-time: %d chunk(s)%s%n",
                    outcome.rank() == 0 ? "-" : outcome.rank(), outcome.rankAll() == 0 ? "-" : outcome.rankAll(), picked.size(),
                    picked.isEmpty() ? "" : " " + picked.stream().map(chunk -> (expected(golden, chunk) ? "*" : "")
                            + shortPath(chunk.path())).toList()));
            if (!golden.noDoc()) {
                // Rank of each expected document's best chunk (0 = not ranked: no shared term, hidden or not indexed).
                List<String> perDocument = new ArrayList<>();
                for (String fragment : golden.expected()) {
                    int at = 0;
                    for (int i = 0; i < full.size() && at == 0; i++) {
                        if (chunks.get(full.get(i).chunk()).path().contains(fragment)) at = i + 1;
                    }
                    perDocument.add(fragment + "=" + (at == 0 ? "-" : at));
                }
                out.append("   expected ranks: ").append(perDocument).append('\n');
            }
            out.append('\n');
        }

        // Metrics over the questions the documents answer.
        List<Outcome> answerable = outcomes.stream().filter(outcome -> !outcome.golden().noDoc()).toList();
        out.append(metrics("ALL (doc-answerable)", answerable));
        Map<String, List<Outcome>> byArea = new LinkedHashMap<>();
        for (Outcome outcome : answerable) byArea.computeIfAbsent(outcome.golden().area(), key -> new ArrayList<>()).add(outcome);
        byArea.forEach((area, list) -> out.append(metrics(area, list)));
        Map<String, List<Outcome>> byDomain = new TreeMap<>();
        for (Outcome outcome : answerable) byDomain.computeIfAbsent(outcome.golden().domain(), key -> new ArrayList<>()).add(outcome);
        out.append('\n');
        byDomain.forEach((domain, list) -> out.append(metrics("domain " + domain, list)));
        Map<String, List<Outcome>> byKind = new TreeMap<>();
        for (Outcome outcome : answerable) byKind.computeIfAbsent(outcome.golden().kind(), key -> new ArrayList<>()).add(outcome);
        out.append('\n');
        byKind.forEach((kind, list) -> out.append(metrics("kind " + kind, list)));

        List<Outcome> noDoc = outcomes.stream().filter(outcome -> outcome.golden().noDoc()).toList();
        out.append(String.format(Locale.ROOT, "%nNO_DOC questions: %d; documents still sent to the model for %d: %s%n",
                noDoc.size(), noDoc.stream().filter(Outcome::answered).count(),
                noDoc.stream().filter(Outcome::answered).map(outcome -> outcome.golden().id()).toList()));
        out.append("NO_DOC unrelated chunks sent: ").append(noDoc.stream()
                .map(outcome -> outcome.golden().id() + "=" + outcome.unrelated()).toList()).append('\n');
        out.append("Misses (no expected document in reader top-5): ")
                .append(answerable.stream().filter(outcome -> outcome.rank() == 0 || outcome.rank() > 5)
                        .map(outcome -> outcome.golden().id() + "(r=" + outcome.rank() + ",all=" + outcome.rankAll()
                                + (outcome.visibleToReader() ? "" : ",hidden") + ")").toList())
                .append('\n');
        out.append("Answer-time misses (expected document not among the chunks sent): ")
                .append(answerable.stream().filter(outcome -> !outcome.answerHit())
                        .map(outcome -> outcome.golden().id() + (outcome.answered() ? "" : "(nothing sent)")).toList())
                .append('\n');
        // ADR-159: no doc-answerable question gets the restricted-subject answer from its own reader; the live questions
        // about another department's rules (N2, N3 as a sales reader) do.
        List<String> restrictedFalse = answerable.stream()
                .filter(outcome -> docs.restrictedTopic(outcome.golden().question(), reader(outcome.golden().domain())).isPresent())
                .map(outcome -> outcome.golden().id()).toList();
        out.append("Restricted-subject answer on doc-answerable questions (must be none): ").append(restrictedFalse).append('\n');
        Map<String, String> restrictedLive = new LinkedHashMap<>();
        for (String question : RESTRICTED_LIVE) {
            restrictedLive.put(question, docs.restrictedTopic(question, LIVE_SALES_READER).map(Object::toString).orElse("-"));
        }
        out.append("Restricted-subject answer for the live sales reader: ").append(restrictedLive).append('\n');

        String report = out.toString();
        System.out.println(report);
        Path file = buildDirectory().resolve("ai-knowledge-golden-eval.txt");
        Files.createDirectories(file.getParent());
        Files.writeString(file, report, StandardCharsets.UTF_8);

        long hit3 = answerable.stream().filter(outcome -> outcome.rank() >= 1 && outcome.rank() <= 3).count();
        long hit5 = answerable.stream().filter(outcome -> outcome.rank() >= 1 && outcome.rank() <= 5).count();
        long answerHits = answerable.stream().filter(Outcome::answerHit).count();
        long cleanNoDoc = noDoc.stream().filter(outcome -> MEASURED_NO_DOC.contains(outcome.golden().id()))
                .filter(outcome -> outcome.unrelated() == 0).count();
        // Regression floors (see the comment on the constants): raise them as retrieval improves.
        assertThat(hit3).as("doc-answerable golden questions with an expected document in the reader's top 3")
                .isGreaterThanOrEqualTo(HIT3_FLOOR);
        assertThat(hit5).as("doc-answerable golden questions with an expected document in the reader's top 5")
                .isGreaterThanOrEqualTo(HIT5_FLOOR);
        assertThat(answerHits).as("doc-answerable golden questions whose expected document reaches the model")
                .isGreaterThanOrEqualTo(ANSWER_HIT_FLOOR);
        assertThat(cleanNoDoc).as("measured NO_DOC questions (" + MEASURED_NO_DOC + ") sent no unrelated chunk")
                .isGreaterThanOrEqualTo(CLEAN_NO_DOC_FLOOR);
        assertThat(restrictedFalse).as("doc-answerable questions answered as another department's rules").isEmpty();
        assertThat(restrictedLive).as("live questions about another department's rules").doesNotContainValue("-");
    }

    /** The reader of the live non-administrator pass (qa-live-after 4): sales and subcontract, no finance or personnel. */
    static final Set<String> LIVE_SALES_READER = Set.of("SELF", "SALES", "SUBCONTRACT");
    /** Live N3 and N2 (and N2's short form): the rules are finance's and personnel's. */
    static final List<String> RESTRICTED_LIVE = List.of("货品成本是怎么算出来的", "工资条怎么生成 生成完要谁审核", "工资条怎么生成");

    /*
     * Measured on the 68 doc-answerable questions:
     *   2026-10-05 (before Phase B): hit@3 = 60, hit@5 = 60, answer-time hit = 59; NO_DOC X03, B04, G01, D02 each got
     *   six unrelated chunks.
     *   2026-10-06 (P0-4/5/6, P1-2, P2-1, file names and aliases, and the documents written for P1-8): hit@3 = 68,
     *   hit@5 = 68, answer-time hit = 68; of X03, B04, G01, D02 three get no unrelated chunk.
     *   2026-10-06 (ADR-159 section-level domains, restricted-subject answer, sections marked as replaced): hit@1 = 58,
     *   hit@3 = 68, hit@5 = 68, answer-time hit = 68, three clean NO_DOC; no doc-answerable question gets the
     *   restricted-subject answer, and the live N2 and N3 questions of a sales reader do.
     * The floors are the achieved values: an ordinary document edit that costs a hit is looked at, not waved through.
     */
    static final long HIT3_FLOOR = 68;
    static final long HIT5_FLOOR = 68;
    static final long ANSWER_HIT_FLOOR = 68;
    static final long CLEAN_NO_DOC_FLOOR = 3;

    /** The build directory this test runs from (target, or the one an isolated build chose). */
    private static Path buildDirectory() {
        try {
            return Path.of(AiKnowledgeGoldenQuestionsEvalTest.class.getProtectionDomain().getCodeSource().getLocation().toURI())
                    .getParent();
        } catch (java.net.URISyntaxException | RuntimeException unknown) {
            return Path.of("target");
        }
    }

    private static String metrics(String label, List<Outcome> list) {
        long n = list.size();
        long h1 = list.stream().filter(outcome -> outcome.rank() == 1).count();
        long h3 = list.stream().filter(outcome -> outcome.rank() >= 1 && outcome.rank() <= 3).count();
        long h5 = list.stream().filter(outcome -> outcome.rank() >= 1 && outcome.rank() <= 5).count();
        long a5 = list.stream().filter(outcome -> outcome.rankAll() >= 1 && outcome.rankAll() <= 5).count();
        long sent = list.stream().filter(Outcome::answerHit).count();
        long empty = list.stream().filter(outcome -> !outcome.answered()).count();
        return String.format(Locale.ROOT, "%-24s n=%2d hit@1=%2d hit@3=%2d (%3.0f%%) hit@5=%2d (%3.0f%%) | as-superadmin hit@5=%2d"
                        + " | answer-time hit=%2d (%3.0f%%) nothing-sent=%d%n", label, n, h1, h3, pct(h3, n), h5, pct(h5, n), a5,
                sent, pct(sent, n), empty);
    }

    private static double pct(long part, long whole) {
        return whole == 0 ? 0 : 100.0 * part / whole;
    }
}
