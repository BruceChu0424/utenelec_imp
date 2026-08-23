package com.uten.imp.features.finance.payables;

import org.junit.jupiter.api.Test;

import java.time.LocalDate;

import static org.assertj.core.api.Assertions.assertThat;

class SupplierClosedPeriodGuardTest {
    private static final LocalDate CLOSED_THROUGH = LocalDate.of(2026, 7, 31);

    @Test
    void dateOnOrBeforeConfirmedStatementEndIsClosed() {
        assertThat(SupplierClosedPeriodGuard.isClosed(
                LocalDate.of(2026, 7, 1), CLOSED_THROUGH)).isTrue();
        assertThat(SupplierClosedPeriodGuard.isClosed(
                CLOSED_THROUGH, CLOSED_THROUGH)).isTrue();
    }

    @Test
    void nextOpenDayAndNoCloseRemainWritable() {
        assertThat(SupplierClosedPeriodGuard.isClosed(
                LocalDate.of(2026, 8, 1), CLOSED_THROUGH)).isFalse();
        assertThat(SupplierClosedPeriodGuard.isClosed(
                LocalDate.of(2026, 7, 1), null)).isFalse();
    }

    @Test
    void frozenBlocksAndOnlyNeverConfirmedReversalReopens() {
        assertThat(SupplierClosedPeriodGuard.contributesToClosedThrough(
                "FROZEN",false,false)).isTrue();
        assertThat(SupplierClosedPeriodGuard.contributesToClosedThrough(
                "REVERSED",false,false)).isFalse();
        assertThat(SupplierClosedPeriodGuard.contributesToClosedThrough(
                "REVERSED",true,true)).isTrue();
        assertThat(SupplierClosedPeriodGuard.contributesToClosedThrough(
                "CLOSED",false,false)).isTrue();
    }
}
