package com.uten.imp.features.sales.shipment;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;

class SalesShipmentFinanceGatePolicyTest {

    @Test
    void allV1CustomersRequireFinanceApprovalBeforeWarehouseWork() {
        SalesShipment monthly = shipment((short) 1, (short) 0);
        assertThatThrownBy(() -> SalesShipmentService.assertFinanceAudited(monthly))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("所有客户出货均须先完成财务审核");

        SalesShipment deposit = shipment((short) 1, (short) 1);
        assertDoesNotThrow(() -> SalesShipmentService.assertFinanceAudited(deposit));
    }

    @Test
    void historicalCompatibilityDoesNotFabricateApproval() {
        SalesShipment historical = shipment((short) 0, (short) 0);
        historical.setWarehouseWorkStatus(SalesShipment.WORK_LEGACY_PENDING);
        assertDoesNotThrow(() -> SalesShipmentService.assertFinanceAudited(historical));

        historical.setWarehouseWorkStatus(SalesShipment.WORK_PENDING_PICK);
        assertThatThrownBy(() -> SalesShipmentService.assertFinanceAudited(historical))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("所有客户出货均须先完成财务审核");
    }

    @Test
    void financeReleaseRequiresAValidManualCustomerClassification() {
        assertDoesNotThrow(() ->
                SalesShipmentService.requireClassifiedSalesPaymentType("MONTHLY"));
        assertDoesNotThrow(() ->
                SalesShipmentService.requireClassifiedSalesPaymentType("CASH"));
        assertDoesNotThrow(() ->
                SalesShipmentService.requireClassifiedSalesPaymentType("DEPOSIT"));

        assertThatThrownBy(() ->
                SalesShipmentService.requireClassifiedSalesPaymentType(null))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("客户货款类型尚未分类");
        assertThatThrownBy(() ->
                SalesShipmentService.requireClassifiedSalesPaymentType("UNKNOWN"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("客户货款类型无效");
    }

    private static SalesShipment shipment(short gateVersion, short financeAudit) {
        SalesShipment shipment = new SalesShipment();
        shipment.setFinanceGateVersion(gateVersion);
        shipment.setFinanceAudit(financeAudit);
        return shipment;
    }
}
