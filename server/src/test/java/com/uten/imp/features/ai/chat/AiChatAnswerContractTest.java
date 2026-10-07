package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiChatToolPort;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class AiChatAnswerContractTest {
    private final ObjectMapper json = new ObjectMapper();
    private static final Map<String, Object> ROW_VALUE = Map.of("type", "object", "additionalProperties", false,
            "properties", Map.of("row", Map.of("type", "integer", "title", "行号", "minimum", 1, "maximum", 500),
                    "value", Map.of("type", "string", "title", "新值", "maxLength", 80)),
            "required", List.of("row", "value"));

    @Test void onlyIssuedSourceIdsIntentsAndCurrentPageActionsAppearInTheContract() throws Exception {
        var action = new AiChatPageSnapshot.PageAction("setLineQty", "改数量", "FORM", "LOW", ROW_VALUE);
        var contract = AiChatAnswerContract.create(List.of(), List.of("page.tables", "page.legend", "knowledge.UI_CONVENTIONS"),
                true, false, true, List.of(action));
        JsonNode schema = json.valueToTree(contract.schema());
        assertThat(schema.path("properties").path("intent").path("enum").toString())
                .contains("PAGE_STATE", "PAGE_HELP", "KNOWLEDGE", "ACTION").doesNotContain("TOOL", "SALES_DRAFT");
        assertThat(schema.path("properties").path("tool").path("enum").toString()).isEqualTo("[\"\"]");
        assertThat(schema.path("properties").path("usedSources").path("items").path("enum").toString())
                .isEqualTo("[\"page.tables\",\"page.legend\",\"knowledge.UI_CONVENTIONS\"]");
        assertThat(schema.path("properties").path("action").path("properties").path("name").path("enum").toString())
                .isEqualTo("[\"\",\"setLineQty\"]");
        assertThat(schema.path("properties").path("action").path("properties").path("args").path("anyOf").size()).isEqualTo(2);
        assertThat(schema.toString()).doesNotContain("mode", "fieldKey", "knowledgeId");
        assertStrictObjects(schema);
        JsonNode example = json.readTree(contract.exampleJson());
        assertThat(example.path("intent").asText()).isEqualTo("PAGE_STATE");
        // ADR-153: focus (the restated question) comes first.
        assertThat(example.size()).isEqualTo(7);
        assertThat(example.has("focus")).isTrue();
        assertThat(example.path("action").path("args").isObject()).isTrue();
    }

    @Test void withoutPageOrToolsTheModelCannotChooseThem() {
        JsonNode schema = json.valueToTree(AiChatAnswerContract.create(List.of(), List.of(), false, false, false, List.of()).schema());
        assertThat(schema.path("properties").path("intent").path("enum").toString())
                .doesNotContain("PAGE_STATE", "PAGE_HELP", "TOOL", "ACTION", "KNOWLEDGE")
                .contains("CLARIFY", "UNSUPPORTED", "GENERAL_HELP", "SMALL_TALK");
        assertThat(schema.path("properties").path("usedSources").path("items").path("enum").toString()).isEqualTo("[\"none\"]");
    }

    @Test void eachToolGetsItsOwnClosedArgumentShapeAndNoReturnValueIsRead() {
        AiChatToolPort tool = tool("query_goods_cost", Map.of("type", "object", "additionalProperties", false,
                "properties", Map.of("goodsKeyword", Map.of("type", "string", "minLength", 1, "maxLength", 100)),
                "required", List.of("goodsKeyword")));
        var contract = AiChatAnswerContract.create(List.of(tool), List.of("tool.query_goods_cost"), false, false, false, List.of());
        JsonNode schema = json.valueToTree(contract.schema());
        JsonNode variants = schema.path("properties").path("arguments").path("anyOf");
        assertThat(variants.size()).isEqualTo(2);
        assertThat(variants.get(0).path("properties").size()).isZero();
        assertThat(variants.get(1).path("required").get(0).asText()).isEqualTo("goodsKeyword");
        assertThat(variants.get(1).path("properties").path("goodsKeyword").path("maxLength").asInt()).isEqualTo(100);
        assertThat(schema.path("properties").path("intent").path("enum").toString()).contains("TOOL");
        assertStrictObjects(schema);
        verify(tool, never()).execute(any());
    }

    @Test void optionalArgumentsAreOmittedOrPresentNeverInventedAsNull() {
        AiChatToolPort tool = tool("lookup", Map.of("type", "object", "additionalProperties", false,
                "properties", Map.of("query", Map.of("type", "string"), "limit", Map.of("type", "integer", "minimum", 1, "maximum", 5)),
                "required", List.of("query")));
        JsonNode schema = json.valueToTree(AiChatAnswerContract.create(List.of(tool), List.of(), false, false, false, List.of()).schema());
        assertStrictObjects(schema);
        assertThat(schema.path("properties").path("arguments").path("anyOf").size()).isEqualTo(3);
        assertThat(schema.toString()).doesNotContain("\"null\"");
    }

    @Test void openEndedToolSchemasCannotEnterTheContract() {
        AiChatToolPort tool = tool("unsafe", Map.of("type", "object", "properties", Map.of(), "required", List.of(), "additionalProperties", true));
        assertThatThrownBy(() -> AiChatAnswerContract.create(List.of(tool), List.of(), false, false, false, List.of()))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test void missingPropertyTypeFailsAsInvalidSchemaWithoutNullDereference() {
        AiChatToolPort tool = tool("invalid", Map.of("type", "object", "additionalProperties", false,
                "properties", Map.of("query", Map.of("maxLength", 10)), "required", List.of("query")));
        assertThatThrownBy(() -> AiChatAnswerContract.create(List.of(tool), List.of(), false, false, false, List.of()))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("property type");
    }

    @Test void toolAnswerContractOnlyCarriesReplyAndItsOwnSource() {
        JsonNode schema = json.valueToTree(AiChatAnswerContract.toolAnswer(List.of("tool.inventory_lookup")).schema());
        assertThat(schema.path("required").toString()).isEqualTo("[\"reply\",\"usedSources\"]");
        assertThat(schema.path("properties").path("usedSources").path("items").path("enum").toString())
                .isEqualTo("[\"tool.inventory_lookup\"]");
        assertStrictObjects(schema);
    }

    private AiChatToolPort tool(String name, Map<String,Object> schema) {
        AiChatToolPort tool=mock(AiChatToolPort.class); when(tool.name()).thenReturn(name); when(tool.parameters()).thenReturn(schema); return tool;
    }
    private void assertStrictObjects(JsonNode node) {
        if (node.isObject()) {
            if ("object".equals(node.path("type").asText())) {
                assertThat(node.path("additionalProperties").asBoolean(true)).isFalse();
                assertThat(node.path("required").size()).isEqualTo(node.path("properties").size());
                node.path("properties").fieldNames().forEachRemaining(name -> {
                    boolean found=false; for(JsonNode required:node.path("required")) if(name.equals(required.asText())) found=true;
                    assertThat(found).as(name).isTrue();
                });
            }
            node.elements().forEachRemaining(this::assertStrictObjects);
        } else if (node.isArray()) node.forEach(this::assertStrictObjects);
    }
}
