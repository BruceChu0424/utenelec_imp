package com.uten.imp.features.attachment;

import com.uten.imp.common.storage.StorageService;
import com.uten.imp.common.storage.StorageProviderRegistry;
import com.uten.imp.common.storage.StorageService.StoredObject;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Slf4j
@Component
@Profile("!cloud")
@RequiredArgsConstructor
final class AttachmentUploadExpiryScheduler {
    private static final int MAX_BATCH = 20;

    private final AttachmentUploadSessionStore sessions;
    private final AttachmentObjectOutboxStore outbox;
    private final StorageProviderRegistry storageProviders;

    @Scheduled(fixedDelayString = "${uten.storage.outbox.poll-delay-millis:2000}",
            initialDelayString = "${uten.storage.outbox.poll-delay-millis:2000}")
    void expire() {
        for (int index = 0; index < MAX_BATCH; index++) {
            AttachmentUploadSessionStore.ExpiredSession session = sessions.expireNext();
            if (session == null) {
                return;
            }
            try {
                StoredObject object = storageProviders.require(session.storageProvider()).describe(session.storageKey());
                if (object.exists()) {
                    outbox.enqueueStaging(
                            session.id(), session.storageKey(), object.versionId(), session.storageProvider());
                    sessions.recordExpiryCleanup(session.id(), "EXPIRY_DELETE_QUEUED");
                } else {
                    sessions.recordExpiryCleanup(session.id(), "NO_STAGING_OBJECT");
                }
            } catch (RuntimeException error) {
                sessions.recordExpiryCleanup(session.id(), "CLEANUP_LOOKUP_FAILED");
                log.warn("Expired attachment staging lookup failed session={} type={}",
                        session.id(), error.getClass().getSimpleName());
            }
        }
    }
}
