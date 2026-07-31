package com.uten.imp.features.stock;

import com.uten.imp.features.stock.dto.StockBalanceAdjustmentRequest;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;

import java.lang.reflect.Method;

import static org.junit.jupiter.api.Assertions.assertEquals;

class StockBalanceAdjustmentControllerSecurityTest {

    @Test
    void adjustmentEndpointRequiresDedicatedNarrowPermission() throws Exception {
        Method method = StockBalanceAdjustmentController.class.getDeclaredMethod(
                "adjust", StockBalanceAdjustmentRequest.class);
        PreAuthorize authorization = method.getAnnotation(PreAuthorize.class);

        assertEquals(
                "hasAuthority('stock:balance:adjust')",
                authorization.value());

        Method serviceMethod = StockBalanceAdjustmentService.class.getDeclaredMethod(
                "adjust", StockBalanceAdjustmentRequest.class);
        PreAuthorize serviceAuthorization = serviceMethod.getAnnotation(PreAuthorize.class);
        assertEquals(
                "hasAuthority('stock:balance:adjust')",
                serviceAuthorization.value());
    }
}
