package com.uten.imp.application.port;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * Neutral boundary for the finance approval reviewer pool.
 *
 * <p>From V229 / ADR-027 a finance approval task (procurement order approval
 * and over-arrival exception) is actionable by any active employee inside the
 * finance department tree who currently holds {@code finance_order_approval:review},
 * rather than a single configured assignee. This port is the single source of
 * truth for that eligibility.
 */
public interface FinanceReviewerEligibilityPort {

    /** Whether the given user is currently an eligible finance reviewer. */
    Optional<EligibleFinanceReviewer> findEligible(UUID userId);

    /** All currently eligible finance reviewers (the approver pool). */
    List<EligibleFinanceReviewer> allEligible();

    record EligibleFinanceReviewer(
            UUID userId,
            UUID employeeId,
            String employeeName) {
    }
}
