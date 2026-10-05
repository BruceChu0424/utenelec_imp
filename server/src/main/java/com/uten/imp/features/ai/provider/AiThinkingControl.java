package com.uten.imp.features.ai.provider;

/**
 * 服务商的「思考参数写法」(ADR-133 / ADR-152): 网关怎样把与服务商无关的思考程度
 * ({@code AiCompletionPort.AiReasoningEffort}) 写进请求体。
 *
 * <ul>
 *   <li>{@code NONE}: 不发任何思考参数(服务商不支持调整思考程度)。</li>
 *   <li>{@code DEEPSEEK}: {@code thinking: {type}} 开关 + {@code reasoning_effort}(DeepSeek, OpenAI 兼容协议)。</li>
 *   <li>{@code DASHSCOPE}: {@code enable_thinking=false}(通义千问, OpenAI 兼容协议)。通义的思考模式只支持流式输出、
 *       且不能和 JSON 模式同用, 本平台是非流式 JSON 调用, 所以这种写法只用来关掉思考, 不能调整思考程度。</li>
 *   <li>{@code OPENAI_REASONING}: {@code reasoning_effort}(OpenAI, OpenAI 兼容协议)。</li>
 *   <li>{@code ZHIPU}: 智谱 GLM。OpenAI 兼容端点({@code /api/paas/v4})发 {@code thinking} +
 *       {@code reasoning_effort}; Anthropic 兼容端点({@code /api/anthropic})发 {@code output_config.effort}。
 *       GLM-5.3 起思考关不掉, 「不思考」取最轻档 low。</li>
 *   <li>{@code ANTHROPIC_EFFORT}: Anthropic Messages {@code output_config.effort}(Opus 4.5 / Sonnet 4.6 及以上;
 *       Haiku 4.5、Sonnet 4.5 等不认 effort 的模型由 {@code AiReasoningParams.supported} 按模型名自动不发)。</li>
 * </ul>
 *
 * <p>调用方不要求思考程度({@code DEFAULT}, 识别类用途)时保持原有行为: DeepSeek/通义/OpenAI 写法关掉思考
 * (识别客户文件不需要推理, 关掉更快更省), 智谱与 Anthropic 写法不发参数。
 */
public enum AiThinkingControl {
    NONE,
    DEEPSEEK,
    DASHSCOPE,
    OPENAI_REASONING,
    ZHIPU,
    ANTHROPIC_EFFORT;

    /**
     * 在给定(生效)协议下, 这种写法能否表达思考程度。只看写法与协议; 是否真的可调还要看模型,
     * 唯一判定是 {@code AiReasoningParams.supported(runtime)}。
     */
    public boolean supportsEffort(AiProtocol protocol) {
        if (protocol == AiProtocol.ANTHROPIC_MESSAGES) {
            return this == ZHIPU || this == ANTHROPIC_EFFORT;
        }
        return this == DEEPSEEK || this == OPENAI_REASONING || this == ZHIPU;
    }
}
