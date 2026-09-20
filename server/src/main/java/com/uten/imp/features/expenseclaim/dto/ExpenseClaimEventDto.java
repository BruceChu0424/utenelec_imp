package com.uten.imp.features.expenseclaim.dto;

import java.time.Instant;

/** 报销单流转事件（详情审批轨迹；操作人姓名为落库快照）。 */
public record ExpenseClaimEventDto(
        String eventType,
        String actorName,
        String remark,
        Instant occurredAt) {
}
