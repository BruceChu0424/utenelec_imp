package com.uten.imp.features.production.chain;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.chain.dto.ChainHealthCategory;
import com.uten.imp.features.production.chain.dto.ChainHealthIssue;
import com.uten.imp.security.DocumentAccessPolicy;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
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
    private final ProductionChainSalesAccessPolicy salesAccess;
    private final ProductionDocumentAccessPolicy productionAccess;
    private final ProductionChainStockAccessPolicy stockAccess;

    @Transactional(readOnly = true)
    public List<ChainHealthCategory> scan(int limit) {
        int capped = limit <= 0 ? 50 : Math.min(limit, MAX_LIMIT);
        List<ChainHealthCategory> out = new ArrayList<>();
        out.add(salesGapWithoutAnalysis(capped));
        out.add(analysisUnplanned(capped));
        out.add(planWithoutDraw(capped));
        out.add(drawWithoutPlan(capped));
        out.add(duplicateActiveDrawLinks(capped));
        out.add(planQuantityCacheMismatch(capped));
        out.add(reportOrInboundOverflow(capped));
        out.add(completedSegmentViolation(capped));
        out.add(fqcQuantityMismatch(capped));
        out.add(fqcRecoveryMismatch(capped));
        return out;
    }

    // ===== 1. 有销售缺口无分析 =====

    private ChainHealthCategory salesGapWithoutAnalysis(int limit) {
        var scope = salesAccess.nativeReadScope(
                "o.maker_id", "salesHealthOwners");
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
                  AND %s
                """.formatted(SCHEDULING_NEED_SQL, scope.predicate());
        long count = count("SELECT COUNT(*) " + from, scope);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                limitedQuery(salesGapDetailSql(from), scope, limit));
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
                        + "(未财务确认的订单对计划部不可见，不计入)。修复：到调度台勾选该行进入物料分析。",
                count, issues);
    }

    // ===== 2. 有分析无计划 =====

    private ChainHealthCategory analysisUnplanned(int limit) {
        var scope = productionAccess.nativeReadScope(
                "a.maker_id", "analysisHealthOwners");
        String from = """
                FROM production_material_analyses a
                WHERE a.is_deleted = FALSE
                  AND a.status IN ('ACTIVE','PARTIALLY_PLANNED')
                  AND EXISTS (
                      SELECT 1 FROM production_material_analysis_items ai
                      WHERE ai.analysis_id = a.id AND ai.is_deleted = FALSE
                        AND ai.requested_qty - ai.submitted_qty - ai.approved_qty > 0)
                  AND %s
                """.formatted(scope.predicate());
        long count = count("SELECT COUNT(*) " + from, scope);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(limitedQuery(
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
                        + " ORDER BY a.analyzed_at ASC NULLS FIRST LIMIT :limit",
                scope,
                limit));
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
        var scope = productionAccess.nativeReadScope(
                "p.maker_id", "planDrawHealthOwners");
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
                  AND %s
                """.formatted(scope.predicate());
        long count = count("SELECT COUNT(*) " + from, scope);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(limitedQuery(
                "SELECT p.id, p.bill_no, p.bill_date, p.workshop_name "
                        + from
                        + " ORDER BY p.bill_date NULLS LAST, p.bill_no LIMIT :limit",
                scope,
                limit));
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
        var scope = stockAccess.nativeReadScope(
                "sd.maker_id", "drawHealthOwners");
        String from = """
                FROM stock_documents sd
                WHERE sd.doc_type = 'DRAW' AND sd.is_deleted = FALSE
                  AND NOT EXISTS (
                      SELECT 1 FROM plan_draw_links l
                      WHERE l.draw_id = sd.id AND l.is_deleted = FALSE)
                  AND %s
                """.formatted(scope.predicate());
        long count = count("SELECT COUNT(*) " + from, scope);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(limitedQuery(
                "SELECT sd.id, sd.bill_no, sd.bill_date "
                        + from
                        + " ORDER BY sd.bill_date DESC NULLS LAST, sd.bill_no LIMIT :limit",
                scope,
                limit));
        List<ChainHealthIssue> issues = rows.stream()
                .map(r -> new ChainHealthIssue(
                        str(r[0]), str(r[0]), str(r[1]), str(r[1]),
                        r[2] == null ? "" : "单据日期 " + r[2],
                        "STOCK_DRAW"))
                .toList();
        return new ChainHealthCategory(
                "DRAW_NO_PLAN",
                "有领料单 · 无计划来源",
                "生产领料单没有计划联动记录，无法反查来源计划(老库迁移单据属预期，新单据出现即真断链)。"
                        + "修复：新流程请从计划生成领料单，不要手工直接开。",
                count, issues);
    }

    // ===== 5. 活动 DRAW 关系重复或跨计划 =====

    private ChainHealthCategory duplicateActiveDrawLinks(int limit) {
        var scope = productionAccess.nativeReadScope(
                "plan.maker_id", "duplicateDrawOwners");
        String grouped = """
                SELECT (array_agg(link.id ORDER BY link.id))[1]
                           AS sample_link_id,
                       link.draw_id,
                       MIN(draw.bill_no) AS draw_no,
                       (array_agg(
                           DISTINCT plan.id ORDER BY plan.id))[1]
                           AS sample_plan_id,
                       MIN(plan.bill_no) AS sample_plan_no,
                       COUNT(*) AS link_count,
                       COUNT(DISTINCT link.plan_id) AS plan_count
                FROM plan_draw_links link
                JOIN production_plans plan
                  ON plan.id = link.plan_id
                 AND plan.is_deleted = FALSE
                JOIN stock_documents draw
                  ON draw.id = link.draw_id
                 AND draw.is_deleted = FALSE
                WHERE link.is_deleted = FALSE
                  AND %s
                GROUP BY link.draw_id
                HAVING COUNT(*) > 1
                    OR COUNT(DISTINCT link.plan_id) > 1
                """.formatted(scope.predicate());
        long count = count(
                "SELECT COUNT(*) FROM (" + grouped + ") anomaly",
                scope);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                limitedQuery(
                        "SELECT sample_link_id, draw_id, draw_no, "
                                + "sample_plan_id, sample_plan_no, "
                                + "link_count, plan_count FROM ("
                                + grouped
                                + ") anomaly ORDER BY draw_no, draw_id "
                                + "LIMIT :limit",
                        scope,
                        limit));
        List<ChainHealthIssue> issues = rows.stream()
                .map(row -> new ChainHealthIssue(
                        str(row[1]), str(row[3]), str(row[2]),
                        str(row[2]),
                        "活动关系 " + row[5] + " 条 · 涉及计划 "
                                + row[6] + " 张"
                                + (row[4] == null
                                ? "" : " · 示例 " + row[4]),
                        "STOCK_DRAW"))
                .toList();
        return new ChainHealthCategory(
                "DUPLICATE_ACTIVE_DRAW_LINK",
                "生产计划与领料单关系重复",
                "同一活动 DRAW 出现重复关系或同时归属多张生产计划。"
                        + "V411 会阻止新重复；已有命中必须人工按 UUID 对账，禁止自动删行。",
                count,
                issues);
    }

    // ===== 6. fqty / iqty 缓存与有效事实不一致 =====

    private ChainHealthCategory planQuantityCacheMismatch(int limit) {
        var scope = productionAccess.nativeReadScope(
                "plan.maker_id", "quantityCacheOwners");
        String from = """
                FROM production_plan_items item
                JOIN production_plans plan
                  ON plan.id = item.plan_id
                 AND plan.is_deleted = FALSE
                LEFT JOIN goods goods
                  ON goods.id = item.goods_id
                LEFT JOIN LATERAL (
                    SELECT COALESCE(SUM(
                               report_item.qty
                               - COALESCE(adjusted.qty, 0)), 0) AS qty
                    FROM production_daily_report_items report_item
                    JOIN production_daily_reports report
                      ON report.id = report_item.report_id
                     AND report.is_deleted = FALSE
                     AND report.status = 1
                    LEFT JOIN LATERAL (
                        SELECT SUM(adjustment.adjusted_qty) AS qty
                        FROM production_fqc_contribution_adjustments adjustment
                        WHERE adjustment.source_report_item_id = report_item.id
                    ) adjusted ON TRUE
                    WHERE report_item.plan_item_id = item.id
                      AND report_item.is_deleted = FALSE
                ) reported ON TRUE
                LEFT JOIN LATERAL (
                    SELECT COALESCE(SUM(stock_item.qty), 0) AS qty
                    FROM stock_document_items stock_item
                    JOIN stock_documents stock
                      ON stock.id = stock_item.doc_id
                     AND stock.is_deleted = FALSE
                     AND stock.doc_type = 'FINISHED_IN'
                     AND stock.status = 1
                    WHERE stock_item.upstream_item_id = item.id
                      AND stock_item.is_deleted = FALSE
                ) inbound ON TRUE
                WHERE item.is_deleted = FALSE
                  AND %s
                  AND (
                      COALESCE(item.fqty, 0) <>
                          COALESCE(reported.qty, 0)
                      OR COALESCE(item.iqty, 0) <>
                          COALESCE(inbound.qty, 0)
                  )
                """.formatted(scope.predicate());
        long count = count("SELECT COUNT(*) " + from, scope);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                limitedQuery("""
                        SELECT item.id, plan.id, plan.bill_no,
                               item.product_no, goods.name,
                               COALESCE(item.fqty, 0),
                               COALESCE(reported.qty, 0),
                               COALESCE(item.iqty, 0),
                               COALESCE(inbound.qty, 0)
                        """ + from + """
                        ORDER BY plan.bill_no, item.line_no, item.id
                        LIMIT :limit
                        """, scope, limit));
        List<ChainHealthIssue> issues = rows.stream()
                .map(row -> new ChainHealthIssue(
                        str(row[0]), str(row[1]), str(row[2]),
                        str(row[3]),
                        (row[4] == null ? "" : row[4] + " · ")
                                + "fqty " + qty(row[5])
                                + "/事实 " + qty(row[6])
                                + " · iqty " + qty(row[7])
                                + "/事实 " + qty(row[8]),
                        "PRODUCTION_PLAN"))
                .toList();
        return new ChainHealthCategory(
                "PLAN_QUANTITY_CACHE_MISMATCH",
                "计划数量缓存与有效事实不一致",
                "计划行 fqty 必须等于有效审核报工合计，iqty 必须等于有效已审"
                        + " FINISHED_IN 合计；任一差异都可能造成错误完成率或重复处理。",
                count,
                issues);
    }

    // ===== 7. 报工 / 入库超过计划或入库超过报工 =====

    private ChainHealthCategory reportOrInboundOverflow(int limit) {
        var scope = productionAccess.nativeReadScope(
                "plan.maker_id", "quantityOverflowOwners");
        String from = """
                FROM production_plan_items item
                JOIN production_plans plan
                  ON plan.id = item.plan_id
                 AND plan.is_deleted = FALSE
                LEFT JOIN goods goods
                  ON goods.id = item.goods_id
                WHERE item.is_deleted = FALSE
                  AND %s
                  AND (
                      COALESCE(item.fqty, 0) > COALESCE(item.qty, 0)
                      OR COALESCE(item.iqty, 0) >
                         COALESCE(item.fqty, 0)
                      OR COALESCE(item.iqty, 0) > COALESCE(item.qty, 0)
                  )
                """.formatted(scope.predicate());
        long count = count("SELECT COUNT(*) " + from, scope);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                limitedQuery("""
                        SELECT item.id, plan.id, plan.bill_no,
                               item.product_no, goods.name,
                               COALESCE(item.qty, 0),
                               COALESCE(item.fqty, 0),
                               COALESCE(item.iqty, 0)
                        """ + from + """
                        ORDER BY plan.bill_no, item.line_no, item.id
                        LIMIT :limit
                        """, scope, limit));
        List<ChainHealthIssue> issues = rows.stream()
                .map(row -> new ChainHealthIssue(
                        str(row[0]), str(row[1]), str(row[2]),
                        str(row[3]),
                        (row[4] == null ? "" : row[4] + " · ")
                                + "计划 " + qty(row[5])
                                + " / 报工 " + qty(row[6])
                                + " / 入库 " + qty(row[7]),
                        "PRODUCTION_PLAN"))
                .toList();
        return new ChainHealthCategory(
                "REPORT_OR_INBOUND_OVERFLOW",
                "报工或入库数量越界",
                "必须满足 iqty ≤ fqty ≤ 计划量；命中表示完成率、库存或报工链"
                        + "至少一处越界，应立即停止相关单据继续写入并对账。",
                count,
                issues);
    }

    // ===== 8. COMPLETED 执行段未足额入库或物料未结清 =====

    private ChainHealthCategory completedSegmentViolation(int limit) {
        var scope = productionAccess.nativeReadScope(
                "plan.maker_id", "completedSegmentOwners");
        String from = """
                FROM production_execution_segments segment
                JOIN production_plans plan
                  ON plan.id = segment.plan_id
                 AND plan.is_deleted = FALSE
                LEFT JOIN LATERAL (
                    SELECT COALESCE(SUM(item.qty), 0) AS qty
                    FROM stock_document_items item
                    JOIN stock_documents document
                      ON document.id = item.doc_id
                     AND document.is_deleted = FALSE
                     AND document.doc_type = 'FINISHED_IN'
                     AND document.status = 1
                    WHERE item.execution_segment_id = segment.id
                      AND item.is_deleted = FALSE
                ) inbound ON TRUE
                WHERE segment.is_deleted = FALSE
                  AND segment.status = 'COMPLETED'
                  AND %s
                  AND (
                      COALESCE(inbound.qty, 0) <>
                          COALESCE(segment.planned_qty, 0)
                      OR EXISTS (
                          SELECT 1
                          FROM production_material_demands demand
                          LEFT JOIN v_production_material_clearance clearance
                            ON clearance.demand_id = demand.id
                          WHERE demand.execution_segment_id = segment.id
                            AND demand.is_deleted = FALSE
                            AND demand.status NOT IN (
                                'RELEASED', 'REVERSED')
                            AND NOT COALESCE(
                                clearance.can_close, FALSE)
                      )
                  )
                """.formatted(scope.predicate());
        long count = count("SELECT COUNT(*) " + from, scope);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                limitedQuery("""
                        SELECT segment.id, plan.id, plan.bill_no,
                               segment.segment_code,
                               segment.planned_qty,
                               COALESCE(inbound.qty, 0)
                        """ + from + """
                        ORDER BY plan.bill_no, segment.segment_no,
                                 segment.id
                        LIMIT :limit
                        """, scope, limit));
        List<ChainHealthIssue> issues = rows.stream()
                .map(row -> new ChainHealthIssue(
                        str(row[0]), str(row[1]), str(row[2]),
                        str(row[3]),
                        "计划量 " + qty(row[4])
                                + " · 有效入库 " + qty(row[5])
                                + " · 同时检查物料结清",
                        "PRODUCTION_PLAN"))
                .toList();
        return new ChainHealthCategory(
                "COMPLETED_SEGMENT_INVALID",
                "已完成执行段不满足完成条件",
                "COMPLETED 必须足额有效入库且全部物料需求结清。"
                        + "命中表示状态被异常推进或后续反向未完整重开。",
                count,
                issues);
    }

    // ===== 9. FQC 投影、决定和合格入库授权不守恒 =====

    private ChainHealthCategory fqcQuantityMismatch(int limit) {
        var scope = productionAccess.nativeReadScope(
                "report.maker_id", "fqcHealthOwners");
        String from = """
                FROM production_fqc_inspections inspection
                JOIN production_daily_reports report
                  ON report.id = inspection.source_report_id
                 AND report.is_deleted = FALSE
                JOIN production_plan_items plan_item
                  ON plan_item.id = inspection.source_plan_item_id
                 AND plan_item.is_deleted = FALSE
                JOIN production_plans plan
                  ON plan.id = plan_item.plan_id
                 AND plan.is_deleted = FALSE
                LEFT JOIN goods goods
                  ON goods.id = inspection.goods_id
                LEFT JOIN LATERAL (
                    SELECT COALESCE(SUM(decision.pass_qty), 0)
                               AS pass_qty,
                           COALESCE(SUM(decision.fail_qty), 0)
                               AS fail_qty
                    FROM production_fqc_decision_events decision
                    WHERE decision.inspection_id = inspection.id
                ) decisions ON TRUE
                LEFT JOIN LATERAL (
                    SELECT COALESCE(SUM(allocation.qty), 0) AS qty
                    FROM production_fqc_release_allocations allocation
                    WHERE allocation.inspection_id = inspection.id
                ) released ON TRUE
                WHERE %s
                  AND inspection.status <> 'CANCELLED'
                  AND (
                      inspection.passed_qty <>
                          COALESCE(decisions.pass_qty, 0)
                      OR inspection.failed_qty <>
                          COALESCE(decisions.fail_qty, 0)
                      OR inspection.passed_qty <>
                          COALESCE(released.qty, 0)
                      OR inspection.passed_qty
                           + inspection.failed_qty >
                         inspection.reported_qty
                  )
                """.formatted(scope.predicate());
        long count = count("SELECT COUNT(*) " + from, scope);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                limitedQuery("""
                        SELECT inspection.id, plan.id, plan.bill_no,
                               report.bill_no, goods.name,
                               inspection.reported_qty,
                               inspection.passed_qty,
                               inspection.failed_qty,
                               COALESCE(released.qty, 0)
                        """ + from + """
                        ORDER BY report.bill_no, inspection.id
                        LIMIT :limit
                        """, scope, limit));
        List<ChainHealthIssue> issues = rows.stream()
                .map(row -> new ChainHealthIssue(
                        str(row[0]), str(row[1]), str(row[2]),
                        str(row[3]),
                        (row[4] == null ? "" : row[4] + " · ")
                                + "报工 " + qty(row[5])
                                + " / PASS " + qty(row[6])
                                + " / FAIL " + qty(row[7])
                                + " / 入库授权 " + qty(row[8]),
                        "PRODUCTION_PLAN"))
                .toList();
        return new ChainHealthCategory(
                "FQC_QUANTITY_MISMATCH",
                "FQC 决定与合格入库授权不一致",
                "FQC 投影必须等于不可变决定事件合计，且每一份 PASS 数量"
                        + "必须等量分配到待点收 FINISHED_IN；FAIL 永不形成授权。",
                count,
                issues);
    }

    // ===== 10. FQC recovery / legacy cutover conservation =====

    private ChainHealthCategory fqcRecoveryMismatch(int limit) {
        var scope = productionAccess.nativeReadScope(
                "plan.maker_id", "fqcRecoveryHealthOwners");
        String sql = """
                SELECT COUNT(*) FROM (
                    SELECT recovery_auth.id
                    FROM production_fqc_recovery_authorizations recovery_auth
                    JOIN production_fqc_decision_events decision
                      ON decision.id = recovery_auth.source_decision_event_id
                    JOIN production_plan_items plan_item
                      ON plan_item.id = recovery_auth.source_plan_item_id
                    JOIN production_plans plan ON plan.id = plan_item.plan_id
                    LEFT JOIN production_fqc_contribution_adjustments adjustment
                      ON adjustment.decision_event_id = decision.id
                    JOIN v_production_fqc_recovery_balance balance
                      ON balance.authorization_id = recovery_auth.id
                    WHERE %s AND (
                        recovery_auth.authorized_qty <> decision.fail_qty
                        OR adjustment.id IS NULL
                        OR adjustment.adjusted_qty <> decision.fail_qty
                        OR balance.available_qty < 0
                        OR balance.allocated_qty < 0
                        OR balance.allocated_qty > recovery_auth.authorized_qty
                        OR (balance.cancelled AND balance.allocated_qty <> 0))
                    UNION ALL
                    SELECT allocation_event.id
                    FROM production_fqc_recovery_allocation_events allocation_event
                    JOIN production_fqc_recovery_authorizations recovery_auth
                      ON recovery_auth.id = allocation_event.authorization_id
                    JOIN production_plan_items plan_item
                      ON plan_item.id = recovery_auth.source_plan_item_id
                    JOIN production_plans plan ON plan.id = plan_item.plan_id
                    LEFT JOIN production_daily_report_items report_item
                      ON report_item.id = allocation_event.recovery_report_item_id
                    LEFT JOIN production_daily_reports report
                      ON report.id = report_item.report_id
                    WHERE allocation_event.event_type = 'ALLOCATE' AND %s
                      AND (
                        report_item.id IS NULL
                        OR report_item.fqc_recovery_authorization_id
                             IS DISTINCT FROM recovery_auth.id
                        OR report_item.plan_item_id
                             IS DISTINCT FROM recovery_auth.source_plan_item_id
                        OR report_item.execution_segment_id
                             IS DISTINCT FROM recovery_auth.execution_segment_id
                        OR report_item.execution_segment_sales_allocation_id
                             IS DISTINCT FROM recovery_auth.execution_segment_sales_allocation_id
                        OR report_item.qty IS DISTINCT FROM allocation_event.qty
                        OR (
                            NOT EXISTS (
                                SELECT 1
                                FROM production_fqc_recovery_allocation_events release_event
                                WHERE release_event.event_type = 'RELEASE'
                                  AND release_event.source_allocation_event_id = allocation_event.id)
                            AND (report.id IS NULL OR report.status IS DISTINCT FROM 1)))
                    UNION ALL
                    SELECT report_item.id
                    FROM production_daily_report_items report_item
                    JOIN production_daily_reports report
                      ON report.id = report_item.report_id
                     AND report.status = 1 AND report.is_deleted = FALSE
                    JOIN production_plan_items plan_item
                      ON plan_item.id = report_item.plan_item_id
                    JOIN production_plans plan ON plan.id = plan_item.plan_id
                    WHERE report_item.execution_segment_id IS NOT NULL
                      AND report_item.is_deleted = FALSE AND %s
                      AND EXISTS (
                          SELECT 1
                          FROM production_finished_arrival_registration_items
                               arrival_item
                          WHERE arrival_item.source_report_item_id = report_item.id)
                      AND NOT EXISTS (
                          SELECT 1 FROM production_fqc_inspections inspection
                          WHERE inspection.source_report_item_id = report_item.id)
                      AND NOT EXISTS (
                          SELECT 1 FROM production_fqc_legacy_exemptions exemption
                          WHERE exemption.source_report_item_id = report_item.id)
                    UNION ALL
                    SELECT ready.id
                    FROM production_fqc_replenishment_ready_events ready
                    JOIN production_fqc_replenishment_cycles cycle
                      ON cycle.id = ready.cycle_id
                    JOIN production_plan_items plan_item
                      ON plan_item.id = cycle.source_plan_item_id
                    JOIN production_plans plan ON plan.id = plan_item.plan_id
                    JOIN production_fqc_replenishment_draw_links draw_link
                      ON draw_link.cycle_id = cycle.id
                    JOIN stock_documents draw
                      ON draw.id = draw_link.stock_document_id
                    LEFT JOIN production_fqc_replenishment_ready_reversals reversal
                      ON reversal.ready_event_id = ready.id
                    WHERE reversal.id IS NULL AND %s AND (
                        draw.status IS DISTINCT FROM 1
                        OR draw.issue_status IS DISTINCT FROM 2
                        OR EXISTS (
                            SELECT 1 FROM production_material_demands demand
                            WHERE demand.fqc_replenishment_cycle_id = cycle.id
                              AND demand.is_deleted = FALSE
                              AND demand.status IS DISTINCT FROM 'FULFILLED'))
                    UNION ALL
                    SELECT allocation_event.id
                    FROM production_fqc_recovery_allocation_events allocation_event
                    JOIN production_fqc_recovery_authorizations recovery_auth
                      ON recovery_auth.id = allocation_event.authorization_id
                    JOIN production_plan_items plan_item
                      ON plan_item.id = recovery_auth.source_plan_item_id
                    JOIN production_plans plan ON plan.id = plan_item.plan_id
                    WHERE allocation_event.event_type = 'ALLOCATE'
                      AND recovery_auth.disposition_code IN ('SCRAP','REJECT')
                      AND %s
                      AND NOT fn_fqc_replenishment_material_ready(recovery_auth.id)
                ) problem
                """.formatted(
                        scope.predicate(), scope.predicate(), scope.predicate(),
                        scope.predicate(), scope.predicate());
        long count = count(sql, scope);
        return new ChainHealthCategory(
                "FQC_RECOVERY_OR_CUTOVER_MISMATCH",
                "FQC补产或历史切点不守恒",
                "FAIL授权、贡献回退和净分配必须守恒；取消lot净分配须为0，"
                        + "V414后精确报工不得凭缺inspection绕检；SCRAP/REJECT"
                        + "必须有V415已实发且需求FULFILLED的补产物料事实。",
                count,
                List.of());
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

    private long count(
            String sql,
            DocumentAccessPolicy.NativeReadScope scope) {
        Query query = em.createNativeQuery(sql);
        scope.bind(query);
        return ((Number) query.getSingleResult()).longValue();
    }

    private Query limitedQuery(
            String sql,
            DocumentAccessPolicy.NativeReadScope scope,
            int limit) {
        Query query = em.createNativeQuery(sql);
        scope.bind(query);
        query.setParameter("limit", limit);
        return query;
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
