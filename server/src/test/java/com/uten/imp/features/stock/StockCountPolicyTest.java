package com.uten.imp.features.stock;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class StockCountPolicyTest {

    @Test
    void computesGainAndLossFromServerBookSnapshot() {
        assertEquals(
                new BigDecimal("2.5000"),
                StockCountPolicy.adjustment(
                        new BigDecimal("10.0000"), new BigDecimal("12.5000")));
        assertEquals(
                new BigDecimal("-3.0000"),
                StockCountPolicy.adjustment(
                        new BigDecimal("10.0000"), new BigDecimal("7.0000")));
    }

    @Test
    void acceptsZeroButRejectsMissingOrNegativePhysicalCount() {
        assertEquals(
                BigDecimal.ZERO,
                StockCountPolicy.requireCountQuantity(BigDecimal.ZERO, 1));
        assertThrows(
                ApiException.class,
                () -> StockCountPolicy.requireCountQuantity(null, 2));
        assertThrows(
                ApiException.class,
                () -> StockCountPolicy.requireCountQuantity(
                        new BigDecimal("-0.0001"), 3));
    }

    @Test
    void approvalRejectsAChangedBookSnapshot() {
        assertDoesNotThrow(() -> StockCountPolicy.requireSnapshotUnchanged(
                new BigDecimal("10.0"), new BigDecimal("10.0000"), 1));

        ApiException error = assertThrows(
                ApiException.class,
                () -> StockCountPolicy.requireSnapshotUnchanged(
                        new BigDecimal("10"), new BigDecimal("11"), 4));
        assertTrue(error.getMessage().contains("盘点期间库存已变化"));
    }
}
