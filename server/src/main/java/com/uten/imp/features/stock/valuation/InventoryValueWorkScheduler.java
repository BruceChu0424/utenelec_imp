package com.uten.imp.features.stock.valuation;

import org.springframework.context.annotation.Profile;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/** Local polling entry point; the work service remains available in every profile. */
@Component
@Profile("!cloud")
@ConditionalOnProperty(prefix = "uten.inventory.value-work", name = "enabled", havingValue = "true", matchIfMissing = true)
public class InventoryValueWorkScheduler {
    private final InventoryValueWorkService work;

    public InventoryValueWorkScheduler(InventoryValueWorkService work) {
        this.work = work;
    }

    @Scheduled(fixedDelayString = "${uten.inventory.value-work-delay-ms:2000}",
            initialDelayString = "${uten.inventory.value-work-initial-delay-ms:10000}")
    public void scheduled() {
        work.runBatch();
    }
}
