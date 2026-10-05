package com.uten.imp.features.ai.chat;

import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/** ADR-152 bounded conversation memory: order, budget, cross-page labels and withheld answers. */
class AiChatConversationTest {
    private static AiChatConversation.Turn turn(String question, String reply, boolean shareable, String page, String route) {
        return new AiChatConversation.Turn(question, reply, shareable, page, route, "", "PAGE_STATE", "", Map.of(),
                Map.of(), List.of());
    }

    @Test void turnsAreOldestFirstWithTheirPageAndTool() {
        var newest = new AiChatConversation.Turn("刚才那个任务对应的订单能发货吗", "可以发货。", true, "销售订货", "/sales/orders",
                "订单发货查询", "TOOL", "", Map.of(), Map.of(), List.of());
        var oldest = turn("哪些任务缺料", "第1行 HP035754 缺料", true, "我的车间任务", "/production/workshop-tasks");
        var history = AiChatConversation.assemble(List.of(newest, oldest), 0);
        assertThat(history.carried()).containsExactly(oldest, newest);
        assertThat(history.latest()).isEqualTo(newest);
        assertThat(history.truncated()).isFalse();
        assertThat(history.text()).startsWith("Turn 1 (page: 我的车间任务 /production/workshop-tasks)\nQ: 哪些任务缺料\nA: 第1行 HP035754 缺料")
                .contains("Turn 2 (page: 销售订货 /sales/orders) (tool: 订单发货查询)\nQ: 刚才那个任务对应的订单能发货吗\nA: 可以发货。");
    }

    @Test void sensitiveAnswersKeepOnlyTheQuestionAndCardsOnlyTheirTitles() {
        var sensitive = turn("A001 成本多少", "PRIVATE_COST_765432", false, "", "");
        var card = new AiChatConversation.Turn("把第3行数量改成100", "我准备了一个操作", true, "新建销售订货单", "/sales/orders/new",
                "", "ACTION", "", Map.of(), Map.of(), List.of("修改明细行"));
        var history = AiChatConversation.assemble(List.of(card, sensitive), 0);
        assertThat(history.text()).contains("(no page)\nQ: A001 成本多少\nA: " + AiChatConversation.WITHHELD)
                .contains("(确认卡: 修改明细行)").doesNotContain("PRIVATE_COST", "765432");
        assertThat(history.memoryEvidence()).doesNotContain("765432");
    }

    @Test void historyIsBoundedAndDropsTheOldestTurnsFirst() {
        List<AiChatConversation.Turn> newestFirst = new ArrayList<>();
        for (int i = 10; i >= 1; i--) newestFirst.add(turn("问题" + i + "号", ("回答" + i + "号。").repeat(200), true, "页面" + i, "/p"));
        var history = AiChatConversation.assemble(newestFirst, 2);
        assertThat(AiChatConversation.utf8(history.text())).isLessThanOrEqualTo(AiChatConversation.MAX_BYTES);
        assertThat(history.truncated()).isTrue();
        assertThat(history.text()).startsWith(AiChatConversation.OMITTED).contains("问题10号").doesNotContain("问题1号\n");
        assertThat(history.carried().getLast().question()).isEqualTo("问题10号");
        assertThat(history.hidden()).isEqualTo(2);
        // The newest reply keeps more text than the older ones and every cut is marked.
        assertThat(history.text()).contains("...(已截断)");
        String newestBlock = history.text().substring(history.text().lastIndexOf("Q: 问题10号"));
        assertThat(AiChatConversation.utf8(newestBlock)).isGreaterThan(AiChatConversation.OLDER_REPLY_BYTES);
    }

    /** The 8 KB contract covers the text as sent, including every "Turn N " prefix and line break. */
    @Test void theByteBudgetCoversTheTurnPrefixes() {
        // Sizes where the blocks alone fit but blocks plus prefixes went over 8 KB before (8227, 8290, 8301 bytes).
        for (int[] shape : new int[][] {{10, 332}, {20, 143}, {40, 59}}) {
            int count = shape[0];
            List<AiChatConversation.Turn> newestFirst = new ArrayList<>();
            for (int i = count; i >= 1; i--) newestFirst.add(turn("问" + i, "答".repeat(shape[1]), true, "", ""));
            var history = AiChatConversation.assemble(newestFirst, 0);
            assertThat(AiChatConversation.utf8(history.text())).as(count + " turns").isLessThanOrEqualTo(AiChatConversation.MAX_BYTES);
        }
        var builder = new AiChatConversation.Builder(2);
        assertThat(builder.open()).isTrue();
        assertThat(builder.offer(turn("问1", "答", true, "", ""))).isTrue();
        assertThat(builder.offer(turn("问2", "答", true, "", ""))).isTrue();
        assertThat(builder.open()).as("the memory setting bounds the turns read").isFalse();
        assertThat(builder.offer(turn("问3", "答", true, "", ""))).isFalse();
    }

    @Test void aTurnWhoseDataChangedKeepsOnlyItsQuestion() {
        var changed = new AiChatConversation.Turn("HP035754 还有多少库存", "", false, "库存查询", "/stock", "库存查询", "TOOL", "",
                Map.of(), Map.of("tool", "inventory_lookup"), List.of(), true);
        var history = AiChatConversation.assemble(List.of(changed), 0);
        assertThat(history.text()).contains("Q: HP035754 还有多少库存\nA: " + AiChatConversation.DATA_CHANGED);
        assertThat(history.latest().query()).containsEntry("tool", "inventory_lookup");
    }

    @Test void clippingNeverSplitsACharacter() {
        String clipped = AiChatConversation.clip("缺料".repeat(100), 50);
        assertThat(AiChatConversation.utf8(clipped)).isLessThanOrEqualTo(50);
        assertThat(clipped).endsWith("...(已截断)").doesNotContain("�");
        assertThat(AiChatConversation.assemble(List.of(), 3)).satisfies(empty -> {
            assertThat(empty.isEmpty()).isTrue();
            assertThat(empty.hidden()).isEqualTo(3);
            assertThat(empty.latest()).isNull();
        });
    }
}
