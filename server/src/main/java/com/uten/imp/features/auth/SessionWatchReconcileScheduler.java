package com.uten.imp.features.auth;

import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/** Periodic local reconciliation; watch registration and committed events remain available in cloud. */
@Component
@Profile("!cloud")
@RequiredArgsConstructor
final class SessionWatchReconcileScheduler {

    private final SessionWatchService watches;

    /** Also observes revocations committed by another server process and idle expiry. */
    @Scheduled(fixedDelay = 2000L)
    void reconcile() {
        watches.reconcile();
    }
}
