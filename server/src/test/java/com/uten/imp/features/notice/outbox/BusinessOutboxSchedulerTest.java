package com.uten.imp.features.notice.outbox;

import org.junit.jupiter.api.Test;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verifyNoInteractions;

class BusinessOutboxSchedulerTest {
    @Test
    void concurrentWakeupsCoalesceAndFullBatchesContinueInTheSameDispatch() throws Exception {
        var processor = mock(BusinessOutboxProcessor.class);
        var failures = mock(BusinessOutboxFailureRecorder.class);
        var executor = new ManualOutboxExecutor();
        var processed = new AtomicInteger();
        when(processor.processNext()).thenAnswer(call -> processed.getAndIncrement() < 61);
        try (var scheduler = new BusinessOutboxScheduler(processor, failures, OutboxWarnThrottler.withDefaults(), executor)) {
            try (var callers = Executors.newFixedThreadPool(8)) {
                for (int i = 0; i < 1000; i++) callers.submit(scheduler::drain);
            }
            assertEquals(1, executor.queued());
            assertEquals(1, executor.submitted());
            executor.runOne();
            assertEquals(62, processed.get(), "61 events plus the empty-queue probe, without another scheduled tick");
            assertEquals(1, executor.submitted());
            verifyNoInteractions(failures);
        }
    }

    @Test
    void wakeDuringAnEmptyProbeIsNotLost() {
        var processor = mock(BusinessOutboxProcessor.class);
        var executor = new ManualOutboxExecutor();
        try (var scheduler = new BusinessOutboxScheduler(processor, mock(BusinessOutboxFailureRecorder.class),
                OutboxWarnThrottler.withDefaults(), executor)) {
            var calls = new AtomicInteger();
            when(processor.processNext()).thenAnswer(call -> {
                if (calls.getAndIncrement() == 0) scheduler.drain();
                return false;
            });
            scheduler.drain();
            executor.runOne();
            assertEquals(2, calls.get());
            assertEquals(1, executor.submitted());
        }
    }

    @Test
    void workerNeverRunsInParallelOrOnTheCallingThread() throws Exception {
        var processor = mock(BusinessOutboxProcessor.class);
        var failures = mock(BusinessOutboxFailureRecorder.class);
        var entered = new CountDownLatch(1);
        var release = new CountDownLatch(1);
        var finished = new CountDownLatch(1);
        var active = new AtomicInteger();
        var maximum = new AtomicInteger();
        var calls = new AtomicInteger();
        Thread requestingThread = Thread.currentThread();
        when(processor.processNext()).thenAnswer(call -> {
            assertTrue(Thread.currentThread() != requestingThread);
            maximum.accumulateAndGet(active.incrementAndGet(), Math::max);
            try {
                if (calls.getAndIncrement() == 0) {
                    entered.countDown();
                    assertTrue(release.await(5, TimeUnit.SECONDS));
                    return true;
                }
                finished.countDown();
                return false;
            } finally { active.decrementAndGet(); }
        });
        try (var scheduler = new BusinessOutboxScheduler(processor, failures)) {
            scheduler.drain();
            assertTrue(entered.await(5, TimeUnit.SECONDS));
            try (var callers = Executors.newFixedThreadPool(8)) {
                for (int i = 0; i < 500; i++) callers.submit(scheduler::drain);
            } finally { release.countDown(); }
            assertTrue(finished.await(5, TimeUnit.SECONDS));
            assertEquals(1, maximum.get());
        }
    }

    @Test
    void pollingFailureStopsThisRunAndTheNextFallbackTickCanRecover() {
        var processor = mock(BusinessOutboxProcessor.class);
        var executor = new ManualOutboxExecutor();
        when(processor.processNext()).thenThrow(new IllegalStateException("database temporarily unavailable"))
                .thenReturn(true, false);
        try (var scheduler = new BusinessOutboxScheduler(processor, mock(BusinessOutboxFailureRecorder.class),
                OutboxWarnThrottler.withDefaults(), executor)) {
            scheduler.drain(); executor.runOne();
            assertEquals(0, executor.queued(), "a general failure must not spin in an immediate retry loop");
            scheduler.drain(); executor.runOne();
            verify(processor, times(3)).processNext();
        }
    }
}
