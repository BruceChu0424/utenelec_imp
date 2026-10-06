package com.uten.imp.features.subcontract.order;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiChatToolPort;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.kit.SubcontractKitService;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts;
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
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 委外申请单与委外订货单状态查询(AI 助手只读工具, P1-3)。一个单号先按委外订货单找, 再按委外申请单找;
 * 查看范围分别与两个详情接口同一口径: 订货单要有查看委外订货单权限并在本人归属范围内(与订货单进度接口相同),
 * 申请单要有查看委外申请权限(申请是计划系统生成的需求单, 不按归属隔离); 不可见与不存在一样回答。
 *
 * <p>申请单回答 ADR-156 的锁: 直属物料不齐时申请锁住不能生成订货单, 只能按现有物料够做的套数下单, 逐种物料
 * 说清差多少; 数量全部来自 V809 齐套函数(经 {@link SubcontractKitService}), 这里不另算。草稿订货单同样
 * 读齐套检查, 提前说明提交财务或财务批准时会被拦。已批准订货单读订货单进度(ADR-143 时间线与物料段)。
 *
 * <p>回答里只有状态、日期、数量、货品与物料编码和名称; 不带委外商名、人员姓名、价格金额和退回原因原文。
 *
 * <p>查看审计(ADR-105): 每次查到一张本人看得到的单, 写一条与对应详情页(委外订货单详情或委外申请详情)相同的
 * 查看记录(同一动作与对象表, 对象名称标「AI 助手查询」, 30 分钟内同人同单只记一次, 与详情页同一规则);
 * 单号不存在、不在范围内或没有权限时不写, 恢复对话时复核旧回答也不算一次查看。
 */
@Component
public class SubcontractOrderAiChatTool implements AiChatToolPort {
    static final String NOT_FOUND = "没有找到你能查看的这张单据。请核对单号是否完整、有没有输错；"
            + "如果这张单不在你的查看范围内(比如由别的同事负责)，这里同样查不到，可以请负责的同事或主管查看。";
    /** The detail pages' own view events (SubcontractOrderController and SubcontractApplicationController detail). */
    static final String ORDER_VIEW_AUDIT_ACTION = "view_subcontract_order_detail";
    static final String ORDER_VIEW_AUDIT_TARGET = "subcontract_orders";
    static final String ORDER_VIEW_AUDIT_LABEL = "委外订货单(AI 助手查询)";
    static final String APPLICATION_VIEW_AUDIT_ACTION = "view_subcontract_application_detail";
    static final String APPLICATION_VIEW_AUDIT_TARGET = "subcontract_applications";
    static final String APPLICATION_VIEW_AUDIT_LABEL = "委外申请单(AI 助手查询)";
    private static final String SOURCE = "subcontract/document-status";
    private static final int LINE_LIMIT = 20;
    private static final int MATERIAL_LIMIT = 10;
    private static final DateTimeFormatter TIME = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")
            .withZone(BusinessTime.ZONE);

    private final AiChatAccessPolicy access;
    private final SecurityContextCurrentUser current;
    private final SubcontractDocumentAccessPolicy documents;
    private final SubcontractOrderProgressService progress;
    private final SubcontractKitService kits;
    private final JdbcTemplate jdbc;
    private final ObjectMapper json;
    private final Clock clock;
    private final AuditDetailViewRecorder viewAudit;

    public SubcontractOrderAiChatTool(AiChatAccessPolicy access, SecurityContextCurrentUser current,
                                      SubcontractDocumentAccessPolicy documents, SubcontractOrderProgressService progress,
                                      SubcontractKitService kits, JdbcTemplate jdbc, ObjectMapper json, Clock clock,
                                      AuditDetailViewRecorder viewAudit) {
        this.access = access; this.current = current; this.documents = documents; this.progress = progress;
        this.kits = kits; this.jdbc = jdbc; this.json = json; this.clock = clock; this.viewAudit = viewAudit;
    }

    @Override public String name() { return "subcontract_order_status"; }
    @Override public String title() { return "查询委外申请与委外订货单状态"; }
    @Override public String domain() { return "SUBCONTRACT"; }
    @Override public boolean rememberQueryArguments() { return true; }
    @Override public String description() {
        return "Read the current status of ONE subcontract document by its number: a subcontract application (委外申请单, "
                + "e.g. EB20261006000001) or a subcontract order (委外订货单, e.g. EO20261006000001). Use it only when the user "
                + "names that number and asks why it cannot be ordered or submitted, whether it is locked, what material is "
                + "missing, whether it was approved, or how far drawing, processing, return, inspection and stock-in have got. "
                + "For an application it returns open, kit-ready and orderable quantities and, when locked because direct "
                + "materials are not complete, each missing material with needed, usable and short quantities. For an order "
                + "it returns status, finance approval state, the material kit check of a draft and the per-goods chain "
                + "(order, finance, material draw, return, inspection, stock-in, close). The server checks the caller's "
                + "document scope and answers 'not found' otherwise. No supplier names, people, prices or amounts.";
    }
    @Override public Map<String, Object> parameters() {
        return Map.of("type", "object", "additionalProperties", false,
                "properties", Map.of("documentNo", Map.of("type", "string", "minLength", 2, "maxLength", 40,
                        "description", "The subcontract application or order number exactly as the user wrote it.")),
                "required", List.of("documentNo"));
    }
    @Override public boolean available() {
        return access.hasDomain(domain()) && current.get().filter(actor -> actor.isSuperAdmin()
                || actor.getPermissions().contains("subcontract_order:view")
                || actor.getPermissions().contains("subcontract_application:view")).isPresent();
    }
    /** ADR-150: the detail text holds only states, dates, quantities, goods/material and document numbers. */
    @Override public Map<String, Object> modelFacts(Map<String, Object> result) {
        return result.get("detailReply") instanceof String text ? Map.of("facts", text) : Map.of();
    }

    @Override @Transactional(readOnly = true)
    public Map<String, Object> execute(Map<String, Object> arguments) {
        require();
        String number = documentNo(arguments);
        Read read = read(number);
        Facts facts = read.facts();
        String time = TIME.format(clock.instant());
        Map<String, Object> evidence = Map.of("source", SOURCE, "documentNo", number, "snapshot", digest(facts));
        if (!facts.found()) {
            // Unknown and out of scope look the same here and leave no view record either.
            return Map.of("reply", NOT_FOUND, "actions", List.of(), "source", SOURCE, "_toolEvidence", evidence);
        }
        Map<String, Object> result = Map.of("reply", render(facts, time, false), "detailReply", render(facts, time, true),
                "actions", List.of(), "source", SOURCE, "_toolEvidence", evidence);
        // Written before the facts leave this method: if the view cannot be recorded, nothing is answered (fail closed).
        Viewed viewed = read.viewed();
        viewAudit.record(viewed.action(), viewed.target(), viewed.id(), viewed.billNo(), viewed.legacyId(), viewed.label());
        return result;
    }

    @Override @Transactional(readOnly = true)
    public void authorizeResultRead(Map<String, Object> evidence) {
        require();
        if (evidence == null || !evidence.keySet().equals(Set.of("source", "documentNo", "snapshot"))
                || !SOURCE.equals(evidence.get("source"))
                || !(evidence.get("documentNo") instanceof String number)
                || !(evidence.get("snapshot") instanceof String expected) || !expected.matches("[0-9a-f]{64}")) throw changed();
        String normalized;
        try { normalized = documentNo(Map.of("documentNo", number)); }
        catch (ApiException invalid) { throw changed(); }
        // Kit facts move with stock: an answer about a lock is shown again only while the same numbers still hold.
        // A re-check of a stored answer shows nothing new, so it is not recorded as a view.
        if (!normalized.equals(number) || !expected.equals(digest(read(normalized).facts()))) throw changed();
    }

    // ---------------------------------------------------------------- facts

    /** One goods line with its own text rows (chain steps or missing materials), already worded. */
    record Line(String goods, String summary, List<String> details) {}
    record Facts(boolean found, String kind, String number, String statusText, String waiting, String billDate,
                 String dueDate, List<Line> lines, int lineCount) {
        static Facts notFound(String number) {
            return new Facts(false, null, number, null, null, null, null, List.of(), 0);
        }
    }
    /**
     * The document a successful read resolved, with the view event of its own detail page: the view-audit target
     * only, never part of the facts or their digest.
     */
    record Viewed(String action, String target, String label, UUID id, String billNo, Integer legacyId) {}
    private record Read(Facts facts, Viewed viewed) {}

    private Read read(String number) {
        List<Map<String, Object>> order = jdbc.queryForList("""
                SELECT id, maker_id, status, is_closed, CAST(bill_date AS text) AS bill_date,
                       CAST(deliver_date AS text) AS deliver_date, legacy_id
                FROM subcontract_orders WHERE bill_no = ? AND is_deleted = FALSE
                """, number);
        if (!order.isEmpty()) {
            Map<String, Object> head = order.getFirst();
            // The order progress endpoint's own rule: order view permission and the reader's owner scope.
            if (!can("subcontract_order:view") || !documents.canRead((UUID) head.get("maker_id")))
                return new Read(Facts.notFound(number), null);
            return new Read(order(number, head), new Viewed(ORDER_VIEW_AUDIT_ACTION, ORDER_VIEW_AUDIT_TARGET,
                    ORDER_VIEW_AUDIT_LABEL, (UUID) head.get("id"), number, legacyId(head)));
        }
        List<Map<String, Object>> application = jdbc.queryForList("""
                SELECT id, status, is_closed, CAST(bill_date AS text) AS bill_date, CAST(need_date AS text) AS need_date,
                       legacy_id
                FROM subcontract_applications WHERE bill_no = ? AND is_deleted = FALSE
                """, number);
        if (application.isEmpty() || !can("subcontract_application:view")) return new Read(Facts.notFound(number), null);
        Map<String, Object> head = application.getFirst();
        return new Read(application(number, head), new Viewed(APPLICATION_VIEW_AUDIT_ACTION,
                APPLICATION_VIEW_AUDIT_TARGET, APPLICATION_VIEW_AUDIT_LABEL, (UUID) head.get("id"), number, legacyId(head)));
    }

    private static Integer legacyId(Map<String, Object> head) {
        return head.get("legacy_id") instanceof Number legacy ? legacy.intValue() : null;
    }

    private Facts order(String number, Map<String, Object> head) {
        UUID orderId = (UUID) head.get("id");
        int status = ((Number) head.get("status")).intValue();
        boolean closed = Boolean.TRUE.equals(head.get("is_closed"));
        var chain = progress.progress(orderId);
        List<String> shortages = status == 0 ? orderShortages(orderId) : List.of();
        List<Line> lines = new ArrayList<>();
        List<String> running = new ArrayList<>();
        boolean missingBom = false;
        for (var item : chain.items()) {
            missingBom |= OrderProgressContracts.MATERIAL_MODE_MISSING_BOM.equals(item.materialMode());
            String unit = unit(item.unitName());
            String goods = goods(item.goodsCode(), item.goodsName(), item.colorName());
            List<String> details = new ArrayList<>();
            for (var node : item.timeline()) {
                String detail = safeDetail(node.detail());
                details.add(label(node.label(), "环节") + "：" + nodeState(node.state()) + (detail == null ? "" : "(" + detail + ")"));
                if (OrderProgressContracts.NODE_ACTIVE.equals(node.state()) && running.size() < 3 && status == 1)
                    running.add(label(item.goodsCode(), "未编码") + " " + label(node.label(), "环节")
                            + (detail == null ? "" : "(" + detail + ")"));
            }
            item.materials().stream().filter(material -> material.shortQty() != null && material.shortQty().signum() > 0)
                    .limit(MATERIAL_LIMIT)
                    .forEach(material -> details.add("物料「" + goods(material.goodsCode(), material.goodsName(), material.colorName())
                            + "」还缺 " + plain(material.shortQty()) + unit(material.unitName())));
            if (lines.size() < LINE_LIMIT) lines.add(new Line(goods, "订 " + plain(item.orderQty()) + unit
                    + "，已回厂 " + plain(item.receivedQty()) + "，已入仓 " + plain(item.stockedQty()) + unit, List.copyOf(details)));
        }
        String finance = chain.financeCaseStatus();
        String statusText;
        String waiting;
        if (status < 0) {
            statusText = "已红冲";
            waiting = "这张委外订货单已红冲作废，领料已取消。";
        } else if (status == 0) {
            statusText = "PENDING".equals(finance) ? "财务审批中" : "REJECTED".equals(finance) ? "财务已退回" : "草稿";
            String step = "PENDING".equals(finance) ? "已提交财务，等财务审核组审批"
                    : "REJECTED".equals(finance) ? "财务已退回，等委外修改后重新提交；退回原因请在订货单详情里查看"
                    : "还是草稿，等提交财务审核";
            StringBuilder text = new StringBuilder(step).append("。");
            if (missingBom) text.append("委外件还没有维护 BOM(直属物料)，研发完善后才能提交财务。");
            if (!shortages.isEmpty()) {
                text.append("直属物料还没齐套，").append("PENDING".equals(finance) ? "财务批准" : "提交财务")
                        .append("时会被拦下(委外价格每天不一样，物料齐了才解锁)：").append(String.join("；", shortages)).append("。");
            }
            waiting = text.toString();
        } else if (closed) {
            statusText = "已结案";
            waiting = "委外订货单已结案。";
        } else {
            statusText = "财务已批准";
            waiting = running.isEmpty() ? "各环节都已完成，等结案核销。" : "正在：" + String.join("；", running) + "。";
        }
        return new Facts(true, "委外订货单", number, statusText, waiting, text(head.get("bill_date")),
                text(head.get("deliver_date")), List.copyOf(lines), chain.items().size());
    }

    /** ADR-156 订货单齐套检查 (read only): which direct materials this order still lacks. */
    private List<String> orderShortages(UUID orderId) {
        return jdbc.query("""
                SELECT shortage.need_qty, shortage.exact_free_qty + shortage.public_free_qty AS usable_qty,
                       goods.code AS goods_code, goods.name AS goods_name, color.name AS color_name, unit.name AS unit_name
                FROM fn_subcontract_order_kit_shortages(?) shortage
                JOIN goods ON goods.id = shortage.goods_id
                LEFT JOIN colors color ON color.id = shortage.color_id
                LEFT JOIN units unit ON unit.id = goods.unit_id
                ORDER BY goods.code, goods.id
                LIMIT 10
                """, (rs, row) -> "「" + goods(rs.getString("goods_code"), rs.getString("goods_name"), rs.getString("color_name"))
                + "」本单需要 " + plain(rs.getBigDecimal("need_qty")) + unit(rs.getString("unit_name"))
                + "，现在能用 " + plain(rs.getBigDecimal("usable_qty")) + unit(rs.getString("unit_name")), orderId);
    }

    private Facts application(String number, Map<String, Object> head) {
        UUID applicationId = (UUID) head.get("id");
        int status = ((Number) head.get("status")).intValue();
        boolean closed = Boolean.TRUE.equals(head.get("is_closed"));
        List<Map<String, Object>> items = jdbc.queryForList("""
                SELECT id, COALESCE(qty, 0) AS qty, COALESCE(ordered_qty, 0) AS ordered_qty
                FROM subcontract_application_items
                WHERE application_id = ? AND is_deleted = FALSE
                ORDER BY line_no NULLS LAST, id
                """, applicationId);
        List<Line> lines = new ArrayList<>();
        BigDecimal open = BigDecimal.ZERO;
        BigDecimal orderable = BigDecimal.ZERO;
        boolean bomMissing = false;
        boolean anyLocked = false;
        List<String> missing = new ArrayList<>();
        for (Map<String, Object> item : items) {
            SubcontractKitService.ApplicationKit kit = kits.applicationKit((UUID) item.get("id"));
            String unit = unit(kit.unitName());
            BigDecimal itemOpen = zero(kit.openQty());
            BigDecimal itemOrderable = zero(kit.orderableQty());
            open = open.add(itemOpen);
            orderable = orderable.add(itemOrderable);
            boolean itemBomMissing = kit.bomMissing() && itemOpen.signum() > 0;
            bomMissing |= itemBomMissing;
            anyLocked |= !itemBomMissing && itemOpen.signum() > 0 && itemOrderable.signum() == 0;
            String goods = goods(kit.goodsCode(), kit.goodsName(), kit.colorName());
            List<String> details = new ArrayList<>();
            if (itemBomMissing) details.add("委外件还没有维护 BOM(直属物料)，研发完善之前不能下单");
            for (SubcontractKitService.MaterialFact material : kit.materials()) {
                if (material.shortQty() == null || material.shortQty().signum() <= 0 || itemOpen.signum() <= 0) continue;
                String text = "「" + goods(material.goodsCode(), material.goodsName(), material.colorName()) + "」还缺 "
                        + plain(material.shortQty()) + unit(material.unitName()) + "(需要 " + plain(material.neededQty())
                        + "，现在能用 " + plain(material.freeQty()) + ")";
                if (details.size() < MATERIAL_LIMIT) details.add("物料" + text);
                if (missing.size() < MATERIAL_LIMIT) missing.add(label(kit.goodsCode(), "未编码") + " 的" + text);
            }
            if (lines.size() < LINE_LIMIT) lines.add(new Line(goods, "申请 " + plain((BigDecimal) item.get("qty")) + unit
                    + "，已下单 " + plain((BigDecimal) item.get("ordered_qty")) + "，剩余未下单 " + plain(itemOpen)
                    + "，现有物料够做 " + plain(zero(kit.kitQty())) + "，现在可下单 " + plain(itemOrderable) + unit,
                    List.copyOf(details)));
        }
        String statusText;
        String waiting;
        if (status < 0) {
            statusText = "已红冲";
            waiting = "这张委外申请已红冲作废，不能再下单。";
        } else if (status == 0) {
            statusText = "草稿";
            waiting = "还是草稿，审核后才能生成委外订货单。";
        } else if (closed) {
            statusText = "已结案";
            waiting = "委外申请已结案，不能再下单。";
        } else if (open.signum() <= 0) {
            statusText = "已全部下单";
            waiting = "申请数量都已下单或正在财务审批，不需要再下单。";
        } else if (bomMissing) {
            statusText = "缺 BOM";
            waiting = "委外件还没有维护 BOM(直属物料)，研发完善之前不能生成委外订货单。";
        } else if (orderable.signum() == 0) {
            statusText = "等物料齐套(锁住)";
            waiting = "直属物料不够，这张申请锁住了，暂时不能生成委外订货单；委外价格每天不一样，物料齐了才解锁。还缺："
                    + String.join("；", missing) + "。";
        } else if (anyLocked || orderable.compareTo(open) < 0) {
            statusText = "可部分下单";
            waiting = "现有物料只够下一部分，现在可下单 " + plain(orderable) + "，其余等物料到了再解锁"
                    + (missing.isEmpty() ? "。" : "。还缺：" + String.join("；", missing) + "。");
        } else {
            statusText = "待下单";
            waiting = "物料已齐，可以在委外任务中心生成委外订货单，现在可下单 " + plain(orderable) + "。";
        }
        return new Facts(true, "委外申请单", number, statusText, waiting, text(head.get("bill_date")),
                text(head.get("need_date")), List.copyOf(lines), items.size());
    }

    // ---------------------------------------------------------------- text

    private static String render(Facts facts, String time, boolean detailed) {
        StringBuilder reply = new StringBuilder(facts.kind()).append(" ").append(facts.number()).append("：")
                .append(facts.statusText()).append("。");
        if (detailed) reply.append("\n截至 ").append(time).append("。");
        reply.append("\n现在：").append(facts.waiting());
        reply.append("\n单据日期 ").append(facts.billDate() == null ? "未登记" : facts.billDate())
                .append("委外订货单".equals(facts.kind()) ? "，交货日期 " : "，需求日期 ")
                .append(facts.dueDate() == null ? "未登记" : facts.dueDate()).append("。");
        int shown = Math.min(detailed ? LINE_LIMIT : 5, facts.lines().size());
        if (shown > 0) reply.append("\n货品：");
        for (Line line : facts.lines().subList(0, shown)) {
            reply.append("\n• ").append(line.goods()).append("：").append(line.summary()).append("。");
            if (detailed) for (String detail : line.details()) reply.append("\n  ").append(detail).append("。");
        }
        if (facts.lineCount() > shown) {
            reply.append("\n另有 ").append(facts.lineCount() - shown).append(" 个货品")
                    .append(detailed || facts.lines().size() <= shown ? "，请到单据详情查看。" : "，回复“展开”可看更多。");
        }
        if (!detailed) reply.append("\n回复“展开”可看每个货品的环节和缺的物料。");
        return reply.toString();
    }

    /** Fixed server wording only: a detail with a colon could carry a person or a free-text reason. */
    static String safeDetail(String detail) {
        if (detail == null || detail.isBlank() || detail.indexOf('：') >= 0 || detail.indexOf(':') >= 0) return null;
        return label(detail, null);
    }

    private static String nodeState(String state) {
        return switch (state == null ? "" : state) {
            case OrderProgressContracts.NODE_DONE -> "已完成";
            case OrderProgressContracts.NODE_ACTIVE -> "进行中";
            case OrderProgressContracts.NODE_SKIPPED -> "已取消";
            default -> "未开始";
        };
    }

    // ---------------------------------------------------------------- guards and helpers

    private boolean can(String permission) {
        return current.get().filter(actor -> actor.isSuperAdmin() || actor.getPermissions().contains(permission)).isPresent();
    }

    private void require() {
        access.requireDomain(domain());
        if (!available()) throw new ApiException(ErrorCode.FORBIDDEN, "你没有查看委外申请或委外订货单的权限，请联系管理员开通");
    }

    static String documentNo(Map<String, Object> arguments) {
        if (arguments == null || !Set.of("documentNo").equals(arguments.keySet())
                || !(arguments.get("documentNo") instanceof String raw)) throw invalidNumber();
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
            throw new IllegalStateException("Cannot fingerprint subcontract document status", failure);
        }
    }

    private static String goods(String code, String name, String color) {
        return label(code, "未编码") + " · " + label(name, "未命名货品")
                + (color == null || color.isBlank() ? "" : "(" + label(color, "") + ")");
    }

    private static String unit(String unit) { return unit == null || unit.isBlank() ? "" : " " + label(unit, ""); }

    private static String text(Object value) {
        return value == null || value.toString().isBlank() ? null : label(value.toString(), null);
    }

    private static BigDecimal zero(BigDecimal value) { return value == null ? BigDecimal.ZERO : value; }

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
                "请告诉我完整的委外申请单号或委外订货单号：字母和数字，2 到 40 位");
    }

    private static ApiException changed() {
        return new ApiException(ErrorCode.FORBIDDEN, "这张委外单据的状态、物料齐套情况或你的查看范围已变化，请重新查询");
    }
}
