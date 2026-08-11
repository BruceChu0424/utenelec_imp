package com.uten.imp.features.production.report;

import com.uten.imp.common.report.ReportSort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * 物料反查产成品的 CQRS 读侧。
 *
 * <p>当前理论关系、旧生产快照、新履约需求和委外历史证据分别聚合，绝不把
 * 不同语义的数量相加。日期仅过滤历史/履约证据，当前 BOM 始终按查询时现状返回。
 */
@Service
@RequiredArgsConstructor
public class ProductionWhereUsedQueryService {

    private static final Set<String> SOURCE_FILTERS = Set.of(
            "all", "current", "history", "production", "subcontract");

    private final EntityManager em;

    /**
     * 共用查询骨架。递归 CTE 使用 UNION 按 (product_id, valid_path) 状态去重，无固定深度上限，
     * 即使脏数据意外成环也会收敛。
     */
    private static final String WHERE_USED_CTES = """
            WITH RECURSIVE
            direct_bom_edges AS (
                SELECT bi.goods_id AS product_id,
                       bi.qty AS direct_qty,
                       bi.qty > 0 AS valid_path
                FROM goods_bom_items bi
                JOIN goods parent_goods ON parent_goods.id = bi.goods_id
                JOIN goods component_goods ON component_goods.id = bi.component_goods_id
                WHERE bi.is_deleted = FALSE
                  AND bi.component_goods_id = :material
                  AND parent_goods.is_deleted = FALSE
                  AND parent_goods.auto_created = FALSE
                  AND component_goods.is_deleted = FALSE
                  AND component_goods.auto_created = FALSE
            ),
            bom_walk(product_id, valid_path) AS (
                SELECT product_id, valid_path FROM direct_bom_edges
                UNION
                SELECT bi.goods_id, child.valid_path AND bi.qty > 0
                FROM goods_bom_items bi
                JOIN bom_walk child ON child.product_id = bi.component_goods_id
                JOIN goods parent_goods ON parent_goods.id = bi.goods_id
                WHERE bi.is_deleted = FALSE
                  AND parent_goods.is_deleted = FALSE
                  AND parent_goods.auto_created = FALSE
            ),
            current_ancestors(product_id) AS (
                SELECT DISTINCT product_id FROM bom_walk WHERE valid_path
            ),
            invalid_ancestors(product_id) AS (
                SELECT DISTINCT invalid.product_id
                FROM bom_walk invalid
                WHERE NOT invalid.valid_path
                  AND NOT EXISTS (
                      SELECT 1 FROM current_ancestors current
                      WHERE current.product_id = invalid.product_id
                  )
            ),
            direct_bom AS (
                SELECT product_id, direct_qty
                FROM direct_bom_edges
                WHERE valid_path
            ),
            legacy_production AS (
                SELECT c.master_goods_id AS product_id,
                       COUNT(DISTINCT COALESCE(plan.id, c.bill_item_id)) AS evidence_count,
                       COUNT(DISTINCT plan.id)
                           FILTER (WHERE plan.status = 1 AND plan.is_stopped = FALSE AND plan.is_canceled = FALSE) AS plan_count,
                       COUNT(DISTINCT c.bill_item_id)
                           FILTER (WHERE plan.status = 1 AND plan.is_stopped = FALSE AND plan.is_canceled = FALSE) AS line_count,
                       COALESCE(SUM(c.qty)
                           FILTER (WHERE plan.status = 1 AND plan.is_stopped = FALSE AND plan.is_canceled = FALSE), 0) AS required_qty,
                       COALESCE(SUM(c.pdraw_qty)
                           FILTER (WHERE plan.status = 1 AND plan.is_stopped = FALSE AND plan.is_canceled = FALSE), 0) AS issued_qty,
                       COALESCE(SUM(c.owdraw_qty)
                           FILTER (WHERE plan.status = 1 AND plan.is_stopped = FALSE AND plan.is_canceled = FALSE), 0) AS returned_qty,
                       MIN(c.dqty)
                           FILTER (WHERE plan.status = 1 AND plan.is_stopped = FALSE AND plan.is_canceled = FALSE) AS dqty_min,
                       MAX(c.dqty)
                           FILTER (WHERE plan.status = 1 AND plan.is_stopped = FALSE AND plan.is_canceled = FALSE) AS dqty_max,
                       MIN(c.bill_date)
                           FILTER (WHERE plan.status = 1 AND plan.is_stopped = FALSE AND plan.is_canceled = FALSE) AS first_used,
                       MAX(c.bill_date)
                           FILTER (WHERE plan.status = 1 AND plan.is_stopped = FALSE AND plan.is_canceled = FALSE) AS last_used
                FROM production_plan_costs c
                LEFT JOIN production_plan_items pi
                  ON pi.id = c.bill_item_id
                 AND pi.is_deleted = FALSE
                LEFT JOIN production_plans plan
                  ON plan.id = pi.plan_id
                 AND plan.is_deleted = FALSE
                WHERE c.is_deleted = FALSE
                  AND c.goods_id = :material
                  AND c.node_class = 0
                  AND c.master_goods_id IS NOT NULL
                  AND (CAST(:from AS date) IS NULL OR c.bill_date >= CAST(:from AS date))
                  AND (CAST(:to AS date) IS NULL OR c.bill_date <= CAST(:to AS date))
                GROUP BY c.master_goods_id
            ),
            execution_demands AS (
                SELECT segment.product_goods_id AS product_id,
                       COUNT(DISTINCT demand.execution_segment_id) AS evidence_count,
                       COUNT(DISTINCT demand.execution_segment_id)
                           FILTER (WHERE demand.supply_route = 'SUBCONTRACT') AS subcontract_evidence_count,
                       COUNT(DISTINCT demand.execution_segment_id)
                           FILTER (WHERE demand.status NOT IN ('RELEASED', 'REVERSED')
                                AND segment.status NOT IN ('CANCELLED', 'REVERSED')
                                AND plan.status = 1
                                AND plan.is_stopped = FALSE
                                AND plan.is_canceled = FALSE) AS segment_count,
                       COALESCE(SUM(demand.required_qty)
                           FILTER (WHERE demand.status NOT IN ('RELEASED', 'REVERSED')
                                AND segment.status NOT IN ('CANCELLED', 'REVERSED')
                                AND plan.status = 1
                                AND plan.is_stopped = FALSE
                                AND plan.is_canceled = FALSE), 0) AS required_qty,
                       MIN(demand.per_product_qty)
                           FILTER (WHERE demand.status NOT IN ('RELEASED', 'REVERSED')
                                AND segment.status NOT IN ('CANCELLED', 'REVERSED')
                                AND plan.status = 1
                                AND plan.is_stopped = FALSE
                                AND plan.is_canceled = FALSE) AS per_product_min,
                       MAX(demand.per_product_qty)
                           FILTER (WHERE demand.status NOT IN ('RELEASED', 'REVERSED')
                                AND segment.status NOT IN ('CANCELLED', 'REVERSED')
                                AND plan.status = 1
                                AND plan.is_stopped = FALSE
                                AND plan.is_canceled = FALSE) AS per_product_max,
                       COUNT(DISTINCT demand.execution_segment_id)
                           FILTER (WHERE demand.supply_route = 'SUBCONTRACT'
                                AND demand.status NOT IN ('RELEASED', 'REVERSED')
                                AND segment.status NOT IN ('CANCELLED', 'REVERSED')
                                AND plan.status = 1
                                AND plan.is_stopped = FALSE
                                AND plan.is_canceled = FALSE) AS subcontract_segments,
                       COALESCE(SUM(demand.required_qty)
                           FILTER (WHERE demand.supply_route = 'SUBCONTRACT'
                                AND demand.status NOT IN ('RELEASED', 'REVERSED')
                                AND segment.status NOT IN ('CANCELLED', 'REVERSED')
                                AND plan.status = 1
                                AND plan.is_stopped = FALSE
                                AND plan.is_canceled = FALSE), 0) AS subcontract_required_qty,
                       MIN(COALESCE(demand.need_date, segment.plan_begin_date, plan.bill_date))
                           FILTER (WHERE demand.status NOT IN ('RELEASED', 'REVERSED')
                                AND segment.status NOT IN ('CANCELLED', 'REVERSED')
                                AND plan.status = 1
                                AND plan.is_stopped = FALSE
                                AND plan.is_canceled = FALSE) AS first_used,
                       MAX(COALESCE(demand.need_date, segment.plan_begin_date, plan.bill_date))
                           FILTER (WHERE demand.status NOT IN ('RELEASED', 'REVERSED')
                                AND segment.status NOT IN ('CANCELLED', 'REVERSED')
                                AND plan.status = 1
                                AND plan.is_stopped = FALSE
                                AND plan.is_canceled = FALSE) AS last_used
                FROM production_material_demands demand
                JOIN production_execution_segments segment
                  ON segment.id = demand.execution_segment_id
                 AND segment.is_deleted = FALSE
                JOIN production_plans plan
                  ON plan.id = demand.plan_id
                 AND plan.is_deleted = FALSE
                WHERE demand.is_deleted = FALSE
                  AND demand.execution_segment_id IS NOT NULL
                  AND demand.goods_id = :material
                  AND (CAST(:from AS date) IS NULL
                       OR COALESCE(demand.need_date, segment.plan_begin_date, plan.bill_date)
                          >= CAST(:from AS date))
                  AND (CAST(:to AS date) IS NULL
                       OR COALESCE(demand.need_date, segment.plan_begin_date, plan.bill_date)
                          <= CAST(:to AS date))
                GROUP BY segment.product_goods_id
            ),
            subcontract_planned AS (
                SELECT order_item.goods_id AS product_id,
                       COUNT(DISTINCT cost.order_id) AS evidence_count,
                       COUNT(DISTINCT cost.order_id)
                           FILTER (WHERE orders.status = 1) AS order_count,
                       COUNT(DISTINCT cost.order_item_id)
                           FILTER (WHERE orders.status = 1) AS line_count,
                       MIN(cost.unit_qty) FILTER (WHERE orders.status = 1) AS unit_qty_min,
                       MAX(cost.unit_qty) FILTER (WHERE orders.status = 1) AS unit_qty_max,
                       COALESCE(SUM(cost.qty) FILTER (WHERE orders.status = 1), 0) AS required_qty,
                       MIN(cost.bill_date) FILTER (WHERE orders.status = 1) AS first_used,
                       MAX(cost.bill_date) FILTER (WHERE orders.status = 1) AS last_used
                FROM subcontract_order_cost_items cost
                JOIN subcontract_order_items order_item
                  ON order_item.id = cost.order_item_id
                 AND order_item.is_deleted = FALSE
                 AND order_item.order_id = cost.order_id
                JOIN subcontract_orders orders
                  ON orders.id = cost.order_id
                 AND orders.is_deleted = FALSE
                WHERE cost.is_deleted = FALSE
                  AND cost.goods_id = :material
                  AND (CAST(:from AS date) IS NULL OR cost.bill_date >= CAST(:from AS date))
                  AND (CAST(:to AS date) IS NULL OR cost.bill_date <= CAST(:to AS date))
                GROUP BY order_item.goods_id
            ),
            subcontract_issued AS (
                SELECT COALESCE(order_item.goods_id, issue_item.parent_goods_id) AS product_id,
                       COUNT(DISTINCT issue_item.issue_id) AS evidence_count,
                       COUNT(DISTINCT issue_item.issue_id)
                           FILTER (WHERE issue.status = 1) AS issue_count,
                       COALESCE(SUM(issue_item.qty)
                           FILTER (WHERE issue.status = 1), 0) AS issued_qty,
                       COALESCE(SUM(issue_item.returned_qty)
                           FILTER (WHERE issue.status = 1), 0) AS returned_qty,
                       COALESCE(SUM(issue_item.wasted_qty)
                           FILTER (WHERE issue.status = 1), 0) AS wasted_qty,
                       MIN(issue_item.bill_date)
                           FILTER (WHERE issue.status = 1) AS first_used,
                       MAX(issue_item.bill_date)
                           FILTER (WHERE issue.status = 1) AS last_used
                FROM subcontract_material_issue_items issue_item
                JOIN subcontract_material_issues issue
                  ON issue.id = issue_item.issue_id
                 AND issue.is_deleted = FALSE
                LEFT JOIN subcontract_order_items order_item
                  ON order_item.id = issue_item.order_item_id
                WHERE issue_item.is_deleted = FALSE
                  AND issue_item.goods_id = :material
                  AND COALESCE(order_item.goods_id, issue_item.parent_goods_id) IS NOT NULL
                  AND (CAST(:from AS date) IS NULL
                       OR issue_item.bill_date >= CAST(:from AS date))
                  AND (CAST(:to AS date) IS NULL
                       OR issue_item.bill_date <= CAST(:to AS date))
                GROUP BY COALESCE(order_item.goods_id, issue_item.parent_goods_id)
            ),
            product_ids AS (
                SELECT product_id FROM current_ancestors
                UNION SELECT product_id FROM invalid_ancestors
                UNION SELECT product_id FROM legacy_production
                UNION SELECT product_id FROM execution_demands
                UNION SELECT product_id FROM subcontract_planned
                UNION SELECT product_id FROM subcontract_issued
            ),
            combined AS (
                SELECT goods.id AS product_id,
                       goods.code AS goods_code,
                       goods.name AS goods_name,
                       goods.spec AS spec,
                       category.name AS category_name,
                       goods.status AS goods_status,
                       goods.auto_created AS auto_created,
                       goods.is_deleted AS goods_deleted,
                       ancestor.product_id IS NOT NULL AS current_bom,
                       invalid.product_id IS NOT NULL AS invalid_bom,
                       direct.product_id IS NOT NULL AS current_direct,
                       direct.direct_qty AS current_direct_qty,
                       COALESCE(legacy.plan_count, 0) AS legacy_plan_count,
                       COALESCE(legacy.evidence_count, 0) AS legacy_evidence_count,
                       COALESCE(legacy.line_count, 0) AS legacy_line_count,
                       legacy.required_qty AS legacy_required_qty,
                       legacy.issued_qty AS legacy_issued_qty,
                       legacy.returned_qty AS legacy_returned_qty,
                       legacy.dqty_min AS legacy_dqty_min,
                       legacy.dqty_max AS legacy_dqty_max,
                       legacy.first_used AS legacy_first_used,
                       legacy.last_used AS legacy_last_used,
                       COALESCE(execution.segment_count, 0) AS execution_segment_count,
                       COALESCE(execution.evidence_count, 0) AS execution_evidence_count,
                       COALESCE(execution.subcontract_evidence_count, 0) AS execution_subcontract_evidence_count,
                       execution.required_qty AS execution_required_qty,
                       execution.per_product_min AS execution_per_product_min,
                       execution.per_product_max AS execution_per_product_max,
                       COALESCE(execution.subcontract_segments, 0) AS execution_subcontract_segments,
                       execution.subcontract_required_qty AS execution_subcontract_required_qty,
                       execution.first_used AS execution_first_used,
                       execution.last_used AS execution_last_used,
                       COALESCE(planned.order_count, 0) AS subcontract_order_count,
                       COALESCE(planned.evidence_count, 0) AS subcontract_order_evidence_count,
                       COALESCE(planned.line_count, 0) AS subcontract_order_line_count,
                       planned.unit_qty_min AS subcontract_unit_qty_min,
                       planned.unit_qty_max AS subcontract_unit_qty_max,
                       planned.required_qty AS subcontract_required_qty,
                       planned.first_used AS subcontract_planned_first_used,
                       planned.last_used AS subcontract_planned_last_used,
                       COALESCE(issued.issue_count, 0) AS subcontract_issue_count,
                       COALESCE(issued.evidence_count, 0) AS subcontract_issue_evidence_count,
                       issued.issued_qty AS subcontract_issue_qty,
                       issued.returned_qty AS subcontract_returned_qty,
                       issued.wasted_qty AS subcontract_wasted_qty,
                       issued.first_used AS subcontract_issue_first_used,
                       issued.last_used AS subcontract_issue_last_used,
                       CONCAT_WS(' · ',
                           CASE WHEN ancestor.product_id IS NOT NULL THEN '当前BOM' END,
                           CASE WHEN invalid.product_id IS NOT NULL THEN 'BOM异常待治理' END,
                           CASE
                               WHEN execution.segment_count > 0 THEN '新生产需求'
                               WHEN execution.product_id IS NOT NULL THEN '非有效生产需求痕迹'
                           END,
                           CASE
                               WHEN legacy.plan_count > 0 THEN '旧生产快照'
                               WHEN legacy.product_id IS NOT NULL THEN '未审核/红冲/中止/取消生产痕迹'
                           END,
                           CASE
                               WHEN planned.order_count > 0 THEN '委外成本快照'
                               WHEN planned.product_id IS NOT NULL THEN '未审核/红冲委外成本痕迹'
                           END,
                           CASE
                               WHEN issued.issue_count > 0 THEN '委外发料痕迹'
                               WHEN issued.product_id IS NOT NULL THEN '未审核/红冲委外发料痕迹'
                           END
                       ) AS sources,
                       CASE
                           WHEN direct.product_id IS NOT NULL THEN '直接使用'
                           WHEN ancestor.product_id IS NOT NULL THEN '间接使用'
                            WHEN invalid.product_id IS NOT NULL THEN '非正用量异常'
                           ELSE NULL
                       END AS bom_relation,
                       GREATEST(legacy.last_used, execution.last_used,
                                planned.last_used, issued.last_used) AS last_used
                FROM product_ids ids
                JOIN goods ON goods.id = ids.product_id
                LEFT JOIN material_categories category ON category.id = goods.category_id
                LEFT JOIN current_ancestors ancestor ON ancestor.product_id = goods.id
                LEFT JOIN invalid_ancestors invalid ON invalid.product_id = goods.id
                LEFT JOIN direct_bom direct ON direct.product_id = goods.id
                LEFT JOIN legacy_production legacy ON legacy.product_id = goods.id
                LEFT JOIN execution_demands execution ON execution.product_id = goods.id
                LEFT JOIN subcontract_planned planned ON planned.product_id = goods.id
                LEFT JOIN subcontract_issued issued ON issued.product_id = goods.id
                WHERE goods.id <> :material
            )
            """;

    @Transactional(readOnly = true)
    public ReportTableResponse whereUsed(UUID materialGoodsId, String source,
                                         LocalDate dateFrom, LocalDate dateTo,
                                         int page, int size, String sort, String order) {
        String normalizedSource = normalizeSource(source);
        if (dateFrom != null && dateTo != null && dateFrom.isAfter(dateTo)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "起始日期不能晚于结束日期");
        }

        List<ReportColumn> columns = columns();
        List<ReportColumn> visible = columns.stream()
                .filter(column -> !column.key().startsWith("__"))
                .toList();
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 200);
        Map<String, Object> meta = materialGoodsId == null
                ? emptyMeta(normalizedSource, dateFrom, dateTo)
                : unattributedDemandMeta(materialGoodsId, normalizedSource, dateFrom, dateTo);
        if (materialGoodsId == null) {
            return new ReportTableResponse(visible, List.of(), Map.of(),
                    safePage, safeSize, 0L, 0, meta);
        }

        Set<String> sortKeys = new LinkedHashSet<>();
        visible.forEach(column -> sortKeys.add(column.key()));
        String effectiveOrder = ReportSort.resolveOrderBy(
                sort, order,
                "\"__currentBom\" DESC, \"lastUsed\" DESC NULLS LAST, \"goodsCode\" ASC",
                sortKeys);
        String predicate = sourcePredicate(normalizedSource);
        String sql = WHERE_USED_CTES + """
                SELECT row.product_id AS "__productId",
                       row.current_bom AS "__currentBom",
                       row.invalid_bom AS "__invalidBom",
                       row.current_direct AS "__currentDirect",
                       row.current_direct_qty AS "__currentDirectQty",
                       row.legacy_line_count AS "__legacyProductionLineCount",
                       row.legacy_evidence_count AS "__legacyEvidenceCount",
                       row.legacy_dqty_min AS "__legacyDqtyMin",
                       row.legacy_dqty_max AS "__legacyDqtyMax",
                       row.legacy_issued_qty AS "__legacyIssuedQty",
                       row.legacy_returned_qty AS "__legacyReturnedQty",
                       row.legacy_first_used AS "__legacyFirstUsed",
                       row.legacy_last_used AS "__legacyLastUsed",
                       row.execution_required_qty AS "__executionRequiredQty",
                       row.execution_evidence_count AS "__executionEvidenceCount",
                       row.execution_subcontract_evidence_count AS "__executionSubcontractEvidenceCount",
                       row.execution_per_product_min AS "__executionPerProductMin",
                       row.execution_per_product_max AS "__executionPerProductMax",
                       row.execution_subcontract_segments AS "__executionSubcontractSegments",
                       row.execution_subcontract_required_qty AS "__executionSubcontractRequiredQty",
                       row.execution_first_used AS "__executionFirstUsed",
                       row.execution_last_used AS "__executionLastUsed",
                       row.subcontract_order_line_count AS "__subcontractOrderLineCount",
                       row.subcontract_order_evidence_count AS "__subcontractOrderEvidenceCount",
                       row.subcontract_unit_qty_min AS "__subcontractUnitQtyMin",
                       row.subcontract_unit_qty_max AS "__subcontractUnitQtyMax",
                       row.subcontract_required_qty AS "__subcontractRequiredQty",
                       row.subcontract_issue_qty AS "__subcontractIssueQty",
                       row.subcontract_issue_evidence_count AS "__subcontractIssueEvidenceCount",
                       row.subcontract_returned_qty AS "__subcontractReturnedQty",
                       row.subcontract_wasted_qty AS "__subcontractWastedQty",
                       LEAST(row.subcontract_planned_first_used,
                             row.subcontract_issue_first_used) AS "__subcontractFirstUsed",
                       GREATEST(row.subcontract_planned_last_used,
                                row.subcontract_issue_last_used) AS "__subcontractLastUsed",
                       row.goods_status AS "__goodsStatus",
                       row.auto_created AS "__autoCreated",
                       row.goods_deleted AS "__goodsDeleted",
                       row.goods_code AS "goodsCode",
                       row.goods_name AS "goodsName",
                       row.spec AS "spec",
                       row.category_name AS "categoryName",
                       row.sources AS "sources",
                       row.bom_relation AS "bomRelation",
                       row.execution_segment_count AS "executionSegmentCount",
                       row.legacy_plan_count AS "legacyPlanCount",
                       row.legacy_required_qty AS "legacyRequiredQty",
                       row.subcontract_order_count AS "subcontractOrderCount",
                       row.subcontract_issue_count AS "subcontractIssueCount",
                       row.last_used AS "lastUsed",
                       COUNT(*) OVER() AS "__total"
                FROM combined row
                """ + " WHERE " + predicate
                + " ORDER BY " + effectiveOrder + ", \"__productId\" ASC"
                + " LIMIT :__limit OFFSET :__offset";

        Query query = em.createNativeQuery(sql);
        bindWhereUsed(query, materialGoodsId, dateFrom, dateTo);
        query.setParameter("__limit", safeSize);
        query.setParameter("__offset", (long) (safePage - 1) * safeSize);
        @SuppressWarnings("unchecked")
        List<Object[]> rawRows = query.getResultList();

        List<Map<String, Object>> rows = new ArrayList<>(rawRows.size());
        for (Object[] raw : rawRows) {
            Map<String, Object> mapped = new LinkedHashMap<>();
            for (int index = 0; index < columns.size(); index++) {
                mapped.put(columns.get(index).key(), normalize(raw[index]));
            }
            mapped.put("__srcId", mapped.get("__productId")); // 兼容旧客户端；语义同产成品货品 UUID
            rows.add(mapped);
        }

        long total = rawRows.isEmpty()
                ? (safePage == 1 ? 0L : countRows(materialGoodsId, dateFrom, dateTo, predicate))
                : ((Number) rawRows.get(0)[columns.size()]).longValue();
        int totalPages = (int) ((total + safeSize - 1) / safeSize);
        return new ReportTableResponse(visible, rows, Map.of(), safePage, safeSize,
                total, totalPages, meta);
    }

    /**
     * 报表自己的材料搜索。覆盖全部匹配货品并标注当前/历史关系，避免依赖 goods:view；
     * 无已知关系的货品也可选择后确认空结果。空关键字不触发全库/大历史表扫描。
     */
    @Transactional(readOnly = true)
    public PageResponse<WhereUsedMaterialOption> searchWhereUsedMaterials(
            String keyword, int page, int size) {
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 50);
        String normalizedKeyword = keyword == null ? "" : keyword.trim();
        if (normalizedKeyword.isEmpty()) {
            return new PageResponse<>(List.of(), safePage, safeSize, 0L, 0);
        }

        String sql = """
                WITH matched_goods AS MATERIALIZED (
                    SELECT goods.id, goods.code, goods.name, goods.model, goods.spec,
                           goods.status, goods.source_type, goods.auto_created, goods.is_deleted,
                           category.name AS category_name,
                           CASE
                               WHEN LOWER(COALESCE(goods.code, '')) = :exact THEN 0
                               WHEN LOWER(COALESCE(goods.name, '')) = :exact THEN 1
                               WHEN LOWER(COALESCE(goods.code, '')) LIKE :prefix ESCAPE '\\' THEN 2
                               WHEN LOWER(COALESCE(goods.name, '')) LIKE :prefix ESCAPE '\\' THEN 3
                               ELSE 4
                           END AS match_rank,
                           COUNT(*) OVER() AS total_count
                    FROM goods
                    LEFT JOIN material_categories category ON category.id = goods.category_id
                    WHERE LOWER(
                        COALESCE(goods.code, '') || ' ' ||
                        COALESCE(goods.name, '') || ' ' ||
                        COALESCE(goods.model, '') || ' ' ||
                        COALESCE(goods.spec, '') || ' ' ||
                        COALESCE(goods.series, '') || ' ' ||
                        COALESCE(goods.c_number, '') || ' ' ||
                        COALESCE(goods.material, '') || ' ' ||
                        COALESCE(goods.require_remark, '')
                    ) LIKE :pattern ESCAPE '\\'
                    ORDER BY match_rank,
                             goods.is_deleted ASC,
                             goods.auto_created ASC,
                             goods.code ASC NULLS LAST,
                             goods.name ASC NULLS LAST,
                             goods.id ASC
                    LIMIT :__limit OFFSET :__offset
                )
                SELECT goods.id, goods.code, goods.name, goods.model, goods.spec, goods.status,
                       goods.source_type, goods.category_name,
                       goods.auto_created, goods.is_deleted,
                       source.current_bom, source.bom_issue, source.production_history,
                       source.subcontract_history,
                       goods.total_count
                FROM matched_goods goods
                CROSS JOIN LATERAL (
                    SELECT
                        EXISTS (
                            SELECT 1
                            FROM goods_bom_items bom
                            JOIN goods parent_goods ON parent_goods.id = bom.goods_id
                            WHERE bom.component_goods_id = goods.id
                              AND bom.is_deleted = FALSE
                              AND bom.qty > 0
                              AND bom.goods_id <> goods.id
                              AND goods.is_deleted = FALSE
                              AND goods.auto_created = FALSE
                              AND parent_goods.is_deleted = FALSE
                              AND parent_goods.auto_created = FALSE
                        ) AS current_bom,
                        EXISTS (
                            SELECT 1
                            FROM goods_bom_items bom
                            JOIN goods parent_goods ON parent_goods.id = bom.goods_id
                            WHERE bom.component_goods_id = goods.id
                              AND bom.is_deleted = FALSE
                              AND (bom.qty <= 0 OR bom.goods_id = goods.id)
                              AND goods.is_deleted = FALSE
                              AND goods.auto_created = FALSE
                              AND parent_goods.is_deleted = FALSE
                              AND parent_goods.auto_created = FALSE
                        ) AS bom_issue,
                        (
                            EXISTS (
                                SELECT 1 FROM production_plan_costs legacy
                                WHERE legacy.goods_id = goods.id
                                  AND legacy.is_deleted = FALSE
                                  AND legacy.node_class = 0
                                  AND legacy.master_goods_id IS NOT NULL
                                  AND legacy.master_goods_id <> goods.id
                            )
                            OR EXISTS (
                                SELECT 1
                                FROM production_material_demands demand
                                JOIN production_plans plan
                                  ON plan.id = demand.plan_id
                                 AND plan.is_deleted = FALSE
                                LEFT JOIN production_execution_segments segment
                                  ON segment.id = demand.execution_segment_id
                                 AND segment.is_deleted = FALSE
                                WHERE demand.goods_id = goods.id
                                  AND demand.is_deleted = FALSE
                                  AND (
                                      (demand.execution_segment_id IS NOT NULL
                                          AND segment.id IS NOT NULL
                                          AND segment.product_goods_id <> goods.id)
                                      OR (demand.execution_segment_id IS NULL
                                          AND demand.status NOT IN ('RELEASED', 'REVERSED')
                                          AND plan.status = 1
                                          AND plan.is_stopped = FALSE
                                          AND plan.is_canceled = FALSE)
                                  )
                            )
                        ) AS production_history,
                        (
                            EXISTS (
                                SELECT 1
                                FROM subcontract_order_cost_items planned
                                JOIN subcontract_order_items order_item
                                  ON order_item.id = planned.order_item_id
                                 AND order_item.order_id = planned.order_id
                                 AND order_item.is_deleted = FALSE
                                JOIN subcontract_orders orders
                                  ON orders.id = planned.order_id
                                 AND orders.is_deleted = FALSE
                                WHERE planned.goods_id = goods.id
                                  AND planned.is_deleted = FALSE
                                  AND order_item.goods_id <> goods.id
                            )
                            OR EXISTS (
                                SELECT 1
                                FROM subcontract_material_issue_items issued
                                JOIN subcontract_material_issues issue
                                  ON issue.id = issued.issue_id
                                 AND issue.is_deleted = FALSE
                                LEFT JOIN subcontract_order_items order_item
                                  ON order_item.id = issued.order_item_id
                                WHERE issued.goods_id = goods.id
                                  AND issued.is_deleted = FALSE
                                  AND COALESCE(order_item.goods_id, issued.parent_goods_id) IS NOT NULL
                                  AND COALESCE(order_item.goods_id, issued.parent_goods_id) <> goods.id
                            )
                            OR EXISTS (
                                SELECT 1
                                FROM production_material_demands demand
                                JOIN production_plans plan
                                  ON plan.id = demand.plan_id
                                 AND plan.is_deleted = FALSE
                                LEFT JOIN production_execution_segments segment
                                  ON segment.id = demand.execution_segment_id
                                 AND segment.is_deleted = FALSE
                                WHERE demand.goods_id = goods.id
                                  AND demand.is_deleted = FALSE
                                  AND demand.supply_route = 'SUBCONTRACT'
                                  AND (
                                      (demand.execution_segment_id IS NOT NULL
                                          AND segment.id IS NOT NULL
                                          AND segment.product_goods_id <> goods.id)
                                      OR (demand.execution_segment_id IS NULL
                                          AND demand.status NOT IN ('RELEASED', 'REVERSED')
                                          AND plan.status = 1
                                          AND plan.is_stopped = FALSE
                                          AND plan.is_canceled = FALSE)
                                  )
                            )
                        ) AS subcontract_history
                ) source
                ORDER BY goods.match_rank,
                    goods.is_deleted ASC,
                    goods.auto_created ASC,
                    goods.code ASC NULLS LAST,
                    goods.name ASC NULLS LAST,
                    goods.id ASC
                """;
        Query query = em.createNativeQuery(sql);
        String normalizedSearch = normalizedKeyword.toLowerCase(Locale.ROOT);
        String escapedSearch = escapeLike(normalizedSearch);
        query.setParameter("pattern", "%" + escapedSearch + "%");
        query.setParameter("prefix", escapedSearch + "%");
        query.setParameter("exact", normalizedSearch);
        query.setParameter("__limit", safeSize);
        query.setParameter("__offset", (long) (safePage - 1) * safeSize);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = query.getResultList();

        List<WhereUsedMaterialOption> items = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            items.add(new WhereUsedMaterialOption(
                    (UUID) row[0], text(row[1]), text(row[2]), text(row[3]),
                    text(row[4]), text(row[5]), text(row[6]), text(row[7]),
                    truth(row[8]), truth(row[9]), truth(row[10]), truth(row[11]),
                    truth(row[12]), truth(row[13])));
        }
        long total = rows.isEmpty()
                ? (safePage == 1 ? 0L : countWhereUsedMaterials(escapedSearch))
                : ((Number) rows.get(0)[14]).longValue();
        int totalPages = (int) ((total + safeSize - 1) / safeSize);
        return new PageResponse<>(items, safePage, safeSize, total, totalPages);
    }

    private long countWhereUsedMaterials(String escapedSearch) {
        Query query = em.createNativeQuery("""
                SELECT COUNT(*)
                FROM goods
                WHERE LOWER(
                    COALESCE(code, '') || ' ' ||
                    COALESCE(name, '') || ' ' ||
                    COALESCE(model, '') || ' ' ||
                    COALESCE(spec, '') || ' ' ||
                    COALESCE(series, '') || ' ' ||
                    COALESCE(c_number, '') || ' ' ||
                    COALESCE(material, '') || ' ' ||
                    COALESCE(require_remark, '')
                ) LIKE :pattern ESCAPE '\\'
                """);
        query.setParameter("pattern", "%" + escapedSearch + "%");
        return ((Number) query.getSingleResult()).longValue();
    }

    private static String escapeLike(String value) {
        return value.replace("\\", "\\\\")
                .replace("%", "\\%")
                .replace("_", "\\_");
    }

    private long countRows(UUID materialGoodsId, LocalDate dateFrom, LocalDate dateTo,
                           String predicate) {
        Query query = em.createNativeQuery(
                WHERE_USED_CTES + "SELECT COUNT(*) FROM combined row WHERE " + predicate);
        bindWhereUsed(query, materialGoodsId, dateFrom, dateTo);
        return ((Number) query.getSingleResult()).longValue();
    }

    private Map<String, Object> unattributedDemandMeta(
            UUID materialGoodsId, String source, LocalDate dateFrom, LocalDate dateTo) {
        Map<String, Object> meta = emptyMeta(source, dateFrom, dateTo);
        if ("current".equals(source)) return meta;

        String routeClause = "subcontract".equals(source)
                ? " AND demand.supply_route = 'SUBCONTRACT'"
                : "";
        Query query = em.createNativeQuery("""
                SELECT COUNT(*), COALESCE(SUM(demand.required_qty), 0)
                FROM production_material_demands demand
                JOIN production_plans plan
                  ON plan.id = demand.plan_id
                 AND plan.is_deleted = FALSE
                WHERE demand.goods_id = :material
                  AND demand.is_deleted = FALSE
                  AND demand.status NOT IN ('RELEASED', 'REVERSED')
                  AND demand.execution_segment_id IS NULL
                  AND plan.status = 1
                  AND plan.is_stopped = FALSE
                  AND plan.is_canceled = FALSE
                  AND (CAST(:from AS date) IS NULL
                       OR COALESCE(demand.need_date, plan.bill_date) >= CAST(:from AS date))
                  AND (CAST(:to AS date) IS NULL
                       OR COALESCE(demand.need_date, plan.bill_date) <= CAST(:to AS date))
                """ + routeClause);
        bindWhereUsed(query, materialGoodsId, dateFrom, dateTo);
        Object[] row = (Object[]) query.getSingleResult();
        meta.put("unattributedDemandCount", ((Number) row[0]).longValue());
        meta.put("unattributedDemandQty", normalize(row[1]));
        return meta;
    }

    private static Map<String, Object> emptyMeta(
            String source, LocalDate dateFrom, LocalDate dateTo) {
        Map<String, Object> meta = new LinkedHashMap<>();
        meta.put("source", source);
        meta.put("historyDateFiltered", dateFrom != null || dateTo != null);
        meta.put("unattributedDemandCount", 0L);
        meta.put("unattributedDemandQty", BigDecimal.ZERO);
        return meta;
    }

    private static void bindWhereUsed(
            Query query, UUID materialGoodsId, LocalDate dateFrom, LocalDate dateTo) {
        query.setParameter("material", materialGoodsId);
        query.setParameter("from", dateFrom);
        query.setParameter("to", dateTo);
    }

    private static String normalizeSource(String source) {
        String normalized = source == null ? "all" : source.trim().toLowerCase(Locale.ROOT);
        if (!SOURCE_FILTERS.contains(normalized)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "source 仅支持 all/current/history/production/subcontract");
        }
        return normalized;
    }

    private static String sourcePredicate(String source) {
        return switch (source) {
            case "current" -> "row.current_bom";
            case "history" -> "(row.legacy_evidence_count > 0 OR row.execution_evidence_count > 0 "
                    + "OR row.subcontract_order_evidence_count > 0 OR row.subcontract_issue_evidence_count > 0)";
            case "production" -> "(row.legacy_evidence_count > 0 OR row.execution_evidence_count > 0)";
            case "subcontract" -> "(row.execution_subcontract_evidence_count > 0 "
                    + "OR row.subcontract_order_evidence_count > 0 "
                    + "OR row.subcontract_issue_evidence_count > 0)";
            default -> "TRUE";
        };
    }

    private static List<ReportColumn> columns() {
        return List.of(
                ReportColumn.text("__productId", ""),
                ReportColumn.bool("__currentBom", ""),
                ReportColumn.bool("__invalidBom", ""),
                ReportColumn.bool("__currentDirect", ""),
                ReportColumn.number("__currentDirectQty", ""),
                ReportColumn.number("__legacyProductionLineCount", ""),
                ReportColumn.number("__legacyEvidenceCount", ""),
                ReportColumn.number("__legacyDqtyMin", ""),
                ReportColumn.number("__legacyDqtyMax", ""),
                ReportColumn.number("__legacyIssuedQty", ""),
                ReportColumn.number("__legacyReturnedQty", ""),
                ReportColumn.date("__legacyFirstUsed", ""),
                ReportColumn.date("__legacyLastUsed", ""),
                ReportColumn.number("__executionRequiredQty", ""),
                ReportColumn.number("__executionEvidenceCount", ""),
                ReportColumn.number("__executionSubcontractEvidenceCount", ""),
                ReportColumn.number("__executionPerProductMin", ""),
                ReportColumn.number("__executionPerProductMax", ""),
                ReportColumn.number("__executionSubcontractSegments", ""),
                ReportColumn.number("__executionSubcontractRequiredQty", ""),
                ReportColumn.date("__executionFirstUsed", ""),
                ReportColumn.date("__executionLastUsed", ""),
                ReportColumn.number("__subcontractOrderLineCount", ""),
                ReportColumn.number("__subcontractOrderEvidenceCount", ""),
                ReportColumn.number("__subcontractUnitQtyMin", ""),
                ReportColumn.number("__subcontractUnitQtyMax", ""),
                ReportColumn.number("__subcontractRequiredQty", ""),
                ReportColumn.number("__subcontractIssueQty", ""),
                ReportColumn.number("__subcontractIssueEvidenceCount", ""),
                ReportColumn.number("__subcontractReturnedQty", ""),
                ReportColumn.number("__subcontractWastedQty", ""),
                ReportColumn.date("__subcontractFirstUsed", ""),
                ReportColumn.date("__subcontractLastUsed", ""),
                ReportColumn.text("__goodsStatus", ""),
                ReportColumn.bool("__autoCreated", ""),
                ReportColumn.bool("__goodsDeleted", ""),
                ReportColumn.text("goodsCode", "产成品编号", 130),
                ReportColumn.text("goodsName", "产成品名称", 200),
                ReportColumn.text("spec", "规格", 130),
                ReportColumn.text("categoryName", "分类", 110),
                ReportColumn.text("sources", "关系来源", 230),
                ReportColumn.text("bomRelation", "当前BOM", 105),
                ReportColumn.number("executionSegmentCount", "新生产段"),
                ReportColumn.number("legacyPlanCount", "旧生产计划"),
                ReportColumn.number("legacyRequiredQty", "旧展开需求量"),
                ReportColumn.number("subcontractOrderCount", "委外订货"),
                ReportColumn.number("subcontractIssueCount", "委外发料单"),
                ReportColumn.date("lastUsed", "最近历史使用"));
    }

    private static Object normalize(Object value) {
        if (value == null) return null;
        if (value instanceof java.sql.Date date) return date.toLocalDate().toString();
        if (value instanceof java.sql.Timestamp timestamp) {
            return timestamp.toLocalDateTime().toLocalDate().toString();
        }
        if (value instanceof BigDecimal || value instanceof Boolean || value instanceof Number) {
            return value;
        }
        if (value instanceof UUID uuid) return uuid.toString();
        return value.toString();
    }

    private static String text(Object value) {
        return value == null ? null : Objects.toString(value);
    }

    private static boolean truth(Object value) {
        return Boolean.TRUE.equals(value);
    }
}
