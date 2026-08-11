package com.uten.imp.features.sales.shipment;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SalesShipmentWarehouseReservationSqlContractTest {

    @Test
    void selectedWarehouseCanConsumeItsOwnGlobalOrAlreadyBoundReservation() throws Exception {
        String source = Files.readString(Path.of(
                        "src/main/java/com/uten/imp/features/sales/shipment/"
                                + "SalesShipmentService.java"),
                StandardCharsets.UTF_8);
        int eligibleStart = source.indexOf("BigDecimal eligible =");
        int nextQuery = source.indexOf("BigDecimal ownActive =", eligibleStart);

        assertThat(eligibleStart).isGreaterThanOrEqualTo(0);
        assertThat(nextQuery).isGreaterThan(eligibleStart);
        assertThat(source.substring(eligibleStart, nextQuery))
                .contains("AND (warehouse_id IS NULL OR warehouse_id = :wid)");
    }
}
