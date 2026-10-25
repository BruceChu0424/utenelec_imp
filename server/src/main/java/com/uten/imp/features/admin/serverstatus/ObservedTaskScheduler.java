package com.uten.imp.features.admin.serverstatus;

import org.springframework.beans.factory.DisposableBean;
import org.springframework.context.annotation.Profile;
import org.springframework.context.ApplicationContext;
import org.springframework.context.ApplicationContextAware;
import org.springframework.context.ApplicationListener;
import org.springframework.context.SmartLifecycle;
import org.springframework.context.event.ContextClosedEvent;
import org.springframework.scheduling.TaskScheduler;
import org.springframework.scheduling.Trigger;
import org.springframework.scheduling.concurrent.ThreadPoolTaskScheduler;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.time.Instant;
import java.util.concurrent.ScheduledFuture;

/**
 * Single-thread scheduler that records task execution for the server status page.
 * The delegate participates in Spring shutdown so active work finishes before its dependencies
 * are destroyed, while queued delayed work is discarded.
 */
@Component
@Profile("!cloud")
public class ObservedTaskScheduler implements TaskScheduler, DisposableBean, SmartLifecycle,
        ApplicationContextAware, ApplicationListener<ContextClosedEvent> {

    private final ScheduledTaskRunRegistry runRegistry;
    private final ThreadPoolTaskScheduler delegate;

    public ObservedTaskScheduler(ScheduledTaskRunRegistry runRegistry) {
        this.runRegistry = runRegistry;
        this.delegate = new ThreadPoolTaskScheduler();
        // 单线程: 任一任务在跑, 其余任务只能排队。ServerStatusProbe.jobReports 据此把
        // 「有任务占线时的没执行」记为排队而不是故障; 改池大小须同步改那边的判定。
        this.delegate.setPoolSize(1);
        this.delegate.setThreadNamePrefix("scheduling-");
        this.delegate.setRemoveOnCancelPolicy(true);
        this.delegate.setExecuteExistingDelayedTasksAfterShutdownPolicy(false);
        this.delegate.setContinueExistingPeriodicTasksAfterShutdownPolicy(false);
        this.delegate.initialize();
    }

    /** Record each execution without changing the task cadence. */
    private Runnable observed(Runnable task, Duration period) {
        String name = runRegistry.register(task, period);
        return () -> {
            runRegistry.started(name, Instant.now());
            try {
                task.run();
                runRegistry.finished(name, Instant.now(), null);
            } catch (RuntimeException | Error failure) {
                runRegistry.finished(name, Instant.now(), failure);
                throw failure;
            }
        };
    }

    @Override
    public ScheduledFuture<?> schedule(Runnable task, Trigger trigger) {
        return delegate.schedule(observed(task, null), trigger);
    }

    @Override
    public ScheduledFuture<?> schedule(Runnable task, Instant startTime) {
        return delegate.schedule(observed(task, null), startTime);
    }

    @Override
    public ScheduledFuture<?> scheduleAtFixedRate(
            Runnable task, Instant startTime, Duration period) {
        return delegate.scheduleAtFixedRate(observed(task, period), startTime, period);
    }

    @Override
    public ScheduledFuture<?> scheduleAtFixedRate(Runnable task, Duration period) {
        return delegate.scheduleAtFixedRate(observed(task, period), period);
    }

    @Override
    public ScheduledFuture<?> scheduleWithFixedDelay(
            Runnable task, Instant startTime, Duration delay) {
        return delegate.scheduleWithFixedDelay(observed(task, delay), startTime, delay);
    }

    @Override
    public ScheduledFuture<?> scheduleWithFixedDelay(Runnable task, Duration delay) {
        return delegate.scheduleWithFixedDelay(observed(task, delay), delay);
    }

    @Override
    public void setApplicationContext(ApplicationContext applicationContext) {
        delegate.setApplicationContext(applicationContext);
    }

    @Override
    public void onApplicationEvent(ContextClosedEvent event) {
        // The delegate checks context identity, so closing an unrelated child
        // context cannot stop the application's scheduler.
        delegate.onApplicationEvent(event);
    }

    @Override
    public boolean isAutoStartup() {
        return delegate.isAutoStartup();
    }

    @Override
    public int getPhase() {
        return delegate.getPhase();
    }

    @Override
    public void start() {
        delegate.start();
    }

    @Override
    public void stop() {
        delegate.stop();
    }

    @Override
    public void stop(Runnable callback) {
        // Spring invokes the callback after admitted tasks finish and applies
        // its existing bounded phase timeout before destroying dependencies.
        delegate.stop(callback);
    }

    @Override
    public boolean isRunning() {
        return delegate.isRunning();
    }

    @Override
    public void destroy() {
        delegate.shutdown();
    }
}
