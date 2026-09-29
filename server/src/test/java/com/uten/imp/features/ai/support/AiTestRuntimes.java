package com.uten.imp.features.ai.support;

import com.uten.imp.features.ai.provider.AiEndpointPolicy;
import com.uten.imp.features.ai.provider.AiJsonMode;
import com.uten.imp.features.ai.provider.AiProtocol;
import com.uten.imp.features.ai.provider.AiProviderPreset;
import com.uten.imp.features.ai.provider.AiProviderRuntime;
import com.uten.imp.features.ai.provider.AiRegion;
import com.uten.imp.features.ai.provider.AiThinkingControl;

import java.util.UUID;

/** 指向 {@link FakeAiProviderServer} 的运行配置(本机部署 + 字面回环 http, 符合防 SSRF 规则)。 */
public final class AiTestRuntimes {

    private AiTestRuntimes() {
    }

    public static AiProviderRuntime openAi(FakeAiProviderServer fake, String apiKey) {
        return openAi(fake, apiKey, AiJsonMode.JSON_OBJECT, AiThinkingControl.DEEPSEEK, true, 30);
    }

    public static AiProviderRuntime openAi(FakeAiProviderServer fake, String apiKey, AiJsonMode jsonMode,
                                           AiThinkingControl thinking, boolean temperature, int timeoutSeconds) {
        return new AiProviderRuntime(UUID.randomUUID(), "假服务商", AiProviderPreset.CUSTOM, AiRegion.LOCAL,
                AiProtocol.OPENAI_CHAT, AiEndpointPolicy.parse(fake.openAiBaseUrl()), "fake-model", apiKey,
                jsonMode, thinking, temperature, true, 4096, timeoutSeconds);
    }

    public static AiProviderRuntime anthropic(FakeAiProviderServer fake, String apiKey, AiJsonMode jsonMode,
                                              boolean temperature) {
        return new AiProviderRuntime(UUID.randomUUID(), "假 Claude", AiProviderPreset.CUSTOM, AiRegion.LOCAL,
                AiProtocol.ANTHROPIC_MESSAGES, AiEndpointPolicy.parse(fake.anthropicBaseUrl()), "fake-claude",
                apiKey, jsonMode, AiThinkingControl.NONE, temperature, true, 4096, 30);
    }
}
