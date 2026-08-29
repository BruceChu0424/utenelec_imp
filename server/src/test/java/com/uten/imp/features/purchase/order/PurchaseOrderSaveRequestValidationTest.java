package com.uten.imp.features.purchase.order;

import com.uten.imp.features.purchase.order.dto.OrderItemLine;
import com.uten.imp.features.purchase.order.dto.OrderSaveRequest;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class PurchaseOrderSaveRequestValidationTest {

    private final Validator validator =
            Validation.buildDefaultValidatorFactory().getValidator();

    @Test
    void settlementMethodIsRequiredForPurchaseOrderWrites() {
        OrderSaveRequest request = validRequest();

        var missingViolations = validator.validate(request);
        assertTrue(missingViolations.stream().anyMatch(violation ->
                "settlementMethodId".contentEquals(
                        violation.getPropertyPath().toString())
                        && "采购订货单必须选择结账方式".equals(
                                violation.getMessage())));

        request.setSettlementMethodId(UUID.randomUUID());

        assertFalse(validator.validate(request).stream().anyMatch(violation ->
                "settlementMethodId".contentEquals(
                        violation.getPropertyPath().toString())));
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
