package com.uten.imp.features.production.schedule;
import com.uten.imp.common.util.NativeValueConverters;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.validation.RequestLimits;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.mrp.MrpService;
import com.uten.imp.features.production.schedule.dto.PendingPlanRow;
import com.uten.imp.features.production.schedule.dto.ScheduleOrderLine;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 生产调度工作台服务（业务链 · 排产段，docs/07-业务链路/02）。
 *
 * <p>① 待排产列表：已审订单的链路行中"待生产缺口 = qty − 预留 − 已排产 > 0"的明细，
 * 交货越近越靠前，≤3 天 urgent 标红（SOP：距离交货日期越近排序越靠前）。
 *
 * <p>写入排产已迁移到持久物料分析的联合预览/原子生成链路；本服务只保留待排产读模型和
 * 历史兼容查询。
 */
@Service
@RequiredArgsConstructor
public class ProductionScheduleService {

    private final EntityManager em;
    /** 新增排产缺口：订单净未交 - 当前可发预留 - 尚未入库的计划量（均为行单位）。 */
    static final String SCHEDULING_NEED_SQL = """
            GREATEST(
                COALESCE(i.qty,0) - COALESCE(i.shipped_qty,0)
                + COALESCE(i.returned_qty,0) - COALESCE(i.flag_qty,0)
                - COALESCE(i.reserved_qty,0)
                - GREATEST(COALESCE(i.planned_qty,0) - COALESCE(i.produced_qty,0), 0),
                0)
            """.strip();
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final MrpService mrpService;

    /** 待排产订单行（服务端分页；交货升序，urgent=距交货 ≤3 天或已逾期）。
     *  keyword 模糊 订单号/客户/货品名/货品编码；dateFrom/dateTo 交货日期范围（行级优先、缺省取单头）。
     *  页码越界自动回退到最后一页。 */
    @Transactional(readOnly = true)
    public com.uten.imp.common.web.PageResponse<PendingPlanRow> pending(
            int page, int size, String keyword, LocalDate dateFrom, LocalDate dateTo,
            String sort, String order, String status) {
        int p = Math.max(1, page);
        int sz = Math.min(Math.max(1, size), 100);
        String kw = keyword == null ? "" : keyword.trim().toLowerCase();
        LocalDate warn = BusinessTime.today().plusDays(3);
        String filters = pendingFiltersBase(kw, dateFrom, dateTo) + pendingStatusFilter(status);
        // :warn 仅 urgent/normal 状态筛选会进 SQL；Hibernate 6 原生查询 setParameter 会校验参数
        // 是否存在，未用时绑定抛 UnknownParameterException，故按需绑定（facets 恒为 true）。
        boolean needsWarn = "urgent".equals(status) || "normal".equals(status);

        var countQ = em.createNativeQuery("SELECT COUNT(*) " + filters);
        bindPendingFilters(countQ, kw, dateFrom, dateTo, warn, needsWarn);
        long total = ((Number) countQ.getSingleResult()).longValue();
        int totalPages = total == 0 ? 0 : (int) ((total + sz - 1) / sz);
        if (totalPages > 0 && p > totalPages) p = totalPages; // 页码越界回退

        var dataQ = em.createNativeQuery("""
                SELECT i.id, o.id, o.bill_no, o.client_id, c.name,
                       i.goods_id, g.code, g.name, g.spec,
                       i.color_id, col.name, i.unit_id, u.name,
                       i.qty, COALESCE(i.reserved_qty,0), COALESCE(i.planned_qty,0),
                       %s AS need,
                       COALESCE(i.deliver_date, o.deliver_date) AS deliver,
                       i.chain_status,
                       latest_analysis.analysis_id,
                       latest_analysis.analysis_item_id,
                       latest_analysis.analysis_status,
                       latest_analysis.analysis_version,
                       latest_analysis.analyzed_at,
                       latest_analysis.requested_qty,
                       latest_analysis.submitted_qty,
                       latest_analysis.approved_qty,
                       latest_analysis.ready_now_qty,
                       latest_analysis.ready_by_date_qty,
                       CASE WHEN latest_analysis.remaining_qty > 0 THEN
                           LEAST(latest_analysis.ready_now_qty
                                  / latest_analysis.remaining_qty, 1)
                       ELSE 1 END AS readiness_ratio
                """.formatted(SCHEDULING_NEED_SQL) + filters
                + " " + pendingOrderBy(sort, order) + " LIMIT :lim OFFSET :off");
        bindPendingFilters(dataQ, kw, dateFrom, dateTo, warn, needsWarn);
        @SuppressWarnings("unchecked")
        List<Object[]> rs = (List<Object[]>) dataQ
                .setParameter("lim", sz).setParameter("off", (p - 1) * sz)
                .getResultList();

        List<PendingPlanRow> out = new ArrayList<>(rs.size());
        for (Object[] r : rs) {
            LocalDate deliver = r[17] == null ? null : NativeValueConverters.toLocalDate(r[17]);
            out.add(new PendingPlanRow(
                    (UUID) r[0], (UUID) r[1], (String) r[2], (UUID) r[3], (String) r[4],
                    (UUID) r[5], (String) r[6], (String) r[7], (String) r[8],
                    (UUID) r[9], (String) r[10], (UUID) r[11], (String) r[12],
                    bd(r[13]), bd(r[14]), bd(r[15]), bd(r[16]),
                    deliver, r[18] == null ? null : ((Number) r[18]).shortValue(),
                    deliver != null && !deliver.isAfter(warn),
                    (UUID) r[19], (UUID) r[20], (String) r[21],
                    r[22] == null ? null : ((Number) r[22]).longValue(),
                    offsetDateTime(r[23]), bdOrNull(r[24]), bdOrNull(r[25]),
                    bdOrNull(r[26]), bdOrNull(r[27]), bdOrNull(r[28]),
                    bdOrNull(r[29])));
        }
        return new com.uten.imp.common.web.PageResponse<>(out, p, sz, total, totalPages);
    }

    /** 绑定 pending 过滤参数（未出现的条件不绑；:warn 始终绑——状态筛选/facets 会用到，未用也无害）。 */
    private static void bindPendingFilters(jakarta.persistence.Query q, String kw,
                                           LocalDate dateFrom, LocalDate dateTo,
                                           LocalDate warn, boolean needsWarn) {
        if (!kw.isEmpty()) q.setParameter("kw", "%" + kw + "%");
        if (dateFrom != null) q.setParameter("dateFrom", dateFrom);
        if (dateTo != null) q.setParameter("dateTo", dateTo);
        if (needsWarn && warn != null) q.setParameter("warn", warn);
    }

    /** 行级交货日期（行级优先、缺省取单头）。 */
    private static final String DELIVER_EXPR = "COALESCE(i.deliver_date, o.deliver_date)";

    /** pending 列表 FROM/JOIN/WHERE 基础过滤（keyword 模糊 订单号/客户/货品，交货日期范围；不含状态）。 */
    private static String pendingFiltersBase(String kw, LocalDate dateFrom, LocalDate dateTo) {
        return """
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                LEFT JOIN clients c ON c.id = o.client_id
                JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors col ON col.id = i.color_id
                LEFT JOIN units u ON u.id = i.unit_id
                LEFT JOIN LATERAL (
                    SELECT a.id AS analysis_id,
                           ai.id AS analysis_item_id,
                           a.status AS analysis_status,
                           a.version AS analysis_version,
                           a.analyzed_at,
                           ai.requested_qty,
                           ai.submitted_qty,
                           ai.approved_qty,
                           ai.ready_now_qty,
                           ai.ready_by_date_qty,
                           (ai.requested_qty-ai.submitted_qty-ai.approved_qty)
                               AS remaining_qty
                    FROM production_material_analysis_items ai
                    JOIN production_material_analyses a ON a.id = ai.analysis_id
                    WHERE ai.sales_order_item_id = i.id
                      AND ai.source_type = 'SALES_ORDER_ITEM'
                      AND ai.is_deleted = FALSE AND a.is_deleted = FALSE
                      AND a.status IN ('ACTIVE','PARTIALLY_PLANNED')
                      AND ai.requested_qty-ai.submitted_qty-ai.approved_qty > 0
                    ORDER BY a.analyzed_at DESC, a.id DESC
                    LIMIT 1
                ) latest_analysis ON TRUE
                WHERE o.is_deleted = false AND o.status = 1
                  AND o.finance_confirmed = true
                  AND o.is_closed = false AND o.is_stopped = false
                  AND i.is_deleted = false
                  AND COALESCE(i.chain_status,0) BETWEEN 1 AND 8
                  AND %s > 0
                """.formatted(SCHEDULING_NEED_SQL)
                + (kw.isEmpty() ? ""
                        : "  AND (LOWER(o.bill_no) LIKE :kw OR LOWER(COALESCE(c.name,'')) LIKE :kw"
                          + " OR LOWER(g.name) LIKE :kw OR LOWER(g.code) LIKE :kw)\n")
                + (dateFrom == null ? ""
                        : "  AND " + DELIVER_EXPR + " >= :dateFrom\n")
                + (dateTo == null ? ""
                        : "  AND " + DELIVER_EXPR + " <= :dateTo\n");
    }

    /** 状态筛选 WHERE 片段（status = urgent/normal；未知值不过滤）。引用 :warn。 */
    private static String pendingStatusFilter(String status) {
        return switch (status == null ? "" : status) {
            case "urgent" -> "  AND " + DELIVER_EXPR + " <= :warn\n";
            case "normal" -> "  AND (" + DELIVER_EXPR + " IS NULL OR " + DELIVER_EXPR + " > :warn)\n";
            default -> "";
        };
    }

    /** pending 排序 ORDER BY（白名单映射前端列 key→SQL 表达式；未知/空→默认交货升序）。方向 asc/desc。
     *  铁律：ORDER BY 不拼用户原值，只从白名单取表达式。deliver/need 是 SELECT 别名（Postgres 支持）。 */
    private static String pendingOrderBy(String sort, String order) {
        String expr = switch (sort == null ? "" : sort) {
            case "deliverDate" -> "deliver";
            case "qty" -> "i.qty";
            case "needQty" -> "need";
            case "orderBillNo" -> "o.bill_no";
            default -> "deliver";
        };
        String dir = "desc".equalsIgnoreCase(order) ? "DESC" : "ASC";
        return "deliver".equals(expr)
                ? "ORDER BY deliver " + dir + " NULLS LAST, o.bill_date"
                : "ORDER BY " + expr + " " + dir + " NULLS LAST, deliver ASC NULLS LAST, o.bill_date";
    }

    /** 待排产状态 facets：{status:[{value,count,label}]}（紧急/正常 两桶，全量计数）。
     *  复用 pendingFiltersBase（不含 status 条件，故两桶计数互补）；SUM(CASE WHEN ...) 聚合。 */
    @Transactional(readOnly = true)
    public Map<String, List<Map<String, Object>>> pendingFacets(
            String keyword, LocalDate dateFrom, LocalDate dateTo) {
        String kw = keyword == null ? "" : keyword.trim().toLowerCase();
        LocalDate warn = BusinessTime.today().plusDays(3);
        String filters = pendingFiltersBase(kw, dateFrom, dateTo);
        var q = em.createNativeQuery("""
                SELECT
                  SUM(CASE WHEN %s <= :warn THEN 1 ELSE 0 END),
                  SUM(CASE WHEN (%s IS NULL OR %s > :warn) THEN 1 ELSE 0 END)
                """.formatted(DELIVER_EXPR, DELIVER_EXPR, DELIVER_EXPR)
                + filters);
        bindPendingFilters(q, kw, dateFrom, dateTo, warn, true);
        Object[] r = (Object[]) q.getSingleResult();
        long urgent = r[0] == null ? 0 : ((Number) r[0]).longValue();
        long normal = r[1] == null ? 0 : ((Number) r[1]).longValue();
        return Map.of("status", List.of(
                facetBucket("urgent", urgent, "紧急"),
                facetBucket("normal", normal, "正常")));
    }

    private static Map<String, Object> facetBucket(String value, long count, String label) {
        return Map.of("value", value, "count", count, "label", label);
    }


    // ======================== 工作台徽标：待排产计数 ========================

    /** 缺料待备料计数（PMC 采购管理徽标）：链路行状态=3 待物料（计划已审但 BOM 净需求不足）的行数。 */
    @Transactional(readOnly = true)
    public Map<String, Long> shortageCount() {
        if (!mrpService.isPlanningWriteReady()) {
            return Map.of("count", 0L);
        }
        // 单列原生查询返回标量（Long），不能当 Object[] 强转（多列才返回 Object[]）。
        Number n = (Number) em.createNativeQuery("""
                SELECT COUNT(*)
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                WHERE o.is_deleted = false AND o.status = 1
                  AND o.finance_confirmed = true
                  AND o.is_closed = false AND o.is_stopped = false
                  AND i.is_deleted = false AND i.chain_status = 3
                """).getSingleResult();
        return Map.of("count", n.longValue());
    }

    /** 待排产计数（生产部工作台徽标）：待排产行数 + 其中紧急（交货 ≤3 天/含逾期）+ 已逾期（交货 < 今天）行数。口径同 PENDING_SQL。 */
    @Transactional(readOnly = true)
    public Map<String, Long> pendingCount() {
        Object[] r = (Object[]) em.createNativeQuery("""
                SELECT COUNT(*),
                       COUNT(*) FILTER (
                           WHERE COALESCE(i.deliver_date, o.deliver_date)
                                 <= CAST(:today AS date) + 3),
                       COUNT(*) FILTER (
                           WHERE COALESCE(i.deliver_date, o.deliver_date)
                                 < CAST(:today AS date))
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                WHERE o.is_deleted = false AND o.status = 1
                  AND o.finance_confirmed = true
                  AND o.is_closed = false AND o.is_stopped = false
                  AND i.is_deleted = false
                  AND COALESCE(i.chain_status,0) BETWEEN 1 AND 8
                  AND %s > 0
                """.formatted(SCHEDULING_NEED_SQL))
                .setParameter("today", BusinessTime.today())
                .getSingleResult();
        return Map.of("count", ((Number) r[0]).longValue(),
                "urgent", ((Number) r[1]).longValue(),
                "overdue", ((Number) r[2]).longValue());
    }

    // ======================== 新建计划单：从订单带明细（含 BOM 零件） ========================

    /**
     * 已审订单明细 + 每行货品一层 BOM 零件清单。
     * 前端「来源订单→选行带入计划明细」弹窗数据源：勾选行带 salesOrderItemId 入计划，
     * 审核时走 ProductionPlanService.linkOrderItems 手工 1:1 link 分支，业务链闭合。
     */
    @Transactional(readOnly = true)
    public List<ScheduleOrderLine> orderLines(UUID orderId) {
        Object n = em.createNativeQuery(
                """
                SELECT COUNT(*) FROM sales_orders
                WHERE id=:id AND status=1 AND is_deleted=false
                  AND is_closed=false AND is_stopped=false
                  AND finance_confirmed=true
                """)
                .setParameter("id", orderId).getSingleResult();
        if (((Number) n).intValue() == 0) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核且已通过财务确认的销售订货单可带入计划明细");
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rs = em.createNativeQuery("""
                SELECT i.id, i.line_no, i.goods_id, g.code, g.name, g.spec,
                       i.color_id, col.name, i.unit_id, u.name,
                       i.qty, COALESCE(i.planned_qty,0),
                       %s AS need,
                       COALESCE(i.deliver_date, o.deliver_date) AS deliver,
                       o.bill_no, c.name, COALESCE(i.unit_rate, 1)
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                LEFT JOIN clients c ON c.id = o.client_id
                JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors col ON col.id = i.color_id
                LEFT JOIN units u ON u.id = i.unit_id
                WHERE i.order_id = :orderId AND i.is_deleted = false
                  AND COALESCE(i.chain_status,0) BETWEEN 1 AND 8
                ORDER BY i.line_no NULLS LAST, i.id
                """.formatted(SCHEDULING_NEED_SQL))
                .setParameter("orderId", orderId).getResultList();
        List<ScheduleOrderLine> out = new ArrayList<>(rs.size());
        for (Object[] r : rs) {
            UUID goodsId = (UUID) r[2];
            BigDecimal need = bd(r[12]);
            BigDecimal rate = bd(r[16]).signum() > 0 ? bd(r[16]) : BigDecimal.ONE;
            out.add(new ScheduleOrderLine(
                    (UUID) r[0], r[1] == null ? null : ((Number) r[1]).intValue(),
                    goodsId, (String) r[3], (String) r[4], (String) r[5],
                    (UUID) r[6], (String) r[7], (UUID) r[8], (String) r[9],
                    bd(r[10]), bd(r[11]), need, rate,
                    r[13] == null ? null : NativeValueConverters.toLocalDate(r[13]),
                    (String) r[14], (String) r[15],
                    // 零件需求按基本单位折算：缺口(销售单位) × unit_rate
                    bomOf(goodsId, need.multiply(rate))));
        }
        return out;
    }

    /** 一层 BOM 零件（需求小计 = 单件用量 × 待排产缺口；onhand 全仓即时库存；selfMade=零件本身还有 BOM）。 */
    private List<ScheduleOrderLine.BomComponent> bomOf(UUID goodsId, BigDecimal need) {
        @SuppressWarnings("unchecked")
        List<Object[]> rs = em.createNativeQuery("""
                SELECT b.component_goods_id, g.code, g.name, g.spec, b.qty,
                       COALESCE(sb.onhand, 0),
                       EXISTS (SELECT 1 FROM goods_bom_items c
                               WHERE c.goods_id = b.component_goods_id AND c.is_deleted = false)
                FROM goods_bom_items b
                JOIN goods g ON g.id = b.component_goods_id
                LEFT JOIN (SELECT goods_id, SUM(qty) AS onhand FROM stock_balances GROUP BY goods_id) sb
                       ON sb.goods_id = b.component_goods_id
                WHERE b.goods_id = :g AND b.is_deleted = false
                ORDER BY g.code
                """).setParameter("g", goodsId).getResultList();
        List<ScheduleOrderLine.BomComponent> out = new ArrayList<>(rs.size());
        for (Object[] r : rs) {
            BigDecimal per = bd(r[4]);
            out.add(new ScheduleOrderLine.BomComponent(
                    (UUID) r[0], (String) r[1], (String) r[2], (String) r[3],
                    per, per.multiply(need), bd(r[5]), Boolean.TRUE.equals(r[6])));
        }
        return out;
    }

    // ======================== D2 建议完工日期 ========================

    /** 建议完工日期（韩焕超）：按 历史日均完工(近 180 天报工) 推天数 + BOM 层级缓冲（每多一层 +1 天）。
     *  items=[{goodsId, qty}]；返回 suggestedDate + 每货品依据（无历史的行 days=null 不参与取最大）。 */
    @Transactional(readOnly = true)
    public Map<String, Object> suggestFinish(List<Map<String, Object>> items, LocalDate startDate) {
        if (items == null
                || items.isEmpty()
                || items.size() > RequestLimits.DOCUMENT_LINES) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "items 必须包含 1-" + RequestLimits.DOCUMENT_LINES + " 行");
        }
        LocalDate today = BusinessTime.today();
        LocalDate start = startDate != null ? startDate : today;
        List<Map<String, Object>> lines = new ArrayList<>();
        int maxDays = 0;
        int maxDepth = 1;
        boolean anyHistory = false;
        for (Map<String, Object> it : items) {
            UUID goodsId;
            BigDecimal qty;
            try {
                goodsId = UUID.fromString(String.valueOf(it == null ? null : it.get("goodsId")));
                qty = new BigDecimal(String.valueOf(it == null ? null : it.get("qty")));
            } catch (IllegalArgumentException ex) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "items 行必须包含合法 goodsId 和大于 0 的 qty");
            }
            if (qty.signum() <= 0) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "items 行必须包含合法 goodsId 和大于 0 的 qty");
            }
            // 历史日均完工 = 近 180 天报工量 / 报工天数（ DISTINCT bill_date ）
            Object avg = em.createNativeQuery("""
                    SELECT SUM(i.qty) / NULLIF(COUNT(DISTINCT i.bill_date),0)
                    FROM production_daily_report_items i
                    JOIN production_daily_reports d ON d.id = i.report_id
                    WHERE i.goods_id = :g AND d.status = 1 AND i.is_deleted = false
                      AND i.bill_date >= CAST(:historyStart AS date)
                    """)
                    .setParameter("g", goodsId)
                    .setParameter("historyStart", today.minusDays(180))
                    .getSingleResult();
            BigDecimal dailyAvg = avg == null ? null : (BigDecimal) avg;
            Integer days = null;
            if (dailyAvg != null && dailyAvg.signum() > 0) {
                days = qty.divide(dailyAvg, 0, java.math.RoundingMode.CEILING).intValue();
                maxDays = Math.max(maxDays, days);
                anyHistory = true;
            }
            int depth = bomDepth(goodsId);
            maxDepth = Math.max(maxDepth, depth);
            Map<String, Object> line = new LinkedHashMap<>();
            line.put("goodsId", goodsId.toString());
            line.put("qty", qty);
            line.put("dailyAvg", dailyAvg);
            line.put("days", days);
            line.put("bomDepth", depth);
            lines.add(line);
        }
        // BOM 层级缓冲：多层 BOM 的半成品需先行投产，每多一层 +1 天
        int buffer = anyHistory ? Math.max(0, maxDepth - 1) : 0;
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("startDate", start.toString());
        out.put("suggestedDate", anyHistory ? start.plusDays(maxDays + buffer).toString() : null);
        out.put("planDays", anyHistory ? maxDays + buffer : null);
        out.put("bomBufferDays", buffer);
        out.put("lines", lines);
        out.put("note", anyHistory ? null : "所选货品近 180 天无报工记录，无法推算(给出各行 dailyAvg 为空)");
        return out;
    }

    /** BOM 最大层级（防环上限 5）。 */
    private int bomDepth(UUID goodsId) {
        Object d = em.createNativeQuery("""
                WITH RECURSIVE bom AS (
                    SELECT b.component_goods_id AS gid, 1 AS depth
                    FROM goods_bom_items b WHERE b.goods_id = :g AND b.is_deleted = false
                    UNION ALL
                    SELECT b.component_goods_id, bom.depth + 1
                    FROM goods_bom_items b JOIN bom ON b.goods_id = bom.gid
                    WHERE b.is_deleted = false AND bom.depth < 5
                )
                SELECT COALESCE(MAX(depth), 1) FROM bom
                """).setParameter("g", goodsId).getSingleResult();
        return d == null ? 1 : ((Number) d).intValue();
    }

    /** Java 镜像口径，供边界测试与非 SQL 调用复用。 */
    static BigDecimal schedulingNeed(
            BigDecimal qty,
            BigDecimal shippedQty,
            BigDecimal returnedQty,
            BigDecimal flagQty,
            BigDecimal reservedQty,
            BigDecimal plannedQty,
            BigDecimal producedQty) {
        BigDecimal outstanding = zero(qty)
                .subtract(zero(shippedQty))
                .add(zero(returnedQty))
                .subtract(zero(flagQty));
        BigDecimal unfinishedPlan = zero(plannedQty)
                .subtract(zero(producedQty))
                .max(BigDecimal.ZERO);
        return outstanding
                .subtract(zero(reservedQty))
                .subtract(unfinishedPlan)
                .max(BigDecimal.ZERO);
    }

    private static BigDecimal zero(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value;
    }

    private static BigDecimal bd(Object v) {
        return v == null ? BigDecimal.ZERO : (BigDecimal) v;
    }

    private static BigDecimal bdOrNull(Object value) {
        return value == null ? null : new BigDecimal(value.toString());
    }

    private static java.time.OffsetDateTime offsetDateTime(Object value) {
        if (value == null) return null;
        if (value instanceof java.time.OffsetDateTime offset) return offset;
        if (value instanceof java.time.Instant instant) {
            return instant.atOffset(java.time.ZoneOffset.UTC);
        }
        if (value instanceof java.sql.Timestamp timestamp) {
            return timestamp.toInstant().atOffset(java.time.ZoneOffset.UTC);
        }
        return java.time.OffsetDateTime.parse(value.toString());
    }
}
