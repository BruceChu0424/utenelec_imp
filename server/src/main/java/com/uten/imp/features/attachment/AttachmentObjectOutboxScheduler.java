package com.uten.imp.features.attachment;

import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
@Profile("!cloud")
@RequiredArgsConstructor
final class AttachmentObjectOutboxScheduler {
    private static final int MAX_BATCH = 20;

    private final AttachmentObjectOutboxProcessor processor;

    @Scheduled(
            fixedDelayString = "${uten.storage.outbox.poll-delay-millis:2000}",
            initialDelayString = "${uten.storage.outbox.poll-delay-millis:2000}")
    void drain() {
        for (int index = 0; index < MAX_BATCH && processor.processNext(); index++) {
            // bounded drain; the next scheduler tick continues any backlog
        }
    }
}
