package com.uten.imp.features.notice;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
@Profile("!cloud")
@ConditionalOnProperty(name="uten.notices.planning-catch-up.enabled", havingValue="true", matchIfMissing=true)
public class SalesPlanningNoticeCatchUpScheduler {
    private final SalesPlanningNoticeCatchUpService service;
    public SalesPlanningNoticeCatchUpScheduler(SalesPlanningNoticeCatchUpService service) { this.service = service; }

    @Scheduled(fixedDelayString="${uten.notices.planning-catch-up.delay-ms:30000}",
            initialDelayString="${uten.notices.planning-catch-up.initial-delay-ms:30000}")
    public void reconcile() { service.runBatch(); }
}
