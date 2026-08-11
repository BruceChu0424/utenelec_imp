package com.uten.imp.features.notice.outbox;

import java.util.function.LongSupplier;

/**
 * Rate-limits repeated outbox delivery warnings: the same message is emitted at
 * most once per quiet window; repeats inside the window are counted silently and
 * the count rides on the next emitted warning.
 *
 * <p>Background: {@link BusinessOutboxScheduler} polls every 2s and processes up
 * to 20 events per cycle. A sustained downstream outage with backlog would
 * otherwise emit up to 20 identical WARN lines per cycle indefinitely, drowning
 * actionable logs. Delivery failures are already persisted via {@link
 * BusinessOutboxFailureRecorder}, so suppressed warnings lose no information.
 */
final class OutboxWarnThrottler {

    static final long DEFAULT_WINDOW_MS = 5 * 60 * 1000L;

    private final long windowMs;
    private final LongSupplier clock;

    private String lastMessage;
    private long lastLoggedAtMs = Long.MIN_VALUE;
    private int suppressed;

    OutboxWarnThrottler(long windowMs, LongSupplier clock) {
        this.windowMs = windowMs;
        this.clock = clock;
    }

    static OutboxWarnThrottler withDefaults() {
        return new OutboxWarnThrottler(DEFAULT_WINDOW_MS, System::currentTimeMillis);
    }

    /**
     * Returns the line to log for {@code message}, or {@code null} when this
     * repeat is suppressed inside the quiet window. The first line emitted after
     * a suppressed stretch carries the silent count.
     */
    synchronized String consume(String message) {
        long now = clock.getAsLong();
        if (message.equals(lastMessage) && now - lastLoggedAtMs < windowMs) {
            suppressed++;
            return null;
        }
        int carried = suppressed;
        suppressed = 0;
        lastMessage = message;
        lastLoggedAtMs = now;
        return carried > 0 ? message + "（同期相同告警已静默 " + carried + " 条）" : message;
    }
}
