package com.uten.imp.features.subcontract.order;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.subcontract.order.dto.OrderDetail;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

/** Atomically applies a subcontract finance decision and assembles its response. */
@Service
@RequiredArgsConstructor
public class SubcontractOrderFinanceDecisionCommandService {

    private final ProcurementFinanceApprovalService financeApproval;
    private final SubcontractOrderService orders;

    @Transactional
    public OrderDetail approve(UUID orderId, long expectedVersion) {
        FinanceApproval decision = financeApproval.approve(
                "SUBCONTRACT", orderId, expectedVersion);
        requireStatus(decision, "APPROVED");
        return orders.financeDecisionResultDetail(orderId, decision);
    }

    @Transactional
    public OrderDetail reject(
            UUID orderId, long expectedVersion, String reason) {
        FinanceApproval decision = financeApproval.reject(
                "SUBCONTRACT", orderId, expectedVersion, reason);
        requireStatus(decision, "REJECTED");
        return orders.financeDecisionResultDetail(orderId, decision);
    }

    private static void requireStatus(
            FinanceApproval decision, String expectedStatus) {
        if (decision == null
                || decision.caseId() == null
                || !expectedStatus.equals(decision.status())) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "财务审批结果已变化，请刷新任务后重试");
        }
    }
}
