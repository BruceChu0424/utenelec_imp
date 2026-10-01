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
 * 访客短信签发事实（仅哈希入库）；到期失效，记录永久保留。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "visitor_sms_codes")
public class VisitorSmsCode {

    @Id
    private UUID id = UUID.randomUUID();

    @Column(nullable = false)
    private String phone;

    @Column(name = "code_hash", nullable = false)
    private String codeHash;

    @Column(nullable = false)
    private String scene;   // login / apply

    @Column(name = "attempts", nullable = false)
    private int attempts = 0;

    @Column(name = "expires_at", nullable = false)
    private OffsetDateTime expiresAt;

    @Column(name = "consumed_at")
    private OffsetDateTime consumedAt;

    @Column(name="delivery_result",nullable=false)
    private String deliveryResult="OPEN_OR_UNKNOWN";
    @Column(name="delivery_result_at")
    private OffsetDateTime deliveryResultAt;
    @Column(name="delivery_actor")
    private String deliveryActor;
    @Column(name="delivery_reason")
    private String deliveryReason;

    @Column(name = "created_at", updatable = false)
    private OffsetDateTime createdAt = OffsetDateTime.now();
}
