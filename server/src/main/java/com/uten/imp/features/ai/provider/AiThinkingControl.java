package com.uten.imp.features.ai.provider;

/**
 * 关闭「深度思考」的方式(识别客户文件不需要推理, 关掉更快更省):
 * DeepSeek 用 {@code thinking: {type: disabled}}, 通义用 {@code enable_thinking: false},
 * OpenAI 用 {@code reasoning_effort: none}; NONE 表示不发任何思考参数。
 */
public enum AiThinkingControl {
    NONE,
    DEEPSEEK,
    DASHSCOPE,
    OPENAI_REASONING
}
