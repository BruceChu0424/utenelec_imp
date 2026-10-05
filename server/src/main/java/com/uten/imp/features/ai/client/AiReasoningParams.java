package com.uten.imp.features.ai.client;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.application.port.AiCompletionPort.AiReasoningEffort;
import com.uten.imp.features.ai.provider.AiProtocol;
import com.uten.imp.features.ai.provider.AiProviderRuntime;
import com.uten.imp.features.ai.provider.AiThinkingControl;

import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * 思考程度到各服务商请求参数的唯一映射(ADR-152)。协议客户端只调用这里写请求体, 网关用同一张表报告能否调整、
 * 放宽/收紧输出上限与超时、写调用日志, 不会出现「日志说发了、请求体里没有」。
 *
 * <p>「能否调整」({@link #supported}) 是唯一的判定: 写法 + 生效协议 + 模型三者都接受思考程度参数时才算。
 * 不能调整时一律按 {@code DEFAULT} 写请求体(与识别类用途完全相同), 所以账号里存的任何档位都不会让请求被拒。
 *
 * <p>参数依据各家公开文档(2026-10): DeepSeek {@code thinking.type} + {@code reasoning_effort}(low/high/max,
 * 关思考时不能同时带 reasoning_effort); 智谱 {@code thinking.type} + {@code reasoning_effort}(GLM-5.3 只认
 * low/high/max 且不能关思考), Anthropic 兼容端点按 {@code output_config.effort} 定档、忽略 budget_tokens;
 * OpenAI {@code reasoning_effort}(GPT-5 系列在 effort 不是 none 时拒绝 temperature, 见 {@link #allowsTemperature});
 * Claude {@code output_config.effort}(Opus 4.5 及以上、Sonnet 4.6 及以上; Haiku 4.5、Sonnet 4.5、更早的模型带
 * effort 会被拒, 见 {@link #EFFORT_REJECTING_CLAUDE})。通义千问的思考模式只支持流式输出、且不能和 JSON 模式同用,
 * 本平台是非流式 JSON 调用, 所以通义写法只用来关掉思考, 不算「能调整」。
 */
public final class AiReasoningParams {

    private static final ObjectMapper JSON = new ObjectMapper();

    /**
     * 不接受 {@code output_config.effort} 的 Claude 模型(带上就 400): Claude 3 全系、Haiku 4.x、Sonnet 4 / 4.5、
     * Opus 4 / 4.1。也匹配云厂商前缀(如 {@code anthropic.claude-haiku-4-5})。名单之外的新模型按支持处理,
     * 由连接测试的「思考程度」一步实测兜底。
     */
    static final Pattern EFFORT_REJECTING_CLAUDE = Pattern.compile(
            "(?:^|[./:@])claude-(?:3|haiku-4|sonnet-4-5|sonnet-4(?:-\\d{8})?(?![0-9-])|opus-4-1"
                    + "|opus-4(?:-\\d{8})?(?![0-9-]))");

    private AiReasoningParams() {
    }

    /** 这个服务商配置(写法 + 生效协议 + 模型)能否按思考程度调整。 */
    public static boolean supported(AiProviderRuntime runtime) {
        AiThinkingControl control = runtime.thinkingControl();
        if (!control.supportsEffort(runtime.protocol())) {
            return false;
        }
        if (control == AiThinkingControl.ANTHROPIC_EFFORT) {
            String model = runtime.model() == null ? "" : runtime.model().toLowerCase(Locale.ROOT);
            return !EFFORT_REJECTING_CLAUDE.matcher(model).find();
        }
        return true;
    }

    /** 这次调用实际会不会写思考参数(配置能调整且调用方明确要求了某一档)。 */
    public static boolean adjustable(AiProviderRuntime runtime, AiReasoningEffort effort) {
        return effort != null && effort.explicit() && supported(runtime);
    }

    /** 实际生效的档位: 不能调整时退回 DEFAULT(请求体与识别类用途一致)。 */
    static AiReasoningEffort effective(AiProviderRuntime runtime, AiReasoningEffort effort) {
        return adjustable(runtime, effort) ? effort : AiReasoningEffort.DEFAULT;
    }

    /** OpenAI 兼容协议的请求体字段(顶层)。 */
    static Map<String, Object> openAi(AiProviderRuntime runtime, AiReasoningEffort effort) {
        return openAi(runtime.thinkingControl(), effective(runtime, effort));
    }

    private static Map<String, Object> openAi(AiThinkingControl control, AiReasoningEffort level) {
        Map<String, Object> fields = new LinkedHashMap<>();
        switch (control) {
            case DEEPSEEK -> {
                if (level == AiReasoningEffort.DEFAULT || level == AiReasoningEffort.OFF) {
                    fields.put("thinking", Map.of("type", "disabled"));
                } else {
                    fields.put("thinking", Map.of("type", "enabled"));
                    fields.put("reasoning_effort", switch (level) {
                        case LOW -> "low";
                        case MEDIUM -> "high";
                        default -> "max";
                    });
                }
            }
            // 非流式 JSON 调用里通义只能关掉思考(见类说明), 任何档位都一样。
            case DASHSCOPE -> fields.put("enable_thinking", false);
            case OPENAI_REASONING -> fields.put("reasoning_effort", openAiEffort(level));
            case ZHIPU -> {
                if (level.explicit()) {
                    fields.put("thinking", Map.of("type", "enabled"));
                    fields.put("reasoning_effort", zhipuEffort(level));
                }
            }
            case NONE, ANTHROPIC_EFFORT -> {
            }
        }
        return fields;
    }

    private static String openAiEffort(AiReasoningEffort level) {
        return switch (level) {
            case DEFAULT, OFF -> "none";
            case LOW -> "low";
            case MEDIUM -> "medium";
            case HIGH -> "high";
        };
    }

    /** Anthropic Messages 协议的 {@code output_config.effort}; 不发时为 null。 */
    static String anthropicEffort(AiProviderRuntime runtime, AiReasoningEffort effort) {
        AiReasoningEffort level = effective(runtime, effort);
        if (!level.explicit()) {
            return null;
        }
        return switch (runtime.thinkingControl()) {
            case ZHIPU -> zhipuEffort(level);
            case ANTHROPIC_EFFORT -> switch (level) {
                case MEDIUM -> "medium";
                case HIGH -> "high";
                default -> "low";
            };
            default -> null;
        };
    }

    /** GLM-5.3 只认 low/high/max: 不思考/轻 = low, 标准 = high, 深入 = max。 */
    private static String zhipuEffort(AiReasoningEffort level) {
        return switch (level) {
            case MEDIUM -> "high";
            case HIGH -> "max";
            default -> "low";
        };
    }

    /**
     * 这次请求能否带 {@code temperature}(管理员打开了「固定输出」时)。OpenAI 推理模型只有在
     * {@code reasoning_effort=none} 时接受 temperature, 否则 400; DeepSeek 开思考后 temperature 不生效,
     * 也不发。其余写法照管理员的开关。
     */
    public static boolean allowsTemperature(AiProviderRuntime runtime, AiReasoningEffort effort) {
        AiReasoningEffort level = effective(runtime, effort);
        return switch (runtime.thinkingControl()) {
            case OPENAI_REASONING, DEEPSEEK -> level == AiReasoningEffort.DEFAULT || level == AiReasoningEffort.OFF;
            default -> true;
        };
    }

    /** 把 OpenAI 兼容协议的思考字段写进请求体。 */
    static void applyOpenAi(ObjectNode body, AiProviderRuntime runtime, AiReasoningEffort effort) {
        openAi(runtime, effort).forEach((key, value) -> body.set(key, JSON.valueToTree(value)));
    }

    /** 思考额度: 回答上限之外希望多给的输出额度(不调整时为 0)。 */
    public static int thinkingAllowance(AiProviderRuntime runtime, AiReasoningEffort effort) {
        if (!adjustable(runtime, effort)) {
            return 0;
        }
        return switch (effort) {
            case LOW -> 2048;
            case MEDIUM -> 4096;
            case HIGH -> 16384;
            default -> 0;
        };
    }

    /**
     * 本次请求的输出上限: 回答上限 + 思考额度, 但绝不超过管理员给这个服务商配置的「最大输出长度」——
     * 那是单次输出(含思考)的硬上限, 可能就是模型本身的上限, 也是成本上限。想给「深入」更多思考空间,
     * 由管理员调大这个配置。
     */
    public static int maxOutputTokens(AiProviderRuntime runtime, int answerTokens, AiReasoningEffort effort) {
        int cap = Math.max(1, runtime.maxOutputTokens());
        int answer = Math.max(1, Math.min(answerTokens, cap));
        long total = (long) answer + thinkingAllowance(runtime, effort);
        return (int) Math.min(total, cap);
    }

    /**
     * 本次调用的超时秒数: 不思考收紧到 60 秒以内; 深入放宽到配置的 1.5 倍(最多 240 秒, 任务租约在调用期间
     * 自动续); 其余与服务商配置一致。不能调整时不改。
     */
    public static int timeoutSeconds(AiProviderRuntime runtime, AiReasoningEffort effort) {
        int configured = runtime.timeoutSeconds();
        if (!adjustable(runtime, effort)) {
            return configured;
        }
        return switch (effort) {
            case OFF -> Math.min(configured, 60);
            case HIGH -> Math.max(configured, Math.min(configured * 3 / 2, 240));
            default -> configured;
        };
    }

    /** 调用日志里的一句话(只有参数名和档位, 没有业务数据)。 */
    public static String describe(AiProviderRuntime runtime, AiReasoningEffort effort) {
        if (!adjustable(runtime, effort)) {
            return "none";
        }
        if (runtime.protocol() == AiProtocol.ANTHROPIC_MESSAGES) {
            return "output_config.effort=" + anthropicEffort(runtime, effort);
        }
        StringBuilder text = new StringBuilder();
        for (Map.Entry<String, Object> field : openAi(runtime, effort).entrySet()) {
            if (!text.isEmpty()) {
                text.append(", ");
            }
            text.append(field.getKey()).append('=').append(field.getValue());
        }
        return text.toString();
    }
}
