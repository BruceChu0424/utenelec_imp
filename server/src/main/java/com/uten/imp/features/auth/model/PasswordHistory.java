package com.uten.imp.features.auth.model;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.OffsetDateTime;
import java.util.UUID;

/** 密码历史（改密时防重用最近 N 条）。 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "password_history")
public class PasswordHistory {

    @Id
    private UUID id = UUID.randomUUID();

    @Column(name = "user_id", nullable = false)
    private UUID userId;

    @Column(name = "password_hash", nullable = false)
    private String passwordHash;

    @Column(name = "changed_at")
    private OffsetDateTime changedAt = OffsetDateTime.now();
}
