package com.uten.imp.features.sales.order;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiChatToolPort;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.order.dto.OrderProgressRow;
import com.uten.imp.features.sales.order.dto.OrderProgressTimelineEvent;
import com.uten.imp.features.sales.order.dto.PlanProgressLine;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.text.Normalizer;
import java.time.Clock;
import java.time.OffsetDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * 销售订货单进度查询(AI 助手只读工具, P1-3)。按用户给的订货单号在本人销售查看范围内找单, 范围与订货单
 * 详情接口同一口径(查看订货单权限 + 归属范围, 不可见与不存在一样回答); 事实全部来自订单进度、排产进度和
 * 全链路时间线三个现成读接口, 这里只挑选与排版, 不另算。
 *
 * <p>回答里只有阶段、状态、日期、数量、货品编码与名称和关联单号; 不带客户名、人员姓名、价格金额和退回原因
 * 原文(这些在订货单详情里看)。可外送的回答会带进后续对话发给 AI 服务商, 所以展开回答同样不带姓名。
 *
 * <p>查看审计(ADR-105): 每次查到一张本人看得到的单, 写一条与订货单详情页相同的查看记录(同一动作与对象表,
 * 对象名称标「AI 助手查询」, 30 分钟内同人同单只记一次, 与详情页同一规则); 单号不存在、不在范围内或没有权限时
 * 不写, 恢复对话时复核旧回答也不算一次查看。
 */
@Component
public class SalesOrderAiChatTool implements AiChatToolPort {
    static final String NOT_FOUND = "没有找到你能查看的这张单据。请核对单号是否完整、有没有输错；"
            + "如果这张单不在你的查看范围内(比如由别的同事负责)，这里同样查不到，可以请负责的同事或主管查看。";
    /** The detail page's own view event (SalesOrderController#detail); only the display label marks the AI source. */
    static final String VIEW_AUDIT_ACTION = "view_sales_order_detail";
    static final String VIEW_AUDIT_TARGET = "sales_orders";
    static final String VIEW_AUDIT_LABEL = "销售订货单(AI 助手查询)";
    private static final String SOURCE = "sales/order-progress";
    private static final String VIEW = "sales_order:view";
    private static final int LINE_LIMIT = 20;
    private static final int STEP_LIMIT = 30;
    private static final DateTimeFormatter TIME = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")
            .withZone(BusinessTime.ZONE);
    private static final DateTimeFormatter DAY = DateTimeFormatter.ofPattern("yyyy-MM-dd");

    private final AiChatAccessPolicy access;
    private final SecurityContextCurrentUser current;
    private final SalesDocumentAccessPolicy documents;
    private final SalesOrderService orders;
    private final SalesOrderTimelineService timeline;
    private final EntityManager em;
    private final ObjectMapper json;
    private final Clock clock;
    private final AuditDetailViewRecorder viewAudit;

    public SalesOrderAiChatTool(AiChatAccessPolicy access, SecurityContextCurrentUser current,
                                SalesDocumentAccessPolicy documents, SalesOrderService orders,
                                SalesOrderTimelineService timeline, EntityManager em, ObjectMapper json, Clock clock,
                                AuditDetailViewRecorder viewAudit) {
        this.access = access; this.current = current; this.documents = documents; this.orders = orders;
        this.timeline = timeline; this.em = em; this.json = json; this.clock = clock; this.viewAudit = viewAudit;
    }

    @Override public String name() { return "sales_order_progress"; }
    @Override public String title() { return "查询销售订单进度"; }
    @Override public String domain() { return "SALES"; }
    @Override public boolean rememberQueryArguments() { return true; }
    @Override public String description() {
        return "Read the current progress of ONE sales order (销售订货单) by its order number, e.g. XD20261006000003, "
                + "only when the user names that number and asks where it is, whether it has shipped, what it is waiting for "
                + "or how much is produced or shipped. The server finds the order only within the caller's own sales order "
                + "scope (the same as the order detail page) and answers 'not found' for anything else. Returns the stage, "
                + "what it is waiting for, order/bill and delivery dates, per-goods ordered, scheduled, produced, ready to ship, "
                + "in-flight shipment and shipped quantities, and the chain steps (sales review, finance review, material "
                + "analysis, purchase/subcontract preparation, production plans, shipments) with their states and dates. "
                + "No customer names, people, prices, amounts or rejection reasons; no history parameter; one order per call.";
    }
    @Override public Map<String, Object> parameters() {
        return Map.of("type", "object", "additionalProperties", false,
                "properties", Map.of("orderNo", Map.of("type", "string", "minLength", 2, "maxLength", 40,
                        "description", "The sales order number exactly as the user wrote it, e.g. XD20261006000003.")),
                "required", List.of("orderNo"));
    }
    @Override public boolean available() {
        return access.hasDomain(domain()) && current.get()
                .filter(actor -> actor.isSuperAdmin() || actor.getPermissions().contains(VIEW)).isPresent();
    }
    /** ADR-150: the detail text holds only stages, states, dates, quantities, goods and document numbers. */
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
        // The same number re-read in the reader's current scope: a moved owner, a revoked view-all or any
        // progress change gives a different snapshot, so the stored answer is not shown again. This re-check
        // shows nothing new, so it is not recorded as a view.
        if (!normalized.equals(orderNo) || !expected.equals(digest(read(normalized).facts()))) throw changed();
    }

    // ---------------------------------------------------------------- facts

    record Line(String goods, String unit, String qty, String planned, String produced, String ready,
                String inFlight, String shipped) {}
    record Step(int seq, String title, String state, String day, String docNo, String detail) {}
    record Facts(boolean found, String orderNo, String stage, String stageText, String waiting, String billDate,
                 String deliverDate, String totals, List<Line> lines, int lineCount, List<Step> steps) {
        static Facts notFound(String orderNo) {
            return new Facts(false, orderNo, null, null, null, null, null, null, List.of(), 0, List.of());
        }
    }
    /** The order a successful read resolved: the view-audit target only, never part of the facts or their digest. */
    record Viewed(UUID id, String billNo, Integer legacyId) {}
    private record Read(Facts facts, Viewed viewed) {}

    private Read read(String orderNo) {
        var scope = documents.nativeReadScope("o.owner_employee_id", "salesOwners");
        var query = em.createNativeQuery("""
                SELECT o.id, o.status, CAST(o.bill_date AS text), CAST(o.deliver_date AS text),
                       o.finance_confirmed, o.finance_rejected, o.legacy_id
                FROM sales_orders o
                WHERE o.bill_no = :billNo AND o.is_deleted = FALSE AND """ + " " + scope.predicate());
        query.setParameter("billNo", orderNo);
        scope.bind(query);
        @SuppressWarnings("unchecked") List<Object[]> rows = query.getResultList();
        if (rows.isEmpty()) return new Read(Facts.notFound(orderNo), null);
        Object[] head = rows.getFirst();
        UUID orderId = (UUID) head[0];
        int status = ((Number) head[1]).intValue();
        boolean financeConfirmed = Boolean.TRUE.equals(head[4]);
        boolean financeRejected = Boolean.TRUE.equals(head[5]);

        OrderProgressRow progress = null;
        if (status == 1 || (status == 0 && financeRejected)) {
            var page = orders.progress(1, 1, "", "", null, null, null, null, orderNo);
            progress = page.getItems().isEmpty() ? null : page.getItems().getFirst();
        }
        String stage = status == -1 ? "REVERSED"
                : status == 0 && !financeRejected ? "DRAFT"
                : progress == null ? (financeRejected ? "REJECTED" : "PENDING") : progress.stage();
        boolean awaitingFinance = status == 1 && !financeConfirmed && !financeRejected;

        List<PlanProgressLine> planLines = orders.planProgress(orderId);
        List<Line> lines = planLines.stream().limit(LINE_LIMIT).map(SalesOrderAiChatTool::line).toList();
        String totals = totals(planLines);
        List<Step> steps = timeline.timeline(orderId).stream()
                .map(SalesOrderAiChatTool::step)
                .sorted(Comparator.comparingInt(Step::seq).thenComparing(step -> step.day() == null ? "" : step.day()))
                .limit(STEP_LIMIT).toList();
        Facts facts = new Facts(true, orderNo, stage, awaitingFinance ? "等待财务审核" : stageLabel(stage),
                waiting(stage, awaitingFinance, progress, planLines), text(head[2]), text(head[3]), totals,
                lines, planLines.size(), steps);
        return new Read(facts, new Viewed(orderId, orderNo, head[6] instanceof Number legacy ? legacy.intValue() : null));
    }

    private static Line line(PlanProgressLine row) {
        String goods = label(row.goodsCode(), "未编码") + " · " + label(row.goodsName(), "未命名货品")
                + (row.colorName() == null || row.colorName().isBlank() ? "" : "(" + label(row.colorName(), "") + ")");
        return new Line(goods, label(row.unitName(), ""), plain(row.qty()), plain(row.plannedQty()),
                plain(row.producedQty()), plain(row.shippableQty()), plain(row.pendingShipmentQty()), plain(row.shippedQty()));
    }

    /** Totals only when every line has the same unit: different units are never added together. */
    private static String totals(List<PlanProgressLine> lines) {
        if (lines.isEmpty()) return null;
        Set<String> units = new java.util.HashSet<>();
        for (PlanProgressLine line : lines) units.add(line.unitName() == null ? "" : line.unitName().strip());
        if (units.size() != 1) return null;
        String unit = units.iterator().next();
        String suffix = unit.isEmpty() ? "" : " " + label(unit, "");
        return "订货 " + plain(sum(lines, PlanProgressLine::qty)) + suffix
                + "，已生产 " + plain(sum(lines, PlanProgressLine::producedQty)) + suffix
                + "，已发货 " + plain(sum(lines, PlanProgressLine::shippedQty)) + suffix;
    }

    private static BigDecimal sum(List<PlanProgressLine> lines, java.util.function.Function<PlanProgressLine, BigDecimal> value) {
        return lines.stream().map(value).filter(Objects::nonNull).reduce(BigDecimal.ZERO, BigDecimal::add);
    }

    /**
     * Only the fixed, server-worded detail of a step that is still running or not yet reached is kept. Finished and
     * rejected steps can carry a person (审核人) or a free-text reason, so their detail is never used; a detail with a
     * colon (the platform writes 「审核人：…」「原因：…」) is dropped as well, whatever its state.
     */
    static Step step(OrderProgressTimelineEvent event) {
        boolean open = OrderProgressTimelineEvent.CURRENT.equals(event.state())
                || OrderProgressTimelineEvent.PENDING.equals(event.state());
        String detail = open && event.detail() != null && !event.detail().isBlank()
                && event.detail().indexOf('：') < 0 && event.detail().indexOf(':') < 0
                ? label(event.detail(), null) : null;
        return new Step(event.seq(), label(event.title(), "环节"), stateLabel(event.state()), day(event.occurredAt()),
                event.docNo() == null || event.docNo().isBlank() ? null : label(event.docNo(), null), detail);
    }

    private static String waiting(String stage, boolean awaitingFinance, OrderProgressRow progress,
                                  List<PlanProgressLine> lines) {
        if (awaitingFinance) return "等财务审核组确认；确认之后才进入物料分析和排产。";
        return switch (stage) {
            case "REVERSED" -> "这张订货单已红冲作废，不会再往下走。";
            case "DRAFT" -> "还是草稿，等销售审核。";
            case "REJECTED" -> "财务已退回，等销售修改后重新审核；退回原因请在订货单详情里查看。";
            case "CANCELED" -> "订单已中止，不会再往下走。";
            case "CLOSED" -> "订单已结案。";
            case "SHIPPED" -> "订货数量已全部发货。";
            case "PENDING" -> "还有数量没排产，等计划部做物料分析并下达生产计划。";
            case "PRODUCING" -> "已全部排产，正在备料或生产；做完入库备好货后才能开出货单。";
            case "SHIPPABLE" -> "有备好的货可以开出货单发货"
                    + (sameUnit(lines) ? "，现在可开 " + plain(sum(lines, PlanProgressLine::shippableQty)) + unitSuffix(lines) : "")
                    + "。";
            case "SHIPMENT_PENDING" -> progress != null && progress.shipmentFinanceRejectedQty() > 1e-6
                    ? "有出货单被财务退回，等销售修改后重新提交。"
                    : progress != null && progress.shipmentPendingFinanceQty() > 1e-6
                    ? "出货单已提交，等财务审核组放行。"
                    : "出货单还是草稿，等销售确认并提交财务。";
            case "WAREHOUSE_PENDING" -> "财务已放行出货，等仓库出库。";
            default -> "请在订货单详情里查看当前环节。";
        };
    }

    // ---------------------------------------------------------------- text

    private static String render(Facts facts, String time, boolean detailed) {
        StringBuilder reply = new StringBuilder("销售订货单 ").append(facts.orderNo()).append("：")
                .append(facts.stageText()).append("。");
        if (detailed) reply.append("\n截至 ").append(time).append("。");
        reply.append("\n现在：").append(facts.waiting());
        reply.append("\n下单日期 ").append(facts.billDate() == null ? "未登记" : facts.billDate())
                .append("，交货日期 ").append(facts.deliverDate() == null ? "未登记" : facts.deliverDate()).append("。");
        if (facts.totals() != null) reply.append("\n合计：").append(facts.totals()).append("。");
        // Only steps running now: a rejection that was later revised stays in the chain as history.
        List<Step> running = facts.steps().stream().filter(step -> "进行中".equals(step.state())).toList();
        if (!running.isEmpty()) {
            reply.append("\n正在办的环节：");
            reply.append(String.join("；", running.stream().map(SalesOrderAiChatTool::stepText).toList())).append("。");
        }
        int shown = Math.min(detailed ? LINE_LIMIT : 5, facts.lines().size());
        if (shown > 0) reply.append("\n货品：");
        for (Line line : facts.lines().subList(0, shown)) {
            String unit = line.unit().isEmpty() ? "" : " " + line.unit();
            reply.append("\n• ").append(line.goods()).append("：订 ").append(line.qty()).append(unit);
            if (detailed) reply.append("，已排产 ").append(line.planned()).append("，已生产 ").append(line.produced())
                    .append("，备好可发 ").append(line.ready()).append("，出货在途 ").append(line.inFlight());
            else reply.append("，已生产 ").append(line.produced());
            reply.append("，已发货 ").append(line.shipped()).append(unit).append("。");
        }
        if (facts.lineCount() > shown) {
            reply.append("\n另有 ").append(facts.lineCount() - shown).append(" 个货品")
                    .append(detailed || facts.lines().size() <= shown ? "，请到订货单详情查看。" : "，回复“展开”可看更多。");
        }
        if (detailed && !facts.steps().isEmpty()) {
            reply.append("\n全链路：");
            for (Step step : facts.steps()) reply.append("\n• ").append(stepText(step));
        } else if (!detailed) {
            reply.append("\n回复“展开”可看每个货品的排产与出货数量和全链路各环节。");
        }
        return reply.toString();
    }

    private static String stepText(Step step) {
        StringBuilder text = new StringBuilder(step.title());
        if (step.docNo() != null) text.append(" ").append(step.docNo());
        text.append("：").append(step.state());
        if (step.day() != null) text.append(" ").append(step.day());
        if (step.detail() != null) text.append("(").append(step.detail()).append(")");
        return text.toString();
    }

    static String stageLabel(String stage) {
        return switch (stage) {
            case "REVERSED" -> "已红冲作废";
            case "DRAFT" -> "草稿";
            case "REJECTED" -> "财务驳回";
            case "PENDING" -> "待排产";
            case "PRODUCING" -> "生产中";
            case "SHIPPABLE" -> "可分批发货";
            case "SHIPMENT_PENDING" -> "出货待财审";
            case "WAREHOUSE_PENDING" -> "等仓库出货";
            case "SHIPPED" -> "仓库已发货";
            case "CANCELED" -> "已中止";
            case "CLOSED" -> "已结案";
            default -> "状态待确认";
        };
    }

    private static String stateLabel(String state) {
        return switch (state == null ? "" : state) {
            case OrderProgressTimelineEvent.DONE -> "已完成";
            case OrderProgressTimelineEvent.CURRENT -> "进行中";
            case OrderProgressTimelineEvent.REJECTED -> "未通过";
            default -> "未开始";
        };
    }

    private static boolean sameUnit(List<PlanProgressLine> lines) {
        return !lines.isEmpty() && lines.stream().map(line -> line.unitName() == null ? "" : line.unitName().strip())
                .distinct().count() == 1;
    }

    private static String unitSuffix(List<PlanProgressLine> lines) {
        String unit = lines.getFirst().unitName();
        return unit == null || unit.isBlank() ? "" : " " + label(unit, "");
    }

    // ---------------------------------------------------------------- guards and helpers

    private void require() {
        access.requireDomain(domain());
        if (!available()) throw new ApiException(ErrorCode.FORBIDDEN, "你没有查看销售订货单的权限，请联系管理员开通");
    }

    /** Full-width letters and digits are folded, spaces removed and letters upper-cased, as numbers are stored. */
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
            throw new IllegalStateException("Cannot fingerprint sales order progress", failure);
        }
    }

    private static String day(OffsetDateTime time) {
        return time == null ? null : DAY.format(time.atZoneSameInstant(BusinessTime.ZONE));
    }

    private static String text(Object value) {
        return value == null || value.toString().isBlank() ? null : label(value.toString(), null);
    }

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
                "请告诉我完整的销售订货单号：字母和数字，2 到 40 位，例如以 XD 开头的单号");
    }

    private static ApiException changed() {
        return new ApiException(ErrorCode.FORBIDDEN, "这张订货单的进度或你的查看范围已变化，请重新查询");
    }
}
