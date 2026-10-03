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
    public static final String SALES_EDIT = "SALES_EDIT";
    public static final String CUSTOMER_ACCEPT = "CUSTOMER_ACCEPT";
    public static final String CANCEL = "CANCEL";
    public static final String CONVERT = "CONVERT";

    private static final Map<String, String> LABELS = Map.ofEntries(
            Map.entry(SUBMIT, "提交财务核价"), Map.entry(WITHDRAW, "销售撤回"),
            Map.entry(FINANCE_EDIT, "财务修改"), Map.entry(RETURN, "财务退回"),
            Map.entry(CONFIRM, "财务确认"), Map.entry(REOPEN, "销售重新修改"),
            Map.entry(FINANCE_REOPEN, "财务撤销确认"), Map.entry(SALES_EDIT, "销售修改"),
            Map.entry(CUSTOMER_ACCEPT, "销售确认客户接受"), Map.entry(CANCEL, "取消报价"),
            Map.entry(CONVERT, "生成订货草稿"));

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
        return history(quoteId, false);
    }

    /** Price permissions apply to immutable snapshots as well as current rows. */
    public List<QuoteRevisionDto> history(UUID quoteId, boolean masked) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT log.revision, log.action, COALESCE(actor.full_name, ''), log.reason, log.created_at,
                               CAST(log.snapshot AS text)
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
                    NativeValueConverters.toOffsetDateTime(row[4]), visibleSnapshot(row[5], masked)));
        }
        return out;
    }

    private JsonNode visibleSnapshot(Object raw, boolean masked) {
        if (raw == null) return null;
        try {
            JsonNode snapshot = objectMapper.readTree(raw.toString());
            if (masked && snapshot instanceof ObjectNode root) {
                root.remove(List.of("totalOriginal", "totalLocal"));
                for (JsonNode item : root.path("lines")) {
                    if (!(item instanceof ObjectNode line)) continue;
                    line.remove(List.of("price", "discount", "amount", "clientPrice"));
                    JsonNode columns = line.get("extraColumns");
                    if (columns != null && columns.isArray()) {
                        List<com.uten.imp.common.columns.ExtraColumnSnapshot> values = objectMapper.convertValue(columns,
                                new com.fasterxml.jackson.core.type.TypeReference<>() {});
                        line.set("extraColumns", objectMapper.valueToTree(
                                com.uten.imp.common.columns.BusinessColumnService.visible(values, true)));
                    }
                }
            }
            return snapshot;
        } catch (JsonProcessingException malformed) {
            throw new IllegalStateException("quote revision snapshot is unreadable", malformed);
        }
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
        putText(root, "clientId", quote.getClientId());
        putText(root, "billDate", quote.getBillDate());
        putText(root, "sellerId", quote.getSellerId());
        Object[] parties = (Object[]) em.createNativeQuery("""
                SELECT COALESCE(c.name, ''), COALESCE(s.full_name, m.full_name, ''), COALESCE(sm.name, '')
                FROM sales_quotes q
                LEFT JOIN clients c ON c.id = q.client_id
                LEFT JOIN employees s ON s.id = q.seller_id
                LEFT JOIN employees m ON m.id = q.maker_id
                LEFT JOIN settlement_methods sm ON sm.id = q.settlement_method_id
                WHERE q.id = :id
                """).setParameter("id", quote.getId()).getSingleResult();
        putText(root, "clientName", parties[0]);
        putText(root, "sellerName", parties[1]);
        putText(root, "settlementMethodName", parties[2]);
        putText(root, "deliverDate", quote.getDeliverDate());
        putText(root, "contractNo", quote.getContractNo());
        putText(root, "remark", quote.getRemark());
        putText(root, "customerAcceptedAt", quote.getCustomerAcceptedAt());
        putText(root, "cancelReason", quote.getCancelReason());
        putText(root, "validUntil", quote.getValidUntil());
        putText(root, "settlementMethodId", quote.getSettlementMethodId());
        putText(root, "currencyId", quote.getCurrencyId());
        putText(root, "financeRemark", quote.getFinanceRemark());
        putText(root, "clientFileCurrency", quote.getClientFileCurrency());
        putDecimal(root, "totalOriginal", quote.getTotalOriginal());
        ArrayNode lines = root.putArray("lines");
        Map<UUID, String> unitNames = referenceNames("units", items == null ? List.of()
                : items.stream().map(SalesQuoteItem::getUnitId).filter(java.util.Objects::nonNull).distinct().toList());
        Map<UUID, String> colorNames = referenceNames("colors", items == null ? List.of()
                : items.stream().map(SalesQuoteItem::getColorId).filter(java.util.Objects::nonNull).distinct().toList());
        for (SalesQuoteItem item : items == null ? List.<SalesQuoteItem>of() : items) {
            ObjectNode line = lines.addObject();
            putText(line, "id", item.getId());
            if (item.getLineNo() != null) line.put("lineNo", item.getLineNo());
            putText(line, "goodsId", item.getGoodsId());
            putText(line, "goodsCode", item.getGoodsCodeSnapshot());
            putText(line, "goodsName", item.getGoodsNameSnapshot());
            putText(line, "colorId", item.getColorId());
            putText(line, "unitId", item.getUnitId());
            putText(line, "unitName", item.getUnitId() == null ? null : unitNames.get(item.getUnitId()));
            putText(line, "colorName", item.getColorId() == null ? null : colorNames.get(item.getColorId()));
            putDecimal(line, "unitRate", item.getUnitRate());
            putDecimal(line, "qty", item.getQty());
            putDecimal(line, "price", item.getPrice());
            putDecimal(line, "discount", item.getDiscount());
            putText(line, "priceSource", item.getPriceSource());
            putDecimal(line, "amount", item.getAmountOriginal());
            putDecimal(line, "clientPrice", item.getClientPrice());
            putText(line, "clientModel", item.getClientModel());
            putText(line, "clientGoodsName", item.getClientGoodsName());
            putText(line, "remark", item.getRemark());
            line.set("extraColumns", objectMapper.valueToTree(item.getExtraColumns()));
            line.put("goodsNameEn", item.getGoodsNameEnSnapshot());
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

    private Map<UUID, String> referenceNames(String table, List<UUID> ids) {
        if (ids.isEmpty()) return Map.of();
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("SELECT id, name FROM " + table + " WHERE id IN (:ids)")
                .setParameter("ids", ids).getResultList();
        Map<UUID, String> names = new HashMap<>();
        rows.forEach(row -> names.put((UUID) row[0], (String) row[1]));
        return names;
    }

    private static void putDecimal(ObjectNode node, String key, BigDecimal value) {
        if (value != null) node.put(key, value.stripTrailingZeros().toPlainString());
    }
}
