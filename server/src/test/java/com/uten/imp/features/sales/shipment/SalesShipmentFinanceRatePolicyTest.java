package com.uten.imp.features.sales.shipment;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class SalesShipmentFinanceRatePolicyTest {

    @Test
    void newDirectShipmentNeverRoundsAwayLocalMoney() {
        SalesShipment shipment=new SalesShipment();shipment.setShipmentKind("DIRECT_CUSTOMER");
        var item=item("0.0001");
        assertThatThrownBy(()->SalesShipmentService.applyPostingRateSnapshot(shipment,List.of(item),new BigDecimal("0.0001")))
                .isInstanceOf(ApiException.class).hasMessageContaining("未自动四舍五入");
        assertThat(item.getAmountLocal()).isNull();
        SalesShipmentService.applyPostingRateSnapshot(shipment,List.of(item),new BigDecimal("7"));
        assertThat(item.getAmountLocal()).isEqualByComparingTo("0.0007");
    }

    @Test
    void financeRateRecalculatesEveryShipmentLineAndHeaderSnapshot() {
        SalesShipment shipment = new SalesShipment();

        SalesShipmentItem first = item("1.2345");
        SalesShipmentItem second = item("2.0000");

        SalesShipmentService.applyPostingRateSnapshot(
                shipment, List.of(first, second), new BigDecimal("7.123456"));

        assertThat(first.getAmountLocal()).isEqualByComparingTo("8.7939");
        assertThat(second.getAmountLocal()).isEqualByComparingTo("14.2469");
        assertThat(shipment.getTotalOriginal()).isEqualByComparingTo("3.2345");
        assertThat(shipment.getTotalLocal()).isEqualByComparingTo("23.0408");
        assertThat(shipment.getExchangeRate()).isEqualByComparingTo("7.123456");
    }

    @Test
    void missingOrNonPositiveFinanceRateFailsClosed() {
        SalesShipment shipment = new SalesShipment();
        List<SalesShipmentItem> items = List.of(item("1.0000"));

        assertThatThrownBy(() -> SalesShipmentService.applyPostingRateSnapshot(
                shipment, items, null))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("汇率必须大于 0");
        assertThatThrownBy(() -> SalesShipmentService.applyPostingRateSnapshot(
                shipment, items, BigDecimal.ZERO))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("汇率必须大于 0");
        assertThatThrownBy(() -> SalesShipmentService.applyPostingRateSnapshot(
                shipment, items, new BigDecimal("-1")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("汇率必须大于 0");
    }

    @Test
    void settlementSnapshotUsesResolvedUuidShadowAndOnlyPositiveClientTerms() {
        LocalDate billDate = LocalDate.of(2026, 2, 1);
        java.util.UUID methodId = java.util.UUID.randomUUID();

        SalesShipmentService.ClientSettlementSnapshot snapshot =
                SalesShipmentService.settlementSnapshot(
                        8, 30, billDate, methodId, true);
        assertThat(snapshot.settlementStyleLegacy()).isEqualTo((short) 8);
        assertThat(snapshot.settlementMethodId()).isEqualTo(methodId);
        assertThat(snapshot.cashSettlement()).isTrue();
        assertThat(snapshot.dueDate()).isEqualTo(billDate.plusDays(30));

        SalesShipmentService.ClientSettlementSnapshot zeroDay =
                SalesShipmentService.settlementSnapshot(
                        null, 0, billDate, null, false);
        assertThat(zeroDay.settlementStyleLegacy()).isNull();
        assertThat(zeroDay.dueDate()).isEqualTo(billDate);

        assertThat(SalesShipmentService.settlementSnapshot(
                null, -5, billDate, null, false).dueDate()).isEqualTo(billDate);
    }

    private static SalesShipmentItem item(String original) {
        SalesShipmentItem item = new SalesShipmentItem();
        item.setAmountOriginal(new BigDecimal(original));
        item.setAmountLocal(null);
        return item;
    }
}
