package com.uten.imp.features.sales.template;

import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/** Keep automatic writes off the cloud reader while the template service remains available. */
@Component
@Profile("!cloud")
public class SalesQuoteTemplateCleanupScheduler {
    private final SalesQuoteTemplateStore store;

    public SalesQuoteTemplateCleanupScheduler(SalesQuoteTemplateStore store) {
        this.store = store;
    }

    @Scheduled(fixedDelayString = "${uten.sales.quote-template-cleanup-ms:3600000}")
    public void purgeExpired() {
        store.purgeExpired();
    }
}
