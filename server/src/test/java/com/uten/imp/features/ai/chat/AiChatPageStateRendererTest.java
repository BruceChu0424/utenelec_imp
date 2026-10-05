package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class AiChatPageStateRendererTest {
    private final ObjectMapper json = new ObjectMapper();

    /** The eight readiness tones of 我的车间任务 (production_flow_stage_cell.dart). */
    private AiChatPageSnapshot workshop() {
        String[][] legend = {
                {"绿", "success", "可开工", "材料齐了，可以开工", "6"},
                {"琥珀", "warning", "部分齐", "部分材料已到，可以先做一部分", "4"},
                {"蓝", "info", "去领料", "仓库已备好，去领料", "3"},
                {"紫", "violet", "部分可领", "部分物料可领，先去领料", "2"},
                {"青绿", "accent", "待仓库发料", "已申请，等仓库发料", "2"},
                {"灰", "neutral", "缺料", "还缺材料，等采购或生产", "5"},
                {"品红", "fuchsia", "等计划", "等计划员下达", "1"},
                {"红", "danger", "待选路线", "还没选生产路线，先选路线", "1"}};
        List<Map<String, Object>> entries = new ArrayList<>();
        for (String[] item : legend) entries.add(Map.of("column", "状态", "color", item[0], "tone", item[1], "value", item[2],
                "meaning", item[3], "count", Integer.parseInt(item[4])));
        return json.convertValue(Map.of("title", "我的车间任务", "tables", List.of(Map.of("title", "车间任务", "totalRows", 24,
                "visibleRows", 24, "columns", List.of(Map.of("label", "货品"), Map.of("label", "状态")), "rows", List.of(),
                "legend", entries))), AiChatPageSnapshot.class).sanitized();
    }

    private AiChatPageSnapshot salesReview() {
        List<Map<String, Object>> flagged = new ArrayList<>();
        for (int row = 1; row <= 11; row++) flagged.add(Map.of("rowNo", row, "rowLabel", "V5ZJ00" + row, "column", "单价",
                "value", "0", "state", "REVIEW", "reason", "标价为0, 要先做报价单交给财务定价"));
        flagged.add(Map.of("rowNo", 12, "rowLabel", "A-12", "column", "单价", "value", "9.9", "state", "REVIEW",
                "reason", "客户单价高于标价, 请核对"));
        return json.convertValue(Map.of("title", "新建销售订货单", "tables", List.of(Map.of("title", "货品明细",
                        "columns", List.of(Map.of("label", "货品")), "rows", List.of(), "flaggedCells", flagged)),
                "fields", List.of(Map.of("label", "客户", "state", "REQUIRED_EMPTY", "required", true),
                        Map.of("label", "币种", "value", "USD", "state", "AUTOFILLED", "message", "按文件识别"))),
                AiChatPageSnapshot.class).sanitized();
    }

    @Test void workshopColourQuestionListsAllEightColoursWithStatusMeaningAndCount() {
        String reply = AiChatPageStateRenderer.render(workshop(), "不同的状态分别是什么颜色", "");
        assertThat(reply).startsWith("页面上的状态颜色(颜色 = 状态 = 含义):")
                .contains("1. 绿 = 可开工 = 材料齐了，可以开工 (6 行)", "2. 琥珀 = 部分齐", "3. 蓝 = 去领料",
                        "4. 紫 = 部分可领 = 部分物料可领，先去领料 (2 行)", "5. 青绿 = 待仓库发料", "6. 灰 = 缺料",
                        "7. 品红 = 等计划", "8. 红 = 待选路线 = 还没选生产路线，先选路线 (1 行)")
                .doesNotContain("还有");
    }

    @Test void salesReviewListsTwelveItemsThenTheRemainderAndFieldProblems() {
        String reply = AiChatPageStateRenderer.render(salesReview(), "这个订单哪个产品需要再确认", "");
        assertThat(reply).startsWith("需要你核对的有 14 项:")
                .contains("1. 第 1 行 V5ZJ001 / 单价: 黄框待核对; 当前值 0; 原因: 标价为0, 要先做报价单交给财务定价; 建议: 核对无误就保留，不对就改正",
                        "12. 第 12 行 A-12 / 单价: 黄框待核对; 当前值 9.9; 原因: 客户单价高于标价, 请核对", "还有 2 项。")
                .doesNotContain("13. ");
        assertThat(AiChatPageStateRenderer.review(salesReview())).contains("还有 2 项");
    }

    @Test void colourQuestionWithoutALegendExplainsThePlatformConventionsInstead() {
        var empty = json.convertValue(Map.of("title", "空页面"), AiChatPageSnapshot.class).sanitized();
        String reply = AiChatPageStateRenderer.render(empty, "红框是什么意思", "红框: 必填但还没填");
        assertThat(reply).contains("没有登记状态颜色的图例", "红框: 必填但还没填");
        assertThat(AiChatPageStateRenderer.render(empty, "有什么需要检查", "")).contains("没有标出需要核对的值");
    }

    /** A3 quality P2: a question about one row falls back to that row, not to a whole-page overview. */
    @Test void aQuestionAboutOneRowIsAnsweredFromThatRow() {
        var snapshot = json.convertValue(Map.of("title", "我的车间任务", "tables", List.of(Map.of("title", "车间任务",
                "columns", List.of(Map.of("label", "工单"), Map.of("label", "状态"), Map.of("label", "物料"), Map.of("label", "下一步")),
                "rows", List.of(Map.of("no", 1, "cells", List.of("GD-1", "可开工", "已领 3/3 种", "开工")),
                        Map.of("no", 3, "cells", List.of("GD-0", "等待物料到齐 · 已备 2/3 种", "已领 0/3 种 · 缺 1 种", "齐套生产"))),
                "legend", List.of(Map.of("column", "状态", "color", "琥珀", "value", "等待物料到齐", "meaning", "齐套路线要求领齐才开工", "count", 1))))),
                AiChatPageSnapshot.class).sanitized();
        String question = "第3行为什么还不能开工？下一步该做什么？";
        assertThat(AiChatPageStateRenderer.focus(question)).isEqualTo(AiChatPageStateRenderer.Focus.ROW);
        String reply = AiChatPageStateRenderer.render(snapshot, question, "");
        assertThat(reply).startsWith("第 3 行 GD-0").contains("状态: 等待物料到齐 · 已备 2/3 种 (琥珀 = 等待物料到齐: 齐套路线要求领齐才开工)",
                "物料: 已领 0/3 种 · 缺 1 种", "下一步: 齐套生产").doesNotContain("GD-1", "列: ");
        assertThat(AiChatPageStateRenderer.render(snapshot, "第 9 行是什么", "")).startsWith("当前页面");
        // Only a pure legend question is answered without the model; a "why" is reasoned by the model.
        assertThat(AiChatPageStateRenderer.legendOnly(workshop(), "不同状态是什么颜色")).isTrue();
        assertThat(AiChatPageStateRenderer.legendOnly(workshop(), "为什么第3行是黄色的")).isFalse();
        assertThat(AiChatPageStateRenderer.legendOnly(workshop(), "黄色是什么意思，下一步该做什么")).isFalse();
    }

    @Test void summaryMentionsTablesLegendAndCountsWithoutInventingMeaning() {
        String reply = AiChatPageStateRenderer.render(workshop(), "这个页面是做什么的", "");
        assertThat(reply).contains("当前页面: 我的车间任务", "表格 车间任务: 共 24 行，当前显示 24 行", "列: 货品、状态",
                "绿 = 可开工 = 材料齐了，可以开工 (6 行)");
        var noMeaning = json.convertValue(Map.of("tables", List.of(Map.of("columns", List.of(), "rows", List.of(),
                "legend", List.of(Map.of("value", "处理中", "tone", "info"))))), AiChatPageSnapshot.class).sanitized();
        assertThat(AiChatPageStateRenderer.render(noMeaning, "颜色", "")).contains("蓝 = 处理中 = 页面没有写明含义");
    }
}
