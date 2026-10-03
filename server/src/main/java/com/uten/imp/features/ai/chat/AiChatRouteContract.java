package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiChatToolPort;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

/**
 * Provider-visible routing shape, built exclusively from currently authorized server descriptors.
 * This constrains generation, not authority: selected-tool argument and current-scope validation
 * still run immediately before execution. No business reply or tool result belongs in this schema.
 */
public record AiChatRouteContract(String schemaName, Map<String, Object> schema, String exampleJson) {
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final Map<String, Object> EMPTY_ARGUMENTS = object(Map.of());

    public static AiChatRouteContract create(List<AiChatToolPort> allowedTools,
                                             List<AiChatKnowledge.Entry> knowledge,
                                             Optional<AiChatPageGuideCatalog.PageGuide> page,
                                             boolean previousAttachment) {
        List<String> intents = new ArrayList<>(List.of("OUT_OF_SCOPE", "UNSUPPORTED", "CLARIFY"));
        if (!allowedTools.isEmpty()) intents.add("TOOL");
        if (!knowledge.isEmpty()) intents.add("KNOWLEDGE");
        if (page.isPresent()) intents.add("PAGE_HELP");
        if (previousAttachment) intents.add("SALES_DRAFT");

        Set<Map<String, Object>> argumentVariants = new LinkedHashSet<>();
        argumentVariants.add(EMPTY_ARGUMENTS);
        for (AiChatToolPort tool : allowedTools) argumentVariants.addAll(strictObjectVariants(tool.parameters(), 0));

        Map<String, Object> properties = new LinkedHashMap<>();
        properties.put("intent", strings(intents));
        properties.put("tool", strings(withEmpty(allowedTools.stream().map(AiChatToolPort::name).toList())));
        properties.put("arguments", Map.of("anyOf", List.copyOf(argumentVariants)));
        properties.put("knowledgeId", strings(withEmpty(knowledge.stream().map(AiChatKnowledge.Entry::id).toList())));
        properties.put("fieldKey", strings(withEmpty(page.map(guide -> guide.fields().stream()
                .map(AiChatPageGuideCatalog.FieldGuide::key).toList()).orElse(List.of()))));
        properties.put("mode", strings(List.of("OVERVIEW", "EXAMPLE", "STEPS", "SUMMARY")));

        Map<String, Object> example = new LinkedHashMap<>();
        example.put("intent", page.isPresent() ? "PAGE_HELP" : knowledge.isEmpty() ? "CLARIFY" : "KNOWLEDGE");
        example.put("tool", "");
        example.put("arguments", Map.of());
        example.put("knowledgeId", page.isPresent() || knowledge.isEmpty() ? "" : knowledge.getFirst().id());
        example.put("fieldKey", "");
        example.put("mode", "OVERVIEW");
        try {
            return new AiChatRouteContract("erp_chat_route_v1", object(properties), JSON.writeValueAsString(example));
        } catch (JsonProcessingException impossible) {
            throw new IllegalStateException("Cannot encode static chat routing example", impossible);
        }
    }

    private static Map<String, Object> strings(List<String> values) {
        return Map.of("type", "string", "enum", values);
    }

    private static List<String> withEmpty(List<String> values) {
        Set<String> result = new LinkedHashSet<>(); result.add(""); result.addAll(values);
        return List.copyOf(result);
    }

    private static Map<String, Object> object(Map<String, Object> properties) {
        return Map.of("type", "object", "additionalProperties", false, "properties", Map.copyOf(properties),
                "required", List.copyOf(properties.keySet()));
    }

    /**
     * Optional tool arguments use explicit closed-object variants, rather than inventing nullable
     * values which the business tool does not accept. Current tools have only required scalars.
     */
    private static List<Map<String, Object>> strictObjectVariants(Map<String, Object> source, int depth) {
        if (depth > 4 || source == null || !"object".equals(source.get("type"))
                || !Boolean.FALSE.equals(source.get("additionalProperties"))
                || !(source.get("properties") instanceof Map<?, ?> rawProperties)
                || rawProperties.size() > 8 || !(source.get("required") instanceof List<?> rawRequired)) {
            throw new IllegalArgumentException("Chat tool arguments require a bounded closed object schema");
        }
        Map<String, Object> properties = new LinkedHashMap<>();
        for (var entry : rawProperties.entrySet()) {
            if (!(entry.getKey() instanceof String key) || !(entry.getValue() instanceof Map<?, ?> value)) {
                throw new IllegalArgumentException("Invalid chat tool property schema");
            }
            Map<String, Object> child = new LinkedHashMap<>();
            value.forEach((name, rule) -> child.put(String.valueOf(name), rule));
            if ("object".equals(child.get("type"))) {
                List<Map<String, Object>> variants = strictObjectVariants(child, depth + 1);
                properties.put(key, variants.size() == 1 ? variants.getFirst() : Map.of("anyOf", variants));
            } else {
                if (!(child.get("type") instanceof String type)
                        || !Set.of("string", "boolean", "integer", "number").contains(type)) {
                    throw new IllegalArgumentException("Unsupported chat tool property type");
                }
                properties.put(key, Map.copyOf(child));
            }
        }
        Set<String> required = new LinkedHashSet<>();
        for (Object raw : rawRequired) {
            if (!(raw instanceof String name) || !properties.containsKey(name)) {
                throw new IllegalArgumentException("Invalid chat tool required properties");
            }
            required.add(name);
        }
        List<String> optional = properties.keySet().stream().filter(key -> !required.contains(key)).toList();
        List<Map<String, Object>> result = new ArrayList<>();
        for (int mask = 0; mask < (1 << optional.size()); mask++) {
            Map<String, Object> selected = new LinkedHashMap<>();
            required.forEach(key -> selected.put(key, properties.get(key)));
            for (int bit = 0; bit < optional.size(); bit++) {
                if ((mask & (1 << bit)) != 0) selected.put(optional.get(bit), properties.get(optional.get(bit)));
            }
            result.add(object(selected));
        }
        return result;
    }
}
