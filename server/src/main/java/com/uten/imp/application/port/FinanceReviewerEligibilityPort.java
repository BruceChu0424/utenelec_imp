package com.uten.imp.application.port;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * Neutral boundary for the finance approval reviewer pool.
 *
 * <p>A finance approval task (procurement order approval or over-arrival exception)
 * is actionable by an enabled employee account with the current page and action authorities.
 * Department membership and the source of an effective grant do not add another access gate.
 * This port is the shared account-state and permission check for those operations.
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
