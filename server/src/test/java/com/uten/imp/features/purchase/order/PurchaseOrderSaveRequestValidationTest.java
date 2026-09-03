package com.uten.imp.features.purchase.order;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.purchase.order.dto.OrderItemLine;
import com.uten.imp.features.purchase.order.dto.OrderSaveRequest;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class PurchaseOrderSaveRequestValidationTest {

    private final Validator validator =
            Validation.buildDefaultValidatorFactory().getValidator();

    @Test
    void settlementMovesFromBeanValidationToServiceRuntimeCheck() {
        // 2026-09 行级商业条款：批量拆单请求头不携带结账方式，@NotNull 改为
        // 单张路径的运行时校验（requireHeaderSettlement），bean validation 不再拦截。
        OrderSaveRequest request = validRequest();

        assertFalse(validator.validate(request).stream().anyMatch(violation ->
                "settlementMethodId".contentEquals(
                        violation.getPropertyPath().toString())));

        ApiException error = assertThrows(
                ApiException.class,
                () -> PurchaseOrderService.requireHeaderSettlement(request));
        assertTrue(error.getMessage().contains("结账方式"));

        request.setSettlementMethodId(UUID.randomUUID());
        assertDoesNotThrow(() -> PurchaseOrderService.requireHeaderSettlement(request));
    }

    private static OrderSaveRequest validRequest() {
        OrderItemLine line = new OrderItemLine();
        line.setGoodsId(UUID.randomUUID());
        line.setRequestItemId(UUID.randomUUID());
        line.setQty(BigDecimal.ONE);

        OrderSaveRequest request = new OrderSaveRequest();
        request.setBillDate(LocalDate.of(2026, 8, 27));
        request.setItems(List.of(line));
        return request;
    }
}
