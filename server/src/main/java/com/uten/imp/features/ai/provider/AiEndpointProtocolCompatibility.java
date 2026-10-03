package com.uten.imp.features.ai.provider;

/** Exact known-vendor paths only; custom providers and unknown reverse-proxy paths remain configurable. */
final class AiEndpointProtocolCompatibility {
    private AiEndpointProtocolCompatibility() {}

    static String mismatch(AiProviderPreset preset, AiProtocol protocol, AiEndpointPolicy.Endpoint endpoint) {
        AiProtocol effective = effectiveProtocol(preset, protocol, endpoint);
        if (effective == protocol) return null;
        String path = endpoint.path();
        if (("/api/anthropic".equals(path) || "/api/anthropic/v1".equals(path))
                && protocol != AiProtocol.ANTHROPIC_MESSAGES) {
            return "智谱 /api/anthropic 地址需要选择 Anthropic Messages 协议；"
                    + "如使用 OpenAI 兼容协议，请填写 /api/paas/v4 接口地址。请核对后保存，不会自动修改配置";
        }
        if ("/api/paas/v4".equals(path) && protocol != AiProtocol.OPENAI_CHAT) {
            return "智谱 /api/paas/v4 地址需要选择 OpenAI 兼容协议；"
                    + "如使用 Anthropic Messages 协议，请填写 /api/anthropic 接口地址。请核对后保存，不会自动修改配置";
        }
        return null;
    }

    /** In-memory legacy bridge: never changes a hostname, base path, credential or persisted setting. */
    static AiProtocol effectiveProtocol(AiProviderPreset preset, AiProtocol configured, AiEndpointPolicy.Endpoint endpoint) {
        if (preset != AiProviderPreset.ZHIPU || endpoint == null || !"open.bigmodel.cn".equals(endpoint.host())) return configured;
        return switch (endpoint.path()) {
            case "/api/anthropic", "/api/anthropic/v1" -> AiProtocol.ANTHROPIC_MESSAGES;
            case "/api/paas/v4" -> AiProtocol.OPENAI_CHAT;
            default -> configured;
        };
    }
}
