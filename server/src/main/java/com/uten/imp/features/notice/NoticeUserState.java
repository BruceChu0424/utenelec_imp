package com.uten.imp.features.notice;

import jakarta.persistence.Column;
import jakarta.persistence.EmbeddedId;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;
import org.hibernate.annotations.DynamicUpdate;

import java.time.Instant;

/**
 * 通知的每用户状态（已读/强提醒确认/删除/待办完成）。
 * 无记录 = 未读、未确认强提醒、未删且待办未完成。
 * 删除是「从自己列表移除」语义（deleted_at 非空即对该用户隐藏），不影响其他收件人。
 *
 * <p>{@code @DynamicUpdate}（2026-09-10）：UPDATE 只写被改动的列。弹窗「稍后再看」
 * （置 snoozed_until）与「去工作台处理」/已读（置 read_at + popup_acknowledged_at）
 * 可能并发落到同一行；全列 UPDATE 会用各自加载时的旧值互相覆盖（如 markRead 把刚写的
 * snoozed_until 冲回 NULL），按列写入则两者互不覆盖，无需新增版本列。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@DynamicUpdate
@Table(name = "notice_user_states")
public class NoticeUserState {

    @EmbeddedId
    private NoticeUserStateId id;

    @Column(name = "read_at")
    private Instant readAt;

    /**
     * 弹窗确认时间：登录待办弹窗的静默依据（2026-09-10 口径：已确认且未办结的
     * 待办登录不再弹，但「稍后再看」到期例外）。markRead / 去工作台处理 即置；
     * 与 readAt 分离，不等同于完成业务任务，也不要求从通知中心未读列表消失。
     */
    @Column(name = "popup_acknowledged_at")
    private Instant popupAcknowledgedAt;

    @Column(name = "deleted_at")
    private Instant deletedAt;

    @Column(name = "task_completed_at")
    private Instant taskCompletedAt;

    /**
     * V459「稍后再看」到期时刻：未到期不出弹卡流（通知中心仍可见），
     * 到点未办结则下次登录/到达重弹——即使期间已读或已确认弹窗（2026-09-10：
     * markRead 不再清空本列，「稍后」是用户明确要求的再提醒）。跨设备一致（服务端语义）。
     */
    @Column(name = "snoozed_until")
    private Instant snoozedUntil;
}
