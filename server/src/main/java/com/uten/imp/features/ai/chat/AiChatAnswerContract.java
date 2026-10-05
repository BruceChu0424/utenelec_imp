package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiChatToolPort;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * ADR-150 provider-visible answer shape, built only from currently authorized descriptors: the
 * model answers page/guide/knowledge questions in one call and may instead choose a listed tool or
 * one of the current page's registered actions. This constrains generation, not authority: tool
 * arguments, action arguments, sources and the reply itself are re-validated before use.
 */
public record AiChatAnswerContract(String schemaName, Map<String, Object> schema, String exampleJson) {
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final Map<String, Object> EMPTY_ARGUMENTS = object(Map.of());

    public static AiChatAnswerContract create(List<AiChatToolPort> allowedTools, List<String> sourceIds,
                                              boolean pageSnapshot, boolean pageGuide, boolean knowledge,
                                              List<AiChatPageSnapshot.PageAction> actions) {
        List<String> intents = new ArrayList<>(List.of("CLARIFY", "OUT_OF_SCOPE", "NON_WORK", "UNSUPPORTED"));
        if (pageSnapshot) intents.add("PAGE_STATE");
        if (pageSnapshot || pageGuide) intents.add("PAGE_HELP");
        if (knowledge) intents.add("KNOWLEDGE");
        if (!allowedTools.isEmpty()) intents.add("TOOL");
        if (!actions.isEmpty()) intents.add("ACTION");

        Set<Map<String, Object>> argumentVariants = new LinkedHashSet<>();
        argumentVariants.add(EMPTY_ARGUMENTS);
        for (AiChatToolPort tool : allowedTools) argumentVariants.addAll(strictObjectVariants(tool.parameters(), 0));
        Set<Map<String, Object>> actionVariants = new LinkedHashSet<>();
        actionVariants.add(EMPTY_ARGUMENTS);
        for (var action : actions) actionVariants.addAll(strictObjectVariants(action.params(), 0));

        Map<String, Object> properties = new LinkedHashMap<>();
        // ADR-153: the model restates the question first, so the reply answers that question and not a related one.
        properties.put("focus", Map.of("type", "string"));
        properties.put("intent", strings(intents));
        properties.put("reply", Map.of("type", "string"));
        properties.put("usedSources", Map.of("type", "array", "items", strings(sourceIds.isEmpty()
                ? List.of("none") : sourceIds)));
        properties.put("tool", strings(withEmpty(allowedTools.stream().map(AiChatToolPort::name).toList())));
        properties.put("arguments", Map.of("anyOf", List.copyOf(argumentVariants)));
        Map<String, Object> action = new LinkedHashMap<>();
        action.put("name", strings(withEmpty(actions.stream().map(AiChatPageSnapshot.PageAction::name).toList())));
        action.put("args", Map.of("anyOf", List.copyOf(actionVariants)));
        properties.put("action", object(action));

        Map<String, Object> example = new LinkedHashMap<>();
        example.put("focus", "用户问的是……");
        example.put("intent", pageSnapshot ? "PAGE_STATE" : knowledge ? "KNOWLEDGE" : "CLARIFY");
        example.put("reply", "直接回答。\n1. 依据一\n2. 依据二");
        example.put("usedSources", sourceIds.isEmpty() ? List.of() : List.of(sourceIds.getFirst()));
        example.put("tool", "");
        example.put("arguments", Map.of());
        example.put("action", Map.of("name", "", "args", Map.of()));
        return new AiChatAnswerContract("erp_chat_answer_v1", object(properties), write(example));
    }

    /** Second call after a tool ran: compose the answer from the tool's model-safe facts only. */
    public static AiChatAnswerContract toolAnswer(List<String> sourceIds) {
        Map<String, Object> properties = new LinkedHashMap<>();
        properties.put("reply", Map.of("type", "string"));
        properties.put("usedSources", Map.of("type", "array", "items", strings(sourceIds)));
        Map<String, Object> example = new LinkedHashMap<>();
        example.put("reply", "直接回答。\n1. 依据一");
        example.put("usedSources", List.of(sourceIds.getFirst()));
        return new AiChatAnswerContract("erp_chat_tool_answer_v1", object(properties), write(example));
    }

    private static String write(Object value) {
        try { return JSON.writeValueAsString(value); }
        catch (JsonProcessingException impossible) { throw new IllegalStateException("Cannot encode chat contract", impossible); }
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
     * Optional arguments use explicit closed-object variants rather than invented nullable values.
     * Display-only keywords (title, description) are kept; unsupported types fail closed.
     */
    static List<Map<String, Object>> strictObjectVariants(Map<String, Object> source, int depth) {
        if (depth > 4 || source == null || !"object".equals(source.get("type"))
                || !Boolean.FALSE.equals(source.get("additionalProperties"))
                || !(source.get("properties") instanceof Map<?, ?> rawProperties)
                || rawProperties.size() > 8 || !(source.get("required") instanceof List<?> rawRequired)) {
            throw new IllegalArgumentException("Chat arguments require a bounded closed object schema");
        }
        Map<String, Object> properties = new LinkedHashMap<>();
        for (var entry : rawProperties.entrySet()) {
            if (!(entry.getKey() instanceof String key) || !(entry.getValue() instanceof Map<?, ?> value)) {
                throw new IllegalArgumentException("Invalid chat argument property schema");
            }
            Map<String, Object> child = new LinkedHashMap<>();
            value.forEach((name, rule) -> child.put(String.valueOf(name), rule));
            if ("object".equals(child.get("type"))) {
                List<Map<String, Object>> variants = strictObjectVariants(child, depth + 1);
                properties.put(key, variants.size() == 1 ? variants.getFirst() : Map.of("anyOf", variants));
            } else {
                if (!(child.get("type") instanceof String type)
                        || !Set.of("string", "boolean", "integer", "number").contains(type)) {
                    throw new IllegalArgumentException("Unsupported chat argument property type");
                }
                properties.put(key, Map.copyOf(child));
            }
        }
        Set<String> required = new LinkedHashSet<>();
        for (Object raw : rawRequired) {
            if (!(raw instanceof String name) || !properties.containsKey(name)) {
                throw new IllegalArgumentException("Invalid chat argument required properties");
            }
            required.add(name);
        }
        List<String> optional = properties.keySet().stream().filter(key -> !required.contains(key)).toList();
        if (optional.size() > 4) throw new IllegalArgumentException("Too many optional chat arguments");
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
