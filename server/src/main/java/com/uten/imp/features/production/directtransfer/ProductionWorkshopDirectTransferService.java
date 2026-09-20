package com.uten.imp.features.production.directtransfer;

import com.uten.imp.application.port.LineSideWarehousePort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.dailyreport.ProductionDailyReport;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportItem;
import com.uten.imp.features.production.fulfillment.ProductionExecutionReadinessService;
import com.uten.imp.features.production.quality.ProductionFqcInspectionService;
import com.uten.imp.features.production.ProductionWorkshopMembership;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 车间内部直送：子件做完不入公共仓库，自检合格后直接投给同车间的上层工单(V584/V585/V595)。
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
 *   <li>上层工单是「持续生产」的(V595)：这批料立刻按需求补投给它，不看齐套；
 *       否则重算上层工单齐套，齐了就形成线边仓领料单并同事务出库</li>
 * </ol>
 *
 * <p>为什么不做成「纯记账、料不在任何位置」：那样会同时撞死齐套判定、需求履约、
 * 材料清账与成本产出四道既有硬闸，其中成本产出行的 movement_id 是 NOT NULL——
 * 没有库存移动就没有成本产出，子件的成本会永远停在在制。所以取向是**不绕开「仓库」
 * 这个数据概念，只绕开「仓库」这个部门角色**：线边仓是车间自己的料架，是一个真实叶仓。
 * V595 起线边仓由系统按「车间 × 收料主仓」自动配置，不再要求手工到仓库资料里建。
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
    /** 线边仓自动配置走应用端口(ADR-017：跨 feature 只经 application.port)。 */
    private final LineSideWarehousePort lineSideWarehouses;
    private final ChainNoticeService chainNotices;

    /** 报工页「转下一道工序」下拉的候选：同车间、同货品同颜色、还缺料的上层工单。 */
    public record Candidate(
            UUID demandId,
            UUID executionSegmentId,
            String executionSegmentCode,
            String executionSegmentStatus,
            boolean continuousSupply,
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
            UUID receivingGoodsId,
            String receivingGoodsCode,
            String receivingGoodsName) {
    }

    /**
     * 候选列表 + 上次报工的记忆(V595)。
     *
     * <p>{@code lastDestination} / {@code lastReceivingGoodsId}：本车间上一次报这个货品时
     * 选的去向与投给的父件产品。报工页据此预填并标黄提醒核对——车间的去向大多数时候不变，
     * 但每次都要人重新选一遍。学习查询直接看历史报工行，不另起记忆表。
     */
    public record CandidateListing(
            List<Candidate> candidates,
            String lastDestination,
            UUID lastReceivingGoodsId,
            String lastReceivingGoodsCode,
            String lastReceivingGoodsName) {
    }

    /**
     * 列出这条报工行可以投给谁。
     *
     * <p>只列同车间的段：跨车间必须走仓库(数据库守卫也会拒)。等待/齐套/已派工的上层工单，
     * 以及**持续生产中**(V595)的上层工单都可以收；普通已开工的段不列——它的料已经领齐，
     * 投过去挂不上，只会变成线边仓的呆料。「还差多少」按基础数量计算，普通仓供给与直送相加，
     * 直送已形成的线边预留只计一次，并扣除同一拆批谱系中其他工单已占用的直送料。
     * 父件从仓库领过的部分不再重复直送。线边仓缺失不再是空候选的原因(V595 起自动配置)。
     */
    private static final String CANDIDATE_SQL = """
                        WITH candidate_scope AS MATERIALIZED (
                        SELECT demand.id AS demand_id, receiving.id AS receiving_id, receiving.segment_code,
                               receiving.status, receiving.continuous_supply,
                               receiving.plan_id, plan.bill_no,
                               demand.goods_id, goods.code AS goods_code, goods.name AS goods_name,
                               color.name AS color_name, unit.name AS unit_name,
                               demand.required_qty,
                               receiving.product_goods_id,
                               receiving_product.code AS product_code, receiving_product.name AS product_name,
                               producing.id AS producing_id
                        FROM production_execution_segments producing
                        JOIN production_plans producing_plan ON producing_plan.id=producing.plan_id AND NOT producing_plan.is_deleted
                        JOIN production_execution_segments receiving
                          ON receiving.workshop_department_id = producing.workshop_department_id
                         AND receiving.is_deleted = FALSE
                         AND receiving.id <> producing.id
                         AND (receiving.status IN ('WAITING', 'READY', 'DISPATCHED')
                              OR (receiving.status = 'IN_PROGRESS'
                                  AND receiving.continuous_supply))
                        JOIN production_material_demands demand
                          ON demand.execution_segment_id = receiving.id
                         AND demand.is_deleted = FALSE
                         AND demand.status NOT IN ('RELEASED', 'REVERSED', 'FULFILLED')
                         AND demand.goods_id = :goodsId
                         AND demand.color_id IS NOT DISTINCT FROM CAST(:colorId AS UUID)
                        JOIN production_plans plan
                          ON plan.id = receiving.plan_id AND plan.is_deleted = FALSE
                         AND plan.status = 1 AND plan.is_closed = FALSE
                         AND plan.is_canceled = FALSE AND plan.is_stopped = FALSE
                        JOIN production_planning_packages package
                          ON package.id = receiving.package_id AND package.plan_id = plan.id
                         AND package.status = 'CONFIRMED' AND package.is_deleted = FALSE
                        LEFT JOIN goods ON goods.id = demand.goods_id
                        LEFT JOIN goods receiving_product
                          ON receiving_product.id = receiving.product_goods_id
                        LEFT JOIN colors color ON color.id = demand.color_id
                        LEFT JOIN units unit ON unit.id = demand.unit_id
                        WHERE producing.id = :segmentId
                          AND producing.is_deleted = FALSE
                          AND producing.workshop_department_id IS NOT NULL
                          AND ((producing_plan.material_analysis_id IS NOT NULL
                                AND plan.material_analysis_id=producing_plan.material_analysis_id)
                            OR (producing_plan.material_analysis_id IS NULL AND plan.material_analysis_id IS NULL
                                AND (EXISTS(SELECT 1 FROM subplan_links link WHERE link.plan_id=plan.id
                                        AND link.subplan_id=producing_plan.id AND NOT link.is_deleted)
                                  OR EXISTS(SELECT 1 FROM production_material_supply_pegs peg
                                        WHERE peg.demand_id IN(demand.id,demand.split_root_demand_id)
                                          AND peg.supply_type='PRODUCTION_PLAN_ITEM'
                                          AND peg.supply_item_id=producing.source_plan_item_id
                                          AND peg.status<>'REVERSED' AND peg.allocated_qty>peg.released_qty))))
                        )
                        SELECT demand_id,receiving_id,segment_code,status,continuous_supply,plan_id,bill_no,
                               goods_id,goods_code,goods_name,color_name,unit_name,required_qty,
                               fn_workshop_direct_covered_base_qty(demand_id),product_goods_id,product_code,product_name,
                               fn_workshop_direct_remaining_for_source(producing_id,demand_id)
                        FROM candidate_scope
                        WHERE fn_workshop_direct_relationship_allows(producing_id,demand_id)
                        ORDER BY bill_no,segment_code,demand_id
                            """;

    @Transactional(readOnly = true)
    public CandidateListing candidates(UUID executionSegmentId, UUID goodsId, UUID colorId) {
        if (executionSegmentId == null || goodsId == null) {
            throw validation("请先选择报工来源工单与货品");
        }
        requireWorkshopMember(executionSegmentId);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery(CANDIDATE_SQL)
                .setParameter("segmentId", executionSegmentId)
                .setParameter("goodsId", goodsId)
                .setParameter("colorId", colorId));
        List<Candidate> out = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            BigDecimal required = decimal(row[12]);
            BigDecimal covered = decimal(row[13]);
            BigDecimal remaining = decimal(row[17]);
            if (remaining.signum() <= 0) continue;
            out.add(new Candidate(
                    (UUID) row[0], (UUID) row[1], (String) row[2],
                    (String) row[3], Boolean.TRUE.equals(row[4]),
                    (UUID) row[5], (String) row[6], (UUID) row[7],
                    (String) row[8], (String) row[9], (String) row[10], (String) row[11],
                    required, covered, remaining,
                    (UUID) row[14], (String) row[15], (String) row[16]));
        }
        Object[] learned = lastChoice(executionSegmentId, goodsId, colorId);
        return new CandidateListing(
                List.copyOf(out),
                learned == null ? null : (String) learned[0],
                learned == null ? null : (UUID) learned[1],
                learned == null ? null : (String) learned[2],
                learned == null ? null : (String) learned[3]);
    }

    /**
     * 本车间上一次报这个货品(同颜色)时选的去向与父件产品。草稿也算——那是车间最近一次的意愿。
     */
    private Object[] lastChoice(UUID executionSegmentId, UUID goodsId, UUID colorId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT item.destination,
                               receiving.product_goods_id,
                               receiving_product.code,
                               receiving_product.name
                        FROM production_daily_report_items item
                        JOIN production_daily_reports report
                          ON report.id = item.report_id
                         AND report.status IN (0, 1)
                         AND report.is_deleted = FALSE
                        JOIN production_execution_segments producing
                          ON producing.id = item.execution_segment_id
                        JOIN production_execution_segments current_segment
                          ON current_segment.id = :segmentId
                         AND current_segment.workshop_department_id
                             = producing.workshop_department_id
                        LEFT JOIN production_material_demands demand
                          ON demand.id = item.direct_transfer_demand_id
                        LEFT JOIN production_execution_segments receiving
                          ON receiving.id = demand.execution_segment_id
                        LEFT JOIN goods receiving_product
                          ON receiving_product.id = receiving.product_goods_id
                        WHERE item.is_deleted = FALSE
                          AND item.goods_id = :goodsId
                          AND item.color_id IS NOT DISTINCT FROM CAST(:colorId AS UUID)
                        ORDER BY report.created_at DESC, item.line_no DESC
                        LIMIT 1
                        """)
                .setParameter("segmentId", executionSegmentId)
                .setParameter("goodsId", goodsId)
                .setParameter("colorId", colorId));
        return rows.isEmpty() ? null : rows.getFirst();
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

        // 一张报工可送至多个收料主仓；每个线边位置分别保留真实仓库身份。
        Map<UUID, UUID> transferByLocation = new LinkedHashMap<>();
        for (ProductionDailyReportItem item : direct) {
            Resolved resolved = resolve(item);
            UUID transferId = transferByLocation.computeIfAbsent(
                    resolved.lineSideWarehouseId(),
                    location -> insertTransfer(report, resolved.workshopDepartmentId(), location));
            insertTransferItem(transferId, item, resolved);
            releaseBySelfInspection(report, item, resolved);
            handOverToReceivingSegment(item, resolved);
            chainNotices.notifyWorkshopMaterialArrival(resolved.receivingSegmentId(),
                    "DT-" + item.getId(), "本次车间直送到料："
                            + resolved.goodsName() + " "
                            + baseQuantity(item).stripTrailingZeros().toPlainString() + "（基本单位数量）",
                    "DIRECT_REPORT", List.of(report.getId()));
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
        if (transfers.isEmpty()) return;
        List<UUID> receivingSegments = NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT DISTINCT demand.execution_segment_id
                        FROM production_workshop_direct_transfer_items transfer_item
                        JOIN production_material_demands demand
                          ON demand.id = transfer_item.to_demand_id
                          OR demand.split_root_demand_id = transfer_item.to_demand_id
                        WHERE transfer_item.transfer_id IN (:transferIds)
                          AND transfer_item.reversal_id IS NULL
                          AND NOT demand.is_deleted
                          AND demand.execution_segment_id IS NOT NULL
                        ORDER BY 1
                        """).setParameter("transferIds", transfers), UUID.class);
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
        chainNotices.resolveProductionWorkshopTasks(receivingSegments, "DIRECT_TRANSFER_REVERSED");
        for (UUID receivingSegment : receivingSegments) {
            chainNotices.notifyWorkshopMaterialArrival(receivingSegment,
                    "DT-REVERSE-" + reportId, "车间直送已撤回，已重新核对当前物料",
                    "CURRENT_STATE", List.of());
        }
    }

    // ===================== 内部 =====================

    private record Resolved(
            UUID demandId,
            UUID receivingSegmentId,
            UUID receivingPlanId,
            String receivingStatus,
            boolean receivingContinuous,
            UUID workshopDepartmentId,
            UUID lineSideWarehouseId,
            UUID packageWarehouseId,
            String goodsName) {
    }

    /**
     * 逐行解析收料需求、车间与线边仓，并把「同车间」这条边界在应用层也说清楚。
     * 线边仓按「车间 × 收料主仓」自动配置(V595)，第一次直送时就地建好。
     */
    private Resolved resolve(ProductionDailyReportItem item) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT demand.id, receiving.id, receiving.plan_id,
                               producing.workshop_department_id,
                               receiving.workshop_department_id,
                               demand.warehouse_id,
                               package.warehouse_id,
                               receiving.status, receiving.continuous_supply,
                               COALESCE(goods.name, goods.code, '物料'),
                               fn_workshop_direct_remaining_for_source(producing.id,demand.id)
                        FROM production_daily_report_items report_item
                        JOIN production_execution_segments producing
                          ON producing.id = report_item.execution_segment_id
                         AND producing.is_deleted = FALSE
                        JOIN goods ON goods.id = report_item.goods_id
                        JOIN production_material_demands demand
                          ON demand.id = report_item.direct_transfer_demand_id
                         AND demand.is_deleted = FALSE
                         AND demand.status NOT IN ('RELEASED', 'REVERSED', 'FULFILLED')
                        JOIN production_execution_segments receiving
                          ON receiving.id = demand.execution_segment_id
                         AND receiving.is_deleted = FALSE
                         AND (receiving.status IN ('WAITING', 'READY', 'DISPATCHED')
                              OR (receiving.status = 'IN_PROGRESS' AND receiving.continuous_supply))
                        JOIN production_plans receiving_plan
                          ON receiving_plan.id = receiving.plan_id
                         AND receiving_plan.status = 1 AND receiving_plan.is_deleted = FALSE
                         AND receiving_plan.is_closed = FALSE AND receiving_plan.is_canceled = FALSE
                         AND receiving_plan.is_stopped = FALSE
                        JOIN production_planning_packages package
                          ON package.id = receiving.package_id AND package.plan_id = receiving_plan.id
                         AND package.status = 'CONFIRMED' AND package.is_deleted = FALSE
                        WHERE report_item.id = :itemId
                          AND fn_workshop_direct_relationship_allows(producing.id,demand.id)
                        FOR UPDATE OF receiving_plan, package, producing, receiving, demand
                        """).setParameter("itemId", item.getId()));
        if (rows.size() != 1) {
            throw conflict("直送须有同车间的真实上下层供给责任；接收任务可能无对应来源关系、已暂停或结束，请刷新后选择。跨来源任务请先办理正常仓库或正式让料流程");
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
        BigDecimal remaining=decimal(row[10]);
        if (baseQuantity(item).compareTo(remaining)>0) {
            throw conflict("本生产来源剩余可直送数量为 " + remaining.stripTrailingZeros().toPlainString()
                    + "（基本单位）；同一计划行拆出的执行段共用供给额度，请刷新后调整数量");
        }
        UUID lineSide = lineSideWarehouses.ensure(producingWorkshop, (UUID) row[5]);
        return new Resolved(
                (UUID) row[0], (UUID) row[1], (UUID) row[2],
                (String) row[7], Boolean.TRUE.equals(row[8]),
                producingWorkshop, lineSide, (UUID) row[6], (String) row[9]);
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
                .setParameter("key", "DT-" + report.getId() + "-" + lineSideWarehouseId)
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
     * 料已经在线边仓里，投给上层工单。
     *
     * <p>上层是**持续生产**工单(V595)：不看齐套，这批料立刻按那条需求补投(预留 → 线边仓
     * 领料单 → 同事务出库)，上层接着做就行；超出需求的部分留在线边仓等下一批需求。
     *
     * <p>上层还在等待物料：重算齐套，齐了就地形成线边仓领料单并投入。这一步是**尽力而为**：
     * 上层还缺别的料时不算失败，料留在线边仓里等后续到料，既有的就绪补偿会在齐套时自动提升。
     * 绝不因为上层没齐套就把整张报工审核回滚掉。
     * 用户口径(2026-09-15)：「父件下面其他物料不齐没关系，各自完成送过去就行，不用卡着。」
     */
    private void handOverToReceivingSegment(ProductionDailyReportItem item, Resolved resolved) {
        if (resolved.packageWarehouseId() == null) return;
        if (resolved.receivingContinuous()) {
            readiness.topUpDirectSupply(
                    resolved.receivingSegmentId(), resolved.demandId(),
                    resolved.lineSideWarehouseId(), baseQuantity(item),
                    "DT-TOPUP-" + item.getId());
            return;
        }
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

    static BigDecimal baseQuantity(ProductionDailyReportItem item) {
        BigDecimal rate = item.getUnitRate() == null ? BigDecimal.ONE : item.getUnitRate();
        if (item.getQty() == null || item.getQty().signum() <= 0 || rate.signum() <= 0) {
            throw validation("车间直送数量与单位换算率必须大于零");
        }
        return item.getQty().multiply(rate).setScale(4, RoundingMode.HALF_UP);
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }
}
