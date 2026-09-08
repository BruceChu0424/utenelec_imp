package com.uten.imp.application.port;

import java.util.UUID;

/** Current sales-order finance reviewer eligibility, shared with review-task claims. */
@FunctionalInterface
public interface SalesOrderFinanceReviewerEligibilityPort {
    boolean isEligible(UUID userId);
}
