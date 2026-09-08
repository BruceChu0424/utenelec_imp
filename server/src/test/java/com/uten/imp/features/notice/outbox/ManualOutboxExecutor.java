package com.uten.imp.features.notice.outbox;

import java.util.ArrayDeque;
import java.util.List;
import java.util.concurrent.AbstractExecutorService;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.TimeUnit;

/** Deterministic one-slot executor: queuing and actual execution are separate. */
final class ManualOutboxExecutor extends AbstractExecutorService {
    private final ArrayDeque<Runnable> tasks = new ArrayDeque<>();
    private boolean shutdown;
    private int submitted;

    @Override public synchronized void execute(Runnable task) {
        if (shutdown || !tasks.isEmpty()) throw new RejectedExecutionException();
        submitted++;
        tasks.add(task);
    }
    synchronized int queued() { return tasks.size(); }
    synchronized int submitted() { return submitted; }
    void runOne() {
        Runnable task;
        synchronized (this) { task = tasks.remove(); }
        task.run();
    }
    @Override public synchronized void shutdown() { shutdown = true; tasks.clear(); }
    @Override public synchronized List<Runnable> shutdownNow() {
        List<Runnable> remaining = List.copyOf(tasks);
        shutdown();
        return remaining;
    }
    @Override public synchronized boolean isShutdown() { return shutdown; }
    @Override public synchronized boolean isTerminated() { return shutdown; }
    @Override public boolean awaitTermination(long timeout, TimeUnit unit) { return isTerminated(); }
}
