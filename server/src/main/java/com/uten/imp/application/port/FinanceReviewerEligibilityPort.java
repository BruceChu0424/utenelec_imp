package com.uten.imp.application.port;

import java.util.Optional;
import java.util.UUID;

/** Neutral boundary for validating a configured finance workflow reviewer. */
public interface FinanceReviewerEligibilityPort {

    Optional<EligibleFinanceReviewer> findEligible(UUID userId);

    record EligibleFinanceReviewer(
            UUID userId,
            UUID employeeId,
            String employeeName) {
    }
}
