package com.uten.imp.common.report;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ReportReadPlanTest {
    @Test
    void nestedScopesRestoreThePreviousPlanEvenAfterFailure() {
        assertThat(ReportReadPlan.current()).isEqualTo(ReportReadPlan.ALL);
        try (var outer = ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)) {
            assertThatThrownBy(() -> {
                try (var inner = ReportReadPlan.open(new ReportReadPlan(true, false, true))) {
                    assertThat(ReportReadPlan.current().includeCount()).isTrue();
                    throw new IllegalArgumentException("test failure");
                }
            }).isInstanceOf(IllegalArgumentException.class);
            assertThat(ReportReadPlan.current()).isEqualTo(ReportReadPlan.ROWS_ONLY);
        }
        assertThat(ReportReadPlan.current()).isEqualTo(ReportReadPlan.ALL);
    }

    @Test
    void omittedMetadataNeverCallsTheSupplierOrClaimsAnEmptyResult() {
        AtomicInteger calls = new AtomicInteger();
        assertThat(ReportReadPlan.ROWS_ONLY.count(() -> calls.incrementAndGet())).isEqualTo(-1);
        assertThat(ReportReadPlan.ROWS_ONLY.totals(() -> List.of(calls.incrementAndGet()))).isEmpty();
        assertThat(calls).hasValue(0);
        assertThat(ReportReadPlan.totalPages(-1, 50)).isEqualTo(-1);
        assertThat(ReportReadPlan.totalPages(0, 50)).isZero();
        assertThat(ReportReadPlan.totalPages(51, 50)).isEqualTo(2);
        assertThat(ReportReadPlan.totalPages(Long.MAX_VALUE, 1)).isEqualTo(Integer.MAX_VALUE);
    }

    @Test
    void scopesDoNotPropagateToAnotherRequestThread() throws InterruptedException {
        try (var ignored = ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)) {
            var observed = new java.util.concurrent.atomic.AtomicReference<ReportReadPlan>();
            Thread other = Thread.ofPlatform().start(() -> observed.set(ReportReadPlan.current()));
            other.join();
            assertThat(observed.get()).isEqualTo(ReportReadPlan.ALL);
            assertThat(ReportReadPlan.current()).isEqualTo(ReportReadPlan.ROWS_ONLY);
        }
    }
}
