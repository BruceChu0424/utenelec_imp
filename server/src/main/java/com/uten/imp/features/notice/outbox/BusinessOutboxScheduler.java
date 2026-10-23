package com.uten.imp.features.notice.outbox;

import lombok.extern.slf4j.Slf4j;
import jakarta.annotation.PreDestroy;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.event.TransactionPhase;
import org.springframework.transaction.event.TransactionalEventListener;

import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/**
 * 提交后异步唤醒单个有界worker，满20条立即续批；2s轮询兜底。
 * 失败转 {@link BusinessOutboxFailureRecorder} 退避重试；
 * 相同告警 5 分钟窗口内只打一条 warn 防积压刷屏。仅非 cloud profile 生效。
 */
@Slf4j
@Component
@Profile("!cloud")
public class BusinessOutboxScheduler implements AutoCloseable {

    private static final int MAX_BATCH = 20;

    private final BusinessOutboxProcessor processor;
    private final BusinessOutboxFailureRecorder failureRecorder;
    private final OutboxWarnThrottler warnThrottler;
    private final BusinessOutboxDeliveryDiagnostics diagnostics;
    private final ExecutorService worker;
    private final Object dispatchLock = new Object();
    private boolean queuedOrRunning;
    private boolean wakeRequested;
    private boolean closed;

    // 多构造器必须显式 @Autowired 标记注入入口（同 MaterializedViewRefreshScheduler
    // 的约定），否则 Spring 回退找默认构造器直接启动失败。
    public BusinessOutboxScheduler(
            BusinessOutboxProcessor processor, BusinessOutboxFailureRecorder failureRecorder) {
        this(processor, failureRecorder, OutboxWarnThrottler.withDefaults());
    }

    @Autowired
    public BusinessOutboxScheduler(BusinessOutboxProcessor processor,
            BusinessOutboxFailureRecorder failureRecorder, BusinessOutboxDeliveryDiagnostics diagnostics) {
        this(processor, failureRecorder, OutboxWarnThrottler.withDefaults(), newWorker(), diagnostics);
    }

    BusinessOutboxScheduler(
            BusinessOutboxProcessor processor,
            BusinessOutboxFailureRecorder failureRecorder,
            OutboxWarnThrottler warnThrottler) {
        this(processor, failureRecorder, warnThrottler, newWorker());
    }

    private static ExecutorService newWorker() {
        return new ThreadPoolExecutor(
                1, 1, 0, TimeUnit.MILLISECONDS, new ArrayBlockingQueue<>(1),
                Thread.ofPlatform().daemon().name("business-outbox-dispatch")
                        .inheritInheritableThreadLocals(false).factory(),
                new ThreadPoolExecutor.AbortPolicy());
    }

    BusinessOutboxScheduler(
            BusinessOutboxProcessor processor,
            BusinessOutboxFailureRecorder failureRecorder,
            OutboxWarnThrottler warnThrottler,
            ExecutorService worker) {
        this(processor, failureRecorder, warnThrottler, worker, new BusinessOutboxDeliveryDiagnostics(null));
    }

    BusinessOutboxScheduler(BusinessOutboxProcessor processor,
            BusinessOutboxFailureRecorder failureRecorder, OutboxWarnThrottler warnThrottler,
            ExecutorService worker, BusinessOutboxDeliveryDiagnostics diagnostics) {
        this.processor = processor;
        this.failureRecorder = failureRecorder;
        this.warnThrottler = warnThrottler;
        this.worker = worker;
        this.diagnostics = diagnostics;
    }

    @TransactionalEventListener(classes = BusinessOutboxReady.class, phase = TransactionPhase.AFTER_COMMIT)
    public void onCommittedEvent() {
        requestDrain();
    }

    @Scheduled(
            fixedDelayString = "${uten.outbox.poll-delay-ms:2000}",
            initialDelayString = "${uten.outbox.initial-delay-ms:2000}")
    public void drain() {
        requestDrain();
    }

    private void requestDrain() {
        synchronized (dispatchLock) {
            if (closed) return;
            wakeRequested = true;
            if (queuedOrRunning) return;
            queuedOrRunning = true;
            try {
                worker.execute(this::runPending);
            } catch (RejectedExecutionException error) {
                queuedOrRunning = false;
                wakeRequested = false;
                // This is an acceleration hint after commit, not a delivery failure.
                // Never turn a committed business request into a false HTTP error.
                if (!closed) log.warn("Business outbox wake-up rejected; durable polling will retry");
            }
        }
    }

    private void runPending() {
        boolean failed = false;
        try {
            while (true) {
                synchronized (dispatchLock) {
                    if (closed) return;
                    wakeRequested = false;
                }
                BatchResult result = drainBatch();
                if (result == BatchResult.FAILED) {
                    failed = true;
                    return;
                }
                synchronized (dispatchLock) {
                    if (closed || (result == BatchResult.IDLE && !wakeRequested)) return;
                }
            }
        } finally {
            boolean again;
            synchronized (dispatchLock) {
                queuedOrRunning = false;
                again = !closed && !failed && wakeRequested;
                wakeRequested = false;
            }
            if (again) requestDrain();
        }
    }

    private BatchResult drainBatch() {
        for (int index = 0; index < MAX_BATCH; index++) {
            synchronized (dispatchLock) {
                if (closed) return BatchResult.IDLE;
            }
            try {
                if (!processor.processNext()) {
                    return BatchResult.IDLE;
                }
                diagnostics.count(BusinessOutboxDeliveryDiagnostics.Outcome.DELIVERED,
                        BusinessOutboxDeliveryDiagnostics.Kind.NONE);
            } catch (OutboxDeliveryException error) {
                var failure = BusinessOutboxDeliveryDiagnostics.describe(error);
                java.util.Optional<BusinessOutboxFailureRecorder.FailureRecording> recorded;
                try {
                    recorded = failureRecorder.record(error.eventId(), error);
                } catch (RuntimeException recordingFailure) {
                    diagnostics.count(BusinessOutboxDeliveryDiagnostics.Outcome.NOT_RECORDED, failure.kind());
                    log.error("Business outbox failure recording failed; polling will retry", recordingFailure);
                    return BatchResult.FAILED;
                }
                if (recorded.isEmpty()) {
                    diagnostics.count(BusinessOutboxDeliveryDiagnostics.Outcome.NOT_RECORDED, failure.kind());
                    log.warn("Business outbox failure state was not recorded (event={}): {}",
                            error.eventId(), failure.persistedDescription());
                    continue;
                }
                var state = recorded.orElseThrow();
                if (state.alreadyDelivered()) {
                    diagnostics.count(BusinessOutboxDeliveryDiagnostics.Outcome.ALREADY_DELIVERED, failure.kind());
                    if (failure.deferrable()) {
                        log.info("Business outbox already delivered by another consumer after rolled-back contention (event={}): {}",
                                error.eventId(), failure.persistedDescription());
                    } else {
                        // A successful competitor does not explain an unexpected SQL/code failure.
                        log.warn("Business outbox unexpected delivery failure; another consumer has completed the event (event={}): {}",
                                error.eventId(), failure.persistedDescription());
                    }
                    continue;
                }
                if (state.exhausted()) {
                    diagnostics.count(BusinessOutboxDeliveryDiagnostics.Outcome.EXHAUSTED, failure.kind());
                    log.error("Business outbox delivery exhausted (event={}, attempts={}): {}",
                            error.eventId(), state.attempts(), failure.persistedDescription());
                    continue;
                }
                if (!state.recorded()) {
                    diagnostics.count(BusinessOutboxDeliveryDiagnostics.Outcome.NOT_RECORDED, failure.kind());
                    log.warn("Business outbox failure state was not recorded (event={}, observedStatus={}): {}",
                            error.eventId(), state.status(), failure.persistedDescription());
                    continue;
                }
                if (failure.deferrable() && state.deferred()) {
                    diagnostics.count(BusinessOutboxDeliveryDiagnostics.Outcome.DEFERRED, failure.kind());
                    log.info("Business outbox contention deferred (event={}, attempts={}, availableAt={}): {}",
                            error.eventId(), state.attempts(), state.availableAt(), failure.persistedDescription());
                    continue;
                }
                diagnostics.count(BusinessOutboxDeliveryDiagnostics.Outcome.FAILED, failure.kind());
                // 投递失败已落 failureRecorder；相同告警 5 分钟窗口内只打一条，
                // 其余静默计数，避免下游长故障 + 积压时每轮刷屏 20 条相同 warn。
                String line = warnThrottler.consume(failure.persistedDescription());
                if (line != null) {
                    log.warn("Business outbox delivery deferred (event={}): {}", error.eventId(), line);
                }
            } catch (RuntimeException error) {
                log.error("Business outbox polling failed", error);
                return BatchResult.FAILED;
            }
        }
        return BatchResult.FULL;
    }

    @Override
    @PreDestroy
    public void close() {
        synchronized (dispatchLock) {
            if (closed) return;
            closed = true;
            wakeRequested = false;
        }
        worker.shutdown();
        try {
            if (!worker.awaitTermination(5, TimeUnit.SECONDS)) worker.shutdownNow();
        } catch (InterruptedException error) {
            worker.shutdownNow();
            Thread.currentThread().interrupt();
        }
    }

    private enum BatchResult { FULL, IDLE, FAILED }
}
