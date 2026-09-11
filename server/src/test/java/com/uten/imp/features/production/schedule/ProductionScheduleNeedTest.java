package com.uten.imp.features.production.schedule;

import com.uten.imp.common.saleschain.SalesChainStatus;
import com.uten.imp.common.saleschain.SalesOrderChainSql;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;

/** 待排产缺口 = 剩余未排量（V545 起与 chain_status 派生同源，SalesOrderChainSql）。 */
class ProductionScheduleNeedTest {

    @Test
    void schedulingNeedIsTheSharedUnplannedQtyExpression() {
        assertThat(ProductionScheduleService.SCHEDULING_NEED_SQL)
                .isEqualTo(SalesOrderChainSql.unplannedQtySql("i"));
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
