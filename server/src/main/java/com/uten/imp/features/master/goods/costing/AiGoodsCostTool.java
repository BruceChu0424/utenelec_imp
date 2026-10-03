package com.uten.imp.features.master.goods.costing;

import com.uten.imp.application.port.AiChatToolPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.goods.dto.GoodsListItem;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.CurrentAuthorityGuard;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.ArrayList;
import java.util.Map;
import java.util.UUID;
import java.util.Set;
import java.util.stream.Collectors;

/** Financial facts stay in the application; only a bounded lookup intent reaches the model. */
@Component
@RequiredArgsConstructor
public class AiGoodsCostTool implements AiChatToolPort {
    private final AiChatAccessPolicy access;
    private final SecurityContextCurrentUser current;
    private final GoodsService goods;
    private final GoodsCostSheetService costs;

    @Override public String name() { return "query_goods_cost"; }
    @Override public String title() { return "查询货品成本"; }
    @Override public String description() { return "财务人员按物料或货品名称、编码查询可见的成本单。结果包含成本口径、状态、币别和单位；匹配多件时要求用户提供准确货品编码。"; }
    @Override public String domain() { return "FINANCE"; }
    @Override public Map<String, Object> parameters() {
        return Map.of("type", "object", "additionalProperties", false,
                "properties", Map.of("goodsKeyword", Map.of("type", "string", "minLength", 1, "maxLength", 100)),
                "required", List.of("goodsKeyword"));
    }
    @Override public boolean available() {
        return access.hasDomain(domain()) && current.get().filter(actor -> actor.isSuperAdmin()
                || actor.getPermissions().containsAll(List.of("goods:view", "goods:cost:view"))).isPresent();
    }

    @Override
    @Transactional(readOnly = true)
    public Map<String, Object> execute(Map<String, Object> arguments) {
        access.requireDomain(domain());
        CurrentAuthorityGuard.requireAll("goods:view", "goods:cost:view");
        if (arguments == null || !arguments.keySet().equals(Set.of("goodsKeyword"))) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "成本查询只能包含货品名称或编码");
        }
        Object raw = arguments == null ? null : arguments.get("goodsKeyword");
        if (!(raw instanceof String keyword) || keyword.isBlank() || keyword.length() > 100) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请提供明确的物料名称或编码");
        }
        String query = keyword.strip();
        // Existing GoodsService is the sole owner-scope/filter/masking authority.
        var page = goods.list(new GoodsQueryFilter(null, null, query, null,
                null, null, null, null, null, null, null, null, null, null, null,
                null, null, null, null, null, null, null, null, null), 1, 11, "code", "asc");
        List<GoodsListItem> candidates = page.getItems();
        List<GoodsListItem> exact = candidates.stream().filter(item -> query.equalsIgnoreCase(item.getCode())).toList();
        if (!exact.isEmpty()) candidates = exact;
        if (candidates.isEmpty()) return reply("在你可见的货品范围内没有找到匹配记录，请核对物料编码。", List.of(), List.of());
        if (candidates.size() != 1 || (exact.isEmpty() && page.getTotal() > 1)) {
            return reply("匹配到多件货品，请提供准确编码后再查询：\n" + candidates.stream().limit(10)
                    .map(item -> item.getCode() + " · " + item.getName()
                            + (item.getSpec() == null ? "" : " · " + item.getSpec()))
                    .collect(Collectors.joining("\n")), candidates.stream().limit(10).map(GoodsListItem::getId).toList(), List.of());
        }
        var selected = candidates.getFirst();
        // Cost service additionally checks all component goods, client and price-evidence scopes.
        var sheets = costs.list(selected.getId());
        String heading = selected.getCode() + " · " + selected.getName();
        if (sheets.isEmpty()) return reply(heading + "\n当前可见范围内没有成本单。未登记成本不能按 0 元回答。", List.of(selected.getId()), List.of());
        StringBuilder reply = new StringBuilder(heading).append("\n以下为成本单测算结果，实际发生额需在成本工作台按期间核对：");
        List<Map<String, Object>> sheetEvidence = new ArrayList<>();
        for (var summary : sheets.stream().limit(5).toList()) {
            var sheet = costs.get(summary.id());
            sheetEvidence.add(Map.of("id", sheet.id().toString(), "version", sheet.version()));
            var calculation = sheet.calculation();
            var totals = calculation.totals();
            reply.append("\n• ").append(sheet.sheetNo()).append(" · ").append(sheet.input().name())
                    .append(" · ").append("CONFIRMED".equals(sheet.status()) ? "已确认" : "未确认测算")
                    .append(" · 版本 ").append(sheet.version())
                    .append("\n  单位成本：").append(value(totals.unitCost())).append(" ")
                    .append(value(calculation.currencyName())).append(" / ").append(value(calculation.unitName()))
                    .append("；测算批量：").append(value(calculation.batchQty()))
                    .append("；已知总成本：").append(value(totals.knownTotal()))
                    .append("；成本状态：").append("COMPLETE".equals(totals.valueState()) ? "资料完整" : "待核，不能视为完整实际成本")
                    .append("；缺价项：").append(totals.missingPriceCount())
                    .append("\n  测算时间：").append(calculation.calculatedAt());
        }
        if (sheets.size() > 5) reply.append("\n仅显示最近 5 张可见成本单，完整记录请进入货品成本工作台。");
        return reply(reply.toString(), List.of(selected.getId()), sheetEvidence);
    }
    @Override
    @Transactional(readOnly = true)
    public void authorizeResultRead(Map<String, Object> evidence) {
        access.requireDomain(domain());
        CurrentAuthorityGuard.requireAll("goods:view", "goods:cost:view");
        if (evidence == null || !(evidence.get("goodsIds") instanceof List<?> goodsIds)
                || !(evidence.get("sheets") instanceof List<?> sheets)
                || goodsIds.size() > 10 || sheets.size() > 5) throw changed();
        for (Object id : goodsIds) costs.requireGoodsScope(uuid(id));
        for (Object raw : sheets) {
            if (!(raw instanceof Map<?, ?> item) || !(item.get("version") instanceof Number version)) throw changed();
            var sheet = costs.get(uuid(item.get("id")));
            // If references changed since the answer, validating the new sheet would not prove the
            // old answer's scope. Require a new query instead of replaying its old financial facts.
            if (sheet.version() != version.longValue()) throw changed();
        }
    }

    private static UUID uuid(Object value) {
        try { return UUID.fromString((String) value); }
        catch (RuntimeException malformed) { throw changed(); }
    }
    private static ApiException changed() {
        return new ApiException(ErrorCode.FORBIDDEN, "成本记录或数据范围已变化，请重新查询");
    }
    private static String value(String value) { return value == null || value.isBlank() ? "未登记" : value; }
    private static Map<String, Object> reply(String value, List<UUID> goods, List<Map<String, Object>> sheets) {
        return Map.of("reply", value, "_toolEvidence", Map.of("goodsIds", goods.stream().map(UUID::toString).toList(), "sheets", sheets));
    }
}
