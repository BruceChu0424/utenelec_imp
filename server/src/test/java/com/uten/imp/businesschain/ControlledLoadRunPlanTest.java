package com.uten.imp.businesschain;

import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.*;

class ControlledLoadRunPlanTest {
    @Test void defaultsAreShortAndBounded() {
        var plan = ControlledLoadRunPlan.from(Map.of());
        assertEquals(60, plan.durationSeconds()); assertEquals(12, plan.maxSamples());
        assertEquals(1, plan.maxInFlight()); assertEquals(ControlledLoadRunPlan.Background.QUIET, plan.background());
    }
    @Test void extendedDurationNeedsOptInAndStillCannotExceedHardCaps() {
        assertThrows(IllegalArgumentException.class, () -> ControlledLoadRunPlan.from(Map.of("UTEN_WINDOW_DURATION_SECONDS", "1800")));
        assertEquals(1800, ControlledLoadRunPlan.from(Map.of("UTEN_WINDOW_DURATION_SECONDS", "1800", "UTEN_WINDOW_ALLOW_EXTENDED", "true")).durationSeconds());
        for (var limit : Map.of("DURATION_SECONDS", "3601", "MAX_SAMPLES", "2001", "MAX_IN_FLIGHT", "9", "RATE", "2.1", "READY_CAPACITY", "17", "DATABASE_LIMIT_MIB", "4097").entrySet()) {
            assertThrows(IllegalArgumentException.class, () -> ControlledLoadRunPlan.from(Map.of("UTEN_WINDOW_" + limit.getKey(), limit.getValue(), "UTEN_WINDOW_ALLOW_EXTENDED", "true")));
        }
    }
    @Test void invalidRatesScenariosAndMisleadingSampleThresholdsAreRejected() {
        for (String rate : new String[]{"NaN", "Infinity", "0", "-1"})
            assertThrows(IllegalArgumentException.class, () -> ControlledLoadRunPlan.from(Map.of("UTEN_WINDOW_RATE", rate)));
        for (String scenarios : new String[]{"", "production", "draw-1,draw-1"})
            assertThrows(IllegalArgumentException.class, () -> ControlledLoadRunPlan.from(Map.of("UTEN_WINDOW_SCENARIOS", scenarios)));
        assertThrows(IllegalArgumentException.class, () -> ControlledLoadRunPlan.from(Map.of("UTEN_WINDOW_MIN_SAMPLES", "13")));
    }
}
