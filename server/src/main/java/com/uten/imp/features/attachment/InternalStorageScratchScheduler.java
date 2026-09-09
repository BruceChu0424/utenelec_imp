package com.uten.imp.features.attachment;

import com.uten.imp.common.storage.InternalStorageService;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
@Profile("!cloud")
@ConditionalOnProperty(prefix="uten.storage",name="provider",havingValue="internal")
class InternalStorageScratchScheduler {
    private final InternalStorageService storage;
    InternalStorageScratchScheduler(InternalStorageService storage) { this.storage=storage; }
    @Scheduled(fixedDelayString="${uten.storage.internal.scratch-cleanup-delay-millis:3600000}",
            initialDelayString="${uten.storage.internal.scratch-cleanup-delay-millis:3600000}")
    void cleanup() { storage.cleanupAbandonedScratch(); }
}
