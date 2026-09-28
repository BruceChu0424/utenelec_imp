package com.uten.imp.features.ai.provider;

/** 接口协议: 绝大多数服务商兼容 OpenAI Chat Completions, Claude 用 Anthropic Messages。 */
public enum AiProtocol {
    OPENAI_CHAT,
    ANTHROPIC_MESSAGES
}
