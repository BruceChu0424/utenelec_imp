package com.uten.imp.application.port;

import java.util.UUID;

/** Bounded, idempotent delivery of still-pending work to a newly authorized reviewer. */
public interface SalesManagerReviewCatchUpPort {
    void catchUp(UUID userId);
}
