package com.uten.imp.features.purchase.order;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiChatToolPort;
import com.uten.imp.application.port.ProcurementArrivalControlPort;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.procurement.ProcurementApprovalProjectionQuery;
import com.uten.imp.features.purchase.PurchaseDocumentAccessPolicy;
import com.uten.imp.features.purchase.order.dto.OrderDetail;
import com.uten.imp.features.purchase.order.dto.OrderItemDto;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.text.Normalizer;
import java.time.Clock;
import java.time.LocalDate;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 采购订货单状态查询(AI 助手只读工具, P1-3)。按用户给的订货单号找单, 查看范围与采购订货单详情接口同一口径:
 * 有查看采购订货单或财务订货审批查看权限, 并且是本人归属范围内的单, 或本人是这张单正在待审的财务审核人;
 * 不可见与不存在一样回答。抬头与明细读详情接口本身, 到货登记、来料质检、仓库入库和超量待财务判定按
 * 订货明细聚合(质检记基本单位, 按订货单位换算)。
 *
 * <p>回答里只有状态、日期、数量、货品编码与名称和收货单号; 不带供应商名、人员姓名、价格金额和退回原因原文。
 *
 * <p>查看审计(ADR-105): 每次查到一张本人看得到的单, 写一条与采购订货单详情页相同的查看记录(同一动作与对象表,
 * 对象名称标「AI 助手查询」, 30 分钟内同人同单只记一次, 与详情页同一规则); 单号不存在、不在范围内或没有权限时
 * 不写, 恢复对话时复核旧回答也不算一次查看。
 */
@Component
public class PurchaseOrderAiChatTool implements AiChatToolPort {
    static final String NOT_FOUND = "没有找到你能查看的这张单据。请核对单号是否完整、有没有输错；"
            + "如果这张单不在你的查看范围内(比如由别的同事负责)，这里同样查不到，可以请负责的同事或主管查看。";
    /** The detail page's own view event (PurchaseOrderController#detail); only the display label marks the AI source. */
    static final String VIEW_AUDIT_ACTION = "view_purchase_order_detail";
    static final String VIEW_AUDIT_TARGET = "purchase_orders";
    static final String VIEW_AUDIT_LABEL = "采购订货单(AI 助手查询)";
    private static final String SOURCE = "purchase/order-status";
    private static final int LINE_LIMIT = 20;
    private static final short DRAFT = 0;
    private static final short APPROVED = 1;
    private static final short REVERSED = -1;
    private static final short CANCELED = 2;
    private static final DateTimeFormatter TIME = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")
            .withZone(BusinessTime.ZONE);

    private final AiChatAccessPolicy access;
    private final SecurityContextCurrentUser current;
    private final PurchaseDocumentAccessPolicy documents;
    private final ProcurementApprovalProjectionQuery approvals;
    private final PurchaseOrderService orders;
    private final JdbcTemplate jdbc;
    private final ObjectMapper json;
    private final Clock clock;
    private final AuditDetailViewRecorder viewAudit;

    public PurchaseOrderAiChatTool(AiChatAccessPolicy access, SecurityContextCurrentUser current,
                                   PurchaseDocumentAccessPolicy documents, ProcurementApprovalProjectionQuery approvals,
                                   PurchaseOrderService orders, JdbcTemplate jdbc, ObjectMapper json, Clock clock,
                                   AuditDetailViewRecorder viewAudit) {
        this.access = access; this.current = current; this.documents = documents; this.approvals = approvals;
        this.orders = orders; this.jdbc = jdbc; this.json = json; this.clock = clock; this.viewAudit = viewAudit;
    }

    @Override public String name() { return "purchase_order_status"; }
    @Override public String title() { return "查询采购订货单状态"; }
    @Override public String domain() { return "PURCHASE"; }
    @Override public boolean rememberQueryArguments() { return true; }
    @Override public String description() {
        return "Read the current status of ONE purchase order (采购订货单) by its order number, e.g. CD20261006000001, "
                + "only when the user names that number and asks whether it was approved, whether the goods arrived, were "
                + "inspected or stocked in, or what it is waiting for. The server finds the order only within the caller's "
                + "purchase order scope (the same as the order detail page) and answers 'not found' for anything else. "
                + "Returns the order status and finance approval state, what it is waiting for, order and delivery dates, and "
                + "per-goods ordered, registered arrival, returned, waiting for inspection, passed, failed, stocked-in and "
                + "over-receipt-held-for-finance quantities in the order unit. No supplier names, people, prices, amounts or "
                + "rejection reasons; no history parameter; one order per call.";
    }
    @Override public Map<String, Object> parameters() {
        return Map.of("type", "object", "additionalProperties", false,
                "properties", Map.of("orderNo", Map.of("type", "string", "minLength", 2, "maxLength", 40,
                        "description", "The purchase order number exactly as the user wrote it, e.g. CD20261006000001.")),
                "required", List.of("orderNo"));
    }
    /** The detail page is open to purchase order viewers and to finance reviewers of a pending approval. */
    @Override public boolean available() {
        return access.hasDomain(domain()) && current.get().filter(actor -> actor.isSuperAdmin()
                || actor.getPermissions().contains("purchase_order:view")
                || actor.getPermissions().contains("finance_order_approval:view")).isPresent();
    }
    /** ADR-150: the detail text holds only statuses, dates, quantities, goods and document numbers. */
    @Override public Map<String, Object> modelFacts(Map<String, Object> result) {
        return result.get("detailReply") instanceof String text ? Map.of("facts", text) : Map.of();
    }

    @Override @Transactional(readOnly = true)
    public Map<String, Object> execute(Map<String, Object> arguments) {
        require();
        String orderNo = orderNo(arguments);
        Read read = read(orderNo);
        Facts facts = read.facts();
        String time = TIME.format(clock.instant());
        Map<String, Object> evidence = Map.of("source", SOURCE, "orderNo", orderNo, "snapshot", digest(facts));
        if (!facts.found()) {
            // Unknown and out of scope look the same here and leave no view record either.
            return Map.of("reply", NOT_FOUND, "actions", List.of(), "source", SOURCE, "_toolEvidence", evidence);
        }
        Map<String, Object> result = Map.of("reply", render(facts, time, false), "detailReply", render(facts, time, true),
                "actions", List.of(), "source", SOURCE, "_toolEvidence", evidence);
        // Written before the facts leave this method: if the view cannot be recorded, nothing is answered (fail closed).
        Viewed viewed = read.viewed();
        viewAudit.record(VIEW_AUDIT_ACTION, VIEW_AUDIT_TARGET, viewed.id(), viewed.billNo(), viewed.legacyId(),
                VIEW_AUDIT_LABEL);
        return result;
    }

    @Override @Transactional(readOnly = true)
    public void authorizeResultRead(Map<String, Object> evidence) {
        require();
        if (evidence == null || !evidence.keySet().equals(Set.of("source", "orderNo", "snapshot"))
                || !SOURCE.equals(evidence.get("source"))
                || !(evidence.get("orderNo") instanceof String orderNo)
                || !(evidence.get("snapshot") instanceof String expected) || !expected.matches("[0-9a-f]{64}")) throw changed();
        String normalized;
        try { normalized = orderNo(Map.of("orderNo", orderNo)); }
        catch (ApiException invalid) { throw changed(); }
        // A re-check of a stored answer shows nothing new, so it is not recorded as a view.
        if (!normalized.equals(orderNo) || !expected.equals(digest(read(normalized).facts()))) throw changed();
    }

    // ---------------------------------------------------------------- facts

    record Line(String goods, String unit, String deliverDate, String qty, String received, String returned,
                String waitingInspection, String passed, String failed, String stocked, String held, String heldReceipts) {}
    record Facts(boolean found, String orderNo, String statusText, String waiting, String billDate, String deliverDate,
                 List<Line> lines, int lineCount) {
        static Facts notFound(String orderNo) {
            return new Facts(false, orderNo, null, null, null, null, List.of(), 0);
        }
    }
    /** The order a successful read resolved: the view-audit target only, never part of the facts or their digest. */
    record Viewed(UUID id, String billNo, Integer legacyId) {}
    private record Read(Facts facts, Viewed viewed) {}

    private record Arrival(String unit, String color, BigDecimal rate, BigDecimal waitingBase, BigDecimal passedBase,
                           BigDecimal failedBase, BigDecimal stockedBase, BigDecimal held, String heldUnit,
                           String heldReceipts) {}

    private Read read(String orderNo) {
        List<Map<String, Object>> heads = jdbc.queryForList("""
                SELECT id, maker_id FROM purchase_orders WHERE bill_no = ? AND is_deleted = FALSE
                """, orderNo);
        if (heads.isEmpty()) return new Read(Facts.notFound(orderNo), null);
        UUID orderId = (UUID) heads.getFirst().get("id");
        UUID maker = (UUID) heads.getFirst().get("maker_id");
        // The detail endpoint's own object rule, checked first so that no hidden order is ever read.
        if (!documents.canRead(maker) && !approvals.canCurrentActorReviewPending(ProcurementArrivalControlPort.PURCHASE, orderId))
            return new Read(Facts.notFound(orderNo), null);
        OrderDetail detail = orders.detail(orderId);
        Map<UUID, Arrival> arrivals = arrivals(orderId);
        List<OrderItemDto> items = detail.getItems() == null ? List.of() : detail.getItems();
        List<Line> lines = new ArrayList<>();
        BigDecimal anyWaiting = BigDecimal.ZERO;
        BigDecimal unstocked = BigDecimal.ZERO;
        BigDecimal anyHeld = BigDecimal.ZERO;
        boolean anyReceived = false;
        boolean allReceived = !items.isEmpty();
        for (OrderItemDto item : items) {
            Arrival arrival = arrivals.getOrDefault(item.getId(), new Arrival(null, null, BigDecimal.ONE, BigDecimal.ZERO,
                    BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, null, null));
            BigDecimal qty = zero(item.getQty());
            BigDecimal received = zero(item.getReceivedQty());
            BigDecimal returned = zero(item.getReturnedQty());
            BigDecimal waiting = toOrderUnit(arrival.waitingBase(), arrival.rate());
            BigDecimal passed = toOrderUnit(arrival.passedBase(), arrival.rate());
            BigDecimal stocked = toOrderUnit(arrival.stockedBase(), arrival.rate());
            anyWaiting = anyWaiting.add(waiting);
            unstocked = unstocked.add(passed.subtract(stocked).max(BigDecimal.ZERO));
            anyHeld = anyHeld.add(arrival.held());
            anyReceived |= received.signum() > 0;
            allReceived &= received.subtract(returned).compareTo(qty) >= 0;
            if (lines.size() >= LINE_LIMIT) continue;
            String goods = label(item.getGoodsCodeSnapshot(), "未编码") + " · " + label(item.getGoodsNameSnapshot(), "未命名货品")
                    + (arrival.color() == null ? "" : "(" + label(arrival.color(), "") + ")");
            String held = arrival.held().signum() > 0
                    ? plain(arrival.held()) + (arrival.heldUnit() == null ? "" : " " + label(arrival.heldUnit(), "")) : null;
            lines.add(new Line(goods, label(arrival.unit(), ""), item.getDeliverDate() == null ? null : item.getDeliverDate().toString(),
                    plain(qty), plain(received), plain(returned), plain(waiting), plain(passed),
                    plain(toOrderUnit(arrival.failedBase(), arrival.rate())), plain(stocked), held,
                    arrival.heldReceipts() == null ? null : label(arrival.heldReceipts(), null)));
        }
        short status = detail.getStatus() == null ? DRAFT : detail.getStatus();
        String financeStatus = detail.getFinanceApproval() == null ? null : detail.getFinanceApproval().status();
        String[] state = state(status, detail.isClosed(), financeStatus, anyHeld, anyWaiting, unstocked,
                anyReceived, allReceived, detail.getDeliverDate());
        Facts facts = new Facts(true, orderNo, state[0], state[1], date(detail.getBillDate()), date(detail.getDeliverDate()),
                List.copyOf(lines), items.size());
        // The same bill number and legacy id the detail page records for this order.
        return new Read(facts, new Viewed(orderId, detail.getBillNo(), detail.getLegacyId()));
    }

    /** One row per order line: arrivals that were registered and sent to inspection, and any over-receipt on hold. */
    private Map<UUID, Arrival> arrivals(UUID orderId) {
        Map<UUID, Arrival> out = new HashMap<>();
        jdbc.query("""
                SELECT oi.id, unit.name AS unit_name, color.name AS color_name, COALESCE(oi.unit_rate, 1) AS rate,
                       COALESCE(iqc.waiting_base, 0) AS waiting_base, COALESCE(iqc.passed_base, 0) AS passed_base,
                       COALESCE(iqc.failed_base, 0) AS failed_base, COALESCE(iqc.stocked_base, 0) AS stocked_base,
                       COALESCE(held.qty, 0) AS held_qty, held.unit_name AS held_unit, held.receipts AS held_receipts
                FROM purchase_order_items oi
                LEFT JOIN units unit ON unit.id = oi.unit_id
                LEFT JOIN colors color ON color.id = oi.color_id
                LEFT JOIN LATERAL (
                    SELECT SUM(CASE WHEN iq.status IN ('PENDING', 'PARTIAL')
                                    THEN iq.received_base_qty - iq.passed_base_qty - iq.failed_base_qty ELSE 0 END) AS waiting_base,
                           SUM(CASE WHEN iq.status = 'REVERSED' THEN 0 ELSE iq.passed_base_qty END) AS passed_base,
                           SUM(CASE WHEN iq.status = 'REVERSED' THEN 0 ELSE iq.failed_base_qty END) AS failed_base,
                           SUM(CASE WHEN iq.status = 'REVERSED' THEN 0
                                    ELSE iq.warehouse_stocked_base_qty + iq.legacy_stocked_base_qty END) AS stocked_base
                    FROM purchase_receipt_items receipt_item
                    JOIN purchase_receipts receipt ON receipt.id = receipt_item.receipt_id
                     AND receipt.status = 1 AND receipt.is_deleted = FALSE
                    JOIN procurement_inspection_items iq
                      ON iq.receipt_type = 'PURCHASE' AND iq.receipt_item_id = receipt_item.id
                    WHERE receipt_item.order_item_id = oi.id AND receipt_item.is_deleted = FALSE
                ) iqc ON TRUE
                LEFT JOIN LATERAL (
                    SELECT SUM(exception.declared_qty) AS qty, MIN(held_unit.name) AS unit_name,
                           string_agg(DISTINCT exception.receipt_bill_no_snapshot, '、') AS receipts
                    FROM procurement_arrival_exceptions exception
                    LEFT JOIN units held_unit ON held_unit.id = exception.unit_id
                    WHERE exception.order_type = 'PURCHASE' AND exception.order_item_id = oi.id
                      AND exception.status = 'PENDING_FINANCE'
                ) held ON TRUE
                WHERE oi.order_id = ?
                """, rs -> {
            out.put(rs.getObject("id", UUID.class), new Arrival(rs.getString("unit_name"), rs.getString("color_name"),
                    rs.getBigDecimal("rate"), rs.getBigDecimal("waiting_base"), rs.getBigDecimal("passed_base"),
                    rs.getBigDecimal("failed_base"), rs.getBigDecimal("stocked_base"), rs.getBigDecimal("held_qty"),
                    rs.getString("held_unit"), rs.getString("held_receipts")));
        }, orderId);
        return out;
    }

    /** [status text, what it is waiting for]; the first matching fact wins, in the order the goods move. */
    static String[] state(short status, boolean closed, String financeStatus, BigDecimal held, BigDecimal waiting,
                          BigDecimal unstocked, boolean anyReceived, boolean allReceived, LocalDate deliverDate) {
        if (status == REVERSED) return new String[]{"已红冲", "这张订货单已红冲作废，不会再到货。"};
        if (status == CANCELED) return new String[]{"已取消", "这张订货单已取消，不会再到货。"};
        if (status == DRAFT) {
            if ("PENDING".equals(financeStatus)) return new String[]{"财务审批中", "已提交财务，等财务审核组审批；批准后供应商才送货。"};
            if ("REJECTED".equals(financeStatus))
                return new String[]{"财务已退回", "财务已退回，等采购修改后重新提交；退回原因请在订货单详情里查看。"};
            return new String[]{"草稿", "还是草稿，等采购提交财务审批。"};
        }
        if (status != APPROVED) return new String[]{"状态待确认", "请在订货单详情里查看当前状态。"};
        if (held.signum() > 0)
            return new String[]{"到货超量待财务判定", "有到货超过了最多可收数量(含允许超收)，那张收货单整张等财务审核组判定，判定前不入库。"};
        if (waiting.signum() > 0) return new String[]{"待品质检验", "已登记到货的货等品质部来料检验。"};
        if (unstocked.signum() > 0) return new String[]{"合格待入库", "检验合格的货等仓库确认入库。"};
        if (closed) return new String[]{"已结案", "订货单已结案。"};
        if (allReceived) return new String[]{"已全部到货", "订货数量已全部到货。"};
        if (anyReceived) return new String[]{"部分到货", "已到一部分，等供应商送剩下的。"};
        return new String[]{"财务已批准", "财务已批准，等供应商送货"
                + (deliverDate == null ? "。" : "，交货日期 " + deliverDate + "。")};
    }

    // ---------------------------------------------------------------- text

    private static String render(Facts facts, String time, boolean detailed) {
        StringBuilder reply = new StringBuilder("采购订货单 ").append(facts.orderNo()).append("：")
                .append(facts.statusText()).append("。");
        if (detailed) reply.append("\n截至 ").append(time).append("。");
        reply.append("\n现在：").append(facts.waiting());
        reply.append("\n下单日期 ").append(facts.billDate() == null ? "未登记" : facts.billDate())
                .append("，交货日期 ").append(facts.deliverDate() == null ? "未登记" : facts.deliverDate()).append("。");
        int shown = Math.min(detailed ? LINE_LIMIT : 5, facts.lines().size());
        if (shown > 0) reply.append("\n货品：");
        for (Line line : facts.lines().subList(0, shown)) {
            String unit = line.unit().isEmpty() ? "" : " " + line.unit();
            reply.append("\n• ").append(line.goods()).append("：订 ").append(line.qty()).append(unit)
                    .append("，已到货 ").append(line.received());
            if (detailed) {
                reply.append("，已退货 ").append(line.returned()).append("，待检 ").append(line.waitingInspection())
                        .append("，合格 ").append(line.passed()).append("，不合格 ").append(line.failed())
                        .append("，已入库 ").append(line.stocked()).append(unit);
                if (line.deliverDate() != null) reply.append("；交货日期 ").append(line.deliverDate());
            } else {
                reply.append("，已入库 ").append(line.stocked()).append(unit);
            }
            if (line.held() != null) {
                reply.append("；到货超量待财务判定 ").append(line.held());
                if (detailed && line.heldReceipts() != null) reply.append("(收货单 ").append(line.heldReceipts()).append(")");
            }
            reply.append("。");
        }
        if (facts.lineCount() > shown) {
            reply.append("\n另有 ").append(facts.lineCount() - shown).append(" 个货品")
                    .append(detailed || facts.lines().size() <= shown ? "，请到订货单详情查看。" : "，回复“展开”可看更多。");
        }
        if (!detailed) reply.append("\n回复“展开”可看待检、合格、不合格和退货数量。");
        else reply.append("\n数量都按订货单位；不同货品的单位不同时不能相加。");
        return reply.toString();
    }

    // ---------------------------------------------------------------- guards and helpers

    private void require() {
        access.requireDomain(domain());
        if (!available()) throw new ApiException(ErrorCode.FORBIDDEN, "你没有查看采购订货单的权限，请联系管理员开通");
    }

    static String orderNo(Map<String, Object> arguments) {
        if (arguments == null || !Set.of("orderNo").equals(arguments.keySet())
                || !(arguments.get("orderNo") instanceof String raw)) throw invalidNumber();
        String value = Normalizer.normalize(raw, Normalizer.Form.NFKC).replaceAll("\\s+", "")
                .toUpperCase(java.util.Locale.ROOT);
        if (!value.matches("[A-Z0-9][A-Z0-9_-]{1,39}")) throw invalidNumber();
        return value;
    }

    private String digest(Facts facts) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(json.writeValueAsString(facts).getBytes(StandardCharsets.UTF_8)));
        } catch (JsonProcessingException | NoSuchAlgorithmException failure) {
            throw new IllegalStateException("Cannot fingerprint purchase order status", failure);
        }
    }

    private static BigDecimal toOrderUnit(BigDecimal base, BigDecimal rate) {
        BigDecimal safeRate = rate == null || rate.signum() <= 0 ? BigDecimal.ONE : rate;
        return MoneyPolicy.quantityFromBase(zero(base), safeRate);
    }

    private static BigDecimal zero(BigDecimal value) { return value == null ? BigDecimal.ZERO : value; }

    private static String date(LocalDate value) { return value == null ? null : value.toString(); }

    private static String plain(BigDecimal value) {
        return value == null ? "0" : value.stripTrailingZeros().toPlainString();
    }

    private static String label(String value, String fallback) {
        if (value == null || value.isBlank()) return fallback;
        String safe = value.replaceAll("\\p{Cntrl}", " ").strip();
        return safe.length() <= 64 ? safe : safe.substring(0, 63) + "…";
    }

    private static ApiException invalidNumber() {
        return new ApiException(ErrorCode.VALIDATION_FAILED,
                "请告诉我完整的采购订货单号：字母和数字，2 到 40 位，例如以 CD 开头的单号");
    }

    private static ApiException changed() {
        return new ApiException(ErrorCode.FORBIDDEN, "这张采购订货单的状态或你的查看范围已变化，请重新查询");
    }
}
