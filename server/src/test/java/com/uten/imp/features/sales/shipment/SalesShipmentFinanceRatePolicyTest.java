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

    // ===== V632 放行记账汇率规则 =====

    private static SalesShipmentService.FinanceRateState usd(String masterRate) {
        return new SalesShipmentService.FinanceRateState(
                "美金", masterRate == null ? null : new BigDecimal(masterRate), false, true);
    }

    @Test
    void financeFilledRateWinsAndIsTaggedManualWhenItDiffersFromTheMaster() {
        var decided = SalesShipmentService.decideFinanceReleaseRate(usd("7.000000"), new BigDecimal("7.200000"));
        assertThat(decided.rate()).isEqualByComparingTo("7.2");
        assertThat(decided.source()).isEqualTo(SalesShipmentService.RATE_SOURCE_FINANCE_MANUAL);

        var same = SalesShipmentService.decideFinanceReleaseRate(usd("7.000000"), new BigDecimal("7.0"));
        assertThat(same.rate()).isEqualByComparingTo("7");
        assertThat(same.source()).isEqualTo(SalesShipmentService.RATE_SOURCE_CURRENCY_MASTER);
    }

    @Test
    void masterRateIsUsedWhenFinanceLeavesTheRateBlank() {
        var decided = SalesShipmentService.decideFinanceReleaseRate(usd("7.123456"), null);
        assertThat(decided.rate()).isEqualByComparingTo("7.123456");
        assertThat(decided.source()).isEqualTo(SalesShipmentService.RATE_SOURCE_CURRENCY_MASTER);
    }

    @Test
    void missingMasterRateOnlyFailsWhenFinanceDidNotFillOne() {
        assertThatThrownBy(() -> SalesShipmentService.decideFinanceReleaseRate(usd("0"), null))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("请在放行时填写记账汇率");
        assertThatThrownBy(() -> SalesShipmentService.decideFinanceReleaseRate(usd(null), null))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("当前 空");
        var filled = SalesShipmentService.decideFinanceReleaseRate(usd("0"), new BigDecimal("7.25"));
        assertThat(filled.rate()).isEqualByComparingTo("7.25");
        assertThat(filled.source()).isEqualTo(SalesShipmentService.RATE_SOURCE_FINANCE_MANUAL);
    }

    @Test
    void baseCurrencyIsAlwaysOneEvenWhenTheMasterRowIsZero() {
        var cny = new SalesShipmentService.FinanceRateState("人民币", BigDecimal.ZERO, true, true);
        var decided = SalesShipmentService.decideFinanceReleaseRate(cny, null);
        assertThat(decided.rate()).isEqualByComparingTo("1");
        assertThat(decided.source()).isEqualTo(SalesShipmentService.RATE_SOURCE_CURRENCY_MASTER);
        assertThat(SalesShipmentService.decideFinanceReleaseRate(cny, new BigDecimal("1.000")).rate())
                .isEqualByComparingTo("1");
        assertThatThrownBy(() -> SalesShipmentService.decideFinanceReleaseRate(cny, new BigDecimal("7.2")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("本位币「人民币」的记账汇率固定为 1");
    }

    @Test
    void financeFilledRateMustBePositiveWithAtMostSixDecimals() {
        assertThatThrownBy(() -> SalesShipmentService.decideFinanceReleaseRate(usd("7"), BigDecimal.ZERO))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("记账汇率必须大于 0");
        assertThatThrownBy(() -> SalesShipmentService.decideFinanceReleaseRate(usd("7"), new BigDecimal("-7.2")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("记账汇率必须大于 0");
        assertThatThrownBy(() -> SalesShipmentService.decideFinanceReleaseRate(usd("7"), new BigDecimal("7.1234567")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("最多保留 6 位小数");
        // 尾零不算位数：7.1234560 等价 7.123456。
        assertThat(SalesShipmentService.decideFinanceReleaseRate(usd("7"), new BigDecimal("7.1234560")).rate())
                .isEqualByComparingTo("7.123456");
    }

    @Test
    void disabledOrUnknownCurrencyFailsClosed() {
        var missing = new SalesShipmentService.FinanceRateState("", null, false, false);
        assertThatThrownBy(() -> SalesShipmentService.decideFinanceReleaseRate(missing, new BigDecimal("7")))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("已停用或不存在");
    }

    private static SalesShipmentItem item(String original) {
        SalesShipmentItem item = new SalesShipmentItem();
        item.setAmountOriginal(new BigDecimal(original));
        item.setAmountLocal(null);
        return item;
    }
}
