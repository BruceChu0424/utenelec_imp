package com.uten.imp.features.stock.allocation;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.sql.Timestamp;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class ProductionMaterialSettlementServiceTest {

    @Test
    void nativeTimestampProjectionAcceptsHibernateUtcTypes() {
        Instant instant = Instant.parse("2026-08-01T10:15:30Z");
        OffsetDateTime expected = instant.atOffset(ZoneOffset.UTC);

        assertEquals(expected,
                ProductionMaterialSettlementService.offsetDateTime(instant));
        assertEquals(expected, ProductionMaterialSettlementService.offsetDateTime(
                Timestamp.from(instant)));
        assertEquals(expected,
                ProductionMaterialSettlementService.offsetDateTime(expected));
        assertThrows(ApiException.class,
                () -> ProductionMaterialSettlementService.offsetDateTime("not-a-time"));
    }
}