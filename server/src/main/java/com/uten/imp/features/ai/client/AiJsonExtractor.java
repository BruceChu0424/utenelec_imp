package com.uten.imp.features.ai.client;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiCompletionPort.AiCallException;
import com.uten.imp.application.port.AiCompletionPort.AiErrorCategory;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 从模型回复里取出 JSON 对象: 原样是 JSON 就直接用; 否则去掉 Markdown 代码块;
 * 再不行取第一个配平的顶层 {@code {...}}。取不出或为空一律 INVALID_RESPONSE。
 */
public final class AiJsonExtractor {

    private static final ObjectMapper JSON = new ObjectMapper();
    private static final Pattern FENCE = Pattern.compile("(?s)```(?:json|JSON)?\\s*(.*?)```");

    private AiJsonExtractor() {
    }

    /** 返回规范化(紧凑)的 JSON 对象文本。 */
    public static String extractObject(String content) {
        if (content == null || content.isBlank()) {
            throw new AiCallException(AiErrorCategory.INVALID_RESPONSE, "AI 没有返回内容, 请稍后再试");
        }
        String trimmed = content.trim();
        String parsed = tryObject(trimmed);
        if (parsed != null) {
            return parsed;
        }
        Matcher fence = FENCE.matcher(trimmed);
        while (fence.find()) {
            parsed = tryObject(fence.group(1).trim());
            if (parsed != null) {
                return parsed;
            }
        }
        String balanced = firstBalancedObject(trimmed);
        if (balanced != null) {
            parsed = tryObject(balanced);
            if (parsed != null) {
                return parsed;
            }
        }
        throw new AiCallException(AiErrorCategory.INVALID_RESPONSE, "AI 返回的内容不是有效的 JSON, 请稍后再试");
    }

    private static String tryObject(String text) {
        if (text.isEmpty() || text.charAt(0) != '{') {
            return null;
        }
        try {
            JsonNode node = JSON.readTree(text);
            return node != null && node.isObject() ? JSON.writeValueAsString(node) : null;
        } catch (Exception e) {
            return null;
        }
    }

    /** 第一个配平的顶层对象(跳过字符串里的括号与转义)。 */
    static String firstBalancedObject(String text) {
        int start = text.indexOf('{');
        while (start >= 0) {
            int depth = 0;
            boolean inString = false;
            boolean escaped = false;
            for (int i = start; i < text.length(); i++) {
                char c = text.charAt(i);
                if (inString) {
                    if (escaped) {
                        escaped = false;
                    } else if (c == '\\') {
                        escaped = true;
                    } else if (c == '"') {
                        inString = false;
                    }
                    continue;
                }
                if (c == '"') {
                    inString = true;
                } else if (c == '{') {
                    depth++;
                } else if (c == '}') {
                    depth--;
                    if (depth == 0) {
                        return text.substring(start, i + 1);
                    }
                }
            }
            start = text.indexOf('{', start + 1);
        }
        return null;
    }
}
