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
 * 通知的每用户状态（已读/删除）。无记录 = 未读未删。
 * 删除是「从自己列表移除」语义（deleted_at 非空即对该用户隐藏），不影响其他收件人。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "notice_user_states")
public class NoticeUserState {

    @EmbeddedId
    private NoticeUserStateId id;

    @Column(name = "read_at")
    private Instant readAt;

    @Column(name = "deleted_at")
    private Instant deletedAt;
}
