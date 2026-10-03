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
                + "pending inspection and pending stock-in with unit and time. For a user-supplied warehouse name or business code, "
                + "use warehouseKeyword; the server resolves it only within assigned warehouses and asks to clarify duplicates. "
                + "Optional warehouseId is for an explicitly known UUID. Never supply both warehouse selectors. "
                + "Only current facts are supported, with no historical date parameter; never substitute current stock for yesterday or a past month. "
                + "No costs, arbitrary SQL, other departments, allocation or stock changes.";
    }
    @Override public String domain() { return "WAREHOUSE"; }
    @Override public boolean rememberQueryArguments() { return true; }
    @Override public Map<String, Object> parameters() {
        return Map.of("type", "object", "properties", Map.of(
                "keyword", Map.of("type", "string", "minLength", 1, "maxLength", 80),
                "warehouseKeyword", Map.of("type", "string", "minLength", 1, "maxLength", 80,
                        "description", "User-supplied warehouse name or business code, e.g. 一号仓 or W001. Exact matches take priority; ambiguous names require clarification."),
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
        return Map.of("reply", render(facts, now, false), "detailReply", render(facts, now, true),
                "actions", List.of(), "source", SOURCE,
                "generatedAt", now.toString(), "_toolEvidence", Map.of("source", SOURCE,
                        "arguments", Map.copyOf(arguments), "snapshot", signature(facts)));
    }

    private static String render(InventoryAiChatQueryService.Facts facts, Instant now, boolean detailed) {
        if (facts.rows().isEmpty()) return emptyReply(facts, detailed);
        StringBuilder reply = new StringBuilder(detailed ? "库存明细（" + TIME.format(now) + "）：" : "当前库存：");
        int shown = Math.min(detailed ? 20 : 5, facts.rows().size());
        for (var row : facts.rows().subList(0, shown)) {
            String unit = label(row.unit(), "单位未登记");
            reply.append("\n• ").append(label(row.code(), "未编码")).append(" · ").append(label(row.name(), "未命名货品"));
            if (row.color() != null && !row.color().isBlank()) reply.append("（").append(label(row.color(), "")).append("）");
            reply.append(" · ").append(label(row.warehouseName(), "未命名仓库"))
                    .append("：现有 ").append(row.qty().toPlainString()).append(" ").append(unit)
                    .append("，可用 ").append(row.movable().toPlainString()).append(" ").append(unit);
            if (detailed) reply.append("\n  预留 ").append(row.reserved().toPlainString()).append(" ").append(unit)
                    .append("，待检 ").append(row.pendingInspection().toPlainString()).append(" ").append(unit)
                    .append("，待入库 ").append(row.pendingStockIn().toPlainString()).append(" ").append(unit);
            reply.append("。");
        }
        if (facts.rows().size() > shown) {
            reply.append("\n另有 ").append(facts.rows().size() - shown).append(" 项，");
            if (!detailed) reply.append(facts.rows().size() > 20
                    ? "回复“展开”可再看 15 项；其余请到库存页面查看" : "回复“展开”可看更多");
            else reply.append("请到库存页面查看");
            reply.append("。");
        }
        if (detailed) {
            if (facts.rows().stream().anyMatch(row -> row.pendingInspection().signum() > 0 || row.pendingStockIn().signum() > 0))
                reply.append("\n待检、待入库还不能领用。");
            if (facts.rows().stream().map(InventoryAiChatQueryService.Row::warehouseId).distinct().count() > 1)
                reply.append("\n不同仓库的可用量不能直接相加。");
        }
        return reply.toString();
    }

    private static String emptyReply(InventoryAiChatQueryService.Facts facts, boolean detailed) {
        String note = facts.note();
        if (note.startsWith("当前账号尚未分配")) return "还没设置你的负责仓库，请联系管理员。";
        if (note.startsWith("当前范围没有可查询的核算仓库")) return "暂时没有可查询的仓库。";
        if (note.startsWith("当前可查询仓库较多")) return "仓库较多，请说出要查的仓库名称或编码。";
        if (note.startsWith("匹配到的货品和颜色超过")) return "匹配的货品较多，请补充准确编码或更完整的名称。";
        if (note.startsWith("在当前负责仓库范围内未找到")) return "没找到这个仓库，请核对名称或业务编码。";
        if (note.startsWith("匹配到多个当前有权查询的仓库")) {
            StringBuilder reply = new StringBuilder("找到几个同名仓库，请提供仓库编码：");
            int shown = Math.min(detailed ? 10 : 5, facts.scope().size());
            for (var warehouse : facts.scope().subList(0, shown)) reply.append("\n• ")
                    .append(label(warehouse.code(), "未登记编码")).append(" · ").append(label(warehouse.name(), "未命名仓库"));
            if (facts.scope().size() > shown) reply.append("\n还有其他匹配仓库，请提供更完整的名称或编码。");
            return reply.toString();
        }
        if (note.startsWith("当前范围未找到匹配的有效货品"))
            return "没找到该物料，请核对名称或编码。没找到不代表库存为 0。";
        return "暂时没查到库存，请稍后再试。";
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
        if (arguments == null || !Set.of("keyword", "warehouseId", "warehouseKeyword").containsAll(arguments.keySet())
                || !(arguments.get("keyword") instanceof String keyword)
                || keyword.isBlank() || keyword.length() > 80 || keyword.codePoints().anyMatch(Character::isISOControl))
            throw invalid();
        UUID warehouse = null;
        String warehouseKeyword = null;
        if (arguments.containsKey("warehouseKeyword")) {
            if (arguments.containsKey("warehouseId") || !(arguments.get("warehouseKeyword") instanceof String value)
                    || value.isBlank() || value.length() > 80 || value.codePoints().anyMatch(Character::isISOControl)) throw invalid();
            warehouseKeyword = value.strip();
        }
        if (arguments.containsKey("warehouseId")) {
            if (!(arguments.get("warehouseId") instanceof String value) || !value.matches(UUID_PATTERN)) throw invalid();
            warehouse = UUID.fromString(value);
        }
        return new InventoryAiChatQueryService.Request(keyword.strip(), warehouse, warehouseKeyword);
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
        // Twenty rows must remain within the chat contract's 16,000-character bound.
        // Only descriptive labels are shortened; physical quantities retain their exact precision.
        return safe.length() <= 64 ? safe : safe.substring(0, 63) + "…";
    }
    private static ApiException invalid() { return new ApiException(ErrorCode.VALIDATION_FAILED,
            "请提供 1 至 80 字的物料编码或名称；可选仓库名称或业务编码与内部仓库编号只能填写一种"); }
    private static ApiException changed() { return new ApiException(ErrorCode.FORBIDDEN,
            "库存对象、数量或负责仓库范围已变化，请重新查询当前库存"); }
}
