package com.uten.imp.features.sales.learning;

import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/** Automatic retention belongs to the writable internal deployment. */
@Component
@Profile("!cloud")
public class SalesLearningEvidenceCleanupScheduler {
    private final SalesLearningReceiptService receipts;

    public SalesLearningEvidenceCleanupScheduler(SalesLearningReceiptService receipts) {
        this.receipts = receipts;
    }

    @Scheduled(fixedDelayString = "${uten.sales.learning-receipt-cleanup-ms:3600000}")
    public void purgeExpiredEvidence() {
        receipts.purgeExpiredEvidence();
    }
}
