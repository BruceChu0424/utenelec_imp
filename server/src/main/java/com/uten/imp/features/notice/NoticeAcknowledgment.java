package com.uten.imp.features.notice;

import jakarta.persistence.Column;
import jakarta.persistence.EmbeddedId;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.Instant;

/**
 * 通知回执（一人一条仅一次）。主键 (notice_id, user_id) 保证幂等：重复 acknowledge 只刷新 acked_at。
 * 回执保留「我已收到」的显式记录，同时将 {@link NoticeUserState} 标记已读；已读本身不代行回执。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "notice_acknowledgments")
public class NoticeAcknowledgment {

    @EmbeddedId
    private NoticeAcknowledgmentId id;

    @Column(name = "acked_at", nullable = false)
    private Instant ackedAt;
}
