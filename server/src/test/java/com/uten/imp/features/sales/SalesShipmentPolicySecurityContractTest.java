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
    void warehouseExecutionIsGuardedAtControllerAndService() throws Exception {
        assertPreAuthorize(
                SalesShipmentController.class.getMethod(
                        "transitionWarehouseWork",
                        UUID.class,
                        WarehouseWorkTransitionRequest.class),
                "hasAuthority('sales_shipment:warehouse-work')");
        assertPreAuthorize(
                SalesShipmentService.class.getMethod(
                        "transitionWarehouseWork",
                        UUID.class,
                        WarehouseWorkTransitionRequest.class),
                "hasAuthority('sales_shipment:warehouse-work')");
    }

    private static void assertPreAuthorize(Method method, String expected) {
        assertEquals(expected, method.getAnnotation(PreAuthorize.class).value());
    }
}
