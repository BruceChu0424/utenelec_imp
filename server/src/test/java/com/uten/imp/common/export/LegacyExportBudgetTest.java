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
        assertThat(LegacyExportBudget.maximumRows(100000)).isEqualTo(100000);
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

    @Test void largeKnownTotalsReadEveryBoundedBatchWithOnlyTheFirstCount() {
        var calls = new AtomicInteger(); var projections = new AtomicInteger();
        try (var operation = new LegacyExportBudget(1).open()) {
            var result=ReportQueryKit.paginateAll((page, size) -> {
                calls.incrementAndGet();
                assertThat(size).isEqualTo(500);
                assertThat(ReportReadPlan.current().includeCount()).isEqualTo(page==1);
                assertThat(ReportReadPlan.current().includeFacets()).isFalse();
                assertThat(ReportReadPlan.current().includeTotals()).isFalse();
                return new Page(1201,java.util.stream.IntStream.range((page-1)*size,Math.min(page*size,1201))
                        .mapToObj(index->Map.<String,Object>of("value",index)).toList());
            }, Page::total, ignored -> COLUMNS, value -> { projections.incrementAndGet(); return value.rows(); });
            assertThat(result.total()).isEqualTo(1201);
            assertThat(result.rows()).extracting(row->row.get("value"))
                    .containsExactlyElementsOf(java.util.stream.IntStream.range(0,1201).boxed().toList());
        }
        assertThat(calls.get()).isEqualTo(3); assertThat(projections.get()).isEqualTo(3);
        assertThat(ReportReadPlan.current()).isSameAs(ReportReadPlan.ALL);
    }

    @Test void unknownTotalsIncludeTheRowsAfterTheFirstFiveHundred() {
        var calls = new AtomicInteger();
        List<Map<String, Object>> first = java.util.stream.IntStream.range(0, 500)
                .mapToObj(index -> Map.<String, Object>of("value", index)).toList();
        try (var operation = new LegacyExportBudget(1).open()) {
            var result=ReportQueryKit.paginateAll((page, size) -> {
                calls.incrementAndGet();
                if (page > 1) assertThat(ReportReadPlan.current().includeCount()).isFalse();
                return new Page(-1, page == 1 ? first : List.of(Map.of("value", 500)));
            }, Page::total, ignored -> COLUMNS, Page::rows);
            assertThat(result.rows()).hasSize(501).endsWith(Map.of("value",500));
            assertThat(result.total()).isEqualTo(501);
        }
        assertThat(calls.get()).isEqualTo(2);
        assertThat(LegacyExportBudget.active()).isFalse();
    }

    @Test void anOldConfiguredRowLimitDoesNotChangeCompleteOutputOrBoundedBatchSize() {
        try (var operation = new LegacyExportBudget(1).open()) {
            var result = ReportQueryKit.paginateAll((page, size) -> {
                assertThat(size).isEqualTo(500);
                return new Page(501,java.util.stream.IntStream.range((page-1)*size,Math.min(page*size,501))
                        .mapToObj(index->Map.<String,Object>of("value","001234.000000000000000001","id",index)).toList());
            }, Page::total, ignored -> COLUMNS, Page::rows);
            assertThat(result.rows()).hasSize(501);
            assertThat(result.rows().getLast()).containsEntry("value","001234.000000000000000001").containsEntry("id",500);
        }
    }

    @Test void incompleteOrDriftingTotalsFailBeforeAnyCompleteResultIsReturned() {
        var first=java.util.stream.IntStream.range(0,500).mapToObj(i->Map.<String,Object>of("value",i)).toList();
        for(boolean drift:List.of(false,true))try(var operation=new LegacyExportBudget(1).open()) {
            assertThatThrownBy(()->ReportQueryKit.paginateAll((page,size)->new Page(page==2&&drift?502:501,page==1?first:List.of()),
                    Page::total,ignored->COLUMNS,Page::rows)).isInstanceOf(IllegalStateException.class)
                    .hasMessageContaining(drift?"count changed":"incomplete");
        }
        assertThat(LegacyExportBudget.active()).isFalse();
        assertThat(ReportReadPlan.current()).isSameAs(ReportReadPlan.ALL);
    }

    @Test void interruptionAfterTheFirstFiveHundredRetiresTheReadAndReleasesItsSlot() {
        var budget=new LegacyExportBudget(1);
        try(var operation=budget.open()) {
            assertThatThrownBy(()->ReportQueryKit.paginateAll((page,size)->{
                if(page==2)Thread.currentThread().interrupt();
                return new Page(501,java.util.stream.IntStream.range((page-1)*size,Math.min(page*size,501))
                        .mapToObj(index->Map.<String,Object>of("value",index)).toList());
            },Page::total,ignored->COLUMNS,Page::rows)).isInstanceOf(java.util.concurrent.CancellationException.class);
        }finally{Thread.interrupted();}
        assertThat(LegacyExportBudget.active()).isFalse();
        assertThat(ReportReadPlan.current()).isSameAs(ReportReadPlan.ALL);
        try(var retry=budget.open()){LegacyExportBudget.requireRows(1201);}
    }
}
