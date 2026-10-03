package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.util.Map;
import java.util.List;
import java.util.ArrayList;
import java.util.LinkedHashMap;

/** Small fail-closed validator for the bounded JSON-Schema subset supported by chat tools. */
final class AiChatArguments {
    private AiChatArguments() {}
    static void validate(JsonNode value, Map<String, Object> schema, ObjectMapper json) {
        if (schema == null || value == null) throw invalid();
        validate(value, json.valueToTree(schema), 0);
    }
    /** Ask for missing required values, while still rejecting forged keys or malformed supplied values. */
    static List<String> missingRequired(JsonNode value, Map<String, Object> schema, ObjectMapper json) {
        if (value == null || !value.isObject() || schema == null || !(schema.get("required") instanceof List<?> required)) throw invalid();
        var missing = new ArrayList<String>();
        var supplied = value.deepCopy();
        for (Object raw : required) {
            if (!(raw instanceof String name)) throw invalid();
            JsonNode field = value.get(name);
            if (field == null || (field.isTextual() && field.asText().isBlank())) {
                missing.add(name);
                ((com.fasterxml.jackson.databind.node.ObjectNode) supplied).remove(name);
            }
        }
        var partial = new LinkedHashMap<>(schema);
        partial.put("required", required.stream().filter(name -> !missing.contains(name)).toList());
        validate(supplied, partial, json);
        return List.copyOf(missing);
    }
    private static void validate(JsonNode value, JsonNode schema, int depth) {
        if (depth > 4 || !schema.isObject() || !schema.path("type").isTextual()) throw invalid();
        String type = schema.path("type").asText();
        switch (type) {
            case "object" -> {
                if (!value.isObject() || value.size() > 8 || !schema.path("additionalProperties").isBoolean()
                        || schema.path("additionalProperties").asBoolean() || !schema.path("properties").isObject()
                        || !schema.path("required").isArray()) throw invalid();
                for (JsonNode required : schema.path("required")) {
                    if (!required.isTextual() || !value.has(required.asText())) throw invalid();
                }
                var names = value.fieldNames();
                while (names.hasNext()) {
                    String name = names.next();
                    if (!schema.path("properties").has(name)) throw invalid();
                    validate(value.get(name), schema.path("properties").get(name), depth + 1);
                }
            }
            case "string" -> {
                if (!value.isTextual()) throw invalid();
                String text = value.asText();
                if (text.length() > Math.min(512, schema.path("maxLength").asInt(512))
                        || text.length() < schema.path("minLength").asInt(0)
                        || text.codePoints().anyMatch(Character::isISOControl)) throw invalid();
                if (schema.has("pattern") && !text.matches(schema.path("pattern").asText())) throw invalid();
            }
            case "boolean" -> { if (!value.isBoolean()) throw invalid(); }
            case "integer", "number" -> {
                if (!value.isNumber() || ("integer".equals(type) && !value.isIntegralNumber())) throw invalid();
                if (schema.has("minimum") && value.decimalValue().compareTo(schema.get("minimum").decimalValue()) < 0) throw invalid();
                if (schema.has("maximum") && value.decimalValue().compareTo(schema.get("maximum").decimalValue()) > 0) throw invalid();
            }
            default -> throw invalid();
        }
        if (schema.has("enum")) {
            if (!schema.get("enum").isArray()) throw invalid();
            boolean found = false;
            for (JsonNode option : schema.get("enum")) if (option.equals(value)) found = true;
            if (!found) throw invalid();
        }
    }
    private static ApiException invalid() {
        return new ApiException(ErrorCode.VALIDATION_FAILED, "请补充要查询的内容，或换个说法再试。");
    }
}
