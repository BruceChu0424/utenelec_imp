package com.uten.imp.features.ai.chat;

import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * ADR-153 knowledge index over the real design documents of this repository (docs/, as packaged): policy,
 * chunking, sanitizing and retrieval quality for the questions users actually asked.
 */
class AiDocKnowledgeTest {
    private static final Set<String> ALL = Set.of("SELF", "SALES", "PRODUCTION", "PURCHASE", "WAREHOUSE", "FINANCE",
            "ADMIN", "QUALITY", "SUBCONTRACT", "HR", "RD");
    static final String WEIGHT_QUESTION =
            "这个erp的产品重量是怎么计算的，比如我入库了100个A产品填了1KG，又入库了100个A产品没填重量，最终会显示每个多重";
    private static AiDocKnowledge docs;

    @BeforeAll static void build() {
        docs = AiDocKnowledge.fromDirectory(Path.of("..", "docs"));
    }

    @Test void onlyWhitelistedDocumentsAreIndexed() {
        assertThat(docs.size()).isGreaterThan(1000);
        for (var chunk : docs.chunks()) {
            assertThat(AiDocKnowledgePolicy.included(chunk.path())).as(chunk.path()).isTrue();
            assertThat(chunk.path()).doesNotStartWith("99-项目治理").doesNotStartWith("数据迁移").doesNotStartWith("05-架构")
                    .doesNotContain("登录页", "AI服务设置页", "系统设置页", "代码总结", "10-安全准则", "ADR-150", "ADR-152",
                            "ADR-031", "ADR-110");
        }
        assertThat(docs.chunks()).anySatisfy(chunk -> assertThat(chunk.path()).contains("ADR-135"));
        assertThat(docs.chunks()).anySatisfy(chunk -> assertThat(chunk.path()).contains("14-徽章与计数口径"));
        // The server status page document is readable by administrators only.
        assertThat(docs.chunks()).filteredOn(chunk -> chunk.path().contains("服务器状态页"))
                .isNotEmpty().allSatisfy(chunk -> assertThat(chunk.domains()).containsExactly("ADMIN"));
    }

    @Test void chunksAreBoundedLabelledAndFreeOfInternalNames() {
        List<String> leaks = new ArrayList<>();
        for (var chunk : docs.chunks()) {
            // A glossary definition or the pointer left for a replaced document is short by nature.
            int smallest = chunk.kind() == AiDocChunker.Kind.RULE ? AiDocChunker.SMALLEST : AiDocChunker.SMALLEST_ROW;
            assertThat(chunk.text().length()).as(chunk.label()).isBetween(smallest, AiDocChunker.MAX_CHARS + 2);
            assertThat(chunk.docTitle()).as(chunk.path()).isNotBlank().doesNotStartWith("ADR-");
            assertThat(chunk.id()).matches("doc-[0-9a-f]{12}");
            var problems = AiChatInternalContent.problems(chunk.text(), "");
            if (!problems.isEmpty()) leaks.add(chunk.label() + " " + problems);
        }
        assertThat(leaks).isEmpty();
        // Sections about implementation (tests, migration, interfaces, security, background) are not indexed.
        assertThat(docs.chunks()).noneSatisfy(chunk -> assertThat(chunk.section())
                .containsAnyOf("迁移与退役", "参考系统", "一、背景", "设计快照", "同行做法"));
    }

    @Test void chunkIdsAreStableAcrossBuilds() {
        var again = AiDocKnowledge.fromDirectory(Path.of("..", "docs"));
        assertThat(again.chunks().stream().map(AiDocChunker.Chunk::id).toList())
                .isEqualTo(docs.chunks().stream().map(AiDocChunker.Chunk::id).toList());
    }

    @Test void theWeightQuestionFindsTheWeightLedgerRules() {
        var found = docs.search(WEIGHT_QUESTION, ALL);
        assertThat(found).hasSizeBetween(4, AiDocKnowledge.MAX_CHUNKS);
        assertThat(found.stream().mapToInt(chunk -> chunk.text().length()).sum()).isLessThanOrEqualTo(AiDocKnowledge.MAX_CHARS);
        // The decision record's weight ledger rules: unweighed stock-in uses the learned unit weight or the stock average.
        assertThat(found).anySatisfy(chunk -> {
            assertThat(chunk.path()).contains("ADR-135");
            assertThat(chunk.text()).contains("入库未称", "库存均重");
        });
        assertThat(found).allSatisfy(chunk -> assertThat(chunk.text() + chunk.label()).containsAnyOf("重量", "称重", "单重"));
        assertThat(docs.search("单重是怎么学出来的，什么时候算可靠", ALL))
                .anySatisfy(chunk -> assertThat(chunk.text()).contains("可靠"));
    }

    @Test void stocktakeAndDefectiveQuestionsFindTheirDocuments() {
        assertThat(docs.search("盘点有差异的时候怎么处理，谁来审核", ALL))
                .anySatisfy(chunk -> assertThat(chunk.label() + chunk.path()).contains("盘点"));
        assertThat(docs.search("不良品放到哪里，会不会算可用库存", ALL))
                .anySatisfy(chunk -> assertThat(chunk.text()).contains("不良品"));
        assertThat(docs.search("红色徽章和黄色徽章有什么区别", ALL))
                .anySatisfy(chunk -> assertThat(chunk.label()).contains("徽章"));
        assertThat(docs.search("出货时汇率按哪天的算", ALL))
                .anySatisfy(chunk -> assertThat(chunk.label()).contains("汇率"));
    }

    /** A3 quality and review rounds: the questions whose documents were not found before the revision. */
    @Test void questionsThatMissedTheirRulesNowFindThem() {
        // The reliable-unit-weight threshold (3.3) is no longer pushed out by the permission section.
        assertThat(docs.search(WEIGHT_QUESTION, ALL)).anySatisfy(chunk -> assertThat(chunk.label()).contains("单重自学习"));
        // The user's current rule stated before the first heading travels with the first section.
        assertThat(docs.search("盘点保存以后库存马上就改了吗？", ALL))
                .anySatisfy(chunk -> assertThat(chunk.text()).contains("保存只生成待审核申请"));
        // Single filler characters are no longer cut out of words (在途, 让料, 对账).
        assertThat(docs.search("在途数量怎么算", ALL)).anySatisfy(chunk -> assertThat(chunk.text()).contains("在途"));
        assertThat(docs.search("供给不足时怎么让料", ALL)).anySatisfy(chunk -> assertThat(chunk.label()).contains("让料"));
        assertThat(AiDocIndex.keyTerms("账户余额对账怎么核对")).contains("对账", "核对");
        // Yes/no and listing questions find the rule they ask about.
        assertThat(docs.search("仓库任务中心里的「我的仓库」包含哪些单据？没有设负责人的仓库的单我看得到吗？", ALL))
                .anySatisfy(chunk -> assertThat(chunk.label()).contains("仓库范围"));
        assertThat(docs.search("客户退货回来的货，退货单审核完能直接再卖吗？", ALL))
                .anySatisfy(chunk -> assertThat(chunk.label()).contains("销售退货质检冻结与处置"));
    }

    @Test void englishAndKoreanQuestionsReachTheChineseRules() {
        assertThat(docs.search("If I receive goods without weighing them, how does the system estimate the weight?", ALL))
                .anySatisfy(chunk -> assertThat(chunk.path()).contains("ADR-135"));
        assertThat(docs.search("Who approves a stock count difference, and does the stock change before approval?", ALL))
                .anySatisfy(chunk -> assertThat(chunk.label()).contains("盘点"));
        assertThat(docs.search("재고 실사에서 수량 차이가 나면 누가 승인하나요?", ALL))
                .anySatisfy(chunk -> assertThat(chunk.label()).contains("盘点"));
        assertThat(docs.search("How do I change my login password?", ALL))
                .anySatisfy(chunk -> assertThat(chunk.text()).contains("密码"));
    }

    @Test void aFollowUpKeepsTheTopicOfTheConversation() {
        var found = docs.search("审核之前这段时间又有出库了会怎样？", "库存盘点有差异的时候怎么处理？谁来审核？ 那车间内料仓的呢？", ALL);
        assertThat(found).anySatisfy(chunk -> assertThat(chunk.text()).contains("整单不入账"));
    }

    @Test void tablesStayReadableRowsAndInternalColumnsGo() {
        var ownership = docs.chunks().stream().filter(chunk -> chunk.label().contains("库存盘点模式与审核 / 审核归属")).findFirst().orElseThrow();
        assertThat(ownership.text()).contains("普通仓库 | 财务 → 普通仓盘点审核\n", "车间内料仓 | 仓库 → 仓库任务中心 → 盘点审核\n")
                .doesNotContain("必要个人权限");
    }

    @Test void securityAndDeploymentSentencesNeverLeaveWhateverTheDocument() {
        List<String> leaks = new ArrayList<>();
        for (var chunk : docs.chunks()) {
            var matcher = AiDocKnowledgePolicy.SECURITY_TEXT.matcher(chunk.text());
            if (matcher.find()) leaks.add(chunk.label() + ": " + matcher.group());
        }
        assertThat(leaks).isEmpty();
        assertThat(docs.chunks()).noneSatisfy(chunk -> assertThat(chunk.text()).containsAnyOf("HMAC", "pgcrypto", "split-horizon",
                "refresh token", "8080 后台"));
    }

    @Test void selfServiceRulesAreForEveryEmployee() {
        assertThat(docs.chunks()).filteredOn(chunk -> chunk.path().contains("员工报销全链路"))
                .isNotEmpty().allSatisfy(chunk -> assertThat(chunk.domains()).isEmpty());
        assertThat(docs.search("报销怎么提交", Set.of("SELF", "WAREHOUSE")))
                .anySatisfy(chunk -> assertThat(chunk.path()).contains("报销"));
    }

    @Test void unrelatedQuestionsFindNothing() {
        // 我有哪些待办 is a data question (answered by a tool); 待办 alone is too common a word to pick a document.
        for (String question : List.of("今天天气怎么样", "我有哪些待办", "你好", "帮我写首诗")) {
            assertThat(docs.search(question, ALL)).as(question).isEmpty();
        }
    }

    /** P0-4 short and everyday questions: the term's definition and the rules titled with it, not nothing. */
    @Test void shortAndEverydayQuestionsFindTheirRules() {
        var production = Set.of("SELF", "PRODUCTION");
        assertThat(docs.search("让料是什么意思", production))
                .anySatisfy(chunk -> assertThat(chunk.path()).contains("ADR-049"))
                .anySatisfy(chunk -> assertThat(chunk.label()).isEqualTo("业务术语与状态总表 / 让料"));
        assertThat(docs.search("黄框是什么意思", Set.of("SELF")).getFirst().label()).isEqualTo("业务术语与状态总表 / 黄框");
        assertThat(docs.search("直送是什么意思", production)).anySatisfy(chunk -> assertThat(chunk.label()).contains("直送"));
        assertThat(docs.search("待检是什么", Set.of("SELF", "QUALITY"))).anySatisfy(chunk -> assertThat(chunk.label()).contains("待检"));
        assertThat(docs.search("在途数量怎么算", ALL)).anySatisfy(chunk -> assertThat(chunk.label()).contains("在途"));
        // Spoken questions: 东西到了 / 收进去 are 到货 / 入库, and 那边 / 后仓 no longer pull in quoted wording elsewhere.
        assertThat(docs.search("东西到了以后仓库那边要怎么收进去", Set.of("SELF", "WAREHOUSE")))
                .anySatisfy(chunk -> assertThat(chunk.label()).contains("到货登记"));
        assertThat(docs.search("为啥我下不了委外单 按钮是灰得", Set.of("SELF", "SUBCONTRACT")))
                .anySatisfy(chunk -> assertThat(chunk.path()).contains("ADR-156"));
        assertThat(docs.search("字太小了看不清 怎么调大", Set.of("SELF")))
                .anySatisfy(chunk -> assertThat(chunk.path()).contains("设置页"));
        // A term the many rules that use it outrank still gets its own definition.
        for (String term : List.of("预留", "齐套", "在途")) {
            assertThat(docs.search(term + "是什么", Set.of("SELF"))).as(term)
                    .anySatisfy(chunk -> assertThat(chunk.label()).isEqualTo("业务术语与状态总表 / " + term));
        }
        // Two common words that an FAQ heading names together; a spoken lead-in and 日产量 (报工) around 本次 and 累计.
        assertThat(docs.search("通知能删除吗", Set.of("SELF")))
                .anySatisfy(chunk -> assertThat(chunk.label()).startsWith("通知列表页 / 十、常见问题"));
        assertThat(docs.search("我想听听日产量记录时本次和累计怎么区分", production))
                .anySatisfy(chunk -> assertThat(chunk.label()).contains("报工数量填本次还是累计"));
    }

    /** P0-5 a wholly replaced decision is one pointer to its successor; history and unbuilt pages are not rules. */
    @Test void replacedDecisionsAndHistoryAreNotServedAsRules() {
        for (String replaced : List.of("ADR-062-", "ADR-085-", "ADR-103-")) {
            var chunks = docs.chunks().stream().filter(chunk -> chunk.path().contains(replaced)).toList();
            assertThat(chunks).as(replaced).singleElement().satisfies(pointer -> {
                assertThat(pointer.kind()).isEqualTo(AiDocChunker.Kind.POINTER);
                assertThat(pointer.label()).endsWith(" / 已被取代");
                assertThat(pointer.text()).contains("整份取代", "不是现行规则", "《委外按工序领直属物料与分批回厂》");
            });
        }
        assertThat(docs.search("委外件要先自制再通知委外吗", Set.of("SELF", "SUBCONTRACT")).getFirst().path()).contains("ADR-143");
        // Page change logs, compatibility-only history and pages that were never built are not indexed.
        assertThat(docs.chunks()).noneSatisfy(chunk -> assertThat(chunk.label())
                .containsPattern("演进记录|历史(?:实现|执行|调度|合同|说明)|仅兼容|不作当前|二轮历史"));
        assertThat(docs.chunks()).noneSatisfy(chunk -> assertThat(chunk.path())
                .containsAnyOf("产量录入页", "产量统计页", "流水线看板页"));
    }

    /** P2-1 a source label never names ports, cloned test databases, acceptance runs or security internals. */
    @Test void labelsNeverNameInternals() {
        List<String> leaks = new ArrayList<>();
        for (var chunk : docs.chunks()) {
            if (AiDocKnowledgePolicy.INTERNAL_LABEL.matcher(chunk.label()).find()
                    || AiDocKnowledgePolicy.SECURITY_TEXT.matcher(chunk.label()).find()) leaks.add(chunk.label());
        }
        assertThat(leaks).isEmpty();
        // The note is cut, the heading stays.
        assertThat(AiDocChunker.label("1. 事实(调查与复现，克隆库 + 8085)")).isEqualTo("1. 事实");
        assertThat(AiDocChunker.label("UAT 验收步骤")).isNull();
        assertThat(AiDocChunker.label("3.2 重量账规则")).isEqualTo("3.2 重量账规则");
    }

    /** Eval #8: the file name and a {@code > 别名：} line near the top are searched with the title. */
    @Test void theFileNameAndTheAliasesNameTheDocument() {
        var documents = new java.util.LinkedHashMap<String, String>();
        documents.put("03-页面/生产计划单一键生成与全链路溯源设计.md",
                "# 联合排产、供给批次与全链路溯源设计\n\n> 别名：一键排产、子计划生成\n\n## 当前规则\n\n"
                        + "在物料分析页勾选父件和下层，一次下达车间、采购和委外；下层的子计划随父件一起生成，不用逐层去建，生成后可以在计划详情里逐层追溯来源。\n");
        for (int i = 0; i < 20; i++) {
            documents.put("03-页面/其它页" + i + ".md", "# 其它页" + i + "\n\n## 规则\n\n仓库按单据逐行办理，提交后由负责人审核，"
                    + "审核通过才生效；退回时写明原因，改完重新提交；同一张单据只能由一个人办理。第" + i + "页。\n");
        }
        AiDocKnowledge small = AiDocKnowledge.of(documents);
        var chunk = small.chunks().stream().filter(c -> c.path().contains("一键生成")).findFirst().orElseThrow();
        assertThat(chunk.documentName()).contains("联合排产", "生产计划单一键生成与全链路溯源设计", "一键排产", "子计划生成");
        assertThat(chunk.text()).doesNotContain("别名");
        assertThat(small.search("生产计划能一键生成吗", ALL)).anySatisfy(c -> assertThat(c.path()).contains("一键生成"));
        assertThat(small.search("子计划生成在哪", ALL)).anySatisfy(c -> assertThat(c.path()).contains("一键生成"));
    }

    /**
     * P0-6 who reads which rules (reviewed overrides): receiving and inspection rules for every department that works
     * with them, the credit rule for sales and finance, personnel pages for personnel, data clearing for administrators,
     * the glossary and the assistant's own guide for everyone.
     */
    @Test void visibilityMatrixOfTheReviewedDocuments() {
        record Row(String path, Set<String> visibleTo, Set<String> hiddenFrom) {}
        var self = Set.of("SELF");
        List<Row> matrix = List.of(
                new Row("ADR-090-", Set.of("PRODUCTION", "SALES", "WAREHOUSE", "QUALITY", "PURCHASE"), Set.of()),
                new Row("ADR-144-", Set.of("WAREHOUSE", "PURCHASE", "SALES"), Set.of()),
                new Row("ADR-128-", Set.of("SALES", "FINANCE"), Set.of("WAREHOUSE", "PRODUCTION")),
                new Row("03-页面/员工详情页", Set.of("HR"), Set.of("SALES", "WAREHOUSE")),
                new Row("03-页面/员工编辑页", Set.of("HR"), Set.of("SALES", "WAREHOUSE")),
                new Row("ADR-155-", Set.of("ADMIN"), Set.of("SALES", "FINANCE", "HR")),
                new Row(AiDocGlossary.PATH, Set.of("SALES", "WAREHOUSE"), Set.of()));
        for (Row row : matrix) {
            var chunks = docs.chunks().stream().filter(chunk -> chunk.path().contains(row.path())).toList();
            assertThat(chunks).as(row.path()).isNotEmpty();
            for (String domain : row.visibleTo()) {
                assertThat(chunks).as(row.path() + " for " + domain)
                        .allSatisfy(chunk -> assertThat(AiDocKnowledge.visible(chunk, Set.of("SELF", domain))).isTrue());
            }
            for (String domain : row.hiddenFrom()) {
                assertThat(chunks).as(row.path() + " hidden from " + domain)
                        .allSatisfy(chunk -> assertThat(AiDocKnowledge.visible(chunk, Set.of("SELF", domain))).isFalse());
            }
        }
        // Every chat user reads the glossary and the assistant's guide, with no business domain at all.
        assertThat(docs.chunks()).filteredOn(chunk -> chunk.path().equals(AiDocGlossary.PATH)
                        || chunk.path().equals("03-页面/AI工作助手使用说明.md"))
                .allSatisfy(chunk -> assertThat(AiDocKnowledge.visible(chunk, self)).isTrue());
    }

    @Test void businessRulesAreSharedButPersonnelFinanceAndAdministrationStayInTheirDepartment() {
        // A sales clerk asking how stock weight works gets the warehouse rules (no business data in them).
        var sales = docs.search(WEIGHT_QUESTION, Set.of("SELF", "SALES"));
        assertThat(sales).anySatisfy(chunk -> assertThat(chunk.path()).contains("ADR-135"));
        assertThat(sales).allSatisfy(chunk -> assertThat(chunk.domains()).doesNotContainAnyElementsOf(
                java.util.Set.of("HR", "ADMIN")));
        assertThat(docs.search("工资条审核的流程是什么", Set.of("SELF", "WAREHOUSE")))
                .noneSatisfy(chunk -> assertThat(chunk.domains()).contains("HR"));
        assertThat(docs.search("工资条审核的流程是什么", ALL)).anySatisfy(chunk -> assertThat(chunk.domains()).contains("HR"));
        // Live 2026-10-06 (N2): ADR-063's personnel event catalog (an unrestricted decision record) gave a sales reader the
        // payroll review and publish chain; an event catalog is mechanics and is no longer indexed at all.
        assertThat(docs.search("工资条怎么生成 生成完要谁审核", Set.of("SELF", "SALES", "SUBCONTRACT")))
                .noneSatisfy(chunk -> assertThat(chunk.section()).contains("事件目录"));
        assertThat(docs.chunks()).noneSatisfy(chunk -> assertThat(chunk.section()).contains("人事域事件目录"));
        assertThat(docs.search("服务器状态页显示什么", Set.of("SELF", "WAREHOUSE")))
                .noneSatisfy(chunk -> assertThat(chunk.path()).contains("服务器状态页"));
        assertThat(docs.search("服务器状态页显示什么", ALL))
                .anySatisfy(chunk -> assertThat(chunk.path()).contains("服务器状态页"));
    }

    /**
     * ADR-159 section-level domains (root cure for live N2): inside a document every chat user reads, the sections about
     * personnel or finance (by heading or a list item's bold lead) are for those departments only; the rest of the document
     * stays shared, and documents about one's own matters, the glossary and the assistant's guide stay fully visible.
     */
    @Test void sectionVisibilityMatrix() {
        record Row(String path, String text, Set<String> visibleTo, Set<String> hiddenFrom) {}
        List<Row> matrix = List.of(
                // ADR-063 2026-09-10 修订: items 4-6 (personnel notice routing, payroll review and publish) are personnel's;
                // items 1-3 and 7-8 (login popup rules, manual notices) are everyone's.
                new Row("ADR-063-", "人事域接收池", Set.of("HR"), Set.of("SALES", "FINANCE", "WAREHOUSE", "SUBCONTRACT")),
                new Row("ADR-063-", "工资审核通过", Set.of("HR"), Set.of("SALES", "FINANCE")),
                new Row("ADR-063-", "登录弹窗口径", Set.of("HR", "SALES", "FINANCE", "WAREHOUSE"), Set.of()),
                new Row("ADR-063-", "人工通知登录弹窗与打卡", Set.of("HR", "SALES", "FINANCE"), Set.of()),
                // ADR-131 §7 成本 is finance's; the rest of the workshop decision is production's and the warehouse's.
                new Row("ADR-131-", "成本对象", Set.of("FINANCE"), Set.of("PRODUCTION", "WAREHOUSE", "SALES")),
                new Row("ADR-131-", "整批", Set.of("PRODUCTION", "WAREHOUSE", "FINANCE"), Set.of()));
        for (Row row : matrix) {
            var chunks = docs.chunks().stream().filter(chunk -> chunk.path().contains(row.path()) && chunk.text().contains(row.text()))
                    .filter(chunk -> row.hiddenFrom().isEmpty() ? chunk.sectionDomains().isEmpty() : !chunk.sectionDomains().isEmpty())
                    .toList();
            assertThat(chunks).as(row.path() + " " + row.text()).isNotEmpty();
            for (String domain : row.visibleTo()) {
                assertThat(chunks).as(row.path() + " " + row.text() + " for " + domain)
                        .allSatisfy(chunk -> assertThat(AiDocKnowledge.visible(chunk, Set.of("SELF", domain))).isTrue());
            }
            for (String domain : row.hiddenFrom()) {
                assertThat(chunks).as(row.path() + " " + row.text() + " hidden from " + domain)
                        .allSatisfy(chunk -> assertThat(AiDocKnowledge.visible(chunk, Set.of("SELF", domain))).isFalse());
            }
        }
        // The personnel chunk of ADR-063 holds nothing of the shared login popup rules (they never share a chunk).
        assertThat(docs.chunks()).filteredOn(chunk -> chunk.path().contains("ADR-063-") && !chunk.sectionDomains().isEmpty())
                .isNotEmpty().allSatisfy(chunk -> assertThat(chunk.text()).doesNotContain("登录弹窗口径", "人工通知登录弹窗"));
        // The personnel event catalog is mechanics and indexed for nobody.
        assertThat(docs.chunks()).noneSatisfy(chunk -> assertThat(chunk.section()).contains("事件目录"));
        // Fully visible: documents about one's own matters (「我的部门」 roster under the department page too), the glossary,
        // the assistant's guide, and a sales chain whose 「发货与正式应收」 is a shipping step as well.
        var self = Set.of("SELF");
        assertThat(docs.chunks()).filteredOn(chunk -> chunk.path().equals("03-页面/我的页.md") || chunk.path().equals(AiDocGlossary.PATH)
                        || chunk.path().equals("03-页面/AI工作助手使用说明.md")
                        || (chunk.path().equals("03-页面/部门管理页.md") && chunk.section().contains("我的部门")))
                .isNotEmpty().allSatisfy(chunk -> {
                    assertThat(chunk.sectionDomains()).as(chunk.label()).isEmpty();
                    assertThat(AiDocKnowledge.visible(chunk, self)).as(chunk.label()).isTrue();
                });
        assertThat(docs.chunks()).filteredOn(chunk -> chunk.path().contains("01-销售订货到发货全链路") && chunk.section().contains("发货与正式应收"))
                .isNotEmpty().allSatisfy(chunk -> assertThat(AiDocKnowledge.visible(chunk, Set.of("SELF", "SALES"))).isTrue());
        // A section scope only narrows: a finance document's sections never open to a personnel reader.
        assertThat(docs.chunks()).filteredOn(chunk -> chunk.domains().contains("FINANCE") && !chunk.domains().contains("HR"))
                .isNotEmpty().allSatisfy(chunk -> assertThat(chunk.sectionDomains()).isEmpty());
    }

    /** ADR-159 section scoping on small documents: a heading and a list item's bold lead; the scope ends with the item. */
    @Test void aPersonnelSectionOrItemInsideASharedDocumentIsScopedOnItsOwn() {
        var documents = new java.util.LinkedHashMap<String, String>();
        documents.put("99-决策记录-ADR/ADR-990-通知弹窗规则.md", "# ADR-990 通知弹窗规则\n\n## 一、决策\n\n"
                + "1. **登录弹窗**：一条待办在未办结期间每次登录都弹，直到用户确认过它；稍后再看到期后重新弹出，右上角关闭只关本次，"
                + "下次登录仍然提醒，已读或去工作台处理之后才静默。\n"
                + "2. **人事办结**：工资审核通过后先办结审核卡，再给发布人发待发布卡；发布后办结，驳回时撤回两张卡。\n"
                + "   工资批次的复核人和发布人按职能权限判定，不限部门子树，提交人本人一律排除。\n"
                + "3. **车间任务**：开工即按段办结，完工入库由完工投递兜底办结，取消和红冲同样按段办结，换车间重投也按段办结，"
                + "报工本身不办结。\n\n"
                + "## 二、附：人事流程\n\n入职、离职和工资条的提醒都发给人事职能权限的持有人，不限部门，提交人本人不收，"
                + "这些提醒在人事办完之后自动办结，驳回时撤回，员工撤销信息变更时也一并办结。\n");
        AiDocKnowledge small = AiDocKnowledge.of(documents);
        var hr = small.chunks().stream().filter(chunk -> !chunk.sectionDomains().isEmpty()).toList();
        assertThat(hr).hasSize(2).allSatisfy(chunk -> assertThat(chunk.sectionDomains()).containsExactly("HR"));
        assertThat(hr.getFirst().text()).contains("人事办结", "复核人").doesNotContain("登录弹窗", "车间任务");
        assertThat(hr.get(1).section()).contains("附：人事流程");
        var shared = small.chunks().stream().filter(chunk -> chunk.sectionDomains().isEmpty()).toList();
        assertThat(shared).anySatisfy(chunk -> assertThat(chunk.text()).contains("登录弹窗"))
                .anySatisfy(chunk -> assertThat(chunk.text()).contains("车间任务"))
                .allSatisfy(chunk -> assertThat(chunk.text()).doesNotContain("工资"));
        assertThat(hr).allSatisfy(chunk -> {
            assertThat(AiDocKnowledge.visible(chunk, Set.of("SELF", "HR"))).isTrue();
            assertThat(AiDocKnowledge.visible(chunk, Set.of("SELF", "SALES", "FINANCE"))).isFalse();
            assertThat(AiDocKnowledge.hiddenBy(chunk, Set.of("SELF", "SALES"))).containsExactly("HR");
        });
        assertThat(shared).allSatisfy(chunk -> assertThat(AiDocKnowledge.visible(chunk, Set.of("SELF"))).isTrue());
    }

    /** ADR-159 §十 6: sections of a partly replaced decision record marked as replaced are not indexed, the rest is. */
    @Test void sectionsMarkedAsReplacedAreNotIndexed() {
        var documents = new java.util.LinkedHashMap<String, String>();
        documents.put("99-决策记录-ADR/ADR-991-委外解锁.md", "# ADR-991 委外解锁\n\n## 二、决策(已被 ADR-143 取代，不作当前规则)\n\n"
                + "委外子件批准即派活，按申请量一次发料，回厂后按订货量结案，这是旧的做法，现在已经不用了，只留作追溯；"
                + "发料不看库存够不够，缺料时由委外商自己垫料，回厂再按实收补扣。\n\n"
                + "## 三、口径(部分被 ADR-143 取代)\n\n委外损耗按订货量的百分比计算，超出损耗的部分转财务责任判定，这一条仍然有效；"
                + "损耗以内的短交自动结案，不再催委外商补货，超出的部分由财务审核组决定由谁承担。\n");
        AiDocKnowledge small = AiDocKnowledge.of(documents);
        assertThat(small.chunks()).noneSatisfy(chunk -> assertThat(chunk.text()).contains("批准即派活"));
        assertThat(small.chunks()).anySatisfy(chunk -> assertThat(chunk.text()).contains("委外损耗按订货量"));
        // The real records C2 marked: ADR-064 §二 and ADR-081 §三 are not indexed.
        assertThat(docs.chunks()).noneSatisfy(chunk -> assertThat(chunk.label()).containsPattern("已被 ADR-\\d+.{0,40}取代"));
    }

    /**
     * ADR-159 (live N2, N3): a question whose best match over every document is hidden from the reader and clearly outranks
     * what the reader sees is about a restricted subject; the same question from the department that owns it is not.
     */
    @Test void aQuestionAboutAnotherDepartmentsRulesIsRecognized() {
        var sales = Set.of("SELF", "SALES", "SUBCONTRACT");
        assertThat(docs.restrictedTopic("货品成本是怎么算出来的", sales)).contains(Set.of("FINANCE"));
        assertThat(docs.restrictedTopic("工资条怎么生成", sales)).contains(Set.of("HR"));
        assertThat(docs.restrictedTopic("工资条怎么生成 生成完要谁审核", sales)).contains(Set.of("HR"));
        assertThat(docs.restrictedTopic("货品成本是怎么算出来的", Set.of("SELF", "FINANCE"))).isEmpty();
        assertThat(docs.restrictedTopic("工资条怎么生成 生成完要谁审核", Set.of("SELF", "HR"))).isEmpty();
        assertThat(docs.restrictedTopic("货品成本是怎么算出来的", ALL)).isEmpty();
        // The sales reader's own rules are not restricted, and an unrelated question matches nothing.
        assertThat(docs.restrictedTopic("报价单怎么转成订货单", sales)).isEmpty();
        assertThat(docs.restrictedTopic("今天天气怎么样", sales)).isEmpty();
        // The margin: 1.5 times the best visible score, or a higher score with two more of the question's own words.
        var hidden = Set.of("FINANCE");
        assertThat(new AiDocKnowledge.TopicCheck(15.0, 10.0, 3, 3, true, hidden).restricted(true)).isTrue();
        assertThat(new AiDocKnowledge.TopicCheck(14.9, 10.0, 3, 3, true, hidden).restricted(true)).isFalse();
        assertThat(new AiDocKnowledge.TopicCheck(12.0, 10.0, 4, 2, true, hidden).restricted(true)).isTrue();
        assertThat(new AiDocKnowledge.TopicCheck(12.0, 10.0, 4, 3, true, hidden).restricted(true)).isFalse();
        assertThat(new AiDocKnowledge.TopicCheck(9.0, 10.0, 4, 1, true, hidden).restricted(true)).isFalse();
        // Nothing the reader sees would be used: any hidden match that answers the question decides.
        assertThat(new AiDocKnowledge.TopicCheck(11.0, 10.0, 2, 2, true, hidden).restricted(false)).isTrue();
        // The hidden match must itself answer the question, and be hidden.
        assertThat(new AiDocKnowledge.TopicCheck(30.0, 5.0, 3, 1, false, hidden).restricted(false)).isFalse();
        assertThat(new AiDocKnowledge.TopicCheck(30.0, 5.0, 3, 1, true, Set.of()).restricted(false)).isFalse();
        assertThat(AiDocKnowledge.RESTRICTED_MARGIN).isEqualTo(1.5);
        assertThat(AiDocKnowledge.RESTRICTED_WORD_MARGIN).isEqualTo(2);
    }

    @Test void searchIsFastEnoughToRunOnEveryQuestion() {
        for (int warm = 0; warm < 20; warm++) docs.search(WEIGHT_QUESTION, ALL);
        long[] runs = new long[31];
        for (int i = 0; i < runs.length; i++) {
            long started = System.nanoTime();
            docs.search(i % 2 == 0 ? WEIGHT_QUESTION : "盘点有差异的时候怎么处理，谁来审核", ALL);
            runs[i] = System.nanoTime() - started;
        }
        java.util.Arrays.sort(runs);
        assertThat(runs[runs.length / 2] / 1_000_000.0).as("median search ms").isLessThan(20.0);
    }
}
