package com.uten.imp.features.production.mrp;

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
import com.uten.imp.features.purchase.request.PurchaseRequest;
import com.uten.imp.features.purchase.request.PurchaseRequestItem;
import com.uten.imp.features.purchase.request.PurchaseRequestItemRepository;
import com.uten.imp.features.purchase.request.PurchaseRequestRepository;
import com.uten.imp.features.stock.StockDocument;
import com.uten.imp.features.stock.StockDocumentItem;
import com.uten.imp.features.stock.StockDocumentItemRepository;
import com.uten.imp.features.stock.StockDocumentRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * MRP-lite：生产计划 → BOM 展开物料需求 → 一键生成采购申请（业务联动核心）。
 *
 * <p>口径（design doc 37）：
 * <ol>
 *   <li>毛需求：计划明细排产量 × BOM 递归展开（goods_bom_items，≤10 层、路径防环），
 *       按货品聚合（颜色取需求最大贡献行参考色，净需求按货品级计算）。</li>
 *   <li>净需求 = 毛需求 − 即时库存（stock_balances 全仓合计）− 在途订货
 *       （已审采购订货单 数量−已收数量），小于 0 归 0。</li>
 *   <li>半成品（本身有 BOM 的组件）标记「自制」，只做预览不进采购申请。</li>
 *   <li>生成：一张采购申请（草稿，单号走 CS 序列），明细挂 production_plan_no 溯源；
 *       mrp_generations 记录联动，防重复生成（未删且未红冲的生成单存在即拒绝，
 *       申请被删/红冲后可再生成，旧联动软删留痕）。</li>
 * </ol>
 */
@Service
@RequiredArgsConstructor
public class MrpService {

    /** 毛需求展开 + 净需求 SQL（一次性算完，行数=物料种数，规模可控）。 */
    private static final String MRP_SQL = """
            WITH RECURSIVE exp AS (
                SELECT b.component_goods_id AS goods_id, b.color_legacy_id,
                       (i.qty * COALESCE(i.unit_rate,1) * b.qty)::numeric AS req_qty, 1 AS lvl, ARRAY[b.id]::uuid[] AS path
                FROM production_plan_items i
                JOIN goods_bom_items b ON b.goods_id = i.goods_id AND b.is_deleted = false
                WHERE i.plan_id = :planId AND i.is_deleted = false
                UNION ALL
                SELECT b.component_goods_id, b.color_legacy_id,
                       (e.req_qty * b.qty)::numeric, e.lvl + 1, e.path || b.id
                FROM exp e
                JOIN goods_bom_items b ON b.goods_id = e.goods_id AND b.is_deleted = false
                WHERE e.lvl < 10 AND NOT b.id = ANY(e.path)
            ),
            agg AS (
                SELECT e.goods_id,
                       (array_agg((SELECT c.id FROM colors c WHERE c.legacy_id = e.color_legacy_id)
                                  ORDER BY e.req_qty DESC))[1] AS color_id,
                       SUM(e.req_qty) AS gross,
                       bool_or(EXISTS (SELECT 1 FROM goods_bom_items c
                                       WHERE c.goods_id = e.goods_id AND c.is_deleted = false)) AS has_bom
                FROM exp e GROUP BY e.goods_id
            )
            SELECT a.goods_id, g.code, g.name, g.spec, a.color_id, a.gross,
                   COALESCE(sb.onhand, 0) AS onhand, COALESCE(po.openqty, 0) AS openqty,
                   GREATEST(a.gross - COALESCE(sb.onhand, 0) - COALESCE(po.openqty, 0), 0) AS net,
                   a.has_bom, u.id AS unit_id, g.a_price
            FROM agg a
            JOIN goods g ON g.id = a.goods_id
            LEFT JOIN units u ON u.legacy_id = g.unit_legacy_id
            LEFT JOIN (SELECT goods_id, SUM(qty) AS onhand FROM stock_balances GROUP BY goods_id) sb
                   ON sb.goods_id = a.goods_id
            LEFT JOIN (SELECT oi.goods_id,
                              SUM(GREATEST(oi.qty - COALESCE(oi.received_qty, 0), 0)) AS openqty
                       FROM purchase_order_items oi
                       JOIN purchase_orders o ON o.id = oi.order_id
                       WHERE o.status = 1 AND o.is_deleted = false AND oi.is_deleted = false
                       GROUP BY oi.goods_id) po
                   ON po.goods_id = a.goods_id
            ORDER BY net DESC, g.code
            """;

    /** D3：销售订单行需求源（已审订单）的同构展开 SQL。 */
    private static final String MRP_ORDER_SQL = """
            WITH RECURSIVE exp AS (
                SELECT b.component_goods_id AS goods_id, b.color_legacy_id,
                       (i.qty * COALESCE(i.unit_rate,1) * b.qty)::numeric AS req_qty, 1 AS lvl, ARRAY[b.id]::uuid[] AS path
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id AND o.status = 1 AND o.is_deleted = false
                JOIN goods_bom_items b ON b.goods_id = i.goods_id AND b.is_deleted = false
                WHERE i.order_id = :orderId AND i.is_deleted = false
                UNION ALL
                SELECT b.component_goods_id, b.color_legacy_id,
                       (e.req_qty * b.qty)::numeric, e.lvl + 1, e.path || b.id
                FROM exp e
                JOIN goods_bom_items b ON b.goods_id = e.goods_id AND b.is_deleted = false
                WHERE e.lvl < 10 AND NOT b.id = ANY(e.path)
            ),
            agg AS (
                SELECT e.goods_id,
                       (array_agg((SELECT c.id FROM colors c WHERE c.legacy_id = e.color_legacy_id)
                                  ORDER BY e.req_qty DESC))[1] AS color_id,
                       SUM(e.req_qty) AS gross,
                       bool_or(EXISTS (SELECT 1 FROM goods_bom_items c
                                       WHERE c.goods_id = e.goods_id AND c.is_deleted = false)) AS has_bom
                FROM exp e GROUP BY e.goods_id
            )
            SELECT a.goods_id, g.code, g.name, g.spec, a.color_id, a.gross,
                   COALESCE(sb.onhand, 0) AS onhand, COALESCE(po.openqty, 0) AS openqty,
                   GREATEST(a.gross - COALESCE(sb.onhand, 0) - COALESCE(po.openqty, 0), 0) AS net,
                   a.has_bom, u.id AS unit_id, g.a_price
            FROM agg a
            JOIN goods g ON g.id = a.goods_id
            LEFT JOIN units u ON u.legacy_id = g.unit_legacy_id
            LEFT JOIN (SELECT goods_id, SUM(qty) AS onhand FROM stock_balances GROUP BY goods_id) sb
                   ON sb.goods_id = a.goods_id
            LEFT JOIN (SELECT oi.goods_id,
                              SUM(GREATEST(oi.qty - COALESCE(oi.received_qty, 0), 0)) AS openqty
                       FROM purchase_order_items oi
                       JOIN purchase_orders o ON o.id = oi.order_id
                       WHERE o.status = 1 AND o.is_deleted = false AND oi.is_deleted = false
                       GROUP BY oi.goods_id) po
                   ON po.goods_id = a.goods_id
            ORDER BY net DESC, g.code
            """;

    private final EntityManager em;
    private final ProductionPlanRepository planRepo;
    private final ProductionPlanItemRepository itemRepo;
    private final PurchaseRequestRepository requestRepo;
    private final PurchaseRequestItemRepository requestItemRepo;
    private final StockDocumentRepository stockDocRepo;
    private final StockDocumentItemRepository stockDocItemRepo;
    private final DocNumberService docNumberService;
    private final SecurityContextCurrentUser currentUser;

    /** 物料需求预览：全部物料行（含自制半成品标记）。 */
    @Transactional(readOnly = true)
    public List<MrpRow> preview(UUID planId) {
        requirePlan(planId);
        return explode(planId);
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
                    r[4] == null ? null : ((java.sql.Date) r[4]).toLocalDate(),
                    r[5] == null ? null : ((java.sql.Date) r[5]).toLocalDate(),
                    total, inbound, pct));
        }
        return out;
    }

    /** 子计划溯源行（含完工进度）。 */
    public record SubplanRef(UUID planId, String billNo, Short status, boolean closed,
                             LocalDate billDate, LocalDate deliveryDate, BigDecimal totalQty,
                             BigDecimal inboundQty, double percent) {
    }

    /** D3 订单物料分析（李主管）：从已审销售订单直接 BOM 展开（不必先建生产计划）。 */
    @Transactional(readOnly = true)
    public List<MrpRow> previewOrder(UUID orderId) {
        Object n = em.createNativeQuery(
                "SELECT COUNT(*) FROM sales_orders WHERE id=:id AND status=1 AND is_deleted=false")
                .setParameter("id", orderId).getSingleResult();
        if (((Number) n).intValue() == 0) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核的销售订货单可做物料分析");
        }
        return explodeOrder(orderId);
    }

    /** 生成采购申请：默认净需求（strategy=gross 时按毛需求）。 */
    @Transactional
    public MrpGenerateResult generate(UUID planId) {
        return generate(planId, "net");
    }

    /** 生成采购申请：净需求>0（strategy=gross 时毛需求>0）的外购物料 → 一张草稿申请；防重复生成。 */
    @Transactional
    public MrpGenerateResult generate(UUID planId, String strategy) {
        boolean grossMode = "gross".equalsIgnoreCase(strategy);
        ProductionPlan plan = requirePlan(planId);
        if (plan.getStatus() != null && plan.getStatus() == -1) {
            throw new ApiException(ErrorCode.BUSINESS, "已红冲的计划不可生成采购申请");
        }

        // 防重复：存在未删且未红冲的生成申请 → 拒绝（并发下靠 mrp_generations + 申请状态复查）
        var dup = em.createNativeQuery("""
                SELECT r.bill_no FROM mrp_generations g
                JOIN purchase_requests r ON r.id = g.request_id
                WHERE g.plan_id = :planId AND g.is_deleted = false
                  AND r.is_deleted = false AND r.status <> -1
                LIMIT 1
                """).setParameter("planId", planId).getResultList();
        if (!dup.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "本计划已生成过采购申请（" + dup.get(0) + "），如需重生成请先删除或红冲该申请");
        }

        List<MrpRow> rows = explode(planId);
        List<MrpRow> buy = rows.stream()
                .filter(r -> !r.selfMade()
                        && (grossMode ? r.gross() : r.net()) != null
                        && (grossMode ? r.gross() : r.net()).signum() > 0).toList();
        if (buy.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, grossMode
                    ? "无毛需求外购物料（或全部为自制件）"
                    : "无净需求外购物料（库存/在途已覆盖，或全部为自制件）");
        }

        LocalDate today = BusinessTime.today();
        PurchaseRequest r = new PurchaseRequest();
        r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.PURCHASE_REQUEST));
        r.setBillDate(today);
        r.setNeedDate(plan.getDeliveryDate());
        r.setApplicantId(currentUser.requireId());
        r.setMakerId(currentUser.requireEmployeeId());
        r.setRemark("生产计划 " + plan.getBillNo() + " 物料需求自动生成");
        r.setSourceDocNo(plan.getBillNo());
        r.setStatus((short) 0);
        requestRepo.save(r);

        BigDecimal total = BigDecimal.ZERO;
        int line = 0;
        for (MrpRow row : buy) {
            line++;
            PurchaseRequestItem it = new PurchaseRequestItem();
            it.setRequestId(r.getId());
            it.setBillNo(r.getBillNo());
            it.setBillDate(r.getBillDate());
            it.setLineNo(line);
            it.setGoodsId(row.goodsId());
            it.setColorId(row.colorId());
            it.setUnitId(row.unitId());
            it.setUnitRate(BigDecimal.ONE);
            it.setQty(grossMode ? row.gross() : row.net());
            it.setPrice(BigDecimal.ZERO);
            it.setAmountOriginal(BigDecimal.ZERO);
            it.setAmountLocal(BigDecimal.ZERO);
            it.setGiftQty(BigDecimal.ZERO);
            it.setDeliverDate(plan.getDeliveryDate());
            it.setProductionPlanNo(plan.getBillNo());
            it.setSourceDocNo(plan.getBillNo());
            it.setRemark(grossMode
                    ? "毛需求开单（不扣库存/在途）"
                    : "毛需求 " + row.gross().stripTrailingZeros().toPlainString()
                    + " − 库存 " + row.onhand().stripTrailingZeros().toPlainString()
                    + " − 在途 " + row.openPo().stripTrailingZeros().toPlainString());
            requestItemRepo.save(it);
        }
        r.setTotalOriginal(total);
        r.setTotalLocal(total);
        requestRepo.save(r);

        // 联动留痕：旧联动行软删（历史可追溯），插新行
        em.createNativeQuery("""
                UPDATE mrp_generations SET is_deleted = true, deleted_at = now()
                WHERE plan_id = :planId AND is_deleted = false
                """).setParameter("planId", planId).executeUpdate();
        em.createNativeQuery("""
                INSERT INTO mrp_generations (plan_id, request_id, created_by)
                VALUES (:planId, :requestId, :by)
                """).setParameter("planId", planId).setParameter("requestId", r.getId())
                .setParameter("by", currentUser.requireId()).executeUpdate();

        return new MrpGenerateResult(r.getId(), r.getBillNo(), line,
                rows.stream().filter(MrpRow::selfMade).map(MrpRow::goodsId).toList());
    }

    // ======================== 计划 → 生产领料单（DRAW） ========================

    /**
     * 生成生产领料单：全部 BOM 物料按<b>毛需求</b>开单（车间按排产领料，与采购按净需求互补），
     * 自制件同样列出（半成品也可能从仓库领）。plan_draw_links 防重复（规则同采购申请）。
     */
    @Transactional
    public MrpGenerateResult generateDraw(UUID planId, UUID warehouseId) {
        ProductionPlan plan = requirePlan(planId);
        if (plan.getStatus() != null && plan.getStatus() == -1) {
            throw new ApiException(ErrorCode.BUSINESS, "已红冲的计划不可生成领料单");
        }
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
        d.setWorkerId(currentUser.requireId());
        d.setMakerId(currentUser.requireEmployeeId());
        d.setStatus((short) 0);
        stockDocRepo.save(d);

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
     * 生成成品入库单：计划明细自身（非 BOM 展开），数量 = 排产量 − 已入库量（iqty），
     * 防重复与其他生成单同规则（plan_draw_links 按 doc_type 区分 DRAW / FINISHED_IN）。
     */
    @Transactional
    public MrpGenerateResult generateFinishedIn(UUID planId, UUID warehouseId) {
        ProductionPlan plan = requirePlan(planId);
        if (plan.getStatus() != null && plan.getStatus() == -1) {
            throw new ApiException(ErrorCode.BUSINESS, "已红冲的计划不可生成成品入库单");
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
                SELECT i.goods_id, i.color_id, i.unit_id,
                       GREATEST(COALESCE(i.qty,0) - COALESCE(i.iqty,0), 0) AS remain
                FROM production_plan_items i
                WHERE i.plan_id = :planId AND i.is_deleted = false
                ORDER BY i.line_no
                """).setParameter("planId", planId).getResultList();
        List<Object[]> lines = new java.util.ArrayList<>();
        for (Object x : itemRows) {
            Object[] r = (Object[]) x;
            if (r[3] != null && ((BigDecimal) r[3]).signum() > 0) lines.add(r);
        }
        if (lines.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "计划明细均已全部入库（或无明细），无可入库数量");
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
        d.setWorkerId(currentUser.requireId());
        d.setMakerId(currentUser.requireEmployeeId());
        d.setStatus((short) 0);
        stockDocRepo.save(d);

        int line = 0;
        for (Object[] r : lines) {
            line++;
            StockDocumentItem it = new StockDocumentItem();
            it.setDocId(d.getId());
            it.setBillType("FINISHED_IN");
            it.setBillNo(d.getBillNo());
            it.setBillDate(d.getBillDate());
            it.setLineNo(line);
            it.setGoodsId((UUID) r[0]);
            it.setColorId((UUID) r[1]);
            it.setUnitId((UUID) r[2]);
            it.setUnitRate(BigDecimal.ONE);
            it.setQty((BigDecimal) r[3]);
            it.setBaseQty((BigDecimal) r[3]);
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

    // ======================== 计划 → 自制件子计划（多层 BOM 逐级展开） ========================

    /**
     * 生成自制件子计划：BOM 展开后「自制件」（本身还有 BOM 的组件）按<b>净需求</b>开一张
     * 下层生产计划（草稿），交货日取父计划最早开工日（无则父计划交货日）。
     * 多层 BOM：子计划的 MRP 面板可继续向下生成，逐级展开。
     * subplan_links 防重复（规则同采购申请/领料单：子计划删/红冲后可再生成，旧联动软删留痕）。
     *
     * <p>口径说明：展开是全层级一次性展开，下层零件的毛需求按上层全部自制折算，
     * 不扣中间层自制件库存（与采购申请同口径，偏保守多备）。
     */
    @Transactional
    public MrpGenerateResult generateSubplan(UUID planId) {
        ProductionPlan plan = requirePlan(planId);
        if (plan.getStatus() != null && plan.getStatus() == -1) {
            throw new ApiException(ErrorCode.BUSINESS, "已红冲的计划不可生成子计划");
        }
        var dup = em.createNativeQuery("""
                SELECT p.bill_no FROM subplan_links l
                JOIN production_plans p ON p.id = l.subplan_id
                WHERE l.plan_id = :planId AND l.is_deleted = false
                  AND p.is_deleted = false AND p.status <> -1
                LIMIT 1
                """).setParameter("planId", planId).getResultList();
        if (!dup.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "本计划已生成过子计划（" + dup.get(0) + "），如需重生成请先删除或红冲该子计划");
        }

        List<MrpRow> make = explode(planId).stream()
                .filter(r -> r.selfMade() && r.net() != null && r.net().signum() > 0)
                .toList();
        if (make.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "无净需求自制件（库存/在途已覆盖，或明细货品没有多层 BOM）");
        }

        // 子计划交货日：父计划最早开工日（零件要先于成品投产），无开工日则取父计划交货日
        Object begin = em.createNativeQuery("""
                SELECT MIN(plan_begin_date) FROM production_plan_items
                WHERE plan_id = :planId AND is_deleted = false
                """).setParameter("planId", planId).getSingleResult();
        LocalDate subDelivery = begin != null
                ? ((java.sql.Date) begin).toLocalDate() : plan.getDeliveryDate();

        LocalDate today = BusinessTime.today();
        ProductionPlan sub = new ProductionPlan();
        // 子计划编号 = 父计划号-N（编号体系内一眼看出归属，如 SJ26070078-1）
        sub.setBillNo(plan.getBillNo() + "-" + nextSubSuffix(plan.getBillNo()));
        sub.setBillDate(today);
        sub.setDeliveryDate(subDelivery);
        sub.setDepartmentId(plan.getDepartmentId());
        sub.setWorkshopName(plan.getWorkshopName());
        sub.setRemark("父计划 " + plan.getBillNo() + " 自制件按净需求自动生成");
        sub.setSourceDocNo(plan.getBillNo());
        sub.setMakerId(currentUser.requireEmployeeId());
        sub.setStatus((short) 0);
        planRepo.save(sub);

        int line = 0;
        for (MrpRow row : make) {
            line++;
            ProductionPlanItem it = new ProductionPlanItem();
            it.setPlanId(sub.getId());
            it.setBillNo(sub.getBillNo());
            it.setBillDate(sub.getBillDate());
            it.setLineNo(line);
            it.setProductNo(sub.getBillNo() + "-" + line);
            it.setGoodsId(row.goodsId());
            it.setColorId(row.colorId());
            it.setUnitId(row.unitId());
            it.setUnitRate(BigDecimal.ONE); // MRP 展开行已是基本单位口径
            it.setQty(row.net());
            it.setOqty(row.gross());
            it.setSourceDocNo(plan.getBillNo());
            it.setRemark("毛需求 " + row.gross().stripTrailingZeros().toPlainString()
                    + " − 库存 " + row.onhand().stripTrailingZeros().toPlainString()
                    + " − 在途 " + row.openPo().stripTrailingZeros().toPlainString());
            itemRepo.save(it);
        }

        // 联动留痕：旧联动行软删（历史可追溯），插新行
        em.createNativeQuery("""
                UPDATE subplan_links SET is_deleted = true, deleted_at = now()
                WHERE plan_id = :planId AND is_deleted = false
                """).setParameter("planId", planId).executeUpdate();
        em.createNativeQuery("""
                INSERT INTO subplan_links (plan_id, subplan_id, created_by)
                VALUES (:planId, :subplanId, :by)
                """).setParameter("planId", planId).setParameter("subplanId", sub.getId())
                .setParameter("by", currentUser.requireId()).executeUpdate();

        return new MrpGenerateResult(sub.getId(), sub.getBillNo(), line, List.of());
    }

    /**
     * 按车间拆分生成子计划（可定制化）：用户自选自制件行 + 各自数量 + 归属车间，
     * 按车间分组各生成一张草稿计划。允许多轮生成（如先开注塑车间、后开装配车间），
     * 防超产硬校验：每 货品+颜色 累计子计划量 ≤ MRP 净需求。
     */
    @Transactional
    public List<GenerateSubplansRequest.Created> generateSubplans(UUID planId, GenerateSubplansRequest req) {
        ProductionPlan plan = requirePlan(planId);
        if (plan.getStatus() != null && plan.getStatus() == -1) {
            throw new ApiException(ErrorCode.BUSINESS, "已红冲的计划不可生成子计划");
        }
        // 净需求 + 毛需求/库存/在途 按 货品|颜色 建索引（仅自制件允许拆）
        record Key(UUID g, UUID c) {}
        Map<Key, MrpRow> netByKey = new LinkedHashMap<>();
        for (MrpRow r : explode(planId)) {
            if (r.selfMade()) netByKey.put(new Key(r.goodsId(), r.colorId()), r);
        }
        // 已有子计划累计量（未删联动 + 未删未红冲子计划）
        Map<Key, BigDecimal> usedByKey = new HashMap<>();
        for (Object o : em.createNativeQuery("""
                SELECT i.goods_id, i.color_id, COALESCE(SUM(i.qty),0)
                FROM subplan_links l
                JOIN production_plans sp ON sp.id = l.subplan_id AND sp.is_deleted = false AND sp.status <> -1
                JOIN production_plan_items i ON i.plan_id = sp.id AND i.is_deleted = false
                WHERE l.plan_id = :planId AND l.is_deleted = false
                GROUP BY i.goods_id, i.color_id
                """).setParameter("planId", planId).getResultList()) {
            Object[] r = (Object[]) o;
            usedByKey.put(new Key((UUID) r[0], (UUID) r[1]), (BigDecimal) r[2]);
        }
        // 逐行校验 + 归组
        Map<String, List<GenerateSubplansRequest.Line>> byWorkshop = new LinkedHashMap<>();
        Map<String, String> workshopNames = new LinkedHashMap<>();
        Map<Key, BigDecimal> requested = new HashMap<>();
        for (GenerateSubplansRequest.Line line : req.getItems()) {
            Key k = new Key(line.getGoodsId(), line.getColorId());
            MrpRow row = netByKey.get(k);
            if (row == null) {
                throw new ApiException(ErrorCode.BUSINESS, "所选货品不是本计划的自制件需求行: " + line.getGoodsId());
            }
            BigDecimal cap = (row.net() == null ? BigDecimal.ZERO : row.net())
                    .subtract(usedByKey.getOrDefault(k, BigDecimal.ZERO))
                    .subtract(requested.getOrDefault(k, BigDecimal.ZERO));
            if (line.getQty().compareTo(cap) > 0) {
                throw new ApiException(ErrorCode.BUSINESS,
                        "货品 " + row.goodsCode() + " 排产量超过可拆量（净需求扣减已有子计划后剩 "
                                + cap.stripTrailingZeros().toPlainString() + "）");
            }
            requested.merge(k, line.getQty(), BigDecimal::add);
            String wk = line.getDepartmentId() == null ? "" : line.getDepartmentId().toString();
            byWorkshop.computeIfAbsent(wk, x -> new ArrayList<>()).add(line);
            if (line.getWorkshopName() != null && !line.getWorkshopName().isBlank()) {
                workshopNames.putIfAbsent(wk, line.getWorkshopName());
            }
        }

        LocalDate today = BusinessTime.today();
        Object begin = em.createNativeQuery("""
                SELECT MIN(plan_begin_date) FROM production_plan_items
                WHERE plan_id = :planId AND is_deleted = false
                """).setParameter("planId", planId).getSingleResult();
        LocalDate subDelivery = begin != null
                ? ((java.sql.Date) begin).toLocalDate() : plan.getDeliveryDate();

        List<GenerateSubplansRequest.Created> created = new ArrayList<>();
        int suffix = nextSubSuffix(plan.getBillNo());
        for (var e : byWorkshop.entrySet()) {
            String wk = e.getKey();
            String wsName = workshopNames.get(wk);
            UUID deptId = wk.isEmpty() ? null : UUID.fromString(wk);
            if (wsName == null && deptId != null) {
                wsName = str(em.createNativeQuery("SELECT name FROM departments WHERE id = :d")
                        .setParameter("d", deptId).getSingleResult());
            }
            ProductionPlan sub = new ProductionPlan();
            // 子计划编号 = 父计划号-N（按创建顺序递增）
            sub.setBillNo(plan.getBillNo() + "-" + suffix++);
            sub.setBillDate(today);
            sub.setDeliveryDate(subDelivery);
            sub.setDepartmentId(deptId);
            sub.setWorkshopName(wsName);
            sub.setRemark("父计划 " + plan.getBillNo() + " 自制件拆分生成");
            sub.setSourceDocNo(plan.getBillNo());
            sub.setMakerId(currentUser.requireEmployeeId());
            sub.setStatus((short) 0);
            planRepo.save(sub);

            int line = 0;
            for (GenerateSubplansRequest.Line l : e.getValue()) {
                line++;
                MrpRow row = netByKey.get(new Key(l.getGoodsId(), l.getColorId()));
                ProductionPlanItem it = new ProductionPlanItem();
                it.setPlanId(sub.getId());
                it.setBillNo(sub.getBillNo());
                it.setBillDate(sub.getBillDate());
                it.setLineNo(line);
                it.setProductNo(sub.getBillNo() + "-" + line);
                it.setGoodsId(l.getGoodsId());
                it.setColorId(l.getColorId());
                it.setUnitId(l.getUnitId());
                it.setUnitRate(BigDecimal.ONE); // MRP 展开行已是基本单位口径
                it.setQty(l.getQty());
                it.setOqty(row.gross());
                it.setSourceDocNo(plan.getBillNo());
                it.setRemark("毛需求 " + row.gross().stripTrailingZeros().toPlainString()
                        + " − 库存 " + row.onhand().stripTrailingZeros().toPlainString()
                        + " − 在途 " + row.openPo().stripTrailingZeros().toPlainString());
                itemRepo.save(it);
            }
            em.createNativeQuery("""
                    INSERT INTO subplan_links (plan_id, subplan_id, created_by)
                    VALUES (:planId, :subplanId, :by)
                    """).setParameter("planId", planId).setParameter("subplanId", sub.getId())
                    .setParameter("by", currentUser.requireId()).executeUpdate();
            created.add(new GenerateSubplansRequest.Created(
                    sub.getId(), sub.getBillNo(), line, wsName));
        }
        return created;
    }

    private static String str(Object v) {
        return v == null ? null : v.toString();
    }

    /** 子计划编号后缀：父计划已有子计划（含已删，防号冲突）的最大 -N + 1。 */
    private int nextSubSuffix(String parentBillNo) {
        Object v = em.createNativeQuery("""
                SELECT COALESCE(MAX(CAST(split_part(bill_no, '-', 2) AS int)), 0)
                FROM production_plans
                WHERE bill_no LIKE :p || '-%'
                  AND split_part(bill_no, '-', 2) ~ '^[0-9]+$'
                """).setParameter("p", parentBillNo).getSingleResult();
        return ((Number) v).intValue() + 1;
    }

    // ======================== 内部 ========================
    private ProductionPlan requirePlan(UUID planId) {
        return planRepo.findById(planId).filter(p -> !p.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "生产计划不存在"));
    }

    private List<MrpRow> explode(UUID planId) {
        return runExplode(MRP_SQL, "planId", planId);
    }

    /** D3：销售订单行 BOM 展开（同 MRP_SQL，仅需求源换成已审订单行 qty）。 */
    private List<MrpRow> explodeOrder(UUID orderId) {
        return runExplode(MRP_ORDER_SQL, "orderId", orderId);
    }

    private List<MrpRow> runExplode(String sql, String param, UUID id) {
        var q = em.createNativeQuery(sql).setParameter(param, id);
        List<Object[]> rs = NativeQueryResults.objectArrayRows(q);
        List<MrpRow> out = new ArrayList<>(rs.size());
        for (Object[] x : rs) {
            out.add(new MrpRow(
                    (UUID) x[0], (String) x[1], (String) x[2], (String) x[3],
                    (UUID) x[4], (BigDecimal) x[5], (BigDecimal) x[6], (BigDecimal) x[7],
                    (BigDecimal) x[8], Boolean.TRUE.equals(x[9]), (UUID) x[10]));
        }
        return out;
    }
}
