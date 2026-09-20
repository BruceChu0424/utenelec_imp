package com.uten.imp.features.expenseclaim;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.util.UUID;

/**
 * 报销单流转事件（V608）：提交/撤回/编辑/通过/驳回/打款逐笔留痕（操作人姓名快照），
 * 详情页审批轨迹由此渲染，不再由前端时间戳合成。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "expense_claim_events")
public class ExpenseClaimEvent extends BaseEntity {

    @Column(name = "claim_id", nullable = false)
    private UUID claimId;

    /** CREATED/SUBMITTED/WITHDRAWN/EDITED/APPROVED/REJECTED/PAID。 */
    @Column(name = "event_type", nullable = false)
    private String eventType;

    @Column(name = "actor_employee_id")
    private UUID actorEmployeeId;

    @Column(name = "actor_name_snapshot", nullable = false)
    private String actorNameSnapshot;

    /** 驳回原因等备注。 */
    private String remark;
}
