package com.uten.imp.application.port;

import java.util.List;
import java.util.UUID;

public interface SalesManagerReviewerEligibilityPort {
    boolean eligible(UUID userId, String kind, String action);
    List<UUID> reviewers(String kind);
}
