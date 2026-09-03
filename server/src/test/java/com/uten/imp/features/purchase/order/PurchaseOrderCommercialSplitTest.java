package com.uten.imp.features.purchase.order;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.purchase.order.dto.OrderItemLine;
import com.uten.imp.features.purchase.order.dto.OrderSaveRequest;
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
 * 行级商业条款拆单口径（2026-09）：createBatch 按「供应商+结账方式+币种+汇率+税率」
 * 组合分组，每组条款归集到该张单的头字段；单张创建/编辑行值必须与表头一致。
 */
class PurchaseOrderCommercialSplitTest {

    @Test
    void sameSupplierDifferentTermsSplitsIntoSeparateGroups() {
        UUID supplier = UUID.randomUUID();
        UUID settlement = UUID.randomUUID();
        UUID otherSettlement = UUID.randomUUID();
        UUID currency = UUID.randomUUID();
        OrderSaveRequest request = new OrderSaveRequest();
        request.setItems(List.of(
                // 完全相同的条款 → 同组
                line(supplier, settlement, currency, "1", "0"),
                line(supplier, settlement, currency, "1", "0"),
                // 同供应商、不同结账方式 → 不同组合
                line(supplier, otherSettlement, currency, "1", "0"),
                // 同供应商同条款，汇率 2 与 2.0 数值等价 → 同组
                line(supplier, settlement, currency, "2", "0"),
                line(supplier, settlement, currency, "2.0", "0"),
                // 同供应商同条款、不同税率 → 不同组合
                line(supplier, settlement, currency, "1", "13")));

        Map<PurchaseOrderService.CommercialGroupKey, List<OrderItemLine>> groups =
                PurchaseOrderService.groupByCommercial(request);

        // 4 组：基准条款、不同结账方式、汇率 2（两行合并）、税率 13
        assertEquals(4, groups.size());
        assertTrue(groups.keySet().stream().anyMatch(key ->
                key.supplierId().equals(supplier)
                        && key.settlementMethodId().equals(settlement)
                        && key.currencyId().equals(currency)
                        && key.exchangeRate().compareTo(BigDecimal.ONE) == 0
                        && key.taxRate().compareTo(BigDecimal.ZERO) == 0));
        assertTrue(groups.keySet().stream().anyMatch(key ->
                key.settlementMethodId().equals(otherSettlement)));
        // 汇率 2 与 2.0 归并同组（数值等价）
        assertTrue(groups.values().stream().anyMatch(rows -> rows.size() == 2
                && rows.stream().allMatch(row ->
                        row.getExchangeRate().compareTo(BigDecimal.valueOf(2)) == 0)));
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

        Map<PurchaseOrderService.CommercialGroupKey, List<OrderItemLine>> groups =
                PurchaseOrderService.groupByCommercial(request);

        assertEquals(1, groups.size());
        Map.Entry<PurchaseOrderService.CommercialGroupKey, List<OrderItemLine>> only =
                groups.entrySet().iterator().next();
        assertEquals(supplier, only.getKey().supplierId());
        assertEquals(settlement, only.getKey().settlementMethodId());
        assertEquals(currency, only.getKey().currencyId());
        assertEquals(2, only.getValue().size());
    }

    @Test
    void missingTermAfterHeaderFallbackIsRejected() {
        OrderSaveRequest request = new OrderSaveRequest();
        request.setSupplierId(UUID.randomUUID());
        // 头与行都不带结账方式 → 拒绝
        request.setItems(List.of(line(null, null, null, null, null)));

        ApiException error = assertThrows(
                ApiException.class,
                () -> PurchaseOrderService.groupByCommercial(request));
        assertTrue(error.getMessage().contains("结账方式"));

        request.setSettlementMethodId(UUID.randomUUID());
        // 币种缺失（头行皆空）→ 拒绝
        ApiException currencyError = assertThrows(
                ApiException.class,
                () -> PurchaseOrderService.groupByCommercial(request));
        assertTrue(currencyError.getMessage().contains("币种"));

        request.setCurrencyId(UUID.randomUUID());
        // 汇率缺失（头行皆空）→ 拒绝
        ApiException rateError = assertThrows(
                ApiException.class,
                () -> PurchaseOrderService.groupByCommercial(request));
        assertTrue(rateError.getMessage().contains("汇率"));

        request.setExchangeRate(BigDecimal.ZERO);
        ApiException badRate = assertThrows(
                ApiException.class,
                () -> PurchaseOrderService.groupByCommercial(request));
        assertTrue(badRate.getMessage().contains("汇率"));

        request.setExchangeRate(BigDecimal.ONE);
        request.setTaxRate(BigDecimal.valueOf(101));
        ApiException badTax = assertThrows(
                ApiException.class,
                () -> PurchaseOrderService.groupByCommercial(request));
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
                line(supplier, settlement, UUID.randomUUID(), "1", "0")));

        ApiException error = assertThrows(
                ApiException.class,
                () -> PurchaseOrderService.requireRowsMatchHeaderCommercial(request));
        assertTrue(error.getMessage().contains("一套商业条款"));

        // 行值留空 = 回落表头（合法）
        request.setItems(List.of(
                line(supplier, settlement, currency, "1", "0"),
                line(null, null, null, null, null)));
        assertDoesNotThrow(() ->
                PurchaseOrderService.requireRowsMatchHeaderCommercial(request));
    }

    private static OrderItemLine line(
            UUID supplier, UUID settlement, UUID currency,
            String rate, String tax) {
        OrderItemLine line = new OrderItemLine();
        line.setGoodsId(UUID.randomUUID());
        line.setRequestItemId(UUID.randomUUID());
        line.setQty(BigDecimal.ONE);
        line.setSupplierId(supplier);
        line.setSettlementMethodId(settlement);
        line.setCurrencyId(currency);
        line.setExchangeRate(rate == null ? null : new BigDecimal(rate));
        line.setTaxRate(tax == null ? null : new BigDecimal(tax));
        return line;
    }
}
