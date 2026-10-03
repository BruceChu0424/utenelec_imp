package com.uten.imp.features.stock;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiChatToolPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.stereotype.Component;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.time.format.DateTimeFormatter;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** Model selects a bounded read only; server owns scope, quantities, wording and historical evidence. */
@Component
public class InventoryAiChatTool implements AiChatToolPort {
    private static final String SOURCE = "stock/instant-inventory+warehouse-issue-gate";
    private static final String UUID_PATTERN = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}";
    private static final DateTimeFormatter TIME = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")
            .withZone(BusinessTime.ZONE);
    private final InventoryAiChatQueryService query;
    private final ObjectMapper json;

    public InventoryAiChatTool(InventoryAiChatQueryService query, ObjectMapper json) {
        this.query = query;
        this.json = json;
    }

    @Override public String name() { return "inventory_lookup"; }
    @Override public String title() { return "查询物料库存"; }
    @Override public String description() {
        return "Read current inventory by goods/material code or name within the caller's assigned warehouses. "
                + "Returns physical quantity, effective reservations, conservative per-warehouse issue quantity, "
                + "pending inspection and pending stock-in with unit and time. Optional warehouseId narrows scope. "
                + "No costs, arbitrary SQL, other departments, allocation or stock changes.";
    }
    @Override public String domain() { return "WAREHOUSE"; }
    @Override public Map<String, Object> parameters() {
        return Map.of("type", "object", "properties", Map.of(
                "keyword", Map.of("type", "string", "minLength", 1, "maxLength", 80),
                "warehouseId", Map.of("type", "string", "pattern", UUID_PATTERN,
                        "description", "Only supply an explicitly known warehouse UUID; never invent an ID from a name. Omit to query assigned warehouses.")),
                "required", List.of("keyword"), "additionalProperties", false);
    }
    @Override public boolean available() { return query.available(); }

    @Override public Map<String, Object> execute(Map<String, Object> arguments) {
        if (!available()) throw new ApiException(ErrorCode.FORBIDDEN);
        InventoryAiChatQueryService.Request request = parse(arguments);
        var facts = query.read(request);
        Instant now = Instant.now();
        StringBuilder reply = new StringBuilder("库存查询时间 ").append(TIME.format(now)).append("（北京时间）。");
        if (!facts.note().isEmpty()) reply.append('\n').append(facts.note());
        int shown = 0;
        for (var row : facts.rows()) {
            if (shown++ == 20) break;
            reply.append("\n").append(label(row.code(), "未编码")).append(" · ").append(label(row.name(), "未命名货品"))
                    .append(" / ").append(label(row.color(), "无颜色"))
                    .append(" / 仓库：").append(label(row.warehouseName(), row.warehouseId().toString()))
                    .append(" / 单位：").append(label(row.unit(), "基本单位未维护"))
                    .append("；账面库存 ").append(row.qty().toPlainString())
                    .append("，有效预留占用 ").append(row.reserved().toPlainString())
                    .append("，出库可动量 ").append(row.movable().toPlainString())
                    .append("，待检 ").append(row.pendingInspection().toPlainString())
                    .append("，待入库 ").append(row.pendingStockIn().toPlainString()).append("。");
        }
        if (facts.rows().size() > 20) reply.append("\n仅显示前 20 个仓库/货品/颜色组合，请指定仓库缩小范围。");
        if (!facts.rows().isEmpty()) reply.append("\n有效预留占用包含本仓和未定仓的全局预留；出库可动量已按实际出库闸门扣除有效预留与安全库存，最低为 0。"
                + "全局预留在各仓分别保护，各仓可动量不能相加当作可一次领取总量。待检、待入库不属于可动库存；本查询包含不良品仓，不包含车间线边仓。"
                + "此结果是当前查询快照，实际领取仍以业务单据校验为准。");
        reply.append("\n来源：即时库存 / 库存预留 / 仓库出库校验；只展示当前部门、功能权限和负责仓库范围允许的数据。");
        return Map.of("reply", reply.toString(), "actions", List.of(), "source", SOURCE,
                "generatedAt", now.toString(), "_toolEvidence", Map.of("source", SOURCE,
                        "arguments", Map.copyOf(arguments), "snapshot", signature(facts)));
    }

    @Override public void authorizeResultRead(Map<String, Object> evidence) {
        if (!available()) throw new ApiException(ErrorCode.FORBIDDEN);
        try {
            if (evidence == null || !SOURCE.equals(evidence.get("source"))
                    || !(evidence.get("arguments") instanceof Map<?, ?> arguments)) throw changed();
            @SuppressWarnings("unchecked") Map<String, Object> typed = (Map<String, Object>) arguments;
            if (!signature(query.read(parse(typed))).equals(evidence.get("snapshot"))) throw changed();
        } catch (ApiException invalid) { throw changed(); }
    }

    private static InventoryAiChatQueryService.Request parse(Map<String, Object> arguments) {
        if (arguments == null || !Set.of("keyword", "warehouseId").containsAll(arguments.keySet())
                || !(arguments.get("keyword") instanceof String keyword)
                || keyword.isBlank() || keyword.length() > 80 || keyword.codePoints().anyMatch(Character::isISOControl))
            throw invalid();
        UUID warehouse = null;
        if (arguments.containsKey("warehouseId")) {
            if (!(arguments.get("warehouseId") instanceof String value) || !value.matches(UUID_PATTERN)) throw invalid();
            warehouse = UUID.fromString(value);
        }
        return new InventoryAiChatQueryService.Request(keyword.strip(), warehouse);
    }

    private String signature(InventoryAiChatQueryService.Facts facts) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(json.writeValueAsString(facts).getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException | JsonProcessingException unavailable) {
            throw new IllegalStateException("Inventory evidence unavailable", unavailable);
        }
    }

    private static String label(String value, String fallback) {
        if (value == null || value.isBlank()) return fallback;
        String safe = value.replaceAll("[\\p{Cntrl}]", " ").strip();
        return safe.substring(0, Math.min(safe.length(), 120));
    }
    private static ApiException invalid() { return new ApiException(ErrorCode.VALIDATION_FAILED,
            "请提供 1 至 80 字的物料编码或名称，并仅使用可选的仓库编号限定范围"); }
    private static ApiException changed() { return new ApiException(ErrorCode.FORBIDDEN,
            "库存对象、数量或负责仓库范围已变化，请重新查询当前库存"); }
}
