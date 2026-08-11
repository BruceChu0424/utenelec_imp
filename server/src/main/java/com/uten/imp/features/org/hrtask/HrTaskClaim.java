package com.uten.imp.features.org.hrtask;

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
 * HR 工作台任务软认领（ADR-021 §四）：任务始终可见，认领者显示「处理中」；
 * 租约过期自动失效（读取时惰性判定）；released_at 非空 = 已释放/被接管。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "hr_task_claims")
public class HrTaskClaim extends BaseEntity {

    @Column(name = "task_type", nullable = false)
    private String taskType;   // confirm / birthday / anniversary / newhire

    @Column(name = "employee_id", nullable = false)
    private UUID employeeId;

    @Column(name = "claimed_by", nullable = false)
    private UUID claimedBy;

    @Column(name = "claimed_at", nullable = false)
    private OffsetDateTime claimedAt = OffsetDateTime.now();

    @Column(name = "lease_until", nullable = false)
    private OffsetDateTime leaseUntil;

    @Column(name = "released_at")
    private OffsetDateTime releasedAt;

    private String remark;

    /** 是否仍有效占用（未释放且在租约内）。 */
    public boolean isActive() {
        return releasedAt == null && leaseUntil != null
                && leaseUntil.isAfter(OffsetDateTime.now());
    }
}
