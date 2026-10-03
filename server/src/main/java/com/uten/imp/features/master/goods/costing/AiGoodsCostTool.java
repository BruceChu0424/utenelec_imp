package com.uten.imp.features.master.goods.costing;

import com.uten.imp.application.port.AiChatToolPort;
import com.uten.imp.application.port.GoodsActualCostQueryPort;
import com.uten.imp.common.time.BusinessTime;
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
import org.springframework.transaction.annotation.Isolation;

import java.util.List;
import java.util.ArrayList;
import java.util.Map;
import java.util.UUID;
import java.util.Set;
import java.util.stream.Collectors;
import java.time.LocalDate;
import java.time.temporal.ChronoUnit;
import java.math.BigDecimal;

/** Financial facts stay in the application; only a bounded lookup intent reaches the model. */
@Component
@RequiredArgsConstructor
public class AiGoodsCostTool implements AiChatToolPort {
    private final AiChatAccessPolicy access;
    private final SecurityContextCurrentUser current;
    private final GoodsService goods;
    private final GoodsCostSheetService costs;
    private final GoodsActualCostSnapshotService actual;

    @Override public String name() { return "query_goods_cost"; }
    @Override public String title() { return "查询货品成本"; }
    @Override public String description() { return "财务按货品名称或编码查询最新可见确认成本单与期间实际成本依据。basis可选ESTIMATE/ACTUAL/BOTH，默认BOTH；实际期间默认最近90天，日期成对且最多366天。实际仅库存生产成本口径，未覆盖人工和制造费用时不会称为完整成本；歧义需准确货品编码。"; }
    @Override public String domain() { return "FINANCE"; }
    @Override public Map<String, Object> parameters() {
        return Map.of("type", "object", "additionalProperties", false,
                "properties", Map.of("goodsKeyword", Map.of("type", "string", "minLength", 1, "maxLength", 100),
                        "basis", Map.of("type", "string", "enum", List.of("ESTIMATE", "ACTUAL", "BOTH")),
                        "dateFrom", Map.of("type", "string", "pattern", "[0-9]{4}-[0-9]{2}-[0-9]{2}"),
                        "dateTo", Map.of("type", "string", "pattern", "[0-9]{4}-[0-9]{2}-[0-9]{2}")),
                "required", List.of("goodsKeyword"));
    }
    @Override public boolean available() {
        return access.hasDomain(domain()) && current.get().filter(actor -> actor.isSuperAdmin()
                || actor.getPermissions().containsAll(List.of("goods:view", "goods:cost:view"))).isPresent();
    }

    @Override
    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public Map<String, Object> execute(Map<String, Object> arguments) {
        access.requireDomain(domain());
        CurrentAuthorityGuard.requireAll("goods:view", "goods:cost:view");
        if (arguments == null || !Set.of("goodsKeyword", "basis", "dateFrom", "dateTo").containsAll(arguments.keySet())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "成本查询只能包含货品名称或编码");
        }
        Object raw = arguments == null ? null : arguments.get("goodsKeyword");
        if (!(raw instanceof String keyword) || keyword.isBlank() || keyword.length() > 100) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请提供明确的物料名称或编码");
        }
        QueryOptions options = options(arguments);
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
        // Cost service additionally checks all component goods and client scopes.
        var sheets = "ACTUAL".equals(options.basis()) ? List.<GoodsCostContracts.SheetSummary>of() : costs.list(selected.getId());
        String heading = selected.getCode() + " · " + selected.getName();
        StringBuilder reply = new StringBuilder(heading);
        List<Map<String, Object>> sheetEvidence = new ArrayList<>();
        if (!"ACTUAL".equals(options.basis())) reply.append(sheets.isEmpty()
                ? "\n当前可见范围内没有成本单。未登记成本不能按 0 元回答。"
                : "\n成本单测算: 优先列最新可见确认版本，再列近期测算；须核对各单适用批量与客户条件。");
        List<GoodsCostContracts.SheetSummary> chosen = new ArrayList<>();
        sheets.stream().filter(sheet -> "CONFIRMED".equals(sheet.status())).findFirst().ifPresent(chosen::add);
        for (var sheet : sheets) if (chosen.size() < 3 && chosen.stream().noneMatch(item -> item.id().equals(sheet.id()))) chosen.add(sheet);
        for (var summary : chosen) {
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
        if (sheets.size() > chosen.size()) reply.append("\n本次列出 ").append(chosen.size()).append(" 张可见成本单；其余记录请进入成本工作台核对。");
        Map<String, Object> actualEvidence = null;
        if (!"ESTIMATE".equals(options.basis())) {
            var queryFilter = new GoodsActualCostQueryPort.Query(selected.getId(), null, options.from(), options.to(), null);
            var result = actual.read(queryFilter);
            var snapshot = result.snapshot();
            var summary = snapshot.summary();
            reply.append("\n\n期间实际成本依据: ").append(options.from()).append(" 至 ").append(options.to())
                    .append("，按产出业务日期选取，投入保留完整原成本范围。")
                    .append("\n实际产出基本数量: ").append(decimal(summary.outputQtyBase())).append(" ").append(value(selected.getUnitName()))
                    .append("；已知已分摊产出成本: ").append(decimal(summary.allocatedOutputCostLocal())).append(" 本币")
                    .append("\n").append(summary.pending() ? "实际成本仍待核，当前不能给出可靠单位实际成本。"
                            : "单位库存生产成本: " + decimal(summary.actualUnitCostLocal()) + " 本币 / " + value(selected.getUnitName()))
                    .append("\n").append(summary.fullCostComplete() ? "该实际成本来源已标记完整。"
                            : "这不是完整产品实际成本：当前实际来源未覆盖全部人工与制造费用，不能当作完整成本报价。")
                    .append("\n待核来源数: ").append(summary.pendingSourceCount()).append("；采集时间: ").append(snapshot.capturedAt());
            if (snapshot.costObjects().isEmpty()) reply.append("\n所选期间没有可验证的生产估值依据；缺失不能按零成本处理。");
            actualEvidence = Map.of("goodsId", selected.getId().toString(), "from", options.from().toString(),
                    "to", options.to().toString(), "digest", result.digest());
        }
        reply.append("\n来源: 货品成本工作台 / 成本单及只读实际成本来源。金额未发送给对话模型。");
        Map<String, Object> response = new java.util.LinkedHashMap<>(reply(reply.toString(), List.of(selected.getId()), sheetEvidence));
        if (actualEvidence != null) {
            @SuppressWarnings("unchecked") var evidence = new java.util.LinkedHashMap<>((Map<String, Object>) response.get("_toolEvidence"));
            evidence.put("actual", actualEvidence); response.put("_toolEvidence", evidence);
        }
        return Map.copyOf(response);
    }
    @Override
    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
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
        if (evidence.containsKey("actual")) {
            if (!(evidence.get("actual") instanceof Map<?, ?> item) || !(item.get("digest") instanceof String digest)) throw changed();
            try {
                var query = new GoodsActualCostQueryPort.Query(uuid(item.get("goodsId")), null,
                        LocalDate.parse((String) item.get("from")), LocalDate.parse((String) item.get("to")), null);
                if (!digest.equals(actual.read(query).digest())) throw changed();
            } catch (java.time.DateTimeException | ClassCastException malformed) { throw changed(); }
        }
    }

    private record QueryOptions(String basis, LocalDate from, LocalDate to) {}
    private static QueryOptions options(Map<String, Object> args) {
        Object value = args.getOrDefault("basis", "BOTH");
        if (!(value instanceof String basis) || !Set.of("ESTIMATE", "ACTUAL", "BOTH").contains(basis)) throw invalidPeriod();
        boolean dates = args.containsKey("dateFrom") || args.containsKey("dateTo");
        if (dates && ("ESTIMATE".equals(basis) || !(args.get("dateFrom") instanceof String) || !(args.get("dateTo") instanceof String))) throw invalidPeriod();
        LocalDate today = BusinessTime.today();
        try {
            LocalDate from = dates ? LocalDate.parse((String) args.get("dateFrom")) : today.minusDays(89);
            LocalDate to = dates ? LocalDate.parse((String) args.get("dateTo")) : today;
            if (from.isAfter(to) || to.isAfter(today) || ChronoUnit.DAYS.between(from, to) > 365) throw invalidPeriod();
            return new QueryOptions(basis, from, to);
        } catch (java.time.DateTimeException malformed) { throw invalidPeriod(); }
    }
    private static ApiException invalidPeriod() {
        return new ApiException(ErrorCode.VALIDATION_FAILED, "实际成本日期须成对填写、不能晚于今天且最多366天；测算模式不使用期间筛选");
    }
    private static String decimal(BigDecimal value) { return value == null ? "未确认" : value.stripTrailingZeros().toPlainString(); }

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
