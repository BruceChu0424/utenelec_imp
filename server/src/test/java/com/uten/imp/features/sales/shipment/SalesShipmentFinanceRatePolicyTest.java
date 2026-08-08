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
    void financeRateRecalculatesEveryShipmentLineAndHeaderSnapshot() {
        SalesShipment shipment = new SalesShipment();
        shipment.setExchangeRate(new BigDecimal("6.500000"));
        shipment.setTotalLocal(new BigDecimal("9999.0000"));

        SalesShipmentItem first = item("1.2345", "1.0000");
        SalesShipmentItem second = item("2.0000", "2.0000");

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
        List<SalesShipmentItem> items = List.of(item("1.0000", "99.0000"));

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
    void settlementSnapshotPrefersShipmentStyleAndUsesOnlyPositiveClientTerms() {
        LocalDate billDate = LocalDate.of(2026, 2, 1);

        SalesShipmentService.ClientSettlementSnapshot overridden =
                SalesShipmentService.settlementSnapshot(
                        8, 6, 30, billDate);
        assertThat(overridden.clientPriceStyle()).isEqualTo(6);
        assertThat(overridden.settlementStyleLegacy()).isEqualTo((short) 8);
        assertThat(overridden.dueDate()).isEqualTo(billDate.plusDays(30));

        SalesShipmentService.ClientSettlementSnapshot fallback =
                SalesShipmentService.settlementSnapshot(
                        null, 6, 0, billDate);
        assertThat(fallback.settlementStyleLegacy()).isEqualTo((short) 6);
        assertThat(fallback.dueDate()).isEqualTo(billDate);

        assertThat(SalesShipmentService.settlementSnapshot(
                null, 6, -5, billDate).dueDate()).isEqualTo(billDate);
    }

    private static SalesShipmentItem item(String original, String oldLocal) {
        SalesShipmentItem item = new SalesShipmentItem();
        item.setAmountOriginal(new BigDecimal(original));
        item.setAmountLocal(new BigDecimal(oldLocal));
        return item;
    }
}
