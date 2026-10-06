package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiCompletionPort.AiReasoningEffort;
import com.uten.imp.application.port.UserPreferenceReadPort;
import com.uten.imp.application.port.UserPreferenceWritePort;
import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** ADR-152 chat settings: whitelisted values, sensible defaults, tolerant reads and strict writes. */
class AiChatSettingsTest {
    private final ObjectMapper json = new ObjectMapper();

    private JsonNode node(String text) throws Exception { return json.readTree(text); }

    @Test void newAccountsGetTheDocumentedDefaults() {
        var defaults = AiChatSettings.DEFAULTS;
        // ADR-153 revision: fast answers by default; a question asking for a careful analysis thinks deeper for itself.
        assertThat(defaults.toJson()).isEqualTo(Map.of("detail", "STANDARD", "reasoning", "FAST", "pageAware", true,
                "showSources", true, "memoryTurns", 6, "replyLanguage", "AUTO", "sendKey", "ENTER",
                "explanationStyle", "PLAIN", "showSuggestions", true));
        assertThat(AiChatSettings.fromStored(null)).isEqualTo(defaults);
        assertThat(defaults.effort()).isEqualTo(AiReasoningEffort.OFF);
        assertThat(AiChatJobHandler.effort(defaults, "盘点有差异怎么处理")).isEqualTo(AiReasoningEffort.OFF);
        assertThat(AiChatJobHandler.effort(defaults, "请详细分析一下这个例子的重量怎么推算")).isEqualTo(AiReasoningEffort.MEDIUM);
        assertThat(AiChatJobHandler.effort(defaults.merge(com.fasterxml.jackson.databind.json.JsonMapper.builder().build()
                .valueToTree(Map.of("reasoning", "DEEP"))), "请详细分析")).as("a deeper account choice is never lowered")
                .isEqualTo(AiReasoningEffort.HIGH);
    }

    @Test void thinkingDepthMapsToTheProviderNeutralEffort() throws Exception {
        assertThat(AiChatSettings.DEFAULTS.merge(node("{\"reasoning\":\"FAST\"}")).effort()).isEqualTo(AiReasoningEffort.OFF);
        assertThat(AiChatSettings.DEFAULTS.merge(node("{\"reasoning\":\"DEEP\"}")).effort()).isEqualTo(AiReasoningEffort.HIGH);
    }

    @Test void storedValuesFallBackFieldByFieldAndNeverBreak() throws Exception {
        var stored = AiChatSettings.fromStored(node("""
                {"detail":"CONCISE","reasoning":"TURBO","pageAware":"yes","memoryTurns":99,"replyLanguage":"EN",
                 "sendKey":"CTRL_ENTER","showSources":false,"extra":"ignored"}"""));
        assertThat(stored.detail()).isEqualTo(AiChatSettings.Detail.CONCISE);
        assertThat(stored.reasoning()).isEqualTo(AiChatSettings.Reasoning.FAST);
        assertThat(stored.pageAware()).isTrue();
        assertThat(stored.memoryTurns()).isEqualTo(6);
        assertThat(stored.replyLanguage()).isEqualTo(AiChatSettings.Language.EN);
        assertThat(stored.sendKey()).isEqualTo(AiChatSettings.SendKey.CTRL_ENTER);
        assertThat(stored.showSources()).isFalse();
        assertThat(AiChatSettings.fromStored(node("[1,2]"))).isEqualTo(AiChatSettings.DEFAULTS);
    }

    @Test void changesAcceptOnlyKnownFieldsWithAllowedValues() throws Exception {
        var changed = AiChatSettings.DEFAULTS.merge(node("{\"detail\":\"COMPREHENSIVE\",\"memoryTurns\":10,\"showSuggestions\":false}"));
        assertThat(changed.detail()).isEqualTo(AiChatSettings.Detail.COMPREHENSIVE);
        assertThat(changed.memoryTurns()).isEqualTo(10);
        assertThat(changed.showSuggestions()).isFalse();
        assertThat(changed.reasoning()).isEqualTo(AiChatSettings.Reasoning.FAST);
        for (int turns : AiChatSettings.MEMORY_CHOICES) {
            assertThat(AiChatSettings.DEFAULTS.merge(node("{\"memoryTurns\":" + turns + "}")).memoryTurns()).isEqualTo(turns);
        }
        for (String invalid : List.of("{}", "[]", "\"detail\"", "{\"detail\":\"concise\"}", "{\"detail\":\"VERBOSE\"}",
                "{\"memoryTurns\":7}", "{\"memoryTurns\":\"6\"}", "{\"memoryTurns\":6.5}", "{\"pageAware\":\"false\"}",
                "{\"replyLanguage\":\"FR\"}", "{\"sendKey\":1}", "{\"sensitiveFields\":true}", "{\"memoryTurns\":100}",
                "{\"detail\":\"STANDARD\",\"superAdmin\":true}")) {
            assertThatThrownBy(() -> AiChatSettings.DEFAULTS.merge(node(invalid))).as(invalid).isInstanceOf(ApiException.class);
        }
    }

    @Test void serviceStoresTheNormalizedSettingsUnderTheFeatureOwnedKey() throws Exception {
        var reader = mock(UserPreferenceReadPort.class);
        var writer = mock(UserPreferenceWritePort.class);
        when(reader.currentUserPreference(AiChatSettings.PREFERENCE_KEY))
                .thenReturn(Optional.of(node("{\"detail\":\"CONCISE\",\"memoryTurns\":3}")));
        var service = new AiChatSettingsService(reader, writer, json);
        assertThat(service.current().detail()).isEqualTo(AiChatSettings.Detail.CONCISE);
        var saved = service.update(node("{\"reasoning\":\"DEEP\"}"));
        assertThat(saved.detail()).isEqualTo(AiChatSettings.Detail.CONCISE);
        assertThat(saved.memoryTurns()).isEqualTo(3);
        var value = ArgumentCaptor.forClass(JsonNode.class);
        verify(writer).putOwnedPreference(eq(AiChatSettings.PREFERENCE_KEY), value.capture());
        assertThat(json.convertValue(value.getValue(), new TypeReference<Map<String, Object>>() {})).isEqualTo(saved.toJson());
        assertThat(AiChatSettings.PREFERENCE_KEY).startsWith(UserPreferenceWritePort.RESERVED_PREFIX);

        var rejected = mock(UserPreferenceWritePort.class);
        var strict = new AiChatSettingsService(reader, rejected, json);
        assertThatThrownBy(() -> strict.update(node("{\"reasoning\":\"MAX\"}"))).isInstanceOf(ApiException.class);
        verify(rejected, never()).putOwnedPreference(eq(AiChatSettings.PREFERENCE_KEY), org.mockito.ArgumentMatchers.any());
    }
}
