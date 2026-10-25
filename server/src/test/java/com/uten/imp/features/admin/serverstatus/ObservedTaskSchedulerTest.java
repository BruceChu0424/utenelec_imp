package com.uten.imp.features.admin.serverstatus;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.DisposableBean;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.event.ContextClosedEvent;

import java.time.Duration;
import java.time.Instant;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicBoolean;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;

class ObservedTaskSchedulerTest {

    private final ObservedTaskScheduler scheduler = new ObservedTaskScheduler(new ScheduledTaskRunRegistry());

    @AfterEach
    void tearDown() {
        scheduler.destroy();
    }

    @Test
    void closingTheOwnedContextDrainsActiveWorkBeforeDestroyingDependenciesAndDiscardsDelayedWork() throws Exception {
        var entered = new CountDownLatch(1);
        var release = new CountDownLatch(1);
        var closingStarted = new CountDownLatch(1);
        var finished = new AtomicBoolean();
        var interrupted = new AtomicBoolean();
        var dependencyDestroyed = new AtomicBoolean();
        var dependencyDestroyedBeforeWorkFinished = new AtomicBoolean();
        var delayedRuns = new AtomicInteger();
        var context = new AnnotationConfigApplicationContext();
        context.registerBean(ScheduledTaskRunRegistry.class);
        context.registerBean(ObservedTaskScheduler.class);
        // A datasource/transaction collaborator must outlive already admitted work.
        context.registerBean("workDependency", DisposableBean.class, () -> () -> {
            dependencyDestroyedBeforeWorkFinished.set(!finished.get());
            dependencyDestroyed.set(true);
        });
        context.addApplicationListener(event -> {
            if (event instanceof ContextClosedEvent) closingStarted.countDown();
        });
        try (var closer = Executors.newSingleThreadExecutor()) {
            try {
                context.refresh();
                var owned = context.getBean(ObservedTaskScheduler.class);
                var active = owned.schedule(() -> {
                    entered.countDown();
                    // JDBC work may not stop immediately on interruption. Keep the
                    // operation in flight until its explicit commit/rollback boundary.
                    while (release.getCount() != 0) {
                        try {
                            release.await();
                        } catch (InterruptedException shutdown) {
                            interrupted.set(true);
                        }
                    }
                    finished.set(true);
                    if (interrupted.get()) Thread.currentThread().interrupt();
                }, Instant.now());
                assertTrue(entered.await(5, TimeUnit.SECONDS));
                var delayed = owned.schedule(delayedRuns::incrementAndGet, Instant.now().plusSeconds(300));
                var closed = closer.submit(context::close);
                assertTrue(closingStarted.await(5, TimeUnit.SECONDS));
                try {
                    assertThrows(TimeoutException.class, () -> closed.get(150, TimeUnit.MILLISECONDS),
                            "Context close must wait for already admitted work, before destroying its dependencies");
                    assertFalse(dependencyDestroyed.get());
                } finally {
                    release.countDown();
                }
                closed.get(5, TimeUnit.SECONDS);
                active.get(5, TimeUnit.SECONDS);
                assertTrue(finished.get());
                assertFalse(interrupted.get(), "Graceful close must let the current transaction finish");
                assertTrue(dependencyDestroyed.get());
                assertFalse(dependencyDestroyedBeforeWorkFinished.get());
                assertTrue(delayed.isCancelled(), "Queued delayed work must not be admitted during shutdown");
                assertEquals(0, delayedRuns.get());
            } finally {
                release.countDown();
                context.close();
            }
        }
    }

    @Test
    void anotherContextsCloseEventCannotStopTheOwnedScheduler() throws Exception {
        try (var context = new AnnotationConfigApplicationContext();
             var unrelated = new AnnotationConfigApplicationContext()) {
            context.registerBean(ScheduledTaskRunRegistry.class);
            context.registerBean(ObservedTaskScheduler.class);
            context.refresh();
            var owned = context.getBean(ObservedTaskScheduler.class);
            context.publishEvent(new ContextClosedEvent(unrelated));
            var runs = new AtomicInteger();
            owned.schedule(runs::incrementAndGet, Instant.now()).get(5, TimeUnit.SECONDS);
            assertEquals(1, runs.get());
        }
    }

    /** 服务器状态页「定时任务最近执行」的数据来源：同一包装点记录每次执行。 */
    @Test void scheduledRunsAndFailuresAreRecorded() throws Exception {
        var registry = new ScheduledTaskRunRegistry();
        var recording = new ObservedTaskScheduler(registry);
        try {
            Runnable healthy = named("com.uten.imp.jobs.OutboxScheduler.drain", () -> {});
            recording.scheduleWithFixedDelay(healthy, Instant.now(), Duration.ofSeconds(600));
            org.awaitility.Awaitility.await().atMost(Duration.ofSeconds(5))
                    .until(() -> run(registry, "OutboxScheduler.drain").runs() == 1);
            var first = run(registry, "OutboxScheduler.drain");
            assertEquals(Duration.ofSeconds(600), first.period(), "周期随注册一并记录，供「超期未跑」判定");
            assertTrue(first.lastStart() != null && first.lastEnd() != null);
            assertNull(first.lastErrorType());

            Runnable failing = named("com.uten.imp.jobs.BackupScheduler.check",
                    () -> { throw new IllegalStateException("select secret from vault"); });
            recording.schedule(failing, Instant.now());
            org.awaitility.Awaitility.await().atMost(Duration.ofSeconds(5))
                    .until(() -> run(registry, "BackupScheduler.check").lastErrorType() != null);
            var failed = run(registry, "BackupScheduler.check");
            assertEquals("IllegalStateException", failed.lastErrorType(), "只留异常类名");
            assertEquals(1, failed.consecutiveFailures());
            assertFalse(failed.toString().contains("secret"), "异常消息不得进入状态页");
        } finally {
            recording.destroy();
        }
    }

    private static ScheduledTaskRunRegistry.Run run(ScheduledTaskRunRegistry registry, String name) {
        return registry.snapshot().stream().filter(run -> run.name().equals(name)).findFirst().orElseThrow();
    }

    /** Spring 交给调度器的包装器 toString() 即「全限定类名.方法名」，这里照样模拟。 */
    private static Runnable named(String name, Runnable body) {
        return new Runnable() {
            @Override public void run() { body.run(); }
            @Override public String toString() { return name; }
        };
    }
}
