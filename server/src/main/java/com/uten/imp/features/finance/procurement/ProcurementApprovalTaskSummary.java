package com.uten.imp.features.finance.procurement;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.TaskItemSummary;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;
import java.util.UUID;

/** List and history share the same submitted commercial facts as the review lines. */
final class ProcurementApprovalTaskSummary {
    private ProcurementApprovalTaskSummary() { }

    static List<TaskItemSummary> fromSnapshotItems(String json, ObjectMapper mapper) {
        if (json == null) return List.of();
        try {
            JsonNode items = mapper.readTree(json);
            if (items == null || items.isNull()) return List.of();
            if (!items.isArray()) throw new IllegalArgumentException("Approval items are not an array");
            Map<String, Group> groups = new LinkedHashMap<>();
            int index = 0;
            for (JsonNode item : items) {
                if (!item.isObject()) throw new IllegalArgumentException("Approval item is not an object");
                String rawId = text(item, "unitId");
                UUID unitId = rawId == null ? null : UUID.fromString(rawId);
                String unitName = text(item, "unitName");
                // Missing unit identity cannot justify adding different lines together.
                String key = unitId == null ? "unknown:" + index : unitId + "\u0000" + unitName;
                Group group = groups.computeIfAbsent(key, ignored -> new Group(unitId, unitName));
                BigDecimal quantity = decimal(item, "quantity");
                if (quantity == null) group.missingQuantity = true;
                else group.quantity = group.quantity.add(quantity);
                BigDecimal price = decimal(item, "price");
                if (price == null) group.missingPrice = true;
                else group.prices.add(price);
                index++;
            }
            List<TaskItemSummary> result = new ArrayList<>(groups.size());
            for (Group group : groups.values()) {
                result.add(new TaskItemSummary(group.unitId, group.unitName,
                        group.missingQuantity ? null : group.quantity,
                        List.copyOf(group.prices), group.missingPrice));
            }
            return List.copyOf(result);
        } catch (JsonProcessingException | IllegalArgumentException invalid) {
            throw new IllegalStateException("Invalid approval commercial summary snapshot", invalid);
        }
    }

    private static String text(JsonNode item, String name) {
        JsonNode value = item.get(name);
        if (value == null || value.isNull()) return null;
        String text = value.asText();
        return text.isBlank() ? null : text;
    }

    private static BigDecimal decimal(JsonNode item, String name) {
        String value = text(item, name);
        return value == null ? null : new BigDecimal(value);
    }

    private static final class Group {
        final UUID unitId;
        final String unitName;
        BigDecimal quantity = BigDecimal.ZERO;
        boolean missingQuantity;
        boolean missingPrice;
        final TreeSet<BigDecimal> prices = new TreeSet<>();

        Group(UUID unitId, String unitName) {
            this.unitId = unitId;
            this.unitName = unitName;
        }
    }
}
