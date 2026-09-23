package com.uten.imp.features.subcontract.plan;

import com.uten.imp.application.port.SubcontractOutboundWakePort;
import com.uten.imp.application.port.SubcontractPreparationInventoryPort;
import com.uten.imp.application.port.SubcontractChainNoticePort;
import com.uten.imp.application.port.SubcontractShortDeliveryPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.application.port.SubcontractOrderPreparationPort;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.subcontract.SubcontractGoodsSnapshot;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssue;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueItem;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueItemRepository;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueRepository;
import com.uten.imp.features.subcontract.plan.dto.OutboundContracts.OutboundDraftRef;
import com.uten.imp.features.subcontract.plan.dto.OutboundContracts.OutboundPlanLine;
import com.uten.imp.features.subcontract.plan.dto.OutboundContracts.OutboundTaskDetail;
import com.uten.imp.features.subcontract.plan.dto.OutboundContracts.OutboundTaskListItem;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * 委外目标件出仓与前置自制服务（V436；兼容 V304 历史行）。
 *
 * <p>V436 新流永远出仓订货目标件本身。无活动直接 BOM 的目标件走
 * {@code DIRECT_OUTBOUND}；有子层走 {@code MAKE_THEN_OUTBOUND}，必须经过物料分析、
 * DRAW 实发、生产、FQC 与仓库整批实收，形成订单专属 reservation 后才进入仓库任务。
 * 草稿按冻结仓分组；未选仓 DIRECT 行独立成单，由仓库选择仓后原子占用库存。
 *
 * <p>新流 {@code planned/prepared/issued} 全部使用货品基本单位；订货单位换算率冻结在
 * {@code bom_unit_qty}，回仓仍由 V221 supplier-held 守恒消费。V304 已存在的
 * {@code LEGACY_BOM_COMPONENT} 行保留原“发 BOM 子件”语义，不回填、不改写历史。
 */
@Service
@RequiredArgsConstructor
public class SubcontractMaterialPlanService
        implements SubcontractPreparationInventoryPort, SubcontractOutboundWakePort {

    private static final short ISSUE_DRAFT = 0;

    /**
     * ADR-103 路线 B 锁判据的仓过滤: 只认「未删、非不良品、非线边、且是作业叶仓」的仓。
     * 必须与 {@code JOIN warehouses w} 搭配使用 (别名固定 w)。wakeOutboundAfterStockIn 的
     * 入库仓短路也用它, 于是「哪些仓的货算数」全系统只有这一份定义。
     */
    public static final String OPERATIONAL_LEAF_WAREHOUSE_PREDICATE = """
            NOT w.is_deleted AND NOT w.is_defective AND NOT w.is_line_side
            AND fn_warehouse_is_operational_leaf(w.id)""";

    /**
     * ADR-103 路线 B 锁判据 (全系统唯一口径): 「作业叶仓里的合格可动用量」——
     * {@code v_stock_available sa JOIN warehouses w}, 仓按 {@link #OPERATIONAL_LEAF_WAREHOUSE_PREDICATE}
     * 过滤, 只取 {@code available_qty > 0} 的行; 合计 > 0 即解锁, 否则锁。
     * countTasks / draftLineCappedByStock / requireSoleComponentStockAvailable / tasks() 都拼这一段,
     * 货色条件由各处自己接在后面 ({@code AND sa.goods_id = ...}), 片段以换行结尾可直接续写。
     */
    public static final String QUALIFIED_AVAILABLE_STOCK_SOURCE = """
            FROM v_stock_available sa
            JOIN warehouses w ON w.id = sa.warehouse_id
            WHERE sa.available_qty > 0
              AND
            """ + " " + OPERATIONAL_LEAF_WAREHOUSE_PREDICATE + "\n";

    /**
     * 该流向发出去的是**子件**而不是订货目标件：V304 历史 LEGACY 行与
     * V581 的 COMPONENT_OUTBOUND 共用这一物理形态（父件=目标件、goods=子件、
     * bom_unit_qty=冻结单耗），凡是按「发出物身份」分组或折算的地方都要认它。
     */
    private static boolean issuesComponent(Object flowMode) {
        String value = Objects.toString(flowMode, "");
        return "LEGACY_BOM_COMPONENT".equals(value) || "COMPONENT_OUTBOUND".equals(value);
    }

    private final EntityManager em;
    private final JdbcTemplate jdbc;
    private final DocNumberService docNumberService;
    private final SubcontractMaterialIssueRepository issueRepo;
    private final SubcontractMaterialIssueItemRepository issueItemRepo;
    private final SecurityContextCurrentUser currentUser;
    private final SubcontractChainNoticePort chainNotice;
    private final InventoryMutationLock inventoryLock;
    private final SubcontractOrderPreparationPort orderPreparation;
    /**
     * ADR-103 §2.5：关计划后重评短交。ObjectProvider 断 bean 环——短交服务本身依赖本服务
     * (minimumOrderQtyFromIssued 体检), 构造注入会成环。
     */
    private final ObjectProvider<SubcontractShortDeliveryPort> shortDelivery;

    /** 先算后插的计算结果（createPlanOnApproval 与草稿期共用同一口径）。 */
    record ApprovalComputation(
            String orderBillNo, UUID supplierId, LocalDate deliverDate,
            List<PendingLine> lines,
            List<OverQuantityShortage> overQuantityShortages) {
    }

    /**
     * 前置自制订货超过「任务锁定 + 公共可用」的缺口(基本单位, 2026-09-21): 送审/批准时
     * 给出可读拒绝; 不进 MAKE_THEN 缺口行, 不自动交计划再做一批。
     */
    record OverQuantityShortage(UUID orderItemId, Integer lineNo,
                                String goodsCode, String goodsName,
                                BigDecimal orderedBase, BigDecimal lockedBase,
                                BigDecimal publicBase, BigDecimal missingBase) {
    }

    /** 超出锁定量的份额建议从哪个仓发、该仓当前合格可动用量(基本单位)。 */
    private record PublicSupply(UUID warehouseId, BigDecimal availableQty) {
    }

    /**
     * 计划行待插草案。{@code goodsId/colorId/unitId/plannedBaseQty} 描述的是
     * **实际要发出去的那件东西**：目标件流向发目标件本身；V581 的
     * {@code COMPONENT_OUTBOUND} 发的是目标件那唯一的叶子子件，此时
     * {@code parentGoodsId/parentColorId} 才是订货目标件，{@code bomUnitQty}
     * 记「每 1 个目标件订货单位消耗多少子件基本量」。
     */
    record PendingLine(UUID id, UUID orderItemId, UUID goodsId, UUID colorId,
                       UUID unitId, BigDecimal orderUnitRate,
                       BigDecimal plannedBaseQty, String flowMode,
                       String preparationStatus, BigDecimal preparedBaseQty,
                       UUID suggestedWarehouseId,
                       boolean bomHasChildren, String bomFingerprint,
                       UUID preparationAnalysisId, UUID preparationAnalysisItemId,
                       UUID prepareTaskId,
                       UUID parentGoodsId, UUID parentColorId,
                       BigDecimal bomUnitQty) {

        /** 目标件流向：父件即子件即订货货品，冻结单耗就是订货换算率（V436 口径）。 */
        PendingLine(UUID id, UUID orderItemId, UUID goodsId, UUID colorId,
                    UUID unitId, BigDecimal orderUnitRate,
                    BigDecimal plannedBaseQty, String flowMode,
                    String preparationStatus, BigDecimal preparedBaseQty,
                    UUID suggestedWarehouseId,
                    boolean bomHasChildren, String bomFingerprint,
                    UUID preparationAnalysisId, UUID preparationAnalysisItemId,
                    UUID prepareTaskId) {
            this(id, orderItemId, goodsId, colorId, unitId, orderUnitRate,
                    plannedBaseQty, flowMode, preparationStatus, preparedBaseQty,
                    suggestedWarehouseId, bomHasChildren, bomFingerprint,
                    preparationAnalysisId, preparationAnalysisItemId, prepareTaskId,
                    goodsId, colorId, orderUnitRate);
        }
    }

    // ==================== 链路钩子（订货 Service 同事务调用） ====================

    /**
     * 财务批准同事务：每条订货明细建立一个“目标件出仓”计划行。
     * 无活动子 BOM 的目标件可直接进入仓库出仓；有活动子 BOM 的目标件必须先由计划员
     * 启动正常 MAKE 分析，并在 DRAW 实发、报工、FQC、仓库整批实收后才能生成出仓草稿。
     * V304 历史 BOM 子件计划不改写，继续由 flow_mode=LEGACY_BOM_COMPONENT 兼容。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    @SuppressWarnings("unchecked")
    public void createPlanOnApproval(UUID orderId) {
        lockOrderInventoryDimensions(orderId);
        ApprovalComputation computation = computeApprovalLines(orderId);
        requireNoOverQuantityShortage(computation);
        if (computation == null || computation.lines().isEmpty()) {
            return;
        }
        List<PendingLine> pendingLines = computation.lines();
        String orderBillNo = computation.orderBillNo();
        UUID supplierId = computation.supplierId();
        LocalDate deliverDate = computation.deliverDate();

        UUID planId = UUID.randomUUID();
        UUID actorUser = currentUser.requireId();
        jdbc.update("""
                INSERT INTO subcontract_material_plans(
                    id, order_id, order_bill_no, supplier_id, status, created_by, updated_by)
                VALUES (?, ?, ?, ?, 'OPEN', ?, ?)
                """, planId, orderId, orderBillNo, supplierId, actorUser, actorUser);
        int lineNo = 1;
        for (PendingLine line : pendingLines) {
            jdbc.update("""
                    INSERT INTO subcontract_material_plan_items(
                        id, plan_id, order_item_id, line_no,
                        parent_goods_id, parent_color_id,
                        goods_id, color_id, unit_id, unit_rate,
                        bom_unit_qty, planned_qty, issued_qty,
                        flow_mode, preparation_status, prepared_qty,
                        preparation_warehouse_id, preparation_version,
                        bom_has_children_snapshot, preparation_bom_fingerprint,
                        preparation_analysis_id, preparation_analysis_item_id,
                        created_by, updated_by)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, 0,
                            ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?)
                    """,
                    line.id(), planId, line.orderItemId(), lineNo++,
                    line.parentGoodsId(), line.parentColorId(),
                    line.goodsId(), line.colorId(), line.unitId(),
                    line.bomUnitQty(), line.plannedBaseQty(),
                    line.flowMode(), line.preparationStatus(),
                    line.preparedBaseQty(), line.suggestedWarehouseId(),
                    line.bomHasChildren(), line.bomFingerprint(),
                    line.preparationAnalysisId(), line.preparationAnalysisItemId(),
                    actorUser, actorUser);
        }
        // V458：PREPARED_OUTBOUND 行把任务持有的前置自制预留转换为本行专属
        // SUBCONTRACT_OUTBOUND 预留（释放旧的、等量新建，保持事实可回放），
        // 之后再生成出仓草稿。
        for (PendingLine line : pendingLines) {
            if ("PREPARED_OUTBOUND".equals(line.flowMode())) {
                convertPreparationReservations(line.id(),
                        line.prepareTaskId()==null?"SUBCONTRACT_ORDER_PREPARATION":"SUBCONTRACT_PREPARE_TASK",
                        line.prepareTaskId()==null?line.orderItemId():line.prepareTaskId(),line.plannedBaseQty(),actorUser);
            }
        }
        Set<UUID> draftedPlanItems = new LinkedHashSet<>();
        createDraftForPlan(planId, orderBillNo, supplierId, deliverDate, actorUser, draftedPlanItems);
        for (PendingLine line : pendingLines) {
            if ("MAKE_THEN_OUTBOUND".equals(line.flowMode())) {
                // 2026-09-05 委外收敛：准备中心/手工 start 已退役，MAKE 行
                // （历史在批单与批准时点库存突降的兜底路径）由系统自动启动
                // 前置生产分析并通知计划部；现货直发行走 OUTBOUND_READY。
                chainNotice.notifySubcontractPrepareShortage(line.id());
                orderPreparation.autoStartPlanLinePreparation(line.id());
            } else if (!draftedPlanItems.isEmpty()) {
                // ADR-101：这张计划一张草稿都没排出来，就说明料还没到，此刻把仓库叫来只会
                // 白跑一趟——等料到了由 wakeOutboundAfterStockIn 补草稿并补这条通知。
                // 判定放在**计划级**：通知本身就是一张计划级任务卡(深链指向 /:planId)，
                // 一张计划只要有活可干就该叫人，具体每行能发多少由任务详情给。
                chainNotice.notifySubcontractOutboundReady(line.id());
            }
        }
    }

    /**
     * ADR-101：货真正入库之后，叫醒在等这批货的委外出仓计划行。
     *
     * <p>只管「发的是现货」的两种流向(COMPONENT 发子件、DIRECT 发目标件本身)：前置自制
     * 两种流向吃的是专属预留，由 V458 那条链自己推进，与公共库存到货无关。
     *
     * <p>幂等由 {@link #hasPendingDraftForPlanItem} 兜底：已有未审草稿的行直接跳过，所以
     * 入库幂等重放、一次入库命中同一计划的多行、以及后续每一批到货都可以安全地再调一次。
     * 通知只发给「这次真的新开出了草稿」的行，不会每来一批货就刷一遍旧提醒。
     */
    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void wakeOutboundAfterStockIn(List<StockedDimension> dimensions) {
        if (dimensions == null || dimensions.isEmpty()) return;
        Set<UUID> waitingLines = new LinkedHashSet<>();
        Map<UUID, Object[]> plans = new LinkedHashMap<>();
        for (StockedDimension dimension : dimensions) {
            if (dimension == null || dimension.goodsId() == null) continue;
            // ADR-103: 唤醒已收口到库存内核 (StockService 每笔 DIR_IN 都会调进来), 线边仓/
            // 不良品仓/非作业叶仓的入库对委外发料没有意义——按锁判据同一份仓过滤短路,
            // 省掉后面那一趟计划行查询。
            if (dimension.warehouseId() != null
                    && !isOperationalLeafWarehouse(dimension.warehouseId())) {
                continue;
            }
            for (Object[] row : jdbc.query("""
                    SELECT pi.id, p.id, p.order_bill_no, p.supplier_id, o.deliver_date
                    FROM subcontract_material_plan_items pi
                    JOIN subcontract_material_plans p
                      ON p.id = pi.plan_id AND p.is_deleted = FALSE AND p.status = 'OPEN'
                    JOIN subcontract_orders o ON o.id = p.order_id
                    WHERE pi.is_deleted = FALSE
                      AND pi.flow_mode IN ('DIRECT_OUTBOUND','COMPONENT_OUTBOUND')
                      AND pi.preparation_status = 'READY_OUTBOUND'
                      AND pi.goods_id = CAST(? AS uuid)
                      AND pi.color_id IS NOT DISTINCT FROM CAST(? AS uuid)
                      AND LEAST(pi.planned_qty, pi.prepared_qty) - pi.issued_qty - COALESCE((
                            SELECT SUM(ii.qty) FROM subcontract_material_issue_items ii
                            JOIN subcontract_material_issues i ON i.id = ii.issue_id
                            WHERE ii.plan_item_id = pi.id
                              AND i.status = 0 AND i.is_deleted = FALSE), 0) > 0
                    ORDER BY p.id, pi.line_no ASC NULLS LAST, pi.id
                    """,
                    (rs, rowNum) -> new Object[]{
                            rs.getObject(1, UUID.class), rs.getObject(2, UUID.class),
                            rs.getString(3), rs.getObject(4, UUID.class),
                            rs.getObject(5, LocalDate.class)},
                    dimension.goodsId(), dimension.colorId())) {
                UUID planItemId = (UUID) row[0];
                if (hasPendingDraftForPlanItem(planItemId)) continue;
                waitingLines.add(planItemId);
                plans.putIfAbsent((UUID) row[1], row);
            }
        }
        if (waitingLines.isEmpty()) return;
        UUID actorUser = currentUser.requireId();
        Set<UUID> draftedPlanItems = new LinkedHashSet<>();
        for (Object[] plan : plans.values()) {
            createDraftForPlan((UUID) plan[1], Objects.toString(plan[2], null),
                    (UUID) plan[3], (LocalDate) plan[4], actorUser, draftedPlanItems);
        }
        // 只给「这一次真排进草稿」的行发通知：同一张计划里别的行可能还在等自己的料，
        // 每来一批货就把它们全刷一遍提醒，等于把通知做成噪音。
        for (UUID planItemId : waitingLines) {
            if (draftedPlanItems.contains(planItemId)) {
                chainNotice.notifySubcontractOutboundReady(planItemId);
            }
        }
    }

    /**
     * ADR-103: 这个仓的货算不算「作业叶仓合格可动用量」——与 {@link #OPERATIONAL_LEAF_WAREHOUSE_PREDICATE}
     * 同一份判据; 仓不存在按不算处理。
     */
    private boolean isOperationalLeafWarehouse(UUID warehouseId) {
        return jdbc.query("""
                SELECT
                """ + " " + OPERATIONAL_LEAF_WAREHOUSE_PREDICATE + """

                FROM warehouses w
                WHERE w.id = CAST(? AS uuid)
                """,
                (rs, rowNum) -> rs.getBoolean(1),
                warehouseId).stream().findFirst().orElse(Boolean.FALSE);
    }

    /** Orders are locked by the caller; lock stock before any preparation/task reservation. */
    @Transactional(propagation = Propagation.MANDATORY)
    public void lockOrderInventoryDimensions(UUID orderId) {
        // V581：COMPONENT_OUTBOUND 占的是**子件**库存，批准事务必须把子件货色
        // 一并纳入同一次排序加锁，否则会与 reserveDraft 的二次加锁交叉死锁。
        List<Object[]> dimensions = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT DISTINCT goods_id, color_id FROM (
                    SELECT inventory_item.goods_id, inventory_item.color_id
                    FROM subcontract_order_items inventory_item
                    WHERE inventory_item.order_id=:orderId AND inventory_item.is_deleted=FALSE
                    UNION
                    SELECT edge.component_goods_id, edge.color_id
                    FROM subcontract_order_items inventory_item
                    JOIN goods_bom_items edge ON edge.goods_id=inventory_item.goods_id
                     AND edge.is_deleted=FALSE
                    JOIN goods child ON child.id=edge.component_goods_id
                     AND child.is_deleted=FALSE
                     AND COALESCE(child.auto_created,FALSE)=FALSE
                    WHERE inventory_item.order_id=:orderId AND inventory_item.is_deleted=FALSE
                      AND edge.consumption_basis='PER_UNIT'
                      AND edge.control_stage IN ('START','ASSEMBLY','FINISH')
                      AND edge.qty>0
                      -- ADR-085 §三.1「判据只有一个来源」：这里以前内联抄了一整套判据，
                      -- 而且漏了 edge.qty>0，判据与加锁集合从此是两份定义。改回调函数本体，
                      -- 收紧判据时不会再漏掉这一份副本(ADR-101)。
                      AND fn_subcontract_sole_component_goods(inventory_item.goods_id)
                ) dimension
                ORDER BY goods_id, color_id NULLS FIRST
                """).setParameter("orderId",orderId));
        inventoryLock.lockAll(dimensions.stream()
                .map(row -> new InventoryKey((UUID)row[0],(UUID)row[1]))
                .distinct().sorted().toList());
    }

    /**
     * 提交财务闸门（2026-09-05 委外收敛）：有子层目标件必须「先发单给计划、
     * 生产完入库」后才允许提交——按批准同款口径重算，仍出现 MAKE_THEN 缺口行
     * 即拒绝。财务批准通过即全部行 READY，仓库可立即目标件出仓。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireNoMakeThenShortage(UUID orderId) {
        ApprovalComputation computation = computeApprovalLines(orderId);
        if (computation == null) {
            return;
        }
        requireNoOverQuantityShortage(computation);
        List<PendingLine> shortage = computation.lines().stream()
                .filter(line -> "MAKE_THEN_OUTBOUND".equals(line.flowMode()))
                .toList();
        if (!shortage.isEmpty()) {
            BigDecimal missing = shortage.stream()
                    .map(PendingLine::plannedBaseQty)
                    .reduce(BigDecimal.ZERO, BigDecimal::add)
                    .setScale(4, RoundingMode.HALF_UP);
            throw new ApiException(ErrorCode.CONFLICT,
                    "有子层委外件尚未完成前置生产（合计缺口 "
                            + missing.stripTrailingZeros().toPlainString()
                            + "，基本单位）：请等计划部车间生产入库后再提交财务审核；"
                            + "进度可在订货单详情查看");
        }
        // ADR-103 路线 B: 送审与批准同一把锁——子件仓里一件都没有就不能把委外订货推下去。
        requireSoleComponentStockAvailable(computation);
    }

    /**
     * ADR-103 路线 B 锁 (建单/改单/送审/批准四层同锁): 目标件只有一个叶子子件
     * (COMPONENT_OUTBOUND 行) 时, 发给委外商的是那颗子件, 子件在作业叶仓里的合格可动用量
     * 合计 <= 0 即锁——一次 409 逐行列出哪张委外件在等哪颗子件。判据与 countTasks /
     * draftLineCappedByStock 共用 {@link #QUALIFIED_AVAILABLE_STOCK_SOURCE}, 不另写一份。
     * 这里只看「有没有」, 不占子件库存: 有货后可分批发, 每批可发量由 createDraftForPlan
     * 按此刻可动用量截断。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireSoleComponentStockAvailable(UUID orderId) {
        requireSoleComponentStockAvailable(computeApprovalLines(orderId));
    }

    private void requireSoleComponentStockAvailable(ApprovalComputation computation) {
        if (computation == null) {
            return;
        }
        List<PendingLine> componentLines = computation.lines().stream()
                .filter(line -> "COMPONENT_OUTBOUND".equals(line.flowMode()))
                .toList();
        if (componentLines.isEmpty()) {
            return;
        }
        Map<String, BigDecimal> availableByDimension = new HashMap<>();
        Set<String> reported = new LinkedHashSet<>();
        List<PendingLine> locked = new ArrayList<>();
        for (PendingLine line : componentLines) {
            String dimension = line.goodsId() + "|" + Objects.toString(line.colorId(), "");
            BigDecimal available = availableByDimension.computeIfAbsent(dimension,
                    ignored -> qualifiedAvailableTotal(line.goodsId(), line.colorId()));
            if (available.signum() > 0) {
                continue;
            }
            if (reported.add(line.parentGoodsId() + "|" + dimension)) {
                locked.add(line);
            }
        }
        if (locked.isEmpty()) {
            return;
        }
        List<UUID> goodsIds = new ArrayList<>();
        for (PendingLine line : locked) {
            goodsIds.add(line.parentGoodsId());
            goodsIds.add(line.goodsId());
        }
        Map<UUID, Object[]> master = loadGoodsMaster(goodsIds);
        StringBuilder detail = new StringBuilder();
        for (PendingLine line : locked) {
            if (detail.length() > 0) {
                detail.append("; ");
            }
            detail.append("委外件 ").append(goodsLabel(master.get(line.parentGoodsId())))
                    .append(" 要发给委外商加工的子件 ").append(goodsLabel(master.get(line.goodsId())))
                    .append(" 仓里还一件都没有");
        }
        throw new ApiException(ErrorCode.CONFLICT,
                detail + "; 等子件采购或生产入库后再下委外订货, 入库后任务中心会自动解锁");
    }

    /** 「名称(编码)」, 主档缺失时退回空串, 不让文案里出现 null。 */
    private static String goodsLabel(Object[] master) {
        if (master == null) {
            return "";
        }
        String name = Objects.toString(master[2], "");
        String code = Objects.toString(master[1], "");
        return code.isEmpty() ? name : name + "(" + code + ")";
    }

    /**
     * ADR-103 锁判据本体: 该货色在作业叶仓里的合格可动用量合计 (基本单位)。
     * 逐仓取 available_qty > 0 的行再在 Java 里求和, 与 draftLineCappedByStock 选仓那条查询
     * 同源同形 (SELECT warehouse_id, qty), 聚焦单测按同一段 SQL 片段路由。
     */
    private BigDecimal qualifiedAvailableTotal(UUID goodsId, UUID colorId) {
        List<Object[]> rows = jdbc.query("""
                SELECT sa.warehouse_id, GREATEST(COALESCE(sa.available_qty, 0), 0)
                """ + QUALIFIED_AVAILABLE_STOCK_SOURCE + """
                  AND sa.goods_id = CAST(? AS uuid)
                  AND sa.color_id IS NOT DISTINCT FROM CAST(? AS uuid)
                """,
                (rs, rowNum) -> new Object[]{rs.getObject(1, UUID.class), rs.getBigDecimal(2)},
                goodsId, colorId);
        BigDecimal total = BigDecimal.ZERO;
        for (Object[] row : rows) {
            total = total.add(decimal(row[1]).max(BigDecimal.ZERO));
        }
        return total;
    }

    /**
     * 草稿期缺口（基本单位，按订货明细行）：有子层且无 V458 前置完成谱系的行，
     * 按全局可用量池拆出仍需内部生产的量——用于保存时自动「发单给计划」。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public Map<UUID, BigDecimal> draftChildrenShortageByOrderItem(UUID orderId) {
        ApprovalComputation computation = computeApprovalLines(orderId);
        if (computation == null) {
            return Map.of();
        }
        Map<UUID, BigDecimal> shortage = new LinkedHashMap<>();
        for (PendingLine line : computation.lines()) {
            if ("MAKE_THEN_OUTBOUND".equals(line.flowMode())) {
                shortage.merge(line.orderItemId(), line.plannedBaseQty(),
                        BigDecimal::add);
            }
        }
        return shortage;
    }

    /** 与 {@link #createPlanOnApproval} 完全同一口径的先算后插（不入库）。 */
    @SuppressWarnings("unchecked")
    private ApprovalComputation computeApprovalLines(UUID orderId) {
        List<Object[]> orderRows = em.createNativeQuery("""
                SELECT id, bill_no, supplier_id, deliver_date
                FROM subcontract_orders WHERE id = :id
                """).setParameter("id", orderId).getResultList();
        if (orderRows.isEmpty()) {
            return null;
        }
        Object[] order = orderRows.getFirst();
        String orderBillNo = Objects.toString(order[1]);
        UUID supplierId = (UUID) order[2];
        LocalDate deliverDate = toLocalDate(order[3]);

        List<Object[]> items = em.createNativeQuery("""
                SELECT item.id, item.goods_id, item.color_id, item.qty, item.line_no,
                       COALESCE(item.unit_rate, 1), item.unit_id,
                       COALESCE(application.warehouse_id, order_header.warehouse_id)
                FROM subcontract_order_items item
                JOIN subcontract_orders order_header ON order_header.id = item.order_id
                LEFT JOIN subcontract_application_items application_item
                  ON application_item.id = item.application_item_id
                LEFT JOIN subcontract_applications application
                  ON application.id = application_item.application_id
                WHERE item.order_id = :orderId
                  AND COALESCE(item.is_deleted, false) = false
                ORDER BY item.line_no ASC NULLS LAST, item.id
                """).setParameter("orderId", orderId).getResultList();
        if (items.isEmpty()) {
            return null;
        }
        List<UUID> parentGoodsIds = items.stream()
                .map(row -> (UUID) row[1]).filter(Objects::nonNull).distinct().toList();
        Map<UUID, Object[]> goodsMaster = loadGoodsMaster(parentGoodsIds);

        List<PendingLine> pendingLines = new ArrayList<>();
        // 直下单销售式供货：同单同货多行共享一个递减的可用量池，防止重复占用
        // （与销售 reserveOnApprove 同款口径）。
        Map<String, BigDecimal> stockPool = new HashMap<>();
        List<OverQuantityShortage> overQuantityShortages = new ArrayList<>();
        for (Object[] item : items) {
            UUID orderItemId = (UUID) item[0];
            UUID goodsId = (UUID) item[1];
            UUID colorId = (UUID) item[2];
            BigDecimal orderQty = decimal(item[3]);
            BigDecimal orderUnitRate = decimal(item[5]);
            BigDecimal planned = orderQty.multiply(orderUnitRate)
                    .setScale(4, RoundingMode.HALF_UP);
            if (planned.signum() <= 0) {
                continue;
            }
            Object[] master = goodsMaster.get(goodsId);
            UUID baseUnitId = master == null ? (UUID) item[6] : (UUID) master[3];
            BomSnapshot bom = currentBomSnapshot(goodsId);
            // V458：订货行能追溯到委外前置自制账本批次时，说明自制在下单前
            // 已完成（produced ≥ notified ≥ planned），批准即待出仓。
            PreparedLineage prepared = preparedLineage(orderItemId);
            boolean partiallyPrepared = false;
            if(prepared==null){
                DirectPreparedLineage direct=directPreparedLineage(orderItemId);
                BigDecimal own=direct==null?BigDecimal.ZERO:planned.min(direct.qty());
                if(own.signum()>0){
                    partiallyPrepared = true;
                    pendingLines.add(new PendingLine(UUID.randomUUID(),orderItemId,goodsId,colorId,baseUnitId,orderUnitRate,
                            own,"PREPARED_OUTBOUND","READY_OUTBOUND",own,(UUID)item[7],true,bom.fingerprint(),
                            direct.analysisId(),direct.analysisItemId(),null));
                    planned=planned.subtract(own);
                    if(planned.signum()==0)continue;
                }
            }
            if (prepared != null) {
                // 2026-09-21 用户口径: 委外前置自制的订货可以超过通知量(超委外备货), 上限 =
                // 「任务锁定给本申请的量」+「同货色公共可用量」。锁定量 = 任务持有的专属预留
                // 未消费余量, 再以台账 required_qty 与本申请批次 notify_qty 封顶(与 V458/V634
                // 谱系守卫同口径); 锁定份落 PREPARED_OUTBOUND(专属预留等量转换), 超出份落
                // DIRECT_OUTBOUND 吃公共库存(建议仓优先台账仓, 否则可用量最多的仓), 再超出
                // 即为缺口——送审/批准时可读拒绝, 不自动交计划再做一批。
                BigDecimal locked = preparedTaskLockedBase(prepared.taskId(), orderItemId)
                        .max(BigDecimal.ZERO).setScale(4, RoundingMode.HALF_UP);
                BigDecimal own = planned.min(locked);
                if (own.signum() > 0) {
                    pendingLines.add(new PendingLine(
                            UUID.randomUUID(), orderItemId, goodsId, colorId,
                            baseUnitId, orderUnitRate, own,
                            "PREPARED_OUTBOUND", "READY_OUTBOUND", own,
                            prepared.warehouseId(), true, bom.fingerprint(),
                            prepared.analysisId(), prepared.analysisItemId(),
                            prepared.taskId()));
                }
                BigDecimal excess = planned.subtract(own);
                if (excess.signum() <= 0) {
                    continue;
                }
                String poolKey = goodsId + "|" + Objects.toString(colorId, "");
                BigDecimal avail = stockPool.computeIfAbsent(poolKey,
                        k -> globalAvailableBase(goodsId, colorId));
                PublicSupply supply = preferredPublicWarehouse(
                        goodsId, colorId, prepared.warehouseId());
                BigDecimal publicTake = excess.min(avail.max(BigDecimal.ZERO))
                        .min(supply.availableQty().max(BigDecimal.ZERO))
                        .setScale(4, RoundingMode.HALF_UP);
                if (publicTake.signum() > 0) {
                    stockPool.put(poolKey, avail.subtract(publicTake));
                    pendingLines.add(new PendingLine(
                            UUID.randomUUID(), orderItemId, goodsId, colorId,
                            baseUnitId, orderUnitRate, publicTake,
                            "DIRECT_OUTBOUND", "READY_OUTBOUND", publicTake,
                            supply.warehouseId(), bom.hasChildren(), bom.fingerprint(),
                            null, null, null));
                }
                BigDecimal missing = excess.subtract(publicTake);
                if (missing.signum() > 0) {
                    overQuantityShortages.add(new OverQuantityShortage(
                            orderItemId,
                            item[4] instanceof Number lineNo ? lineNo.intValue() : null,
                            master == null ? null : Objects.toString(master[1], null),
                            master == null ? null : Objects.toString(master[2], null),
                            planned, own, publicTake, missing));
                }
                continue;
            }
            // V581：目标件只有一个叶子子件时不先自制，直接把那个子件发给委外商，
            // 委外商加工后交回目标件。整条订货明细只出一条 COMPONENT 行——不做
            // 「先吃目标件现货 DIRECT + 余量另走」的拆分：回厂消费按货色分组
            // 逐组扣满，混行会两组都扣不够而把单据永久卡死（V581 迁移里另有
            // subcontract_component_outbound_exclusive_guard 兜底）。
            // partiallyPrepared：本明细已经拿现货目标件出了一条 PREPARED 行，
            // 剩余量不能再落 COMPONENT——同一订货明细混两种发出物，回厂消费按
            // 货色分组逐组扣满会两组都扣不够，把单据永久卡死（V581 的
            // subcontract_component_outbound_exclusive_guard 也会直接拒 INSERT）。
            SoleComponent sole = prepared == null && !partiallyPrepared
                    ? soleOutboundComponent(goodsId) : null;
            if (sole != null) {
                BigDecimal componentUnitQty = orderUnitRate.multiply(sole.bomQty())
                        .setScale(6, RoundingMode.HALF_UP);
                BigDecimal componentPlanned = orderQty.multiply(componentUnitQty)
                        .setScale(4, RoundingMode.HALF_UP);
                if (componentUnitQty.signum() > 0 && componentPlanned.signum() > 0) {
                    // ADR-103: 下单前已按子件库存锁过 (requireSoleComponentStockAvailable,
                    // 建单/改单/送审/批准四层同锁), 这里仍不占子件库存、建议仓刻意留空——
                    // 有货后允许分批发, 由 createDraftForPlan 按此刻可动用量建草稿并替仓库
                    // 选一个真有货的作业叶仓; 后续每一批到货由 wakeOutboundAfterStockIn 补草稿。
                    pendingLines.add(new PendingLine(
                            UUID.randomUUID(), orderItemId,
                            sole.goodsId(), sole.colorId(), sole.unitId(),
                            orderUnitRate, componentPlanned,
                            "COMPONENT_OUTBOUND", "READY_OUTBOUND", componentPlanned,
                            null, true, bom.fingerprint(),
                            null, null, null,
                            goodsId, colorId, componentUnitQty));
                    continue;
                }
                // 单耗小到 round6 归零：不能用 0 冻结单耗发料（回厂永远倒扣不出量），
                // 按既有口径回落前置自制。
            }
            // 走到这里 prepared 必为 null(前置自制谱系已在上面整段处理完)。
            boolean makeFirst = bom.hasChildren();
            if (makeFirst) {
                String poolKey = goodsId + "|" + Objects.toString(colorId, "");
                BigDecimal avail = stockPool.computeIfAbsent(poolKey,
                        k -> globalAvailableBase(goodsId, colorId));
                BigDecimal stockTake = planned.min(avail.max(BigDecimal.ZERO))
                        .setScale(4, RoundingMode.HALF_UP);
                if (stockTake.signum() > 0) {
                    stockPool.put(poolKey, avail.subtract(stockTake));
                }
                BigDecimal makeQty = planned.subtract(stockTake);
                if (stockTake.signum() > 0) {
                    pendingLines.add(new PendingLine(
                            UUID.randomUUID(), orderItemId, goodsId, colorId,
                            baseUnitId, orderUnitRate, stockTake,
                            "DIRECT_OUTBOUND", "READY_OUTBOUND", stockTake,
                            (UUID) item[7], true, bom.fingerprint(),
                            null, null, null));
                }
                if (makeQty.signum() > 0) {
                    pendingLines.add(new PendingLine(
                            UUID.randomUUID(), orderItemId, goodsId, colorId,
                            baseUnitId, orderUnitRate, makeQty,
                            "MAKE_THEN_OUTBOUND", "ACTION_REQUIRED",
                            BigDecimal.ZERO, (UUID) item[7],
                            true, bom.fingerprint(),
                            null, null, null));
                }
                continue;
            }
            pendingLines.add(new PendingLine(
                    UUID.randomUUID(), orderItemId, goodsId, colorId,
                    baseUnitId, orderUnitRate, planned,
                    "DIRECT_OUTBOUND", "READY_OUTBOUND", planned,
                    (UUID) item[7], bom.hasChildren(), bom.fingerprint(),
                    null, null, null));
        }
        return new ApprovalComputation(
                orderBillNo, supplierId, deliverDate, List.copyOf(pendingLines),
                List.copyOf(overQuantityShortages));
    }

    /**
     * 前置自制订货超过「任务锁定 + 公共可用」: 送审(requireNoMakeThenShortage)与批准
     * (createPlanOnApproval)同口径拒绝, 文案逐行给出订货量/锁定量/公共可用量/超出量。
     */
    private static void requireNoOverQuantityShortage(ApprovalComputation computation) {
        if (computation == null || computation.overQuantityShortages().isEmpty()) {
            return;
        }
        StringBuilder detail = new StringBuilder();
        for (OverQuantityShortage shortage : computation.overQuantityShortages()) {
            if (detail.length() > 0) {
                detail.append("；");
            }
            detail.append("第 ")
                    .append(shortage.lineNo() == null ? "?" : shortage.lineNo())
                    .append(" 行 ")
                    .append(shortage.goodsName() == null ? "" : shortage.goodsName())
                    .append(shortage.goodsCode() == null ? "" : "(" + shortage.goodsCode() + ")")
                    .append(" 订货 ").append(plain(shortage.orderedBase()))
                    .append("，前置自制锁定 ").append(plain(shortage.lockedBase()))
                    .append(" + 公共可用 ").append(plain(shortage.publicBase()))
                    .append("，超出 ").append(plain(shortage.missingBase()));
        }
        throw new ApiException(ErrorCode.CONFLICT,
                "委外订货量超过仓库可发出量(基本单位): " + detail
                        + "；请调小订货量，或等该件入库形成公共库存后再提交财务审核");
    }

    private static String plain(BigDecimal value) {
        return value == null ? "0" : value.stripTrailingZeros().toPlainString();
    }

    /**
     * 前置自制任务锁定给本订货行的量(基本单位): 任务持有的 SUBCONTRACT_PREPARE_TASK 专属预留
     * 未消费余量(与 convertPreparationReservations 可转换的口径一致), 再以台账 required_qty
     * 和本行主锚点申请明细所属通知批 notify_qty 封顶——这两条正是数据库谱系守卫
     * (fn_assert_subcontract_preparation_source_before_v535, V634 口径)对 PREPARED_OUTBOUND
     * 行数量的上限, 这里先按同口径切片, 超出的份额才去吃公共库存。
     */
    private BigDecimal preparedTaskLockedBase(UUID taskId, UUID orderItemId) {
        BigDecimal value = jdbc.queryForObject("""
                SELECT LEAST(
                    (SELECT COALESCE(SUM(reservation.qty - reservation.consumed_qty
                                        - reservation.released_qty), 0)
                       FROM stock_reservations reservation
                      WHERE reservation.owner_type = 'SUBCONTRACT_PREPARE_TASK'
                        AND reservation.owner_id = task.id
                        AND reservation.status = 0 AND reservation.is_deleted = FALSE
                        AND reservation.consumed_qty = 0),
                    task.required_qty,
                    COALESCE((SELECT MAX(batch.notify_qty)
                                FROM preplan_subcontract_make_task_batches batch
                                JOIN subcontract_order_items order_item
                                  ON order_item.id = ?
                               WHERE batch.task_id = task.id
                                 AND batch.application_item_id = order_item.application_item_id), 0))
                FROM preplan_subcontract_make_tasks task
                WHERE task.id = ?
                """, BigDecimal.class, orderItemId, taskId);
        return value == null ? BigDecimal.ZERO : value;
    }

    /**
     * 超出锁定量的份额从哪个仓发: 优先台账仓(前置自制入库的仓, 同货色公共库存多半也在
     * 那里), 其次合格可动用量最多的仓; 都没有可动用量时回落台账仓、可动用量记 0。
     * 批准同事务会按建议仓立即生成出仓草稿并占专属预留, 所以这里必须选一个真有货的仓。
     */
    private PublicSupply preferredPublicWarehouse(UUID goodsId, UUID colorId, UUID preferredWarehouseId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT available.warehouse_id, available.available_qty
                FROM v_stock_available available
                WHERE available.goods_id = :goodsId
                  AND available.color_id IS NOT DISTINCT FROM CAST(:colorId AS uuid)
                  AND available.available_qty > 0
                ORDER BY CASE WHEN available.warehouse_id = CAST(:preferred AS uuid) THEN 0 ELSE 1 END,
                         available.available_qty DESC, available.warehouse_id
                """).setParameter("goodsId", goodsId)
                .setParameter("colorId", colorId)
                .setParameter("preferred", preferredWarehouseId));
        if (rows.isEmpty()) {
            return new PublicSupply(preferredWarehouseId, BigDecimal.ZERO);
        }
        Object[] best = rows.getFirst();
        return new PublicSupply((UUID) best[0], decimal(best[1]));
    }

    /**
     * 全局可用量（基本单位，销售 reserveOnApprove 同款口径）：
     * 全仓账面−安全库存−全部生效预留，GREATEST(…,0) 兜底；带货色锁防并发超占。
     * colorId 可能为 NULL，比较与 CAST 对齐 StockReservationRepository 的写法。
     */
    private BigDecimal globalAvailableBase(UUID goodsId, UUID colorId) {
        inventoryLock.lock(new InventoryKey(goodsId, colorId));
        BigDecimal value = jdbc.queryForObject("""
                SELECT GREATEST(
                  (SELECT COALESCE(SUM(GREATEST(
                              COALESCE(b.qty, 0)
                              - GREATEST(
                                  COALESCE(CAST(g.min_qty AS NUMERIC), 0), 0),
                              0)), 0)
                     FROM stock_balances b
                     JOIN goods g ON g.id = b.goods_id
                     WHERE b.goods_id = ?
                       AND (b.color_id IS NOT DISTINCT FROM CAST(? AS uuid)))
                  - (SELECT COALESCE(SUM(r.qty - r.consumed_qty - r.released_qty), 0)
                       FROM stock_reservations r
                       WHERE r.is_deleted = FALSE AND r.status = 0
                         AND r.goods_id = ?
                         AND (r.color_id IS NOT DISTINCT FROM CAST(? AS uuid)))
                , 0)
                """, BigDecimal.class, goodsId, colorId, goodsId, colorId);
        return value == null ? BigDecimal.ZERO : value;
    }

    /** V458 订货红冲：PREPARED 行未消费的计划专属预留对称转回任务持有。 */
    private void restorePrepareTaskReservations(UUID planId, UUID actorUser) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT plan_item.id, COALESCE(task.id,child.subcontract_order_item_id,
                           CASE WHEN child.source_ref='SC-PREP:'||plan_item.order_item_id::text THEN plan_item.order_item_id END),
                       CASE WHEN task.id IS NULL THEN 'SUBCONTRACT_ORDER_PREPARATION' ELSE 'SUBCONTRACT_PREPARE_TASK' END
                FROM subcontract_material_plan_items plan_item
                LEFT JOIN preplan_subcontract_make_tasks task
                  ON task.analysis_id=plan_item.preparation_analysis_id
                 AND task.preparation_item_id=plan_item.preparation_analysis_item_id
                LEFT JOIN production_material_analysis_items child ON child.id=plan_item.preparation_analysis_item_id
                WHERE plan_item.plan_id = :planId
                  AND plan_item.flow_mode IN ('PREPARED_OUTBOUND','MAKE_THEN_OUTBOUND')
                  AND plan_item.is_deleted = FALSE
                  AND (task.id IS NOT NULL OR child.subcontract_order_item_id=plan_item.order_item_id
                       OR child.source_type='SUBCONTRACT_PREPARATION' AND child.source_ref='SC-PREP:'||plan_item.order_item_id::text)
                """).setParameter("planId", planId));
        for (Object[] row : rows) {
            UUID planItemId = (UUID) row[0];
            UUID holderId = (UUID) row[1];
            String holderType=(String)row[2];
            @SuppressWarnings("unchecked")
            List<Object[]> reservations = em.createNativeQuery("""
                    SELECT id, qty - consumed_qty - released_qty,
                           goods_id, color_id, warehouse_id,
                           supply_id, source_doc_id,released_qty
                    FROM stock_reservations
                    WHERE owner_type = 'SUBCONTRACT_OUTBOUND'
                      AND owner_id = :planItemId
                      AND status = 0 AND is_deleted = FALSE
                    ORDER BY created_at, id
                    FOR UPDATE
                    """).setParameter("planItemId", planItemId).getResultList();
            for (Object[] reservation : reservations) {
                BigDecimal slice = decimal(reservation[1]);
                if (slice.signum() <= 0) continue;
                em.createNativeQuery("""
                        UPDATE stock_reservations
                        SET released_qty = qty-consumed_qty, status = 1,
                            release_reason = 'SUBCONTRACT_PREPARED_ORDER_REVERSED',
                            lock_version = lock_version + 1,
                            updated_at = now(), updated_by = :actorId
                        WHERE id = :id
                        """).setParameter("actorId", actorUser)
                        .setParameter("id", reservation[0]).executeUpdate();
                em.createNativeQuery("""
                        INSERT INTO stock_reservations(
                            id, order_item_id, goods_id, color_id, warehouse_id,
                            qty, consumed_qty, released_qty, status, source,
                            source_doc_type, source_doc_id,
                            owner_type, owner_id, purpose, demand_id,
                            supply_type, supply_id, idempotency_key,
                            created_by, updated_by)
                        VALUES (
                            :id, NULL, :goodsId, :colorId, :warehouseId,
                            :qty, 0, 0, 0, 1,
                            'PRODUCTION_INBOUND', :sourceDocId,
                            :holderType, :holderId,
                            :holderType, NULL,
                            'PRODUCTION_FINISHED_IN', :supplyId, :key,
                            :actorId, :actorId)
                        """)
                        .setParameter("id", UUID.randomUUID())
                        .setParameter("goodsId", reservation[2])
                        .setParameter("colorId", reservation[3])
                        .setParameter("warehouseId", reservation[4])
                        .setParameter("qty", slice)
                        .setParameter("sourceDocId", reservation[6])
                        .setParameter("holderType",holderType).setParameter("holderId", holderId)
                        .setParameter("supplyId", reservation[5])
                        .setParameter("key", "SC-PREPARED-BACK:" + holderId + ':'
                                + reservation[0]+':'+decimal(reservation[7]).toPlainString())
                        .setParameter("actorId", actorUser)
                        .executeUpdate();
            }
        }
    }

    /** V458 订货行 → 前置自制账本批次 → 任务的谱系（无批次返回 null）。 */
    private PreparedLineage preparedLineage(UUID orderItemId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT DISTINCT task.id, task.warehouse_id,
                       task.analysis_id, task.preparation_item_id
                FROM subcontract_order_items order_item
                JOIN subcontract_order_item_sources src
                  ON src.order_item_id = order_item.id
                 AND src.alloc_qty>0
                JOIN subcontract_application_items application_item
                  ON application_item.id = src.application_item_id
                 AND application_item.is_deleted = FALSE
                JOIN preplan_subcontract_make_task_batches batch
                  ON batch.application_item_id = application_item.id
                JOIN preplan_subcontract_make_tasks task
                  ON task.id = batch.task_id
                 AND task.status = 'ACTIVE'
                WHERE order_item.id = :orderItemId
                  AND order_item.is_deleted = FALSE
                ORDER BY task.id
                """).setParameter("orderItemId", orderItemId));
        if (rows.isEmpty()) return null;
        if (rows.size() != 1) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "委外订货行对应多个前置自制任务，数据谱系异常，禁止自动出仓");
        }
        Object[] row = rows.getFirst();
        return new PreparedLineage((UUID) row[0], (UUID) row[1],
                (UUID) row[2], (UUID) row[3]);
    }

    private record PreparedLineage(
            UUID taskId, UUID warehouseId,
            UUID analysisId, UUID analysisItemId) {
    }

    private record DirectPreparedLineage(UUID analysisId,UUID analysisItemId,BigDecimal qty){}

    private DirectPreparedLineage directPreparedLineage(UUID orderItemId){
        List<Object[]> rows=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT child.analysis_id,child.id,SUM(reservation.qty-reservation.released_qty)
                FROM stock_reservations reservation
                JOIN stock_document_items item ON item.id=reservation.supply_id AND item.doc_id=reservation.source_doc_id
                JOIN production_plan_items production_item ON production_item.id=item.upstream_item_id
                JOIN production_plans plan ON plan.id=production_item.plan_id
                JOIN production_material_analysis_items child ON child.id=plan.material_analysis_item_id
                WHERE reservation.owner_type='SUBCONTRACT_ORDER_PREPARATION' AND reservation.owner_id=:orderItem
                  AND reservation.status=0 AND NOT reservation.is_deleted AND reservation.qty>reservation.released_qty
                  AND fn_subcontract_preparation_reservation_has_qualified_origin(reservation.id)
                GROUP BY child.analysis_id,child.id ORDER BY child.id
                """).setParameter("orderItem",orderItemId));
        if(rows.isEmpty())return null;
        if(rows.size()!=1)throw new ApiException(ErrorCode.CONFLICT,"原委外订货备料对应多份生产来源，请核对原分析后继续");
        Object[] row=rows.getFirst();return new DirectPreparedLineage((UUID)row[0],(UUID)row[1],decimal(row[2]));
    }

    /**
     * 释放任务持有的 SUBCONTRACT_PREPARE_TASK 预留切片（FIFO，至多 planned），
     * 并为计划行建立等量 SUBCONTRACT_OUTBOUND / PRODUCTION_FINISHED_IN 预留。
     */
    private void convertPreparationReservations(
            UUID planItemId, String holderType, UUID holderId, BigDecimal plannedQty, UUID actorUser) {
        List<Object[]> held = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT reservation.id, reservation.qty
                    - reservation.consumed_qty - reservation.released_qty,
                       reservation.goods_id, reservation.color_id,
                       reservation.warehouse_id, reservation.supply_id,
                       reservation.source_doc_id
                FROM stock_reservations reservation
                WHERE reservation.owner_type = :holderType
                  AND reservation.owner_id = :holderId
                  AND reservation.status = 0 AND reservation.is_deleted = FALSE
                  AND reservation.consumed_qty = 0
                ORDER BY reservation.created_at, reservation.id
                FOR UPDATE
                """).setParameter("holderType",holderType).setParameter("holderId", holderId));
        BigDecimal remaining = plannedQty;
        for (Object[] row : held) {
            if (remaining.signum() <= 0) break;
            UUID reservationId = (UUID) row[0];
            BigDecimal slice = decimal(row[1]).min(remaining);
            if (slice.signum() <= 0) continue;
            em.createNativeQuery("""
                    UPDATE stock_reservations
                    SET released_qty = released_qty + :slice,
                        status = CASE WHEN released_qty + :slice >= qty THEN 1 ELSE 0 END,
                        release_reason = 'SUBCONTRACT_PREPARED_ORDER_CONVERTED',
                        lock_version = lock_version + 1,
                        updated_at = now(), updated_by = :actorId
                    WHERE id = :id AND consumed_qty = 0
                      AND released_qty + :slice <= qty
                    """).setParameter("slice", slice)
                    .setParameter("actorId", actorUser)
                    .setParameter("id", reservationId).executeUpdate();
            em.createNativeQuery("""
                    INSERT INTO stock_reservations(
                        id, order_item_id, goods_id, color_id, warehouse_id,
                        qty, consumed_qty, released_qty, status, source,
                        source_doc_type, source_doc_id,
                        owner_type, owner_id, purpose, demand_id,
                        supply_type, supply_id, idempotency_key,
                        created_by, updated_by)
                    VALUES (
                        :id, NULL, :goodsId, :colorId, :warehouseId,
                        :qty, 0, 0, 0, 1,
                        'PRODUCTION_INBOUND', :sourceDocId,
                        'SUBCONTRACT_OUTBOUND', :planItemId,
                        'SUBCONTRACT_OUTBOUND', NULL,
                        'PRODUCTION_FINISHED_IN', :supplyId, :key,
                        :actorId, :actorId)
                    """)
                    .setParameter("id", UUID.randomUUID())
                    .setParameter("goodsId", row[2])
                    .setParameter("colorId", row[3])
                    .setParameter("warehouseId", row[4])
                    .setParameter("qty", slice)
                    .setParameter("sourceDocId", row[6])
                    .setParameter("planItemId", planItemId)
                    .setParameter("supplyId", row[5])
                    .setParameter("key", "SC-PREPARED-OUT:" + planItemId + ':' + reservationId)
                    .setParameter("actorId", actorUser)
                    .executeUpdate();
            remaining = remaining.subtract(slice);
        }
        if (remaining.signum() != 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "委外前置自制专属库存不足以覆盖订货量，请核对账本后重试");
        }
    }

    /**
     * 出仓审核同事务末段：按计划行回写 issued_qty（CAS 防超计划）；计划 OPEN 且仍有
     * 剩余量且无未审草稿时自动续生下一批草稿（分批出仓闭环）。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void syncAfterIssueApproved(UUID issueId) {
        @SuppressWarnings("unchecked")
        List<Object[]> lines = em.createNativeQuery("""
                SELECT id, plan_item_id, qty FROM subcontract_material_issue_items
                WHERE issue_id = :issueId AND plan_item_id IS NOT NULL
                """).setParameter("issueId", issueId).getResultList();
        if (lines.isEmpty()) {
            return;
        }
        UUID planId = null;
        for (Object[] line : lines) {
            UUID planItemId = (UUID) line[1];
            BigDecimal qty = decimal(line[2]);
            int updated = jdbc.update("""
                    UPDATE subcontract_material_plan_items
                    SET issued_qty = issued_qty + ?, updated_at = now()
                    WHERE id = ? AND is_deleted = FALSE
                      AND issued_qty + ? <= planned_qty
                    """, qty, planItemId, qty);
            if (updated != 1) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "出仓量超过发料计划余量，请刷新出仓任务后重试");
            }
            if (planId == null) {
                planId = jdbc.queryForObject("""
                        SELECT plan_id FROM subcontract_material_plan_items WHERE id = ?
                        """, UUID.class, planItemId);
            }
        }
        if (planId == null) {
            return;
        }
        jdbc.update("""
                UPDATE subcontract_material_plan_items
                SET preparation_status = 'OUTBOUND_COMPLETE',
                    preparation_version = preparation_version + 1,
                    updated_at = now()
                WHERE id IN (
                    SELECT DISTINCT plan_item_id
                    FROM subcontract_material_issue_items
                    WHERE issue_id = ? AND plan_item_id IS NOT NULL)
                  AND flow_mode IN ('DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND','COMPONENT_OUTBOUND')
                  AND issued_qty = planned_qty
                  AND preparation_status = 'READY_OUTBOUND'
                """, issueId);
        String status = jdbc.queryForObject("""
                SELECT status FROM subcontract_material_plans WHERE id = ?
                """, String.class, planId);
        if (!"OPEN".equals(status)) {
            throw new ApiException(ErrorCode.CONFLICT, "发料计划已关闭或取消，禁止继续出仓");
        }
        Long issuedNewFlowLines = jdbc.queryForObject("""
                SELECT COUNT(DISTINCT issue_item.plan_item_id)
                FROM subcontract_material_issue_items issue_item
                JOIN subcontract_material_plan_items plan_item
                  ON plan_item.id = issue_item.plan_item_id
                 AND plan_item.flow_mode IN (
                     'DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND','COMPONENT_OUTBOUND')
                 AND plan_item.is_deleted = FALSE
                WHERE issue_item.issue_id = ?
                  AND issue_item.plan_item_id IS NOT NULL
                  AND issue_item.is_deleted = FALSE
                """, Long.class, issueId);
        if (issuedNewFlowLines != null && issuedNewFlowLines > 0) {
            chainNotice.notifySubcontractOutboundCompleted(issueId);
        }
        // 分批闭环：审核后仍有剩余且已无未审草稿 → 自动续生下一批。
        if (remainingLines(planId).stream().anyMatch(row -> decimal(row[8]).signum() > 0)) {
            @SuppressWarnings("unchecked")
            List<Object[]> plan = em.createNativeQuery("""
                    SELECT p.order_bill_no, p.supplier_id, o.deliver_date
                    FROM subcontract_material_plans p
                    JOIN subcontract_orders o ON o.id = p.order_id
                    WHERE p.id = :id
                    """).setParameter("id", planId).getResultList();
            if (!plan.isEmpty()) {
                Object[] head = plan.getFirst();
                createDraftForPlan(planId, Objects.toString(head[0]), (UUID) head[1],
                        toLocalDate(head[2]),
                        currentUser.requireId());
            }
        }
    }

    /** 出仓红冲同事务：issued_qty 对称回减（不自动补草稿，由工作台手工补齐，避免抖动）。 */
    @Transactional(propagation = Propagation.MANDATORY)
    public void syncAfterIssueReversed(UUID issueId) {
        @SuppressWarnings("unchecked")
        List<Object[]> lines = em.createNativeQuery("""
                SELECT issue_item.plan_item_id, issue_item.qty, plan_item.flow_mode
                FROM subcontract_material_issue_items issue_item
                JOIN subcontract_material_plan_items plan_item
                  ON plan_item.id = issue_item.plan_item_id
                WHERE issue_item.issue_id = :issueId
                  AND issue_item.plan_item_id IS NOT NULL
                """).setParameter("issueId", issueId).getResultList();
        boolean reversedNewFlow = false;
        for (Object[] line : lines) {
            BigDecimal qty = decimal(line[1]);
            reversedNewFlow = reversedNewFlow
                    || List.of("DIRECT_OUTBOUND", "MAKE_THEN_OUTBOUND",
                            "PREPARED_OUTBOUND", "COMPONENT_OUTBOUND")
                    .contains(Objects.toString(line[2], ""));
            int updated = jdbc.update("""
                    UPDATE subcontract_material_plan_items
                    SET preparation_status = CASE
                            WHEN flow_mode IN ('DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND','COMPONENT_OUTBOUND')
                             AND preparation_status = 'OUTBOUND_COMPLETE'
                             AND GREATEST(issued_qty - ?, 0) < planned_qty
                            THEN 'READY_OUTBOUND' ELSE preparation_status END,
                        preparation_version = CASE
                            WHEN flow_mode IN ('DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND','COMPONENT_OUTBOUND')
                            THEN preparation_version + 1 ELSE preparation_version END,
                        issued_qty = GREATEST(issued_qty - ?, 0), updated_at = now()
                    WHERE id = ? AND is_deleted = FALSE
                    """, qty, qty, (UUID) line[0]);
            if (updated != 1) {
                throw new ApiException(ErrorCode.CONFLICT, "发料计划行已变化，请刷新后重试");
            }
        }
        if (reversedNewFlow) {
            chainNotice.notifySubcontractOutboundReversed(issueId);
        }
    }

    /** 订货红冲同事务：软删未审自动草稿 + 计划置 CANCELED（已审出仓由既有守卫先行拦截）。 */
    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public void requireOrderReversalAllowed(UUID orderId) {
        Long blocked = jdbc.queryForObject("""
                SELECT COUNT(*)
                FROM subcontract_material_plan_items plan_item
                JOIN subcontract_material_plans plan ON plan.id = plan_item.plan_id
                LEFT JOIN production_material_analyses analysis
                  ON analysis.id = plan_item.preparation_analysis_id
                WHERE plan.order_id = ?
                  AND plan.is_deleted = FALSE AND plan_item.is_deleted = FALSE
                  AND plan_item.flow_mode = 'MAKE_THEN_OUTBOUND'
                  AND plan_item.preparation_status IN (
                      'IN_PREPARATION','WAITING_FQC','WAITING_INBOUND')
                  AND (analysis.id IS NULL OR analysis.status <> 'CANCELLED')
                """, Long.class, orderId);
        if (blocked != null && blocked > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "委外订货仍有进行中的前置自制链；请先按成品入库/FQC/报工/DRAW/生产计划顺序反向并取消物料分析");
        }
    }

    /** Actual supplier-held obligations, expressed in the order's business unit.
     * Different components are parallel requirements; their target equivalents must never be summed.
     * Drafts and unconsumed reservations are future allocations and do not enter this bound.
     */
    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public BigDecimal minimumOrderQtyFromIssued(UUID orderItemId, BigDecimal orderUnitRate) {
        List<Object[]> rows=jdbc.query("""
                SELECT ii.goods_id,ii.color_id,
                       CASE WHEN pi.flow_mode IN ('DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
                            THEN 'TARGET' ELSE 'COMPONENT' END AS kind,
                       SUM(CASE WHEN pi.flow_mode IN ('DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
                            THEN GREATEST(ii.at_supplier_qty+COALESCE(ii.compensated_qty,0)-ii.consumed_qty-ii.returned_qty-ii.wasted_qty,0)*ii.unit_rate / ?
                            ELSE GREATEST(ii.at_supplier_qty+COALESCE(ii.compensated_qty,0)-ii.consumed_qty-ii.returned_qty-ii.wasted_qty,0) / NULLIF(ii.frozen_unit_qty,0) END),
                       BOOL_OR((pi.flow_mode IS NULL OR pi.flow_mode IN ('LEGACY_BOM_COMPONENT','COMPONENT_OUTBOUND'))
                           AND GREATEST(ii.at_supplier_qty-ii.returned_qty,0)>0
                           AND COALESCE(ii.frozen_unit_qty,0)<=0)
                FROM subcontract_material_issue_items ii
                JOIN subcontract_material_issues issue ON issue.id=ii.issue_id
                LEFT JOIN subcontract_material_plan_items pi ON pi.id=ii.plan_item_id
                WHERE ii.order_item_id=? AND issue.status=1 AND issue.is_deleted=FALSE AND ii.is_deleted=FALSE
                GROUP BY ii.goods_id,ii.color_id,kind
                """,(rs,n)->new Object[]{rs.getObject(1),rs.getObject(2),rs.getString(3),rs.getBigDecimal(4),rs.getBoolean(5)},
                orderUnitRate,orderItemId);
        BigDecimal minimum=BigDecimal.ZERO;
        for(Object[] row:rows) {
            if(Boolean.TRUE.equals(row[4])) throw new ApiException(ErrorCode.CONFLICT,
                    "历史委外实发缺少冻结单耗，不能推算减量下限，请先核实原出仓来源");
            minimum=minimum.max(decimal(row[3]));
        }
        return minimum.add(com.uten.imp.common.finance.ProcurementOrderQuantityBounds.receipts(em,"SUBCONTRACT",orderItemId)
                .minimumOrderedQty(orderUnitRate)).setScale(4,RoundingMode.CEILING);
    }

    /** Replenish the physical loss allowance without changing the commercial delivery target. */
    @Transactional(propagation=Propagation.MANDATORY)
    public void synchronizeWasteAllowance(UUID wasteId){
        List<UUID> plans=jdbc.queryForList("""
                SELECT DISTINCT plan.id FROM subcontract_waste_items waste
                JOIN subcontract_material_issue_items issue ON issue.id=waste.material_issue_item_id
                JOIN subcontract_material_plan_items item ON item.id=issue.plan_item_id
                JOIN subcontract_material_plans plan ON plan.id=item.plan_id
                WHERE waste.waste_id=? AND item.flow_mode='DIRECT_OUTBOUND' AND NOT item.is_deleted AND plan.status='OPEN'
                ORDER BY plan.id
                """,UUID.class,wasteId);
        for(UUID plan:plans)synchronizeDirectLossAllowance(plan);
    }

    private void synchronizeDirectLossAllowance(UUID planId){
        for(var row:jdbc.queryForList("""
                SELECT plan.id,plan.planned_qty,plan.issued_qty,plan.loss_replacement_qty_base,
                    GREATEST(COALESCE((SELECT SUM((issue.wasted_qty-COALESCE(issue.compensated_qty,0))*COALESCE(issue.unit_rate,1))
                        FROM subcontract_material_issue_items issue JOIN subcontract_material_issues header ON header.id=issue.issue_id
                        WHERE issue.plan_item_id=plan.id AND NOT issue.is_deleted AND header.status=1 AND NOT header.is_deleted),0),0) allowance
                FROM subcontract_material_plan_items plan
                WHERE plan.plan_id=? AND plan.flow_mode='DIRECT_OUTBOUND' AND NOT plan.is_deleted
                ORDER BY plan.id FOR UPDATE OF plan
                """,planId)){
            BigDecimal allowance=(BigDecimal)row.get("allowance");
            BigDecimal planned=((BigDecimal)row.get("planned_qty")).subtract((BigDecimal)row.get("loss_replacement_qty_base")).add(allowance)
                    .max((BigDecimal)row.get("issued_qty"));
            jdbc.update("""
                    UPDATE subcontract_material_plan_items SET planned_qty=?,prepared_qty=?,loss_replacement_qty_base=?,
                        preparation_status=CASE WHEN issued_qty=? THEN 'OUTBOUND_COMPLETE' ELSE 'READY_OUTBOUND' END,
                        preparation_version=preparation_version+1,updated_at=now() WHERE id=?
                    """,planned,planned,allowance,planned,row.get("id"));
        }
    }

    /**
     * V486 批准后改量的计划行对账（与订货 changeQty 同事务）：
     * 减量收回尚未履行的出仓安排，草稿和未消费预留同步撤回；毛实发与实退历史保留。
     * 增量无子层建 DIRECT READY 行并通知出仓，
     * 有子层建 MAKE_THEN 行并自动发单给计划。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void applyOrderQtyChange(
            UUID orderId, Map<UUID, BigDecimal> baseDeltaByOrderItemId,
            Map<UUID, BigDecimal> unitRateByOrderItemId,
            Map<UUID, UUID> goodsColorByOrderItemId) {
        lockOrderInventoryDimensions(orderId);
        UUID actorUser = currentUser.requireId();
        for (Map.Entry<UUID, BigDecimal> change
                : baseDeltaByOrderItemId.entrySet()) {
            UUID orderItemId = change.getKey();
            BigDecimal baseDelta = change.getValue();
            if (baseDelta.signum() == 0) {
                continue;
            }
            if (baseDelta.signum() < 0) {
                shrinkOrderItemLines(orderId, orderItemId,unitRateByOrderItemId.get(orderItemId));
                continue;
            }
            extendOrderItemLines(
                    orderId, orderItemId, baseDelta,
                    unitRateByOrderItemId.get(orderItemId),
                    goodsColorByOrderItemId.get(orderItemId), actorUser);
        }
    }

    /** planned is a gross authorization: new target + proven returns + physical loss allowance,
     * never below gross issues. Loss replenishment does not increase the commercial delivery target.
     * Completed PREP output belongs to its original task; reducing this order returns only unused rights.
     * An already started MAKE_THEN analysis keeps its frozen production requirement until explicitly reversed.
     */
    private void shrinkOrderItemLines(
            UUID orderId, UUID orderItemId, BigDecimal orderUnitRate) {
        List<Object[]> lines = jdbc.query("""
                SELECT item.id, item.planned_qty, item.issued_qty, item.prepared_qty,
                       item.flow_mode,item.plan_id,item.goods_id,item.color_id,item.bom_unit_qty,
                       COALESCE((SELECT SUM(ii.returned_qty)
                                 FROM subcontract_material_issue_items ii
                                 JOIN subcontract_material_issues i
                                   ON i.id = ii.issue_id
                                 WHERE ii.plan_item_id = item.id
                                   AND i.status = 1 AND ii.is_deleted=FALSE
                                   AND i.is_deleted = FALSE), 0) AS returned_qty,
                       item.preparation_analysis_id,item.loss_replacement_qty_base,
                       COALESCE((SELECT SUM(ii.wasted_qty)
                                 FROM subcontract_material_issue_items ii
                                 JOIN subcontract_material_issues i
                                   ON i.id = ii.issue_id
                                 WHERE ii.plan_item_id = item.id
                                   AND i.status = 1 AND ii.is_deleted=FALSE
                                   AND i.is_deleted = FALSE), 0) AS wasted_qty
                FROM subcontract_material_plan_items item
                JOIN subcontract_material_plans plan ON plan.id = item.plan_id
                WHERE item.order_item_id = ?
                  AND plan.order_id = ?
                  AND plan.status = 'OPEN'
                  AND plan.is_deleted = FALSE
                  AND item.is_deleted = FALSE
                ORDER BY plan.id,item.line_no,item.id
                FOR UPDATE OF plan,item
                """, (rs, rowNum) -> new Object[]{
                rs.getObject(1, UUID.class),
                rs.getBigDecimal(2), rs.getBigDecimal(3), rs.getBigDecimal(4),
                rs.getString(5),rs.getObject(6,UUID.class),rs.getObject(7,UUID.class),rs.getObject(8,UUID.class),
                rs.getBigDecimal(9),rs.getBigDecimal(10),rs.getObject(11,UUID.class),rs.getBigDecimal(12),
                rs.getBigDecimal(13)},
                orderItemId, orderId);
        BigDecimal targetOrderQty=jdbc.queryForObject("SELECT qty FROM subcontract_order_items WHERE id=?",BigDecimal.class,orderItemId);
        Map<String,List<Object[]>> groups=new LinkedHashMap<>();
        // 发子件的两种流向（V304 LEGACY 与 V581 COMPONENT_OUTBOUND）按子件分组，
        // 换算因子取各自冻结单耗；发目标件的三种流向共用订货换算率。
        for(Object[] line:lines) groups.computeIfAbsent(issuesComponent(line[4])
                ? "COMPONENT:"+line[6]+":"+line[7] : "TARGET",ignored->new ArrayList<>()).add(line);
        Map<UUID,BigDecimal> reductions=new LinkedHashMap<>();
        for(var group:groups.values()) {
            BigDecimal factor=issuesComponent(group.getFirst()[4])
                    ? decimal(group.getFirst()[8]) : orderUnitRate;
            if(factor.signum()<=0 || group.stream().anyMatch(line -> issuesComponent(line[4])
                    && decimal(line[8]).compareTo(decimal(group.getFirst()[8]))!=0))
                throw new ApiException(ErrorCode.CONFLICT,"历史同子料的冻结单耗不一致，不能自动改量");
            // 计划量该留多少 = 新订货量折算 + 已精确退回的材料 + 损耗头寸。
            // 损耗头寸按流向取数，两处来源记的是同一批料、严禁叠加：
            // DIRECT 行的补量额度就是 synchronizeDirectLossAllowance 从 wasted_qty 推出来的
            // (批准那一刻已经加进 planned)，只认额度；其余流向(COMPONENT 被 V581 焊死额度=0、
            // LEGACY/前置自制根本没有额度同步)只能认 wasted_qty 本身——否则结案第一步刚把
            // 供应商处那份料核销掉，planned 一点都收不回来(take = planned − issued = 0)，
            // 剩余差额只能抛「新数量仍低于已实发或进行中的前置生产量」把整笔结案回滚。
            BigDecimal target=targetOrderQty.multiply(factor).setScale(4,RoundingMode.HALF_UP)
                    .add(group.stream()
                            .map(line->decimal(line[9]).add(decimal(line[11]))
                                    .add("DIRECT_OUTBOUND".equals(line[4]) ? BigDecimal.ZERO : decimal(line[12])))
                            .reduce(BigDecimal.ZERO,BigDecimal::add));
            BigDecimal remaining=group.stream().map(line->decimal(line[1])).reduce(BigDecimal.ZERO,BigDecimal::add)
                    .subtract(target).max(BigDecimal.ZERO);
            for(Object[] line:group) {
                // Linked MAKE_THEN requirements cannot be silently rewritten beneath an existing analysis.
                BigDecimal locked="MAKE_THEN_OUTBOUND".equals(line[4]) && line[10]!=null
                        ? decimal(line[1]) : decimal(line[2]);
                BigDecimal take=decimal(line[1]).subtract(locked).max(BigDecimal.ZERO).min(remaining);
                if(take.signum()>0) reductions.put((UUID)line[0],take);
                remaining=remaining.subtract(take);
            }
            if(remaining.signum()>0) throw new ApiException(ErrorCode.CONFLICT,
                    "新数量仍低于已实发或进行中的前置生产量；请先完成精确退料或反向前置生产后再改量");
        }
        if(reductions.isEmpty()) return; // e.g. issued 10, returned 2, order 10 -> 8: gross plan stays 10.
        List<UUID> affectedDrafts=jdbc.queryForList("""
                SELECT issue.id FROM subcontract_material_issues issue
                WHERE issue.status=0 AND issue.is_deleted=FALSE AND EXISTS(
                    SELECT 1 FROM subcontract_material_issue_items ii
                    JOIN subcontract_material_plan_items pi ON pi.id=ii.plan_item_id
                    WHERE ii.issue_id=issue.id AND pi.order_item_id=?)
                ORDER BY issue.id FOR UPDATE
                """,UUID.class,orderItemId);
        for(UUID draftId:affectedDrafts) {
            releaseDraftReservations(draftId);
            jdbc.update("UPDATE subcontract_material_issues SET is_deleted=TRUE,deleted_at=now(),updated_at=now() WHERE id=?",draftId);
        }
        for(Object[] line:lines) {
            BigDecimal take=reductions.get((UUID)line[0]);
            if(take==null) continue;
            BigDecimal newPlanned=decimal(line[1]).subtract(take);
            if("PREPARED_OUTBOUND".equals(line[4])) restorePreparedSlice((UUID)line[0],take,currentUser.requireId());
            if(newPlanned.signum()==0) {
                // Preserve the positive historical authorization, while retiring its unused live capacity.
                jdbc.update("""
                        UPDATE subcontract_material_plan_items
                        SET is_deleted=TRUE,deleted_at=now(),preparation_status='CANCELLED',
                            preparation_version=preparation_version+1,updated_at=now()
                        WHERE id = ?
                        """,line[0]);
            } else {
                jdbc.update("""
                        UPDATE subcontract_material_plan_items SET planned_qty=?,
                            prepared_qty=CASE WHEN flow_mode IN ('DIRECT_OUTBOUND','PREPARED_OUTBOUND','LEGACY_BOM_COMPONENT','COMPONENT_OUTBOUND')
                                THEN ? ELSE LEAST(prepared_qty,?) END,
                            preparation_status=CASE WHEN flow_mode IN ('DIRECT_OUTBOUND','PREPARED_OUTBOUND','COMPONENT_OUTBOUND')
                                AND issued_qty=? THEN 'OUTBOUND_COMPLETE' ELSE preparation_status END,
                            preparation_version=preparation_version+1,updated_at=now()
                        WHERE id=?
                        """,newPlanned,newPlanned,newPlanned,newPlanned,line[0]);
            }
        }
        for(UUID planId:lines.stream().map(line->(UUID)line[5]).distinct().toList()) {
            var head=jdbc.queryForMap("SELECT plan.order_bill_no,plan.supplier_id,orders.deliver_date FROM subcontract_material_plans plan JOIN subcontract_orders orders ON orders.id=plan.order_id WHERE plan.id=?",planId);
            createDraftForPlan(planId,(String)head.get("order_bill_no"),(UUID)head.get("supplier_id"),toLocalDate(head.get("deliver_date")),currentUser.requireId());
        }
    }

    private void restorePreparedSlice(UUID planItemId,BigDecimal amount,UUID actorId) {
        Map<String,Object> holder=jdbc.queryForMap("""
                SELECT COALESCE(task.id,child.subcontract_order_item_id,
                        CASE WHEN child.source_ref='SC-PREP:'||pi.order_item_id::text THEN pi.order_item_id END) AS holder_id,
                    CASE WHEN task.id IS NULL THEN 'SUBCONTRACT_ORDER_PREPARATION' ELSE 'SUBCONTRACT_PREPARE_TASK' END AS holder_type
                FROM subcontract_material_plan_items pi
                LEFT JOIN preplan_subcontract_make_tasks task ON pi.preparation_analysis_id=task.analysis_id
                    AND pi.preparation_analysis_item_id=task.preparation_item_id
                LEFT JOIN production_material_analysis_items child ON child.id=pi.preparation_analysis_item_id
                WHERE pi.id=?
                """,planItemId);
        if(holder.get("holder_id")==null)throw new ApiException(ErrorCode.CONFLICT,"委外前置备料没有明确原任务或原订货归属");
        List<Object[]> reservations=jdbc.query("""
                SELECT id,qty-consumed_qty-released_qty,goods_id,color_id,warehouse_id,supply_id,source_doc_id,released_qty
                FROM stock_reservations WHERE owner_type='SUBCONTRACT_OUTBOUND' AND owner_id=?
                  AND supply_type='PRODUCTION_FINISHED_IN' AND status=0 AND is_deleted=FALSE
                  AND qty-consumed_qty-released_qty>0 ORDER BY created_at,id FOR UPDATE
                """,(rs,n)->new Object[]{rs.getObject(1,UUID.class),rs.getBigDecimal(2),rs.getObject(3,UUID.class),
                    rs.getObject(4,UUID.class),rs.getObject(5,UUID.class),rs.getObject(6,UUID.class),rs.getObject(7,UUID.class),rs.getBigDecimal(8)},planItemId);
        BigDecimal remaining=amount;
        for(Object[] reservation:reservations) {
            BigDecimal take=decimal(reservation[1]).min(remaining);
            if(take.signum()<=0) continue;
            jdbc.update("""
                    UPDATE stock_reservations SET released_qty=released_qty+?,
                        status=CASE WHEN consumed_qty+released_qty+?=qty THEN 1 ELSE 0 END,
                        release_reason='SUBCONTRACT_ORDER_QTY_REDUCED',lock_version=lock_version+1,
                        updated_at=now(),updated_by=? WHERE id=?
                    """,take,take,actorId,reservation[0]);
            jdbc.update("""
                    INSERT INTO stock_reservations(id,goods_id,color_id,warehouse_id,qty,consumed_qty,released_qty,status,source,
                        source_doc_type,source_doc_id,owner_type,owner_id,purpose,supply_type,supply_id,idempotency_key,created_by,updated_by)
                    VALUES (?,?,?,?,?,0,0,0,1,'PRODUCTION_INBOUND',?,?,?,?,
                        'PRODUCTION_FINISHED_IN',?,?,?,?)
                    """,UUID.randomUUID(),reservation[2],reservation[3],reservation[4],take,reservation[6],
                    holder.get("holder_type"),holder.get("holder_id"),holder.get("holder_type"),reservation[5],
                    "SC-PREP-QTY-BACK:"+reservation[0]+":"+decimal(reservation[7]).add(take).toPlainString(),actorId,actorId);
            remaining=remaining.subtract(take);
        }
        if(remaining.signum()!=0) throw new ApiException(ErrorCode.CONFLICT,"前置自制未消费预留不足，不能回收订单权益");
    }

    /** 增量：无子层 DIRECT READY（补通知出仓），有子层 MAKE_THEN 自动发单计划。 */
    private void extendOrderItemLines(
            UUID orderId, UUID orderItemId, BigDecimal increase,
            BigDecimal orderUnitRate, UUID goodsId, UUID actorUser) {
        Map<String, Object> item = jdbc.queryForMap("""
                SELECT item.color_id, goods.unit_id, item.unit_rate,
                       COALESCE(application.warehouse_id, orders.warehouse_id)
                           AS suggested_warehouse
                FROM subcontract_order_items item
                JOIN subcontract_orders orders ON orders.id = item.order_id
                JOIN goods ON goods.id = item.goods_id
                LEFT JOIN subcontract_application_items application_item
                  ON application_item.id = item.application_item_id
                LEFT JOIN subcontract_applications application
                  ON application.id = application_item.application_id
                WHERE item.id = ?
                """, orderItemId);
        Object[] orderHead = jdbc.query("""
                SELECT plan.id, plan.order_bill_no, plan.supplier_id,
                       COALESCE(orders.deliver_date, CURRENT_DATE)
                FROM subcontract_material_plans plan
                JOIN subcontract_orders orders ON orders.id = plan.order_id
                WHERE plan.order_id = ? AND plan.status = 'OPEN'
                  AND plan.is_deleted = FALSE
                ORDER BY plan.created_at
                LIMIT 1
                """, (rs, rowNum) -> new Object[]{
                rs.getObject(1, UUID.class), rs.getString(2),
                rs.getObject(3, UUID.class),
                rs.getObject(4, LocalDate.class)}, orderId).stream()
                .findFirst().orElse(null);
        if (orderHead == null) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "订货单没有 OPEN 状态的出仓计划，无法扩量；请红冲后重新下单");
        }
        UUID planId = (UUID) orderHead[0];
        Integer maxLineNo = jdbc.queryForObject(
                "SELECT MAX(line_no) FROM subcontract_material_plan_items WHERE plan_id = ?",
                Integer.class, planId);
        int lineNo = (maxLineNo == null ? 0 : maxLineNo) + 1;
        // 批准后增量：按当前 BOM 事实重判流向。原实现查的是 goods_bom_items
        // 根本不存在的 parent_goods_id/goods.active 两列（真库必 42703），
        // 且 INSERT 漏了 bom_snapshot_chk 要求的 preparation_bom_fingerprint，
        // 这条路径今天走不通；V581 顺手按批准同款口径修好。
        BomSnapshot bom = currentBomSnapshot(goodsId);
        SoleComponent sole = soleOutboundComponent(goodsId);
        boolean children = bom.hasChildren();
        UUID lineId = UUID.randomUUID();
        UUID unitId = (UUID) item.get("unit_id");
        UUID colorId = (UUID) item.get("color_id");
        UUID suggestedWarehouse = (UUID) item.get("suggested_warehouse");
        BigDecimal frozenRate = orderUnitRate == null ? BigDecimal.ONE : orderUnitRate;
        BigDecimal componentUnitQty = sole == null ? null
                : frozenRate.multiply(sole.bomQty()).setScale(6, RoundingMode.HALF_UP);
        // increase 已是目标件基本量；子件量 = 目标件基本量 × 每基本单位单耗
        //（与批准路径的 orderQty × bom_unit_qty 恒等，但不必再除一次换算率）。
        BigDecimal componentIncrease = sole == null ? null
                : increase.multiply(sole.bomQty()).setScale(4, RoundingMode.HALF_UP);
        boolean component = componentUnitQty != null && componentUnitQty.signum() > 0
                && componentIncrease != null && componentIncrease.signum() > 0;
        String flowMode = component ? "COMPONENT_OUTBOUND"
                : children ? "MAKE_THEN_OUTBOUND" : "DIRECT_OUTBOUND";
        boolean makeFirst = "MAKE_THEN_OUTBOUND".equals(flowMode);
        BigDecimal plannedQty = component ? componentIncrease : increase;
        jdbc.update("""
                INSERT INTO subcontract_material_plan_items(
                    id, plan_id, order_item_id, line_no,
                    parent_goods_id, parent_color_id,
                    goods_id, color_id, unit_id, unit_rate,
                    bom_unit_qty, planned_qty, issued_qty,
                    flow_mode, preparation_status, prepared_qty,
                    preparation_warehouse_id, preparation_version,
                    bom_has_children_snapshot, preparation_bom_fingerprint,
                    created_by, updated_by)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, 0,
                        ?, ?, ?, ?, 0, ?, ?, ?, ?)
                """,
                lineId, planId, orderItemId, lineNo,
                goodsId, colorId,
                component ? sole.goodsId() : goodsId,
                component ? sole.colorId() : colorId,
                component ? sole.unitId() : unitId,
                component ? componentUnitQty : frozenRate,
                plannedQty,
                flowMode,
                makeFirst ? "ACTION_REQUIRED" : "READY_OUTBOUND",
                makeFirst ? BigDecimal.ZERO : plannedQty,
                // ADR-101：COMPONENT 行发的是**子件**，而 suggested_warehouse 取的是
                // COALESCE(申请收货仓, 订货收货仓)——那是**目标件**回厂要进的仓。把它写成子件的
                // 发料仓，reserveDraft 就会跑到一个根本不放子件的仓上查库存，订货改量会被一句
                // 「待发子件在该仓的合格可动用库存不足」顶回来，与改量这件事毫无关系。
                // 留空交给 draftLineCappedByStock 按子件实际有货的叶仓来选，与批准路径同一口径。
                component ? null : suggestedWarehouse,
                children, bom.fingerprint(), actorUser, actorUser);
        if (makeFirst) {
            chainNotice.notifySubcontractPrepareShortage(lineId);
            orderPreparation.autoStartPlanLinePreparation(lineId);
        } else {
            chainNotice.notifySubcontractOutboundReady(lineId);
            createDraftForPlan(planId, (String) orderHead[1],
                    (UUID) orderHead[2], (LocalDate) orderHead[3], actorUser);
        }
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void cancelForOrderReversal(UUID orderId) {
        lockOrderInventoryDimensions(orderId);
        UUID actorUser = currentUser.requireId();
        List<UUID> planIds = jdbc.queryForList("""
                SELECT id FROM subcontract_material_plans
                WHERE order_id = ? AND is_deleted = FALSE AND status = 'OPEN'
                """, UUID.class, orderId);
        for (UUID planId : planIds) {
            // V458：PREPARED_OUTBOUND 行的未消费预留先转回任务持有（申请仍有效，
            // 可再次分解订货），避免释放回公共池后被其它需求抢走。
            restorePrepareTaskReservations(planId, actorUser);
            releasePlanReservations(planId, "SUBCONTRACT_ORDER_REVERSED");
            jdbc.update("""
                    UPDATE subcontract_material_issues SET is_deleted = TRUE, deleted_at = now()
                    WHERE status = 0 AND is_deleted = FALSE AND id IN (
                        SELECT DISTINCT ii.issue_id FROM subcontract_material_issue_items ii
                        JOIN subcontract_material_plan_items pi ON pi.id = ii.plan_item_id
                        WHERE pi.plan_id = ?)
                    """, planId);
            jdbc.update("""
                    UPDATE subcontract_material_plans
                    SET status = 'CANCELED', updated_at = now() WHERE id = ?
                    """, planId);
            jdbc.update("""
                    UPDATE subcontract_material_plan_items
                    SET preparation_status = 'CANCELLED',
                        preparation_version = preparation_version + 1,
                        updated_at = now()
                    WHERE plan_id = ? AND flow_mode IN (
                        'DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND','COMPONENT_OUTBOUND')
                    """, planId);
        }
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void afterFinishedInboundApproved(
            UUID stockDocumentId, UUID warehouseId) {
        holdDirectOrderPreparationOutput(stockDocumentId, warehouseId);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT plan_item.id, plan_item.plan_id, stock_item.id,
                       stock_item.goods_id, stock_item.color_id,
                       stock_item.qty * COALESCE(stock_item.unit_rate, 1),
                       plan_item.preparation_warehouse_id,
                       plan_item.planned_qty, plan_item.prepared_qty,
                       plan.order_bill_no, plan.supplier_id, order_header.deliver_date,
                       production_plan.material_analysis_id,
                       production_plan.material_analysis_item_id,
                       analysis_link.analysis_id, analysis_link.analysis_item_id,
                       analysis_link.allocation_status,
                       production_item.goods_id, production_item.color_id,
                       production_item.unit_id, production_item.unit_rate,
                       stock_item.unit_id, stock_item.unit_rate,
                       plan_item.goods_id, plan_item.color_id, plan_item.unit_id,
                       plan_item.preparation_analysis_id,
                       plan_item.preparation_analysis_item_id,
                       production_plan.status, stock_doc.warehouse_id
                FROM stock_document_items stock_item
                JOIN stock_documents stock_doc
                  ON stock_doc.id = stock_item.doc_id
                 AND stock_doc.status = 1 AND stock_doc.is_deleted = FALSE
                JOIN production_plan_items production_item
                  ON production_item.id = stock_item.upstream_item_id
                 AND production_item.is_deleted = FALSE
                JOIN production_plans production_plan
                  ON production_plan.id = production_item.plan_id
                 AND production_plan.is_deleted = FALSE
                JOIN subcontract_material_plan_items plan_item
                  ON plan_item.preparation_analysis_id =
                     production_plan.material_analysis_id
                 AND plan_item.preparation_analysis_item_id =
                     production_plan.material_analysis_item_id
                 AND plan_item.flow_mode = 'MAKE_THEN_OUTBOUND'
                 AND plan_item.is_deleted = FALSE
                LEFT JOIN production_material_analysis_plan_links analysis_link
                  ON analysis_link.plan_id = production_plan.id
                 AND analysis_link.analysis_id = plan_item.preparation_analysis_id
                 AND analysis_link.analysis_item_id =
                     plan_item.preparation_analysis_item_id
                JOIN subcontract_material_plans plan
                  ON plan.id = plan_item.plan_id AND plan.status = 'OPEN'
                 AND plan.is_deleted = FALSE
                JOIN subcontract_orders order_header ON order_header.id = plan.order_id
                WHERE stock_item.doc_id = :documentId
                  AND stock_item.bill_type = 'FINISHED_IN'
                  AND stock_item.is_deleted = FALSE
                ORDER BY plan_item.id, stock_item.id
                FOR UPDATE OF plan_item
                """).setParameter("documentId", stockDocumentId).getResultList();
        if (rows.isEmpty()) return;
        UUID actorId = currentUser.requireId();
        java.util.Set<UUID> readyPlans = new java.util.LinkedHashSet<>();
        java.util.Set<UUID> notifyPlans = new java.util.LinkedHashSet<>();
        java.util.Map<UUID, Object[]> planHeads = new LinkedHashMap<>();
        java.util.Map<UUID, BigDecimal> preparedByPlanItem = new HashMap<>();
        for (Object[] row : rows) {
            UUID planItemId = (UUID) row[0];
            UUID planId = (UUID) row[1];
            UUID stockItemId = (UUID) row[2];
            BigDecimal baseQty = decimal(row[5]);
            UUID preparationAnalysisId = (UUID) row[26];
            UUID preparationAnalysisItemId = (UUID) row[27];
            BigDecimal productionRate = row[20] == null
                    ? BigDecimal.ONE : decimal(row[20]);
            BigDecimal stockRate = row[22] == null
                    ? BigDecimal.ONE : decimal(row[22]);
            boolean exactLineage = Objects.equals(row[12], preparationAnalysisId)
                    && Objects.equals(row[13], preparationAnalysisItemId)
                    && Objects.equals(row[14], preparationAnalysisId)
                    && Objects.equals(row[15], preparationAnalysisItemId)
                    && "APPROVED".equals(row[16]);
            boolean exactDimension = Objects.equals(row[17], row[23])
                    && Objects.equals(row[18], row[24])
                    && Objects.equals(row[19], row[25])
                    && Objects.equals(row[3], row[23])
                    && Objects.equals(row[4], row[24])
                    && Objects.equals(row[21], row[25])
                    && productionRate.compareTo(BigDecimal.ONE) == 0
                    && stockRate.compareTo(BigDecimal.ONE) == 0;
            if (!exactLineage || !exactDimension
                    || row[28] == null || ((Number) row[28]).shortValue() != 1) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "成品实收入库与委外前置分析目标计划行的 UUID、货色、单位或换算率不一致");
            }
            if (!Objects.equals(row[29], warehouseId)) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "委外前置自制预留仓与真实成品实收单据不一致");
            }
            if (baseQty.signum() <= 0) continue;
            String idempotencyKey = "SC-OUT-MAKE-IN:" + stockItemId;
            Number existing = (Number) em.createNativeQuery("""
                    SELECT COUNT(*) FROM stock_reservations
                    WHERE idempotency_key = :key
                    """).setParameter("key", idempotencyKey).getSingleResult();
            if (existing.longValue() > 0) continue;
            UUID reservationId = UUID.randomUUID();
            em.createNativeQuery("""
                    INSERT INTO stock_reservations(
                        id, order_item_id, goods_id, color_id, warehouse_id,
                        qty, consumed_qty, released_qty, status, source,
                        source_doc_type, source_doc_id,
                        owner_type, owner_id, purpose, demand_id,
                        supply_type, supply_id, idempotency_key,
                        created_by, updated_by)
                    VALUES (
                        :id, NULL, :goodsId, :colorId, :warehouseId,
                        :qty, 0, 0, 0, 1,
                        'PRODUCTION_INBOUND', :documentId,
                        'SUBCONTRACT_OUTBOUND', :planItemId,
                        'SUBCONTRACT_OUTBOUND', NULL,
                        'PRODUCTION_FINISHED_IN', :stockItemId, :key,
                        :actorId, :actorId)
                    """)
                    .setParameter("id", reservationId)
                    .setParameter("goodsId", row[3])
                    .setParameter("colorId", row[4])
                    .setParameter("warehouseId", warehouseId)
                    .setParameter("qty", baseQty)
                    .setParameter("documentId", stockDocumentId)
                    .setParameter("planItemId", planItemId)
                    .setParameter("stockItemId", stockItemId)
                    .setParameter("key", idempotencyKey)
                    .setParameter("actorId", actorId)
                    .executeUpdate();
            int updated = em.createNativeQuery("""
                    UPDATE subcontract_material_plan_items
                    SET prepared_qty = prepared_qty + :qty,
                        preparation_status = CASE
                            WHEN prepared_qty + :qty > 0
                            THEN 'READY_OUTBOUND' ELSE 'WAITING_INBOUND' END,
                        preparation_version = preparation_version + 1,
                        updated_at = now(), updated_by = :actorId
                    WHERE id = :id
                      AND flow_mode = 'MAKE_THEN_OUTBOUND'
                      AND preparation_status IN (
                          'IN_PREPARATION','WAITING_FQC','WAITING_INBOUND','READY_OUTBOUND')
                      AND prepared_qty + :qty <= planned_qty
                    """)
                    .setParameter("qty", baseQty)
                    .setParameter("actorId", actorId)
                    .setParameter("id", planItemId)
                    .executeUpdate();
            if (updated != 1) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "委外前置自制实收量超过订货目标量或任务状态已变化");
            }
            BigDecimal preparedAfter = preparedByPlanItem
                    .getOrDefault(planItemId, decimal(row[8]))
                    .add(baseQty);
            preparedByPlanItem.put(planItemId, preparedAfter);
            // V458 分批出仓：首片实收即释放可出仓（可出仓量=LEAST(planned,prepared)-issued）。
            // 通知只在「首次可得」与「整批完成」两个节点发出，避免每片打扰仓库；
            // 中途追加的可出仓量由任务投影与续生草稿体现。
            boolean firstAvailability = decimal(row[8]).signum() == 0
                    && preparedAfter.signum() > 0;
            boolean completed = preparedAfter.compareTo(decimal(row[7])) >= 0;
            readyPlans.add(planId);
            planHeads.put(planId, new Object[]{row[9], row[10], row[11], planItemId});
            if (firstAvailability || completed) notifyPlans.add(planId);
        }
        for (UUID planId : readyPlans) {
            Object[] head = planHeads.get(planId);
            createDraftForPlan(planId, Objects.toString(head[0]), (UUID) head[1],
                    toLocalDate(head[2]), actorId);
            if (notifyPlans.contains(planId)) chainNotice.notifySubcontractOutboundReady((UUID) head[3]);
        }
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void beforeFinishedInboundReversed(UUID stockDocumentId) {
        releaseDirectOrderPreparationOutput(stockDocumentId);
        @SuppressWarnings("unchecked")
        List<Object[]> reservations = em.createNativeQuery("""
                SELECT reservation.id, reservation.owner_id, reservation.qty,
                       reservation.consumed_qty, reservation.released_qty
                FROM stock_reservations reservation
                WHERE reservation.owner_type = 'SUBCONTRACT_OUTBOUND'
                  AND reservation.supply_type = 'PRODUCTION_FINISHED_IN'
                  AND reservation.source_doc_type = 'PRODUCTION_INBOUND'
                  AND reservation.source_doc_id = :documentId
                  AND reservation.is_deleted = FALSE
                ORDER BY reservation.owner_id, reservation.id
                FOR UPDATE
                """).setParameter("documentId", stockDocumentId).getResultList();
        UUID actorId = currentUser.requireId();
        for (Object[] row : reservations) {
            UUID reservationId = (UUID) row[0];
            UUID planItemId = (UUID) row[1];
            BigDecimal qty = decimal(row[2]);
            if (decimal(row[3]).signum() > 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "前置自制目标件已经委外出仓，必须先红冲委外出仓再红冲成品入库");
            }
            Number drafts = (Number) em.createNativeQuery("""
                    SELECT COUNT(*)
                    FROM subcontract_material_issue_items issue_item
                    JOIN subcontract_material_issues issue
                      ON issue.id = issue_item.issue_id
                    WHERE issue_item.plan_item_id = :planItemId
                      AND issue.status = 0 AND issue.is_deleted = FALSE
                    """).setParameter("planItemId", planItemId).getSingleResult();
            if (drafts.longValue() > 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "前置自制目标件已有委外出仓草稿，请先删除草稿再红冲成品入库");
            }
            if (decimal(row[4]).compareTo(qty) < 0) {
                em.createNativeQuery("""
                        UPDATE stock_reservations
                        SET released_qty = qty, status = 1,
                            release_reason = 'PRODUCTION_FINISHED_IN_REVERSED',
                            lock_version = lock_version + 1,
                            updated_at = now(), updated_by = :actorId
                        WHERE id = :id AND consumed_qty = 0
                        """).setParameter("actorId", actorId)
                        .setParameter("id", reservationId).executeUpdate();
                int updated = em.createNativeQuery("""
                        UPDATE subcontract_material_plan_items
                        SET prepared_qty = prepared_qty - :qty,
                            preparation_status = 'WAITING_INBOUND',
                            preparation_version = preparation_version + 1,
                            updated_at = now(), updated_by = :actorId
                        WHERE id = :id AND prepared_qty >= :qty
                          AND issued_qty <= prepared_qty - :qty
                        """).setParameter("qty", qty)
                        .setParameter("actorId", actorId)
                        .setParameter("id", planItemId).executeUpdate();
                if (updated != 1) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "委外前置自制专属数量已被使用，禁止红冲成品入库");
                }
            }
        }
    }

    /** System draft save: atomically replace its direct-stock reservation. */
    @Transactional(propagation = Propagation.MANDATORY)
    public void reserveDraft(UUID issueId, UUID warehouseId) {
        if (warehouseId == null) return;
        @SuppressWarnings("unchecked")
        List<Object[]> lines = em.createNativeQuery("""
                SELECT issue_item.id, issue_item.plan_item_id, issue_item.qty,
                       plan_item.goods_id, plan_item.color_id,
                       plan_item.flow_mode, plan_item.preparation_status,
                       plan_item.preparation_warehouse_id,
                       plan_item.bom_has_children_snapshot,
                       plan_item.preparation_bom_fingerprint,
                       plan_item.parent_goods_id
                FROM subcontract_material_issue_items issue_item
                JOIN subcontract_material_issues issue
                  ON issue.id = issue_item.issue_id
                 AND issue.status = 0 AND issue.is_deleted = FALSE
                JOIN subcontract_material_plan_items plan_item
                  ON plan_item.id = issue_item.plan_item_id
                 AND plan_item.flow_mode IN ('DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND','COMPONENT_OUTBOUND')
                 AND plan_item.is_deleted = FALSE
                WHERE issue_item.issue_id = :issueId
                ORDER BY plan_item.id, issue_item.id
                FOR UPDATE OF plan_item
                """).setParameter("issueId", issueId).getResultList();
        if (lines.isEmpty()) return;
        inventoryLock.lockAll(lines.stream().map(row ->
                new InventoryKey((UUID) row[3], (UUID) row[4])).toList());
        releaseDraftReservations(issueId);
        UUID actorId = currentUser.requireId();
        for (Object[] row : lines) {
            UUID issueItemId = (UUID) row[0];
            UUID planItemId = (UUID) row[1];
            BigDecimal qty = decimal(row[2]);
            UUID goodsId = (UUID) row[3];
            UUID colorId = (UUID) row[4];
            String flowMode = Objects.toString(row[5]);
            if (Set.of("DIRECT_OUTBOUND", "MAKE_THEN_OUTBOUND").contains(flowMode)) {
                BomSnapshot currentBom = currentBomSnapshot(goodsId);
                if (!Objects.equals(row[8], currentBom.hasChildren())
                        || !Objects.equals(row[9], currentBom.fingerprint())) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "委外目标件 BOM 已在审批后变化，必须受控重评准备路线，禁止按旧结构出仓");
                }
            } else if ("COMPONENT_OUTBOUND".equals(flowMode)) {
                // V581：指纹记的是**目标件**的 BOM（本行 goods_id 已经是子件），
                // 且指纹覆盖不到「子件后来自己长出 BOM」——必须再判一次唯一叶子子件。
                UUID parentGoodsId = (UUID) row[10];
                BomSnapshot currentBom = currentBomSnapshot(parentGoodsId);
                SoleComponent sole = soleOutboundComponent(parentGoodsId);
                if (!Objects.equals(row[8], currentBom.hasChildren())
                        || !Objects.equals(row[9], currentBom.fingerprint())
                        || sole == null || !goodsId.equals(sole.goodsId())) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "委外目标件 BOM 已在审批后变化（不再是「只有一个叶子子件」，或子件已换），"
                                    + "必须受控重评准备路线，禁止按旧结构发料");
                }
            }
            if (qty.signum() <= 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "委外目标件出仓数量必须大于零");
            }
            if ("MAKE_THEN_OUTBOUND".equals(flowMode)
                    || "PREPARED_OUTBOUND".equals(flowMode)) {
                if (!"READY_OUTBOUND".equals(row[6])) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "前置自制尚未合格实收入库，禁止保存委外出仓草稿");
                }
                Number reserved = (Number) em.createNativeQuery("""
                        SELECT COALESCE(SUM(qty-consumed_qty-released_qty),0)-COALESCE((
                            SELECT SUM(other_item.qty) FROM subcontract_material_issue_items other_item
                            JOIN subcontract_material_issues other_issue ON other_issue.id=other_item.issue_id
                            WHERE other_item.plan_item_id=:planItemId AND NOT other_item.is_deleted
                              AND other_issue.status=0 AND NOT other_issue.is_deleted
                              AND other_issue.id<>:issueId AND other_issue.warehouse_id=:warehouseId),0)
                        FROM stock_reservations reservation
                        WHERE owner_type = 'SUBCONTRACT_OUTBOUND'
                          AND owner_id = :planItemId AND warehouse_id = :warehouseId
                          AND goods_id = :goodsId
                          AND color_id IS NOT DISTINCT FROM CAST(:colorId AS uuid)
                          AND status = 0 AND is_deleted = FALSE
                          AND fn_subcontract_preparation_reservation_has_qualified_origin(reservation.id)
                """).setParameter("planItemId", planItemId)
                        .setParameter("issueId", issueId)
                        .setParameter("warehouseId", warehouseId)
                        .setParameter("goodsId", goodsId)
                        .setParameter("colorId", colorId).getSingleResult();
                if (decimal(reserved).compareTo(qty) < 0) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "委外前置自制专属库存不足，请刷新任务");
                }
                continue;
            }
            // DIRECT reservations are replaceable only while unconsumed. This
            // also handles approve -> reverse -> regenerate: the restored old
            // reservation is released under the same inventory lock before a
            // new draft reservation is created, so it is never double-counted.
            em.createNativeQuery("""
                    UPDATE stock_reservations
                    SET released_qty = qty, status = 1,
                        release_reason = 'SUBCONTRACT_OUTBOUND_DRAFT_REPLACED',
                        lock_version = lock_version + 1,
                        updated_at = now(), updated_by = :actorId
                    WHERE owner_type = 'SUBCONTRACT_OUTBOUND'
                      AND owner_id = :planItemId
                      AND supply_type = 'STOCK_BALANCE'
                      AND status = 0 AND consumed_qty = 0
                      AND is_deleted = FALSE
                    """).setParameter("actorId", actorId)
                    .setParameter("planItemId", planItemId).executeUpdate();
            List<Object[]> balances = NativeQueryResults.objectArrayRows(
                    em.createNativeQuery("""
                            SELECT balance.id, available.available_qty
                            FROM stock_balances balance
                            JOIN v_stock_available available
                              ON available.warehouse_id = balance.warehouse_id
                             AND available.goods_id = balance.goods_id
                             AND available.color_id IS NOT DISTINCT FROM balance.color_id
                            WHERE balance.warehouse_id = :warehouseId
                              AND balance.goods_id = :goodsId
                              AND balance.color_id IS NOT DISTINCT FROM CAST(:colorId AS uuid)
                            """).setParameter("warehouseId", warehouseId)
                    .setParameter("goodsId", goodsId).setParameter("colorId", colorId));
            if (balances.isEmpty() || decimal(balances.getFirst()[1]).compareTo(qty) < 0) {
                // V581：COMPONENT 发的是子件，缺的也是子件——这正是「等子件采购
                // 入库后仓库才发得出去」那道天然门禁，文案要说清缺的是哪件东西。
                throw new ApiException(ErrorCode.CONFLICT,
                        "COMPONENT_OUTBOUND".equals(flowMode)
                                ? "待发子件在该仓的合格可动用库存不足，请等子件采购/生产入库后再发料"
                                : "目标仓合格可动用库存不足，不能占用本次委外目标件");
            }
            int warehouseUpdated = em.createNativeQuery("""
                    UPDATE subcontract_material_plan_items
                    SET preparation_warehouse_id = :warehouseId,
                        preparation_version = preparation_version + 1,
                        updated_at = now(), updated_by = :actorId
                    WHERE id = :id
                      AND flow_mode IN ('DIRECT_OUTBOUND','COMPONENT_OUTBOUND')
                      AND preparation_status = 'READY_OUTBOUND'
                    """).setParameter("warehouseId", warehouseId)
                    .setParameter("actorId", actorId).setParameter("id", planItemId)
                    .executeUpdate();
            if (warehouseUpdated != 1) throw new ApiException(ErrorCode.CONFLICT,
                    "委外目标件出仓任务已变化，请刷新后重试");
            em.createNativeQuery("""
                    INSERT INTO stock_reservations(
                        id, order_item_id, goods_id, color_id, warehouse_id,
                        qty, consumed_qty, released_qty, status, source,
                        source_doc_type, source_doc_id,
                        owner_type, owner_id, purpose, demand_id,
                        supply_type, supply_id, idempotency_key,
                        created_by, updated_by)
                    VALUES (:id, NULL, :goodsId, :colorId, :warehouseId,
                        :qty, 0, 0, 0, 0,
                        'SUBCONTRACT_OUTBOUND_DRAFT', :issueId,
                        'SUBCONTRACT_OUTBOUND', :planItemId,
                        'SUBCONTRACT_OUTBOUND', NULL,
                        'STOCK_BALANCE', :balanceId, :key,
                        :actorId, :actorId)
                    """).setParameter("id", UUID.randomUUID())
                    .setParameter("goodsId", goodsId).setParameter("colorId", colorId)
                    .setParameter("warehouseId", warehouseId).setParameter("qty", qty)
                    .setParameter("issueId", issueId).setParameter("planItemId", planItemId)
                    .setParameter("balanceId", balances.getFirst()[0])
                    .setParameter("key", "SC-OUT-DRAFT:" + issueItemId)
                    .setParameter("actorId", actorId).executeUpdate();
        }
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void releaseDraftReservations(UUID issueId) {
        em.createNativeQuery("""
                UPDATE stock_reservations
                SET released_qty = qty, status = 1,
                    release_reason = 'SUBCONTRACT_OUTBOUND_DRAFT_REPLACED',
                    lock_version = lock_version + 1, updated_at = now()
                WHERE owner_type = 'SUBCONTRACT_OUTBOUND'
                  AND supply_type = 'STOCK_BALANCE'
                  AND source_doc_type = 'SUBCONTRACT_OUTBOUND_DRAFT'
                  AND source_doc_id = :issueId
                  AND status = 0 AND consumed_qty = 0 AND is_deleted = FALSE
                """).setParameter("issueId", issueId).executeUpdate();
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void consumeOutboundReservations(UUID issueId, UUID warehouseId) {
        @SuppressWarnings("unchecked")
        List<Object[]> lines = em.createNativeQuery("""
                SELECT issue_item.id, issue_item.plan_item_id, issue_item.qty
                FROM subcontract_material_issue_items issue_item
                JOIN subcontract_material_plan_items plan_item
                  ON plan_item.id = issue_item.plan_item_id
                 AND plan_item.flow_mode IN ('DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND','COMPONENT_OUTBOUND')
                WHERE issue_item.issue_id = :issueId
                ORDER BY plan_item.id, issue_item.id
                """).setParameter("issueId", issueId).getResultList();
        UUID actorId = currentUser.requireId();
        for (Object[] line : lines) {
            UUID issueItemId = (UUID) line[0];
            UUID planItemId = (UUID) line[1];
            BigDecimal remaining = decimal(line[2]);
            @SuppressWarnings("unchecked")
            List<Object[]> reservations = em.createNativeQuery("""
                    SELECT id, qty-consumed_qty-released_qty
                    FROM stock_reservations
                    WHERE owner_type = 'SUBCONTRACT_OUTBOUND'
                      AND owner_id = :planItemId AND warehouse_id = :warehouseId
                      AND status = 0 AND is_deleted = FALSE
                    ORDER BY CASE WHEN supply_type = 'PRODUCTION_FINISHED_IN' THEN 0 ELSE 1 END,
                             created_at, id
                    FOR UPDATE
                    """).setParameter("planItemId", planItemId)
                    .setParameter("warehouseId", warehouseId).getResultList();
            for (Object[] reservation : reservations) {
                if (remaining.signum() <= 0) break;
                BigDecimal take = remaining.min(decimal(reservation[1]));
                if (take.signum() <= 0) continue;
                UUID reservationId = (UUID) reservation[0];
                int updated = em.createNativeQuery("""
                        UPDATE stock_reservations
                        SET consumed_qty = consumed_qty + :qty,
                            status = CASE WHEN consumed_qty + released_qty + :qty = qty
                                          THEN 1 ELSE 0 END,
                            lock_version = lock_version + 1,
                            updated_at = now(), updated_by = :actorId
                        WHERE id = :id AND status = 0
                          AND consumed_qty + released_qty + :qty <= qty
                        """).setParameter("qty", take).setParameter("actorId", actorId)
                        .setParameter("id", reservationId).executeUpdate();
                if (updated != 1) throw new ApiException(ErrorCode.CONFLICT,
                        "委外目标件专属预留已被并发修改");
                em.createNativeQuery("""
                        INSERT INTO subcontract_outbound_issue_reservation_allocations(
                            id, issue_id, issue_item_id, plan_item_id,
                            reservation_id, allocated_qty, status,
                            idempotency_key, created_by)
                        VALUES (:id, :issueId, :issueItemId, :planItemId,
                            :reservationId, :qty, 'EFFECTIVE', :key, :actorId)
                        """).setParameter("id", UUID.randomUUID())
                        .setParameter("issueId", issueId).setParameter("issueItemId", issueItemId)
                        .setParameter("planItemId", planItemId)
                        .setParameter("reservationId", reservationId).setParameter("qty", take)
                        .setParameter("key", "SC-OUT-ISSUE:" + issueItemId + ':' + reservationId)
                        .setParameter("actorId", actorId).executeUpdate();
                remaining = remaining.subtract(take);
            }
            if (remaining.signum() > 0) throw new ApiException(ErrorCode.CONFLICT,
                    "本次委外出仓没有足额订单专属库存预留");
        }
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void reverseOutboundReservations(UUID issueId) {
        @SuppressWarnings("unchecked")
        List<Object[]> allocations = em.createNativeQuery("""
                SELECT allocation.id, allocation.reservation_id, allocation.allocated_qty
                FROM subcontract_outbound_issue_reservation_allocations allocation
                WHERE allocation.issue_id = :issueId AND allocation.status = 'EFFECTIVE'
                ORDER BY allocation.reservation_id, allocation.id FOR UPDATE
                """).setParameter("issueId", issueId).getResultList();
        UUID actorId = currentUser.requireId();
        for (Object[] allocation : allocations) {
            BigDecimal qty = decimal(allocation[2]);
            int restored = em.createNativeQuery("""
                    UPDATE stock_reservations
                    SET consumed_qty = consumed_qty - :qty, status = 0,
                        lock_version = lock_version + 1,
                        updated_at = now(), updated_by = :actorId
                    WHERE id = :id AND consumed_qty >= :qty
                    """).setParameter("qty", qty).setParameter("actorId", actorId)
                    .setParameter("id", allocation[1]).executeUpdate();
            if (restored != 1) throw new ApiException(ErrorCode.CONFLICT,
                    "委外出仓专属预留消费记录不一致，禁止红冲");
            em.createNativeQuery("""
                    UPDATE subcontract_outbound_issue_reservation_allocations
                    SET status = 'REVERSED', reversed_at = now(), reversed_by = :actorId
                    WHERE id = :id AND status = 'EFFECTIVE'
                    """).setParameter("actorId", actorId).setParameter("id", allocation[0])
                    .executeUpdate();
        }
    }

    // ==================== 仓库出仓工作台 ====================

    /** A V529 draft owns its real finished output before any finance-approved outbound plan exists. */
    private void holdDirectOrderPreparationOutput(UUID documentId, UUID warehouseId) {
        UUID actor=currentUser.requireId();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT item.id,child.subcontract_order_item_id,item.goods_id,item.color_id,item.base_qty,document.warehouse_id
                FROM stock_document_items item JOIN stock_documents document ON document.id=item.doc_id
                JOIN production_plan_items production_item ON production_item.id=item.upstream_item_id
                JOIN production_plans plan ON plan.id=production_item.plan_id
                JOIN production_material_analysis_items child ON child.id=plan.material_analysis_item_id
                  AND child.analysis_id=plan.material_analysis_id
                WHERE document.id=:document AND document.doc_type='FINISHED_IN' AND document.status=1 AND NOT document.is_deleted
                  AND item.bill_type='FINISHED_IN' AND NOT item.is_deleted AND item.base_qty>0
                  AND child.source_type='SUBCONTRACT_PREPARATION' AND child.subcontract_order_item_id IS NOT NULL
                  AND NOT EXISTS(SELECT 1 FROM subcontract_material_plan_items target
                    WHERE target.preparation_analysis_item_id=child.id AND target.flow_mode='MAKE_THEN_OUTBOUND' AND NOT target.is_deleted)
                ORDER BY item.id
                """).setParameter("document",documentId))) {
            if(!Objects.equals(warehouseId,row[5]))throw new ApiException(ErrorCode.CONFLICT,"委外原订货备料必须保留真实实收仓");
            em.createNativeQuery("""
                    INSERT INTO stock_reservations(id,goods_id,color_id,warehouse_id,qty,source,source_doc_type,source_doc_id,
                        owner_type,owner_id,purpose,supply_type,supply_id,idempotency_key,created_by,updated_by)
                    VALUES(gen_random_uuid(),:goods,:color,:warehouse,:qty,1,'PRODUCTION_INBOUND',:document,
                        'SUBCONTRACT_ORDER_PREPARATION',:owner,'SUBCONTRACT_ORDER_PREPARATION',
                        'PRODUCTION_FINISHED_IN',:item,:key,:actor,:actor)
                    ON CONFLICT(idempotency_key) WHERE idempotency_key IS NOT NULL DO NOTHING
                    """).setParameter("goods",row[2]).setParameter("color",row[3]).setParameter("warehouse",warehouseId)
                    .setParameter("qty",row[4]).setParameter("document",documentId).setParameter("owner",row[1])
                    .setParameter("item",row[0]).setParameter("key","SC-ORDER-PREP-IN:"+row[0]).setParameter("actor",actor).executeUpdate();
        }
    }

    private void releaseDirectOrderPreparationOutput(UUID documentId) {
        Number used=(Number)em.createNativeQuery("""
                SELECT count(*) FROM stock_reservations reservation
                WHERE reservation.source_doc_type='PRODUCTION_INBOUND' AND reservation.source_doc_id=:document
                  AND reservation.supply_type='PRODUCTION_FINISHED_IN' AND reservation.owner_type='SUBCONTRACT_OUTBOUND'
                  AND NOT reservation.is_deleted AND reservation.qty>reservation.released_qty
                  AND EXISTS(SELECT 1 FROM subcontract_material_plan_items item
                    JOIN production_material_analysis_items child ON child.id=item.preparation_analysis_item_id
                    WHERE item.id=reservation.owner_id AND child.subcontract_order_item_id IS NOT NULL)
                """).setParameter("document",documentId).getSingleResult();
        if(used.longValue()>0)throw new ApiException(ErrorCode.CONFLICT,"委外原订货备料已交接出仓计划，请先反向出仓及订货后再撤回原实收");
        em.createNativeQuery("""
                UPDATE stock_reservations SET released_qty=qty,status=1,release_reason='PRODUCTION_FINISHED_IN_REVERSED',
                    lock_version=lock_version+1,updated_at=now(),updated_by=:actor
                WHERE source_doc_type='PRODUCTION_INBOUND' AND source_doc_id=:document
                  AND owner_type='SUBCONTRACT_ORDER_PREPARATION' AND NOT is_deleted AND consumed_qty=0 AND released_qty<qty
                """).setParameter("document",documentId).setParameter("actor",currentUser.requireId()).executeUpdate();
    }

    /** 待出仓任务：OPEN 计划且有待仓库执行的出仓量（计划 − 已出仓 > 0；草稿占用不影响任务可见性）。
     * 表头筛选（2026-09-16）：supplierId=委外商等值；status=派生任务状态
     * DRAFT_PICKING（已有出仓草稿待拣货）/ READY_OUTBOUND（此刻有货可发, 无草稿）/
     * WAITING_COMPONENT（ADR-103: 全部待出行都在等子件到货, 仓里一件都没有, 无草稿），白名单 fail-closed。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('subcontract_outbound:view')")
    public PageResponse<OutboundTaskListItem> tasks(int page, int size, String keyword) {
        return tasks(page, size, keyword, null, null);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('subcontract_outbound:view')")
    public PageResponse<OutboundTaskListItem> tasks(
            int page, int size, String keyword, UUID supplierId, String status) {
        String kw = keyword == null || keyword.isBlank() ? null : "%" + keyword.trim() + "%";
        String kwClause = kw == null ? "" : """
                AND (p.order_bill_no ILIKE ? OR s.name ILIKE ?)
                """;
        String supplierClause = supplierId == null ? "" : "AND p.supplier_id = ?\n";
        // 派生任务状态与前端 statusLabel 同口径：列表 WHERE 已保证 ready_line_count > 0，
        // 任务分三档 (ADR-103): 「草稿待拣货」(挂有草稿出仓单) / 「已备齐待出仓」(无草稿且此刻
        // 有可发量) / 「等子件到货」(无草稿且可发合计为 0——没草稿时 WHERE 已保证待出量 > 0,
        // 可发为 0 只能是发现货的两种流向仓里一件都没有)。三档互斥, 前端按桶筛不会重叠。
        String normalizedStatus = status == null ? "" : status.strip().toUpperCase();
        String statusClause = switch (normalizedStatus) {
            case "" -> "";
            case "DRAFT_PICKING" -> "AND draft.issue_id IS NOT NULL\n";
            case "READY_OUTBOUND" -> "AND draft.issue_id IS NULL AND agg.issuable_total > 0\n";
            case "WAITING_COMPONENT" -> """
                    AND draft.issue_id IS NULL AND agg.issuable_total <= 0
                    AND agg.waiting_component_line_count > 0
                    """;
            default -> throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "出仓任务状态仅支持 DRAFT_PICKING、READY_OUTBOUND 或 WAITING_COMPONENT");
        };
        String base = """
                FROM subcontract_material_plans p
                JOIN subcontract_orders o ON o.id = p.order_id
                LEFT JOIN suppliers s ON s.id = p.supplier_id
                JOIN (
                    SELECT pi.plan_id,
                           COUNT(*) AS line_count,
                           SUM(pi.planned_qty) AS planned_total,
                           SUM(pi.issued_qty) AS issued_total,
                           SUM(GREATEST(pi.planned_qty - pi.issued_qty, 0))
                               AS remaining_total,
                           SUM(CASE
                                 WHEN pi.preparation_status IN
                                      ('LEGACY_READY','READY_OUTBOUND')
                                 THEN GREATEST(
                                      LEAST(pi.planned_qty, pi.prepared_qty)
                                      - pi.issued_qty
                                      - COALESCE(draft_qty.qty, 0), 0)
                                 ELSE 0
                               END) AS ready_outbound_total,
                           -- ADR-103: 此刻真能开出去的量。发现货的两种流向按「余量 与 作业叶仓
                           -- 合格可动用量 取小」(与任务详情 issuableQty 同口径), 其它流向吃专属
                           -- 预留, 按余量; 列表卡片直接拿它显示「可发 X」, 不让前端再算。
                           SUM(CASE
                                 WHEN pi.preparation_status NOT IN
                                      ('LEGACY_READY','READY_OUTBOUND')
                                 THEN 0
                                 WHEN pi.flow_mode IN ('DIRECT_OUTBOUND','COMPONENT_OUTBOUND')
                                 THEN LEAST(
                                      GREATEST(
                                          LEAST(pi.planned_qty, pi.prepared_qty)
                                          - pi.issued_qty
                                          - COALESCE(draft_qty.qty, 0), 0),
                                      COALESCE(stock.available_qty, 0))
                                 ELSE GREATEST(
                                      LEAST(pi.planned_qty, pi.prepared_qty)
                                      - pi.issued_qty
                                      - COALESCE(draft_qty.qty, 0), 0)
                               END) AS issuable_total,
                           -- ADR-103: 发现货的两种流向里「有余量、没挂未审草稿、仓里一件都没有」
                           -- 的行数——这些行在等子件 (或目标件) 到货, 不是轮到仓库动手。
                           COUNT(*) FILTER (
                               WHERE pi.preparation_status IN
                                     ('LEGACY_READY','READY_OUTBOUND')
                                 AND pi.flow_mode IN ('DIRECT_OUTBOUND','COMPONENT_OUTBOUND')
                                 AND LEAST(pi.planned_qty, pi.prepared_qty)
                                     - pi.issued_qty > 0
                                 AND draft_qty.plan_item_id IS NULL
                                 AND COALESCE(stock.available_qty, 0) <= 0
                           ) AS waiting_component_line_count,
                           COUNT(*) FILTER (
                               WHERE pi.preparation_status IN
                                     ('LEGACY_READY','READY_OUTBOUND')
                                 AND pi.planned_qty - pi.issued_qty > 0
                           ) AS ready_line_count,
                           COUNT(*) FILTER (
                               WHERE pi.flow_mode = 'MAKE_THEN_OUTBOUND'
                                 AND pi.preparation_status IN (
                                     'ACTION_REQUIRED','IN_PREPARATION',
                                     'WAITING_FQC','WAITING_INBOUND')
                           ) AS waiting_preparation_count,
                           COUNT(*) FILTER (
                               WHERE pi.preparation_status = 'CANCELLED'
                                  OR pi.flow_mode NOT IN (
                                      'LEGACY_BOM_COMPONENT','DIRECT_OUTBOUND',
                                      'MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND',
                                      'COMPONENT_OUTBOUND')
                                  OR pi.preparation_status NOT IN (
                                      'LEGACY_READY','ACTION_REQUIRED',
                                      'IN_PREPARATION','WAITING_FQC',
                                      'WAITING_INBOUND','READY_OUTBOUND',
                                      'OUTBOUND_COMPLETE','CANCELLED')
                           ) AS blocked_line_count
                    FROM subcontract_material_plan_items pi
                    LEFT JOIN (
                        SELECT ii.plan_item_id, SUM(ii.qty) AS qty
                        FROM subcontract_material_issue_items ii
                        JOIN subcontract_material_issues issue
                          ON issue.id = ii.issue_id
                         AND issue.status = 0
                         AND issue.is_deleted = FALSE
                        GROUP BY ii.plan_item_id
                    ) draft_qty ON draft_qty.plan_item_id = pi.id
                    LEFT JOIN LATERAL (
                        SELECT COALESCE(SUM(GREATEST(sa.available_qty, 0)), 0) AS available_qty
                """ + QUALIFIED_AVAILABLE_STOCK_SOURCE + """
                          AND pi.flow_mode IN ('DIRECT_OUTBOUND','COMPONENT_OUTBOUND')
                          AND sa.goods_id = pi.goods_id
                          AND sa.color_id IS NOT DISTINCT FROM pi.color_id
                    ) stock ON TRUE
                    WHERE pi.is_deleted = FALSE
                    GROUP BY pi.plan_id
                ) agg ON agg.plan_id = p.id
                LEFT JOIN LATERAL (
                    SELECT i.id AS issue_id, i.bill_no
                    FROM subcontract_material_issues i
                    WHERE i.status = 0 AND i.is_deleted = FALSE AND EXISTS (
                        SELECT 1 FROM subcontract_material_issue_items ii
                        JOIN subcontract_material_plan_items pi2 ON pi2.id = ii.plan_item_id
                        WHERE ii.issue_id = i.id AND pi2.plan_id = p.id)
                    ORDER BY i.created_at DESC
                    LIMIT 1
                ) draft ON TRUE
                WHERE p.is_deleted = FALSE AND p.status = 'OPEN'
                  AND agg.ready_line_count > 0
                  AND (agg.ready_outbound_total > 0 OR draft.issue_id IS NOT NULL)
                """ + supplierClause + statusClause + kwClause;
        List<Object> params = new java.util.ArrayList<>();
        if (supplierId != null) params.add(supplierId);
        if (kw != null) params.addAll(java.util.List.of(kw, kw));
        Long total = jdbc.queryForObject("SELECT COUNT(*) " + base, Long.class, params.toArray());
        List<OutboundTaskListItem> content = jdbc.query("""
                SELECT p.id, p.order_id, p.order_bill_no, s.name, o.deliver_date,
                       agg.line_count, agg.planned_total, agg.issued_total,
                       agg.remaining_total, draft.issue_id, draft.bill_no,
                       agg.ready_outbound_total, agg.ready_line_count,
                       agg.waiting_preparation_count, agg.blocked_line_count,
                       agg.waiting_component_line_count, agg.issuable_total
                """ + base + """
                ORDER BY o.deliver_date ASC NULLS LAST, p.created_at ASC
                LIMIT ? OFFSET ?
                """,
                (rs, rowNum) -> new OutboundTaskListItem(
                        rs.getObject(1, UUID.class),
                        rs.getObject(2, UUID.class),
                        rs.getString(3),
                        rs.getString(4),
                        rs.getObject(5, LocalDate.class),
                        rs.getInt(6),
                        rs.getBigDecimal(7),
                        rs.getBigDecimal(8),
                        rs.getBigDecimal(9),
                        rs.getObject(10, UUID.class),
                        rs.getString(11),
                        rs.getBigDecimal(12),
                        rs.getInt(13),
                        rs.getInt(14),
                        rs.getInt(15),
                        rs.getLong(16),
                        rs.getBigDecimal(17)),
                append(params.toArray(), size, (long) (Math.max(page, 1) - 1) * size));
        long totalElements = total == null ? 0 : total;
        int totalPages = size <= 0 ? 0 : (int) Math.ceil((double) totalElements / size);
        return new PageResponse<>(content, page, size, totalElements, totalPages);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('subcontract_outbound:view')")
    public long countTasks() {
        Long count = jdbc.queryForObject("""
                SELECT COUNT(*) FROM subcontract_material_plans p
                WHERE p.is_deleted = FALSE AND p.status = 'OPEN' AND EXISTS (
                    SELECT 1 FROM subcontract_material_plan_items pi
                    WHERE pi.plan_id = p.id AND pi.is_deleted = FALSE
                      AND pi.preparation_status IN ('LEGACY_READY','READY_OUTBOUND')
                      AND LEAST(pi.planned_qty, pi.prepared_qty) - pi.issued_qty > 0
                      -- ADR-101: 角标是「轮到仓库动手」的红数，发现货的两种流向仓里一件都
                      -- 没有时不算轮到仓库——那是在等采购/生产到货, 属于中性的「等子件到货」。
                      -- 有未审草稿(说明当时有货已经占住了)或此刻仓里还有可动用量, 才算有活。
                      AND (pi.flow_mode NOT IN ('DIRECT_OUTBOUND','COMPONENT_OUTBOUND')
                           OR EXISTS (
                               SELECT 1 FROM subcontract_material_issue_items ii
                               JOIN subcontract_material_issues i ON i.id = ii.issue_id
                               WHERE ii.plan_item_id = pi.id
                                 AND i.status = 0 AND i.is_deleted = FALSE)
                           OR EXISTS (
                               SELECT 1
                """ + QUALIFIED_AVAILABLE_STOCK_SOURCE + """
                                 AND sa.goods_id = pi.goods_id
                                 AND sa.color_id IS NOT DISTINCT FROM pi.color_id)))
                """, Long.class);
        return count == null ? 0 : count;
    }

    /**
     * ADR-103 黄数「等子件到货」: 计划仍有待出量, 但没有一行是「轮到仓库动手」的——发现货的两种
     * 流向仓里一件都没有、也没挂未审草稿。它与 {@link #countTasks} 的红数按同一批行互斥:
     * 一张 OPEN 计划要么红(有货或有草稿, 仓库现在就能发)要么黄(在等采购/生产把子件送进仓),
     * 两数之和 = 出仓任务列表里 OPEN 且有待出量的计划数。用户 2026-09-22 实机口径: 委外出库分段
     * 上「没有对应的通知数量徽章」——按准则 14 三形态, 等料的单子要以黄色在办数出现, 不能消失。
     */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('subcontract_outbound:view')")
    public long countWaitingComponentTasks() {
        Long count = jdbc.queryForObject("""
                SELECT COUNT(*) FROM subcontract_material_plans p
                WHERE p.is_deleted = FALSE AND p.status = 'OPEN'
                  AND EXISTS (
                    SELECT 1 FROM subcontract_material_plan_items pi
                    WHERE pi.plan_id = p.id AND pi.is_deleted = FALSE
                      AND pi.preparation_status IN ('LEGACY_READY','READY_OUTBOUND')
                      AND LEAST(pi.planned_qty, pi.prepared_qty) - pi.issued_qty > 0)
                  AND NOT EXISTS (
                    SELECT 1 FROM subcontract_material_plan_items pi
                    WHERE pi.plan_id = p.id AND pi.is_deleted = FALSE
                      AND pi.preparation_status IN ('LEGACY_READY','READY_OUTBOUND')
                      AND LEAST(pi.planned_qty, pi.prepared_qty) - pi.issued_qty > 0
                      AND (pi.flow_mode NOT IN ('DIRECT_OUTBOUND','COMPONENT_OUTBOUND')
                           OR EXISTS (
                               SELECT 1 FROM subcontract_material_issue_items ii
                               JOIN subcontract_material_issues i ON i.id = ii.issue_id
                               WHERE ii.plan_item_id = pi.id
                                 AND i.status = 0 AND i.is_deleted = FALSE)
                           OR EXISTS (
                               SELECT 1
                """ + QUALIFIED_AVAILABLE_STOCK_SOURCE + """
                                 AND sa.goods_id = pi.goods_id
                                 AND sa.color_id IS NOT DISTINCT FROM pi.color_id)))
                """, Long.class);
        return count == null ? 0 : count;
    }

    /** 计划详情：计划行（含库位/草稿占用/剩余）+ 该计划全部出仓单。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('subcontract_outbound:view')")
    public OutboundTaskDetail taskDetail(UUID planId) {
        boolean canHandleOutbound = hasCurrentAuthority("subcontract_outbound:execute");
        List<OutboundPlanLine> lines = jdbc.query("""
                SELECT pi.id, pi.order_item_id,
                       pi.parent_goods_id, pi.parent_color_id, pg.code, pg.name,
                       pi.goods_id, g.code, g.name, g.stock_place,
                       pi.color_id, c.name, pi.unit_id, u.name, pi.unit_rate, pi.bom_unit_qty,
                       pi.planned_qty, pi.issued_qty,
                       COALESCE(draft_qty.qty, 0)
                       , pi.flow_mode, pi.preparation_status, pi.prepared_qty,
                       GREATEST(LEAST(pi.planned_qty, pi.prepared_qty)
                           - pi.issued_qty - COALESCE(draft_qty.qty, 0), 0),
                       GREATEST(pi.planned_qty - pi.issued_qty, 0),
                       pi.preparation_analysis_id, pi.preparation_analysis_item_id,
                       -- 发现货的两种流向必须给出确定的数：一个仓都没货时是 0 而不是 NULL，
                       -- 否则客户端按「服务端没算」回落成计划余量，又变回那个「界面说有 1000、
                       -- 其实一件都发不出去」的老毛病。其余流向吃的是专属预留，一律 NULL。
                       CASE WHEN pi.flow_mode IN ('DIRECT_OUTBOUND','COMPONENT_OUTBOUND')
                            THEN LEAST(
                                GREATEST(LEAST(pi.planned_qty, pi.prepared_qty)
                                    - pi.issued_qty - COALESCE(draft_qty.qty, 0), 0),
                                COALESCE(stock.available_qty, 0))
                       END,
                       CASE WHEN pi.flow_mode IN ('DIRECT_OUTBOUND','COMPONENT_OUTBOUND')
                            THEN COALESCE(stock.available_qty, 0) END,
                       stock.warehouse_id, stock.warehouse_name
                FROM subcontract_material_plan_items pi
                JOIN goods pg ON pg.id = pi.parent_goods_id
                JOIN goods g ON g.id = pi.goods_id
                LEFT JOIN colors c ON c.id = pi.color_id
                LEFT JOIN units u ON u.id = pi.unit_id
                LEFT JOIN LATERAL (
                    SELECT SUM(ii.qty) AS qty
                    FROM subcontract_material_issue_items ii
                    JOIN subcontract_material_issues i ON i.id = ii.issue_id
                    WHERE ii.plan_item_id = pi.id
                      AND i.status = 0 AND i.is_deleted = FALSE
                ) draft_qty ON TRUE
                LEFT JOIN LATERAL (
                    SELECT w.id AS warehouse_id, w.name AS warehouse_name,
                           GREATEST(COALESCE(sa.available_qty, 0), 0) AS available_qty
                    FROM warehouses w
                    LEFT JOIN v_stock_available sa
                      ON sa.warehouse_id = w.id AND sa.goods_id = pi.goods_id
                     AND sa.color_id IS NOT DISTINCT FROM pi.color_id
                    WHERE pi.flow_mode IN ('DIRECT_OUTBOUND','COMPONENT_OUTBOUND')
                      AND NOT w.is_deleted
                      AND (w.id = pi.preparation_warehouse_id
                           OR (pi.preparation_warehouse_id IS NULL
                               AND NOT w.is_defective AND NOT w.is_line_side
                               AND fn_warehouse_is_operational_leaf(w.id)
                               AND COALESCE(sa.available_qty, 0) > 0))
                    ORDER BY CASE WHEN w.id = pi.preparation_warehouse_id THEN 0 ELSE 1 END,
                             GREATEST(COALESCE(sa.available_qty, 0), 0) DESC, w.code
                    LIMIT 1
                ) stock ON TRUE
                WHERE pi.plan_id = ? AND pi.is_deleted = FALSE
                  AND pi.preparation_status IN ('LEGACY_READY','READY_OUTBOUND')
                  AND pi.planned_qty - pi.issued_qty > 0
                ORDER BY pi.line_no ASC NULLS LAST, pi.id
                """,
                (rs, rowNum) -> new OutboundPlanLine(
                        rs.getObject(1, UUID.class),
                        rs.getObject(2, UUID.class),
                        rs.getObject(3, UUID.class),
                        rs.getObject(4, UUID.class),
                        rs.getString(5), rs.getString(6),
                        rs.getObject(7, UUID.class),
                        rs.getString(8), rs.getString(9), rs.getString(10),
                        rs.getObject(11, UUID.class), rs.getString(12),
                        rs.getObject(13, UUID.class), rs.getString(14),
                        rs.getBigDecimal(15), rs.getBigDecimal(16),
                        rs.getBigDecimal(17), rs.getBigDecimal(18),
                        rs.getBigDecimal(19), rs.getString(20), rs.getString(21),
                        rs.getBigDecimal(22), rs.getBigDecimal(23),
                        rs.getBigDecimal(24), rs.getObject(25, UUID.class),
                        rs.getObject(26, UUID.class), null,
                        outboundActions(canHandleOutbound, rs.getBigDecimal(23),
                                rs.getBigDecimal(19)),
                        rs.getBigDecimal(27), rs.getBigDecimal(28),
                        rs.getObject(29, UUID.class), rs.getString(30)),
                planId);
        if (lines.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "委外发料计划不存在");
        }
        List<Object[]> head = jdbc.query("""
                SELECT p.order_id, p.order_bill_no, p.status, s.name, o.deliver_date, p.close_reason,
                       p.supplier_id
                FROM subcontract_material_plans p
                LEFT JOIN suppliers s ON s.id = p.supplier_id
                JOIN subcontract_orders o ON o.id = p.order_id
                WHERE p.id = ? AND p.is_deleted = FALSE
                """,
                (rs, rowNum) -> new Object[]{
                        rs.getObject(1, UUID.class), rs.getString(2), rs.getString(3),
                        rs.getString(4), rs.getObject(5, LocalDate.class), rs.getString(6),
                        rs.getObject(7, UUID.class)},
                planId);
        if (head.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "委外发料计划不存在");
        }
        List<OutboundDraftRef> drafts = jdbc.query("""
                SELECT i.id, i.bill_no, i.status, i.bill_date, w.name, i.approver_name,
                       (SELECT SUM(ii.qty) FROM subcontract_material_issue_items ii WHERE ii.issue_id = i.id)
                FROM subcontract_material_issues i
                LEFT JOIN warehouses w ON w.id = i.warehouse_id
                WHERE i.is_deleted = FALSE AND EXISTS (
                    SELECT 1 FROM subcontract_material_issue_items ii
                    JOIN subcontract_material_plan_items pi ON pi.id = ii.plan_item_id
                    WHERE ii.issue_id = i.id AND pi.plan_id = ?)
                ORDER BY i.created_at
                """,
                (rs, rowNum) -> new OutboundDraftRef(
                        rs.getObject(1, UUID.class),
                        rs.getString(2),
                        rs.getShort(3),
                        rs.getObject(4, LocalDate.class),
                        rs.getString(5),
                        rs.getString(6),
                        rs.getBigDecimal(7)),
                planId);
        Object[] h = head.getFirst();
        return new OutboundTaskDetail(
                planId,
                (UUID) h[0],
                (String) h[1],
                (String) h[2],
                (UUID) h[6],
                (String) h[3],
                (LocalDate) h[4],
                (String) h[5],
                lines,
                drafts);
    }

    /** 工作台「补齐出仓单」：有剩余且无未审草稿时手工重建草稿（红冲后补发等场景）。 */
    @Transactional
    @PreAuthorize("hasAuthority('subcontract_outbound:execute')")
    public UUID regenerateDraft(UUID planId) {
        lockPlan(planId, "OPEN");
        synchronizeDirectLossAllowance(planId);
        @SuppressWarnings("unchecked")
        List<Object[]> plan = em.createNativeQuery("""
                SELECT p.order_bill_no, p.supplier_id, o.deliver_date
                FROM subcontract_material_plans p
                JOIN subcontract_orders o ON o.id = p.order_id
                WHERE p.id = :id
                """).setParameter("id", planId).getResultList();
        Object[] head = plan.getFirst();
        DraftCreation created = createDraftForPlan(planId, Objects.toString(head[0]), (UUID) head[1],
                toLocalDate(head[2]),
                currentUser.requireId(), null);
        if (created.firstDraftId() == null) {
            // ADR-103: 三种「没建成」各给各的大白话, 仓库不用猜是没余量、没货还是已有草稿。
            throw new ApiException(ErrorCode.CONFLICT, switch (created.skipReason()) {
                case NO_REMAINING -> "本计划已全部出仓, 没有待出的数量";
                case NO_STOCK -> "子件还没到货, 仓里一件都没有; 子件入库后系统会自动补草稿并通知仓库";
                case DRAFT_EXISTS -> "各待出仓仓组均已有未审核草稿，无需补齐";
            });
        }
        return created.firstDraftId();
    }

    /**
     * 工作台「不再出仓」：关闭剩余量（委外商料已够/订单变更等），必填原因。
     *
     * <p>ADR-103 §2.5：关掉余量即算「料已发完」(短交 FACT_SQL 只看 OPEN 计划), 末尾对本计划
     * 涉及的订货明细跑一次与入库同款的短交评估——已回厂且进容差的行当场按允许损耗结案,
     * 此前关余量后无人重评, 案件永远不开。发起人是仓库账号, 自动结案走的是系统路径
     * (不过订货单属主守卫、不开财务复核), 与 settleAfterStockIn 一致。
     */
    @Transactional
    @PreAuthorize("hasAuthority('subcontract_outbound:close')")
    public void closePlan(UUID planId, String reason) {
        if (reason == null || reason.isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "关闭发料计划必须填写原因");
        }
        lockPlan(planId, "OPEN");
        if (hasPendingDraft(planId)) {
            throw new ApiException(ErrorCode.CONFLICT, "存在未审核的出仓草稿，请先处理或删除草稿");
        }
        Long dependentLines = jdbc.queryForObject("""
                SELECT COUNT(*) FROM subcontract_material_plan_items
                WHERE plan_id = ? AND is_deleted = FALSE
                  AND flow_mode = 'MAKE_THEN_OUTBOUND'
                  AND preparation_status IN (
                      'ACTION_REQUIRED','IN_PREPARATION','WAITING_FQC','WAITING_INBOUND')
                """, Long.class, planId);
        if (dependentLines != null && dependentLines > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "同一委外订货仍有待启动或进行中的前置自制行，禁止从仓库关闭整张出仓计划；请拆单或先完成/取消依赖");
        }
        restorePrepareTaskReservations(planId,currentUser.requireId());
        releasePlanReservations(planId, "SUBCONTRACT_OUTBOUND_PLAN_CLOSED");
        jdbc.update("""
                UPDATE subcontract_material_plans
                SET status = 'CLOSED', close_reason = ?, updated_at = now(), updated_by = ?
                WHERE id = ?
                """, reason.trim(), currentUser.requireId(), planId);
        jdbc.update("""
                UPDATE subcontract_material_plan_items
                SET preparation_status = 'CANCELLED',
                    preparation_version = preparation_version + 1,
                    updated_at = now(), updated_by = ?
                WHERE plan_id = ? AND flow_mode IN (
                    'DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND','COMPONENT_OUTBOUND')
                  AND preparation_status <> 'OUTBOUND_COMPLETE'
                """, currentUser.requireId(), planId);
        List<UUID> orderItemIds = jdbc.queryForList("""
                SELECT DISTINCT order_item_id FROM subcontract_material_plan_items
                WHERE plan_id = ? AND is_deleted = FALSE AND order_item_id IS NOT NULL
                ORDER BY order_item_id
                """, UUID.class, planId);
        if (!orderItemIds.isEmpty()) {
            shortDelivery.ifAvailable(port -> port.settleAfterMaterialIssueClosed(orderItemIds));
        }
    }

    // ==================== 内部 ====================

    private void lockPlan(UUID planId, String requiredStatus) {
        List<String> rows = jdbc.query("""
                SELECT status FROM subcontract_material_plans
                WHERE id = ? AND is_deleted = FALSE FOR UPDATE
                """, (rs, rowNum) -> rs.getString(1), planId);
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "委外发料计划不存在");
        }
        if (!rows.getFirst().equals(requiredStatus)) {
            throw new ApiException(ErrorCode.CONFLICT, "发料计划已关闭或取消，请刷新后重试");
        }
    }

    private void releasePlanReservations(UUID planId, String reason) {
        jdbc.update("""
                UPDATE stock_reservations reservation
                SET released_qty = reservation.qty - reservation.consumed_qty,
                    status = 1, release_reason = ?,
                    lock_version = reservation.lock_version + 1,
                    updated_at = now(), updated_by = ?
                WHERE reservation.owner_type = 'SUBCONTRACT_OUTBOUND'
                  AND reservation.status = 0
                  AND reservation.is_deleted = FALSE
                  AND reservation.owner_id IN (
                      SELECT id FROM subcontract_material_plan_items
                      WHERE plan_id = ? AND is_deleted = FALSE)
                """, reason, currentUser.requireId(), planId);
    }

    private boolean hasPendingDraft(UUID planId) {
        Long count = jdbc.queryForObject("""
                SELECT COUNT(DISTINCT i.id) FROM subcontract_material_issues i
                WHERE i.status = 0 AND i.is_deleted = FALSE AND EXISTS (
                    SELECT 1 FROM subcontract_material_issue_items ii
                    JOIN subcontract_material_plan_items pi ON pi.id = ii.plan_item_id
                    WHERE ii.issue_id = i.id AND pi.plan_id = ?)
                """, Long.class, planId);
        return count != null && count > 0;
    }

    private boolean hasCurrentAuthority(String authority) {
        return currentUser.get()
                .map(user -> user.isSuperAdmin() || user.getAuthorities().stream()
                        .anyMatch(granted -> authority.equals(granted.getAuthority())))
                .orElse(false);
    }

    private static List<String> outboundActions(
            boolean canHandleOutbound, BigDecimal readyQty, BigDecimal draftReservedQty) {
        if (!canHandleOutbound) return List.of();
        BigDecimal ready = readyQty == null ? BigDecimal.ZERO : readyQty;
        BigDecimal draft = draftReservedQty == null ? BigDecimal.ZERO : draftReservedQty;
        return ready.add(draft).signum() > 0
                ? List.of("HANDLE_OUTBOUND")
                : List.of();
    }

    /** Prepared output is partitioned by its real source warehouse; DIRECT keeps its existing selection flow. */
    private List<Object[]> remainingLines(UUID planId) {
        return jdbc.query("""
                SELECT pi.id, pi.order_item_id, pi.parent_goods_id, pi.parent_color_id,
                       pi.goods_id, pi.unit_id, pi.bom_unit_qty, pi.planned_qty,
                       CASE
                         WHEN pi.flow_mode IN ('MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
                           AND pi.preparation_status='READY_OUTBOUND'
                         THEN GREATEST(COALESCE(physical.held_qty,0)-COALESCE((
                           SELECT SUM(ii.qty) FROM subcontract_material_issue_items ii
                           JOIN subcontract_material_issues i ON i.id=ii.issue_id
                           WHERE ii.plan_item_id=pi.id AND NOT ii.is_deleted
                             AND i.status=0 AND NOT i.is_deleted AND i.warehouse_id=physical.warehouse_id),0),0)
                         WHEN pi.preparation_status IN ('LEGACY_READY','READY_OUTBOUND')
                         THEN LEAST(pi.planned_qty, pi.prepared_qty)
                              - pi.issued_qty - COALESCE((
                           SELECT SUM(ii.qty) FROM subcontract_material_issue_items ii
                           JOIN subcontract_material_issues i ON i.id = ii.issue_id
                           WHERE ii.plan_item_id = pi.id AND i.status = 0 AND i.is_deleted = FALSE), 0)
                         ELSE 0
                       END,
                       pi.color_id,
                       CASE WHEN pi.flow_mode IN ('MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
                            THEN physical.warehouse_id ELSE pi.preparation_warehouse_id END,
                       pi.flow_mode
                FROM subcontract_material_plan_items pi
                LEFT JOIN LATERAL (
                    SELECT reservation.warehouse_id,SUM(reservation.qty-reservation.consumed_qty-reservation.released_qty) AS held_qty
                    FROM stock_reservations reservation
                    WHERE pi.flow_mode IN ('MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
                      AND reservation.owner_type='SUBCONTRACT_OUTBOUND' AND reservation.owner_id=pi.id
                      AND reservation.status=0 AND NOT reservation.is_deleted
                      AND fn_subcontract_preparation_reservation_has_qualified_origin(reservation.id)
                    GROUP BY reservation.warehouse_id
                ) physical ON TRUE
                WHERE pi.plan_id = ? AND pi.is_deleted = FALSE
                ORDER BY pi.line_no ASC NULLS LAST, pi.id, physical.warehouse_id
                """,
                (rs, rowNum) -> new Object[]{
                        rs.getObject(1, UUID.class), rs.getObject(2, UUID.class),
                        rs.getObject(3, UUID.class), rs.getObject(4, UUID.class),
                        rs.getObject(5, UUID.class), rs.getObject(6, UUID.class),
                        rs.getBigDecimal(7), rs.getBigDecimal(8), rs.getBigDecimal(9),
                        rs.getObject(10, UUID.class), rs.getObject(11, UUID.class),
                        rs.getString(12)},
                planId);
    }

    /**
     * 按计划剩余量分仓生成出仓草稿（调用方须持计划锁/在批准事务内）。
     * 同实际来源仓的准备切片合并；未选仓 DIRECT 行逐行独立，避免一张 issue 混仓。
     * 草稿 maker 置空（系统生成）：仓库凭 subcontract_material_issue:edit 权限拣货审核，
     * 不再受归属人隔离；返回草稿 id。
     */
    private UUID createDraftForPlan(UUID planId, String orderBillNo, UUID supplierId,
                                    LocalDate deliverDate, UUID actorUser) {
        return createDraftForPlan(planId, orderBillNo, supplierId, deliverDate, actorUser, null)
                .firstDraftId();
    }

    /** ADR-103: createDraftForPlan 一张草稿都没建成的原因, regenerateDraft 据此分别给大白话。 */
    enum DraftSkipReason {
        /** 计划余量已全部出仓 (或没有 READY 行)。 */
        NO_REMAINING,
        /** 有余量, 但发现货的行此刻在作业叶仓里一件都没有——等子件 (或目标件) 到货唤醒。 */
        NO_STOCK,
        /** 有余量也有货, 但每个待出仓组都已挂着未审草稿。 */
        DRAFT_EXISTS
    }

    /** 建草稿结果: {@code firstDraftId} 为 null 时 {@code skipReason} 必非 null。 */
    record DraftCreation(UUID firstDraftId, DraftSkipReason skipReason) {
    }

    /**
     * @param draftedPlanItems 非 null 时装入本次真的排进草稿的计划行 id。调用方据此决定叫不叫
     *                         仓库——没排进草稿的行就是「还在等料」，此刻通知它只会让人白跑一趟。
     */
    private DraftCreation createDraftForPlan(UUID planId, String orderBillNo, UUID supplierId,
                                             LocalDate deliverDate, UUID actorUser,
                                             Set<UUID> draftedPlanItems) {
        List<Object[]> pending = remainingLines(planId).stream()
                .filter(row -> decimal(row[8]).signum() > 0)
                .toList();
        if (pending.isEmpty()) {
            return new DraftCreation(null, DraftSkipReason.NO_REMAINING);
        }
        List<Object[]> remaining = pending.stream()
                .map(this::draftLineCappedByStock)
                .filter(Objects::nonNull)
                .toList();
        if (remaining.isEmpty()) {
            return new DraftCreation(null, DraftSkipReason.NO_STOCK);
        }
        Map<String, List<Object[]>> groups = new LinkedHashMap<>();
        for (Object[] row : remaining) {
            UUID frozenWarehouseId = (UUID) row[10];
            // Prepared slices share a header only when their physical warehouses match.
            // DIRECT rows have no warehouse until warehouse staff choose one,
            // so each remains its own draft and can later choose independently.
            String key = frozenWarehouseId == null
                    ? ("LEGACY_BOM_COMPONENT".equals(row[11])
                        ? "LEGACY_UNASSIGNED"
                        : "UNASSIGNED:" + row[0])
                    : "WAREHOUSE:" + frozenWarehouseId;
            if (frozenWarehouseId == null
                    ? hasPendingDraftForPlanItem((UUID) row[0])
                    : hasPendingDraftForWarehouse(planId, frozenWarehouseId)) {
                continue;
            }
            groups.computeIfAbsent(key, ignored -> new ArrayList<>()).add(row);
        }
        if (groups.isEmpty()) {
            return new DraftCreation(null, DraftSkipReason.DRAFT_EXISTS);
        }
        UUID firstDraftId = null;
        for (List<Object[]> group : groups.values()) {
            UUID draftId = createDraftForLines(
                    group, orderBillNo, supplierId, deliverDate, actorUser);
            if (firstDraftId == null) firstDraftId = draftId;
            if (draftedPlanItems != null) {
                group.forEach(row -> draftedPlanItems.add((UUID) row[0]));
            }
        }
        return new DraftCreation(firstDraftId, null);
    }

    /**
     * 现货流向(DIRECT / COMPONENT)建草稿前先按「该仓此刻的合格可动用量」把本批截断，
     * 并在还没定发料仓时替仓库选一个有货的作业叶仓。返回 null = 这一行此刻一件都发不出去，
     * 本轮不给它建草稿，等子件(或目标件)到货唤醒时再来。
     *
     * <p>这一段是 ADR-101 的核心：在此之前系统一律按整笔余量开满量草稿，于是
     * ①子件还在采购路上时仓库照样收到一张发不出去的活，②分批发料时「审核第一批」会顺手
     * 为剩余量再开一张满量草稿，占不上库存就抛 409 把刚审核的那一批一起回滚。
     *
     * <p>返回的数组比 {@link #remainingLines} 多一位：[12] 是这张草稿实际该落的仓
     * (已冻结的发料仓优先，否则是这里选出来的建议仓)。[10] 保持原样，分组口径不变——
     * 未定仓的行仍各自成单，仓库要改仓时互不牵连。前置自制两种流向吃的是专属预留而不是
     * 公共可动用量，这里一律原样放行，由 reserveDraft 按预留口径把关。
     */
    private Object[] draftLineCappedByStock(Object[] row) {
        Object[] extended = Arrays.copyOf(row, 13);
        extended[12] = row[10];
        String flowMode = Objects.toString(row[11], "");
        if (!"DIRECT_OUTBOUND".equals(flowMode) && !"COMPONENT_OUTBOUND".equals(flowMode)) {
            return extended;
        }
        UUID goodsId = (UUID) row[4];
        UUID colorId = (UUID) row[9];
        UUID warehouseId = (UUID) row[10];
        BigDecimal available;
        if (warehouseId == null) {
            // ADR-103: 选仓与锁判据共用同一段 QUALIFIED_AVAILABLE_STOCK_SOURCE。
            List<Object[]> best = jdbc.query("""
                    SELECT sa.warehouse_id, GREATEST(COALESCE(sa.available_qty, 0), 0)
                    """ + QUALIFIED_AVAILABLE_STOCK_SOURCE + """
                      AND sa.goods_id = CAST(? AS uuid)
                      AND sa.color_id IS NOT DISTINCT FROM CAST(? AS uuid)
                    ORDER BY GREATEST(COALESCE(sa.available_qty, 0), 0) DESC, w.code
                    LIMIT 1
                    """,
                    (rs, rowNum) -> new Object[]{rs.getObject(1, UUID.class), rs.getBigDecimal(2)},
                    goodsId, colorId);
            if (best.isEmpty()) {
                return null;
            }
            extended[12] = best.getFirst()[0];
            available = decimal(best.getFirst()[1]);
        } else {
            available = decimal(jdbc.query("""
                    SELECT GREATEST(COALESCE(sa.available_qty, 0), 0)
                    FROM v_stock_available sa
                    WHERE sa.warehouse_id = CAST(? AS uuid)
                      AND sa.goods_id = CAST(? AS uuid)
                      AND sa.color_id IS NOT DISTINCT FROM CAST(? AS uuid)
                    """, (rs, rowNum) -> rs.getBigDecimal(1), warehouseId, goodsId, colorId)
                    .stream().findFirst().orElse(BigDecimal.ZERO));
        }
        if (available.signum() <= 0) {
            return null;
        }
        extended[8] = decimal(row[8]).min(available);
        return extended;
    }

    private boolean hasPendingDraftForPlanItem(UUID planItemId) {
        Long count = jdbc.queryForObject("""
                SELECT COUNT(*)
                FROM subcontract_material_issue_items issue_item
                JOIN subcontract_material_issues issue ON issue.id = issue_item.issue_id
                WHERE issue_item.plan_item_id = ?
                  AND issue.status = 0 AND issue.is_deleted = FALSE
                """, Long.class, planItemId);
        return count != null && count > 0;
    }

    private boolean hasPendingDraftForWarehouse(UUID planId, UUID warehouseId) {
        Long count = jdbc.queryForObject("""
                SELECT COUNT(DISTINCT issue.id)
                FROM subcontract_material_issues issue
                WHERE issue.status = 0 AND issue.is_deleted = FALSE
                  AND issue.warehouse_id = ?
                  AND EXISTS (
                      SELECT 1
                      FROM subcontract_material_issue_items issue_item
                      JOIN subcontract_material_plan_items plan_item
                        ON plan_item.id = issue_item.plan_item_id
                      WHERE issue_item.issue_id = issue.id
                        AND plan_item.plan_id = ?)
                """, Long.class, warehouseId, planId);
        return count != null && count > 0;
    }

    private UUID createDraftForLines(
            List<Object[]> remaining,
            String orderBillNo,
            UUID supplierId,
            LocalDate deliverDate,
            UUID actorUser) {
        List<UUID> goodsIds = new ArrayList<>();
        remaining.forEach(row -> {
            goodsIds.add((UUID) row[4]);
            goodsIds.add((UUID) row[2]);
        });
        Map<UUID, Object[]> master = loadGoodsMaster(goodsIds);

        SubcontractMaterialIssue draft = new SubcontractMaterialIssue();
        draft.setBillNo(docNumberService.nextNumber(DocNumberPrefix.SUB_MATERIAL_ISSUE));
        draft.setBillDate(BusinessTime.today());
        draft.setSupplierId(supplierId);
        // [12]：已冻结的发料仓优先，否则是 draftLineCappedByStock 选出来的建议仓。
        draft.setWarehouseId((UUID) remaining.getFirst()[12]);
        draft.setDeliverDate(deliverDate);
        draft.setStatus(ISSUE_DRAFT);
        // 系统生成草稿：没有个人归属人，显式归入仓库委外出仓池(V678)，不再靠空归属对全员可见。
        draft.setMakerId(null);
        draft.setOwnerPool(SubcontractMaterialIssue.POOL_WAREHOUSE_OUTBOUND);
        draft.setRemark("系统按委外订货单 " + orderBillNo + " 财务批准自动生成");
        draft.setSourceDocNo(orderBillNo);
        issueRepo.save(draft);
        jdbc.update("UPDATE subcontract_material_issues SET created_by = ? WHERE id = ?",
                actorUser, draft.getId());

        OffsetDateTime now = OffsetDateTime.now();
        int lineNo = 1;
        for (Object[] row : remaining) {
            SubcontractMaterialIssueItem it = new SubcontractMaterialIssueItem();
            it.setIssueId(draft.getId());
            it.setBillNo(draft.getBillNo());
            it.setBillDate(draft.getBillDate());
            it.setLineNo(lineNo++);
            it.setOrderItemId((UUID) row[1]);
            it.setPlanItemId((UUID) row[0]);
            it.setGoodsId((UUID) row[4]);
            Object[] childMaster = master.get((UUID) row[4]);
            applySnapshot(it, childMaster, false, now);
            it.setUnitId(row[5] != null ? (UUID) row[5]
                    : childMaster == null ? null : (UUID) childMaster[3]);
            it.setColorId((UUID) row[9]);
            it.setUnitRate(BigDecimal.ONE);
            it.setQty(decimal(row[8]));
            it.setParentGoodsId((UUID) row[2]);
            applySnapshot(it, master.get((UUID) row[2]), true, now);
            it.setParentColorId((UUID) row[3]);
            issueItemRepo.save(it);
        }
        issueRepo.flush();issueItemRepo.flush();
        reserveDraft(draft.getId(),draft.getWarehouseId());
        return draft.getId();
    }

    private static void applySnapshot(SubcontractMaterialIssueItem item, Object[] master,
                                      boolean parent, OffsetDateTime now) {
        String code = master == null ? null : Objects.toString(master[1], null);
        String name = master == null ? null : Objects.toString(master[2], null);
        if (parent) {
            item.setParentGoodsCodeSnapshot(code);
            item.setParentGoodsNameSnapshot(name);
            item.setParentGoodsSnapshotSource(SubcontractGoodsSnapshot.MASTER_AT_SAVE);
            item.setParentGoodsSnapshotLockedAt(now);
        } else {
            item.setGoodsCodeSnapshot(code);
            item.setGoodsNameSnapshot(name);
            item.setGoodsSnapshotSource(SubcontractGoodsSnapshot.MASTER_AT_SAVE);
            item.setGoodsSnapshotLockedAt(now);
        }
    }

    /**
     * V581：目标件是否「只有一个叶子子件」。是则委外直接发那个子件，不先自制。
     *
     * <p>判据与迁移 V581 的 {@code fn_guard_subcontract_target_quantity_basis_insert}
     * COMPONENT 分支逐字同口径，任一条不满足返回 {@code null}（回落既有
     * MAKE_THEN_OUTBOUND，不是报错）：
     * <ol>
     *   <li>活动 BOM 边恰好 1 条（活动 = 边未删 + 子件未删 + 子件不是 auto_created 占位）；</li>
     *   <li>该边 {@code consumption_basis='PER_UNIT'}——PER_PACKAGE/FIXED_BATCH 带取整，
     *       压不成一个标量冻结单耗；</li>
     *   <li>该边 {@code control_stage} 是真实投入阶段（SHIP/REFERENCE 只是参考料）；</li>
     *   <li>该子件自身没有活动 BOM 边（真正的一层）。</li>
     * </ol>
     */
    private SoleComponent soleOutboundComponent(UUID goodsId) {
        // 判据本体在 V581 的 fn_subcontract_sole_component_goods，Java 只取
        // 那条唯一边的身份与单耗——判据不在两处各写一遍，避免日后漂移。
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT edge.component_goods_id, edge.color_id, child.unit_id, edge.qty
                FROM goods_bom_items edge
                JOIN goods child ON child.id = edge.component_goods_id
                 AND child.is_deleted = FALSE
                 AND COALESCE(child.auto_created, FALSE) = FALSE
                WHERE edge.goods_id = :goodsId AND edge.is_deleted = FALSE
                  AND fn_subcontract_sole_component_goods(CAST(:goodsId AS uuid))
                """).setParameter("goodsId", goodsId));
        if (rows.size() != 1) {
            return null;
        }
        Object[] row = rows.getFirst();
        BigDecimal bomQty = decimal(row[3]);
        if (bomQty.signum() <= 0 || row[2] == null) {
            return null;
        }
        return new SoleComponent((UUID) row[0], (UUID) row[1], (UUID) row[2], bomQty);
    }

    private BomSnapshot currentBomSnapshot(UUID goodsId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT bom.id, bom.component_goods_id, bom.color_id, bom.qty
                FROM goods_bom_items bom
                JOIN goods child ON child.id = bom.component_goods_id
                 AND child.is_deleted = FALSE
                 AND COALESCE(child.auto_created, FALSE) = FALSE
                WHERE bom.goods_id = :goodsId AND bom.is_deleted = FALSE
                ORDER BY bom.id
                """).setParameter("goodsId", goodsId));
        StringBuilder canonical = new StringBuilder("GOODS|")
                .append(goodsId).append('\n');
        for (Object[] row : rows) {
            canonical.append(row[0]).append('|').append(row[1]).append('|')
                    .append(Objects.toString(row[2], "")).append('|')
                    .append(decimal(row[3]).stripTrailingZeros().toPlainString())
                    .append('\n');
        }
        try {
            byte[] digest = java.security.MessageDigest.getInstance("SHA-256")
                    .digest(canonical.toString().getBytes(
                            java.nio.charset.StandardCharsets.UTF_8));
            return new BomSnapshot(!rows.isEmpty(),
                    java.util.HexFormat.of().formatHex(digest));
        } catch (java.security.NoSuchAlgorithmException impossible) {
            throw new IllegalStateException("SHA-256 is unavailable", impossible);
        }
    }

    /** goods 主档：id → [id, code, name, unit_id, stock_place]。 */
    private Map<UUID, Object[]> loadGoodsMaster(List<UUID> goodsIds) {
        List<UUID> ids = goodsIds.stream().filter(Objects::nonNull).distinct().toList();
        if (ids.isEmpty()) {
            return Map.of();
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT id, code, name, unit_id, stock_place FROM goods WHERE id IN (:ids)
                """).setParameter("ids", ids).getResultList();
        Map<UUID, Object[]> map = new HashMap<>();
        rows.forEach(row -> map.put((UUID) row[0], row));
        return map;
    }

    /** 原生查询 DATE 列安全转 LocalDate（驱动可能返回 java.sql.Date 或 LocalDate）。 */
    private static LocalDate toLocalDate(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate d) return d;
        if (value instanceof java.sql.Date sqlDate) return sqlDate.toLocalDate();
        return LocalDate.parse(value.toString());
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : (BigDecimal) value;
    }

    private static Object[] append(Object[] params, Object... extra) {
        Object[] out = new Object[params.length + extra.length];
        System.arraycopy(params, 0, out, 0, params.length);
        System.arraycopy(extra, 0, out, params.length, extra.length);
        return out;
    }

    private record BomSnapshot(boolean hasChildren, String fingerprint) {
    }

    /** V581：目标件唯一的叶子子件（发外物），{@code bomQty} 是每 1 个目标件基本单位的单耗。 */
    private record SoleComponent(UUID goodsId, UUID colorId, UUID unitId,
                                 BigDecimal bomQty) {
    }
}
