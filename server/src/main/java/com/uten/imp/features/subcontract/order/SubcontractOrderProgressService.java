package com.uten.imp.features.subcontract.order;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.CommercialPriceVisibility;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts.IssueDoc;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts.MaterialPlanLine;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts.OrderProgress;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts.ReceiptDoc;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts.ReturnDoc;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts.SupplierLedgerLine;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts.WasteDoc;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.sql.Timestamp;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.UUID;

/**
 * 委外订货单全链路进度聚合（V304 · 委外全链路重设计）。
 *
 * <p>委外模块只留订货单 + 进度：财务审批状态 → 发料计划/出仓单 → 进仓单/IQC →
 * 退货/损耗 → 供应商处材料台账 → 应付摘要，一次聚合返回，供订货单详情进度区渲染。
 * 委外视角按订货单归属可读；仓库不调用本接口（仓库有自己的出仓/到货工作台）。
 */
@Service
@RequiredArgsConstructor
public class SubcontractOrderProgressService {

    private final EntityManager em;
    private final SubcontractOrderRepository orderRepo;
    private final SubcontractDocumentAccessPolicy access;
    private final com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService materialPlans;

    @Autowired
    private CommercialPriceVisibility commercialPriceVisibility;

    @Transactional(readOnly = true)
    public OrderProgress progress(UUID orderId) {
        SubcontractOrder order = orderRepo.findById(orderId)
                .filter(o -> !o.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "委外订货单不存在"));
        access.requireReadable(order.getMakerId(), "委外订货单不存在");

        // 财务审批 case（最近一次 attempt）
        String financeStatus = null;
        OffsetDateTime financeDecidedAt = null;
        List<Object[]> cases = query("""
                SELECT status, decided_at FROM procurement_order_approval_cases
                WHERE order_type = 'SUBCONTRACT' AND order_id = :id
                ORDER BY attempt DESC LIMIT 1
                """, orderId);
        if (!cases.isEmpty()) {
            financeStatus = (String) cases.getFirst()[0];
            financeDecidedAt = toOffset(cases.getFirst()[1]);
        }

        // 发料计划
        String planStatus = null;
        String planCloseReason = null;
        UUID planId = null;
        List<Object[]> plans = query("""
                SELECT id, status, close_reason FROM subcontract_material_plans
                WHERE order_id = :id AND is_deleted = FALSE
                """, orderId);
        if (!plans.isEmpty()) {
            planId = (UUID) plans.getFirst()[0];
            planStatus = (String) plans.getFirst()[1];
            planCloseReason = (String) plans.getFirst()[2];
        }

        boolean canOpenPreparationAnalysis =
                access.hasAuthority("production_material_analysis:view");
        List<MaterialPlanLine> materialLines = planId == null ? List.of() : queryRows("""
                SELECT pi.id, pg.code, pg.name, g.code, g.name, c.name, u.name,
                       pi.bom_unit_qty, pi.planned_qty, pi.issued_qty,
                       COALESCE((SELECT SUM(ii.qty) FROM subcontract_material_issue_items ii
                                 JOIN subcontract_material_issues i ON i.id = ii.issue_id
                                 WHERE ii.plan_item_id = pi.id AND i.status = 0 AND i.is_deleted = FALSE), 0),
                       pi.flow_mode, effective.status, pi.prepared_qty,
                       GREATEST(LEAST(pi.planned_qty, pi.prepared_qty)
                           - pi.issued_qty - COALESCE((
                               SELECT SUM(ii.qty)
                               FROM subcontract_material_issue_items ii
                               JOIN subcontract_material_issues i ON i.id = ii.issue_id
                               WHERE ii.plan_item_id = pi.id
                                 AND i.status = 0 AND i.is_deleted = FALSE), 0), 0),
                       GREATEST(pi.planned_qty - pi.issued_qty, 0),
                       pi.preparation_analysis_id, pi.preparation_analysis_item_id,
                       pi.bom_has_children_snapshot
                FROM subcontract_material_plan_items pi
                JOIN goods pg ON pg.id = pi.parent_goods_id
                JOIN goods g ON g.id = pi.goods_id
                LEFT JOIN colors c ON c.id = pi.color_id
                LEFT JOIN units u ON u.id = pi.unit_id
                CROSS JOIN LATERAL (
                    SELECT CASE
                        WHEN pi.preparation_status <> 'IN_PREPARATION'
                            THEN pi.preparation_status
                        WHEN EXISTS (
                            SELECT 1
                            FROM production_plans production_plan
                            JOIN production_plan_items production_item
                              ON production_item.plan_id = production_plan.id
                             AND production_item.is_deleted = FALSE
                            JOIN production_fqc_inspections inspection
                              ON inspection.source_plan_item_id = production_item.id
                             AND inspection.status <> 'CANCELLED'
                             AND inspection.passed_qty > 0
                            WHERE production_plan.material_analysis_id =
                                      pi.preparation_analysis_id
                              AND production_plan.material_analysis_item_id =
                                      pi.preparation_analysis_item_id
                              AND production_plan.is_deleted = FALSE
                        ) OR EXISTS (
                            SELECT 1
                            FROM production_plans production_plan
                            JOIN plan_draw_links finished_link
                              ON finished_link.plan_id = production_plan.id
                             AND finished_link.is_deleted = FALSE
                            JOIN stock_documents finished_in
                              ON finished_in.id = finished_link.draw_id
                             AND finished_in.doc_type = 'FINISHED_IN'
                             AND finished_in.status = 0
                             AND finished_in.is_deleted = FALSE
                            WHERE production_plan.material_analysis_id =
                                      pi.preparation_analysis_id
                              AND production_plan.material_analysis_item_id =
                                      pi.preparation_analysis_item_id
                              AND production_plan.is_deleted = FALSE
                        ) THEN 'WAITING_INBOUND'
                        WHEN EXISTS (
                            SELECT 1
                            FROM production_plans production_plan
                            JOIN production_plan_items production_item
                              ON production_item.plan_id = production_plan.id
                             AND production_item.is_deleted = FALSE
                            JOIN production_daily_report_items report_item
                              ON report_item.plan_item_id = production_item.id
                             AND report_item.is_deleted = FALSE
                            JOIN production_daily_reports report
                              ON report.id = report_item.report_id
                             AND report.status = 1
                             AND report.is_deleted = FALSE
                            WHERE production_plan.material_analysis_id =
                                      pi.preparation_analysis_id
                              AND production_plan.material_analysis_item_id =
                                      pi.preparation_analysis_item_id
                              AND production_plan.is_deleted = FALSE
                        ) THEN 'WAITING_FQC'
                        ELSE 'IN_PREPARATION'
                    END AS status
                ) effective
                WHERE pi.plan_id = :id AND pi.is_deleted = FALSE
                ORDER BY pi.line_no ASC NULLS LAST, pi.id
                """, orderIdParam(planId)).stream()
                .map(row -> new MaterialPlanLine(
                        (UUID) row[0], (String) row[1], (String) row[2],
                        (String) row[3], (String) row[4], (String) row[5], (String) row[6],
                        bd(row[7]), bd(row[8]), bd(row[9]), bd(row[10]),
                        (String) row[11], (String) row[12], bd(row[13]), bd(row[14]),
                        bd(row[15]), (UUID) row[16], (UUID) row[17],
                        Boolean.TRUE.equals(row[18]),
                        preparationBlocker((String) row[12]),
                        preparationActions((String) row[12], (UUID) row[16],
                                canOpenPreparationAnalysis)))
                .toList();

        if(planId==null && order.getStatus()!=null && order.getStatus()==0){
            var shortage=materialPlans.draftChildrenShortageByOrderItem(orderId);
            materialLines=queryRows("""
                    SELECT item.id,goods.code,goods.name,color.name,unit.name,item.unit_rate,round(item.qty*COALESCE(item.unit_rate,1),4),
                           preparation.analysis_id,preparation.id,
                           EXISTS(SELECT 1 FROM goods_bom_items bom WHERE bom.goods_id=item.goods_id AND bom.is_deleted=FALSE),
                           EXISTS(SELECT 1 FROM production_plans plan WHERE plan.material_analysis_id=preparation.analysis_id
                             AND plan.material_analysis_item_id=preparation.id AND plan.is_deleted=FALSE AND plan.is_canceled=FALSE)
                    FROM subcontract_order_items item JOIN goods ON goods.id=item.goods_id
                    LEFT JOIN colors color ON color.id=item.color_id LEFT JOIN units unit ON unit.id=goods.unit_id
                    LEFT JOIN LATERAL(SELECT source.id,source.analysis_id FROM production_material_analysis_items source
                        JOIN production_material_analyses analysis ON analysis.id=source.analysis_id
                        WHERE source.subcontract_order_item_id=item.id AND source.is_deleted=FALSE AND analysis.is_deleted=FALSE
                          AND analysis.status<>'CANCELLED' ORDER BY source.created_at DESC,source.id LIMIT 1) preparation ON TRUE
                    WHERE item.order_id=:id AND item.is_deleted=FALSE AND item.application_item_id IS NULL ORDER BY item.line_no,item.id
                    """,orderIdParam(orderId)).stream().map(row->{
                        BigDecimal required=bd(row[6]),missing=shortage.getOrDefault((UUID)row[0],BigDecimal.ZERO);
                        String status=missing.signum()==0?"READY_FOR_FINANCE":Boolean.TRUE.equals(row[10])?"IN_PREPARATION":"WAITING_PLAN";
                        return new MaterialPlanLine((UUID)row[0],(String)row[1],(String)row[2],(String)row[1],(String)row[2],(String)row[3],(String)row[4],
                                bd(row[5]),required,BigDecimal.ZERO,BigDecimal.ZERO,"DRAFT_PREPARATION",status,required.subtract(missing),BigDecimal.ZERO,missing,
                                (UUID)row[7],(UUID)row[8],Boolean.TRUE.equals(row[9]),missing.signum()==0?null:"目标件缺口 "+missing.stripTrailingZeros().toPlainString()+"，待计划完成生产并由仓库实收入库后提交财务",
                                preparationActions(status,(UUID)row[7],canOpenPreparationAnalysis));
                    }).toList();
        }

        // 出仓单（本订货单全部发料单）
        List<IssueDoc> issues = queryRows("""
                SELECT DISTINCT i.id, i.bill_no, i.status, i.bill_date, w.name, i.approver_name,
                       (SELECT SUM(ii.qty) FROM subcontract_material_issue_items ii WHERE ii.issue_id = i.id),
                       i.updated_at
                FROM subcontract_material_issues i
                LEFT JOIN warehouses w ON w.id = i.warehouse_id
                WHERE i.is_deleted = FALSE AND EXISTS (
                    SELECT 1 FROM subcontract_material_issue_items ii
                    JOIN subcontract_order_items oi ON oi.id = ii.order_item_id
                    WHERE ii.issue_id = i.id AND oi.order_id = :id)
                ORDER BY i.bill_date DESC NULLS LAST, i.id
                """, orderIdParam(orderId)).stream()
                .map(row -> new IssueDoc(
                        (UUID) row[0], (String) row[1], (Short) row[2],
                        toDate(row[3]), (String) row[4], (String) row[5],
                        bd(row[6]), toOffset(row[7])))
                .toList();

        // 进仓单 + IQC 聚合状态
        List<ReceiptDoc> receipts = queryRows("""
                SELECT r.id, r.bill_no, r.status, r.bill_date, w.name, r.approver_name,
                       (SELECT SUM(ri.qty) FROM subcontract_receipt_items ri WHERE ri.receipt_id = r.id),
                       r.total_local,
                       iqc.iqc_status,
                       iqc.warehouse_stock_in_status,
                       iqc.passed_base_qty,
                       iqc.warehouse_stocked_base_qty,
                       iqc.pending_stock_in_base_qty,
                       r.updated_at
                FROM subcontract_receipts r
                LEFT JOIN warehouses w ON w.id = r.warehouse_id
                LEFT JOIN LATERAL (
                    SELECT CASE
                               WHEN COUNT(*) = 0 THEN NULL
                               WHEN COUNT(*) FILTER (
                                   WHERE iq.status IN ('PENDING','PARTIAL')) > 0
                                   THEN 'PENDING'
                               WHEN COUNT(*) FILTER (
                                   WHERE iq.status = 'RESOLVED') = COUNT(*)
                                   THEN 'RESOLVED'
                               WHEN COUNT(*) FILTER (
                                   WHERE iq.status = 'REVERSED') = COUNT(*)
                                   THEN 'REVERSED'
                               ELSE 'PARTIAL'
                           END AS iqc_status,
                           CASE
                               WHEN COUNT(*) = 0 THEN NULL
                               WHEN COUNT(*) FILTER (
                                   WHERE iq.status = 'REVERSED') = COUNT(*)
                                   THEN 'REVERSED'
                               WHEN COALESCE(SUM(iq.warehouse_stocked_base_qty),0) > 0
                                    AND (
                                        COALESCE(SUM(iq.passed_base_qty),0)
                                            > COALESCE(SUM(iq.warehouse_stocked_base_qty),0)
                                        OR COUNT(*) FILTER (
                                            WHERE iq.status IN ('PENDING','PARTIAL')) > 0
                                    )
                                   THEN 'PARTIAL_STOCK_IN'
                               WHEN COALESCE(SUM(iq.passed_base_qty),0)
                                    > COALESCE(SUM(iq.warehouse_stocked_base_qty),0)
                                   THEN 'PENDING_STOCK_IN'
                               WHEN COALESCE(SUM(iq.passed_base_qty),0) = 0
                                    AND COUNT(*) FILTER (
                                        WHERE iq.status IN ('PENDING','PARTIAL')) > 0
                                   THEN 'WAITING_QUALITY'
                               WHEN COALESCE(SUM(iq.passed_base_qty),0) = 0
                                   THEN 'NO_QUALIFIED_STOCK'
                               WHEN COALESCE(SUM(iq.passed_base_qty),0)
                                    = COALESCE(SUM(iq.warehouse_stocked_base_qty),0)
                                   THEN 'STOCKED'
                               ELSE 'PENDING_STOCK_IN'
                           END AS warehouse_stock_in_status,
                           COALESCE(SUM(iq.passed_base_qty),0) AS passed_base_qty,
                           COALESCE(SUM(iq.warehouse_stocked_base_qty),0)
                               AS warehouse_stocked_base_qty,
                           GREATEST(
                               COALESCE(SUM(iq.passed_base_qty),0)
                               - COALESCE(SUM(iq.warehouse_stocked_base_qty),0),
                               0) AS pending_stock_in_base_qty
                    FROM procurement_inspection_items iq
                    WHERE iq.receipt_type = 'SUBCONTRACT'
                      AND iq.receipt_id = r.id
                ) iqc ON TRUE
                WHERE r.is_deleted = FALSE AND EXISTS (
                    SELECT 1 FROM subcontract_receipt_items ri
                    JOIN subcontract_order_items oi ON oi.id = ri.order_item_id
                    WHERE ri.receipt_id = r.id AND oi.order_id = :id)
                ORDER BY r.bill_date DESC NULLS LAST, r.id
                """, orderIdParam(orderId)).stream()
                .map(row -> new ReceiptDoc(
                        (UUID) row[0], (String) row[1], (Short) row[2],
                        toDate(row[3]), (String) row[4], (String) row[5],
                        bd(row[6]), bd(row[7]), (String) row[8], (String) row[9],
                        bd(row[10]), bd(row[11]), bd(row[12]), toOffset(row[13])))
                .toList();

        // 成品退货单
        List<ReturnDoc> returns = queryRows("""
                SELECT r.id, r.bill_no, r.status, r.bill_date,
                       (SELECT SUM(ri.qty) FROM subcontract_return_items ri WHERE ri.return_id = r.id),
                       r.total_local
                FROM subcontract_returns r
                WHERE r.is_deleted = FALSE AND EXISTS (
                    SELECT 1 FROM subcontract_return_items ri
                    JOIN subcontract_order_items oi ON oi.id = ri.order_item_id
                    WHERE ri.return_id = r.id AND oi.order_id = :id)
                ORDER BY r.bill_date DESC NULLS LAST, r.id
                """, orderIdParam(orderId)).stream()
                .map(row -> new ReturnDoc(
                        (UUID) row[0], (String) row[1], (Short) row[2],
                        toDate(row[3]), bd(row[4]), bd(row[5])))
                .toList();

        // 损耗单（含扣款）
        List<WasteDoc> wastes = queryRows("""
                SELECT wst.id, wst.bill_no, wst.status, wst.bill_date,
                       (SELECT SUM(wi.qty) FROM subcontract_waste_items wi WHERE wi.waste_id = wst.id),
                       wst.deduct_amount, wst.deduct_posted
                FROM subcontract_wastes wst
                WHERE wst.is_deleted = FALSE AND EXISTS (
                    SELECT 1 FROM subcontract_waste_items wi
                    JOIN subcontract_material_issue_items ii ON ii.id = wi.material_issue_item_id
                    JOIN subcontract_order_items oi ON oi.id = ii.order_item_id
                    WHERE wi.waste_id = wst.id AND oi.order_id = :id)
                ORDER BY wst.bill_date DESC NULLS LAST, wst.id
                """, orderIdParam(orderId)).stream()
                .map(row -> new WasteDoc(
                        (UUID) row[0], (String) row[1], (Short) row[2],
                        toDate(row[3]), bd(row[4]), bd(row[5]), (Boolean) row[6]))
                .toList();

        // 供应商处材料台账（按子件聚合，V221 守恒口径；仅本订货单已审出仓行）
        List<SupplierLedgerLine> supplierLedger = queryRows("""
                SELECT g.code, g.name, c.name, u.name,
                       SUM(ii.at_supplier_qty), SUM(ii.consumed_qty),
                       SUM(COALESCE(ii.returned_qty, 0)), SUM(COALESCE(ii.wasted_qty, 0)),
                       SUM(ii.at_supplier_qty - ii.consumed_qty
                           - COALESCE(ii.returned_qty, 0) - COALESCE(ii.wasted_qty, 0))
                FROM subcontract_material_issue_items ii
                JOIN subcontract_material_issues i ON i.id = ii.issue_id
                JOIN subcontract_order_items oi ON oi.id = ii.order_item_id
                JOIN goods g ON g.id = ii.goods_id
                LEFT JOIN colors c ON c.id = ii.color_id
                LEFT JOIN units u ON u.id = ii.unit_id
                WHERE oi.order_id = :id AND i.status = 1 AND i.is_deleted = FALSE
                  AND ii.at_supplier_qty > 0
                GROUP BY g.code, g.name, c.name, u.name
                ORDER BY g.code
                """, orderIdParam(orderId)).stream()
                .map(row -> new SupplierLedgerLine(
                        (String) row[0], (String) row[1], (String) row[2], (String) row[3],
                        bd(row[4]), bd(row[5]), bd(row[6]), bd(row[7]), bd(row[8])))
                .toList();

        // 应付摘要：已审进仓加工费 − 已审成品退货；损耗扣款（deduct_posted）
        BigDecimal apPosted = receipts.stream()
                .filter(r -> r.status() != null && r.status() == 1)
                .map(r -> r.totalLocal() == null ? BigDecimal.ZERO : r.totalLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add)
                .subtract(returns.stream()
                        .filter(r -> r.status() != null && r.status() == 1)
                        .map(r -> r.totalLocal() == null ? BigDecimal.ZERO : r.totalLocal().abs())
                        .reduce(BigDecimal.ZERO, BigDecimal::add));
        BigDecimal wasteDeduct = wastes.stream()
                .filter(w -> Boolean.TRUE.equals(w.deductPosted()))
                .map(w -> w.deductAmount() == null ? BigDecimal.ZERO : w.deductAmount())
                .reduce(BigDecimal.ZERO, BigDecimal::add);

        boolean materialRequired = planId != null || !issues.isEmpty();
        OrderProgress result = new OrderProgress(
                order.getId(), order.getBillNo(), order.getStatus(),
                financeStatus, financeDecidedAt,
                materialRequired, planStatus, planCloseReason,
                materialLines, issues, receipts, returns, wastes, supplierLedger,
                apPosted, wasteDeduct, false);
        return subcontractPriceMasked() ? maskCommercialPrices(result) : result;
    }

    private boolean subcontractPriceMasked() {
        return commercialPriceVisibility == null
                || !commercialPriceVisibility.canViewSubcontractOrder();
    }

    /** Pure response redaction used after all quantity/progress calculations are complete. */
    static OrderProgress maskCommercialPrices(OrderProgress progress) {
        List<ReceiptDoc> safeReceipts = progress.receipts().stream()
                .map(r -> new ReceiptDoc(r.id(), r.billNo(), r.status(), r.billDate(),
                        r.warehouseName(), r.approverName(), r.totalQty(), null,
                        r.iqcStatus(), r.warehouseStockInStatus(),
                        r.iqcPassedBaseQty(), r.warehouseStockedBaseQty(),
                        r.pendingStockInBaseQty(), r.updatedAt()))
                .toList();
        List<ReturnDoc> safeReturns = progress.returns().stream()
                .map(r -> new ReturnDoc(r.id(), r.billNo(), r.status(), r.billDate(),
                        r.totalQty(), null))
                .toList();
        List<WasteDoc> safeWastes = progress.wastes().stream()
                .map(w -> new WasteDoc(w.id(), w.billNo(), w.status(), w.billDate(),
                        w.totalQty(), null, w.deductPosted()))
                .toList();
        return new OrderProgress(progress.orderId(), progress.billNo(), progress.status(),
                progress.financeCaseStatus(), progress.financeDecidedAt(),
                progress.materialRequired(), progress.planStatus(), progress.planCloseReason(),
                progress.materialLines(), progress.issues(), safeReceipts, safeReturns, safeWastes,
                progress.supplierLedger(), null, null, true);
    }

    private static UUID orderIdParam(UUID id) {
        return id;
    }

    private List<Object[]> query(String sql, UUID id) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery(sql).setParameter("id", id).getResultList();
        return rows;
    }

    private List<Object[]> queryRows(String sql, UUID id) {
        return query(sql, id);
    }

    private static BigDecimal bd(Object value) {
        return value == null ? BigDecimal.ZERO : (BigDecimal) value;
    }

    private static String preparationBlocker(String status) {
        if (status == null) return "委外出仓准备状态缺失，请刷新或联系管理员";
        return switch (status) {
            case "LEGACY_READY", "READY_OUTBOUND", "OUTBOUND_COMPLETE" -> null;
            case "ACTION_REQUIRED" -> "需由计划员启动委外前置自制物料分析";
            case "IN_PREPARATION" -> "前置自制尚未完成领料、报工、FQC 与仓库实收";
            case "WAITING_FQC" -> "前置自制已报工，等待品质检验";
            case "WAITING_INBOUND" -> "前置自制已合格，等待仓库实收入库";
            case "CANCELLED" -> "委外出仓准备已取消";
            default -> "未知委外出仓准备状态，已失败关闭";
        };
    }

    private static List<String> preparationActions(
            String status, UUID analysisId, boolean canOpenAnalysis) {
        if (!canOpenAnalysis || analysisId == null || "CANCELLED".equals(status)) {
            return List.of();
        }
        return List.of("OPEN_ANALYSIS");
    }

    private static LocalDate toDate(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate d) return d;
        if (value instanceof java.sql.Date sqlDate) return sqlDate.toLocalDate();
        return LocalDate.parse(value.toString());
    }

    private static OffsetDateTime toOffset(Object value) {
        if (value == null) return null;
        if (value instanceof OffsetDateTime odt) return odt;
        if (value instanceof java.time.Instant instant) return instant.atOffset(ZoneOffset.UTC);
        if (value instanceof Timestamp ts) return ts.toInstant().atOffset(ZoneOffset.UTC);
        if (value instanceof java.util.Date date) return date.toInstant().atOffset(ZoneOffset.UTC);
        return OffsetDateTime.parse(value.toString());
    }
}
