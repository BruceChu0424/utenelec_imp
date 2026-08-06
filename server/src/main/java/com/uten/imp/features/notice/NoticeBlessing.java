package com.uten.imp.features.notice;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.util.UUID;

/**
 * 通知祝福（一人一条；UNIQUE(notice_id, user_id) 保证 upsert 语义——重复祝福算作编辑）。
 * 审计字段（id/createdAt/updatedAt/createdBy/updatedBy）由 {@link BaseEntity} 提供。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "notice_blessings")
public class NoticeBlessing extends BaseEntity {

    @Column(name = "notice_id", nullable = false)
    private UUID noticeId;

    @Column(name = "user_id", nullable = false)
    private UUID userId;

    /** 祝福人姓名快照（发布后改名不回溯，与 notices.publisher 同策略）。 */
    @Column(name = "sender_name", nullable = false, length = 100)
    private String senderName;

    @Column(nullable = false, columnDefinition = "text")
    private String content;
}
