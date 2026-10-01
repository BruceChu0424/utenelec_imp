package com.uten.imp.features.ai.provider;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/**
 * AI 服务设置接口的请求与响应(ADR-133)。密钥只写不读: 请求里可以带新密钥, 任何响应都只有
 * 「是否已配置 / 尾号掩码 / 能否解密」。
 */
public final class AiProviderDtos {

    private AiProviderDtos() {
    }
    public record ProviderHistoryView(@com.fasterxml.jackson.annotation.JsonUnwrapped ProviderView document,
            boolean deleted,OffsetDateTime deletedAt,UUID deletedBy,String deletedByName,String deletedReason,
            boolean historyReadOnly,List<ProviderRevision> revisions,Long nextCursor){}
    /** Historical public config is a whitelist: never the encrypted secret or plaintext key. */
    public record ProviderRevision(long id,OffsetDateTime recordedAt,UUID actorId,String operation,
            java.util.Map<String,Object> configuration,boolean historyReadOnly){}

    /** 服务商列表项。 */
    public record ProviderView(
            UUID id,
            String name,
            String preset,
            String presetLabel,
            String region,
            String protocol,
            String baseUrl,
            String model,
            boolean apiKeyConfigured,
            String apiKeyMasked,
            boolean apiKeyUnreadable,
            String jsonMode,
            String thinkingControl,
            boolean sendTemperature,
            boolean supportsVision,
            int maxOutputTokens,
            int timeoutSeconds,
            boolean enabled,
            @JsonProperty("isDefault") boolean isDefault,
            boolean overseasAcknowledged,
            OffsetDateTime lastTestAt,
            Boolean lastTestOk,
            String lastTestMessage,
            long version,
            OffsetDateTime updatedAt,
            String updatedByName) {
    }

    /**
     * 新建/修改请求。修改时 {@code apiKey} 为空表示保留原密钥, {@code clearApiKey=true} 表示清除;
     * 改了接口协议或接口地址时必须同时给新密钥或清除密钥(已保存的密钥只会发往保存时的地址)。
     */
    public record ProviderRequest(
            String name,
            String preset,
            String region,
            String protocol,
            String baseUrl,
            String model,
            String apiKey,
            Boolean clearApiKey,
            String jsonMode,
            String thinkingControl,
            Boolean sendTemperature,
            Boolean supportsVision,
            Integer maxOutputTokens,
            Integer timeoutSeconds,
            Boolean enabled,
            Boolean overseasAcknowledged,
            Long version) {

        @Override
        public String toString() {
            return "ProviderRequest{name=" + name + ", preset=" + preset + ", baseUrl=" + baseUrl
                    + ", model=" + model + ", apiKey=" + (apiKey == null || apiKey.isEmpty() ? "none" : "***") + "}";
        }
    }

    /** 启用/停用。 */
    public record EnabledRequest(Boolean enabled, Long version) {
    }

    /** 设为默认/删除时可带版本号防覆盖。 */
    public record VersionRequest(Long version) {
    }

    /**
     * 用本次填写的密钥测试(或获取模型列表), 不读取也不保存任何已存配置。
     */
    public record ProbeRequest(
            String preset,
            String region,
            String protocol,
            String baseUrl,
            String model,
            String apiKey,
            String jsonMode,
            String thinkingControl,
            Boolean sendTemperature,
            Integer timeoutSeconds,
            Boolean overseasAcknowledged) {

        @Override
        public String toString() {
            return "ProbeRequest{preset=" + preset + ", baseUrl=" + baseUrl + ", model=" + model
                    + ", apiKey=" + (apiKey == null || apiKey.isEmpty() ? "none" : "***") + "}";
        }
    }

    /**
     * 用已保存的密钥测试时, 页面可以带上当前表单的协议/地址/模型: 与已保存的不一致即 422
     * (改了地址就必须重新填密钥), 保证已保存的密钥只发往保存时的地址。
     */
    public record StoredProbeRequest(String protocol, String baseUrl, String model) {
    }

    /** 连接测试的一步。{@code status}: OK / FAILED / SKIPPED / WARN。 */
    public record TestStep(String key, String status, String message, Long latencyMs) {
    }

    /** 连接测试结果。 */
    public record TestResult(boolean ok, String summary, List<TestStep> steps, OffsetDateTime testedAt) {
    }

    /** 模型列表。{@code message} 在拿不到列表时说明原因(此时可以手填模型名)。 */
    public record ModelsResult(List<String> models, String message) {
    }

    /** 预设。 */
    public record PresetView(
            String key,
            String label,
            String region,
            String protocol,
            String defaultBaseUrl,
            List<String> suggestedModels,
            String jsonMode,
            String thinkingControl,
            boolean sendTemperature,
            boolean supportsVision,
            boolean requiresApiKey,
            List<String> registeredDomains,
            boolean selectable,
            String unavailableReason) {
    }

    /** 预设 + 服务端开关(页面据此禁用境外预设并说明原因)。 */
    public record PresetsView(
            List<PresetView> presets,
            boolean allowOverseas,
            boolean allowLanHttp,
            boolean outboundEnabled,
            String overseasNotice) {
    }

    /** 近 N 天用量(按服务商)。 */
    public record UsageRow(
            UUID providerId,
            String providerName,
            long calls,
            long okCalls,
            long inputTokens,
            long outputTokens,
            long averageLatencyMs) {
    }

    /** 近 N 天用量汇总 + 今日 token 与每日额度。 */
    public record UsageView(
            int days,
            List<UsageRow> providers,
            UsageRow total,
            long todayTokens,
            long dailyTokenBudget) {
    }
}
