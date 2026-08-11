package com.uten.imp.features.org.department;

import com.uten.imp.features.org.department.dto.WorkforceOverviewDto;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class WorkforceOverviewServiceTest {

    private final WorkforceOverviewService service =
            new WorkforceOverviewService(null, null);

    @Test
    void calculatesOpeningHeadcountAndTurnoverFromBoundaryFlows() {
        Department department = organization("公司");
        WorkforceOverviewQuery.Snapshot snapshot = new WorkforceOverviewQuery.Snapshot(
                12, 100, 90, 6, 4,
                15, 2, 10, 3, 5,
                0, 4, 0, 2, 0, 8);

        WorkforceOverviewDto result = service.summarize(
                department,
                snapshot,
                LocalDate.of(2025, 7, 31),
                LocalDate.of(2026, 7, 31));

        assertThat(result.openingHeadcount()).isEqualTo(95);
        assertThat(result.averageHeadcount()).isEqualByComparingTo(new BigDecimal("97.5"));
        assertThat(result.turnoverRatePct()).isEqualByComparingTo(new BigDecimal("10.3"));
        assertThat(result.netChange()).isEqualTo(5);
        assertThat(result.historyCoverageComplete()).isTrue();
        assertThat(result.turnoverRateApproximate()).isTrue();
    }

    @Test
    void returnsNullRateForZeroAverageAndMarksMissingHistory() {
        Department department = organization("一级部门");
        WorkforceOverviewQuery.Snapshot snapshot = new WorkforceOverviewQuery.Snapshot(
                0, 0, 0, 0, 0,
                0, 0, 0, 0, 0,
                0, 0, 0, 0, 3, 0);

        WorkforceOverviewDto result = service.summarize(
                department,
                snapshot,
                LocalDate.of(2025, 7, 31),
                LocalDate.of(2026, 7, 31));

        assertThat(result.turnoverRatePct()).isNull();
        assertThat(result.historyCoverageComplete()).isFalse();
        assertThat(result.missingHistoryRecords()).isEqualTo(3);
        assertThat(result.dataQualityNote()).contains("3 条");
    }

    @Test
    void suppressesRateWhenLifecycleCoverageIsIncomplete() {
        Department department = organization("公司");
        WorkforceOverviewQuery.Snapshot snapshot = new WorkforceOverviewQuery.Snapshot(
                10, 10, 10, 0, 0,
                2, 0, 1, 0, 0,
                1, 2, 1, 2, 1, 0);

        WorkforceOverviewDto result = service.summarize(
                department,
                snapshot,
                LocalDate.of(2025, 8, 1),
                LocalDate.of(2026, 7, 31));

        assertThat(result.historyCoverageComplete()).isFalse();
        assertThat(result.turnoverRatePct()).isNull();
        assertThat(result.dataQualityNote()).contains("暂不显示");
    }

    @Test
    void suppressesRateWhenEventFlowWouldProduceNegativeOpening() {
        Department department = organization("公司");
        WorkforceOverviewQuery.Snapshot snapshot = new WorkforceOverviewQuery.Snapshot(
                1, 1, 1, 0, 0,
                5, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0);

        WorkforceOverviewDto result = service.summarize(
                department,
                snapshot,
                LocalDate.of(2025, 8, 1),
                LocalDate.of(2026, 7, 31));

        assertThat(result.openingHeadcount()).isZero();
        assertThat(result.historyCoverageComplete()).isFalse();
        assertThat(result.turnoverRatePct()).isNull();
    }

    private Department organization(String level) {
        Department department = new Department();
        department.setId(UUID.randomUUID());
        department.setName("测试组织");
        department.setLevel(level);
        return department;
    }
}
