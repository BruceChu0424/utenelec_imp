package com.uten.imp.features.visitor;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.OffsetDateTime;

/**
 * 访客账号（手机号验证码注册，独立于员工 users）。
 * phone_enc 走 pgcrypto；phone_hash（HMAC）用于登录/查重。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "visitor_accounts")
public class VisitorAccount extends BaseEntity {

    @Column(name = "phone_enc", nullable = false)
    private String phoneEnc;

    @Column(name = "phone_hash", nullable = false, unique = true)
    private String phoneHash;

    @Column(name = "name", nullable = false)
    private String name;

    @Column(name = "visitor_no", nullable = false, unique = true)
    private String visitorNo;

    @Column(name = "avatar_seed")
    private String avatarSeed;

    @Column(nullable = false)
    private String status = "active";   // active / blocked

    @Column(name = "last_login_at")
    private OffsetDateTime lastLoginAt;
}
