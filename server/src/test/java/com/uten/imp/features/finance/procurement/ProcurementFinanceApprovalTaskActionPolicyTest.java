package com.uten.imp.features.finance.procurement;

import org.junit.jupiter.api.Test;

import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class ProcurementFinanceApprovalTaskActionPolicyTest {

    @Test
    void taskActionsMatchTheEligibleReviewersExactPermissions() {
        assertThat(ProcurementFinanceApprovalService.reviewerActions(
                true, Set.of("finance_order_approval:approve")))
                .containsExactly("APPROVE");
        assertThat(ProcurementFinanceApprovalService.reviewerActions(
                true, Set.of("finance_order_approval:reject")))
                .containsExactly("REJECT");
        assertThat(ProcurementFinanceApprovalService.reviewerActions(
                true, Set.of(
                        "finance_order_approval:approve",
                        "finance_order_approval:reject")))
                .containsExactly("APPROVE", "REJECT");
    }

    @Test
    void viewOnlyOrIneligibleActorsReceiveNoFakeTaskActions() {
        assertThat(ProcurementFinanceApprovalService.reviewerActions(
                true, Set.of("finance_order_approval:view")))
                .isEmpty();
        assertThat(ProcurementFinanceApprovalService.reviewerActions(
                false, Set.of(
                        "finance_order_approval:approve",
                        "finance_order_approval:reject")))
                .isEmpty();
    }
}
