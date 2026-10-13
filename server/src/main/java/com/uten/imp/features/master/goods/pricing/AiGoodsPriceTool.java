package com.uten.imp.features.master.goods.pricing;

import com.uten.imp.application.port.AiChatToolPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.CurrentAuthorityGuard;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

import static com.uten.imp.features.master.goods.pricing.GoodsPriceContracts.*;

/** Local financial evidence and deterministic explanations; private prices never go to the AI provider. */
@Component
@RequiredArgsConstructor
public class AiGoodsPriceTool implements AiChatToolPort {
    private final AiChatAccessPolicy access;
    private final SecurityContextCurrentUser current;
    private final GoodsService goods;
    private final GoodsPriceAnalysisService prices;

    @Override public String name() { return "query_goods_price_analysis"; }
    @Override public String title() { return "查询货品价格分析"; }
    @Override public String description() {
        return "按准确货品编码或名称查询采购价、委外加工价或销售价历史、可比均价、今日参考区间及依据。"
                + "kind为PURCHASE/SUBCONTRACT/SALES；days为1至366，默认180。quantity为本次比较数量。"
                + "销售targetMarginRate为毛利率小数（0.20表示20%，范围0至小于1），只按已确认且适用的成本测算给报价参考。"
                + "样本不足、口径不同或成本待核会说明原因，不推测实时市场价格，不改变单据。";
    }
    @Override public String domain() { return "FINANCE"; }
    @Override public boolean rememberQueryArguments() { return true; }
    @Override public boolean available() {
        return access.hasDomain(domain()) && current.get().filter(actor -> actor.isSuperAdmin()
                || actor.getPermissions().containsAll(List.of("goods:view", "goods:price_analysis:view"))).isPresent();
    }
    @Override public Map<String,Object> parameters() {
        return Map.of("type", "object", "additionalProperties", false, "required", List.of("goodsKeyword", "kind"),
                "properties", Map.of("goodsKeyword", Map.of("type", "string", "minLength", 1, "maxLength", 100),
                    "kind", Map.of("type", "string", "enum", List.of("PURCHASE", "SUBCONTRACT", "SALES")),
                    "days", Map.of("type", "integer", "minimum", 1, "maximum", 366),
                    "quantity", Map.of("type", "string", "pattern", "[0-9]+(?:\\.[0-9]+)?", "maxLength", 30),
                    "targetMarginRate", Map.of("type", "string", "description", "毛利率小数，0.20表示20%，范围0至小于1", "pattern", "[0-9]+(?:\\.[0-9]+)?", "maxLength", 30)));
    }

    @Override @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public Map<String,Object> execute(Map<String,Object> args) {
        requireAccess();
        if (args == null || !Set.of("goodsKeyword", "kind", "days", "quantity", "targetMarginRate").containsAll(args.keySet())
                || !(args.get("goodsKeyword") instanceof String keyword) || keyword.isBlank() || keyword.length() > 100) throw invalid();
        Options options = options(args);
        String text = keyword.strip();
        var page = goods.list(new GoodsQueryFilter(null, null, text, null, null, null, null, null, null, null,
                null, null, null, null, null, null, null, null, null, null, null, null, null, null), 1, 11, "code", "asc");
        var candidates = page.getItems();
        var exact = candidates.stream().filter(item -> text.equalsIgnoreCase(item.getCode())).toList();
        if (!exact.isEmpty()) candidates = exact;
        if (candidates.isEmpty()) return Map.of("reply", "没有找到这件货品，请核对名称或编码。", "_toolEvidence", Map.of("goodsIds", List.of()));
        if (candidates.size() != 1 || exact.isEmpty() && page.getTotal() > 1) {
            return Map.of("reply", "有多个货品，请提供准确编码：\n" + candidates.stream().limit(10)
                    .map(item -> item.getCode() + " · " + item.getName()).collect(Collectors.joining("\n")),
                    "_toolEvidence", Map.of("goodsIds", candidates.stream().limit(10).map(item -> item.getId().toString()).toList()));
        }
        var selected = candidates.getFirst();
        Query query = query(selected.getId(), options);
        Analysis result = prices.analysis(query);
        StringBuilder answer = new StringBuilder(result.goodsName()).append(" (").append(result.goodsCode()).append(")\n")
                .append(result.explanation());
        if ("READY".equals(result.status()) && result.referencePrice() != null) {
            answer.append("\n今日参考：").append(result.referencePrice()).append("；历史加权均价：")
                    .append(result.weightedAveragePrice()).append("；历史参考区间：")
                    .append(result.lowerReferencePrice()).append("～").append(result.upperReferencePrice())
                    .append(" ").append(result.context().currencyName()).append("/").append(result.context().unitName())
                    .append("。独立订单 ").append(result.independentOrderCount()).append(" 张，最近交易日期：")
                    .append(result.lastBusinessDate()).append("。");
        } else {
            answer.append("\n可比记录不足、过旧或尚未完整读取，暂不能给出可靠的今日议价建议。");
            if (result.weightedAveragePrice() != null) answer.append("历史可比加权均价：")
                    .append(result.weightedAveragePrice()).append("；独立订单 ").append(result.independentOrderCount())
                    .append(" 张，最近交易日期：").append(result.lastBusinessDate()).append("。");
        }
        if (result.costSummary() != null) {
            var basis = result.costSummary();
            answer.append("\n").append(basis.explanation());
            if (basis.suggestedPrice() != null) answer.append("\n确认测算成本的报价参考：").append(basis.suggestedPrice())
                    .append(" ").append(basis.currencyName()).append("/").append(basis.unitName())
                    .append("（测算单 ").append(basis.sheetNo()).append("；每批 ")
                    .append(basis.batchQuantity()).append("）。");
            if (!basis.missingCostComponents().isEmpty()) answer.append("\n报价依据还需核对：")
                    .append(basis.missingCostComponents().stream().map(AiGoodsPriceTool::costGap).collect(Collectors.joining("；")));
        }
        Map<String,Object> evidence = new LinkedHashMap<>();
        evidence.put("goodsIds", List.of(selected.getId().toString()));
        evidence.put("goodsId", selected.getId().toString());
        evidence.put("kind", options.kind().name()); evidence.put("days", options.days());
        if (options.quantity() != null) evidence.put("quantity", options.quantity());
        if (options.margin() != null) evidence.put("targetMarginRate", options.margin());
        evidence.put("evidenceToken", result.evidenceToken());
        return Map.of("reply", answer.toString(), "_toolEvidence", Map.copyOf(evidence));
    }

    @Override @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public void authorizeResultRead(Map<String,Object> evidence) {
        requireAccess();
        if (evidence == null || !(evidence.get("goodsIds") instanceof List<?> ids) || ids.size() > 10) throw changed();
        try {
            for (Object raw : ids) goods.detail(UUID.fromString((String)raw));
            if (evidence.containsKey("goodsId")) {
                UUID id = UUID.fromString((String)evidence.get("goodsId"));
                if (!ids.contains(id.toString()) || !(evidence.get("evidenceToken") instanceof String token)) throw changed();
                prices.requireCurrentEvidence(query(id, options(evidence)), token);
            }
        } catch (IllegalArgumentException | ClassCastException malformed) { throw changed(); }
    }
    private void requireAccess() {
        access.requireDomain(domain());
        CurrentAuthorityGuard.requireAll("goods:view", "goods:price_analysis:view");
    }
    private record Options(Kind kind, int days, String quantity, String margin) {}
    private static Options options(Map<String,Object> args) {
        try {
            if (!(args.get("kind") instanceof String rawKind)) throw invalid();
            Kind kind = Kind.valueOf(rawKind);
            Object rawDays = args.getOrDefault("days", 180);
            if (!(rawDays instanceof Number number) || number.doubleValue() != number.intValue()) throw invalid();
            int days = number.intValue(); if (days < 1 || days > 366) throw invalid();
            return new Options(kind, days, decimal(args.get("quantity")), decimal(args.get("targetMarginRate")));
        } catch (IllegalArgumentException | ClassCastException malformed) { throw invalid(); }
    }
    private static String decimal(Object value) {
        if (value == null) return null;
        if (!(value instanceof String text) || text.length() > 30 || !text.matches("[0-9]+(?:\\.[0-9]+)?")) throw invalid();
        return text;
    }
    private static Query query(UUID id, Options options) {
        return new Query(id, options.kind(), options.days(), null, null, null, null, null,
                options.quantity(), null, null, null, options.margin(), null);
    }
    private static ApiException invalid() { return new ApiException(ErrorCode.VALIDATION_FAILED, "请提供准确货品、价格类型和有效的比较参数"); }
    private static ApiException changed() { return new ApiException(ErrorCode.FORBIDDEN, "价格依据或访问范围已变化，请重新查询"); }
    private static String costGap(String reason) {
        return switch (reason) {
            case "COST_PERMISSION_REQUIRED" -> "需要相应成本查看授权";
            case "CONFIRMED_COST_REQUIRED" -> "需要适用的已确认成本测算";
            case "COST_COMPONENTS_INCOMPLETE" -> "成本项目尚未核清";
            case "COST_VERSION_REVIEW_REQUIRED" -> "旧成本版本需复制复核并重新确认，原版本继续保留";
            case "COST_BATCH_MISMATCH" -> "本次数量与成本测算批量不同";
            case "COST_CURRENCY_MISMATCH" -> "比较币种与成本版本不同";
            case "COST_UNIT_MISMATCH", "COST_UNIT_RATE_MISMATCH" -> "计价单位或换算率与成本版本不同";
            case "TARGET_MARGIN_REQUIRED" -> "请明确填写目标销售毛利率";
            default -> "成本依据尚待复核";
        };
    }
}
