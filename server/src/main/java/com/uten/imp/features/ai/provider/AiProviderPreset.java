package com.uten.imp.features.ai.provider;

import java.util.List;
import java.util.Locale;
import java.util.Optional;

/**
 * 服务商预设(ADR-133): 选择后预填接口地址、模型与能力开关, 每一项都可以再改。
 *
 * <p>{@link #registeredDomains()} 是这个预设登记的域名后缀(见《中国大陆部署与兼容性》的外部服务登记);
 * 非空时接口地址的主机必须等于登记域名或是它的子域名, 否则请选「自定义」并自己声明区域 —— 防止把境外地址挂在
 * 境内预设下绕过出境开关。登记要尽量窄: 同一家云的境外节点常常与境内共用上级域名(例如阿里云百炼国际版
 * {@code dashscope-intl.aliyuncs.com} 与境内 {@code dashscope.aliyuncs.com} 同在 {@code aliyuncs.com} 下),
 * 所以通义只登记 {@code dashscope.aliyuncs.com} 与北京业务空间域名 {@code <空间>.cn-beijing.maas.aliyuncs.com},
 * 不登记 {@code aliyuncs.com} 或 {@code maas.aliyuncs.com}(新加坡等境外业务空间也在其下)。本机部署与自定义不限域名。
 */
public enum AiProviderPreset {

    DEEPSEEK("DeepSeek", AiRegion.MAINLAND, AiProtocol.OPENAI_CHAT, "https://api.deepseek.com",
            List.of("deepseek-flash", "deepseek-v4-pro"), AiJsonMode.JSON_OBJECT, AiThinkingControl.DEEPSEEK,
            true, true, true, List.of("deepseek.com")),
    DASHSCOPE("通义千问(阿里云百炼)", AiRegion.MAINLAND, AiProtocol.OPENAI_CHAT,
            "https://dashscope.aliyuncs.com/compatible-mode/v1",
            List.of("qwen3.8-flash", "qwen3.8-max"), AiJsonMode.JSON_OBJECT, AiThinkingControl.DASHSCOPE,
            true, false, true, List.of("dashscope.aliyuncs.com", "cn-beijing.maas.aliyuncs.com")),
    MOONSHOT("Kimi(月之暗面)", AiRegion.MAINLAND, AiProtocol.OPENAI_CHAT, "https://api.moonshot.cn/v1",
            List.of("kimi-k2.6"), AiJsonMode.JSON_OBJECT, AiThinkingControl.NONE,
            true, false, true, List.of("moonshot.cn")),
    ZHIPU("智谱 GLM", AiRegion.MAINLAND, AiProtocol.OPENAI_CHAT, "https://open.bigmodel.cn/api/paas/v4",
            List.of("glm-5.3-flash", "glm-5.3"), AiJsonMode.JSON_OBJECT, AiThinkingControl.NONE,
            true, false, true, List.of("bigmodel.cn")),
    VOLCENGINE("火山方舟(豆包)", AiRegion.MAINLAND, AiProtocol.OPENAI_CHAT,
            "https://ark.cn-beijing.volces.com/api/v3",
            List.of(), AiJsonMode.JSON_OBJECT, AiThinkingControl.NONE,
            true, false, true, List.of("volces.com")),
    SILICONFLOW("硅基流动", AiRegion.MAINLAND, AiProtocol.OPENAI_CHAT, "https://api.siliconflow.cn/v1",
            List.of(), AiJsonMode.JSON_OBJECT, AiThinkingControl.NONE,
            true, false, true, List.of("siliconflow.cn")),
    OPENAI("OpenAI", AiRegion.OVERSEAS, AiProtocol.OPENAI_CHAT, "https://api.openai.com/v1",
            List.of("gpt-5.6-luna"), AiJsonMode.JSON_SCHEMA, AiThinkingControl.OPENAI_REASONING,
            true, true, true, List.of("openai.com")),
    ANTHROPIC("Claude(Anthropic)", AiRegion.OVERSEAS, AiProtocol.ANTHROPIC_MESSAGES, "https://api.anthropic.com",
            List.of("claude-sonnet-5", "claude-haiku-4-5-20251001"), AiJsonMode.JSON_SCHEMA, AiThinkingControl.NONE,
            false, true, true, List.of("anthropic.com")),
    GEMINI("Gemini(OpenAI 兼容)", AiRegion.OVERSEAS, AiProtocol.OPENAI_CHAT,
            "https://generativelanguage.googleapis.com/v1beta/openai",
            List.of("gemini-3.8-flash"), AiJsonMode.JSON_OBJECT, AiThinkingControl.NONE,
            true, true, true, List.of("googleapis.com")),
    OLLAMA("本地部署(Ollama)", AiRegion.LOCAL, AiProtocol.OPENAI_CHAT, "http://127.0.0.1:11434/v1",
            List.of(), AiJsonMode.JSON_OBJECT, AiThinkingControl.NONE,
            true, false, false, List.of()),
    VLLM("本地部署(vLLM)", AiRegion.LOCAL, AiProtocol.OPENAI_CHAT, "http://127.0.0.1:8000/v1",
            List.of(), AiJsonMode.JSON_OBJECT, AiThinkingControl.NONE,
            true, false, false, List.of()),
    CUSTOM("自定义(OpenAI 兼容)", null, AiProtocol.OPENAI_CHAT, "",
            List.of(), AiJsonMode.JSON_OBJECT, AiThinkingControl.NONE,
            true, false, true, List.of());

    private final String label;
    private final AiRegion region;
    private final AiProtocol protocol;
    private final String defaultBaseUrl;
    private final List<String> suggestedModels;
    private final AiJsonMode jsonMode;
    private final AiThinkingControl thinkingControl;
    private final boolean sendTemperature;
    private final boolean supportsVision;
    private final boolean requiresApiKey;
    private final List<String> registeredDomains;

    AiProviderPreset(String label, AiRegion region, AiProtocol protocol, String defaultBaseUrl,
                     List<String> suggestedModels, AiJsonMode jsonMode, AiThinkingControl thinkingControl,
                     boolean sendTemperature, boolean supportsVision, boolean requiresApiKey,
                     List<String> registeredDomains) {
        this.label = label;
        this.region = region;
        this.protocol = protocol;
        this.defaultBaseUrl = defaultBaseUrl;
        this.suggestedModels = suggestedModels;
        this.jsonMode = jsonMode;
        this.thinkingControl = thinkingControl;
        this.sendTemperature = sendTemperature;
        this.supportsVision = supportsVision;
        this.requiresApiKey = requiresApiKey;
        this.registeredDomains = registeredDomains;
    }

    public static Optional<AiProviderPreset> parse(String value) {
        if (value == null) {
            return Optional.empty();
        }
        try {
            return Optional.of(valueOf(value.trim().toUpperCase(Locale.ROOT)));
        } catch (IllegalArgumentException e) {
            return Optional.empty();
        }
    }

    public String label() {
        return label;
    }

    /** 固定区域; 自定义由管理员选择, 返回空。 */
    public AiRegion region() {
        return region;
    }

    public AiProtocol protocol() {
        return protocol;
    }

    public String defaultBaseUrl() {
        return defaultBaseUrl;
    }

    public List<String> suggestedModels() {
        return suggestedModels;
    }

    public AiJsonMode jsonMode() {
        return jsonMode;
    }

    public AiThinkingControl thinkingControl() {
        return thinkingControl;
    }

    public boolean sendTemperature() {
        return sendTemperature;
    }

    public boolean supportsVision() {
        return supportsVision;
    }

    public List<String> registeredDomains() {
        return registeredDomains;
    }

    /** 这个预设在给定区域下是否必须填写密钥(自定义选本机部署时可以不填)。 */
    public boolean requiresApiKey(AiRegion effectiveRegion) {
        if (this == CUSTOM) {
            return effectiveRegion != AiRegion.LOCAL;
        }
        return requiresApiKey;
    }

    /** 主机是否落在登记域名内(没有登记域名的预设不限)。 */
    public boolean acceptsHost(String host) {
        if (registeredDomains.isEmpty()) {
            return true;
        }
        if (host == null) {
            return false;
        }
        String normalized = host.toLowerCase(Locale.ROOT);
        for (String domain : registeredDomains) {
            if (normalized.equals(domain) || normalized.endsWith("." + domain)) {
                return true;
            }
        }
        return false;
    }
}
