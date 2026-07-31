package com.uten.imp.features.sales.ret;

import org.junit.jupiter.api.Test;
import com.uten.imp.common.web.ApiException;

import java.math.BigDecimal;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.assertThrows;

class SalesReturnChainTest {

    @Test
    void returnAfterFullShipmentReopensDemandAndReverseClosesItAgain() {
        assertEquals((short) 2, SalesReturnService.chainAfterReturn(
                (short) 9, bd("10"), bd("10"), bd("2"), bd("0"),
                bd("0"), bd("10"), bd("10")));
        assertEquals((short) 9, SalesReturnService.chainAfterReturn(
                (short) 2, bd("10"), bd("10"), bd("0"), bd("0"),
                bd("0"), bd("10"), bd("10")));
    }

    @Test
    void flaggedQuantityUsesTheSameOutstandingFormula() {
        assertEquals((short) 9, SalesReturnService.chainAfterReturn(
                (short) 9, bd("10"), bd("10"), bd("2"), bd("2"),
                bd("0"), bd("10"), bd("10")));
    }

    @Test
    void reopenedDemandReflectsReservationAndUnfinishedPlan() {
        assertEquals((short) 7, SalesReturnService.chainAfterReturn(
                (short) 9, bd("10"), bd("10"), bd("2"), bd("0"),
                bd("2"), bd("10"), bd("10")));
        assertEquals((short) 4, SalesReturnService.chainAfterReturn(
                (short) 9, bd("10"), bd("10"), bd("2"), bd("0"),
                bd("0"), bd("12"), bd("10")));
        assertEquals((short) 5, SalesReturnService.chainAfterReturn(
                (short) 5, bd("10"), bd("8"), bd("1"), bd("0"),
                bd("0"), bd("10"), bd("8")));
    }

    @Test
    void legacyOrCanceledRowsAreNotSilentlyPutOnTheNewChain() {
        assertEquals((short) 0, SalesReturnService.chainAfterReturn(
                (short) 0, bd("10"), bd("10"), bd("2"), bd("0"),
                bd("0"), bd("10"), bd("10")));
        assertEquals((short) -1, SalesReturnService.chainAfterReturn(
                (short) -1, bd("10"), bd("10"), bd("2"), bd("0"),
                bd("0"), bd("10"), bd("10")));
    }


    @Test
    void returnReverseRejectsUnfinishedReplacementPlan() {
        assertFalse(SalesReturnService.canReverseWithoutStrandingCommitment(
                bd("10"), bd("10"), bd("2"), bd("0"),
                bd("0"), bd("12"), bd("10"), bd("2")));
    }

    @Test
    void returnReverseRejectsReservationThatWouldExceedPostOutstanding() {
        assertFalse(SalesReturnService.canReverseWithoutStrandingCommitment(
                bd("10"), bd("10"), bd("2"), bd("0"),
                bd("1"), bd("10"), bd("10"), bd("2")));
    }

    @Test
    void returnReverseAllowsClosingWhenNoDownstreamCommitmentRemains() {
        assertTrue(SalesReturnService.canReverseWithoutStrandingCommitment(
                bd("10"), bd("10"), bd("2"), bd("0"),
                bd("0"), bd("10"), bd("10"), bd("2")));
    }

    @Test
    void returnReverseRejectsProducedGreaterThanPlannedLedger() {
        assertFalse(SalesReturnService.canReverseWithoutStrandingCommitment(
                bd("10"), bd("10"), bd("2"), bd("0"),
                bd("0"), bd("9"), bd("10"), bd("2")));
    }

    @Test
    void linkedDimensionRequiresExactColorUnitAndPositiveRate() {
        UUID goodsId = UUID.randomUUID();
        UUID colorId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        SalesReturnService.requireLinkedDimension(
                goodsId, colorId, unitId, BigDecimal.ONE,
                goodsId, colorId, unitId, BigDecimal.ONE, "退货");

        assertThrows(ApiException.class, () -> SalesReturnService.requireLinkedDimension(
                goodsId, colorId, unitId, BigDecimal.ONE,
                goodsId, UUID.randomUUID(), unitId, BigDecimal.ONE, "退货"));
        assertThrows(ApiException.class, () -> SalesReturnService.requireLinkedDimension(
                goodsId, colorId, unitId, null,
                goodsId, colorId, unitId, BigDecimal.ONE, "退货"));
    }
    private static BigDecimal bd(String value) {
        return new BigDecimal(value);
    }
}
