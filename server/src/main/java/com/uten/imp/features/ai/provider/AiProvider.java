package com.uten.imp.features.ai.provider;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import jakarta.persistence.Version;
import lombok.Getter;
import lombok.Setter;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * AI 服务商配置(ai_providers, ADR-133)。{@link #secret} 只存 {@code SecretCipher} 密文,
 * 从不出现在任何接口、日志或审计里; 实体的 toString 也不打印它。
 */
@Entity
@Table(name = "ai_providers")
@Getter
@Setter
public class AiProvider {

    @Id
    private UUID id;

    @Column(nullable = false, length = 64)
    private String name;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 32)
    private AiProviderPreset preset;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 16)
    private AiRegion region;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 24)
    private AiProtocol protocol;

    @Column(name = "base_url", nullable = false, length = 512)
    private String baseUrl;

    @Column(nullable = false, length = 128)
    private String model;

    @Column(name = "secret")
    private String secret;

    @Column(name = "api_key_last4", length = 8)
    private String apiKeyLast4;

    @Enumerated(EnumType.STRING)
    @Column(name = "json_mode", nullable = false, length = 16)
    private AiJsonMode jsonMode = AiJsonMode.JSON_OBJECT;

    @Enumerated(EnumType.STRING)
    @Column(name = "thinking_control", nullable = false, length = 24)
    private AiThinkingControl thinkingControl = AiThinkingControl.NONE;

    @Column(name = "send_temperature", nullable = false)
    private boolean sendTemperature = true;

    @Column(name = "supports_vision", nullable = false)
    private boolean supportsVision;

    @Column(name = "max_output_tokens", nullable = false)
    private int maxOutputTokens = 8192;

    @Column(name = "timeout_seconds", nullable = false)
    private int timeoutSeconds = 120;

    @Column(nullable = false)
    private boolean enabled = true;

    @Column(name = "is_default", nullable = false)
    private boolean isDefault;

    @Column(name = "overseas_ack_by")
    private UUID overseasAckBy;

    @Column(name = "overseas_ack_at")
    private OffsetDateTime overseasAckAt;

    @Column(name = "last_test_at")
    private OffsetDateTime lastTestAt;

    @Column(name = "last_test_ok")
    private Boolean lastTestOk;

    @Column(name = "last_test_message", length = 500)
    private String lastTestMessage;

    @Version
    @Column(nullable = false)
    private Long version;

    @Column(name = "created_at", nullable = false, updatable = false)
    private OffsetDateTime createdAt;

    @Column(name = "created_by", updatable = false)
    private UUID createdBy;

    @Column(name = "updated_at", nullable = false)
    private OffsetDateTime updatedAt;

    @Column(name = "updated_by")
    private UUID updatedBy;

    /** 密文的 AAD 上下文(绑定表、列与行 id)。 */
    public static String secretAad(UUID providerId) {
        return "ai_providers|secret|" + providerId;
    }

    @Override
    public String toString() {
        return "AiProvider{id=" + id + ", name=" + name + ", preset=" + preset + ", region=" + region
                + ", protocol=" + protocol + ", model=" + model + ", keyConfigured=" + (secret != null) + "}";
    }
}
