package com.uten.imp.features.production.mrp;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class MrpRowTest {

    private static final UUID GOODS_ID = UUID.randomUUID();

    @Test
    void separatesPurchaseShortageFromNeedDateShortage() {
        MrpRow row = row(
                "100", "20", "10",
                "50", "20");

        assertThat(row.availableNow()).isEqualByComparingTo("70");
        assertThat(row.purchaseNetShortage()).isZero();
        assertThat(row.timelyShortage()).isEqualByComparingTo("10");
        assertThat(row.net()).isZero();
        assertThat(row.materialStatus()).isEqualTo(MrpRow.INBOUND_LATE);
        assertThat(row.allocationBacked()).isFalse();
        assertThat(row.planningWriteReady()).isFalse();
    }

    @Test
    void marksLateInboundWithoutCreatingAnotherPurchaseShortage() {
        MrpRow row = row(
                "0", "0", "0",
                "100", "20");

        assertThat(row.purchaseNetShortage()).isZero();
        assertThat(row.timelyShortage()).isEqualByComparingTo("80");
        assertThat(row.materialStatus()).isEqualTo(MrpRow.INBOUND_LATE);
    }

    @Test
    void reportsShortageWhenNothingCanCoverDemandByNeedDate() {
        MrpRow row = row(
                "0", "0", "5",
                "40", "0");

        assertThat(row.availableNow()).isZero();
        assertThat(row.timelyShortage()).isEqualByComparingTo("100");
        assertThat(row.materialStatus()).isEqualTo(MrpRow.SHORTAGE);
    }

    @Test
    void reportsReadyWhenCurrentAndOnTimeSupplyCoverDemand() {
        MrpRow row = row(
                "80", "10", "10",
                "40", "40");

        assertThat(row.availableNow()).isEqualByComparingTo("60");
        assertThat(row.timelyShortage()).isZero();
        assertThat(row.materialStatus()).isEqualTo(MrpRow.READY_BY_DATE);
    }

    @Test
    void distinguishesStockReadyFromSupplyReadyByDate() {
        MrpRow row = row(
                "120", "10", "10",
                "0", "0");

        assertThat(row.availableNow()).isEqualByComparingTo("100");
        assertThat(row.timelyShortage()).isZero();
        assertThat(row.materialStatus()).isEqualTo(MrpRow.READY_NOW);
    }

    @Test
    void neverLetsOnTimeSupplyExceedAllOpenSupply() {
        MrpRow row = row(
                "0", "0", "0",
                "20", "200");

        assertThat(row.openPoOnTime()).isEqualByComparingTo("20");
        assertThat(row.timelyShortage()).isEqualByComparingTo("80");
    }

    private static MrpRow row(
            String book, String reserved, String safety,
            String allOpenPo, String onTimePo) {
        return MrpRow.fromAvailability(
                GOODS_ID, "M-001", "物料", "S", null,
                new BigDecimal("100"), false, UUID.randomUUID(),
                new BigDecimal(book), new BigDecimal(reserved), new BigDecimal(safety),
                new BigDecimal(allOpenPo), new BigDecimal(onTimePo),
                LocalDate.of(2026, 8, 10), LocalDate.of(2026, 8, 8));
    }
}
