package com.uten.imp.features.notice;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.IdClass;
import jakarta.persistence.Table;
import lombok.AllArgsConstructor;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.Instant;
import java.util.UUID;

/**
 * 个人通知弹窗开关（V833/ADR-171）：存在行 = 该用户已关闭该 source_event 的弹窗提醒。
 * 只抑制「弹窗」（居中行动卡与顶部到达条）；通知仍落库并在通知中心可见。
 */
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Entity
@IdClass(NoticePopupPreferenceId.class)
@Table(name = "notice_popup_preferences")
public class NoticePopupPreference {

    @Id
    @Column(name = "user_id", nullable = false)
    private UUID userId;

    @Id
    @Column(name = "source_event", nullable = false)
    private String sourceEvent;

    @Column(name = "disabled_at", nullable = false)
    private Instant disabledAt = Instant.now();
}
