package com.uten.imp.features.sales.ret;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class SalesReturnQualityServiceTest {

    @Test
    void dispositionActionIsClosedToTheThreeControlledOutcomes() {
        assertEquals("GOOD_RELEASE", SalesReturnQualityService.normalizeAction(" good_release "));
        assertEquals("SCRAP", SalesReturnQualityService.normalizeAction("scrap"));
        assertEquals("REWORK", SalesReturnQualityService.normalizeAction("REWORK"));
        assertThrows(ApiException.class,
                () -> SalesReturnQualityService.normalizeAction("SELL_DIRECTLY"));
        assertThrows(ApiException.class,
                () -> SalesReturnQualityService.normalizeAction(null));
    }

    @Test
    void cumulativeProrationHasNoFinalReleaseRoundingDrift() {
        BigDecimal first = SalesReturnQualityService.proratedIncrement(
                new BigDecimal("1.0000"), new BigDecimal("3"),
                BigDecimal.ZERO, BigDecimal.ONE);
        BigDecimal second = SalesReturnQualityService.proratedIncrement(
                new BigDecimal("1.0000"), new BigDecimal("3"),
                BigDecimal.ONE, BigDecimal.ONE);
        BigDecimal third = SalesReturnQualityService.proratedIncrement(
                new BigDecimal("1.0000"), new BigDecimal("3"),
                new BigDecimal("2"), BigDecimal.ONE);

        assertEquals(new BigDecimal("1.0000"), first.add(second).add(third));
    }

    @Test
    void optionalActualWeightUsesTheSameCumulativeProration() {
        BigDecimal first = SalesReturnQualityService.proratedIncrementNullable(
                new BigDecimal("10.0000"), new BigDecimal("3"),
                BigDecimal.ZERO, BigDecimal.ONE);
        BigDecimal second = SalesReturnQualityService.proratedIncrementNullable(
                new BigDecimal("10.0000"), new BigDecimal("3"),
                BigDecimal.ONE, BigDecimal.ONE);
        BigDecimal third = SalesReturnQualityService.proratedIncrementNullable(
                new BigDecimal("10.0000"), new BigDecimal("3"),
                new BigDecimal("2"), BigDecimal.ONE);

        assertEquals(new BigDecimal("10.0000"), first.add(second).add(third));
        assertEquals(null, SalesReturnQualityService.proratedIncrementNullable(
                null, new BigDecimal("3"), BigDecimal.ZERO, BigDecimal.ONE));
    }

    @Test
    void dispositionIdempotencyIsStableStrictAndPayloadAware() {
        assertEquals("quality-dispose-001",
                SalesReturnQualityService.normalizeIdempotencyKey(
                        " quality-dispose-001 "));
        assertThrows(ApiException.class,
                () -> SalesReturnQualityService.normalizeIdempotencyKey("short"));
        assertThrows(ApiException.class,
                () -> SalesReturnQualityService.normalizeIdempotencyKey(
                        "quality key with spaces"));

        UUID qualityItemId = UUID.randomUUID();
        UUID eventId = SalesReturnQualityService.dispositionEventId(
                qualityItemId, "quality-dispose-001");
        assertEquals(eventId, SalesReturnQualityService.dispositionEventId(
                qualityItemId, "quality-dispose-001"));
        assertNotEquals(eventId, SalesReturnQualityService.dispositionEventId(
                qualityItemId, "quality-dispose-002"));

        assertTrue(SalesReturnQualityService.sameDispositionCommand(
                qualityItemId, "GOOD_RELEASE", new BigDecimal("1.0"), "检验合格",
                qualityItemId, "GOOD_RELEASE", new BigDecimal("1.0000"), "检验合格"));
        assertFalse(SalesReturnQualityService.sameDispositionCommand(
                qualityItemId, "GOOD_RELEASE", BigDecimal.ONE, "检验合格",
                qualityItemId, "GOOD_RELEASE", new BigDecimal("2"), "检验合格"));
        assertFalse(SalesReturnQualityService.sameDispositionCommand(
                qualityItemId, "GOOD_RELEASE", BigDecimal.ONE, "检验合格",
                qualityItemId, "SCRAP", BigDecimal.ONE, "检验合格"));
    }

    @Test
    void dispositionQuantityMatchesTheDatabaseScaleAndPrecision() {
        assertEquals(new BigDecimal("1.0000"),
                SalesReturnQualityService.normalizeDispositionQty(
                        new BigDecimal("1.00000")));
        assertThrows(ApiException.class,
                () -> SalesReturnQualityService.normalizeDispositionQty(
                        new BigDecimal("0.00001")));
        assertThrows(ApiException.class,
                () -> SalesReturnQualityService.normalizeDispositionQty(
                        new BigDecimal("123456789012345")));
    }

    @Test
    void nativeTimestampProjectionAcceptsHibernateUtcTypes() {
        Instant instant = Instant.parse("2026-08-01T10:15:30Z");
        OffsetDateTime expected = instant.atOffset(ZoneOffset.UTC);

        assertEquals(expected, SalesReturnQualityService.offsetDateTime(instant));
        assertEquals(expected, SalesReturnQualityService.offsetDateTime(
                Timestamp.from(instant)));
        assertEquals(expected, SalesReturnQualityService.offsetDateTime(expected));
        assertThrows(ApiException.class,
                () -> SalesReturnQualityService.offsetDateTime("not-a-time"));
    }
}
