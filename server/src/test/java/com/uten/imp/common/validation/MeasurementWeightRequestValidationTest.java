package com.uten.imp.common.validation;

import com.uten.imp.features.sales.shipment.dto.BatchShipRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class MeasurementWeightRequestValidationTest {

    private final Validator validator = Validation
            .buildDefaultValidatorFactory().getValidator();

    @Test
    void salesBatchRejectsNegativeActualTotalWeight() {
        BatchShipRequest.Line line = new BatchShipRequest.Line();
        line.setOrderItemId(UUID.randomUUID());
        line.setQty(BigDecimal.ONE);
        line.setWeight(new BigDecimal("-0.0001"));
        BatchShipRequest request = new BatchShipRequest();
        request.setBillDate(LocalDate.of(2026, 8, 30));
        request.setLines(List.of(line));

        assertThat(validator.validate(request))
                .anyMatch(v -> v.getPropertyPath().toString()
                        .equals("lines[0].weight"));
    }

    @Test
    void warehouseArrivalRejectsOverPrecisionActualTotalWeight() {
        var line = new ProcurementArrivalContracts
                .WarehouseArrivalRegisterRequest.ArrivalLine(
                UUID.randomUUID(), BigDecimal.ONE, UUID.randomUUID(),
                null, UUID.randomUUID(), BigDecimal.ONE,
                new BigDecimal("1.00001"), null);
        var request = new ProcurementArrivalContracts
                .WarehouseArrivalRegisterRequest(
                "arrival-weight-001", "PURCHASE",
                LocalDate.of(2026, 8, 30), UUID.randomUUID(),
                UUID.randomUUID(), null, UUID.randomUUID(), null,
                List.of(line));

        assertThat(validator.validate(request))
                .anyMatch(v -> v.getPropertyPath().toString()
                        .equals("items[0].weight"));
    }
}
