package com.uten.imp.features.admin.systemtest;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

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
        CountDownLatch ranTwice = new CountDownLatch(2);
        scheduler.scheduleWithFixedDelay(
                () -> {
                    runs.incrementAndGet();
                    ranTwice.countDown();
                },
                Duration.ofMillis(10));

        // 清空窗口内：任务按周期被调度但每次都被闸跳过。
        Thread.sleep(300);
        assertEquals(0, runs.get(), "清空窗口内不得执行任何定时任务");

        gate.endReset();
        assertTrue(ranTwice.await(5, TimeUnit.SECONDS), "闸放行后任务应恢复执行");
        assertTrue(runs.get() >= 2);
    }
}
