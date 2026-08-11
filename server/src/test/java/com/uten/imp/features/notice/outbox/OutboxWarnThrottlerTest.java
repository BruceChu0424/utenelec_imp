package com.uten.imp.features.notice.outbox;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class OutboxWarnThrottlerTest {

    private static final long WINDOW_MS = 5 * 60 * 1000L;

    private AtomicLong clock;
    private OutboxWarnThrottler throttler;

    @BeforeEach
    void setUp() {
        clock = new AtomicLong(1_000_000L);
        throttler = new OutboxWarnThrottler(WINDOW_MS, clock::get);
    }

    @Test
    void firstOccurrenceEmitsVerbatim() {
        assertEquals("connection refused", throttler.consume("connection refused"));
    }

    @Test
    void sameMessageInsideWindowIsSuppressed() {
        throttler.consume("connection refused");
        clock.addAndGet(1000);
        assertNull(throttler.consume("connection refused"));
        clock.addAndGet(2000);
        assertNull(throttler.consume("connection refused"));
    }

    @Test
    void firstEmitAfterWindowCarriesSuppressedCount() {
        throttler.consume("connection refused");
        for (int i = 0; i < 7; i++) {
            clock.addAndGet(2000);
            throttler.consume("connection refused");
        }
        clock.addAndGet(WINDOW_MS);
        String line = throttler.consume("connection refused");
        assertTrue(line.startsWith("connection refused"));
        assertTrue(line.contains("7"), "should carry the silent count: " + line);
    }

    @Test
    void differentMessageEmitsImmediatelyAndFlushesCount() {
        throttler.consume("connection refused");
        clock.addAndGet(1000);
        throttler.consume("connection refused"); // suppressed

        String line = throttler.consume("timeout reading channel");
        assertTrue(line.startsWith("timeout reading channel"));
        assertTrue(line.contains("1"), "switching message flushes the count: " + line);
    }

    @Test
    void nullMessageIsHandled() {
        assertEquals("null", throttler.consume(String.valueOf((String) null)));
        clock.addAndGet(1000);
        assertNull(throttler.consume(String.valueOf((String) null)));
    }

    @Test
    void counterResetsAfterBeingFlushed() {
        throttler.consume("boom");
        clock.addAndGet(1000);
        throttler.consume("boom"); // suppressed, count = 1
        clock.addAndGet(WINDOW_MS);
        throttler.consume("boom"); // emits with count, resets
        clock.addAndGet(1000);
        assertNull(throttler.consume("boom")); // suppressed again, count = 1
        clock.addAndGet(WINDOW_MS);
        String line = throttler.consume("boom");
        assertTrue(line.contains("1"), "count must restart after flush: " + line);
    }
}
