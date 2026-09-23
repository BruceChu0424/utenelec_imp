package com.uten.imp.features.sales;

import com.uten.imp.features.sales.order.SalesOrderController;
import com.uten.imp.features.sales.order.SalesOrderService;
import com.uten.imp.features.sales.order.dto.PartialShipmentConfirmationRequest;
import com.uten.imp.features.sales.shipment.SalesShipmentController;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import com.uten.imp.features.sales.shipment.dto.WarehouseWorkTransitionRequest;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;

import java.lang.reflect.Method;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class SalesShipmentPolicySecurityContractTest {

    @Test
    void partialShipmentConfirmationIsGuardedAtControllerAndService() throws Exception {
        assertPreAuthorize(
                SalesOrderController.class.getMethod(
                        "setPartialShipmentConfirmation",
                        UUID.class,
                        PartialShipmentConfirmationRequest.class),
                "hasAuthority('sales_order:confirm_partial_shipment')");
        assertPreAuthorize(
                SalesOrderService.class.getMethod(
                        "setPartialShipmentConfirmation",
                        UUID.class,
                        PartialShipmentConfirmationRequest.class),
                "hasAuthority('sales_order:confirm_partial_shipment')");
    }

    @Test
    void warehouseExecutionHasOneWriteEntryGuardedByViewAndExecute() throws Exception {
        // permissions-09：销售出货控制器里重复的仓库作业写入口已删除，只剩仓库销售出库一个入口。
        assertThrows(NoSuchMethodException.class, () -> SalesShipmentController.class.getMethod(
                "transitionWarehouseWork",
                UUID.class,
                WarehouseWorkTransitionRequest.class));
        assertPreAuthorize(
                SalesShipmentService.class.getMethod(
                        "transitionWarehouseWork",
                        UUID.class,
                        WarehouseWorkTransitionRequest.class),
                "hasAuthority('warehouse_sales_outbound:view') and hasAuthority('warehouse_sales_outbound:execute')");
    }

    private static void assertPreAuthorize(Method method, String expected) {
        assertEquals(expected, method.getAnnotation(PreAuthorize.class).value());
    }
}
