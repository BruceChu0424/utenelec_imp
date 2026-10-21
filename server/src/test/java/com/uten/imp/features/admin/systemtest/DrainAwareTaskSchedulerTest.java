package com.uten.imp.features.admin.systemtest;

import com.uten.imp.features.admin.serverstatus.ScheduledTaskRunRegistry;
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

/**
 * 清空窗口内 @Scheduled 任务必须被跳过（2026-09-04 服务器死锁事故的回归锁）：
 * 排水闸处于 DRAINING/RESETTING 时定时任务不得执行，闸回到 IDLE 后恢复。
 */
class DrainAwareTaskSchedulerTest {

    private final BusinessDataResetDrainGate gate = new BusinessDataResetDrainGate();
    private final DrainAwareTaskScheduler scheduler = new DrainAwareTaskScheduler(gate);

    @AfterEach
    void tearDown() {
        scheduler.destroy();
        if (gate.blockingNewRequests()) {
            gate.endReset();
        }
    }

    @Test
    void scheduledTaskSkipsWhileDrainGateIsEngagedAndResumesAfter() throws Exception {
        assertEquals(BusinessDataResetDrainGate.DrainOutcome.STARTED, gate.beginDrain(1_000), "无在途请求时排水应立即成功，闸进入 RESETTING");

        AtomicInteger runs = new AtomicInteger();
        scheduler.schedule(runs::incrementAndGet, Instant.now()).get(5,TimeUnit.SECONDS);
        assertEquals(0, runs.get(), "清空窗口内不得执行任何定时任务");

        gate.endReset();
        scheduler.schedule(runs::incrementAndGet, Instant.now()).get(5,TimeUnit.SECONDS);
        assertEquals(1,runs.get(),"闸放行后任务应恢复执行");
    }

    @Test void resetWaitsForAlreadyRunningScheduledTaskAndRejectsNewAdmissions() throws Exception {
        CountDownLatch started=new CountDownLatch(1),release=new CountDownLatch(1);
        var task=scheduler.schedule(()->{started.countDown();try{assertTrue(release.await(5,TimeUnit.SECONDS));}
            catch(InterruptedException interrupted){Thread.currentThread().interrupt();throw new IllegalStateException(interrupted);}},Instant.now());
        assertTrue(started.await(5,TimeUnit.SECONDS));
        try(var executor=Executors.newSingleThreadExecutor()){
            var drained=executor.submit(()->gate.beginDrain(5_000));
            org.awaitility.Awaitility.await().atMost(Duration.ofSeconds(2)).until(gate::blockingNewRequests);
            assertFalse(drained.isDone(),"正在执行的任务必须排完，不能立即开始清理");
            assertFalse(gate.tryEnter(),"排水期间不得接纳新请求或任务");
            release.countDown();task.get(5,TimeUnit.SECONDS);
            assertEquals(BusinessDataResetDrainGate.DrainOutcome.STARTED, drained.get(5,TimeUnit.SECONDS));
        } finally {release.countDown();}
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
        context.registerBean(BusinessDataResetDrainGate.class);
        context.registerBean(ScheduledTaskRunRegistry.class);
        context.registerBean(DrainAwareTaskScheduler.class);
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
                var owned = context.getBean(DrainAwareTaskScheduler.class);
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
            context.registerBean(BusinessDataResetDrainGate.class);
            context.registerBean(ScheduledTaskRunRegistry.class);
            context.registerBean(DrainAwareTaskScheduler.class);
            context.refresh();
            var owned = context.getBean(DrainAwareTaskScheduler.class);
            context.publishEvent(new ContextClosedEvent(unrelated));
            var runs = new AtomicInteger();
            owned.schedule(runs::incrementAndGet, Instant.now()).get(5, TimeUnit.SECONDS);
            assertEquals(1, runs.get());
        }
    }

    /** 服务器状态页「定时任务最近执行」的数据来源：同一包装点记录每次执行。 */
    @Test void scheduledRunsAreRecordedAndDrainSkippedRoundsAreNotCountedAsRuns() throws Exception {
        var registry = new ScheduledTaskRunRegistry();
        var recording = new DrainAwareTaskScheduler(gate, registry);
        try {
            Runnable healthy = named("com.uten.imp.jobs.OutboxScheduler.drain", () -> {});
            recording.scheduleWithFixedDelay(healthy, Instant.now(), Duration.ofSeconds(600));
            org.awaitility.Awaitility.await().atMost(Duration.ofSeconds(5))
                    .until(() -> run(registry, "OutboxScheduler.drain").runs() == 1);
            var first = run(registry, "OutboxScheduler.drain");
            assertEquals(Duration.ofSeconds(600), first.period(), "周期随注册一并记录，供「超期未跑」判定");
            assertTrue(first.lastStart() != null && first.lastEnd() != null);
            assertNull(first.lastErrorType());

            assertEquals(BusinessDataResetDrainGate.DrainOutcome.STARTED, gate.beginDrain(1_000));
            recording.schedule(healthy, Instant.now()).get(5, TimeUnit.SECONDS);
            assertEquals(1, run(registry, "OutboxScheduler.drain").runs(), "被排水闸跳过的一轮不算执行");
            gate.endReset();

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
