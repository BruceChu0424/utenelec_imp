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
            assertThat(chunk.text().length()).as(chunk.label()).isBetween(AiDocChunker.SMALLEST, AiDocChunker.MAX_CHARS + 2);
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
        for (String question : List.of("今天天气怎么样", "我有哪些待办", "黄框是什么意思", "你好")) {
            assertThat(docs.search(question, ALL)).as(question).isEmpty();
        }
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
        assertThat(docs.search("服务器状态页显示什么", Set.of("SELF", "WAREHOUSE")))
                .noneSatisfy(chunk -> assertThat(chunk.path()).contains("服务器状态页"));
        assertThat(docs.search("服务器状态页显示什么", ALL))
                .anySatisfy(chunk -> assertThat(chunk.path()).contains("服务器状态页"));
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
