package com.uten.imp.features.production.directtransfer;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.dailyreport.ProductionDailyReport;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportItem;
import com.uten.imp.features.production.fulfillment.ProductionExecutionReadinessService;
import com.uten.imp.features.production.quality.ProductionFqcInspectionService;
import com.uten.imp.features.production.ProductionWorkshopMembership;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 车间内部直送：子件做完不入公共仓库，自检合格后直接投给同车间的上层工单(V584/V585)。
 *
 * <p>用户口径(2026-09-15)：「两个不同的车间必须走仓库；同一个车间才可以不走仓库」
 * 「既然是车间内流转，步骤能简化就简化，比如不需要领料、自动解锁」。
 * 所以本服务把原来要人点四次的链路压成「主管点一次审核」：
 *
 * <ol>
 *   <li>写直送事实(谁、把哪一行报工的产出、投给哪条上层需求)</li>
 *   <li>记一条班组自检放行(FQC 三张表，kind=WORKSHOP_SELF)，由它生成
 *       入本车间线边仓的成品入库草稿</li>
 *   <li>确认那张入库单：料进线边仓，子件的完工量与成本才算数</li>
 *   <li>重算上层工单齐套，齐了就形成线边仓领料单</li>
 *   <li>把料投给上层工单那条需求，上层即可开工</li>
 * </ol>
 *
 * <p>为什么不做成「纯记账、料不在任何位置」：那样会同时撞死齐套判定、需求履约、
 * 材料清账与成本产出四道既有硬闸，其中成本产出行的 movement_id 是 NOT NULL——
 * 没有库存移动就没有成本产出，子件的成本会永远停在在制。所以取向是**不绕开「仓库」
 * 这个数据概念，只绕开「仓库」这个部门角色**：线边仓是车间自己的料架，是一个真实叶仓。
 *
 * <p>权限：整条链由 {@code production_direct_transfer:approve} 一个码显式授权(V585)，
 * 不借用品质部与仓库的码；范围由 {@link ProductionWorkshopMembership} 逐段判定，
 * 更强的不变量(两段与线边仓同车间、同主仓、同货品同颜色、不超收料需求量)
 * 由 V584 的行级守卫在数据库层兜底。
 */
@Service
@RequiredArgsConstructor
public class ProductionWorkshopDirectTransferService {

    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final ProductionWorkshopMembership membership;
    private final ProductionFqcInspectionService inspections;
    private final ProductionExecutionReadinessService readiness;
    private final StockDocService stockDocs;

    /** 报工页「转下一道工序」下拉的候选：同车间、同货品同颜色、还缺料的上层工单。 */
    public record Candidate(
            UUID demandId,
            UUID executionSegmentId,
            String executionSegmentCode,
            UUID planId,
            String planNo,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            String colorName,
            String unitName,
            BigDecimal requiredQty,
            BigDecimal alreadyCoveredQty,
            BigDecimal remainingQty,
            String receivingGoodsCode,
            String receivingGoodsName) {
    }

    /**
     * 候选列表 + 空候选的原因标记。
     *
     * <p>{@code lineSideWarehouseMissing}：同车间明明有还缺料的上层工单，但本车间没有
     * 与收料需求同主仓的线边仓——界面据此提示「先建线边仓」，而不是笼统的「没有可投的上层」。
     * 曾因缺这个区分，真实链路(父子同车间)在界面上永远显示「无下游」，被误读成方向查错。
     */
    public record CandidateListing(
            List<Candidate> candidates,
            boolean lineSideWarehouseMissing) {
    }

    /**
     * 列出这条报工行可以投给谁。
     *
     * <p>只列同车间的段：跨车间必须走仓库(数据库守卫也会拒)。已开工且需求已领齐的段
     * 不列——料投过去也挂不上，只会变成线边仓的呆料。同车间上层工单存在但线边仓缺失时，
     * 候选为空并带 {@code lineSideWarehouseMissing=true}。
     */
    @Transactional(readOnly = true)
    public CandidateListing candidates(UUID executionSegmentId, UUID goodsId, UUID colorId) {
        if (executionSegmentId == null || goodsId == null) {
            throw validation("请先选择报工来源工单与货品");
        }
        requireWorkshopMember(executionSegmentId);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT demand.id, receiving.id, receiving.segment_code,
                               receiving.plan_id, plan.bill_no,
                               demand.goods_id, goods.code, goods.name,
                               color.name, unit.name,
                               demand.required_qty,
                               COALESCE((
                                   SELECT SUM(covered.qty)
                                   FROM production_workshop_direct_transfer_items covered
                                   WHERE covered.to_demand_id = demand.id
                                     AND covered.reversal_id IS NULL), 0),
                               EXISTS (
                                   SELECT 1 FROM warehouses line_side
                                   WHERE line_side.is_line_side
                                     AND line_side.is_deleted = FALSE
                                     AND line_side.workshop_department_id
                                         = producing.workshop_department_id
                                     AND fn_warehouse_same_main(
                                         line_side.id, demand.warehouse_id)),
                               receiving_product.code, receiving_product.name
                        FROM production_execution_segments producing
                        JOIN production_execution_segments receiving
                          ON receiving.workshop_department_id = producing.workshop_department_id
                         AND receiving.is_deleted = FALSE
                         AND receiving.id <> producing.id
                         AND receiving.status IN ('WAITING', 'READY', 'DISPATCHED')
                        JOIN production_material_demands demand
                          ON demand.execution_segment_id = receiving.id
                         AND demand.is_deleted = FALSE
                         AND demand.status NOT IN ('RELEASED', 'REVERSED')
                         AND demand.goods_id = :goodsId
                         AND demand.color_id IS NOT DISTINCT FROM CAST(:colorId AS UUID)
                        JOIN production_plans plan
                          ON plan.id = receiving.plan_id AND plan.is_deleted = FALSE
                         AND plan.is_canceled = FALSE AND plan.is_stopped = FALSE
                        LEFT JOIN goods ON goods.id = demand.goods_id
                        LEFT JOIN goods receiving_product
                          ON receiving_product.id = receiving.product_goods_id
                        LEFT JOIN colors color ON color.id = demand.color_id
                        LEFT JOIN units unit ON unit.id = demand.unit_id
                        WHERE producing.id = :segmentId
                          AND producing.is_deleted = FALSE
                          AND producing.workshop_department_id IS NOT NULL
                        ORDER BY plan.bill_no, receiving.segment_code, demand.id
                        """)
                .setParameter("segmentId", executionSegmentId)
                .setParameter("goodsId", goodsId)
                .setParameter("colorId", colorId));
        List<Candidate> out = new ArrayList<>(rows.size());
        boolean eligibleWithoutLineSide = false;
        for (Object[] row : rows) {
            BigDecimal required = decimal(row[10]);
            BigDecimal covered = decimal(row[11]);
            BigDecimal remaining = required.subtract(covered);
            if (remaining.signum() <= 0) continue;
            boolean lineSideReady = (Boolean) row[12];
            if (!lineSideReady) {
                eligibleWithoutLineSide = true;
                continue;
            }
            out.add(new Candidate(
                    (UUID) row[0], (UUID) row[1], (String) row[2],
                    (UUID) row[3], (String) row[4], (UUID) row[5],
                    (String) row[6], (String) row[7], (String) row[8], (String) row[9],
                    required, covered, remaining,
                    (String) row[13], (String) row[14]));
        }
        return new CandidateListing(List.copyOf(out), out.isEmpty() && eligibleWithoutLineSide);
    }

    /**
     * 审核同事务执行直送。调用方(生产日报审核)已经完成自己的状态与范围校验，
     * 这里独立再校验直送特有的权限、车间归属与线边仓。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void executeForApprovedReport(
            ProductionDailyReport report, List<ProductionDailyReportItem> items) {
        List<ProductionDailyReportItem> direct = items.stream()
                .filter(item -> "WORKSHOP".equals(item.getDestination()))
                .toList();
        if (direct.isEmpty()) return;
        requireAuthority();

        // 一张报工可能有多行直送，但它们必然同车间(守卫保证)，按车间归集成一张直送单。
        Map<UUID, UUID> transferByWorkshop = new LinkedHashMap<>();
        for (ProductionDailyReportItem item : direct) {
            Resolved resolved = resolve(item);
            UUID transferId = transferByWorkshop.computeIfAbsent(
                    resolved.workshopDepartmentId(),
                    workshop -> insertTransfer(report, workshop, resolved.lineSideWarehouseId()));
            insertTransferItem(transferId, item, resolved);
            releaseBySelfInspection(report, item, resolved);
            handOverToReceivingSegment(resolved);
        }
    }

    /** 红冲同事务撤回本单的直送承诺；库存与放行事实由各自的反向链路处理。 */
    @Transactional(propagation = Propagation.MANDATORY)
    public void reverseForReport(UUID reportId, String reason) {
        List<UUID> transfers = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT DISTINCT transfer.id
                        FROM production_workshop_direct_transfers transfer
                        JOIN production_workshop_direct_transfer_items item
                          ON item.transfer_id = transfer.id AND item.reversal_id IS NULL
                        WHERE transfer.source_report_id = :reportId
                        ORDER BY 1
                        """).setParameter("reportId", reportId), UUID.class);
        for (UUID transferId : transfers) {
            UUID reversalId = UUID.randomUUID();
            em.createNativeQuery("""
                            INSERT INTO production_workshop_direct_transfer_reversals(
                                id, transfer_id, reason, created_by)
                            VALUES (:id, :transferId, :reason, :actorId)
                            """)
                    .setParameter("id", reversalId)
                    .setParameter("transferId", transferId)
                    .setParameter("reason", reason)
                    .setParameter("actorId", currentUser.requireId())
                    .executeUpdate();
            em.createNativeQuery("""
                            UPDATE production_workshop_direct_transfer_items
                            SET reversal_id = :reversalId
                            WHERE transfer_id = :transferId AND reversal_id IS NULL
                            """)
                    .setParameter("reversalId", reversalId)
                    .setParameter("transferId", transferId)
                    .executeUpdate();
        }
    }

    // ===================== 内部 =====================

    private record Resolved(
            UUID demandId,
            UUID receivingSegmentId,
            UUID receivingPlanId,
            UUID workshopDepartmentId,
            UUID lineSideWarehouseId,
            UUID packageWarehouseId) {
    }

    /** 逐行解析收料需求、车间与线边仓，并把「同车间」这条边界在应用层也说清楚。 */
    private Resolved resolve(ProductionDailyReportItem item) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT demand.id, receiving.id, receiving.plan_id,
                               producing.workshop_department_id,
                               receiving.workshop_department_id,
                               (SELECT line_side.id FROM warehouses line_side
                                 WHERE line_side.is_line_side
                                   AND line_side.is_deleted = FALSE
                                   AND line_side.workshop_department_id
                                       = producing.workshop_department_id
                                   AND fn_warehouse_same_main(
                                       line_side.id, demand.warehouse_id)
                                 ORDER BY line_side.id LIMIT 1),
                               package.warehouse_id
                        FROM production_daily_report_items report_item
                        JOIN production_execution_segments producing
                          ON producing.id = report_item.execution_segment_id
                         AND producing.is_deleted = FALSE
                        JOIN production_material_demands demand
                          ON demand.id = report_item.direct_transfer_demand_id
                         AND demand.is_deleted = FALSE
                         AND demand.status NOT IN ('RELEASED', 'REVERSED')
                        JOIN production_execution_segments receiving
                          ON receiving.id = demand.execution_segment_id
                         AND receiving.is_deleted = FALSE
                        JOIN production_planning_packages package
                          ON package.id = receiving.package_id
                         AND package.is_deleted = FALSE
                        WHERE report_item.id = :itemId
                        FOR UPDATE OF producing, receiving, demand
                        """).setParameter("itemId", item.getId()));
        if (rows.size() != 1) {
            throw conflict("直送的接收工单已变化或已失效，请刷新报工后重新选择");
        }
        Object[] row = rows.getFirst();
        UUID producingWorkshop = (UUID) row[3];
        UUID receivingWorkshop = (UUID) row[4];
        if (producingWorkshop == null || !producingWorkshop.equals(receivingWorkshop)) {
            throw conflict(
                    "转送车间只能在同一个车间内部进行；跨车间请改选「送入仓库」，"
                            + "由仓库送检登记、品质部检验后入库再发料");
        }
        requireWorkshopMember(item.getExecutionSegmentId());
        UUID lineSide = (UUID) row[5];
        if (lineSide == null) {
            throw conflict(
                    "本车间还没有与收料工单同主仓的线边仓，请先在仓库主档建一个线边仓"
                            + "(参与核算的非不良叶子仓，归属本车间)");
        }
        return new Resolved(
                (UUID) row[0], (UUID) row[1], (UUID) row[2],
                producingWorkshop, lineSide, (UUID) row[6]);
    }

    private UUID insertTransfer(
            ProductionDailyReport report, UUID workshopDepartmentId, UUID lineSideWarehouseId) {
        UUID transferId = UUID.randomUUID();
        em.createNativeQuery("""
                        INSERT INTO production_workshop_direct_transfers(
                            id, source_report_id, line_side_warehouse_id,
                            workshop_department_id, idempotency_key, reason, created_by)
                        VALUES (:id, :reportId, :warehouseId,
                                :workshopId, :key, :reason, :actorId)
                        """)
                .setParameter("id", transferId)
                .setParameter("reportId", report.getId())
                .setParameter("warehouseId", lineSideWarehouseId)
                .setParameter("workshopId", workshopDepartmentId)
                .setParameter("key", "DT-" + report.getId() + "-" + workshopDepartmentId)
                .setParameter("reason",
                        "车间内部直送 · 报工 " + (report.getBillNo() == null ? "" : report.getBillNo()))
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
        return transferId;
    }

    private void insertTransferItem(
            UUID transferId, ProductionDailyReportItem item, Resolved resolved) {
        em.createNativeQuery("""
                        INSERT INTO production_workshop_direct_transfer_items(
                            transfer_id, source_report_item_id,
                            to_execution_segment_id, to_demand_id, qty)
                        VALUES (:transferId, :itemId, :segmentId, :demandId, :qty)
                        """)
                .setParameter("transferId", transferId)
                .setParameter("itemId", item.getId())
                .setParameter("segmentId", resolved.receivingSegmentId())
                .setParameter("demandId", resolved.demandId())
                .setParameter("qty", item.getQty())
                .executeUpdate();
    }

    /**
     * 班组自检放行：建一条 WORKSHOP_SELF 检验并整批判合格，由既有 FQC 放行链路
     * 生成入线边仓的成品入库草稿，随即确认实收。
     *
     * <p>复用 FQC 三张表而不是另起一套自检表：成本对象覆盖判定、入库放行校验、
     * 不合格的返工/报废闭环、报工红冲时的检验取消——四套既有机制全部以
     * 「这条报工行有没有 inspection」为判据，另起炉灶等于在四处各开一个口子。
     */
    private void releaseBySelfInspection(
            ProductionDailyReport report,
            ProductionDailyReportItem item,
            Resolved resolved) {
        UUID inspectionId = inspections.registerWorkshopSelfInspection(
                report.getId(), item.getId(), resolved.lineSideWarehouseId());
        UUID documentId = inspections.passWorkshopSelfInspection(
                inspectionId, "DT-PASS-" + item.getId());
        if (documentId == null) {
            throw conflict("班组自检放行没有生成入库任务，请刷新后重试");
        }
        stockDocs.confirmWorkshopDirectTransferInbound(
                documentId, "DT-IN-" + item.getId());
    }

    /**
     * 料已经在线边仓里，重算上层工单齐套；齐了就地形成线边仓领料单并投入。
     *
     * <p>这一步是**尽力而为**：上层还缺别的料时不算失败，料留在线边仓里等后续到料，
     * 既有的就绪补偿会在齐套时自动提升。绝不因为上层没齐套就把整张报工审核回滚掉。
     * 用户口径(2026-09-15)：「父件下面其他物料不齐没关系，各自完成送过去就行，不用卡着。」
     */
    private void handOverToReceivingSegment(Resolved resolved) {
        if (resolved.packageWarehouseId() == null) return;
        readiness.promoteAfterWorkshopDirectTransfer(
                resolved.receivingSegmentId(), resolved.packageWarehouseId());
        stockDocs.issueWorkshopDirectTransferDraws(
                resolved.receivingSegmentId(), resolved.lineSideWarehouseId(),
                "DT-ISSUE-" + resolved.demandId());
    }

    private void requireAuthority() {
        boolean allowed = currentUser.get()
                .map(user -> user.isSuperAdmin()
                        || user.getAuthorities().stream().anyMatch(grant ->
                                "production_direct_transfer:approve".equals(grant.getAuthority())))
                .orElse(false);
        if (!allowed) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "审核带「转下一道工序」的报工需要车间直送审核权限");
        }
    }

    /** 车间归属按执行段的车间部门与负责人判定，与开工/报工/确认用料同一把尺子。 */
    private void requireWorkshopMember(UUID executionSegmentId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT workshop_department_id, responsible_employee_id
                        FROM production_execution_segments
                        WHERE id = :segmentId AND is_deleted = FALSE
                        """).setParameter("segmentId", executionSegmentId));
        if (rows.size() != 1) throw conflict("执行工单不存在或已失效");
        Object[] row = rows.getFirst();
        if (!membership.isWorkshopMember(
                (UUID) row[0], (UUID) row[1],
                currentUser.employeeId().orElse(null))) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN, "只能办理本人所属、兼职、负责或管理车间的生产任务");
        }
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }
}
