package com.uten.imp.features.production.mrp;

import com.uten.imp.application.port.OrganizationReferencePort;

import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.plan.ProductionPlan;
import com.uten.imp.features.production.plan.ProductionPlanItem;
import com.uten.imp.features.production.plan.ProductionPlanItemRepository;
import com.uten.imp.features.production.plan.ProductionPlanRepository;
import com.uten.imp.features.production.plan.ProductionProductNoAllocator;
import com.uten.imp.features.purchase.PurchaseGoodsSnapshot;
import com.uten.imp.features.purchase.request.PurchaseRequest;
import com.uten.imp.features.purchase.request.PurchaseRequestItem;
import com.uten.imp.features.purchase.request.PurchaseRequestItemRepository;
import com.uten.imp.features.purchase.request.PurchaseRequestRepository;
import com.uten.imp.features.stock.FinishedInboundAllocator;
import com.uten.imp.features.stock.StockDocument;
import com.uten.imp.features.stock.StockDocumentItem;
import com.uten.imp.features.stock.StockDocumentItemRepository;
import com.uten.imp.features.stock.StockDocumentRepository;
import com.uten.imp.features.stock.StockGoodsSnapshot;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * MRP-lite：生产计划 → BOM 展开物料需求 → 一键生成采购申请（业务联动核心）。
 *
 * <p>齐套口径：
 * <ol>
 *   <li>毛需求：计划明细排产量 × BOM 递归展开（goods_bom_items，≤10 层、路径防环），
 *       按货品 + BOM 行颜色（空时回落组件主颜色）聚合。</li>
 *   <li>当前可用 = 全仓账面库存 − 生效销售预留 − 货品安全库存，最小为 0。
 *       安全库存当前仅有货品级字段，对每个颜色分别应用是保守口径。</li>
 *   <li>全部在途与需求日前可到在途分开计算；日期为空的采购行不计入及时在途。
 *       所有库存、预留、在途和 MRP 数量均换算为基本单位。</li>
 *   <li>半成品（本身有 BOM 的组件）标记「自制」，只做预览不进采购申请。</li>
 *   <li>生成：一张采购申请（草稿，单号走 CS 序列），明细挂 production_plan_no 溯源；
 *       mrp_generations 记录联动，防重复生成（未删且未红冲的生成单存在即拒绝，
 *       申请被删/红冲后可再生成，旧联动软删留痕）。</li>
 * </ol>
 */
@Service
@RequiredArgsConstructor
public class MrpService {

    /**
     * 必须在统一原料占用、PO 供给分配和目标仓校验落地后才可开启。
     * 保持编译期默认关闭，避免仅靠前端按钮控制数据安全。
     */
    private static final boolean PLANNING_WRITE_READY = true;
    private static final boolean LEGACY_DERIVED_WRITE_READY = false;

    /** Server-authoritative capability used by every caller that would persist MRP-derived state. */
    public boolean isPlanningWriteReady() {
        return PLANNING_WRITE_READY;
    }

    /**
     * MAKE 树距根最大深度（自底向上 orchestrator / 傻瓜式 UI 用）。复用 MRP {@code exp} CTE 形状：
     * path 防环 + depth&lt;10 双保险。仅计入 {@code source_type='自制'} 的节点（V1 执行段按 source_type
     * 定路由：自制→MAKE；故无 BOM 的自制叶子件也算一层 MAKE）。返回 0=无自制下层。
     * 调用前应先 {@link #preview(UUID)} 触发 {@code validateBomGraph}（环/超 10 层硬错）。
     */
    public int makeTreeDepth(UUID planId) {
        Object r = em.createNativeQuery("""
                WITH RECURSIVE make_tree(goods_id, depth, path) AS (
                    SELECT i.goods_id, 0, ARRAY[]::uuid[]
                    FROM production_plan_items i
                    WHERE i.plan_id = :planId AND i.is_deleted = FALSE
                    UNION ALL
                    SELECT b.component_goods_id, mt.depth + 1, mt.path || b.id
                    FROM make_tree mt
                    JOIN goods_bom_items b
                      ON b.goods_id = mt.goods_id AND b.is_deleted = FALSE
                    JOIN goods component
                      ON component.id = b.component_goods_id AND component.is_deleted = FALSE
                    WHERE mt.depth < 10
                      AND NOT b.id = ANY(mt.path)
                      AND component.source_type = '自制'
                )
                SELECT COALESCE(MAX(depth), 0) FROM make_tree
                """).setParameter("planId", planId).getSingleResult();
        return r == null ? 0 : ((Number) r).intValue();
    }

    /**
     * 该计划的货品是否有 BOM 子件（即 confirm 能否展开）。
     * <p>自制叶子件（source_type='自制' 但无 BOM）是合法的最深 MAKE 节点——它没有可展开的子件，
     * 故 orchestrator 只自动审核它（使其可报工/入库），<b>不</b>对它调 confirm
     * （confirm 的 snapshot 内联 goods_bom_items，无 BOM 会得到空产品行而抛错）。
     * 这与当前人工流程一致：无 BOM 的自制件直接报工+成品入库，不走 confirm 展开。
     */
    public boolean planGoodsHasBom(UUID planId) {
        Object n = em.createNativeQuery("""
                SELECT COUNT(*) FROM goods_bom_items b
                JOIN production_plan_items i ON i.goods_id = b.goods_id
                WHERE i.plan_id = :planId AND b.is_deleted = FALSE AND i.is_deleted = FALSE
                """).setParameter("planId", planId).getSingleResult();
        return n instanceof Number num && num.longValue() > 0;
    }

    /** 生产计划需求源：开工日优先，未排开工日时回落计划交货日。 */
    private static final String MRP_SQL = buildMrpSql("""
            SELECT b.component_goods_id AS goods_id,
                   resolved_color.id AS color_id,
                   CASE
                       WHEN COALESCE(i.unit_rate,1) > 0 AND b.qty > 0 AND COALESCE(i.qty,0) >= 0
                       THEN (COALESCE(i.qty,0) * COALESCE(i.unit_rate,1) * b.qty)::numeric
                       ELSE 0::numeric
                   END AS req_qty,
                   COALESCE(i.plan_begin_date, p.delivery_date) AS need_date,
                   (source.is_deleted OR component.is_deleted
                    OR COALESCE(i.unit_rate,1) <= 0 OR i.unit_id IS NULL
                    OR b.qty <= 0 OR COALESCE(i.qty,0) < 0
                     OR (COALESCE(b.color_id, component.color_id) IS NOT NULL
                         AND (resolved_color.id IS NULL OR resolved_color.is_deleted))
                     OR (b.color_id IS NULL
                         AND NULLIF(b.color_legacy_id, 0) IS NOT NULL)
                     OR (component.color_id IS NULL
                         AND NULLIF(component.color_legacy_id, 0) IS NOT NULL))
                       AS invalid_requirement,
                   source.is_deleted AS src_deleted,
                   component.is_deleted AS comp_deleted,
                   (COALESCE(i.unit_rate,1) <= 0 OR i.unit_id IS NULL) AS plan_unit_bad,
                   (b.qty <= 0) AS bom_qty_bad,
                   (COALESCE(i.qty,0) < 0) AS plan_qty_bad,
                    ((COALESCE(b.color_id, component.color_id) IS NOT NULL
                      AND (resolved_color.id IS NULL OR resolved_color.is_deleted))
                     OR (b.color_id IS NULL
                         AND NULLIF(b.color_legacy_id, 0) IS NOT NULL)
                     OR (component.color_id IS NULL
                         AND NULLIF(component.color_legacy_id, 0) IS NOT NULL)) AS color_bad,
                   1 AS lvl,
                   ARRAY[b.id]::uuid[] AS path
            FROM production_plan_items i
            JOIN production_plans p ON p.id = i.plan_id AND p.is_deleted = false
            JOIN goods source ON source.id = i.goods_id
            JOIN goods_bom_items b ON b.goods_id = i.goods_id AND b.is_deleted = false
            JOIN goods component ON component.id = b.component_goods_id
             LEFT JOIN colors resolved_color
                    ON resolved_color.id = COALESCE(b.color_id, component.color_id)
            WHERE i.plan_id = :planId AND i.is_deleted = false
            """);

    /** D3：销售订单行需求源（已审订单）的同构展开 SQL。 */
    private static final String MRP_ORDER_SQL = buildMrpSql("""
            SELECT b.component_goods_id AS goods_id,
                   resolved_color.id AS color_id,
                   CASE
                       WHEN COALESCE(i.unit_rate,1) > 0 AND b.qty > 0 AND COALESCE(i.qty,0) >= 0
                       THEN (COALESCE(i.qty,0) * COALESCE(i.unit_rate,1) * b.qty)::numeric
                       ELSE 0::numeric
                   END AS req_qty,
                   COALESCE(i.deliver_date, o.deliver_date) AS need_date,
                   (source.is_deleted OR component.is_deleted
                    OR COALESCE(i.unit_rate,1) <= 0 OR i.unit_id IS NULL
                    OR b.qty <= 0 OR COALESCE(i.qty,0) < 0
                     OR (COALESCE(b.color_id, component.color_id) IS NOT NULL
                         AND (resolved_color.id IS NULL OR resolved_color.is_deleted))
                     OR (b.color_id IS NULL
                         AND NULLIF(b.color_legacy_id, 0) IS NOT NULL)
                     OR (component.color_id IS NULL
                         AND NULLIF(component.color_legacy_id, 0) IS NOT NULL))
                       AS invalid_requirement,
                   source.is_deleted AS src_deleted,
                   component.is_deleted AS comp_deleted,
                   (COALESCE(i.unit_rate,1) <= 0 OR i.unit_id IS NULL) AS plan_unit_bad,
                   (b.qty <= 0) AS bom_qty_bad,
                   (COALESCE(i.qty,0) < 0) AS plan_qty_bad,
                    ((COALESCE(b.color_id, component.color_id) IS NOT NULL
                      AND (resolved_color.id IS NULL OR resolved_color.is_deleted))
                     OR (b.color_id IS NULL
                         AND NULLIF(b.color_legacy_id, 0) IS NOT NULL)
                     OR (component.color_id IS NULL
                         AND NULLIF(component.color_legacy_id, 0) IS NOT NULL)) AS color_bad,
                   1 AS lvl,
                   ARRAY[b.id]::uuid[] AS path
            FROM sales_order_items i
            JOIN sales_orders o ON o.id = i.order_id AND o.status = 1 AND o.is_deleted = false
                AND o.finance_confirmed = true
            JOIN goods source ON source.id = i.goods_id
            JOIN goods_bom_items b ON b.goods_id = i.goods_id AND b.is_deleted = false
            JOIN goods component ON component.id = b.component_goods_id
             LEFT JOIN colors resolved_color
                    ON resolved_color.id = COALESCE(b.color_id, component.color_id)
            WHERE i.order_id = :orderId AND i.is_deleted = false
            """);

    private static String buildMrpSql(String seed) {
        return """
            WITH RECURSIVE exp AS (
                %s
                UNION ALL
                SELECT b.component_goods_id,
                       resolved_color.id,
                       CASE WHEN b.qty > 0 THEN (e.req_qty * b.qty)::numeric ELSE 0::numeric END,
                       e.need_date,
                       (e.invalid_requirement OR b.qty <= 0 OR component.is_deleted
                         OR (COALESCE(b.color_id, component.color_id) IS NOT NULL
                             AND (resolved_color.id IS NULL OR resolved_color.is_deleted))
                         OR (b.color_id IS NULL
                             AND NULLIF(b.color_legacy_id, 0) IS NOT NULL)
                         OR (component.color_id IS NULL
                             AND NULLIF(component.color_legacy_id, 0) IS NOT NULL)),
                       e.src_deleted,
                       (e.comp_deleted OR component.is_deleted),
                       e.plan_unit_bad,
                       (e.bom_qty_bad OR b.qty <= 0),
                       e.plan_qty_bad,
                         (e.color_bad
                          OR (COALESCE(b.color_id, component.color_id) IS NOT NULL
                              AND (resolved_color.id IS NULL OR resolved_color.is_deleted))
                          OR (b.color_id IS NULL
                              AND NULLIF(b.color_legacy_id, 0) IS NOT NULL)
                          OR (component.color_id IS NULL
                              AND NULLIF(component.color_legacy_id, 0) IS NOT NULL)),
                       e.lvl + 1,
                       e.path || b.id
                FROM exp e
                JOIN goods_bom_items b ON b.goods_id = e.goods_id AND b.is_deleted = false
                JOIN goods component ON component.id = b.component_goods_id
                 LEFT JOIN colors resolved_color
                        ON resolved_color.id = COALESCE(b.color_id, component.color_id)
                WHERE e.lvl < 10 AND NOT b.id = ANY(e.path)
            ),
            demand_buckets AS (
                SELECT e.goods_id, e.color_id, e.need_date,
                       SUM(e.req_qty)::numeric AS bucket_gross
                FROM exp e
                GROUP BY e.goods_id, e.color_id, e.need_date
            ),
            demand_timeline AS (
                SELECT d.goods_id, d.color_id, d.need_date,
                       SUM(d.bucket_gross) OVER (
                           PARTITION BY d.goods_id, d.color_id
                           ORDER BY d.need_date NULLS FIRST
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                       )::numeric AS cumulative_gross
                FROM demand_buckets d
            ),
            agg AS (
                SELECT e.goods_id, e.color_id,
                       SUM(e.req_qty)::numeric AS gross,
                       CASE WHEN bool_or(e.need_date IS NULL)
                            THEN NULL
                            ELSE MIN(e.need_date)
                       END AS need_date,
                       bool_or(e.invalid_requirement) AS invalid_requirement,
                       bool_or(e.src_deleted) AS src_deleted,
                       bool_or(e.comp_deleted) AS comp_deleted,
                       bool_or(e.plan_unit_bad) AS plan_unit_bad,
                       bool_or(e.bom_qty_bad) AS bom_qty_bad,
                       bool_or(e.plan_qty_bad) AS plan_qty_bad,
                       bool_or(e.color_bad) AS color_bad,
                       bool_or(EXISTS (SELECT 1 FROM goods_bom_items c
                                       WHERE c.goods_id = e.goods_id AND c.is_deleted = false)) AS has_bom
                FROM exp e
                GROUP BY e.goods_id, e.color_id
            ),
            stock AS (
                SELECT goods_id, color_id, SUM(qty)::numeric AS book_stock
                FROM stock_balances
                GROUP BY goods_id, color_id
            ),
            reserved AS (
                SELECT goods_id, color_id,
                       SUM(GREATEST(qty - consumed_qty - released_qty, 0))::numeric AS sales_reserved
                FROM stock_reservations
                WHERE is_deleted = false AND status = 0
                GROUP BY goods_id, color_id
            )
            SELECT a.goods_id, g.code, g.name, g.spec, a.color_id, a.gross,
                   COALESCE(s.book_stock, 0)::numeric AS book_stock,
                   COALESCE(r.sales_reserved, 0)::numeric AS sales_reserved,
                   GREATEST(COALESCE(g.min_qty, 0), 0)::numeric AS safety_stock,
                   COALESCE(po.open_total, 0)::numeric AS open_total,
                   COALESCE(po.open_on_time, 0)::numeric AS open_on_time,
                   a.need_date,
                   po.earliest_arrival,
                   a.has_bom,
                   u.id AS unit_id,
                   (a.invalid_requirement OR g.is_deleted
                    OR u.id IS NULL OR COALESCE(u.is_deleted, true)) AS invalid_requirement,
                   COALESCE(po.invalid_rate, false) AS invalid_po_rate,
                   a.src_deleted,
                   (a.comp_deleted OR g.is_deleted) AS comp_deleted,
                   a.plan_unit_bad,
                   a.bom_qty_bad,
                   a.plan_qty_bad,
                   a.color_bad,
                   (u.id IS NULL OR COALESCE(u.is_deleted, true)) AS unit_unresolved,
                   g.source_type
            FROM agg a
            JOIN goods g ON g.id = a.goods_id
             LEFT JOIN units u ON u.id = g.unit_id
            LEFT JOIN stock s
                   ON s.goods_id = a.goods_id AND s.color_id IS NOT DISTINCT FROM a.color_id
            LEFT JOIN reserved r
                   ON r.goods_id = a.goods_id AND r.color_id IS NOT DISTINCT FROM a.color_id
            CROSS JOIN LATERAL (
                SELECT GREATEST(
                           COALESCE(s.book_stock, 0)
                           - COALESCE(r.sales_reserved, 0)
                           - GREATEST(COALESCE(g.min_qty, 0), 0),
                           0
                       )::numeric AS available_now
            ) av
            LEFT JOIN LATERAL (
                WITH po_line AS (
                    SELECT CASE
                               WHEN COALESCE(oi.unit_rate,1) > 0 AND oi.unit_id IS NOT NULL
                               THEN (GREATEST(COALESCE(oi.qty,0) - COALESCE(oi.received_qty,0), 0)
                                     * COALESCE(oi.unit_rate,1))::numeric
                               ELSE 0::numeric
                           END AS open_base,
                           COALESCE(oi.deliver_date, o.deliver_date) AS eta,
                           (GREATEST(COALESCE(oi.qty,0) - COALESCE(oi.received_qty,0), 0) > 0
                            AND (COALESCE(oi.unit_rate,1) <= 0 OR oi.unit_id IS NULL))
                               AS invalid_rate
                    FROM purchase_order_items oi
                    JOIN purchase_orders o ON o.id = oi.order_id
                    WHERE o.status = 1
                      AND o.is_deleted = false
                      AND COALESCE(o.is_stopped, false) = false
                      AND o.is_closed = false
                      AND oi.is_deleted = false
                      AND oi.goods_id = a.goods_id
                      AND oi.color_id IS NOT DISTINCT FROM a.color_id
                )
                SELECT COALESCE(SUM(pl.open_base), 0)::numeric AS open_total,
                       GREATEST(
                           a.gross - av.available_now
                           - COALESCE((
                               SELECT MAX(GREATEST(
                                   dt.cumulative_gross - av.available_now
                                   - COALESCE((
                                       SELECT SUM(pl_due.open_base)
                                       FROM po_line pl_due
                                       WHERE dt.need_date IS NOT NULL
                                         AND pl_due.eta IS NOT NULL
                                         AND pl_due.eta <= dt.need_date
                                   ), 0),
                                   0
                               ))
                               FROM demand_timeline dt
                               WHERE dt.goods_id = a.goods_id
                                 AND dt.color_id IS NOT DISTINCT FROM a.color_id
                           ), GREATEST(a.gross - av.available_now, 0)),
                           0
                       )::numeric AS open_on_time,
                       MIN(pl.eta) FILTER (WHERE pl.open_base > 0) AS earliest_arrival,
                       COALESCE(bool_or(pl.invalid_rate), false) AS invalid_rate
                FROM po_line pl
            ) po ON true
            ORDER BY a.need_date NULLS LAST, g.code, a.color_id NULLS FIRST
            """.formatted(seed);
    }

    private static final String PLAN_BOM_VALIDATION_SQL = buildBomValidationSql("""
            SELECT DISTINCT goods_id
            FROM production_plan_items
            WHERE plan_id = :sourceId AND is_deleted = false
            """);

    private static final String ORDER_BOM_VALIDATION_SQL = buildBomValidationSql("""
            SELECT DISTINCT i.goods_id
            FROM sales_order_items i
            JOIN sales_orders o ON o.id = i.order_id
            WHERE i.order_id = :sourceId
              AND i.is_deleted = false
              AND o.is_deleted = false
              AND o.status = 1
              AND o.finance_confirmed = true
            """);

    /**
     * BOM 展开虽然有深度/路径护栏，但不能把截断结果当成真实需求。
     * 先验证当前需求根可达图；存在环或超过十层时整次 MRP 失败。
     */
    private static String buildBomValidationSql(String roots) {
        return """
            WITH RECURSIVE roots(goods_id) AS (
                %s
            ),
            walk(root_id, goods_id, path, depth, cycle) AS (
                SELECT r.goods_id, b.component_goods_id,
                       ARRAY[r.goods_id, b.component_goods_id]::uuid[],
                       1,
                       b.component_goods_id = r.goods_id
                FROM roots r
                JOIN goods_bom_items b ON b.goods_id = r.goods_id AND b.is_deleted = false
                UNION ALL
                SELECT w.root_id, b.component_goods_id,
                       w.path || b.component_goods_id,
                       w.depth + 1,
                       b.component_goods_id = ANY(w.path)
                FROM walk w
                JOIN goods_bom_items b ON b.goods_id = w.goods_id AND b.is_deleted = false
                WHERE w.cycle = false AND w.depth < 10
            )
            SELECT COALESCE(bool_or(cycle), false) AS has_cycle,
                   COALESCE(bool_or(depth = 10 AND EXISTS (
                       SELECT 1 FROM goods_bom_items child
                       WHERE child.goods_id = walk.goods_id AND child.is_deleted = false)), false)
                       AS exceeds_depth
            FROM walk
            """.formatted(roots);
    }

    private final EntityManager em;
    private final ProductionPlanRepository planRepo;
    private final ProductionPlanItemRepository itemRepo;
    private final PurchaseRequestRepository requestRepo;
    private final PurchaseRequestItemRepository requestItemRepo;
    private final StockDocumentRepository stockDocRepo;
    private final StockDocumentItemRepository stockDocItemRepo;
    private final DocNumberService docNumberService;
    private final ProductionProductNoAllocator productNoAllocator;
    private final SecurityContextCurrentUser currentUser;
    private final OrganizationReferencePort organizationReferences;
    private final com.uten.imp.features.production.fulfillment.ProductionFulfillmentLedgerService fulfillmentLedger;
    private final TxSessionVars tx;

    /** 物料需求预览：全部物料行（含自制半成品标记）。 */
    @Transactional(readOnly = true)
    public List<MrpRow> preview(UUID planId) {
        requirePlan(planId);
        var backed = fulfillmentLedger.allocationBackedDimensions(planId);
        return explode(planId).stream()
                .map(row -> row.withCapabilities(
                        backed.contains(new com.uten.imp.features.production.fulfillment
                                .ProductionFulfillmentLedgerService.MaterialDimension(
                                row.goodsId(), row.colorId())),
                        PLANNING_WRITE_READY))
                .toList();
    }

    /**
     * 已生成的自制件子计划溯源（父计划 MRP 面板/详情页进度区展示用）：
     * 未删联动 + 未删子计划，红冲的也列出（状态 -1 前端标灰）。含完工进度（Σiqty/Σqty）。
     */
    @Transactional(readOnly = true)
    public List<SubplanRef> subplans(UUID planId) {
        requirePlan(planId);
        List<Object[]> rs = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT p.id, p.bill_no, p.status, p.is_closed, p.bill_date, p.delivery_date,
                       (SELECT COALESCE(SUM(i.qty), 0) FROM production_plan_items i
                        WHERE i.plan_id = p.id AND i.is_deleted = false) AS total_qty,
                       (SELECT COALESCE(SUM(i.iqty), 0) FROM production_plan_items i
                        WHERE i.plan_id = p.id AND i.is_deleted = false) AS inbound_qty
                FROM subplan_links l
                JOIN production_plans p ON p.id = l.subplan_id
                WHERE l.plan_id = :planId AND l.is_deleted = false AND p.is_deleted = false
                ORDER BY p.bill_date DESC NULLS LAST, p.bill_no
                """).setParameter("planId", planId));
        List<SubplanRef> out = new ArrayList<>(rs.size());
        for (Object[] r : rs) {
            BigDecimal total = r[6] == null ? BigDecimal.ZERO : (BigDecimal) r[6];
            BigDecimal inbound = r[7] == null ? BigDecimal.ZERO : (BigDecimal) r[7];
            double pct = total.signum() > 0
                    ? Math.min(inbound.divide(total, 4, java.math.RoundingMode.HALF_UP).doubleValue(), 1.0) : 0;
            out.add(new SubplanRef(
                    (UUID) r[0], (String) r[1],
                    r[2] == null ? null : ((Number) r[2]).shortValue(),
                    Boolean.TRUE.equals(r[3]),
                    localDate(r[4]),
                    localDate(r[5]),
                    total, inbound, pct));
        }
        return out;
    }

    /** 子计划溯源行（含完工进度）。 */
    public record SubplanRef(UUID planId, String billNo, Short status, boolean closed,
                             LocalDate billDate, LocalDate deliveryDate, BigDecimal totalQty,
                             BigDecimal inboundQty, double percent) {
    }

    public record DirectMakeRequirement(
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal requiredQty,
            BigDecimal shortageQty) {
    }

    /** D3 订单物料分析（李主管）：从已审销售订单直接 BOM 展开（不必先建生产计划）。 */
    @Transactional(readOnly = true)
    public List<MrpRow> previewOrder(UUID orderId) {
        Object n = em.createNativeQuery(
                "SELECT COUNT(*) FROM sales_orders WHERE id=:id AND status=1 AND is_deleted=false"
                        + " AND finance_confirmed=true")
                .setParameter("id", orderId).getSingleResult();
        if (((Number) n).intValue() == 0) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核且已通过财务确认的销售订货单可做物料分析");
        }
        return explodeOrder(orderId);
    }

    /** 生成采购申请：默认净需求（strategy=gross 时按毛需求）。 */
    @Transactional
    public MrpGenerateResult generate(UUID planId) {
        tx.bind();
        return generateInternal(planId, "net");
    }

    /** 生成采购申请：净需求>0（strategy=gross 时毛需求>0）的外购物料 → 一张草稿申请；防重复生成。 */
    @Transactional
    public MrpGenerateResult generate(UUID planId, String strategy) {
        tx.bind();
        return generateInternal(planId, strategy);
    }

    private MrpGenerateResult generateInternal(UUID planId, String strategy) {
        ProductionPlan plan = lockPlan(planId);
        assertLegacyDerivedWriteAllowed(planId, "采购申请");
        return generatePurchaseLocked(plan, strategy, true);
    }

    /** 调用方已持有父计划写锁；emptyIsError=false 用于计划包无新购缺口时返回 null。 */
    private MrpGenerateResult generatePurchaseLocked(
            ProductionPlan plan, String strategy, boolean emptyIsError) {
        boolean grossMode = "gross".equalsIgnoreCase(strategy);
        requireNotTerminal(plan, "采购申请");
        requirePlanningWriteReady();

        List<MrpRow> rows = explode(plan.getId());
        List<MrpRow> buy = rows.stream()
                .filter(r -> !r.selfMade()
                        && (grossMode ? r.gross() : r.purchaseNetShortage()) != null
                        && (grossMode ? r.gross() : r.purchaseNetShortage()).signum() > 0)
                .toList();
        if (buy.isEmpty()) {
            if (!emptyIsError) return null;
            throw new ApiException(ErrorCode.BUSINESS, grossMode
                    ? "无毛需求外购物料（或全部为自制件）"
                    : "无新增采购净缺口（当前可用/有效在途已覆盖，晚到在途请走催交或改配）");
        }

        // 父计划写锁使“查重 + 生成”串行；联动表继续承担业务溯源与历史留痕。
        var dup = em.createNativeQuery("""
                SELECT r.bill_no FROM mrp_generations g
                JOIN purchase_requests r ON r.id = g.request_id
                WHERE g.plan_id = :planId AND g.is_deleted = false
                  AND r.is_deleted = false AND r.status <> -1
                LIMIT 1
                """).setParameter("planId", plan.getId()).getResultList();
        if (!dup.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "本计划已生成过采购申请（" + dup.get(0) + "），如需重生成请先删除或红冲该申请");
        }

        LocalDate today = BusinessTime.today();
        LocalDate requestNeedDate = buy.stream()
                .map(MrpRow::needDate)
                .filter(java.util.Objects::nonNull)
                .min(LocalDate::compareTo)
                .orElse(plan.getDeliveryDate());
        PurchaseRequest r = new PurchaseRequest();
        r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.PURCHASE_REQUEST));
        r.setBillDate(today);
        r.setNeedDate(requestNeedDate);
        UUID applicantEmployeeId = currentUser.requireEmployeeId();
        r.setApplicantId(applicantEmployeeId);
        organizationReferences.findActiveEmployee(applicantEmployeeId)
                .map(OrganizationReferencePort.EmployeeReference::departmentId)
                .ifPresent(r::setDepartmentId);
        r.setMakerId(applicantEmployeeId);
        r.setRemark("生产计划 " + plan.getBillNo() + " 物料需求自动生成");
        r.setSourceDocNo(plan.getBillNo());
        r.setStatus((short) 0);
        requestRepo.save(r);

        Map<UUID, PurchaseGoodsSnapshot> goodsSnapshots =
                PurchaseGoodsSnapshot.fromMaster(
                        em,
                        buy.stream().map(MrpRow::goodsId).toList(),
                        PurchaseGoodsSnapshot.MASTER_AT_SAVE);
        int line = 0;
        for (MrpRow row : buy) {
            line++;
            PurchaseRequestItem it = new PurchaseRequestItem();
            it.setRequestId(r.getId());
            it.setBillNo(r.getBillNo());
            it.setBillDate(r.getBillDate());
            it.setLineNo(line);
            it.setGoodsId(row.goodsId());
            PurchaseGoodsSnapshot goodsSnapshot = PurchaseGoodsSnapshot.require(
                    goodsSnapshots, row.goodsId(), "MRP采购申请明细");
            it.setGoodsCodeSnapshot(goodsSnapshot.code());
            it.setGoodsNameSnapshot(goodsSnapshot.name());
            it.setGoodsSnapshotSource(goodsSnapshot.source());
            it.setColorId(row.colorId());
            it.setUnitId(row.unitId());
            it.setUnitRate(BigDecimal.ONE);
            it.setQty(grossMode ? row.gross() : row.purchaseNetShortage());
            it.setPrice(BigDecimal.ZERO);
            it.setAmountOriginal(BigDecimal.ZERO);
            it.setAmountLocal(BigDecimal.ZERO);
            it.setGiftQty(BigDecimal.ZERO);
            it.setDeliverDate(row.needDate() == null ? requestNeedDate : row.needDate());
            it.setProductionPlanNo(plan.getBillNo());
            it.setSourceDocNo(plan.getBillNo());
            it.setRemark(grossMode
                    ? "毛需求开单（不扣库存/在途）"
                    : "毛需求 " + row.gross().stripTrailingZeros().toPlainString()
                    + " − 当前可用 " + row.availableNow().stripTrailingZeros().toPlainString()
                    + " − 全部在途 " + row.openPoTotal().stripTrailingZeros().toPlainString()
                    + "；需求日前缺口 " + row.timelyShortage().stripTrailingZeros().toPlainString());
            requestItemRepo.save(it);
        }
        // 自动生成的草稿采购申请不填单价，金额合计按业务约定保持为 0（采购员定稿后再汇总）。
        r.setTotalOriginal(BigDecimal.ZERO);
        r.setTotalLocal(BigDecimal.ZERO);
        requestRepo.save(r);

        // 联动留痕：旧联动行软删（历史可追溯），插新行
        em.createNativeQuery("""
                UPDATE mrp_generations SET is_deleted = true, deleted_at = now()
                WHERE plan_id = :planId AND is_deleted = false
                """).setParameter("planId", plan.getId()).executeUpdate();
        em.createNativeQuery("""
                INSERT INTO mrp_generations (plan_id, request_id, created_by)
                VALUES (:planId, :requestId, :by)
                """).setParameter("planId", plan.getId()).setParameter("requestId", r.getId())
                .setParameter("by", currentUser.requireId()).executeUpdate();

        return new MrpGenerateResult(r.getId(), r.getBillNo(), line,
                rows.stream().filter(MrpRow::selfMade).map(MrpRow::goodsId).distinct().toList());
    }

    // ======================== 计划 → 生产领料单（DRAW） ========================

    /**
     * 生成生产领料单：全部 BOM 物料按<b>毛需求</b>开单（车间按排产领料，与采购按净需求互补），
     * 自制件同样列出（半成品也可能从仓库领）。plan_draw_links 防重复（规则同采购申请）。
     */
    @Transactional
    public MrpGenerateResult generateDraw(UUID planId, UUID warehouseId) {
        tx.bind();
        requirePlanningWriteReady();
        ProductionPlan plan = lockPlan(planId);
        assertLegacyDerivedWriteAllowed(planId, "领料单");
        requireApprovedPlanForStock(plan, "领料单");
        if (warehouseId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "生成领料单需指定仓库");
        }
        var dup = em.createNativeQuery("""
                SELECT d.bill_no FROM plan_draw_links l
                JOIN stock_documents d ON d.id = l.draw_id
                WHERE l.plan_id = :planId AND l.is_deleted = false
                  AND d.doc_type = 'DRAW' AND d.is_deleted = false AND d.status <> -1
                LIMIT 1
                """).setParameter("planId", planId).getResultList();
        if (!dup.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "本计划已生成过领料单（" + dup.get(0) + "），如需重生成请先删除或红冲该单");
        }

        List<MrpRow> rows = explode(planId).stream()
                .filter(r -> r.gross() != null && r.gross().signum() > 0).toList();
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细货品均未维护 BOM，无物料可领");
        }

        LocalDate today = BusinessTime.today();
        StockDocument d = new StockDocument();
        d.setDocType("DRAW");
        d.setBillNo(docNumberService.nextNumber(DocNumberPrefix.STOCK_DRAW));
        d.setBillDate(today);
        d.setWarehouseId(warehouseId);
        d.setPlanNo(plan.getBillNo());
        d.setSourceDocNo(plan.getBillNo());
        d.setRemark("生产计划 " + plan.getBillNo() + " 按 BOM 毛需求自动生成");
        d.setWorkerId(currentUser.requireEmployeeId());
        d.setMakerId(currentUser.requireEmployeeId());
        d.setStatus((short) 0);
        stockDocRepo.save(d);

        Map<UUID, StockGoodsSnapshot> goodsSnapshots =
                StockGoodsSnapshot.fromMaster(
                        em,
                        rows.stream().map(MrpRow::goodsId).toList(),
                        StockGoodsSnapshot.MASTER_AT_SAVE);
        int line = 0;
        for (MrpRow row : rows) {
            line++;
            StockDocumentItem it = new StockDocumentItem();
            it.setDocId(d.getId());
            it.setBillType("DRAW");
            it.setBillNo(d.getBillNo());
            it.setBillDate(d.getBillDate());
            it.setLineNo(line);
            it.setGoodsId(row.goodsId());
            StockGoodsSnapshot.require(
                            goodsSnapshots, row.goodsId(), "生产领料明细")
                    .applyTo(it, null);
            it.setColorId(row.colorId());
            it.setUnitId(row.unitId());
            it.setUnitRate(BigDecimal.ONE);
            it.setQty(row.gross());
            it.setBaseQty(row.gross());
            it.setSourceDocNo(plan.getBillNo());
            it.setRemark(row.selfMade() ? "自制件（半成品，可从库存领）" : null);
            stockDocItemRepo.save(it);
        }

        em.createNativeQuery("""
                UPDATE plan_draw_links SET is_deleted = true, deleted_at = now()
                WHERE plan_id = :planId AND is_deleted = false
                  AND draw_id IN (SELECT id FROM stock_documents WHERE doc_type = 'DRAW')
                """).setParameter("planId", planId).executeUpdate();
        em.createNativeQuery("""
                INSERT INTO plan_draw_links (plan_id, draw_id, created_by)
                VALUES (:planId, :drawId, :by)
                """).setParameter("planId", planId).setParameter("drawId", d.getId())
                .setParameter("by", currentUser.requireId()).executeUpdate();

        return new MrpGenerateResult(d.getId(), d.getBillNo(), line, List.of());
    }

    // ======================== 计划 → 成品入库单（FINISHED_IN） ========================

    /**
     * 生成成品入库单：计划明细自身（非 BOM 展开），数量 = 已审核合格量（fqty）− 已入库量（iqty）。
     * 没有逐笔销售分摊台账时，多销售行合并计划禁止生成，避免 FIFO 猜测数据归属。
     */
    @Transactional
    public MrpGenerateResult generateFinishedIn(UUID planId, UUID warehouseId) {
        tx.bind();
        ProductionPlan plan = lockPlan(planId);
        assertLegacyDerivedWriteAllowed(planId, "成品入库单");
        requireApprovedPlanForStock(plan, "成品入库单");
        Number segmented = (Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM production_planning_packages package
                        WHERE package.plan_id = :planId
                          AND package.status = 'CONFIRMED'
                          AND package.execution_model_version = 1
                          AND package.is_deleted = FALSE
                        """)
                .setParameter("planId", planId)
                .getSingleResult();
        if (segmented.longValue() > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该计划已启用执行子计划，请从具体子计划报工；报工审核后系统会生成精确归属的成品入库单");
        }
        if (warehouseId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "生成成品入库单需指定仓库");
        }
        var dup = em.createNativeQuery("""
                SELECT d.bill_no FROM plan_draw_links l
                JOIN stock_documents d ON d.id = l.draw_id
                WHERE l.plan_id = :planId AND l.is_deleted = false
                  AND d.doc_type = 'FINISHED_IN' AND d.is_deleted = false AND d.status <> -1
                LIMIT 1
                """).setParameter("planId", planId).getResultList();
        if (!dup.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "本计划已生成过成品入库单（" + dup.get(0) + "），如需重生成请先删除或红冲该单");
        }

        var itemRows = em.createNativeQuery("""
                SELECT i.id, i.goods_id, i.color_id, i.unit_id, COALESCE(i.unit_rate,1),
                       COALESCE(i.fqty,0) AS finished_qty, COALESCE(i.iqty,0) AS inbound_qty,
                       (SELECT COUNT(*) FROM plan_order_item_links l
                        WHERE l.plan_item_id = i.id AND l.is_deleted = false) AS active_link_count
                FROM production_plan_items i
                WHERE i.plan_id = :planId AND i.is_deleted = false
                ORDER BY i.line_no
                """).setParameter("planId", planId).getResultList();
        List<Object[]> lines = new java.util.ArrayList<>();
        for (Object x : itemRows) {
            Object[] r = (Object[]) x;
            BigDecimal rate = r[4] == null ? BigDecimal.ONE : (BigDecimal) r[4];
            if (rate.signum() <= 0) {
                throw new ApiException(ErrorCode.CONFLICT, "生产计划行单位换算率必须大于 0");
            }
            BigDecimal remain = FinishedInboundAllocator.reportedRemaining(
                    (BigDecimal) r[5], (BigDecimal) r[6]);
            if (remain.signum() > 0) {
                long activeLinkCount = r[7] == null ? 0L : ((Number) r[7]).longValue();
                if (activeLinkCount > 1) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "合并销售订单的成品入库缺少持久化分摊明细，禁止生成入库单");
                }
                r[5] = remain;
                lines.add(r);
            }
        }
        if (lines.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "无已报工待入库量");
        }

        LocalDate today = BusinessTime.today();
        StockDocument d = new StockDocument();
        d.setDocType("FINISHED_IN");
        d.setBillNo(docNumberService.nextNumber(DocNumberPrefix.STOCK_FINISHED_IN));
        d.setBillDate(today);
        d.setWarehouseId(warehouseId);
        d.setPlanNo(plan.getBillNo());
        d.setSourceDocNo(plan.getBillNo());
        d.setRemark("生产计划 " + plan.getBillNo() + " 完工入库自动生成");
        d.setWorkerId(currentUser.requireEmployeeId());
        d.setMakerId(currentUser.requireEmployeeId());
        d.setStatus((short) 0);
        stockDocRepo.save(d);

        Map<UUID, StockGoodsSnapshot> goodsSnapshots =
                StockGoodsSnapshot.fromMaster(
                        em,
                        lines.stream().map(row -> (UUID) row[1]).toList(),
                        StockGoodsSnapshot.MASTER_AT_SAVE);
        int line = 0;
        for (Object[] r : lines) {
            line++;
            StockDocumentItem it = new StockDocumentItem();
            it.setDocId(d.getId());
            it.setBillType("FINISHED_IN");
            it.setBillNo(d.getBillNo());
            it.setBillDate(d.getBillDate());
            it.setLineNo(line);
            it.setGoodsId((UUID) r[1]);
            StockGoodsSnapshot.require(
                            goodsSnapshots, (UUID) r[1], "完工入库明细")
                    .applyTo(it, null);
            it.setColorId((UUID) r[2]);
            it.setUnitId((UUID) r[3]);
            BigDecimal rate = (BigDecimal) r[4];
            BigDecimal remain = (BigDecimal) r[5];
            it.setUnitRate(rate);
            it.setQty(remain);
            it.setBaseQty(remain.multiply(rate));
            it.setUpstreamItemId((UUID) r[0]);
            it.setSourceDocNo(plan.getBillNo());
            stockDocItemRepo.save(it);
        }

        em.createNativeQuery("""
                INSERT INTO plan_draw_links (plan_id, draw_id, created_by)
                VALUES (:planId, :drawId, :by)
                """).setParameter("planId", planId).setParameter("drawId", d.getId())
                .setParameter("by", currentUser.requireId()).executeUpdate();

        return new MrpGenerateResult(d.getId(), d.getBillNo(), line, List.of());
    }

    /**
     * V1 执行分段确认事务内的直接层自制件派生内核。
     *
     * <p>输入只能来自已锁定、已校验的执行分段 allocation：仅把本包直接层
     * MAKE 的候选短缺生成一张草稿子生产计划。这里禁止调用递归 explode；
     * 下层 BOM 必须进入该子计划后再逐级预排，避免父子计划重复生成同一孙层物料。
     * qty=直接层短缺，oqty=直接层毛需求，货品/颜色/单位沿用 allocation 权威值。
     */
    @Transactional
    public List<GenerateSubplansRequest.Created> generateSelfMadeSubplansForPackage(
            UUID planId,
            UUID planningPackageId,
            List<DirectMakeRequirement> directRequirements) {
        tx.bind();
        List<DirectMakeRequirement> make =
                normalizeDirectMakeRequirements(directRequirements);
        if (make.isEmpty()) {
            return List.of();
        }
        ProductionPlan plan = lockPlan(planId);
        requireNotTerminal(plan, "自制件子计划");

        // 幂等/防重复：父计划已有 V1 产生的有效子计划则跳过。
        Number existing = (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM subplan_links l
                JOIN production_plans p ON p.id = l.subplan_id
                WHERE l.plan_id = :planId AND l.is_deleted = false
                  AND l.source = 'EXECUTION_V1'
                  AND p.is_deleted = false AND p.status <> -1
                """).setParameter("planId", planId).getSingleResult();
        if (existing.intValue() > 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "该父计划已存在有效的执行分段（EXECUTION_V1）子计划，不能重复生成");
        }

        // 子计划交货日：父计划最早开工日；无开工日则取父计划交货日。
        Object begin = em.createNativeQuery("""
                SELECT MIN(plan_begin_date) FROM production_plan_items
                WHERE plan_id = :planId AND is_deleted = false
                """).setParameter("planId", planId).getSingleResult();
        LocalDate subDelivery = begin != null
                ? localDate(begin)
                : plan.getDeliveryDate();

        ProductionPlan sub = new ProductionPlan();
        sub.setBillNo(docNumberService.nextNumber(DocNumberPrefix.PRODUCTION_SUBPLAN));
        sub.setBillDate(BusinessTime.today());
        sub.setDeliveryDate(subDelivery);
        em.flush();
        sub.setDepartmentId(plan.getDepartmentId());
        sub.setWorkshopName(plan.getWorkshopName());
        sub.setRemark("父计划 " + plan.getBillNo()
                + " 直接层自制短缺自动生成（执行分段）");
        sub.setSourceDocNo(plan.getBillNo());
        sub.setMakerId(currentUser.requireEmployeeId());
        sub.setStatus((short) 0);
        planRepo.save(sub);
        planRepo.flush();

        int line = 0;
        for (DirectMakeRequirement row : make) {
            line++;
            ProductionPlanItem item = new ProductionPlanItem();
            item.setPlanId(sub.getId());
            item.setBillNo(sub.getBillNo());
            item.setBillDate(sub.getBillDate());
            item.setLineNo(line);
            item.setProductNo(productNoAllocator.allocate(sub.getId(), Set.of()));
            item.setGoodsId(row.goodsId());
            item.setColorId(row.colorId());
            item.setUnitId(row.unitId());
            item.setUnitRate(BigDecimal.ONE);
            item.setQty(row.shortageQty());
            item.setOqty(row.requiredQty());
            item.setSourceDocNo(plan.getBillNo());
            item.setRemark("直接层毛需求 "
                    + row.requiredQty().stripTrailingZeros().toPlainString()
                    + "，短缺 "
                    + row.shortageQty().stripTrailingZeros().toPlainString());
            itemRepo.save(item);
        }

        em.createNativeQuery("""
                INSERT INTO subplan_links (plan_id, subplan_id, created_by,
                                           planning_package_id, source)
                VALUES (:planId, :subplanId, :by, :packageId, 'EXECUTION_V1')
                """)
                .setParameter("planId", planId)
                .setParameter("subplanId", sub.getId())
                .setParameter("by", currentUser.requireId())
                .setParameter("packageId", planningPackageId)
                .executeUpdate();

        return List.of(new GenerateSubplansRequest.Created(
                sub.getId(), sub.getBillNo(), line, sub.getWorkshopName()));
    }

    private static List<DirectMakeRequirement>
            normalizeDirectMakeRequirements(
                    List<DirectMakeRequirement> raw) {
        if (raw == null || raw.isEmpty()) {
            return List.of();
        }
        Map<Key, DirectMakeRequirement> unique = new LinkedHashMap<>();
        for (DirectMakeRequirement value : raw) {
            if (value == null
                    || value.goodsId() == null
                    || value.unitId() == null
                    || value.requiredQty() == null
                    || value.requiredQty().signum() <= 0
                    || value.shortageQty() == null
                    || value.shortageQty().signum() <= 0
                    || value.shortageQty().compareTo(
                            value.requiredQty()) > 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "直接层自制需求的货品、单位或数量无效，不能生成子计划");
            }
            Key key = new Key(value.goodsId(), value.colorId());
            DirectMakeRequirement previous = unique.putIfAbsent(key, value);
            if (previous != null) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "同一直接层自制物料颜色维度重复，不能生成子计划");
            }
        }
        return unique.values().stream()
                .sorted(java.util.Comparator
                        .comparing((DirectMakeRequirement value) ->
                                value.goodsId().toString())
                        .thenComparing(value ->
                                java.util.Objects.toString(value.colorId(), ""))
                        .thenComparing(value -> value.unitId().toString()))
                .toList();
    }

    private record Key(UUID goodsId, UUID colorId) {}

    // ======================== 内部 ========================
    private ProductionPlan requirePlan(UUID planId) {
        return planRepo.findById(planId).filter(p -> !p.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "生产计划不存在"));
    }

    private ProductionPlan lockPlan(UUID planId) {
        ProductionPlan plan = em.find(
                ProductionPlan.class, planId, LockModeType.PESSIMISTIC_WRITE);
        if (plan == null || plan.isDeleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "生产计划不存在");
        }
        return plan;
    }

    /**
     * A plan must never mix the execution-segment ledger with legacy
     * derived-document endpoints. Both paths lock the parent plan first, so
     * this check is also safe against a concurrent V1 confirmation.
     */
    private void assertLegacyDerivedWriteAllowed(UUID planId, String targetName) {
        Number count = (Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM production_planning_packages package
                        WHERE package.plan_id = :planId
                          AND package.execution_model_version = 1
                          AND package.is_deleted = FALSE
                        """)
                .setParameter("planId", planId)
                .getSingleResult();
        requireNoMixedExecutionModel(count.longValue(), targetName);
    }

    static void requireNoMixedExecutionModel(
            long executionSegmentPackageCount,
            String targetName) {
        if (executionSegmentPackageCount > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该计划已启用执行子计划，不能再通过旧接口生成" + targetName
                            + "；请在执行子计划链路内处理，避免重复锁料或重复开单");
        }
    }

    private static void requireNotTerminal(ProductionPlan plan, String targetName) {
        if ((plan.getStatus() != null && plan.getStatus() == -1)
                || plan.isCanceled()
                || plan.isStopped()) {
            throw new ApiException(
                    ErrorCode.BUSINESS,
                    "已红冲、已取消或已中止的生产计划不可生成" + targetName);
        }
    }

    private static void requirePlanningWriteReady() {
        if (!LEGACY_DERIVED_WRITE_READY) {
            // 不允许两个计划把同一库存/在途重复当作可用后直接落单。
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "MRP 规划写入尚未启用：需先上线统一原料占用、采购供给分配和目标仓校验");
        }
    }

    private static void requireApprovedPlanForStock(ProductionPlan plan, String targetName) {
        if (plan.getStatus() == null
                || plan.getStatus() != 1
                || plan.isCanceled()
                || plan.isStopped()) {
            throw new ApiException(
                    ErrorCode.BUSINESS,
                    "仅已审核且未取消、未中止的生产计划可生成" + targetName);
        }
    }

    private List<MrpRow> explode(UUID planId) {
        validateBomGraph(PLAN_BOM_VALIDATION_SQL, planId);
        return runExplode(MRP_SQL, "planId", planId);
    }

    /** D3：销售订单行 BOM 展开（同 MRP_SQL，仅需求源换成已审订单行 qty）。 */
    private List<MrpRow> explodeOrder(UUID orderId) {
        validateBomGraph(ORDER_BOM_VALIDATION_SQL, orderId);
        return runExplode(MRP_ORDER_SQL, "orderId", orderId);
    }

    private List<MrpRow> runExplode(String sql, String param, UUID id) {
        var q = em.createNativeQuery(sql).setParameter(param, id);
        List<Object[]> rs = NativeQueryResults.objectArrayRows(q);
        List<MrpRow> out = new ArrayList<>(rs.size());
        for (Object[] x : rs) {
            String goodsLabel = goodsLabel(x);
            if (Boolean.TRUE.equals(x[15])) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "货品 " + goodsLabel + " 的" + invalidRequirementReasons(x)
                                + "，禁止计算齐套");
            }
            if (Boolean.TRUE.equals(x[16])) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "货品 " + goodsLabel + " 存在未完成采购行的单位或换算率无效，禁止计算齐套");
            }
            if (x[14] == null) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "货品 " + goodsLabel + " 未维护可解析的基本单位，禁止生成采购或子计划");
            }
            out.add(MrpRow.fromAvailability(
                    (UUID) x[0], (String) x[1], (String) x[2], (String) x[3],
                    (UUID) x[4], decimal(x[5]), Boolean.TRUE.equals(x[13]), (UUID) x[14],
                    decimal(x[6]), decimal(x[7]), decimal(x[8]),
                    decimal(x[9]), decimal(x[10]),
                    localDate(x[11]), localDate(x[12]),
                    (String) x[24]));
        }
        return out;
    }

    /**
     * 货品编码缺失时用名称兜底，避免错误提示出现“货品 null”而无法定位。
     * code/name 均空时回落到主键 id，保证至少可追溯。
     */
    private static String goodsLabel(Object[] x) {
        String code = (String) x[1];
        if (code != null && !code.isBlank()) {
            return code;
        }
        String name = (String) x[2];
        if (name != null && !name.isBlank()) {
            return name + "（编码为空）";
        }
        return "id=" + x[0];
    }

    /**
     * 把聚合后的 invalid_requirement 拆成具体命中项，便于运维直接定位是单位、
     * 颜色、BOM 用量还是货品删除。各项来自 exp/agg 的分类 bool 与最终投影的
     * 单位解析列；总开关语义（x[15]）保持不变。
     */
    private static String invalidRequirementReasons(Object[] x) {
        List<String> reasons = new ArrayList<>();
        if (Boolean.TRUE.equals(x[17])) reasons.add("计划产品货品已删除");
        if (Boolean.TRUE.equals(x[18])) reasons.add("BOM 组件货品已删除");
        if (Boolean.TRUE.equals(x[23])) reasons.add("组件基本单位未维护或已禁用");
        if (Boolean.TRUE.equals(x[19])) reasons.add("计划明细行的单位或换算率无效");
        if (Boolean.TRUE.equals(x[20])) reasons.add("BOM 用量非正");
        if (Boolean.TRUE.equals(x[22])) reasons.add("颜色映射无效");
        if (Boolean.TRUE.equals(x[21])) reasons.add("计划数量为负");
        if (reasons.isEmpty()) {
            reasons.add("BOM 数量、颜色映射或需求单位无效");
        }
        return String.join("；", reasons);
    }

    private void validateBomGraph(String sql, UUID sourceId) {
        Object result = em.createNativeQuery(sql)
                .setParameter("sourceId", sourceId)
                .getSingleResult();
        Object[] row = (Object[]) result;
        if (Boolean.TRUE.equals(row[0])) {
            throw new ApiException(ErrorCode.CONFLICT, "BOM 结构存在循环引用，禁止计算物料需求");
        }
        if (Boolean.TRUE.equals(row[1])) {
            throw new ApiException(ErrorCode.CONFLICT, "BOM 结构超过 10 层，禁止按截断结果排产");
        }
    }

    private static BigDecimal decimal(Object value) {
        if (value == null) return BigDecimal.ZERO;
        if (value instanceof BigDecimal decimal) return decimal;
        return new BigDecimal(value.toString());
    }

    private static LocalDate localDate(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate date) return date;
        if (value instanceof java.sql.Date date) return date.toLocalDate();
        throw new ApiException(ErrorCode.CONFLICT, "MRP 日期字段类型异常");
    }
}
