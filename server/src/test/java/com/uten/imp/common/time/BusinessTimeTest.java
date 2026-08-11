package com.uten.imp.common.time;

import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneOffset;

import static org.junit.jupiter.api.Assertions.assertEquals;

class BusinessTimeTest {

    @Test
    void businessDayStartsAtMidnightInAsiaShanghai() {
        LocalDate date = LocalDate.of(2026, 1, 1);

        assertEquals(
                ZoneOffset.ofHours(8),
                BusinessTime.startOfDay(date).getOffset());
        assertEquals(
                Instant.parse("2025-12-31T16:00:00Z"),
                BusinessTime.startOfDayInstant(date));
    }

    @Test
    void todayDoesNotDependOnTheJvmDefaultTimeZone() {
        assertEquals(LocalDate.now(BusinessTime.ZONE), BusinessTime.today());
    }
}
