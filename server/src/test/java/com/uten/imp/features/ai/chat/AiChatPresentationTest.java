package com.uten.imp.features.ai.chat;

import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/** ADR-152: the account's detail level is the default; the user's own words override it for one turn. */
class AiChatPresentationTest {
    @Test void settingIsTheDefaultLength() {
        for (var level : AiChatSettings.Detail.values()) {
            var presentation = AiChatPresentation.resolve(level, "哪些任务缺料");
            assertThat(presentation.detail()).isEqualTo(level);
            assertThat(presentation.overridden()).isFalse();
            assertThat(presentation.instruction()).contains("Length: " + level.name()).doesNotContain("overrides");
        }
        assertThat(AiChatPresentation.resolve(AiChatSettings.Detail.CONCISE, "哪些任务缺料").renderMode()).isEqualTo("SUMMARY");
        assertThat(AiChatPresentation.resolve(AiChatSettings.Detail.STANDARD, "哪些任务缺料").renderMode()).isEqualTo("OVERVIEW");
    }

    @Test void theUsersWordsWinForThisTurnOnly() {
        for (String brief : List.of("简单点", "简单说一下状态颜色", "一句话告诉我", "不要展开，哪些缺料", "Keep it short, which tasks?", "간단히")) {
            var presentation = AiChatPresentation.resolve(AiChatSettings.Detail.COMPREHENSIVE, brief);
            assertThat(presentation.detail()).as(brief).isEqualTo(AiChatSettings.Detail.CONCISE);
            assertThat(presentation.overridden()).as(brief).isTrue();
            assertThat(presentation.instruction()).as(brief).contains("overrides their default");
        }
        for (String detailed : List.of("详细点", "展开说说", "全面介绍一下", "把明细全部列出来", "explain in detail", "자세히")) {
            var presentation = AiChatPresentation.resolve(AiChatSettings.Detail.CONCISE, detailed);
            assertThat(presentation.detail()).as(detailed).isEqualTo(AiChatSettings.Detail.COMPREHENSIVE);
            assertThat(presentation.wantsDetails()).as(detailed).isTrue();
            assertThat(presentation.maxReplyChars()).isGreaterThan(AiChatAnswerGuard.MAX_REPLY);
        }
        // Asking for the level that is already the default is not an override.
        assertThat(AiChatPresentation.resolve(AiChatSettings.Detail.CONCISE, "简单点").overridden()).isFalse();
    }

    @Test void examplesAndStepsAreFormatsOnTopOfTheLength() {
        var example = AiChatPresentation.resolve(AiChatSettings.Detail.STANDARD, "请举个例子");
        assertThat(example.renderMode()).isEqualTo("EXAMPLE");
        assertThat(example.instruction()).contains("Length: STANDARD", "举例(假设)");
        var steps = AiChatPresentation.resolve(AiChatSettings.Detail.CONCISE, "按步骤说");
        assertThat(steps.renderMode()).isEqualTo("STEPS");
        assertThat(steps.instruction()).contains("Length: CONCISE", "numbered steps");
    }
}
