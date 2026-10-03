package com.uten.imp.features.sales.order;

import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.sales.order.dto.OrderProgressTimelineEvent;
import org.junit.jupiter.api.Test;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
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

    /**
     * 2026-10-01 用户口径「还没有进行的放上面，最下面是进度开始、最上面是最后的阶段」：
     * 未开始的 PENDING 占位整块置顶（阶段最靠后的在最顶，已完成的更晚阶段不插进来）；
     * 其下已发生事件按时间倒序，无时间的当前环置顶该块（草稿/进行中卡点最显眼），
     * 销售下单垫底。
     */
    @Test
    void timelineOrderPutsNotYetStartedStagesOnTopAndOrderPlacedAtBottom() {
        List<OrderProgressTimelineEvent> events = new ArrayList<>(List.of(
                new OrderProgressTimelineEvent(10, "ORDER_PLACED", "销售下单",
                        "下单人", "李销售", OffsetDateTime.parse("2026-10-01T04:00Z"),
                        OrderProgressTimelineEvent.DONE, null, null, null, null),
                new OrderProgressTimelineEvent(70, "PRODUCTION_PROGRESS", "生产开工",
                        null, null, null, OrderProgressTimelineEvent.PENDING,
                        "已产 0 / 订货 10", null, null, null),
                new OrderProgressTimelineEvent(30, "FINANCE_CONFIRMED", "财务审核",
                        null, null, null, OrderProgressTimelineEvent.CURRENT,
                        "等待财务审核组确认", null, null, null),
                new OrderProgressTimelineEvent(60, "PRODUCTION_PLAN", "生产计划下达",
                        "下达人", "张计划", OffsetDateTime.parse("2026-10-01T06:00Z"),
                        OrderProgressTimelineEvent.DONE, null, null, null, null),
                new OrderProgressTimelineEvent(50, "SUPPLY_ORDER", "物料准备-采购/委外下单",
                        null, null, null, OrderProgressTimelineEvent.PENDING,
                        "物料分析缺口待采购/委外在任务中心下单", null, null, null),
                new OrderProgressTimelineEvent(30, "FINANCE_CONFIRMED", "财务审核通过",
                        "审核人", "王财务", OffsetDateTime.parse("2026-10-01T05:00Z"),
                        OrderProgressTimelineEvent.DONE, null, null, null, null)));

        events.sort(SalesOrderTimelineService.TIMELINE_ORDER);

        assertThat(events.stream().map(OrderProgressTimelineEvent::title).toList())
                .containsExactly(
                        "生产开工", "物料准备-采购/委外下单", "财务审核",
                        "生产计划下达", "财务审核通过", "销售下单");
    }
}
