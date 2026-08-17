package com.uten.imp.features.production.chain;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.features.production.chain.dto.ChainHealthCategory;
import com.uten.imp.features.production.chain.dto.ChainHealthIssue;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/**
 * 全链路断链检查器（生产计划单一键生成与全链路溯源设计 §五）。
 *
 * <p>扫描销售订货 → 物料分析 → 生产计划 → 领料单 / 采购申请 四个环节的断链，
 * 每类给出全量命中数 + 截断明细 + 修复入口，让数据"哪一段缺什么"一眼可见：
 * <ol>
 *   <li>有销售缺口无分析：已审订单行仍有调度缺口，但没有有效物料分析承接；</li>
 *   <li>有分析无计划：有效分析仍有未提交/未批准的剩余需求；</li>
 *   <li>有计划无领料：需物料且已进入执行的计划没有真实 DRAW 单；零物料段排除；</li>
 *   <li>有领料无来源：生产领料单没有 plan_draw_links 来源，无法反查计划。</li>
 * </ol>
 *
 * <p>口径与调度工作台一致（缺口表达式、有效分析定义复用
 * {@code ProductionScheduleService} 同款 SQL，改动需双向同步）。
 * 全部为只读查询，不写任何业务数据。
 */
@Service
@RequiredArgsConstructor
public class ProductionChainHealthService {

    /** 与 ProductionScheduleService.SCHEDULING_NEED_SQL 同款（源头在调度服务，改动需双向同步）。 */
    private static final String SCHEDULING_NEED_SQL = """
            GREATEST(
                COALESCE(i.qty,0) - COALESCE(i.shipped_qty,0)
                + COALESCE(i.returned_qty,0) - COALESCE(i.flag_qty,0)
                - COALESCE(i.reserved_qty,0)
                - GREATEST(COALESCE(i.planned_qty,0) - COALESCE(i.produced_qty,0), 0),
                0)
            """.strip();

    private static final int MAX_LIMIT = 200;

    private final EntityManager em;

    @Transactional(readOnly = true)
    public List<ChainHealthCategory> scan(int limit) {
        int capped = limit <= 0 ? 50 : Math.min(limit, MAX_LIMIT);
        List<ChainHealthCategory> out = new ArrayList<>();
        out.add(salesGapWithoutAnalysis(capped));
        out.add(analysisUnplanned(capped));
        out.add(planWithoutDraw(capped));
        out.add(drawWithoutPlan(capped));
        return out;
    }

    // ===== 1. 有销售缺口无分析 =====

    private ChainHealthCategory salesGapWithoutAnalysis(int limit) {
        String from = """
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                JOIN goods g ON g.id = i.goods_id
                WHERE o.is_deleted = FALSE AND o.status = 1
                  AND o.finance_confirmed = TRUE
                  AND o.is_closed = FALSE AND o.is_stopped = FALSE
                  AND i.is_deleted = FALSE
                  AND COALESCE(i.chain_status,0) BETWEEN 1 AND 8
                  AND %s > 0
                  AND NOT EXISTS (
                      SELECT 1 FROM production_material_analysis_items ai
                      JOIN production_material_analyses a ON a.id = ai.analysis_id
                      WHERE ai.sales_order_item_id = i.id
                        AND ai.source_type = 'SALES_ORDER_ITEM'
                        AND ai.is_deleted = FALSE AND a.is_deleted = FALSE
                        AND a.status IN ('ACTIVE','PARTIALLY_PLANNED')
                        AND ai.requested_qty - ai.submitted_qty - ai.approved_qty > 0)
                """.formatted(SCHEDULING_NEED_SQL);
        long count = count("SELECT COUNT(*) " + from);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery(
                salesGapDetailSql(from))
                .setParameter("limit", limit));
        List<ChainHealthIssue> issues = rows.stream()
                .map(r -> new ChainHealthIssue(
                        str(r[0]), str(r[1]), str(r[2]), str(r[3]),
                        "缺口 " + qty(r[4]) + (r[5] == null ? "" : " · 交期 " + r[5]),
                        "SALES_ORDER"))
                .toList();
        return new ChainHealthCategory(
                "SALES_GAP_NO_ANALYSIS",
                "有销售缺口 · 无物料分析",
                "已审且已财务确认的订单行还有调度缺口，但没有有效物料分析承接"
                        + "（未财务确认的订单对计划部不可见，不计入）。修复：到调度台勾选该行进入物料分析。",
                count, issues);
    }

    // ===== 2. 有分析无计划 =====

    private ChainHealthCategory analysisUnplanned(int limit) {
        String from = """
                FROM production_material_analyses a
                WHERE a.is_deleted = FALSE
                  AND a.status IN ('ACTIVE','PARTIALLY_PLANNED')
                  AND EXISTS (
                      SELECT 1 FROM production_material_analysis_items ai
                      WHERE ai.analysis_id = a.id AND ai.is_deleted = FALSE
                        AND ai.requested_qty - ai.submitted_qty - ai.approved_qty > 0)
                """;
        long count = count("SELECT COUNT(*) " + from);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery(
                """
                SELECT a.id, a.analyzed_at,
                       (SELECT COUNT(*) FROM production_material_analysis_items ai
                        WHERE ai.analysis_id = a.id AND ai.is_deleted = FALSE
                          AND ai.requested_qty - ai.submitted_qty - ai.approved_qty > 0),
                       (SELECT COALESCE(SUM(ai.requested_qty - ai.submitted_qty - ai.approved_qty),0)
                        FROM production_material_analysis_items ai
                        WHERE ai.analysis_id = a.id AND ai.is_deleted = FALSE
                          AND ai.requested_qty - ai.submitted_qty - ai.approved_qty > 0)
                """
                        + from
                        + " ORDER BY a.analyzed_at ASC NULLS FIRST LIMIT :limit")
                .setParameter("limit", limit));
        List<ChainHealthIssue> issues = rows.stream()
                .map(r -> new ChainHealthIssue(
                        str(r[0]), str(r[0]),
                        null,
                        "物料分析 " + shortId(r[0]),
                        "待排 " + r[2] + " 项 · 未排量 " + qty(r[3])
                                + (r[1] == null ? "" : " · 分析于 " + r[1]),
                        "MATERIAL_ANALYSIS"))
                .toList();
        return new ChainHealthCategory(
                "ANALYSIS_UNPLANNED",
                "有物料分析 · 未排完计划",
                "有效分析还有未提交/未批准的剩余需求。修复：打开分析，继续下达缺料任务或生成生产计划。",
                count, issues);
    }

    // ===== 3. 有计划无领料 =====

    private ChainHealthCategory planWithoutDraw(int limit) {
        String from = """
                FROM production_plans p
                WHERE p.is_deleted = FALSE AND p.status = 1 AND p.is_closed = FALSE
                  AND NOT EXISTS (
                      SELECT 1
                      FROM plan_draw_links l
                      JOIN stock_documents draw
                        ON draw.id = l.draw_id
                       AND draw.is_deleted = FALSE
                       AND draw.doc_type = 'DRAW'
                      WHERE l.plan_id = p.id
                        AND l.is_deleted = FALSE)
                  AND EXISTS (
                      SELECT 1
                      FROM production_execution_segments segment
                      WHERE segment.plan_id = p.id
                        AND segment.is_deleted = FALSE
                        AND segment.material_requirement_mode = 'DEMANDED'
                        AND segment.status IN (
                            'READY', 'DISPATCHED', 'IN_PROGRESS', 'COMPLETED'))
                """;
        long count = count("SELECT COUNT(*) " + from);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery(
                "SELECT p.id, p.bill_no, p.bill_date, p.workshop_name "
                        + from
                        + " ORDER BY p.bill_date NULLS LAST, p.bill_no LIMIT :limit")
                .setParameter("limit", limit));
        List<ChainHealthIssue> issues = rows.stream()
                .map(r -> new ChainHealthIssue(
                        str(r[0]), str(r[0]), str(r[1]), str(r[1]),
                        (r[2] == null ? "" : "开单 " + r[2])
                                + (r[3] == null ? "" : " · " + r[3]),
                        "PRODUCTION_PLAN"))
                .toList();
        return new ChainHealthCategory(
                "PLAN_NO_DRAW",
                "有计划 · 未生成领料单",
                "已审核未结案计划存在应由物料支撑的执行段，却没有任何生产领料单；"
                        + "零物料执行段不计入。修复：检查执行段齐套与领料单生成链路。",
                count, issues);
    }

    // ===== 4. 有领料无来源 =====

    private ChainHealthCategory drawWithoutPlan(int limit) {
        String from = """
                FROM stock_documents sd
                WHERE sd.doc_type = 'DRAW' AND sd.is_deleted = FALSE
                  AND NOT EXISTS (
                      SELECT 1 FROM plan_draw_links l
                      WHERE l.draw_id = sd.id AND l.is_deleted = FALSE)
                """;
        long count = count("SELECT COUNT(*) " + from);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery(
                "SELECT sd.id, sd.bill_no, sd.bill_date "
                        + from
                        + " ORDER BY sd.bill_date DESC NULLS LAST, sd.bill_no LIMIT :limit")
                .setParameter("limit", limit));
        List<ChainHealthIssue> issues = rows.stream()
                .map(r -> new ChainHealthIssue(
                        str(r[0]), str(r[0]), str(r[1]), str(r[1]),
                        r[2] == null ? "" : "单据日期 " + r[2],
                        "STOCK_DRAW"))
                .toList();
        return new ChainHealthCategory(
                "DRAW_NO_PLAN",
                "有领料单 · 无计划来源",
                "生产领料单没有计划联动记录，无法反查来源计划（老库迁移单据属预期，新单据出现即真断链）。"
                        + "修复：新流程请从计划生成领料单，不要手工直接开。",
                count, issues);
    }

    // ===== 工具 =====

    static String salesGapDetailSql(String fromClause) {
        return "SELECT i.id, o.id, o.bill_no, g.name, %s, "
                .formatted(SCHEDULING_NEED_SQL)
                + "COALESCE(i.deliver_date, o.deliver_date) "
                + fromClause
                + " ORDER BY COALESCE(i.deliver_date, o.deliver_date) ASC NULLS LAST,"
                + " o.bill_date LIMIT :limit";
    }

    private long count(String sql) {
        return ((Number) em.createNativeQuery(sql).getSingleResult()).longValue();
    }

    private static String str(Object value) {
        return value == null ? null : value.toString();
    }

    private static String qty(Object value) {
        if (value == null) return "0";
        BigDecimal bd = value instanceof BigDecimal b ? b : new BigDecimal(value.toString());
        BigDecimal stripped = bd.stripTrailingZeros();
        return stripped.scale() < 0 ? stripped.toPlainString() : stripped.toPlainString();
    }

    private static String shortId(Object value) {
        if (value == null) return "—";
        String id = value instanceof UUID u ? u.toString() : value.toString();
        return id.length() <= 8 ? id : id.substring(0, 8);
    }
}
