package com.uten.imp.features.sales.shipment;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

/**
 * V582 一步式仓库作业拓扑：仓库侧唯一合法转移是
 * {@code PENDING_PICK → SHIPPED}（财务放行后一次「确认出库」完成选仓/校验/扣账）。
 * 旧四步中间态 PICKING/PICKED/EXCEPTION 连同退拣回路已整体删除
 * （既不占库存也不产生会计事实）；旧目标态重放按 VALIDATION_FAILED 拒绝。
 */
class SalesShipmentWarehouseTransitionPolicyTest {

    @Test
    void acceptsOnlyTheOneStepPendingPickToShippedTransition() {
        assertDoesNotThrow(() ->
                SalesShipmentService.validateWarehouseTransition(
                        SalesShipment.WORK_PENDING_PICK,
                        SalesShipment.WORK_SHIPPED,
                        ""));
    }

    @Test
    void legacyIntermediateTargetsAreRejectedAsValidationFailures() {
        // V582 之前的中间态不再有实物/会计语义——明确拒绝而非静默兼容。
        for (String legacyTarget : new String[] {"PICKING", "PICKED", "EXCEPTION"}) {
            ApiException error = assertThrows(
                    ApiException.class,
                    () -> SalesShipmentService.validateWarehouseTransition(
                            SalesShipment.WORK_PENDING_PICK, legacyTarget, ""));
            assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        }
    }

    @Test
    void nonShippedTargetsFailClosed() {
        ApiException cancelled = assertThrows(
                ApiException.class,
                () -> SalesShipmentService.validateWarehouseTransition(
                        SalesShipment.WORK_PENDING_PICK,
                        SalesShipment.WORK_CANCELLED,
                        ""));
        assertEquals(ErrorCode.VALIDATION_FAILED, cancelled.getCode());

        ApiException reversed = assertThrows(
                ApiException.class,
                () -> SalesShipmentService.validateWarehouseTransition(
                        SalesShipment.WORK_PENDING_PICK,
                        SalesShipment.WORK_REVERSED,
                        ""));
        assertEquals(ErrorCode.VALIDATION_FAILED, reversed.getCode());
    }
}
