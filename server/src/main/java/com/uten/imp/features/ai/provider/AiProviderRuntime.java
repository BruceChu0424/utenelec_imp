package com.uten.imp.features.ai.provider;

import java.util.UUID;

/**
 * 一次调用所需的服务商运行配置(已解密密钥)。只在内存里短暂存在, 不落库、不序列化、不打印:
 * {@link #toString()} 不输出密钥。
 *
 * @param id       服务商 id; 用未保存的表单做连接测试时为空
 * @param apiKey   明文密钥; 本机部署等不需要密钥时为空
 * @param endpoint 已通过静态规则检查的接口地址(调用前还要按 DNS 结果再查一次)
 */
public record AiProviderRuntime(
        UUID id,
        String name,
        AiProviderPreset preset,
        AiRegion region,
        AiProtocol protocol,
        AiEndpointPolicy.Endpoint endpoint,
        String model,
        String apiKey,
        AiJsonMode jsonMode,
        AiThinkingControl thinkingControl,
        boolean sendTemperature,
        boolean supportsVision,
        int maxOutputTokens,
        int timeoutSeconds) {

    public boolean hasApiKey() {
        return apiKey != null && !apiKey.isEmpty();
    }

    @Override
    public String toString() {
        return "AiProviderRuntime{id=" + id + ", name=" + name + ", preset=" + preset + ", region=" + region
                + ", protocol=" + protocol + ", endpoint=" + (endpoint == null ? null : endpoint.normalized())
                + ", model=" + model + ", apiKey=" + (hasApiKey() ? "***" : "none") + "}";
    }
}
