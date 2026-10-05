-- V806 (ADR-152, AI 轨道临时号, 集成时由编排者改号): AI 对话「思考程度」设置需要服务商能表达思考深度。
-- ai_providers.thinking_control 从「关闭深度思考的写法」扩展为「思考参数写法」:
--   ZHIPU            智谱 GLM(OpenAI 兼容端点 thinking + reasoning_effort; Anthropic 兼容端点 output_config.effort)
--   ANTHROPIC_EFFORT Anthropic Messages output_config.effort(Claude 4.6 及以上)
-- 已有的智谱配置原来是 NONE(当时没有可用写法), 改成 ZHIPU; 识别类调用不要求思考程度时仍不发思考参数,
-- 行为不变(见 AiReasoningParams)。其它服务商的配置不动(Claude 的 Haiku 4.5 等不认 effort, 由管理员自选)。
ALTER TABLE ai_providers DROP CONSTRAINT ai_providers_thinking_control_check;
ALTER TABLE ai_providers ADD CONSTRAINT ai_providers_thinking_control_check
    CHECK (thinking_control IN ('NONE', 'DEEPSEEK', 'DASHSCOPE', 'OPENAI_REASONING', 'ZHIPU', 'ANTHROPIC_EFFORT'));
COMMENT ON COLUMN ai_providers.thinking_control IS
    '思考参数写法(ADR-152): NONE 不发; DEEPSEEK/ZHIPU thinking+reasoning_effort; DASHSCOPE enable_thinking+thinking_budget; OPENAI_REASONING reasoning_effort; ANTHROPIC_EFFORT output_config.effort。调用方不要求思考程度时保持原行为';

UPDATE ai_providers
SET thinking_control = 'ZHIPU', version = version + 1, updated_at = now()
WHERE preset = 'ZHIPU' AND thinking_control = 'NONE';
