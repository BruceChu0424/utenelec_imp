package com.uten.imp.features.visitor;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 访客不透明刷新令牌（独立于员工 refresh_tokens）。只存 sha256(原文)；轮换 + 重用检测。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "visitor_refresh_tokens")
public class VisitorRefreshToken {

    @Id
    private UUID id = UUID.randomUUID();

    @Column(name = "visitor_account_id", nullable = false)
    private UUID visitorAccountId;

    @Column(name = "session_id", nullable = false)
    private UUID sessionId;

    @Column(name = "token_hash", nullable = false, unique = true)
    private String tokenHash;

    @Column(name = "device_info")
    private String deviceInfo;

    @Column(name = "issued_at", nullable = false)
    private OffsetDateTime issuedAt = OffsetDateTime.now();

    @Column(name = "expires_at", nullable = false)
    private OffsetDateTime expiresAt;

    @Column(name = "revoked_at")
    private OffsetDateTime revokedAt;

    @Column(name = "replaced_by")
    private UUID replacedBy;

    public boolean isValid() {
        return revokedAt == null && expiresAt != null && expiresAt.isAfter(OffsetDateTime.now());
    }
}
