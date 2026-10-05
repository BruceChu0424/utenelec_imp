package com.uten.imp.features.ai.client;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiCompletionPort.AiCallException;
import com.uten.imp.application.port.AiCompletionPort.AiErrorCategory;

import java.nio.charset.StandardCharsets;
import java.util.regex.Pattern;

/**
 * 把服务商的 HTTP 状态翻成给人看的中文(ADR-133)。只会带出服务商错误 JSON 里的 message 字段,
 * 清洗控制字符、抹掉密钥样子的串、截到 120 字; 从不回显整个响应体。
 */
public final class AiErrorMapper {

    static final int MAX_PROVIDER_MESSAGE = 120;

    private static final ObjectMapper JSON = new ObjectMapper();
    private static final Pattern KEY_LIKE = Pattern.compile(
            "(?i)\\b(?:sk|ak|key|api[-_]?key|bearer)[-_ :=]*[A-Za-z0-9_\\-.]{8,}");
    private static final Pattern LONG_TOKEN = Pattern.compile("[A-Za-z0-9_\\-]{24,}");

    private AiErrorMapper() {
    }

    /** 非 2xx 响应 → 异常。 */
    public static AiCallException fromStatus(int status, byte[] body, String apiKey) {
        if (status >= 300 && status < 400) {
            return new AiCallException(AiErrorCategory.NETWORK,
                    "服务商返回了跳转, 请填写最终接口地址", status);
        }
        return switch (status) {
            case 401, 403 -> new AiCallException(AiErrorCategory.AUTH,
                    "密钥无效或没有权限(也可能是账号所在区域不匹配)", status);
            case 404 -> new AiCallException(AiErrorCategory.NOT_FOUND, "接口地址或模型名称不对", status);
            case 400, 422 -> {
                if (contentFiltered(body)) {
                    yield AiCallException.contentFiltered(status);
                }
                String message = providerMessage(body, apiKey);
                yield new AiCallException(AiErrorCategory.BAD_REQUEST,
                        message.isEmpty() ? "服务商不接受这个请求" : "服务商不接受这个请求: " + message, status);
            }
            case 402 -> new AiCallException(AiErrorCategory.QUOTA, "服务商账户余额不足", status);
            case 429 -> new AiCallException(AiErrorCategory.RATE_LIMIT, "调用太频繁或额度不足, 请稍后再试", status);
            default -> status >= 500
                    ? new AiCallException(AiErrorCategory.SERVER, "AI 服务暂时出错(服务商返回 " + status + "), 请稍后再试", status)
                    : new AiCallException(AiErrorCategory.BAD_REQUEST, "服务商返回了无法识别的状态 " + status, status);
        };
    }

    /**
     * 服务商内容审核的拒绝标记(按各家公开文档与实测, 2026-10): 智谱 error.code=1301「不安全或敏感内容」、
     * 通义 data_inspection_failed、DeepSeek「Content Exists Risk」、OpenAI/Azure content_policy_violation /
     * content management policy / content_filter。只看错误码与错误说明, 从不回显。
     */
    private static final Pattern CONTENT_FILTER = Pattern.compile("(?i)\\b1301\\b|content[_\\s-]?filter|data_inspection_failed"
            + "|content\\s+exists\\s+risk|content[_\\s-]?policy|content\\s+management\\s+policy|inappropriate\\s+content"
            + "|safety\\s+system|不安全或敏感|敏感内容|内容安全|违规内容");

    /** 错误体是不是服务商内容审核的拒绝。 */
    static boolean contentFiltered(byte[] body) {
        if (body == null || body.length == 0) {
            return false;
        }
        try {
            JsonNode node = JSON.readTree(new String(body, StandardCharsets.UTF_8));
            if (node == null) {
                return false;
            }
            JsonNode error = node.path("error");
            StringBuilder marks = new StringBuilder();
            for (JsonNode part : java.util.List.of(error.path("code"), error.path("type"), error.path("message"), node.path("code"),
                    node.path("message"), node.path("msg"))) {
                if (part.isValueNode()) {
                    marks.append(part.asText()).append(' ');
                }
            }
            if (error.isTextual()) {
                marks.append(error.asText());
            }
            return CONTENT_FILTER.matcher(marks).find();
        } catch (Exception notJson) {
            return false;
        }
    }

    /** 服务商错误 JSON 里的 message(OpenAI/Anthropic/通义等都放在 error.message 或 message)。 */
    static String providerMessage(byte[] body, String apiKey) {
        if (body == null || body.length == 0) {
            return "";
        }
        String raw = null;
        try {
            JsonNode node = JSON.readTree(new String(body, StandardCharsets.UTF_8));
            if (node != null) {
                JsonNode error = node.path("error");
                if (error.isObject() && error.path("message").isTextual()) {
                    raw = error.path("message").asText();
                } else if (error.isTextual()) {
                    raw = error.asText();
                } else if (node.path("message").isTextual()) {
                    raw = node.path("message").asText();
                }
            }
        } catch (Exception ignored) {
            // 不是 JSON: 不回显任何内容。
        }
        return sanitize(raw, apiKey);
    }

    /** 清洗: 去控制字符、合并空白、抹掉密钥与长令牌、截断。 */
    public static String sanitize(String text, String apiKey) {
        if (text == null) {
            return "";
        }
        String value = text;
        if (apiKey != null && !apiKey.isEmpty()) {
            value = value.replace(apiKey, "***");
        }
        StringBuilder cleaned = new StringBuilder(value.length());
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            cleaned.append(Character.isISOControl(c) ? ' ' : c);
        }
        value = cleaned.toString().replaceAll("\\s+", " ").trim();
        value = KEY_LIKE.matcher(value).replaceAll("***");
        value = LONG_TOKEN.matcher(value).replaceAll("***");
        if (value.length() > MAX_PROVIDER_MESSAGE) {
            value = value.substring(0, MAX_PROVIDER_MESSAGE - 1) + "…";
        }
        return value;
    }
}
