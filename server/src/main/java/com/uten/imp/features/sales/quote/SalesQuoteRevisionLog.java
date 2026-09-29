package com.uten.imp.features.sales.quote;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.features.sales.quote.dto.QuoteRevisionDto;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 报价核价修订记录(sales_quote_revision_logs, 只追加, 库级触发器禁止改写)。
 *
 * <p>每次提交、撤回、财务修改、退回、确认、重新打开追加一行, 快照含表头核价字段与全部明细
 * (行 id、货品、数量、单价、折扣、单价来源、金额、文件单价; 数值按精确文本保存)。核价页据此显示历次修订、
 * 「销售提交的折扣」与「上次财务确认的折扣」。
 */
@Component
@RequiredArgsConstructor
public class SalesQuoteRevisionLog {

    public static final String SUBMIT = "SUBMIT";
    public static final String WITHDRAW = "WITHDRAW";
    public static final String FINANCE_EDIT = "FINANCE_EDIT";
    public static final String RETURN = "RETURN";
    public static final String CONFIRM = "CONFIRM";
    public static final String REOPEN = "REOPEN";
    public static final String FINANCE_REOPEN = "FINANCE_REOPEN";

    private static final Map<String, String> LABELS = Map.of(
            SUBMIT, "提交财务核价",
            WITHDRAW, "销售撤回",
            FINANCE_EDIT, "财务修改",
            RETURN, "财务退回",
            CONFIRM, "财务确认",
            REOPEN, "销售重新修改",
            FINANCE_REOPEN, "财务撤销确认");

    private final EntityManager em;
    private final ObjectMapper objectMapper;

    /** 追加一条修订记录; revision 取报价当前(已加 1 后)的核价修订号。 */
    public void append(SalesQuote quote, List<SalesQuoteItem> items, String action,
                       UUID actorEmployeeId, String reason) {
        if (!LABELS.containsKey(action)) {
            throw new IllegalArgumentException("Unknown quote revision action: " + action);
        }
        em.createNativeQuery("""
                        INSERT INTO sales_quote_revision_logs (quote_id, revision, action, actor_id, reason, snapshot)
                        VALUES (:quoteId, :revision, :action, :actor, :reason, CAST(:snapshot AS jsonb))
                        """)
                .setParameter("quoteId", quote.getId())
                .setParameter("revision", quote.getReviewRevision())
                .setParameter("action", action)
                .setParameter("actor", actorEmployeeId)
                .setParameter("reason", reason == null || reason.isBlank() ? null : reason.strip())
                .setParameter("snapshot", snapshot(quote, items))
                .executeUpdate();
    }

    /** 财务做的、会留下核价结果的动作(对照「销售重新提交时改没改财务定的折扣」用)。 */
    public static final List<String> FINANCE_ACTIONS = List.of(FINANCE_EDIT, RETURN, CONFIRM, FINANCE_REOPEN);

    /** 一次修订快照里的折扣: 修订号 + 动作 + 明细行 id → 折扣。 */
    public record DiscountSnapshot(int revision, String action, Map<UUID, BigDecimal> discounts) {
        public BigDecimal discountOf(UUID itemId) {
            return discounts.get(itemId);
        }
    }

    /**
     * 给定动作里最近一次的折扣快照; beforeRevision 非空时只看修订号小于它的记录。没有记录返回 null。
     * 修订号每次核价动作加 1, 所以修订号先后就是动作先后。
     */
    public DiscountSnapshot latestSnapshot(UUID quoteId, List<String> actions, Integer beforeRevision) {
        var query = em.createNativeQuery("""
                        SELECT revision, action, CAST(snapshot AS text)
                        FROM sales_quote_revision_logs
                        WHERE quote_id = :quoteId AND action IN (:actions)
                        """ + (beforeRevision == null ? "" : "  AND revision < :before\n") + """
                        ORDER BY revision DESC, created_at DESC
                        LIMIT 1
                        """)
                .setParameter("quoteId", quoteId)
                .setParameter("actions", actions);
        if (beforeRevision != null) query.setParameter("before", beforeRevision);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = query.getResultList();
        if (rows.isEmpty()) return null;
        Object[] row = rows.getFirst();
        return new DiscountSnapshot(((Number) row[0]).intValue(), (String) row[1],
                row[2] == null ? Map.of() : discounts(row[2].toString()));
    }

    private Map<UUID, BigDecimal> discounts(String snapshotJson) {
        Map<UUID, BigDecimal> discounts = new HashMap<>();
        try {
            JsonNode lines = objectMapper.readTree(snapshotJson).path("lines");
            for (JsonNode line : lines) {
                String id = line.path("id").asText(null);
                String discount = line.path("discount").asText(null);
                if (id != null && discount != null && !discount.isBlank()) {
                    discounts.put(UUID.fromString(id), new BigDecimal(discount));
                }
            }
        } catch (JsonProcessingException | IllegalArgumentException malformed) {
            return Map.of();
        }
        return discounts;
    }

    /** 修订时间线(按发生先后)。 */
    public List<QuoteRevisionDto> history(UUID quoteId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT log.revision, log.action, COALESCE(actor.full_name, ''), log.reason, log.created_at
                        FROM sales_quote_revision_logs log
                        LEFT JOIN employees actor ON actor.id = log.actor_id
                        WHERE log.quote_id = :quoteId
                        ORDER BY log.revision, log.created_at, log.id
                        """)
                .setParameter("quoteId", quoteId)
                .getResultList();
        List<QuoteRevisionDto> out = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            String action = (String) row[1];
            out.add(new QuoteRevisionDto(
                    ((Number) row[0]).intValue(), action, LABELS.getOrDefault(action, action),
                    (String) row[2], (String) row[3],
                    NativeValueConverters.toOffsetDateTime(row[4])));
        }
        return out;
    }

    /** 是否已有某动作记录(判断「重新提交」)。 */
    public boolean hasAction(UUID quoteId, String action) {
        Number count = (Number) em.createNativeQuery("""
                        SELECT COUNT(*) FROM sales_quote_revision_logs
                        WHERE quote_id = :quoteId AND action = :action
                        """)
                .setParameter("quoteId", quoteId)
                .setParameter("action", action)
                .getSingleResult();
        return count.longValue() > 0;
    }

    private String snapshot(SalesQuote quote, List<SalesQuoteItem> items) {
        ObjectNode root = objectMapper.createObjectNode();
        root.put("status", quote.getStatus());
        root.put("reviewRevision", quote.getReviewRevision());
        putText(root, "validUntil", quote.getValidUntil());
        putText(root, "settlementMethodId", quote.getSettlementMethodId());
        putText(root, "currencyId", quote.getCurrencyId());
        putText(root, "financeRemark", quote.getFinanceRemark());
        putText(root, "clientFileCurrency", quote.getClientFileCurrency());
        putDecimal(root, "totalOriginal", quote.getTotalOriginal());
        ArrayNode lines = root.putArray("lines");
        for (SalesQuoteItem item : items == null ? List.<SalesQuoteItem>of() : items) {
            ObjectNode line = lines.addObject();
            putText(line, "id", item.getId());
            if (item.getLineNo() != null) line.put("lineNo", item.getLineNo());
            putText(line, "goodsId", item.getGoodsId());
            putText(line, "goodsCode", item.getGoodsCodeSnapshot());
            putText(line, "goodsName", item.getGoodsNameSnapshot());
            putText(line, "colorId", item.getColorId());
            putDecimal(line, "qty", item.getQty());
            putDecimal(line, "price", item.getPrice());
            putDecimal(line, "discount", item.getDiscount());
            putText(line, "priceSource", item.getPriceSource());
            putDecimal(line, "amount", item.getAmountOriginal());
            putDecimal(line, "clientPrice", item.getClientPrice());
            putText(line, "clientModel", item.getClientModel());
        }
        try {
            return objectMapper.writeValueAsString(root);
        } catch (JsonProcessingException impossible) {
            throw new IllegalStateException("quote revision snapshot serialization failed", impossible);
        }
    }

    private static void putText(ObjectNode node, String key, Object value) {
        if (value != null) node.put(key, value.toString());
    }

    private static void putDecimal(ObjectNode node, String key, BigDecimal value) {
        if (value != null) node.put(key, value.stripTrailingZeros().toPlainString());
    }
}
