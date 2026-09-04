package com.uten.imp.features.admin.systemtest;

import org.springframework.beans.factory.DisposableBean;
import org.springframework.scheduling.TaskScheduler;
import org.springframework.scheduling.Trigger;
import org.springframework.scheduling.concurrent.ThreadPoolTaskScheduler;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.time.Instant;
import java.util.concurrent.ScheduledFuture;

/**
 * 排水闸罩住应用内全部 {@code @Scheduled} 定时任务。
 *
 * <p>2026-09-04 服务器事故：工作台「清空业务数据」执行期间，应用内定时任务
 * （物化视图 {@code REFRESH ... CONCURRENTLY}、outbox 清扫等）不是 /api 请求，
 * 不受排水闸约束，与 {@code business_data_reset()} 内部的 TRUNCATE/REFRESH
 * 互相等锁，被 PostgreSQL 死锁检测器选为牺牲品整体回滚，前端只看到网关 504。
 * 定时任务自身也可能排在清空事务的排它锁前队，拖慢甚至阻断清空。</p>
 *
 * <p>本包装器作为容器中唯一的 {@link TaskScheduler}（替代 Boot 默认的单线程
 * 调度器，线程模型不变）接管 {@code @Scheduled} 调度：清空窗口
 * （DRAINING/RESETTING）内跳过本轮任务执行，只推迟到下一周期，不改变周期
 * 语义。HTTP 请求线程不经此处，仍由
 * {@link BusinessDataResetDrainFilter} 负责。</p>
 */
@Component
public class DrainAwareTaskScheduler implements TaskScheduler, DisposableBean {

    private final BusinessDataResetDrainGate drainGate;
    private final ThreadPoolTaskScheduler delegate;

    public DrainAwareTaskScheduler(BusinessDataResetDrainGate drainGate) {
        this.drainGate = drainGate;
        this.delegate = new ThreadPoolTaskScheduler();
        this.delegate.setPoolSize(1);
        this.delegate.setThreadNamePrefix("scheduling-");
        this.delegate.setRemoveOnCancelPolicy(true);
        this.delegate.initialize();
    }

    /** 清空窗口内静默跳过本轮执行（下一周期照常），否则原样执行。 */
    private Runnable gated(Runnable task) {
        return () -> {
            if (drainGate.blockingNewRequests()) {
                return;
            }
            task.run();
        };
    }

    @Override
    public ScheduledFuture<?> schedule(Runnable task, Trigger trigger) {
        return delegate.schedule(gated(task), trigger);
    }

    @Override
    public ScheduledFuture<?> schedule(Runnable task, Instant startTime) {
        return delegate.schedule(gated(task), startTime);
    }

    @Override
    public ScheduledFuture<?> scheduleAtFixedRate(
            Runnable task, Instant startTime, Duration period) {
        return delegate.scheduleAtFixedRate(gated(task), startTime, period);
    }

    @Override
    public ScheduledFuture<?> scheduleAtFixedRate(Runnable task, Duration period) {
        return delegate.scheduleAtFixedRate(gated(task), period);
    }

    @Override
    public ScheduledFuture<?> scheduleWithFixedDelay(
            Runnable task, Instant startTime, Duration delay) {
        return delegate.scheduleWithFixedDelay(gated(task), startTime, delay);
    }

    @Override
    public ScheduledFuture<?> scheduleWithFixedDelay(Runnable task, Duration delay) {
        return delegate.scheduleWithFixedDelay(gated(task), delay);
    }

    @Override
    public void destroy() {
        delegate.shutdown();
    }
}
