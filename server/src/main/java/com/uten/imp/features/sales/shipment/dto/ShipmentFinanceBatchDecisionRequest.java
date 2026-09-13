package com.uten.imp.features.sales.shipment.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.UUID;

/**
 * 出货财务审核批量决策（整批同事务，任一项 revision/哈希/认领失效即全部回滚）。
 *
 * <p>对齐订货审批批量口径（/finance/procurement-approvals/tasks/batch-approve）：
 * 每项携带单笔决策所需的乐观锁三元组；退回批共用一个 [reason]。</p>
 */
public record ShipmentFinanceBatchDecisionRequest(
        @NotEmpty @Size(max = 100) @Valid List<Item> items,
        @Size(max = 500) String reason) {

    public record Item(@NotNull UUID id, Long expectedRevision,
            @Size(max = 64) String expectedContentHash, UUID expectedClaimId) {

        public ShipmentFinanceDecisionRequest toDecision(String sharedReason) {
            return new ShipmentFinanceDecisionRequest(
                    expectedRevision, expectedContentHash, expectedClaimId, sharedReason);
        }
    }
}
