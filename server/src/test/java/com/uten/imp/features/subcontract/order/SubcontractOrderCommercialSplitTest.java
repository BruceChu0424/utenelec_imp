package com.uten.imp.features.subcontract.order;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.subcontract.order.dto.OrderItemLine;
import com.uten.imp.features.subcontract.order.dto.OrderSaveRequest;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * 行级商业条款拆单口径（2026-09，与采购同构）：createBatch 按「委外商+结算方式+
 * 币种+汇率+税率」组合分组；单张创建/编辑行值必须与表头一致。
 */
class SubcontractOrderCommercialSplitTest {

    @Test
    void sameSupplierDifferentTermsSplitsIntoSeparateGroups() {
        UUID supplier = UUID.randomUUID();
        UUID settlement = UUID.randomUUID();
        UUID currency = UUID.randomUUID();
        OrderSaveRequest request = new OrderSaveRequest();
        request.setItems(List.of(
                line(supplier, settlement, currency, "1", "0"),
                // 同委外商、不同结算方式 → 不同组合
                line(supplier, UUID.randomUUID(), currency, "1", "0"),
                // 同委外商同条款，汇率 1.0 与 1 数值等价 → 同组
                line(supplier, settlement, currency, "1.0", "0"),
                // 同委外商、不同币种 → 不同组合
                line(supplier, settlement, UUID.randomUUID(), "1", "0")));

        Map<SubcontractOrderService.CommercialGroupKey, List<OrderItemLine>> groups =
                SubcontractOrderService.groupByCommercial(request);

        assertEquals(3, groups.size());
        assertTrue(groups.values().stream().anyMatch(rows -> rows.size() == 2));
    }

    @Test
    void headerFallbackKeepsLegacySingleTermRequestsWorking() {
        UUID supplier = UUID.randomUUID();
        UUID settlement = UUID.randomUUID();
        UUID currency = UUID.randomUUID();
        OrderSaveRequest request = new OrderSaveRequest();
        request.setSupplierId(supplier);
        request.setSettlementMethodId(settlement);
        request.setCurrencyId(currency);
        request.setExchangeRate(BigDecimal.ONE);
        request.setTaxRate(BigDecimal.ZERO);
        request.setItems(List.of(
                line(null, null, null, null, null),
                line(null, null, null, null, null)));

        Map<SubcontractOrderService.CommercialGroupKey, List<OrderItemLine>> groups =
                SubcontractOrderService.groupByCommercial(request);

        assertEquals(1, groups.size());
        assertEquals(supplier,
                groups.keySet().iterator().next().supplierId());
        assertEquals(2, groups.values().iterator().next().size());
    }

    @Test
    void missingTermAfterHeaderFallbackIsRejected() {
        OrderSaveRequest request = new OrderSaveRequest();
        request.setSupplierId(UUID.randomUUID());
        request.setItems(List.of(line(null, null, null, null, null)));

        ApiException error = assertThrows(
                ApiException.class,
                () -> SubcontractOrderService.groupByCommercial(request));
        assertTrue(error.getMessage().contains("结算方式"));

        request.setSettlementMethodId(UUID.randomUUID());
        ApiException currencyError = assertThrows(
                ApiException.class,
                () -> SubcontractOrderService.groupByCommercial(request));
        assertTrue(currencyError.getMessage().contains("币种"));

        request.setCurrencyId(UUID.randomUUID());
        ApiException rateError = assertThrows(
                ApiException.class,
                () -> SubcontractOrderService.groupByCommercial(request));
        assertTrue(rateError.getMessage().contains("汇率"));

        request.setExchangeRate(BigDecimal.ONE);
        request.setTaxRate(BigDecimal.valueOf(-1));
        ApiException badTax = assertThrows(
                ApiException.class,
                () -> SubcontractOrderService.groupByCommercial(request));
        assertTrue(badTax.getMessage().contains("税率"));
    }

    @Test
    void singleOrderRejectsRowTermsThatDifferFromHeader() {
        UUID supplier = UUID.randomUUID();
        UUID settlement = UUID.randomUUID();
        UUID currency = UUID.randomUUID();
        OrderSaveRequest request = new OrderSaveRequest();
        request.setSupplierId(supplier);
        request.setSettlementMethodId(settlement);
        request.setCurrencyId(currency);
        request.setExchangeRate(BigDecimal.ONE);
        request.setTaxRate(BigDecimal.ZERO);
        request.setItems(List.of(
                line(supplier, settlement, currency, "1", "0"),
                // 汇率与表头不一致 → 拒绝
                line(supplier, settlement, currency, "7.2", "0")));

        ApiException error = assertThrows(
                ApiException.class,
                () -> SubcontractOrderService.requireRowsMatchHeaderCommercial(request));
        assertTrue(error.getMessage().contains("一套商业条款"));

        // 行值留空 = 回落表头（合法）
        request.setItems(List.of(
                line(supplier, settlement, currency, "1", "0"),
                line(null, null, null, null, null)));
        assertDoesNotThrow(() ->
                SubcontractOrderService.requireRowsMatchHeaderCommercial(request));
    }

    private static OrderItemLine line(
            UUID supplier, UUID settlement, UUID currency,
            String rate, String tax) {
        OrderItemLine line = new OrderItemLine();
        line.setGoodsId(UUID.randomUUID());
        line.setQty(BigDecimal.ONE);
        line.setSupplierId(supplier);
        line.setSettlementMethodId(settlement);
        line.setCurrencyId(currency);
        line.setExchangeRate(rate == null ? null : new BigDecimal(rate));
        line.setTaxRate(tax == null ? null : new BigDecimal(tax));
        return line;
    }
}
