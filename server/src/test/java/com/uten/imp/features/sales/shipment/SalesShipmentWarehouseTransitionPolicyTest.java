package com.uten.imp.features.sales.shipment;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import java.time.OffsetDateTime;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class SalesShipmentWarehouseTransitionPolicyTest {

    @Test
    void acceptsOnlyDocumentedForwardAndRecoveryTransitions() {
        List<String[]> allowed = List.of(
                row(SalesShipment.WORK_PENDING_PICK, SalesShipment.WORK_PICKING, ""),
                row(SalesShipment.WORK_PICKING, SalesShipment.WORK_PICKED, ""),
                row(SalesShipment.WORK_PENDING_PICK, SalesShipment.WORK_EXCEPTION, "缺货"),
                row(SalesShipment.WORK_PICKING, SalesShipment.WORK_EXCEPTION, "货损"),
                row(SalesShipment.WORK_PICKED, SalesShipment.WORK_EXCEPTION, "复核不符"),
                row(SalesShipment.WORK_EXCEPTION, SalesShipment.WORK_PENDING_PICK, "已退拣复位"),
                row(SalesShipment.WORK_PICKED, SalesShipment.WORK_SHIPPED, ""));

        for (String[] transition : allowed) {
            assertDoesNotThrow(() ->
                    SalesShipmentService.validateWarehouseTransition(
                            transition[0], transition[1], transition[2]));
        }
    }

    @Test
    void staleOrSkippedStateFailsClosed() {
        ApiException error = assertThrows(
                ApiException.class,
                () -> SalesShipmentService.validateWarehouseTransition(
                        SalesShipment.WORK_PENDING_PICK,
                        SalesShipment.WORK_SHIPPED,
                        ""));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
    }

    @Test
    void exceptionAndRecoveryRequireAnAuditableReason() {
        ApiException exception = assertThrows(
                ApiException.class,
                () -> SalesShipmentService.validateWarehouseTransition(
                        SalesShipment.WORK_PICKING,
                        SalesShipment.WORK_EXCEPTION,
                        " "));
        assertEquals(ErrorCode.VALIDATION_FAILED, exception.getCode());

        ApiException recovery = assertThrows(
                ApiException.class,
                () -> SalesShipmentService.validateWarehouseTransition(
                        SalesShipment.WORK_EXCEPTION,
                        SalesShipment.WORK_PENDING_PICK,
                        null));
        assertEquals(ErrorCode.VALIDATION_FAILED, recovery.getCode());
    }

    @Test
    void arbitraryClientStatusIsRejected() {
        ApiException error = assertThrows(
                ApiException.class,
                () -> SalesShipmentService.validateWarehouseTransition(
                        SalesShipment.WORK_PENDING_PICK,
                        "ADMIN_FORCE_SHIP",
                        "client supplied"));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
    }

    @Test
    void financeAuditCannotChangeAfterPhysicalWarehouseWorkStarts() {
        SalesShipment pending = shipment((short) 0, SalesShipment.WORK_PENDING_PICK);
        SalesShipment legacy = shipment((short) 0, SalesShipment.WORK_LEGACY_PENDING);
        assertDoesNotThrow(() ->
                SalesShipmentService.requireFinanceAuditEditableState(pending));
        ApiException legacyReadOnly = assertThrows(
                ApiException.class,
                () -> SalesShipmentService.requireFinanceAuditEditableState(legacy));
        assertEquals(ErrorCode.CONFLICT, legacyReadOnly.getCode());

        ApiException started = assertThrows(
                ApiException.class,
                () -> SalesShipmentService.requireFinanceAuditEditableState(
                        shipment((short) 0, SalesShipment.WORK_PICKING)));
        assertEquals(ErrorCode.CONFLICT, started.getCode());

        ApiException shipped = assertThrows(
                ApiException.class,
                () -> SalesShipmentService.requireFinanceAuditEditableState(
                        shipment((short) 1, SalesShipment.WORK_SHIPPED)));
        assertEquals(ErrorCode.CONFLICT, shipped.getCode());
    }

    @Test
    void shippedOrHandedOverGoodsCannotBeTurnedIntoInventoryByDirectReversal() {
        SalesShipment legacy = shipment((short) 1, SalesShipment.WORK_SHIPPED);
        ApiException historical = assertThrows(
                ApiException.class,
                () -> SalesShipmentService.requireDirectReversalAllowed(legacy));
        assertEquals(ErrorCode.CONFLICT, historical.getCode());

        SalesShipment handedOver = shipment((short) 1, SalesShipment.WORK_SHIPPED);
        handedOver.setHandedOverAt(OffsetDateTime.now());
        ApiException error = assertThrows(
                ApiException.class,
                () -> SalesShipmentService.requireDirectReversalAllowed(handedOver));
        assertEquals(ErrorCode.CONFLICT, error.getCode());
    }

    @Test
    void financeApprovedDraftMustBeReversedBeforeCommercialMutation() {
        SalesShipment shipment =
                shipment((short) 0, SalesShipment.WORK_PENDING_PICK);
        shipment.setFinanceAudit((short) 1);

        ApiException error = assertThrows(
                ApiException.class,
                () -> SalesShipmentService
                        .requireFinanceAuditClearedForMutation(shipment));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
    }

    @Test
    void legacyPendingDirectApprovalIsReadOnlyAndCannotCreateInventoryOrArFacts() {
        SalesShipment legacy = shipment((short) 0, SalesShipment.WORK_LEGACY_PENDING);

        ApiException error = assertThrows(
                ApiException.class,
                () -> SalesShipmentService.rejectRetiredDirectApproval(legacy));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        org.assertj.core.api.Assertions.assertThat(error.getMessage())
                .contains("已转为只读")
                .contains("按当前订单关联流程重新开单");

        ApiException mutation = assertThrows(
                ApiException.class,
                () -> SalesShipmentService.requireLegacyShipmentMutable(legacy));
        assertEquals(ErrorCode.CONFLICT, mutation.getCode());
        org.assertj.core.api.Assertions.assertThat(mutation.getMessage())
                .contains("只读迁移异常")
                .contains("两审流程重新开单");
    }

    @Test
    void newWarehouseFlowRejectsUnreconciledHistoricalOrderChain() {
        ApiException error = assertThrows(
                ApiException.class,
                () -> SalesShipmentService
                        .requireActivatedReservationChain(true, 0));
        assertEquals(ErrorCode.CONFLICT, error.getCode());

        assertDoesNotThrow(() -> SalesShipmentService
                .requireActivatedReservationChain(false, 0));
        assertDoesNotThrow(() -> SalesShipmentService
                .requireActivatedReservationChain(true, 2));
    }

    private static String[] row(String current, String target, String reason) {
        return new String[]{current, target, reason};
    }

    private static SalesShipment shipment(short status, String workStatus) {
        SalesShipment shipment = new SalesShipment();
        shipment.setStatus(status);
        shipment.setWarehouseWorkStatus(workStatus);
        return shipment;
    }
}
