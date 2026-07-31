package com.uten.imp.features.notice.outbox;

import lombok.extern.slf4j.Slf4j;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Slf4j
@Component
public class BusinessOutboxScheduler {

    private static final int MAX_BATCH = 20;

    private final BusinessOutboxProcessor processor;
    private final BusinessOutboxFailureRecorder failureRecorder;

    public BusinessOutboxScheduler(
            BusinessOutboxProcessor processor,
            BusinessOutboxFailureRecorder failureRecorder) {
        this.processor = processor;
        this.failureRecorder = failureRecorder;
    }

    @Scheduled(
            fixedDelayString = "${uten.outbox.poll-delay-ms:2000}",
            initialDelayString = "${uten.outbox.initial-delay-ms:2000}")
    public void drain() {
        for (int index = 0; index < MAX_BATCH; index++) {
            try {
                if (!processor.processNext()) {
                    return;
                }
            } catch (OutboxDeliveryException error) {
                failureRecorder.record(error.eventId(), error);
                log.warn("Business outbox delivery deferred: {}", error.getMessage());
            } catch (RuntimeException error) {
                log.error("Business outbox polling failed", error);
                return;
            }
        }
    }
}
