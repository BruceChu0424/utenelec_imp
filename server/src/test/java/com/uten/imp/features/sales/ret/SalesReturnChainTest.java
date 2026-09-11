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
        // V545 统一派生：全发后退 2 → 未交付 2、已发 > 0 → 8 部分发货；
        // 缺口 2 按剩余未排量回到调度待排列表/待生产大类（数量口径，不依赖 chain=2）。
        assertEquals((short) 8, SalesReturnService.chainAfterReturn(
                (short) 9, bd("10"), bd("10"), bd("2"), bd("0"),
                bd("0"), bd("10"), bd("10")));
        assertEquals((short) 9, SalesReturnService.chainAfterReturn(
                (short) 8, bd("10"), bd("10"), bd("0"), bd("0"),
                bd("0"), bd("10"), bd("10")));
    }

    @Test
    void returnBeforeAnyShipmentGoesBackToPendingPlan() {
        // 未发过货的行（如出货驳回后退回）：未交付 10、无预留、计划已全部完工 → 2 待排产。
        assertEquals((short) 2, SalesReturnService.chainAfterReturn(
                (short) 7, bd("10"), bd("0"), bd("0"), bd("0"),
                bd("0"), bd("10"), bd("10")));
        // 剩余未排量优先：已排 4 产 0，未排 6 → 仍待排产，不进 4。
        assertEquals((short) 2, SalesReturnService.chainAfterReturn(
                (short) 4, bd("10"), bd("0"), bd("0"), bd("0"),
                bd("0"), bd("4"), bd("0")));
    }

    @Test
    void flaggedQuantityUsesTheSameOutstandingFormula() {
        assertEquals((short) 9, SalesReturnService.chainAfterReturn(
                (short) 9, bd("10"), bd("10"), bd("2"), bd("2"),
                bd("0"), bd("10"), bd("10")));
    }

    @Test
    void reopenedDemandReflectsReservationAndUnfinishedPlan() {
        // 退 2 且预留 2 覆盖未交付 → 7 可发货（预留优先于部分发货）。
        assertEquals((short) 7, SalesReturnService.chainAfterReturn(
                (short) 9, bd("10"), bd("10"), bd("2"), bd("0"),
                bd("2"), bd("10"), bd("10")));
        // 退 2 已补排 2（planned 12 / produced 10）：未排 0，已发 > 0 → 8 部分发货。
        assertEquals((short) 8, SalesReturnService.chainAfterReturn(
                (short) 9, bd("10"), bd("10"), bd("2"), bd("0"),
                bd("0"), bd("12"), bd("10")));
        // 未发货的生产中行退货红冲后：未排 0、未入库、原值 5 → 保留 5。
        assertEquals((short) 5, SalesReturnService.chainAfterReturn(
                (short) 5, bd("10"), bd("0"), bd("0"), bd("0"),
                bd("0"), bd("10"), bd("0")));
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
