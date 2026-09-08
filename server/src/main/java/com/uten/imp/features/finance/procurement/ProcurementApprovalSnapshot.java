package com.uten.imp.features.finance.procurement;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.ProcurementOrderApprovalPort.ItemSnapshot;
import com.uten.imp.application.port.ProcurementOrderApprovalPort.OrderSnapshot;

import java.math.BigDecimal;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.Map;

/** One canonical representation for initial review and quantity-change review. */
final class ProcurementApprovalSnapshot {
    private ProcurementApprovalSnapshot() {}

    static String json(OrderSnapshot snapshot, ObjectMapper mapper) {
        Map<String, Object> header = new LinkedHashMap<>();
        header.put("orderType", snapshot.orderType());
        header.put("orderId", snapshot.orderId());
        header.put("billNo", snapshot.billNo());
        header.put("billDate", snapshot.billDate());
        header.put("supplierId", snapshot.supplierId());
        header.put("warehouseId", snapshot.warehouseId());
        header.put("currencyId", snapshot.currencyId());
        header.put("exchangeRate", decimal(snapshot.exchangeRate()));
        header.put("settlementMethodId", snapshot.settlementMethodId());
        header.put("taxRate", decimal(snapshot.taxRate()));
        header.put("purchaserEmployeeId", snapshot.purchaserEmployeeId());
        header.put("makerEmployeeId", snapshot.makerEmployeeId());
        header.put("deliverDate", snapshot.deliverDate());
        header.put("totalOriginal", decimal(snapshot.totalOriginal()));
        header.put("totalLocal", decimal(snapshot.totalLocal()));
        header.put("items", snapshot.items().stream()
                .sorted(Comparator.comparing(ItemSnapshot::lineNo,
                        Comparator.nullsLast(Integer::compareTo)).thenComparing(ItemSnapshot::itemId))
                .map(ProcurementApprovalSnapshot::item).toList());
        try { return mapper.writeValueAsString(header); }
        catch (JsonProcessingException error) {
            throw new IllegalStateException("审批快照无法序列化", error);
        }
    }

    private static Map<String, Object> item(ItemSnapshot item) {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("itemId", item.itemId());
        row.put("lineNo", item.lineNo());
        row.put("sourceItemId", item.sourceItemId());
        row.put("goodsId", item.goodsId());
        row.put("colorId", item.colorId());
        row.put("unitId", item.unitId());
        row.put("unitRate", decimal(item.unitRate()));
        row.put("qty", decimal(item.qty()));
        row.put("price", decimal(item.price()));
        row.put("amountOriginal", decimal(item.amountOriginal()));
        row.put("amountLocal", decimal(item.amountLocal()));
        row.put("deliverDate", item.deliverDate());
        return row;
    }

    private static String decimal(BigDecimal value) {
        return value == null ? null : value.stripTrailingZeros().toPlainString();
    }
}
