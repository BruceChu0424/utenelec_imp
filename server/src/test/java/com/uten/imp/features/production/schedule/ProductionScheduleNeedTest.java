package com.uten.imp.features.production.schedule;

import com.uten.imp.common.saleschain.SalesChainStatus;
import com.uten.imp.common.saleschain.SalesOrderChainSql;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 剩余未排量 = SalesOrderChainSql 链路口径(V545 起与 chain_status 派生同源)；
 * 待排产缺口 = 剩余未排量 − 活动物料分析已承接量(ADR-088)。
 */
class ProductionScheduleNeedTest {

    @Test
    void schedulingNeedIsTheSharedUnplannedQtyExpression() {
        assertThat(ProductionScheduleService.SCHEDULING_NEED_SQL)
                .isEqualTo(SalesOrderChainSql.unplannedQtySql("i"));
    }

    /** ADR-088：待排产缺口在链路口径之上再扣活动分析承接量，下限 0。 */
    @Test
    void pendingNeedSubtractsActiveAnalysisCoverageFromTheChainUnplannedQty() {
        assertThat(ProductionScheduleService.PENDING_NEED_SQL)
                .isEqualTo("GREATEST(" + ProductionScheduleService.SCHEDULING_NEED_SQL
                        + " - " + ProductionScheduleService.ACTIVE_ANALYSIS_COVERED_SQL + ", 0)");
    }

    /**
     * 承接量只算「分析已接走、但订单行数量列上还看不见」的那部分：
     * requested − approved − root_fulfilled。
     *
     * <p>这两项必须减掉，否则同一批量两段双扣：approved 在计划审核时同事务写进
     * {@code sales_order_items.planned_qty}(ProductionPlanService.applyAllocation)，
     * root_fulfilled 在根产品供给交接时同步写进 {@code reserved_qty}
     * (MaterialAnalysisRootSupplyService)，两者都已被 SCHEDULING_NEED_SQL 自己扣过。
     *
     * <p>反过来 submitted **不能**减：草稿计划不写 planned_qty，减了就等于这批量
     * 两段都不表达，行会带着虚高的缺口留在待排产。
     */
    @Test
    void coverageExcludesQuantitiesAlreadyVisibleOnTheOrderLine() {
        assertThat(ProductionScheduleService.ACTIVE_ANALYSIS_COVERED_SQL)
                .contains("SUM(GREATEST(analysis_item.requested_qty")
                .contains("- analysis_item.approved_qty")
                .contains("- analysis_item.root_fulfilled_qty, 0))")
                .doesNotContain("submitted_qty")
                .contains("analysis_item.source_type = 'SALES_ORDER_ITEM'")
                .contains("analysis_item.is_deleted = FALSE")
                .contains("analysis.is_deleted = FALSE");
    }

    /**
     * 分析状态白名单必须与「进行中」根视图同源(V487 analysis_roots：status <> 'CANCELLED')。
     * 白名单不一致会出现「待排产已经不扣、进行中却还在表达」的窗口，
     * 典型是 COMPLETED 分析——它不在 ACTIVE/PARTIALLY_PLANNED 里，却在根视图里。
     */
    @Test
    void coverageStatusSetMatchesTheOngoingRootView() {
        assertThat(ProductionScheduleService.ACTIVE_ANALYSIS_COVERED_SQL)
                .contains("analysis.status <> 'CANCELLED'")
                .doesNotContain("IN ('ACTIVE','PARTIALLY_PLANNED')");
    }

    @Test
    void partialShipmentAndPartialInboundLeaveOnlyUncoveredOutstanding() {
        assertThat(SalesChainStatus.unplannedQty(
                bd("100"), bd("20"), bd("0"), bd("0"),
                bd("30"), bd("70"), bd("30")))
                .isEqualByComparingTo("10");
    }

    @Test
    void returnIncreasesNeedAndFlagDecreasesNeed() {
        BigDecimal baseline = SalesChainStatus.unplannedQty(
                bd("100"), bd("20"), bd("0"), bd("0"),
                bd("30"), bd("70"), bd("30"));
        BigDecimal afterReturn = SalesChainStatus.unplannedQty(
                bd("100"), bd("20"), bd("8"), bd("0"),
                bd("30"), bd("70"), bd("30"));
        BigDecimal afterFlag = SalesChainStatus.unplannedQty(
                bd("100"), bd("20"), bd("0"), bd("6"),
                bd("30"), bd("70"), bd("30"));

        assertThat(afterReturn).isEqualByComparingTo(baseline.add(bd("8")));
        assertThat(afterFlag).isEqualByComparingTo(baseline.subtract(bd("6")));
    }

    @Test
    void producedQuantityIsNotDoubleCountedWhenFinishedStockIsReserved() {
        assertThat(SalesChainStatus.unplannedQty(
                bd("100"), bd("0"), bd("0"), bd("0"),
                bd("20"), bd("50"), bd("20")))
                .isEqualByComparingTo("50");
    }

    @Test
    void partiallyScheduledLineKeepsItsRemainingNeed() {
        // 订 10 排 4：缺口 6，行仍在待排产列表（chain_status 2 与 need>0 同源）。
        assertThat(SalesChainStatus.unplannedQty(
                bd("10"), bd("0"), bd("0"), bd("0"),
                bd("0"), bd("4"), bd("0")))
                .isEqualByComparingTo("6");
        assertThat(SalesChainStatus.derive((short) 4,
                bd("10"), bd("0"), bd("0"), bd("0"),
                bd("0"), bd("4"), bd("0")))
                .isEqualTo((short) 2);
    }

    private static BigDecimal bd(String value) {
        return new BigDecimal(value);
    }
}
