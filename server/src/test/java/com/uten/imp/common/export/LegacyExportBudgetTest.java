package com.uten.imp.common.export;

import com.uten.imp.common.report.ReportQueryKit;
import com.uten.imp.common.report.ReportReadPlan;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.*;

class LegacyExportBudgetTest {
    @Test void aWholeOperationOwnsOneSlotAndAlwaysReleasesItAfterFailure() {
        var budget = new LegacyExportBudget(1);
        var first = budget.open();
        assertThat(LegacyExportBudget.maximumRows(100000)).isEqualTo(500);
        assertThat(LegacyExportBudget.maximumRows(100)).isEqualTo(100);
        CompletableFuture.runAsync(() -> assertThatThrownBy(budget::open)
                .isInstanceOfSatisfying(ApiException.class, error -> assertThat(error.getCode()).isEqualTo(ErrorCode.RATE_LIMITED))).join();
        first.close(); first.close();
        assertThat(LegacyExportBudget.active()).isFalse();
        try (var retry = budget.open()) { assertThat(LegacyExportBudget.active()).isTrue(); }
        assertThat(LegacyExportBudget.active()).isFalse();
    }

    @Test void artifactsAndWorkerSinksKeepTheirOwnExistingResourceAndRowContracts() {
        var budget = new LegacyExportBudget(1);
        try (var download = budget.openDownload()) {
            assertThat(LegacyExportBudget.maximumRows(100000)).isEqualTo(100000);
            LegacyExportBudget.requireRows(100000);
        }
        try (var legacy = budget.open(); var worker = ExportPageSink.open(page -> {})) {
            assertThat(LegacyExportBudget.maximumRows(100000)).isEqualTo(100000);
            LegacyExportBudget.requireRows(100000);
        }
        try (var natural = budget.openNatural(2000)) {
            assertThat(LegacyExportBudget.maximumRows(100000)).isEqualTo(2000);
            LegacyExportBudget.requireRows(2000);
            assertThatThrownBy(() -> LegacyExportBudget.requireRows(2001)).isInstanceOf(ApiException.class);
        }
    }

    private record Page(long total, List<Map<String, Object>> rows) { }
    private static final List<ExportColumn> COLUMNS = List.of(new ExportColumn("value", "原始值", ExportColumn.TEXT));

    @Test void largeKnownTotalsRefuseBeforeRowProjectionAndMetadataHeavyWork() {
        var calls = new AtomicInteger(); var projections = new AtomicInteger();
        try (var operation = new LegacyExportBudget(1).open()) {
            assertThatThrownBy(() -> ReportQueryKit.paginateAll(100000, (page, size) -> {
                calls.incrementAndGet();
                assertThat(page).isEqualTo(1); assertThat(size).isEqualTo(500);
                assertThat(ReportReadPlan.current().includeCount()).isTrue();
                assertThat(ReportReadPlan.current().includeFacets()).isFalse();
                assertThat(ReportReadPlan.current().includeTotals()).isFalse();
                return new Page(100000, List.of());
            }, Page::total, ignored -> COLUMNS, value -> { projections.incrementAndGet(); return value.rows(); }))
                    .isInstanceOfSatisfying(ApiException.class, error -> {
                        assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
                        assertThat(error.getMessage()).contains("后台导出任务");
                    });
        }
        assertThat(calls.get()).isEqualTo(1); assertThat(projections.get()).isZero();
        assertThat(ReportReadPlan.current()).isSameAs(ReportReadPlan.ALL);
    }

    @Test void unknownTotalsCannotPublishTheFirstFiveHundredOfALargerResult() {
        var calls = new AtomicInteger();
        List<Map<String, Object>> first = java.util.stream.IntStream.range(0, 500)
                .mapToObj(index -> Map.<String, Object>of("value", index)).toList();
        try (var operation = new LegacyExportBudget(1).open()) {
            assertThatThrownBy(() -> ReportQueryKit.paginateAll(100000, (page, size) -> {
                calls.incrementAndGet();
                if (page > 1) assertThat(ReportReadPlan.current().includeCount()).isFalse();
                return new Page(-1, page == 1 ? first : List.of(Map.of("value", 500)));
            }, Page::total, ignored -> COLUMNS, Page::rows))
                    .isInstanceOfSatisfying(ApiException.class, error -> assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        }
        assertThat(calls.get()).isEqualTo(2);
        assertThat(LegacyExportBudget.active()).isFalse();
    }

    @Test void smallResultsPreserveExactRawValuesAndTheConfiguredSmallerLimit() {
        try (var operation = new LegacyExportBudget(1).open()) {
            var result = ReportQueryKit.paginateAll(100, (page, size) -> {
                assertThat(size).isEqualTo(100);
                return new Page(1, List.of(Map.of("value", "001234.000000000000000001")));
            }, Page::total, ignored -> COLUMNS, Page::rows);
            assertThat(result.rows()).containsExactly(Map.of("value", "001234.000000000000000001"));
            assertThatThrownBy(() -> ReportQueryKit.requireExportRowCount(100, 101))
                    .isInstanceOfSatisfying(ApiException.class, error -> assertThat(error.getMessage()).contains("100 行上限"));
        }
    }
}
