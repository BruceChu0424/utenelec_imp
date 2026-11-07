package com.uten.imp.common.export;

import com.uten.imp.common.report.ReportQueryKit;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.stream.IntStream;

import static org.assertj.core.api.Assertions.*;

class CompleteResultExportTest {
    record Page(long total, List<Map<String, Object>> rows) { }
    private static final List<ExportColumn> COLUMNS = List.of(new ExportColumn("value", "原始值", ExportColumn.TEXT));

    @Test void compatibilityExportKeepsEveryRowBeyondFiveHundredAndTheFormerConfiguredLimit() {
        var calls = new AtomicInteger();
        try (var operation = new LegacyExportBudget(1).open()) {
            var result = ReportQueryKit.paginateAll(500, (page, size) -> {
                calls.incrementAndGet();
                assertThat(size).isEqualTo(500);
                return new Page(1201, IntStream.range((page - 1) * size, Math.min(1201, page * size))
                        .mapToObj(value -> Map.<String, Object>of("value", "原值-" + value)).toList());
            }, Page::total, ignored -> COLUMNS, Page::rows);
            assertThat(result.total()).isEqualTo(1201);
            assertThat(result.rows()).hasSize(1201);
            assertThat(result.rows().getLast()).containsEntry("value", "原值-1200");
        }
        assertThat(calls).hasValue(3);
        assertThat(LegacyExportBudget.active()).isFalse();
    }
}
