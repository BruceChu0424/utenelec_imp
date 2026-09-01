package com.uten.imp.features.warehouse.inbound;

import org.junit.jupiter.api.Test;

import static com.uten.imp.features.warehouse.inbound.ProcurementInspectionService.ReplayNotification.NONE;
import static com.uten.imp.features.warehouse.inbound.ProcurementInspectionService.ReplayNotification.REJECTION_DETECTED;
import static com.uten.imp.features.warehouse.inbound.ProcurementInspectionService.ReplayNotification.STOCK_IN_PENDING;
import static org.assertj.core.api.Assertions.assertThat;

class ProcurementInspectionReplayPolicyTest {

    @Test
    void replayRoutesOnlyNewPassToWarehouseAndOnlyFailToRejection() {
        assertThat(ProcurementInspectionService.replayNotification("PASS", true))
                .isEqualTo(STOCK_IN_PENDING);
        assertThat(ProcurementInspectionService.replayNotification("PASS", false))
                .isEqualTo(NONE);
        assertThat(ProcurementInspectionService.replayNotification("FAIL", false))
                .isEqualTo(REJECTION_DETECTED);
    }
}
