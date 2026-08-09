package com.uten.imp.features.notice.outbox;

import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Slf4j
@Component
@Profile("!cloud")
public class BusinessOutboxScheduler {

    private static final int MAX_BATCH = 20;

    private final BusinessOutboxProcessor processor;
    private final BusinessOutboxFailureRecorder failureRecorder;
    private final OutboxWarnThrottler warnThrottler;

    // 多构造器必须显式 @Autowired 标记注入入口（同 MaterializedViewRefreshScheduler
    // 的约定），否则 Spring 回退找默认构造器直接启动失败。
    @Autowired
    public BusinessOutboxScheduler(
            BusinessOutboxProcessor processor, BusinessOutboxFailureRecorder failureRecorder) {
        this(processor, failureRecorder, OutboxWarnThrottler.withDefaults());
    }

    BusinessOutboxScheduler(
            BusinessOutboxProcessor processor,
            BusinessOutboxFailureRecorder failureRecorder,
            OutboxWarnThrottler warnThrottler) {
        this.processor = processor;
        this.failureRecorder = failureRecorder;
        this.warnThrottler = warnThrottler;
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
                // 投递失败已落 failureRecorder；相同告警 5 分钟窗口内只打一条，
                // 其余静默计数，避免下游长故障 + 积压时每轮刷屏 20 条相同 warn。
                String line = warnThrottler.consume(String.valueOf(error.getMessage()));
                if (line != null) {
                    log.warn("Business outbox delivery deferred: {}", line);
                }
            } catch (RuntimeException error) {
                log.error("Business outbox polling failed", error);
                return;
            }
        }
    }
}
