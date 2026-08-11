package com.uten.imp.features.operations.workbench;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.sql.Timestamp;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class FulfillmentWorkbenchTimestampMappingTest {

    @Test
    void nativeTimestampProjectionAcceptsHibernateUtcTypesAndNormalizesToUtc() {
        Instant instant = Instant.parse("2026-08-01T10:15:30Z");
        OffsetDateTime expected = instant.atOffset(ZoneOffset.UTC);

        assertEquals(expected, FulfillmentWorkbenchQueryService.offsetDateTime(instant));
        assertEquals(expected, FulfillmentWorkbenchQueryService.offsetDateTime(
                Timestamp.from(instant)));
        assertEquals(expected, FulfillmentWorkbenchQueryService.offsetDateTime(
                OffsetDateTime.parse("2026-08-01T18:15:30+08:00")));
        assertThrows(ApiException.class,
                () -> FulfillmentWorkbenchQueryService.offsetDateTime("not-a-time"));
    }
}
