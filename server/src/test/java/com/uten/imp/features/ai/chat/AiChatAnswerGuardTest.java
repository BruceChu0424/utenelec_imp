package com.uten.imp.features.ai.chat;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class AiChatAnswerGuardTest {
    private static final String SOURCE = "{\"rows\":[{\"no\":3,\"cells\":[\"V5ZJ001 外壳\",\"200\",\"已提交\"]}],"
            + "\"legend\":[{\"value\":\"可开工\",\"count\":5}]} 2026-10-04 标价为0";

    @Test void groundedNumbersCodesAndListMarkersPass() {
        var verdict = AiChatAnswerGuard.check("V5ZJ001 外壳要核对:\n1. 第 3 行数量 200\n2. 可开工 (5 行)\n还有 7 项。",
                SOURCE, "有什么要检查");
        assertThat(verdict.accepted()).as(verdict.problems().toString()).isTrue();
    }

    @Test void rememberedFactsMustBeMarkedAsComingFromTheEarlierConversation() {
        String memory = "Turn 1 (page: 我的车间任务 /production/workshop-tasks)\nQ: 哪些任务缺料\nA: 第1行 HP035754 缺 120 个";
        var unmarked = AiChatAnswerGuard.check("当前页面上 HP035754 缺 120 个", SOURCE, memory, "", java.util.List.of(), 4000);
        assertThat(unmarked.accepted()).isFalse();
        assertThat(unmarked.problems()).contains("MEMORY_AS_FACT:HP035754", "MEMORY_AS_FACT:120");
        assertThat(AiChatAnswerGuard.check("刚才说的 HP035754 缺 120 个，要先补料", SOURCE, memory, "", java.util.List.of(), 4000)
                .accepted()).isTrue();
        assertThat(AiChatAnswerGuard.check("之前的 HP035754 还缺 999 个", SOURCE, memory, "", java.util.List.of(), 4000).problems())
                .as("memory never vouches for a new number").contains("NUMBER:999");
        assertThat(AiChatAnswerGuard.check("V5ZJ001 外壳第 3 行数量 200", SOURCE, memory, "", java.util.List.of(), 4000).accepted())
                .as("current-page facts need no marker").isTrue();
    }

    @Test void compactAnswersMayChainColourPairsOnOneLine() {
        String legend = "{\"legend\":[{\"value\":\"本周到期\",\"color\":\"黄\",\"count\":1},{\"value\":\"已逾期\",\"color\":\"红\",\"count\":2}]}";
        var colours = java.util.List.of(new AiChatAnswerGuard.ColourFact("黄", "本周到期", 1),
                new AiChatAnswerGuard.ColourFact("红", "已逾期", 2));
        assertThat(AiChatAnswerGuard.check("共两种：黄 = 本周到期 (1 行)；红 = 已逾期 (2 行)", legend, "", "", colours, 4000)
                .accepted()).isTrue();
        assertThat(AiChatAnswerGuard.check("黄 = 已逾期 (1 行)；红 = 本周到期 (2 行)", legend, "", "", colours, 4000).problems())
                .as("a swapped pair is still caught inside one line").anyMatch(problem -> problem.startsWith("LEGEND_PAIR"));
    }

    /** A3 review: the derivation allowance covered most integers; now only the user's example and shown arithmetic count. */
    @Test void ruleExplanationsComputeFromTheUsersExampleButNeverInventCurrentData() {
        String question = AiDocKnowledgeTest.WEIGHT_QUESTION;
        String rules = "入库未称时按单重估算；单重少于 3 条且没有 ≥10 个的称样一律红；库存均重 = 库存重量 ÷ 库存数量。";
        var derivation = AiChatAnswerGuard.Derivation.of(question, rules);
        String evidence = rules + " " + question;
        // The worked example: 1 kg / 100 = 0.01 kg = 10 g, second batch about 1 kg, about 2 kg in total.
        var worked = AiChatAnswerGuard.check("每个约 10 克。\n1. 第二批按库存均重估算: 1 kg ÷ 100 = 0.01 kg/个，约 1 kg，带「≈」。\n"
                + "2. 合计约 2 kg，200 个。", evidence, "", question, java.util.List.of(), 4000, evidence, derivation);
        assertThat(worked.accepted()).as(worked.problems().toString()).isTrue();
        // Invented current data that the old allowance let through: 523 and 1234 on a "目前/账上" line.
        var invented = AiChatAnswerGuard.check("1. 每个约 10 克。\n2. A 产品目前库存 523 个, 账上 1234 kg。", evidence, "", question,
                java.util.List.of(), 4000, evidence, derivation);
        assertThat(invented.problems()).contains("NUMBER:523", "NUMBER:1234");
        for (int n : new int[] {37, 523, 1234, 3517}) {
            assertThat(derivation.allows(String.valueOf(n), "库存还有 " + n + " 个")).as(String.valueOf(n)).isFalse();
        }
        // A follow-up example: "第二次也填 1.5KG" -> 2.5 kg ÷ 200 = 0.0125 kg = 12.5 g, shown as arithmetic.
        var followUp = AiChatAnswerGuard.Derivation.of("如果第二次也填了 1.5KG 呢", rules);
        assertThat(followUp.allows("2.5", "合计 1 + 1.5 = 2.5 kg")).isTrue();
        assertThat(followUp.allows("0.0125", "2.5 kg ÷ 200 = 0.0125 kg = 12.5 g")).isTrue();
        assertThat(followUp.allows("12.5", "2.5 kg ÷ 200 = 0.0125 kg = 12.5 g")).isTrue();
        assertThat(followUp.allows("777", "单重约 777 克")).as("no arithmetic shown, not derived from the example").isFalse();
        // A3 quality W1.2: the follow-up answer states its result first and shows the arithmetic after it; the user's
        // example spans the conversation (the earlier question gave the first batch).
        var conversation = AiChatAnswerGuard.Derivation.of("第二次也填 1.5KG 呢？\n" + question, rules);
        String reply = "每个约 12.5 克，合计约 2.5 kg。\n1. 两批都实称: 1 kg + 1.5 kg = 2.5 kg。\n2. 2.5 kg ÷ 200 = 0.0125 kg = 12.5 g。";
        var verdict = AiChatAnswerGuard.check(reply, evidence, "", "第二次也填 1.5KG 呢？", java.util.List.of(), 4000, evidence, conversation);
        assertThat(verdict.accepted()).as(verdict.problems().toString()).isTrue();
        assertThat(AiChatAnswerGuard.check("目前系统里单重是 0.0125 kg。\n2.5 kg ÷ 200 = 0.0125 kg = 12.5 g。", evidence, "",
                "第二次也填 1.5KG 呢？", java.util.List.of(), 4000, evidence, conversation).problems())
                .as("a computed number never becomes current data").contains("NUMBER:0.0125");
    }

    /** A4 retest (fast thinking): a slipped calculation is caught, correct ones and unit changes pass. */
    @Test void theArithmeticAnExplanationShowsMustBeRight() {
        for (String right : java.util.List.of("1 kg ÷ 100 = 0.01 kg = 10 g", "100 × 0.01 = 1 kg", "0.01 kg × 100 个 = 1 kg",
                "100 × 10 g = 1000 g ≈ 1 kg", "2.5 kg ÷ 200 = 0.0125 kg", "1 + 1.5 = 2.5 kg", "100 × 10% = 10",
                "A 分得 520 × 300 ÷ 500 = 312 kg", "100 + 500 − 0 − 0 − 80 = 520 kg", "1 kg ÷ 3 ≈ 0.33 kg", "1 kg ÷ 100 = 10 克")) {
            java.util.List<String> problems = new java.util.ArrayList<>();
            AiChatAnswerGuard.checkArithmetic(right, problems);
            assertThat(problems).as(right).isEmpty();
        }
        for (String wrong : java.util.List.of("库存总重量约 1 kg + 0.01 kg ≈ 1.02 kg", "均重 = 1 kg ÷ 200 = 0.05 kg", "2 × 3 = 7")) {
            java.util.List<String> problems = new java.util.ArrayList<>();
            AiChatAnswerGuard.checkArithmetic(wrong, problems);
            assertThat(problems).as(wrong).anyMatch(problem -> problem.startsWith("ARITHMETIC:"));
        }
    }

    /** A3 red team: rule explanations about states were rejected as completion claims. */
    @Test void ruleExplanationsAboutStatesAreNotCompletionClaims() {
        var derivation = AiChatAnswerGuard.Derivation.of("入库单数量填错了怎么改？", "");
        for (String rule : java.util.List.of("已审核的入库单不能直接改，要先撤回或做调整单。", "审核完成了才会写入库存。",
                "如果单据已提交，就先退回再改。", "The order has been submitted, so it can no longer be edited.")) {
            var verdict = AiChatAnswerGuard.check(rule, "入库单", "", "入库单数量填错了怎么改？", java.util.List.of(), 4000, "", derivation);
            assertThat(verdict.problems()).as(rule).noneMatch(problem -> problem.startsWith("COMPLETION_CLAIM"));
        }
        assertThat(AiChatAnswerGuard.check("我已经帮你改好了。", "入库单", "", "怎么改", java.util.List.of(), 4000, "", derivation)
                .problems()).contains("COMPLETION_CLAIM");
    }

    /** A3 quality: a colour named in a column's own explanation ("缺=红") is a page fact, not an invented status. */
    @Test void aColourPairFromTheColumnExplanationIsAPageFact() {
        String snapshot = "{\"columns\":[{\"label\":\"物料\",\"info\":\"缺=红, 可领=绿\"}],\"legend\":[{\"value\":\"等待物料到齐\",\"color\":\"琥珀\"}]}";
        var colours = java.util.List.of(new AiChatAnswerGuard.ColourFact("琥珀", "等待物料到齐", 1));
        var verdict = AiChatAnswerGuard.check("1. 琥珀 = 等待物料到齐 (1 行)\n2. 红 = 缺 = 还缺料", snapshot, "", "第3行为什么还不能开工", colours, 4000);
        assertThat(verdict.problems()).noneMatch(problem -> problem.startsWith("LEGEND_STATUS"));
        assertThat(AiChatAnswerGuard.check("紫 = 已报废", snapshot, "", "", colours, 4000).problems())
                .anyMatch(problem -> problem.startsWith("LEGEND_STATUS"));
    }

    @Test void comprehensiveAnswersMayBeLongerButStayBounded() {
        String text = ("可开工\n").repeat(1500);
        assertThat(AiChatAnswerGuard.check(text, SOURCE, "", "", java.util.List.of(), 6000).reply().length())
                .isGreaterThan(AiChatAnswerGuard.MAX_REPLY).isLessThanOrEqualTo(6020);
    }

    @Test void inventedNumbersAndCodesAreRejected() {
        assertThat(AiChatAnswerGuard.check("库存还有 999 个", SOURCE, "").problems()).contains("NUMBER:999");
        assertThat(AiChatAnswerGuard.check("请看 SO-2026-777", SOURCE, "").problems()).anyMatch(problem -> problem.startsWith("CODE:"));
        assertThat(AiChatAnswerGuard.check("把数量改成 100", SOURCE, "把第3行数量改成100").accepted())
                .as("numbers the user typed may be repeated").isTrue();
        assertThat(AiChatAnswerGuard.check("合计 1,000.00 元", SOURCE + " 1000", "").accepted()).isTrue();
    }

    @Test void legendLinesMustUseThePagesOwnColourAndStatusWords() {
        String legend = "{\"legend\":[{\"value\":\"本周到期\",\"color\":\"黄\",\"count\":1},{\"value\":\"已逾期\",\"color\":\"红\",\"count\":1}]}";
        assertThat(AiChatAnswerGuard.check("1. 黄色 = 本周到期 = 7 天内到期 (1 行)\n2. 红 = 已逾期 = 过期未付 (1 行)", legend + " 7", "")
                .accepted()).isTrue();
        assertThat(AiChatAnswerGuard.check("黄色 = 本月到期 = 7 天内到期 (1 行)", legend + " 7", "").problems())
                .contains("LEGEND_STATUS:本月到期");
        assertThat(AiChatAnswerGuard.check("紫色 = 已逾期 = 过期未付", legend, "").problems()).contains("LEGEND_COLOR:紫");
    }

    /** Production evidence always carries the UI conventions text, which names every colour and generic status. */
    private static final String PRODUCTION_EVIDENCE = SOURCE + "\n" + AiChatKnowledge.ALL.stream()
            .filter(entry -> entry.id().equals(AiChatKnowledge.UI_CONVENTIONS)).findFirst().orElseThrow().reply()
            + "\n{\"rows\":[{\"no\":1},{\"no\":2},{\"no\":3},{\"no\":6}],\"legend\":[{\"value\":\"可开工\",\"color\":\"绿\",\"count\":6},"
            + "{\"value\":\"待选路线\",\"color\":\"红\",\"count\":1}],\"badges\":[{\"label\":\"待领料\",\"tone\":\"danger\",\"count\":3}]}";
    private static final java.util.List<AiChatAnswerGuard.ColourFact> WORKSHOP = java.util.List.of(
            new AiChatAnswerGuard.ColourFact("绿", "可开工", 6),
            new AiChatAnswerGuard.ColourFact("红", "待选路线", 1),
            new AiChatAnswerGuard.ColourFact("琥珀", "部分物料已投 · 可开工", 3),
            new AiChatAnswerGuard.ColourFact("红", "待领料", 3));

    @Test void colourLinesAreCheckedAsPairsAgainstThePageNotTheWholeEvidence() {
        String correct = "1. 绿 = 可开工 = 材料齐了 (6 行)\n2. 红 = 待选路线 = 先选路线 (1 行)\n3. 琥珀色 = 部分物料已投 = 可以先开工 (3 行)"
                + "\n徽章: 红 = 待领料 (3)";
        assertThat(AiChatAnswerGuard.check(correct, PRODUCTION_EVIDENCE, "不同状态是什么颜色", WORKSHOP).accepted()).isTrue();
        // Every word below is somewhere in the evidence (conventions + row numbers), but the pairs are swapped.
        var swapped = AiChatAnswerGuard.check("1. 红 = 可开工 = 材料齐了 (3 行)\n2. 绿 = 待选路线 = 先选路线 (6 行)",
                PRODUCTION_EVIDENCE, "不同状态是什么颜色", WORKSHOP);
        assertThat(swapped.accepted()).isFalse();
        assertThat(swapped.problems()).contains("LEGEND_PAIR:红=可开工", "LEGEND_PAIR:绿=待选路线");
        assertThat(AiChatAnswerGuard.check("绿 = 可开工 = 材料齐了 (3 行)", PRODUCTION_EVIDENCE, "", WORKSHOP).problems())
                .contains("LEGEND_COUNT:绿=可开工(3)");
        assertThat(AiChatAnswerGuard.check("灰 = 已完成 = 做完了", PRODUCTION_EVIDENCE, "", WORKSHOP).problems())
                .as("a generic status from the conventions is not this page's status").contains("LEGEND_STATUS:已完成");
        assertThat(AiChatAnswerGuard.check("绿 = 待领料 (3)", PRODUCTION_EVIDENCE, "", WORKSHOP).problems())
                .contains("LEGEND_PAIR:绿=待领料");
        assertThat(AiChatAnswerGuard.check("库存 = 200 个", PRODUCTION_EVIDENCE, "", WORKSHOP).accepted())
                .as("a non-colour line is not a colour claim").isTrue();
    }

    @Test void bareDomainsAreStrippedLikeLinks() {
        var verdict = AiChatAnswerGuard.check("请到 pay-verify.cn/login 核实账户，或看 Report.xlsx 和 v2.4.0", SOURCE + " Report.xlsx 2.4.0", "");
        assertThat(verdict.reply()).doesNotContain("pay-verify", "/login").contains("Report.xlsx", "v2.4.0");
        assertThat(AiChatAnswerGuard.check("见 evil.example.com:8443/a?b=1", SOURCE, "").reply()).isEqualTo("见");
    }

    @Test void completionClaimsAreRejectedUnlessTheyAreAStatusShownOnThePage() {
        for (String claim : java.util.List.of("我已经帮你保存了。", "已为你提交订单。", "数量改好了", "The order has been submitted.")) {
            assertThat(AiChatAnswerGuard.check(claim, SOURCE, "").accepted()).as(claim).isFalse();
        }
        assertThat(AiChatAnswerGuard.check("这一行状态是已提交，等审批。", SOURCE, "").accepted()).isTrue();
        assertThat(AiChatAnswerGuard.check("这张单已审核。", SOURCE, "").accepted()).isFalse();
    }

    @Test void linksAndMarkupAreRemovedAndLengthIsBounded() {
        var verdict = AiChatAnswerGuard.check("看 [说明](https://evil.invalid/x) 和 https://evil.invalid/y <img src=x onerror=1>**重点**",
                SOURCE, "");
        assertThat(verdict.reply()).isEqualTo("看 说明 和  重点");
        assertThat(AiChatAnswerGuard.check("<img src=https://attacker.invalid/c?d=1>", SOURCE, "").accepted()).isFalse();
        var longReply = AiChatAnswerGuard.check(("可开工\n").repeat(1500), SOURCE, "");
        assertThat(longReply.reply().length()).isLessThanOrEqualTo(AiChatAnswerGuard.MAX_REPLY + 20);
        assertThat(longReply.reply()).endsWith("(内容较长，已截断)");
        assertThat(AiChatAnswerGuard.check("   ", SOURCE, "").accepted()).isFalse();
    }

    /**
     * ADR-152: the memory marker must be where the remembered value is (same line, or the line that
     * introduces a list); a time phrase ("发货之前", "before") is not a marker.
     */
    @org.junit.jupiter.api.Test void memoryMarkerMustSitNextToTheRememberedValue() {
        String memory = "Turn 1 (page: 我的车间任务 /production/workshop-tasks)\nQ: 哪些任务缺料\nA: 工单 ZX00000100 缺 4 种物料";
        String page = "当前页面 销售订货 第 1 行";
        var timePhrase = AiChatAnswerGuard.check("当前页面第 1 行的订单对应工单 ZX00000100，缺 4 种物料，请在发货之前确认。",
                page, memory, "", java.util.List.of(), 4000);
        assertThat(timePhrase.accepted()).isFalse();
        assertThat(timePhrase.problems()).contains("MEMORY_AS_FACT:ZX00000100", "MEMORY_AS_FACT:4");
        assertThat(AiChatAnswerGuard.check("Row 1 belongs to ZX00000100, short of 4 parts; check before shipping.",
                page, memory, "", java.util.List.of(), 4000).accepted()).as("English before is not a marker").isFalse();
        var otherLine = AiChatAnswerGuard.check("之前说过的内容我记得。\n当前页面第 1 行对应工单 ZX00000100。",
                page, memory, "", java.util.List.of(), 4000);
        assertThat(otherLine.problems()).as("a marker on another line does not cover it").contains("MEMORY_AS_FACT:ZX00000100");
        assertThat(AiChatAnswerGuard.check("刚才那个任务是工单 ZX00000100。当前页面没有它的发货信息, 无法判断 ZX00000100 能否发货。",
                page, memory, "", java.util.List.of(), 4000).accepted()).as("one line referring back once").isTrue();
        assertThat(AiChatAnswerGuard.check("上一页的工单 ZX00000100 缺 4 种物料。", page, memory, "", java.util.List.of(), 4000)
                .accepted()).isTrue();

        assertThat(AiChatAnswerGuard.check("刚才说的工单 ZX00000100 缺 4 种物料，当前页面看不到发货信息。",
                page, memory, "", java.util.List.of(), 4000).accepted()).isTrue();
        assertThat(AiChatAnswerGuard.check("之前查到的 ZX00000100 缺 4 种物料。", page, memory, "", java.util.List.of(), 4000)
                .accepted()).isTrue();
        assertThat(AiChatAnswerGuard.check("As mentioned earlier, ZX00000100 is short of 4 parts.", page, memory, "",
                java.util.List.of(), 4000).accepted()).isTrue();
        assertThat(AiChatAnswerGuard.check("前面列出的缺料工单:\n1. ZX00000100 缺 4 种物料\n\n当前页面第 1 行没有发货信息。",
                page, memory, "", java.util.List.of(), 4000).accepted()).as("a list inherits its lead-in line").isTrue();
        assertThat(AiChatAnswerGuard.check("前面列出的缺料工单:\n\n1. ZX00000100 缺 4 种物料",
                page, memory, "", java.util.List.of(), 4000).accepted()).as("a blank line ends the lead-in").isFalse();
        assertThat(AiChatAnswerGuard.MEMORY_MARKER.matcher("请在发货之前确认").find()).isFalse();
        assertThat(AiChatAnswerGuard.MEMORY_MARKER.matcher("在此之前").find()).isFalse();
        assertThat(AiChatAnswerGuard.MEMORY_MARKER.matcher("earlier than planned").find()).isFalse();
    }

    /** P1-6: a page, menu or button name the reply quotes, or a menu path it writes, must come from what it was given. */
    @Test void inventedPageNamesAndMenuPathsAreRejectedAsNavigationProblems() {
        String noPlaces = "报工填本次实际产量，报工后还要质检和入库。";
        // The live failure: a fluent menu path with nothing behind it.
        var invented = AiChatAnswerGuard.check("在「生产管理 > 生产报工」点「新建」，填本次数量。", noPlaces, "怎么报工");
        assertThat(invented.accepted()).isFalse();
        assertThat(invented.problems()).contains("NAV:生产管理 > 生产报工", "NAV:新建");
        assertThat(AiChatAnswerGuard.check("打开 生产管理 > 生产报工 页面即可。", noPlaces, "怎么报工").problems())
                .as("an unquoted menu path is checked too").contains("NAV:生产管理 > 生产报工");
        assertThat(AiChatAnswerGuard.check("当前下达入口在标题为「物料分析准备」的页面。", noPlaces, "").problems())
                .contains("NAV:物料分析准备");

        // Names the sources, the page, the directory or the user gave pass; spaces, punctuation and "页" do not matter.
        String places = noPlaces + "\n生产报工页: 在生产管理里打开, 点 新建 按钮。";
        assertThat(AiChatAnswerGuard.check("在「生产管理 > 生产报工」点「新建」。", places, "怎么报工").accepted()).isTrue();
        assertThat(AiChatAnswerGuard.check("到「生产报工页面」去填。", places, "").accepted()).isTrue();
        assertThat(AiChatAnswerGuard.check("在「生产报工」里填。", noPlaces, "生产报工在哪里").accepted())
                .as("the user's own words").isTrue();
        assertThat(AiChatAnswerGuard.check("在「仓库任务中心」里处理。", noPlaces, "", "", java.util.List.of(), 4000,
                "仓库管理\n仓库任务中心\n工作台 > 仓库管理 > 仓库任务中心", null).accepted()).as("a directory title").isTrue();
        assertThat(AiChatAnswerGuard.check("刚才说的「生产报工」页。", noPlaces, "Q: 怎么报工\nA: 在「生产报工」页填。", "",
                java.util.List.of(), 4000).accepted()).as("named earlier in the conversation").isTrue();

        // Symbols and comparisons are not names.
        assertThat(AiChatAnswerGuard.check("估算值带「≈」。", noPlaces, "").accepted()).isTrue();
        assertThat(AiChatAnswerGuard.check("实收 > 0 时才入库。", noPlaces + " 0", "").problems())
                .noneMatch(problem -> problem.startsWith("NAV"));
    }

    /**
     * Live regression 2026-10-06 (#3 单重, #5 汇率): the baseline's grounded answers quote rules in 「」 for emphasis and
     * write an order of precedence with ">"; neither is a page, menu or button, so neither is checked as navigation.
     * Lines of those two answers (brackets written half-width); nothing known is passed in, so only real navigation
     * can be reported.
     */
    @Test void rulesQuotedForEmphasisAndPrecedenceChainsAreNotNavigation() {
        String weight = """
                没称重的入库行本身不参与单重的计算、也不会产生新的学习证据；页面上用到的单重是从其它「有独立数量又有实称重量」的证据(称样、盘点、称过重的到货/产成品/其它入库)学出来的，而这条没称的入库行的重量再反过来按「学到的单重(或库存均重)× 数量」估算，估算值带「≈」，实在推不出来就显示「未称」。
                1. 没称的行不记观测：单重学习只认「独立数量 + 实称重量」。到货登记只对每条称过的收货行记一条观测(供应商取本行订货单的供应商)；没称的行、按称重改数量的行、按重量计的行都不记。手工其它入库、产成品进仓审核时同样只记「称过且数量不是按称重推算」的行。所以本次没称重，对单重学习没有贡献。
                   - 否则按「入库未称」：单重可靠(绿/黄)→ 按学到的单重估算；否则按库存均重；再否则按任意单重估算；都没有 → 未知，界面显示「未称」，永远不显示成 0。
                下一步：
                - 想看或核对单重：货品详情「库存与出入库」页签里的单重学习(当前单重、供应商对比、观测记录、称样与设置)；仓库中心 → 库存查询 → 「库存分析」里的单重学习；单据行右键「称样校准...」，数个数、称重量，保存后立即刷新该货品单重。""";
        String rate = """
                1. 规则是「出货的记账汇率在财务放行这一刻确认并冻结到本单；仓库确认出库按冻结值折算本币立应收」。所以起决定作用的是放行日，财务可按放行当日汇率修改后确认。
                2. 放行前财审页「记账汇率」框的预填顺序：本单已冻结的 > 本位币填 1 > 币种主档参考汇率 > 空(主档没维护时由财务填写)。主档只是默认值来源，没维护不会挡放行，但空着放行仍会被拦下。
                8. 后续收款时「本批汇率报价」按币种预填主档参考汇率(本位币锁 1，主档没有则留空由财务按银行回单填)；收款汇率与应收记账汇率的差额进汇兑损益，不回调应收。""";
        java.util.List<String> problems = new java.util.ArrayList<>();
        AiChatAnswerGuard.checkNavigation(rate, "", problems);
        assertThat(problems).isEmpty();
        AiChatAnswerGuard.checkNavigation(weight, "", problems);
        assertThat(problems).as("only the tab name is navigation").containsExactly("NAV:库存与出入库");
        problems.clear();
        AiChatAnswerGuard.checkNavigation(weight, "货品详情页的「库存与出入库」页签显示单重学习", problems);
        assertThat(problems).isEmpty();
        // Precedence with a step after a number is still not a path ("… 1 > 币种主档参考汇率 > 留空").
        AiChatAnswerGuard.checkNavigation("预填顺序：本单已冻结的 > 本位币填 1 > 币种主档参考汇率 > 留空。", "", problems);
        assertThat(problems).isEmpty();
        // A path that starts at the workbench, or follows "路径：", is navigation wherever it stands.
        AiChatAnswerGuard.checkNavigation("路径：仓库管理 > 库存台账。\n也可以走 工作台 > 仓库管理 > 库存台账。", "仓库管理", problems);
        assertThat(problems).containsExactly("NAV:仓库管理 > 库存台账", "NAV:工作台 > 仓库管理 > 库存台账");
        // The later steps of a quoted path continue it; a status flow written with arrows is not a path.
        problems.clear();
        AiChatAnswerGuard.checkNavigation("进入「设置」→「外观」→「字号」，往大一档点选。", "设置页", problems);
        assertThat(problems).containsExactly("NAV:外观", "NAV:字号");
        problems.clear();
        AiChatAnswerGuard.checkNavigation("状态从「草稿」→「待财务审核」→「已审核」。", "", problems);
        assertThat(problems).isEmpty();
    }

    /**
     * When unverified navigation is the only problem, the lines that carry it are dropped and the verified rest is kept
     * (with no lead-in left dangling); with any other problem, or too little left, the whole reply is rejected.
     */
    @Test void unverifiedNavigationLinesAreDroppedWhenTheRestIsGrounded() {
        String rule = "超收：最多可收 = 订货量 + 允许超收量。允许超收量按订货单明细上的「允许超收%」计算；在这个范围以内照常入库、立应付；"
                + "超过的话整张收货单先不入库、不立应付，转财务审批，财务可以全部接收、指定接收或拒收超量。";
        String reply = "能收，但要看多送的部分有没有超过「订货量+允许超收量」。\n"
                + "1. 最多可收 = 订货量 + 允许超收量，允许超收量按订货单明细上的「允许超收%」计算。\n"
                + "2. 在这个范围以内照常入库、立应付；超过的话整张收货单先不入库、不立应付，转财务审批。\n"
                + "3. 财务可以全部接收、指定接收或拒收超量。\n"
                + "下一步：\n- 到「超收审批中心」里看审批进度。";
        var kept = AiChatAnswerGuard.check(reply, rule, "供应商多送了能收吗");
        assertThat(kept.accepted()).as(kept.problems().toString()).isTrue();
        assertThat(kept.reply()).doesNotContain("超收审批中心").doesNotContain("下一步").contains("转财务审批");
        assertThat(kept.dropped()).containsExactly("NAV:超收审批中心");
        assertThat(kept.problems()).isEmpty();

        var withNumber = AiChatAnswerGuard.check(reply + "\n4. 一般超收 7% 以内都能收。", rule, "供应商多送了能收吗");
        assertThat(withNumber.accepted()).isFalse();
        assertThat(withNumber.problems()).contains("NAV:超收审批中心", "NUMBER:7");
        var mostlyNavigation = AiChatAnswerGuard.check("能收。\n到「超收审批中心」里点「批准超收」按钮，再到「到货异常」页签确认。", rule, "");
        assertThat(mostlyNavigation.accepted()).as("too little would remain").isFalse();
        assertThat(mostlyNavigation.dropped()).isEmpty();
    }

    /**
     * ADR-159 (A7, live N2 「发布(PUBLISHED)」): internal status and type codes taken from the documents are dropped, or
     * become the Chinese meaning the sources give them; business acronyms, document numbers and words the user typed or
     * can see stay; an English reply is not touched.
     */
    @Test void internalStatusCodesAreRemovedOrSaidInChinese() {
        // A code in brackets after the word it stands for goes with its brackets.
        assertThat(AiChatAnswerGuard.withoutStatusCodes("复核通过后再由发布人发布\uFF08PUBLISHED\uFF09才算办结。", "发布\uFF08PUBLISHED\uFF09", ""))
                .isEqualTo("复核通过后再由发布人发布才算办结。");
        assertThat(AiChatAnswerGuard.withoutStatusCodes("先在物料分析里选好路线(MAKE/BUY)再下达。", "", ""))
                .isEqualTo("先在物料分析里选好路线再下达。");
        // A hyphenated or numbered code is a document number, checked as a code elsewhere: it stays.
        assertThat(AiChatAnswerGuard.withoutStatusCodes("刚才的 TASK-A01 还缺外壳，见 ADR-135 的规则。", "", ""))
                .isEqualTo("刚才的 TASK-A01 还缺外壳，见 ADR-135 的规则。");
        // A code on its own: the meaning the sources pair with it, in any of the three written forms.
        assertThat(AiChatAnswerGuard.withoutStatusCodes("订单状态是 SHIPPED。", "出货单 SHIPPED\uFF08已发货\uFF09后不能再改", ""))
                .isEqualTo("订单状态是已发货。");
        assertThat(AiChatAnswerGuard.withoutStatusCodes("订单状态是 SHIPPED。", "| 已发货\uFF08SHIPPED\uFF09 | 仓库确认出库 |", ""))
                .isEqualTo("订单状态是已发货。");
        assertThat(AiChatAnswerGuard.withoutStatusCodes("计划状态为 WAITING，等物料齐了再开工。", "WAITING = 待开工", ""))
                .isEqualTo("计划状态为待开工，等物料齐了再开工。");
        // The meaning already said right before the code: the code just goes.
        assertThat(AiChatAnswerGuard.withoutStatusCodes("状态变为已发货 SHIPPED 后不能再改。", "已发货\uFF08SHIPPED\uFF09", ""))
                .isEqualTo("状态变为已发货后不能再改。");
        // No meaning in the sources: the code goes, with the separators and spaces it leaves behind.
        assertThat(AiChatAnswerGuard.withoutStatusCodes("BUY、SUBCONTRACT 是物料任务，根产品可先生成 WAITING 生产计划；MAKE child item 也可以。",
                "", "")).isEqualTo("是物料任务，根产品可先生成生产计划；child item 也可以。");
        // Business acronyms, document numbers and order numbers stay.
        String acronyms = "下单前先核对 BOM 里每个子件的用量，到货后做 IQC 来料检验，完工后做 FQC 成品检验，出货前再做 OQC 抽检；"
                + "这些检验统称 QC。采购按 SKU 和 MOQ 下单，清单可以导出成 PDF 或 Excel 交给 ERP 以外的同事，也可以问 AI 助手；"
                + "详细规则见 ADR-135，订单号 XD20261006000003 的单位是 PCS。";
        assertThat(AiChatAnswerGuard.withoutStatusCodes(acronyms, "", "")).isEqualTo(acronyms);
        // The user's own word or what is on their screen stays.
        assertThat(AiChatAnswerGuard.withoutStatusCodes("PUBLISHED 表示已经发布给员工查看。", "", "PUBLISHED 是什么意思"))
                .isEqualTo("PUBLISHED 表示已经发布给员工查看。");
        // An English reply's capitals are words.
        assertThat(AiChatAnswerGuard.withoutStatusCodes("Do NOT submit the order twice; it is SHIPPED once approved.", "", ""))
                .isEqualTo("Do NOT submit the order twice; it is SHIPPED once approved.");
        assertThat(AiChatAnswerGuard.withoutStatusCodes("没有代码的回答不变。", "", "")).isEqualTo("没有代码的回答不变。");
    }

    /** ADR-159 (A7) through the full check: a document's code is not on the user's screen, a page's own value is. */
    @Test void theGuardDropsDocumentCodesButKeepsWhatThePageShows() {
        String rule = "工资审核通过 → 发布人「待发布」卡\uFF08发布办结\uFF09；发布\uFF08PUBLISHED\uFF09后员工可以查看本人工资条。";
        var verdict = AiChatAnswerGuard.check("审核通过后由发布人发布\uFF08PUBLISHED\uFF09，发布后员工才能看到本人工资条。", rule, "",
                "工资条怎么发布", java.util.List.of(), 4000, "", null);
        assertThat(verdict.accepted()).as(verdict.problems().toString()).isTrue();
        assertThat(verdict.reply()).isEqualTo("审核通过后由发布人发布，发布后员工才能看到本人工资条。");
        var onPage = AiChatAnswerGuard.check("第 3 行的路线是 MAKE，可以直接下达车间。", "第 3 行 路线 MAKE", "", "第3行怎么下达",
                java.util.List.of(), 4000, "第 3 行 路线 MAKE", null);
        assertThat(onPage.reply()).contains("MAKE");
    }
}
