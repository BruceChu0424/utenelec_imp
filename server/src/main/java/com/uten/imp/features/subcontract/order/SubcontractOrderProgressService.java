package com.uten.imp.features.subcontract.order;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.CommercialPriceVisibility;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.draw.SubcontractOpenSupplySources;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts.IssueDoc;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts.ItemProgress;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts.MaterialLine;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts.OrderProgress;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts.ReceiptDoc;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts.ReturnDoc;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts.SupplierLedgerLine;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts.SupplySource;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts.TimelineNode;
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
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/**
 * 委外订货单全链路进度聚合（ADR-143 §4.6）。
 *
 * <p>每条订货明细(委外任务)一条时间线：下单 → 财务审批 → 领料发外(已领 drawn/Q) → 加工回厂 →
 * 品质检验 → 仓库确认入仓 → 结案核销；物料段按冻结领料计划行逐种列出(与委外任务详情物料表
 * 同字段)。委外件还没有可发外直属物料(缺 BOM)时不能提交财务(ADR-143 §二.3)，进度如实提示。领料数量全部来自服务端齐套函数
 * {@code fn_subcontract_draw_facts / fn_subcontract_draw_summary / fn_subcontract_returnable_qty}，
 * 不在这里另算一遍，也从不把不同物料的数量相加。
 *
 * <p>委外视角按订货单归属可读；仓库不调用本接口（仓库有自己的出仓/到货工作台）。
 */
@Service
@RequiredArgsConstructor
public class SubcontractOrderProgressService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;

    private final EntityManager em;
    private final SubcontractOrderRepository orderRepo;
    private final SubcontractDocumentAccessPolicy access;

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

        // 领料计划(财务批准时冻结)
        String planStatus = null;
        String planCloseReason = null;
        List<Object[]> plans = query("""
                SELECT status, close_reason FROM subcontract_material_plans
                WHERE order_id = :id AND is_deleted = FALSE
                """, orderId);
        if (!plans.isEmpty()) {
            planStatus = (String) plans.getFirst()[0];
            planCloseReason = (String) plans.getFirst()[1];
        }

        List<ItemProgress> items = items(order, financeStatus);

        // 出仓单（本订货单全部领料出仓单，含仓库未发出的领料草稿）
        List<IssueDoc> issues = query("""
                SELECT DISTINCT i.id, i.bill_no, i.status, i.bill_date, w.name, i.approver_name,
                       (SELECT SUM(ii.qty) FROM subcontract_material_issue_items ii
                        WHERE ii.issue_id = i.id AND ii.is_deleted = FALSE),
                       i.updated_at
                FROM subcontract_material_issues i
                LEFT JOIN warehouses w ON w.id = i.warehouse_id
                WHERE i.is_deleted = FALSE AND EXISTS (
                    SELECT 1 FROM subcontract_material_issue_items ii
                    JOIN subcontract_order_items oi ON oi.id = ii.order_item_id
                    WHERE ii.issue_id = i.id AND ii.is_deleted = FALSE AND oi.order_id = :id)
                ORDER BY i.bill_date DESC NULLS LAST, i.id
                """, orderId).stream()
                .map(row -> new IssueDoc(
                        (UUID) row[0], (String) row[1], (Short) row[2],
                        toDate(row[3]), (String) row[4], (String) row[5],
                        bd(row[6]), toOffset(row[7])))
                .toList();

        // 进仓单 + IQC 聚合状态
        List<ReceiptDoc> receipts = query("""
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
                """, orderId).stream()
                .map(row -> new ReceiptDoc(
                        (UUID) row[0], (String) row[1], (Short) row[2],
                        toDate(row[3]), (String) row[4], (String) row[5],
                        bd(row[6]), bd(row[7]), (String) row[8], (String) row[9],
                        bd(row[10]), bd(row[11]), bd(row[12]), toOffset(row[13])))
                .toList();

        // 成品退货单
        List<ReturnDoc> returns = query("""
                SELECT r.id, r.bill_no, r.status, r.bill_date,
                       (SELECT SUM(ri.qty) FROM subcontract_return_items ri WHERE ri.return_id = r.id),
                       r.total_local
                FROM subcontract_returns r
                WHERE r.is_deleted = FALSE AND EXISTS (
                    SELECT 1 FROM subcontract_return_items ri
                    JOIN subcontract_order_items oi ON oi.id = ri.order_item_id
                    WHERE ri.return_id = r.id AND oi.order_id = :id)
                ORDER BY r.bill_date DESC NULLS LAST, r.id
                """, orderId).stream()
                .map(row -> new ReturnDoc(
                        (UUID) row[0], (String) row[1], (Short) row[2],
                        toDate(row[3]), bd(row[4]), bd(row[5])))
                .toList();

        // 损耗单（含扣款）
        List<WasteDoc> wastes = query("""
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
                """, orderId).stream()
                .map(row -> new WasteDoc(
                        (UUID) row[0], (String) row[1], (Short) row[2],
                        toDate(row[3]), bd(row[4]), bd(row[5]), (Boolean) row[6]))
                .toList();

        // 委外商处材料台账（按物料聚合，V221 守恒口径；仅本订货单已审出仓行）
        List<SupplierLedgerLine> supplierLedger = query("""
                SELECT g.code, g.name, c.name, u.name,
                       SUM(ii.at_supplier_qty), SUM(ii.consumed_qty),
                       SUM(COALESCE(ii.returned_qty, 0)), SUM(COALESCE(ii.wasted_qty, 0)),
                       SUM(ii.at_supplier_qty + COALESCE(ii.compensated_qty, 0) - ii.consumed_qty
                           - COALESCE(ii.returned_qty, 0) - COALESCE(ii.wasted_qty, 0))
                FROM subcontract_material_issue_items ii
                JOIN subcontract_material_issues i ON i.id = ii.issue_id
                JOIN subcontract_order_items oi ON oi.id = ii.order_item_id
                JOIN goods g ON g.id = ii.goods_id
                LEFT JOIN colors c ON c.id = ii.color_id
                LEFT JOIN units u ON u.id = ii.unit_id
                WHERE oi.order_id = :id AND i.status = 1 AND i.is_deleted = FALSE
                  AND ii.is_deleted = FALSE AND ii.at_supplier_qty > 0
                GROUP BY g.code, g.name, c.name, u.name
                ORDER BY g.code
                """, orderId).stream()
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

        OrderProgress result = new OrderProgress(
                order.getId(), order.getBillNo(), order.getStatus(),
                financeStatus, financeDecidedAt, planStatus, planCloseReason,
                items, issues, receipts, returns, wastes, supplierLedger,
                apPosted, wasteDeduct, false);
        return subcontractPriceMasked() ? maskCommercialPrices(result) : result;
    }

    /** 每条订货明细一个委外任务：领料齐套事实 + 回厂/质检/入仓 + 时间线。 */
    private List<ItemProgress> items(SubcontractOrder order, String financeStatus) {
        boolean approved = order.getStatus() != null && order.getStatus() == STATUS_APPROVED;
        List<Object[]> rows = query("""
                SELECT oi.id, oi.line_no, oi.goods_id,
                       COALESCE(oi.goods_code_snapshot, g.code), COALESCE(oi.goods_name_snapshot, g.name),
                       oi.color_id, c.name, oi.unit_id, u.name, oi.qty, COALESCE(oi.unit_rate, 1),
                       GREATEST(COALESCE(oi.received_qty, 0) - COALESCE(oi.returned_qty, 0), 0),
                       fn_subcontract_settled_loss_qty(oi.id),
                       EXISTS (SELECT 1 FROM subcontract_material_plan_items plan_item
                               WHERE plan_item.order_item_id = oi.id AND plan_item.is_deleted = FALSE),
                       EXISTS (SELECT 1 FROM fn_subcontract_draw_edges(oi.goods_id)),
                       iqc.passed_base, iqc.pending_base, iqc.stocked_base, iqc.inspected
                FROM subcontract_order_items oi
                JOIN goods g ON g.id = oi.goods_id
                LEFT JOIN colors c ON c.id = oi.color_id
                LEFT JOIN units u ON u.id = oi.unit_id
                LEFT JOIN LATERAL (
                    SELECT COALESCE(SUM(CASE WHEN iq.status = 'REVERSED' THEN 0
                                             ELSE iq.passed_base_qty END), 0) AS passed_base,
                           COALESCE(SUM(CASE WHEN iq.status IN ('PENDING', 'PARTIAL')
                                             THEN iq.received_base_qty - iq.passed_base_qty
                                                  - iq.failed_base_qty
                                             ELSE 0 END), 0) AS pending_base,
                           COALESCE(SUM(CASE WHEN iq.status = 'REVERSED' THEN 0
                                             ELSE iq.warehouse_stocked_base_qty END), 0) AS stocked_base,
                           COUNT(iq.id) FILTER (WHERE iq.status <> 'REVERSED') > 0 AS inspected
                    FROM subcontract_receipt_items ri
                    JOIN subcontract_receipts receipt ON receipt.id = ri.receipt_id
                     AND receipt.status = 1 AND receipt.is_deleted = FALSE
                    JOIN procurement_inspection_items iq
                      ON iq.receipt_type = 'SUBCONTRACT' AND iq.receipt_item_id = ri.id
                    WHERE ri.order_item_id = oi.id AND ri.is_deleted = FALSE
                ) iqc ON TRUE
                WHERE oi.order_id = :id AND oi.is_deleted = FALSE
                ORDER BY oi.line_no ASC NULLS LAST, oi.id
                """, order.getId());
        List<ItemProgress> out = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            UUID orderItemId = (UUID) row[0];
            BigDecimal orderQty = bd(row[9]);
            BigDecimal rate = positiveOrOne(row[10]);
            BigDecimal received = bd(row[11]);
            BigDecimal settledLoss = bd(row[12]);
            boolean hasPlan = Boolean.TRUE.equals(row[13]);
            boolean hasEdges = Boolean.TRUE.equals(row[14]);
            BigDecimal qualified = toOrderUnits(row[15], rate);
            BigDecimal pendingInspection = toOrderUnits(row[16], rate);
            BigDecimal stocked = toOrderUnits(row[17], rate);
            boolean inspected = Boolean.TRUE.equals(row[18]);
            // 已批准的明细一律按领料走(缺 BOM 的委外件不能批准，ADR-143 §二.3；万一没有计划行，
            // 领料段显示「领料计划尚未生成」)；批准前按现时可发外直属边判断是否缺 BOM。
            boolean draw = approved || hasPlan || hasEdges;
            String unitName = (String) row[8];

            Summary summary = hasPlan ? summary(orderItemId) : Summary.EMPTY;
            List<MaterialLine> materials = hasPlan ? materials(orderItemId) : List.of();
            BigDecimal returnable = hasPlan ? returnable(orderItemId) : BigDecimal.ZERO;

            List<TimelineNode> timeline = timeline(order, financeStatus, draw, hasPlan, summary,
                    orderQty, unitName, received, returnable, qualified, pendingInspection,
                    stocked, settledLoss, inspected);
            out.add(new ItemProgress(
                    orderItemId, row[1] == null ? null : ((Number) row[1]).intValue(),
                    (UUID) row[2], (String) row[3], (String) row[4],
                    (UUID) row[5], (String) row[6], (UUID) row[7], unitName,
                    orderQty,
                    draw ? OrderProgressContracts.MATERIAL_MODE_DRAW
                            : OrderProgressContracts.MATERIAL_MODE_MISSING_BOM,
                    summary.anyOpen(), summary.materialKindCount(), summary.readyKindCount(),
                    summary.drawnQty(), summary.pendingQty(), summary.drawableQty(), summary.shortQty(),
                    returnable, received, qualified, pendingInspection, stocked, settledLoss,
                    materials, timeline));
        }
        return out;
    }

    /** ADR-143 §三.4 行级显示量(订货单位)，一次读库内齐套函数。 */
    private Summary summary(UUID orderItemId) {
        List<Object[]> rows = query("""
                SELECT summary.material_kind_count, summary.ready_kind_count,
                       summary.drawn_qty, summary.pending_qty, summary.drawable_qty, summary.short_qty,
                       summary.all_sent, summary.any_open
                FROM fn_subcontract_draw_summary(:id) summary
                """, orderItemId);
        if (rows.isEmpty()) return Summary.EMPTY;
        Object[] row = rows.getFirst();
        return new Summary(
                row[0] == null ? 0 : ((Number) row[0]).intValue(),
                row[1] == null ? 0 : ((Number) row[1]).intValue(),
                bd(row[2]), bd(row[3]), bd(row[4]), bd(row[5]),
                Boolean.TRUE.equals(row[6]), Boolean.TRUE.equals(row[7]));
    }

    /** 委外商处物料可做成的完整套数(ADR-143 §三.6)；只在有计划行时调用。 */
    private BigDecimal returnable(UUID orderItemId) {
        Object value = em.createNativeQuery("SELECT fn_subcontract_returnable_qty(CAST(:id AS uuid))")
                .setParameter("id", orderItemId).getSingleResult();
        return bd(value);
    }

    /**
     * 逐种物料(冻结计划行)：需求 = 我方需发量 needed_i = LEAST(planned_i, f_i(Qm))(ADR-143 §三.4a，
     * 财务批准的委外商自带料那部分不用我方物料)；本次可领 = MAX(0, f_i(complete + drawable) − covered_i)，
     * 还缺 = MAX(0, needed_i − covered_i − avail_i)；已关闭领料的行不再可领、不计还缺。
     * 还缺的开放行带在途供应来源，与委外任务详情物料表同一读口({@link SubcontractOpenSupplySources})。
     */
    private List<MaterialLine> materials(UUID orderItemId) {
        List<Object[]> rows = query("""
                SELECT facts.plan_item_id, facts.line_no, facts.goods_id, g.code, g.name,
                       facts.color_id, c.name, facts.unit_id, u.name,
                       facts.bom_unit_qty, facts.needed_qty, facts.sent_qty, facts.pending_qty,
                       facts.available_qty, facts.usable_qty, facts.line_open,
                       CASE WHEN facts.line_open THEN GREATEST(0,
                                fn_subcontract_draw_f(summary.drawn_qty + summary.pending_qty
                                        + summary.drawable_qty, facts.bom_unit_qty)
                                - facts.sent_qty - facts.pending_qty)
                            ELSE 0 END AS drawable_qty,
                       CASE WHEN facts.line_open THEN GREATEST(0,
                                facts.needed_qty - facts.sent_qty - facts.pending_qty
                                - facts.available_qty)
                            ELSE 0 END AS short_qty
                FROM fn_subcontract_draw_facts(:id) facts
                CROSS JOIN fn_subcontract_draw_summary(:id) summary
                JOIN goods g ON g.id = facts.goods_id
                LEFT JOIN colors c ON c.id = facts.color_id
                LEFT JOIN units u ON u.id = facts.unit_id
                ORDER BY facts.line_no ASC NULLS LAST, facts.plan_item_id
                """, orderItemId);
        List<MaterialLine> out = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            BigDecimal required = bd(row[10]);
            BigDecimal sent = bd(row[11]);
            BigDecimal pending = bd(row[12]);
            boolean open = Boolean.TRUE.equals(row[15]);
            BigDecimal drawable = bd(row[16]);
            BigDecimal shortQty = bd(row[17]);
            List<SupplySource> sources = open && shortQty.signum() > 0
                    ? SubcontractOpenSupplySources.read(em, (UUID) row[2], (UUID) row[5]).stream()
                            .map(source -> new SupplySource(
                                    source.kind(), source.docId(), source.docNo(), source.openQty()))
                            .toList()
                    : List.of();
            out.add(new MaterialLine(
                    (UUID) row[0], row[1] == null ? null : ((Number) row[1]).intValue(),
                    (UUID) row[2], (String) row[3], (String) row[4],
                    (UUID) row[5], (String) row[6], (UUID) row[7], (String) row[8],
                    bd(row[9]), required, sent, pending, bd(row[13]), drawable, shortQty, bd(row[14]),
                    materialState(open, required, sent, pending, shortQty), sources));
        }
        return out;
    }

    /**
     * 物料状态(与委外任务详情物料表同口径)：已结束领料 > 已发齐 > 有待仓库发的领料 > 还缺 >
     * 已备(仓库可用已够；其它物料还缺时本批可领可能为 0)。
     */
    static String materialState(boolean open, BigDecimal required, BigDecimal sent,
                                BigDecimal pending, BigDecimal shortQty) {
        if (!open) return "CLOSED";
        if (sent.compareTo(required) >= 0) return "SENT_FULL";
        if (pending.signum() > 0) return "PENDING";
        if (shortQty.signum() > 0) return "SHORT";
        return "DRAWABLE";
    }

    /** 下单 → 财务审批 → 领料发外 → 加工回厂 → 品质检验 → 仓库确认入仓 → 结案核销。 */
    static List<TimelineNode> timeline(SubcontractOrder order, String financeStatus, boolean draw,
                                       boolean hasPlan, Summary summary, BigDecimal orderQty,
                                       String unitName, BigDecimal received, BigDecimal returnable,
                                       BigDecimal qualified, BigDecimal pendingInspection,
                                       BigDecimal stocked, BigDecimal settledLoss, boolean inspected) {
        String unit = unitName == null || unitName.isBlank() ? "" : " " + unitName;
        Short status = order.getStatus();
        boolean approved = status != null && status == STATUS_APPROVED;
        boolean reversed = status != null && status < 0;
        List<TimelineNode> nodes = new ArrayList<>(7);
        nodes.add(new TimelineNode("ORDER", "下单", OrderProgressContracts.NODE_DONE,
                "订货 " + plain(orderQty) + unit));

        String financeState;
        String financeDetail;
        if (approved || reversed) {
            financeState = OrderProgressContracts.NODE_DONE;
            financeDetail = reversed ? "订货单已红冲" : "财务已批准";
        } else if ("PENDING".equals(financeStatus)) {
            financeState = OrderProgressContracts.NODE_ACTIVE;
            financeDetail = "财务审核中";
        } else if ("REJECTED".equals(financeStatus)) {
            financeState = OrderProgressContracts.NODE_ACTIVE;
            financeDetail = "财务已退回，修改后重新提交";
        } else {
            financeState = status != null && status == STATUS_DRAFT
                    ? OrderProgressContracts.NODE_ACTIVE : OrderProgressContracts.NODE_PENDING;
            financeDetail = "待提交财务审核";
        }
        nodes.add(new TimelineNode("FINANCE", "财务审批", financeState, financeDetail));

        BigDecimal settledTarget = orderQty.subtract(settledLoss).max(BigDecimal.ZERO);
        boolean returnDone = approved && received.compareTo(settledTarget) >= 0 && orderQty.signum() > 0;
        String drawState;
        String drawDetail;
        if (reversed) {
            drawState = OrderProgressContracts.NODE_SKIPPED;
            drawDetail = "订货单已红冲，领料已取消";
        } else if (!draw) {
            drawState = OrderProgressContracts.NODE_ACTIVE;
            drawDetail = "委外件还没有维护 BOM(直属物料)，提交财务时会通知研发完善，研发完善后才能提交";
        } else if (!approved) {
            drawState = OrderProgressContracts.NODE_PENDING;
            drawDetail = "财务批准后按齐套情况领料";
        } else if (!hasPlan) {
            drawState = OrderProgressContracts.NODE_PENDING;
            drawDetail = "领料计划尚未生成";
        } else {
            StringBuilder detail = new StringBuilder("已领 " + plain(summary.drawnQty()) + "/"
                    + plain(orderQty) + unit);
            if (summary.pendingQty().signum() > 0) {
                detail.append("，待仓库发 ").append(plain(summary.pendingQty())).append(unit);
            }
            if (summary.drawableQty().signum() > 0) {
                detail.append("，可领 ").append(plain(summary.drawableQty())).append(unit);
            }
            if (summary.shortQty().signum() > 0 && summary.anyOpen()) {
                detail.append("，还缺 ").append(plain(summary.shortQty())).append(unit);
            }
            if (!summary.anyOpen() && !summary.allSent()) {
                detail.append("，已结束领料");
            }
            drawDetail = detail.toString();
            drawState = summary.allSent() || returnDone
                    ? OrderProgressContracts.NODE_DONE : OrderProgressContracts.NODE_ACTIVE;
        }
        nodes.add(new TimelineNode("DRAW", "领料发外", drawState, drawDetail));

        String returnState = !approved ? OrderProgressContracts.NODE_PENDING
                : returnDone ? OrderProgressContracts.NODE_DONE
                : received.signum() > 0 || summary.drawnQty().signum() > 0
                        ? OrderProgressContracts.NODE_ACTIVE : OrderProgressContracts.NODE_PENDING;
        String returnDetail = "已回厂 " + plain(received) + "/" + plain(orderQty) + unit
                + (hasPlan && approved ? "，委外商处物料可做 " + plain(returnable) + unit : "");
        nodes.add(new TimelineNode("RETURN", "加工回厂", returnState, returnDetail));

        String qualityState = !inspected ? OrderProgressContracts.NODE_PENDING
                : pendingInspection.signum() > 0 ? OrderProgressContracts.NODE_ACTIVE
                : returnDone ? OrderProgressContracts.NODE_DONE : OrderProgressContracts.NODE_ACTIVE;
        String qualityDetail = inspected
                ? "合格 " + plain(qualified) + unit
                        + (pendingInspection.signum() > 0 ? "，待检 " + plain(pendingInspection) + unit : "")
                : null;
        nodes.add(new TimelineNode("QUALITY", "品质检验", qualityState, qualityDetail));

        boolean stockPending = qualified.compareTo(stocked) > 0;
        String stockState = stocked.signum() <= 0 && !stockPending ? OrderProgressContracts.NODE_PENDING
                : stockPending || !returnDone ? OrderProgressContracts.NODE_ACTIVE
                : OrderProgressContracts.NODE_DONE;
        String stockDetail = stocked.signum() > 0 || stockPending
                ? "已入仓 " + plain(stocked) + unit
                        + (stockPending ? "，待确认 " + plain(qualified.subtract(stocked)) + unit : "")
                : null;
        nodes.add(new TimelineNode("STOCK_IN", "仓库确认入仓", stockState, stockDetail));

        boolean closed = approved && orderQty.signum() > 0
                && stocked.add(settledLoss).compareTo(orderQty) >= 0;
        String closeState = closed || (approved && order.isClosed()) ? OrderProgressContracts.NODE_DONE
                : OrderProgressContracts.NODE_PENDING;
        String closeDetail = settledLoss.signum() > 0 ? "已结损耗 " + plain(settledLoss) + unit : null;
        nodes.add(new TimelineNode("CLOSE", "结案核销", closeState, closeDetail));
        return nodes;
    }

    /** 行级齐套显示量；未批准(尚无冻结计划行)时全为 0。 */
    record Summary(int materialKindCount, int readyKindCount, BigDecimal drawnQty, BigDecimal pendingQty,
                   BigDecimal drawableQty, BigDecimal shortQty, boolean allSent, boolean anyOpen) {
        static final Summary EMPTY = new Summary(0, 0, BigDecimal.ZERO, BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO, true, false);
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
                progress.planStatus(), progress.planCloseReason(),
                progress.items(), progress.issues(), safeReceipts, safeReturns, safeWastes,
                progress.supplierLedger(), null, null, true);
    }

    private List<Object[]> query(String sql, UUID id) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery(sql).setParameter("id", id).getResultList();
        return rows;
    }

    private static BigDecimal bd(Object value) {
        if (value == null) return BigDecimal.ZERO;
        return value instanceof BigDecimal decimal ? decimal : new BigDecimal(value.toString());
    }

    private static BigDecimal positiveOrOne(Object value) {
        BigDecimal rate = bd(value);
        return rate.signum() > 0 ? rate : BigDecimal.ONE;
    }

    /** IQC 记的是基本单位；进度按订货单位展示。 */
    private static BigDecimal toOrderUnits(Object baseQty, BigDecimal rate) {
        return com.uten.imp.common.finance.MoneyPolicy.quantityFromBase(bd(baseQty), rate);
    }

    private static String plain(BigDecimal value) {
        return value == null ? "0" : value.stripTrailingZeros().toPlainString();
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
