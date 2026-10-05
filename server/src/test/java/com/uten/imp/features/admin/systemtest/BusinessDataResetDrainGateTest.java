package com.uten.imp.features.admin.systemtest;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** beginDrain tells "another reset is running" apart from "in-flight requests did not finish" (ADR-155 E1a/E1b). */
class BusinessDataResetDrainGateTest {
    @Test
    void beginDrainReportsEachOutcomeAndOnlyStartedKeepsTheGate() throws Exception {
        var gate = new BusinessDataResetDrainGate();
        assertEquals(BusinessDataResetDrainGate.DrainOutcome.STARTED, gate.beginDrain(100));
        assertTrue(gate.blockingNewRequests());
        assertEquals(BusinessDataResetDrainGate.DrainOutcome.ANOTHER_RESET, gate.beginDrain(100));
        assertTrue(gate.blockingNewRequests(), "a refused second reset must not release the first one");
        gate.endReset();
        assertFalse(gate.blockingNewRequests());

        assertTrue(gate.tryEnter());
        assertEquals(BusinessDataResetDrainGate.DrainOutcome.IN_FLIGHT_TIMEOUT, gate.beginDrain(50));
        assertFalse(gate.blockingNewRequests(), "a timed-out drain reopens traffic");
        gate.leave();
        assertEquals(BusinessDataResetDrainGate.DrainOutcome.STARTED, gate.beginDrain(100));
        gate.endReset();
    }
}
