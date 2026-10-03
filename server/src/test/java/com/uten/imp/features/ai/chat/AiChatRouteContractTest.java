package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiChatToolPort;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class AiChatRouteContractTest {
    private final ObjectMapper json = new ObjectMapper();

    @Test void onlyCurrentCapabilitiesAndFieldKeysAppearInTheContract() throws Exception {
        var knowledge = List.of(new AiChatKnowledge.Entry("SALES_GUIDE", "SALES", "销售", "PRIVATE_WORKFLOW_REPLY", List.of()));
        var page = Optional.of(new AiChatPageGuideCatalog.PageGuide("quote", "报价单", "SALES", "guide",
                List.of(new AiChatPageGuideCatalog.FieldGuide("quantity", "数量", "PRIVATE_FIELD_INSTRUCTION", "PRIVATE_FIELD_EXAMPLE"))));
        var contract = AiChatRouteContract.create(List.of(), knowledge, page, false);
        JsonNode schema = json.valueToTree(contract.schema());
        assertThat(schema.path("properties").path("intent").path("enum").toString()).contains("PAGE_HELP", "KNOWLEDGE").doesNotContain("TOOL", "SALES_DRAFT");
        assertThat(schema.path("properties").path("tool").path("enum").toString()).isEqualTo("[\"\"]");
        assertThat(schema.path("properties").path("knowledgeId").path("enum").toString()).isEqualTo("[\"\",\"SALES_GUIDE\"]");
        assertThat(schema.path("properties").path("fieldKey").path("enum").toString()).isEqualTo("[\"\",\"quantity\"]");
        assertThat(contract.toString()).doesNotContain("PRIVATE_", "query_goods_cost", "prepare_permission_grant");
        assertStrictObjects(schema);
        JsonNode example = json.readTree(contract.exampleJson());
        assertThat(example.path("intent").asText()).isEqualTo("PAGE_HELP");
        assertThat(example.size()).isEqualTo(5);
        assertThat(example.path("arguments").isObject()).isTrue();
    }

    @Test void eachToolGetsItsOwnClosedArgumentShapeAndNoReturnValueIsRead() {
        AiChatToolPort tool = tool("query_goods_cost", Map.of("type", "object", "additionalProperties", false,
                "properties", Map.of("goodsKeyword", Map.of("type", "string", "minLength", 1, "maxLength", 100)),
                "required", List.of("goodsKeyword")));
        var contract = AiChatRouteContract.create(List.of(tool), List.of(), Optional.empty(), true);
        JsonNode schema = json.valueToTree(contract.schema());
        JsonNode variants = schema.path("properties").path("arguments").path("anyOf");
        assertThat(variants.size()).isEqualTo(2);
        assertThat(variants.get(0).path("properties").size()).isZero();
        assertThat(variants.get(1).path("required").get(0).asText()).isEqualTo("goodsKeyword");
        assertThat(variants.get(1).path("properties").path("goodsKeyword").path("maxLength").asInt()).isEqualTo(100);
        assertThat(schema.path("properties").path("intent").path("enum").toString()).contains("TOOL", "SALES_DRAFT");
        assertStrictObjects(schema);
        verify(tool, never()).execute(any());
    }

    @Test void optionalArgumentsAreOmittedOrPresentNeverInventedAsNull() {
        AiChatToolPort tool = tool("lookup", Map.of("type", "object", "additionalProperties", false,
                "properties", Map.of("query", Map.of("type", "string"), "limit", Map.of("type", "integer", "minimum", 1, "maximum", 5)),
                "required", List.of("query")));
        JsonNode schema = json.valueToTree(AiChatRouteContract.create(List.of(tool), List.of(), Optional.empty(), false).schema());
        assertStrictObjects(schema);
        assertThat(schema.path("properties").path("arguments").path("anyOf").size()).isEqualTo(3);
        assertThat(schema.toString()).doesNotContain("\"null\"");
    }

    @Test void openEndedToolSchemasCannotEnterTheRoutingContract() {
        AiChatToolPort tool = tool("unsafe", Map.of("type", "object", "properties", Map.of(), "required", List.of(), "additionalProperties", true));
        assertThatThrownBy(() -> AiChatRouteContract.create(List.of(tool), List.of(), Optional.empty(), false))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test void missingPropertyTypeFailsAsInvalidSchemaWithoutNullDereference() {
        AiChatToolPort tool = tool("invalid", Map.of("type", "object", "additionalProperties", false,
                "properties", Map.of("query", Map.of("maxLength", 10)), "required", List.of("query")));
        assertThatThrownBy(() -> AiChatRouteContract.create(List.of(tool), List.of(), Optional.empty(), false))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("property type");
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
