package com.uten.imp.features.stock.valuation;

import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/** Local polling entry point; the work service remains available in every profile. */
@Component
@Profile("!cloud")
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
