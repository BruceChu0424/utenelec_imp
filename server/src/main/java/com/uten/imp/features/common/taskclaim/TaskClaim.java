package com.uten.imp.features.common.taskclaim;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 统一任务软认领（ADR-023，泛化 ADR-021 §四 的 hr_task_claims）。
 *
 * <p>默认 show-as-locked：任务始终可见，被认领的目标显示「XXX 处理中」，他人快捷动作禁用。
 * 认领带短租约（按 target_type 配置，默认 30 分），过期惰性失效；认领人可续租/释放，
 * 持目标 manage 权限者可强制释放/接管。财务新决策必须持本人有效租约，其他类型是软认领；
 * 两者均不替代动作端点的 PESSIMISTIC_WRITE 与业务状态守卫。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "task_claims")
public class TaskClaim extends BaseEntity {

    /** 认领目标类型，如 EXPENSE_APPROVE / PURCHASE_DECOMPOSE / SALES_ORDER_APPROVE / FULFILLMENT_TASK_EDIT / FULFILLMENT_TASK_APPROVE。 */
    @Column(name = "target_type", nullable = false)
    private String targetType;

    /** 目标对象规范键（通常是单据/明细 UUID 字符串）。与 targetType 组合唯一（在未释放范围内）。 */
    @Column(name = "target_key", nullable = false)
    private String targetKey;

    @Column(name = "claimed_by", nullable = false)
    private UUID claimedBy;

    @Column(name = "claimed_at", nullable = false)
    private OffsetDateTime claimedAt = OffsetDateTime.now();

    @Column(name = "lease_until", nullable = false)
    private OffsetDateTime leaseUntil;

    @Column(name = "last_heartbeat")
    private OffsetDateTime lastHeartbeat;

    @Column(name = "released_at")
    private OffsetDateTime releasedAt;

    /** manual / takeover / expired / admin_force_release / completed。 */
    @Column(name = "release_reason")
    private String releaseReason;

    @Column(name = "released_by")
    private UUID releasedBy;

    private String remark;

    /** 是否仍有效占用（未释放且在租约内）。 */
    public boolean isActive() {
        return releasedAt == null && leaseUntil != null
                && leaseUntil.isAfter(OffsetDateTime.now());
    }
}
