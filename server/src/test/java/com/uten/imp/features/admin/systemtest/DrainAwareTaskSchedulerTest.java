package com.uten.imp.features.admin.systemtest;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.time.Instant;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.Executors;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.assertFalse;

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
        assertTrue(gate.beginDrain(1_000), "无在途请求时排水应立即成功，闸进入 RESETTING");

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
            assertTrue(drained.get(5,TimeUnit.SECONDS));
        } finally {release.countDown();}
    }
}
