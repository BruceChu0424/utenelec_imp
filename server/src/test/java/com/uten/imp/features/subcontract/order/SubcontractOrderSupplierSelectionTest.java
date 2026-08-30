package com.uten.imp.features.subcontract.order;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.subcontract.order.dto.OrderItemLine;
import com.uten.imp.features.subcontract.order.dto.OrderSaveRequest;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class SubcontractOrderSupplierSelectionTest {

    @Test
    void rejectsRowsThatDifferFromThePersistedHeaderSupplier() {
        OrderSaveRequest request = request(UUID.randomUUID(), UUID.randomUUID());

        ApiException error = assertThrows(
                ApiException.class,
                () -> SubcontractOrderService.requireRowsMatchHeaderSupplier(request));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
    }

    @Test
    void acceptsMatchingOrUnspecifiedRowSupplier() {
        UUID supplier = UUID.randomUUID();
        OrderSaveRequest matching = request(supplier, supplier);
        OrderSaveRequest inherited = request(supplier, null);

        assertDoesNotThrow(() -> SubcontractOrderService.requireRowsMatchHeaderSupplier(matching));
        assertDoesNotThrow(() -> SubcontractOrderService.requireRowsMatchHeaderSupplier(inherited));
    }

    private static OrderSaveRequest request(UUID header, UUID rowSupplier) {
        OrderItemLine line = new OrderItemLine();
        line.setSupplierId(rowSupplier);
        OrderSaveRequest request = new OrderSaveRequest();
        request.setSupplierId(header);
        request.setItems(List.of(line));
        return request;
    }
}
