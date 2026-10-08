package com.uten.imp.features.production.directtransfer;

import com.uten.imp.application.port.LineSideWarehousePort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.validation.RequestLimits;
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
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
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
 * ADR-147(V802) 起线边仓(内料仓)只能在「车间内料仓」里开通，直送只送已开通的车间，不再自动建仓；
 * 收料车间没开通时资格判定给出 WORKSHOP_BIN_NOT_OPEN，报工这部分送入仓库。
 *
 * <p>权限：整条链由 {@code production_direct_transfer:approve} 一个码显式授权(V585)，
 * 不借用品质部与仓库的码；范围由 {@link ProductionWorkshopMembership} 逐段判定。
 * 能不能送(同车间、真实父子关系、路线、接收状态、数量)只有一份规则：
 * 库函数 fn_workshop_direct_targets / fn_assert_workshop_direct_target(V736, ADR-127)，
 * 候选、审核与数据库守卫都调用它；线边仓同车间同主仓等身份不变量仍由 V584 行级守卫兜底。
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
    /** 读收料车间已开通的内料仓走应用端口(ADR-017：跨 feature 只经 application.port)。 */
    private final LineSideWarehousePort lineSideWarehouses;
    private final ChainNoticeService chainNotices;

    /** 报工页「转下一道工序」下拉的候选：可送的上层工单(同车间、真实父子关系、接收中、还缺料)。 */
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
        @com.fasterxml.jackson.annotation.JsonProperty(value="requiredQtyExact",access=com.fasterxml.jackson.annotation.JsonProperty.Access.READ_ONLY)
        public String requiredQtyExact() { return requiredQty==null?null:requiredQty.toPlainString(); }
        @com.fasterxml.jackson.annotation.JsonProperty(value="alreadyCoveredQtyExact",access=com.fasterxml.jackson.annotation.JsonProperty.Access.READ_ONLY)
        public String alreadyCoveredQtyExact() { return alreadyCoveredQty==null?null:alreadyCoveredQty.toPlainString(); }
        @com.fasterxml.jackson.annotation.JsonProperty(value="remainingQtyExact",access=com.fasterxml.jackson.annotation.JsonProperty.Access.READ_ONLY)
        public String remainingQtyExact() { return remainingQty==null?null:remainingQty.toPlainString(); }
    }

    /** 结构上是它的上层、但现在不能收的工单(报工页下拉里置灰并用红字写明原因)。 */
    public record BlockedTarget(
            UUID demandId,
            UUID executionSegmentId,
            String executionSegmentCode,
            String planNo,
            UUID receivingGoodsId,
            String receivingGoodsCode,
            String receivingGoodsName,
            String reasonCode,
            String reason) {
    }

    /**
     * 候选列表 + 不能收的上层工单 + 不可转原因(V736/ADR-127)。
     *
     * <p>{@code candidates}：可送的上层工单，已按「先急后缓」排好(接收计划所属分析行的优先级、交期…)；
     * 报工页按这个次序把一行产量逐个分给它们，剩下的送入仓库。
     *
     * <p>{@code blockedTargets}：结构上是上层、但现在不能收的工单(跨车间、委外件、已备齐、停产等)，
     * 同一次序；报工页在下拉里置灰并用红字写明原因。与本工单没有父子关系的同货品工单不列出。
     *
     * <p>{@code unavailableReasonCode} / {@code unavailableReason}：一个可送的上层工单都没有时，
     * 最接近可送的那条原因(fn_workshop_direct_targets 的 reason_rank 最小者)；有候选时为空。
     *
     * <p>{@code receiverLimit}：一行报工最多同时转给几个上层工单(服务端同一个常量)。
     */
    public record CandidateListing(
            List<Candidate> candidates,
            List<BlockedTarget> blockedTargets,
            String unavailableReasonCode,
            String unavailableReason,
            int receiverLimit) {
    }

    /**
     * 列候选只读库里唯一的判定入口 fn_workshop_direct_targets(V736)：只列与本工单挂钩的结构上层
     * (任意车间)，逐条给出「能不能送、为什么」；没有父子关系的工单库里就不列，这里不再复写任何资格条件。
     * 报工行的货品与来源工单的产品对不上时，原因与接近程度也取库里同一份文案。
     */
    private static final String TARGETS_SQL = """
                        SELECT target.demand_id, target.receiving_segment_id, target.receiving_segment_code,
                               target.receiving_status, target.receiving_continuous,
                               target.receiving_plan_id, target.receiving_plan_no,
                               demand.goods_id, goods.code, goods.name, color.name, unit.name,
                               target.required_qty, target.covered_qty, target.remaining_qty,
                               target.receiving_product_goods_id, product.code, product.name,
                               target.eligible AND matched.same_goods,
                               CASE WHEN matched.same_goods THEN target.reason_code ELSE 'GOODS_MISMATCH' END,
                               CASE WHEN matched.same_goods THEN target.reason_text
                                    ELSE fn_workshop_direct_reason_text('GOODS_MISMATCH',
                                         NULL, NULL, NULL, NULL, NULL, NULL) END,
                               CASE WHEN matched.same_goods THEN target.reason_rank
                                    ELSE fn_workshop_direct_reason_rank('GOODS_MISMATCH') END
                        FROM fn_workshop_direct_targets(:segmentId) target
                        LEFT JOIN production_material_demands demand ON demand.id = target.demand_id
                        CROSS JOIN LATERAL (
                            SELECT target.demand_id IS NULL
                                   OR (demand.goods_id = :goodsId
                                       AND demand.color_id IS NOT DISTINCT FROM CAST(:colorId AS UUID))
                                   AS same_goods) matched
                        LEFT JOIN goods ON goods.id = demand.goods_id
                        LEFT JOIN goods product ON product.id = target.receiving_product_goods_id
                        LEFT JOIN colors color ON color.id = demand.color_id
                        LEFT JOIN units unit ON unit.id = demand.unit_id
                        ORDER BY target.sort_order
                        """;

    /** 不可转原因的统一前缀：界面红字、审核报错与数据库守卫同一句开头。 */
    public static final String UNAVAILABLE_PREFIX = "无法转到下一道工序：";

    @Transactional(readOnly = true)
    public CandidateListing candidates(UUID executionSegmentId, UUID goodsId, UUID colorId) {
        if (executionSegmentId == null || goodsId == null) {
            throw validation("请先选择报工来源工单与货品");
        }
        requireWorkshopMember(executionSegmentId);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery(TARGETS_SQL)
                .setParameter("segmentId", executionSegmentId)
                .setParameter("goodsId", goodsId)
                .setParameter("colorId", colorId));
        List<Candidate> out = new ArrayList<>(rows.size());
        List<BlockedTarget> blocked = new ArrayList<>();
        String reasonCode = null;
        String reason = null;
        int bestRank = Integer.MAX_VALUE;
        // 行已按「先急后缓」排好(sort_order)，这里原样保序。
        for (Object[] row : rows) {
            if (Boolean.TRUE.equals(row[18])) {
                out.add(new Candidate(
                        (UUID) row[0], (UUID) row[1], (String) row[2],
                        (String) row[3], Boolean.TRUE.equals(row[4]),
                        (UUID) row[5], (String) row[6], (UUID) row[7],
                        (String) row[8], (String) row[9], (String) row[10], (String) row[11],
                        decimal(row[12]), decimal(row[13]), decimal(row[14]),
                        (UUID) row[15], (String) row[16], (String) row[17]));
                continue;
            }
            // 报工行货品对不上时(本查询标的 GOODS_MISMATCH)列出的工单都不是它的上层，不进置灰列表。
            if (row[0] != null && row[19] != null && !"GOODS_MISMATCH".equals(row[19])) {
                blocked.add(new BlockedTarget((UUID) row[0], (UUID) row[1], (String) row[2], (String) row[6],
                        (UUID) row[15], (String) row[16], (String) row[17], (String) row[19], (String) row[20]));
            }
            // 一个都不能送时只报最接近可送的那条原因(接近程度由库里统一给出)。
            int rank = row[21] == null ? Integer.MAX_VALUE : ((Number) row[21]).intValue();
            if (row[19] != null && rank < bestRank) {
                bestRank = rank;
                reasonCode = (String) row[19];
                reason = (String) row[20];
            }
        }
        boolean none = out.isEmpty();
        return new CandidateListing(
                List.copyOf(out),
                List.copyOf(blocked),
                none ? reasonCode : null,
                none ? reason : null,
                RequestLimits.DAILY_REPORT_DIRECT_RECEIVERS);
    }

    /**
     * 审核同事务执行直送。调用方(生产日报审核)已经完成自己的状态与范围校验，
     * 这里独立再校验直送特有的权限、车间归属与线边仓。
     *
     * <p>一张报工分给多个上层工单时仍逐块办：校验、写直送明细、自检入线边仓、投给这个上层工单，
     * 办完一块再办下一块(ADR-127 §8)。曾试过把同一线边位置的各块合成一张入库单一次点收，实测更慢：
     * 各块同时进了线边仓，后面每个上层工单投料时的可用量与权益查询都要把还没投出去的各块再过一遍，
     * 11 块时审核反而多花约一倍时间，所以不合单。收料车间的内料仓一次审核只读一次。
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
        // 同一张报工常有多行出自同一个执行工单；车间成员资格只由 (工单, 当前操作者) 决定，
        // 在一次调用里逐行重查是纯粹的重复往返(每行两条语句)。
        Set<UUID> memberCheckedSegments = new LinkedHashSet<>();
        // 内料仓只由收料车间决定，同一次审核里各块共用，不再每块重读一遍。
        Map<UUID, UUID> binByWorkshop = new HashMap<>();
        for (ProductionDailyReportItem item : direct) {
            Resolved resolved = resolve(item, memberCheckedSegments, binByWorkshop);
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
     * 逐行解析收料需求、车间与线边仓。能不能送只读 fn_workshop_direct_targets 的单条校验(V736)，
     * 与候选列表、保存拆分、数据库守卫同一把尺子；不能送时原样说出原因。
     * 内料仓只读收料车间已开通的那一个(ADR-147)；没开通时上面的判定已经是 WORKSHOP_BIN_NOT_OPEN。
     */
    private Resolved resolve(
            ProductionDailyReportItem item, Set<UUID> memberCheckedSegments,
            Map<UUID, UUID> binByWorkshop) {
        BigDecimal baseQty = baseQuantity(item);
        // 一条语句：先锁住出料工单、收料需求、接收工单及其计划与计划包(防并发停产/关闭穿透)，
        // 再读库里唯一的单条判定。判定读的是本语句快照；写直送明细时数据库断言会在锁后重新判定，
        // 真被并发改了也给同一句原因。
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        WITH locked AS MATERIALIZED (
                            SELECT report_item.id
                            FROM production_daily_report_items report_item
                            JOIN production_execution_segments producing
                              ON producing.id = report_item.execution_segment_id
                            JOIN production_material_demands demand
                              ON demand.id = report_item.direct_transfer_demand_id
                            JOIN production_execution_segments receiving
                              ON receiving.id = demand.execution_segment_id
                            JOIN production_plans receiving_plan ON receiving_plan.id = receiving.plan_id
                            JOIN production_planning_packages package
                              ON package.id = receiving.package_id AND package.plan_id = receiving_plan.id
                            WHERE report_item.id = :itemId
                            FOR UPDATE OF receiving_plan, package, producing, receiving, demand
                        )
                        SELECT target.demand_id, target.receiving_segment_id, target.receiving_plan_id,
                               target.receiving_workshop_id, target.demand_warehouse_id,
                               target.package_warehouse_id, target.receiving_status,
                               target.receiving_continuous,
                               COALESCE(goods.name, goods.code, '物料'),
                               target.eligible, target.reason_text,
                               locked.id IS NOT NULL AS locked
                        FROM production_daily_report_items report_item
                        LEFT JOIN locked ON locked.id = report_item.id
                        JOIN goods ON goods.id = report_item.goods_id
                        CROSS JOIN LATERAL fn_workshop_direct_targets(
                            report_item.execution_segment_id, report_item.direct_transfer_demand_id,
                            CAST(:baseQty AS NUMERIC)) target
                        WHERE report_item.id = :itemId
                        """).setParameter("itemId", item.getId()).setParameter("baseQty", baseQty));
        if (rows.size() != 1) {
            throw conflict(UNAVAILABLE_PREFIX + "报工来源工单已失效，请刷新后重试");
        }
        Object[] row = rows.getFirst();
        if (!Boolean.TRUE.equals(row[9])) {
            throw conflict(UNAVAILABLE_PREFIX + row[10]);
        }
        if (memberCheckedSegments.add(item.getExecutionSegmentId())) {
            requireWorkshopMember(item.getExecutionSegmentId());
        }
        UUID workshop = (UUID) row[3];
        UUID lineSide = binByWorkshop.computeIfAbsent(workshop, receiving -> lineSideWarehouses
                .openedBinOf(receiving)
                .orElseThrow(() -> conflict(UNAVAILABLE_PREFIX + "收料车间还没开通内料仓，请仓库在「车间内料仓」开通后再直送，这次先送入仓库")));
        return new Resolved(
                (UUID) row[0], (UUID) row[1], (UUID) row[2],
                (String) row[6], Boolean.TRUE.equals(row[7]),
                workshop, lineSide, (UUID) row[5], (String) row[8]);
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
        boolean lineSideIssueChecked = readiness.promoteAfterWorkshopDirectTransfer(
                resolved.receivingSegmentId(), resolved.packageWarehouseId());
        if (!lineSideIssueChecked) {
            stockDocs.issueWorkshopDirectTransferDraws(
                    resolved.receivingSegmentId(), resolved.lineSideWarehouseId(),
                    "DT-ISSUE-" + resolved.demandId());
        }
    }

    /**
     * 只读预检(日报详情 allowedActions 用，permissions-15)：当前用户能否审核这些行里的车间直送——
     * 直送审核码 + 每个出料工单的车间成员资格，与 {@link #executeForApprovedReport} 同一把尺子。
     * 没有直送行时恒为真。
     */
    public boolean canApproveDirectTransfers(List<ProductionDailyReportItem> items) {
        List<UUID> segments = items.stream()
                .filter(item -> "WORKSHOP".equals(item.getDestination()))
                .map(ProductionDailyReportItem::getExecutionSegmentId)
                .distinct()
                .toList();
        if (segments.isEmpty()) return true;
        if (!holdsAuthority()) return false;
        for (UUID segmentId : segments) {
            // 工单已失效时预检只是不给按钮，真正审核时写路径会报明原因。
            if (segmentId == null || !Boolean.TRUE.equals(workshopMembership(segmentId))) return false;
        }
        return true;
    }

    private boolean holdsAuthority() {
        return currentUser.get()
                .map(user -> user.isSuperAdmin()
                        || user.getAuthorities().stream().anyMatch(grant ->
                                "production_direct_transfer:approve".equals(grant.getAuthority())))
                .orElse(false);
    }

    private void requireAuthority() {
        boolean allowed = holdsAuthority();
        if (!allowed) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "审核带「转下一道工序」的报工需要车间直送审核权限");
        }
    }

    /** 车间归属按执行段的车间部门与负责人判定，与开工/报工/确认用料同一把尺子。 */
    private void requireWorkshopMember(UUID executionSegmentId) {
        Boolean member = workshopMembership(executionSegmentId);
        if (member == null) throw conflict("执行工单不存在或已失效");
        if (!member) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN, "只能办理本人所属、兼职、负责或管理车间的生产任务");
        }
    }

    /** 当前用户是否该执行工单所属车间的成员；工单不存在或已失效时返回 null。 */
    private Boolean workshopMembership(UUID executionSegmentId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT workshop_department_id, responsible_employee_id
                        FROM production_execution_segments
                        WHERE id = :segmentId AND is_deleted = FALSE
                        """).setParameter("segmentId", executionSegmentId));
        if (rows.size() != 1) return null;
        Object[] row = rows.getFirst();
        return membership.isWorkshopMember(
                (UUID) row[0], (UUID) row[1],
                currentUser.employeeId().orElse(null));
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
