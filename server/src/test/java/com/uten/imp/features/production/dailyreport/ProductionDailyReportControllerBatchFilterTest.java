package com.uten.imp.features.production.dailyreport;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.util.UUID;
import java.util.stream.IntStream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ProductionDailyReportControllerBatchFilterTest {

    @Test
    void singularAndCsvIdsAreMergedInStableDeduplicatedOrder() {
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();

        assertThat(ProductionDailyReportController.normalizeExecutionSegmentIds(
                first, second + "," + first))
                .containsExactly(first, second);
    }

    @Test
    void invalidOrOversizedBatchFailsClosed() {
        assertThatThrownBy(() ->
                ProductionDailyReportController.normalizeExecutionSegmentIds(
                        null, "not-a-uuid"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("UUID 格式无效");

        String oversized = IntStream.range(0, 101)
                .mapToObj(ignored -> UUID.randomUUID().toString())
                .collect(java.util.stream.Collectors.joining(","));
        assertThatThrownBy(() ->
                ProductionDailyReportController.normalizeExecutionSegmentIds(
                        null, oversized))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("最多选择 100");
    }
}
