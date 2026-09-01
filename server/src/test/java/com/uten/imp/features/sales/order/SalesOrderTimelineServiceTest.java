package com.uten.imp.features.sales.order;

import com.uten.imp.common.util.EmployeeNameResolver;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class SalesOrderTimelineServiceTest {

    @Test
    void materialAnalysisStatusUsesBusinessNamesInsteadOfInternalCodes() {
        assertThat(SalesOrderTimelineService.analysisStatusLabel("ACTIVE"))
                .isEqualTo("进行中");
        assertThat(SalesOrderTimelineService.analysisStatusLabel("PARTIALLY_PLANNED"))
                .isEqualTo("部分已下达，剩余待料");
        assertThat(SalesOrderTimelineService.analysisStatusLabel("COMPLETED"))
                .isEqualTo("已全部下达");
        assertThat(SalesOrderTimelineService.analysisStatusLabel("CANCELLED"))
                .isEqualTo("已取消");
        assertThat(SalesOrderTimelineService.analysisStatusLabel("READY"))
                .isEqualTo("已齐套");
        assertThat(SalesOrderTimelineService.analysisStatusLabel("CONFIRMED"))
                .isEqualTo("已确认");
        assertThat(SalesOrderTimelineService.analysisStatusLabel("STALE"))
                .isEqualTo("已过期待刷新");
    }

    @Test
    void materialAnalysisStatusNeverLeaksUnknownInternalCodes() {
        assertThat(SalesOrderTimelineService.analysisStatusLabel("unexpected_internal_code"))
                .isEqualTo("状态待确认");
        assertThat(SalesOrderTimelineService.analysisStatusLabel("  ")).isEqualTo("—");
        assertThat(SalesOrderTimelineService.analysisStatusLabel(null)).isEqualTo("—");
    }

    @Test
    void employeeDisplayUsesActualNameInsteadOfEmployeeCode() {
        UUID employeeId = UUID.randomUUID();
        EmployeeNameResolver nameResolver = mock(EmployeeNameResolver.class);
        when(nameResolver.nameOf(employeeId)).thenReturn("系统管理员");
        SalesOrderTimelineService service =
                new SalesOrderTimelineService(null, null, nameResolver, null);

        assertThat(service.employeeDisplayName(employeeId)).isEqualTo("系统管理员");
        verify(nameResolver).nameOf(employeeId);
    }
}
