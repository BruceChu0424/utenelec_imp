package com.uten.imp.features.finance;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.math.BigDecimal;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Set;

/** Same counterpart + same complete settlement contract => one document. */
public final class FinanceEntryGrouping {
    private FinanceEntryGrouping() {}
    private static final Set<String> SUMS = Set.of("amountOriginal", "accountAmount", "bankFeeAccountAmount", "otherFeeAccountAmount");

    public static List<ObjectNode> group(List<JsonNode> entries, String key) {
        var groups = new LinkedHashMap<String, ObjectNode>();
        for (JsonNode entry : entries) {
            if (!entry.isObject()) throw new ApiException(ErrorCode.VALIDATION_FAILED, "明细格式不正确");
            ObjectNode header = entry.deepCopy();
            header.remove("items");
            header.remove("createIdempotencyKey");
            SUMS.forEach(header::remove);
            if (header.has("receiptKind") && "NONE".equals(header.path("feeSettlementMode").asText())) {
                header.put("feeSettlementMode", "DEDUCTED_FROM_PROCEEDS");
                header.put("feeBearer", "COMPANY");
            }
            String signature = FinanceBatchEntryService.canonical(header).toString();
            var selectedOrders = new java.util.TreeSet<String>();
            for(JsonNode line:entry.path("items")) {
                String selected=line.path("requestedSalesOrderId").asText("").trim();
                if(!selected.isEmpty())selectedOrders.add(selected.toLowerCase(java.util.Locale.ROOT));
            }
            if(!selectedOrders.isEmpty()) {
                ArrayNode selected=header.arrayNode();selectedOrders.forEach(selected::add);
                signature+="|order-sources:"+selected;
            }
            ObjectNode target = groups.get(signature);
            if (target == null) {
                target = entry.deepCopy();
                if (entry.has("createIdempotencyKey")) target.put("createIdempotencyKey", key + "." + groups.size());
                groups.put(signature, target);
            } else {
                if ("NONE".equals(target.path("feeSettlementMode").asText())
                        && !"NONE".equals(entry.path("feeSettlementMode").asText())) {
                    target.set("feeSettlementMode", entry.path("feeSettlementMode"));
                    target.set("feeBearer", entry.path("feeBearer"));
                }
                for (String field : SUMS) {
                    if (entry.hasNonNull(field)) {
                        try {
                            BigDecimal sum = new BigDecimal(target.path(field).asText("0"))
                                    .add(new BigDecimal(entry.get(field).asText()));
                            target.put(field, sum.toPlainString());
                        } catch (NumberFormatException error) {
                            throw new ApiException(ErrorCode.VALIDATION_FAILED, "明细金额格式不正确");
                        }
                    }
                }
                if (entry.path("items").isArray()) {
                    ArrayNode lines = target.withArray("items");
                    entry.path("items").forEach(lines::add);
                }
            }
        }
        return List.copyOf(groups.values());
    }
}
