package com.uten.imp.features.production.plan;
import com.uten.imp.common.util.NativeValueConverters;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.plan.dto.PlanDetail;
import com.uten.imp.features.production.plan.dto.PlanItemDto;
import com.uten.imp.features.production.plan.dto.PlanItemLine;
import com.uten.imp.features.production.plan.dto.PlanListItem;
import com.uten.imp.features.production.plan.dto.PlanQueryFilter;
import com.uten.imp.features.production.plan.dto.PlanSaveRequest;
import com.uten.imp.features.production.plan.dto.PlanTraceLink;
import com.uten.imp.features.production.mrp.MrpRow;
import com.uten.imp.features.production.mrp.MrpService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.features.production.mrp.ProductionPlanningDraftService;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.TreeSet;
import java.util.UUID;

/**
 * 生产计划服务：CRUD（主+明细）+ 审核状态机 + is_closed 派生。
 *
 * <p><b>审核（status 0→1）</b>：
 * <ul>
 *   <li>业务链排产联动：写 plan_order_item_links + 回写 sales_order_items.planned_qty
 *       + BOM/分配核验（未核验或真实短缺→3待物料 / 已分配且齐套→4已排产）+ 防超排硬校验</li>
 *   <li>重算主表 {@code is_closed}（CheckFulfill4 派生：所有明细 {@code qty - iqty ≤ 0}）</li>
 *   <li>【本期后置】设 plan_items.step_legacy_id 首工序 / 填 F_ProductingItem（车间/排产模块）</li>
 * </ul>
 *
 * <p><b>不调</b> {@code StockService}（计划不动库存）；<b>不调</b> {@code ArApLedgerService}（计划不立帐）。
 *
 * <p><b>红冲（1→-1）</b>：links 软删 + planned_qty 回退 + 行状态回退；已报工/已入库拒绝红冲。
 */
@Service
@RequiredArgsConstructor
public class ProductionPlanService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 订单行链路状态（chain_status）：排产落点两态。 */
    private static final short CHAIN_WAIT_MATERIAL = 3;  // 待物料/待分配核验
    private static final short CHAIN_PLANNED = 4;        // 已排产

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of(
            "billDate", "billDate",
            "deliveryDate", "deliveryDate");

    private final ProductionPlanRepository planRepo;
    private final ProductionPlanItemRepository itemRepo;
    private final PlanOrderItemLinkRepository linkRepo;
    private final MrpService mrpService;
    private final ProductionPlanningDraftService planningDraftService;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final EntityManager em;
    private final DocNumberService docNumberService;
    private final ProductionProductNoAllocator productNoAllocator;
    private final ChainNoticeService chainNotice;
    private final ProductionDocumentAccessPolicy access;
    private final MaterialAnalysisService materialAnalysisService;
    private final InventoryMutationLock inventoryLock;

    @Transactional(readOnly = true)
    public PageResponse<PlanListItem> list(PlanQueryFilter f, int page, int size, String sort, String order) {
        var readScope = access.scope();
        Specification<ProductionPlan> spec = (Root<ProductionPlan> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                              CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            ps.add(access.readablePredicate(root, cb, "makerId", readScope));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(cb.like(cb.lower(root.get("billNo")), "%" + f.keyword().toLowerCase() + "%"));
            }
            if (f.departmentId() != null) ps.add(cb.equal(root.get("departmentId"), f.departmentId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.closed() != null) ps.add(cb.equal(root.get("closed"), f.closed()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<ProductionPlan> p = planRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public PlanDetail detail(UUID id) {
        ProductionPlan p = requirePlan(id);
        access.requireReadable(p.getMakerId(), "生产计划不存在");
        List<PlanItemDto> items = itemRepo.findByPlanIdOrderByLineNoAsc(id).stream().map(this::toItemDto).toList();
        return toDetail(p, items);
    }

    @Transactional
    public PlanDetail create(PlanSaveRequest req) {
        tx.bind();
        ProductionPlan p = new ProductionPlan();
        applyHeader(req, p);
        p.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
        p.setStatus(STATUS_DRAFT);
        planRepo.save(p);
        // The database product-number allocator locks this persisted plan and
        // reads its server-issued bill_no. Do not rely on an implicit JPA flush.
        planRepo.flush();
        saveItems(p, req.getItems());
        recomputeClosed(p.getId());
        return detail(p.getId());
    }

    @Transactional
    public PlanDetail update(UUID id, PlanSaveRequest req) {
        tx.bind();
        ProductionPlan p = requirePlanForUpdate(id);
        access.requireWritable(p.getMakerId(), "只能操作本人负责的生产计划");
        if (p.getStatus() != STATUS_DRAFT) throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        if (isMaterialAnalysisPlan(id)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "物料分析生成的计划不可直接编辑，请删除草稿后回到物料分析重新生成");
        }
        planningDraftService.supersedeActive(id, "生产计划已编辑，原预排草案失效");
        applyHeader(req, p);
        itemRepo.deleteByPlanId(id);
        itemRepo.flush();
        saveItems(p, req.getItems());
        recomputeClosed(id);
        return detail(id);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        ProductionPlan p = requirePlanForUpdate(id);
        access.requireWritable(p.getMakerId(), "只能操作本人负责的生产计划");
        rejectDirectLifecycleOfExecutionV1Subplan(id, "删除");
        if (p.getStatus() == STATUS_APPROVED) throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        planningDraftService.supersedeActive(id, "生产计划已删除，原预排草案失效");
        p.setDeleted(true);
        p.setDeletedAt(OffsetDateTime.now());
        planRepo.save(p);
    }

    /**
     * 审核（status 0→1）。
     *
     * <p>锁定并校验草稿计划及销售来源，建立或复核 {@code plan_order_item_links}，
     * 回写销售订单行的 {@code planned_qty}/{@code chain_status}，重算 {@code is_closed}，
     * 并将排产结果写入业务 Outbox。计划审核不直接过账库存或应收应付。
     */
    @Transactional
    public PlanDetail approve(UUID id) {
        tx.bind();
        lockSourceAnalysisInventoryDimensions(id);
        ProductionPlan p = requirePlanForUpdate(id);
        access.requireWritable(p.getMakerId(), "无权审核此生产计划", access.scope());
        if (p.getStatus() == null || p.getStatus() != STATUS_DRAFT)
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        if (p.isStopped() || p.isCanceled())
            throw new ApiException(ErrorCode.BUSINESS, "已中止或已取消的生产计划不可审核");
        if (itemRepo.findByPlanIdOrderByLineNoAsc(id).isEmpty())
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        validateMaterialAnalysisPlanForApproval(id);
        p.setStatus(STATUS_APPROVED);
        p.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        planRepo.save(p);
        planRepo.flush();
        boolean shortage = linkOrderItems(id); // shortage 仅表示分配已核验后的真实及时缺口
        linkRepo.flush();
        recomputeClosed(id);
        planningDraftService.applyActive(id);
        chainNotice.notifyPlanScheduled(id, shortage); // 未核验不伪装成缺料；真实缺料才通知采购/调度
        return detail(id);
    }

    private boolean isMaterialAnalysisPlan(UUID planId) {
        Number count = (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM production_plans
                WHERE id = :id AND material_analysis_id IS NOT NULL
                """).setParameter("id", planId).getSingleResult();
        return count.longValue() > 0;
    }

    /** Re-lock and compare the immutable analysis demand, plan line and conservation link. */
    private void validateMaterialAnalysisPlanForApproval(UUID planId) {
        List<Object[]> analysisHeaders = com.uten.imp.common.util.NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                SELECT analysis.id, plan.material_analysis_item_id
                FROM production_plans plan
                JOIN production_material_analyses analysis
                  ON analysis.id = plan.material_analysis_id
                WHERE plan.id = :id
                FOR UPDATE OF analysis
                """).setParameter("id", planId));
        if (analysisHeaders.isEmpty()) return;
        materialAnalysisService.requireCurrentBomSnapshot(
                (UUID) analysisHeaders.getFirst()[0],
                java.util.Set.of((UUID) analysisHeaders.getFirst()[1]));
        List<Object[]> rows = com.uten.imp.common.util.NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT p.material_analysis_id, p.material_analysis_item_id,
                               ai.goods_id, ai.color_id, ai.unit_id,
                               COALESCE(soi.unit_rate,1), ai.sales_order_item_id,
                               plan_item.goods_id, plan_item.color_id, plan_item.unit_id,
                               COALESCE(plan_item.unit_rate,1), plan_item.sales_order_item_id,
                               plan_item.qty, analysis_link.submitted_qty,
                               analysis_link.allocation_status
                        FROM production_plans p
                        JOIN production_material_analysis_items ai
                          ON ai.analysis_id = p.material_analysis_id
                         AND ai.id = p.material_analysis_item_id
                         AND ai.is_deleted = FALSE
                        JOIN production_material_analysis_plan_links analysis_link
                          ON analysis_link.plan_id = p.id
                         AND analysis_link.analysis_id = p.material_analysis_id
                         AND analysis_link.analysis_item_id = p.material_analysis_item_id
                        JOIN production_plan_items plan_item
                          ON plan_item.plan_id = p.id AND plan_item.is_deleted = FALSE
                        LEFT JOIN sales_order_items soi
                          ON soi.id = ai.sales_order_item_id AND soi.is_deleted = FALSE
                        WHERE p.id = :id
                        FOR UPDATE OF ai, analysis_link, plan_item
                        """).setParameter("id", planId));
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "物料分析计划缺少有效需求、计划明细或提交守恒关联");
        }
        if (rows.size() != 1) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "物料分析计划必须且只能包含一条有效计划明细");
        }
        Object[] row = rows.getFirst();
        BigDecimal sourceRate = normalizedPositiveRate(bd(row[5]), "物料分析需求");
        BigDecimal planRate = normalizedPositiveRate(bd(row[10]), "生产计划明细");
        BigDecimal planQty = requirePositiveAllocation(bd(row[12]));
        BigDecimal linkedQty = requirePositiveAllocation(bd(row[13]));
        if (!Objects.equals(row[2], row[7])
                || !Objects.equals(row[3], row[8])
                || !Objects.equals(row[4], row[9])
                || sourceRate.compareTo(planRate) != 0
                || !Objects.equals(row[6], row[11])
                || planQty.compareTo(linkedQty) != 0
                || !"SUBMITTED".equals(row[14])) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "物料分析需求、计划明细或提交数量已不一致，请释放后重新生成");
        }
    }

    /**
     * 自底向上 orchestrator 用的最小化审核（status 0→1）：仅翻转状态、戳 approver/bom_depth/auto_generated。
     * <b>不</b>做 {@link #approve} 的销售联动（linkOrderItems）/缺料通知（notifyPlanScheduled）/草案应用
     * （applyActive）——那些是给人审计划用的副作用；自动子计划的内容由父级 BOM+MAKE 短缺完全决定，无人决策。
     * {@link Propagation#MANDATORY} 强制加入 orchestrator 事务（全树 all-or-nothing）。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void autoApproveForOrchestrator(UUID planId, int bomDepth) {
        ProductionPlan p = em.find(ProductionPlan.class, planId,
                jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (p == null || p.isDeleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "生产计划不存在");
        }
        if (p.getStatus() == null || p.getStatus() != STATUS_DRAFT) {
            return; // 幂等：已审核（如重放）直接返回
        }
        p.setStatus(STATUS_APPROVED);
        p.setApproverId(currentUser.requireEmployeeId());
        p.setAutoGenerated(true);
        p.setBomDepth(bomDepth);
        planRepo.save(p);
    }

    /**
     * 排产联动（docs/07-业务链路/02 §三）。两种来源：
     * ① 合并排产（调度工作台）：links 已在创建时预建（一行可挂多订单行），审核只做校验+回写；
     * ② 手工计划单：明细行带 salesOrderItemId（1:1），审核时按 qty 建行。
     * 每笔分摊按未交付量扣已预留与未完工计划量做防超排硬校验；
     * 行状态推进：未核验或真实短缺→3待物料 / 已分配且及时齐套→4已排产。
     * @return 是否为已核验的真实及时缺口；未核验返回 false，避免误发采购通知
     */
    private boolean linkOrderItems(UUID planId) {
        List<ProductionPlanItem> items = itemRepo.findByPlanIdOrderByLineNoAsc(planId);
        if (items.isEmpty()) return false;
        List<PlanAllocation> allocations = collectAllocations(items);
        Map<UUID, LockedOrderItem> lockedOrderItems = lockAndValidateSourceOrderItems(allocations);
        MaterialDecision material = materialDecision(planId);
        short chain = material == MaterialDecision.READY ? CHAIN_PLANNED : CHAIN_WAIT_MATERIAL;
        for (PlanAllocation allocation : allocations) {
            applyAllocation(allocation, lockedOrderItems.get(allocation.orderItemId()), chain);
            if (allocation.prebuiltLink() == null) {
                PlanOrderItemLink link = new PlanOrderItemLink();
                link.setPlanItemId(allocation.planItem().getId());
                link.setOrderItemId(allocation.orderItemId());
                link.setAllocatedQty(allocation.allocatedQty());
                linkRepo.save(link);
            }
        }
        return material == MaterialDecision.VERIFIED_SHORTAGE;
    }

    /**
     * Resolve both supported source forms into one allocation model. A merged
     * plan item's active links must account for exactly the plan item quantity;
     * otherwise the plan quantity and the order-side planned quantity would
     * immediately diverge.
     */
    private List<PlanAllocation> collectAllocations(List<ProductionPlanItem> items) {
        List<PlanAllocation> allocations = new ArrayList<>();
        for (ProductionPlanItem item : items) {
            BigDecimal planQty = validatePlanItemForApproval(item);
            List<PlanOrderItemLink> links = linkRepo.findActiveByPlanItemIds(List.of(item.getId()));
            if (!links.isEmpty()) {
                if (item.getSalesOrderItemId() != null
                        && (links.size() != 1
                        || !item.getSalesOrderItemId().equals(links.getFirst().getOrderItemId()))) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "计划明细单值销售来源与预建分摊不一致");
                }
                BigDecimal linkedQty = BigDecimal.ZERO;
                for (PlanOrderItemLink link : links) {
                    if (!item.getId().equals(link.getPlanItemId())) {
                        throw new ApiException(ErrorCode.CONFLICT, "排产关联不属于当前计划明细");
                    }
                    if (link.getOrderItemId() == null) {
                        throw new ApiException(ErrorCode.CONFLICT, "排产关联缺少销售订单行");
                    }
                    BigDecimal allocatedQty = requirePositiveAllocation(link.getAllocatedQty());
                    linkedQty = linkedQty.add(allocatedQty);
                    allocations.add(new PlanAllocation(
                            item, link.getOrderItemId(), allocatedQty, link));
                }
                if (linkedQty.compareTo(planQty) != 0) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "计划明细分摊合计必须等于计划数量（计划 "
                                    + qtyText(planQty) + "，分摊 " + qtyText(linkedQty) + "）");
                }
            } else if (item.getSalesOrderItemId() != null) {
                BigDecimal allocatedQty = planQty;
                allocations.add(new PlanAllocation(
                        item, item.getSalesOrderItemId(), allocatedQty, null));
            } else if (hasHistoricalOrderLinks(item.getId())) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "计划明细的销售来源分摊已失效，不可降级为无来源计划审核");
            }
        }
        return allocations;
    }

    private boolean hasHistoricalOrderLinks(UUID planItemId) {
        Number count = (Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM plan_order_item_links
                        WHERE plan_item_id = :itemId
                        """)
                .setParameter("itemId", planItemId)
                .getSingleResult();
        return count.longValue() > 0;
    }
    /**
     * Different production plans can allocate the same sales-order line.
     * Lock the order headers and lines in stable order before validating any
     * allocation, so no planned_qty write can occur against a changed/stopped
     * source document and concurrent plans cannot over-allocate one order line.
     */
    private Map<UUID, LockedOrderItem> lockAndValidateSourceOrderItems(
            List<PlanAllocation> allocations) {
        TreeSet<UUID> ids = new TreeSet<>();
        allocations.stream().map(PlanAllocation::orderItemId).forEach(ids::add);
        if (ids.isEmpty()) return Map.of();

        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT i.id, i.order_id,
                               o.status, o.is_stopped, o.is_deleted, o.is_closed,
                               i.is_deleted,
                               i.goods_id, i.color_id, i.unit_id, i.unit_rate,
                               i.qty, i.shipped_qty, i.returned_qty, i.flag_qty,
                               i.reserved_qty, i.planned_qty, i.produced_qty, i.chain_status,
                               o.finance_confirmed
                        FROM sales_order_items i
                        JOIN sales_orders o ON o.id = i.order_id
                        WHERE i.id IN (:ids)
                        ORDER BY o.id, i.id
                        FOR UPDATE OF o, i
                        """)
                .setParameter("ids", ids)
                .getResultList();
        if (rows.size() != ids.size()) {
            throw new ApiException(ErrorCode.CONFLICT, "排产关联的销售订单或明细不存在");
        }

        Map<UUID, LockedOrderItem> locked = new HashMap<>();
        for (Object[] row : rows) {
            UUID orderItemId = (UUID) row[0];
            short orderStatus = row[2] == null ? 0 : ((Number) row[2]).shortValue();
            if (orderStatus != STATUS_APPROVED
                    || Boolean.TRUE.equals(row[3])
                    || Boolean.TRUE.equals(row[4])
                    || Boolean.TRUE.equals(row[5])) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "排产关联的销售订单未审核、已中止、已关闭或已删除");
            }
            if (!Boolean.TRUE.equals(row[19])) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "排产关联的销售订单未通过财务确认，请先由财务确认后再排产");
            }
            if (Boolean.TRUE.equals(row[6])) {
                throw new ApiException(ErrorCode.CONFLICT, "排产关联的销售订单行已删除");
            }
            BigDecimal unitRate = normalizedPositiveRate(
                    row[10] == null ? BigDecimal.ONE : bd(row[10]), "销售订单行");
            short chainStatus = row[18] == null ? 0 : ((Number) row[18]).shortValue();
            if (chainStatus <= 0 || chainStatus > 8) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "销售订单行未进入待排产链路、已取消或已全部发货");
            }
            BigDecimal qty = bd(row[11]);
            BigDecimal shipped = bd(row[12]);
            BigDecimal returned = bd(row[13]);
            BigDecimal flagged = bd(row[14]);
            BigDecimal reserved = bd(row[15]);
            BigDecimal planned = bd(row[16]);
            BigDecimal produced = bd(row[17]);
            if (hasNegative(qty, shipped, returned, flagged, reserved, planned, produced)
                    || produced.compareTo(planned) > 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "销售订单行累计量为负或已生产量超过已排产量，请先核对数据");
            }
            BigDecimal outstanding = qty.subtract(shipped).add(returned).subtract(flagged);
            if (outstanding.signum() < 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "销售订单行未交付量为负，请先核对发货、退货和结案数量");
            }
            BigDecimal unfinishedPlan = planned.subtract(produced);
            BigDecimal remaining = outstanding.subtract(reserved).subtract(unfinishedPlan);
            if (remaining.signum() < 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "销售订单行剩余可排数量为负，请先核对预留和已排产数据");
            }
            locked.put(orderItemId, new LockedOrderItem(
                    (UUID) row[7], (UUID) row[8], (UUID) row[9], unitRate, remaining));
        }
        lockAndRevalidatePrebuiltLinks(allocations);

        Map<UUID, BigDecimal> requestedByOrderItem = new HashMap<>();
        for (PlanAllocation allocation : allocations) {
            LockedOrderItem orderItem = locked.get(allocation.orderItemId());
            if (orderItem == null) {
                throw new ApiException(ErrorCode.CONFLICT, "排产关联的销售订单行不存在");
            }
            validateAllocationIdentity(allocation, orderItem);
            requestedByOrderItem.merge(
                    allocation.orderItemId(), allocation.allocatedQty(), BigDecimal::add);
        }
        for (Map.Entry<UUID, BigDecimal> entry : requestedByOrderItem.entrySet()) {
            BigDecimal remaining = locked.get(entry.getKey()).remainingQty();
            if (entry.getValue().compareTo(remaining) > 0) {
                throw new ApiException(ErrorCode.BUSINESS,
                        "排产量超过订单未满足需求（剩余可排 " + qtyText(remaining) + "）");
            }
        }
        return locked;
    }

    /** 销售头/行锁定后再锁并刷新预建 links，禁止使用发现阶段的陈旧分摊。 */
    private void lockAndRevalidatePrebuiltLinks(List<PlanAllocation> allocations) {
        List<PlanAllocation> prebuilt = allocations.stream()
                .filter(allocation -> allocation.prebuiltLink() != null)
                .sorted(java.util.Comparator.comparing(allocation -> allocation.prebuiltLink().getId()))
                .toList();
        Map<UUID, BigDecimal> qtyByPlanItem = new HashMap<>();
        for (PlanAllocation allocation : prebuilt) {
            PlanOrderItemLink link = allocation.prebuiltLink();
            em.lock(link, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
            em.refresh(link);
            BigDecimal currentAllocated = requirePositiveAllocation(link.getAllocatedQty());
            if (link.isDeleted()
                    || !allocation.planItem().getId().equals(link.getPlanItemId())
                    || !allocation.orderItemId().equals(link.getOrderItemId())
                    || currentAllocated.compareTo(allocation.allocatedQty()) != 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "预建销售分摊已被删除或变更，请刷新计划后重试");
            }
            if (hasNonZero(link.getProducedQty(), link.getInboundQty(), link.getCappedQty())) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "草稿计划的预建分摊存在生产、入库或封顶累计量，不可审核");
            }
            qtyByPlanItem.merge(link.getPlanItemId(), currentAllocated, BigDecimal::add);
        }
        for (PlanAllocation allocation : prebuilt) {
            BigDecimal total = qtyByPlanItem.get(allocation.planItem().getId());
            if (total == null || total.compareTo(allocation.planItem().getQty()) != 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "锁定后的预建分摊合计与计划数量不一致");
            }
        }
    }
    private void validateAllocationIdentity(
            PlanAllocation allocation, LockedOrderItem orderItem) {
        ProductionPlanItem planItem = allocation.planItem();
        BigDecimal planUnitRate = normalizedPositiveRate(
                planItem.getUnitRate() == null ? BigDecimal.ONE : planItem.getUnitRate(),
                "生产计划明细");
        if (planItem.getGoodsId() == null || orderItem.goodsId() == null
                || planItem.getUnitId() == null || orderItem.unitId() == null
                || !Objects.equals(planItem.getGoodsId(), orderItem.goodsId())
                || !Objects.equals(planItem.getColorId(), orderItem.colorId())
                || !Objects.equals(planItem.getUnitId(), orderItem.unitId())
                || planUnitRate.compareTo(orderItem.unitRate()) != 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "生产计划明细与销售订单行的货品、颜色、单位或换算率不一致");
        }
    }

    /** 全部来源锁定并预校验通过后，才允许逐笔写回 planned_qty。 */
    private void applyAllocation(
            PlanAllocation allocation, LockedOrderItem orderItem, short chain) {
        if (orderItem == null) {
            throw new ApiException(ErrorCode.CONFLICT, "排产关联的销售订单行不存在");
        }
        em.createNativeQuery("""
                UPDATE sales_order_items
                SET planned_qty = COALESCE(planned_qty,0) + :a,
                    chain_status = CASE WHEN COALESCE(chain_status,0) IN (1,2) THEN :st
                                   ELSE chain_status END
                WHERE id = :id
                """).setParameter("a", allocation.allocatedQty()).setParameter("st", chain)
                .setParameter("id", allocation.orderItemId()).executeUpdate();
    }

    private static BigDecimal validatePlanItemForApproval(ProductionPlanItem item) {
        if (item.getGoodsId() == null || item.getUnitId() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "生产计划明细的货品和单位不能为空");
        }
        BigDecimal planQty = requirePositiveAllocation(item.getQty());
        normalizedPositiveRate(
                item.getUnitRate() == null ? BigDecimal.ONE : item.getUnitRate(),
                "生产计划明细");
        if (hasNonZero(item.getLqty(), item.getIqty(), item.getFqty(), item.getRqty(),
                item.getBqty(), item.getTqty(), item.getPaqty(), item.getIsrqty(),
                item.getCpqty(), item.getPoqty(), item.getPiqty())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "草稿计划存在报工、入库、领料或采购累计量，不可审核");
        }
        return planQty;
    }

    private static boolean hasNonZero(BigDecimal... values) {
        for (BigDecimal value : values) {
            if (value != null && value.signum() != 0) return true;
        }
        return false;
    }

    private static boolean hasNegative(BigDecimal... values) {
        for (BigDecimal value : values) {
            if (value != null && value.signum() < 0) return true;
        }
        return false;
    }
    private static BigDecimal requirePositiveAllocation(BigDecimal qty) {
        if (qty == null || qty.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "排产分摊数量必须大于 0");
        }
        return qty;
    }

    private static BigDecimal normalizedPositiveRate(BigDecimal rate, String source) {
        BigDecimal normalized = rate == null ? BigDecimal.ONE : rate.stripTrailingZeros();
        if (normalized.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, source + "的单位换算率必须大于 0");
        }
        return normalized;
    }

    private static String qtyText(BigDecimal qty) {
        return qty.stripTrailingZeros().toPlainString();
    }

    private enum MaterialDecision {
        READY, VERIFIED_SHORTAGE, UNVERIFIED
    }

    private record PlanAllocation(
            ProductionPlanItem planItem,
            UUID orderItemId,
            BigDecimal allocatedQty,
            PlanOrderItemLink prebuiltLink) {
    }

    private record LockedOrderItem(
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal unitRate,
            BigDecimal remainingQty) {
    }

    /**
     * “未核验”和“真实缺料”都会 fail closed 为待料，但只有逐行分配已生效且
     * 及时缺口为正时才返回 VERIFIED_SHORTAGE，避免把能力未就绪误报成采购缺料。
     */
    private MaterialDecision materialDecision(UUID planId) {
        if (!mrpService.isPlanningWriteReady()) return MaterialDecision.UNVERIFIED;
        List<MrpRow> rows = mrpService.preview(planId);
        if (rows.isEmpty() || rows.stream().anyMatch(row ->
                !row.allocationBacked()
                        || !row.planningWriteReady()
                        || row.timelyShortage() == null)) {
            return MaterialDecision.UNVERIFIED;
        }
        return rows.stream().anyMatch(row -> row.timelyShortage().signum() > 0)
                ? MaterialDecision.VERIFIED_SHORTAGE
                : MaterialDecision.READY;
    }

    /** 锁定全部有效计划行，并以行级累计量作为红冲的第一道门禁。 */
    private List<UUID> lockAndValidatePlanItemsForReverse(UUID planId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id, fqty, iqty
                        FROM production_plan_items
                        WHERE plan_id = :pid
                          AND COALESCE(is_deleted, false) = false
                        ORDER BY id
                        FOR UPDATE
                        """)
                .setParameter("pid", planId)
                .getResultList();
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, "已审核计划没有有效明细，不能红冲");
        }
        List<UUID> itemIds = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            itemIds.add((UUID) row[0]);
            if (bd(row[1]).signum() != 0 || bd(row[2]).signum() != 0) {
                throw new ApiException(ErrorCode.BUSINESS,
                        "计划已有报工或完工入库数量，不能红冲");
            }
        }
        return itemIds;
    }

    /**
     * 父计划不能越过仍有效的下游单据直接红冲。三类查询都锁定当前
     * 联动与单据行；生成端同样锁父计划头，因此不会在检查后插入新下游。
     */
    private void validateNoActiveDownstream(UUID planId) {
        List<?> stockDocuments = em.createNativeQuery("""
                        SELECT d.id, d.doc_type, d.bill_no
                        FROM plan_draw_links l
                        JOIN stock_documents d ON d.id = l.draw_id
                        WHERE l.plan_id = :pid
                          AND COALESCE(l.is_deleted, false) = false
                          AND COALESCE(d.is_deleted, false) = false
                          AND COALESCE(d.status, 0) <> -1
                          AND d.doc_type IN ('DRAW', 'FINISHED_IN')
                        ORDER BY d.id
                        FOR UPDATE OF l, d
                        """)
                .setParameter("pid", planId)
                .setMaxResults(1)
                .getResultList();
        if (!stockDocuments.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "计划存在有效的领料单或成品入库单，请先删除或红冲下游单据");
        }

        List<?> purchaseRequests = em.createNativeQuery("""
                        SELECT r.id, r.bill_no
                        FROM mrp_generations g
                        JOIN purchase_requests r ON r.id = g.request_id
                        WHERE g.plan_id = :pid
                          AND COALESCE(g.is_deleted, false) = false
                          AND COALESCE(r.is_deleted, false) = false
                          AND COALESCE(r.status, 0) <> -1
                        ORDER BY r.id
                        FOR UPDATE OF g, r
                        """)
                .setParameter("pid", planId)
                .setMaxResults(1)
                .getResultList();
        if (!purchaseRequests.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "计划存在有效的采购申请，请先删除或红冲下游单据");
        }

        List<?> subplans = em.createNativeQuery("""
                        SELECT sp.id, sp.bill_no
                        FROM subplan_links l
                        JOIN production_plans sp ON sp.id = l.subplan_id
                        WHERE l.plan_id = :pid
                          AND COALESCE(l.is_deleted, false) = false
                          AND COALESCE(sp.is_deleted, false) = false
                          AND COALESCE(sp.status, 0) <> -1
                        ORDER BY sp.id
                        FOR UPDATE OF l, sp
                        """)
                .setParameter("pid", planId)
                .setMaxResults(1)
                .getResultList();
        if (!subplans.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "计划存在有效的子计划，请先删除或红冲下游单据");
        }
    }

    /**
     * 全部红冲门禁通过后，精确软删 links 并按订单行聚合回退 planned_qty。
     * 不使用 GREATEST 掩盖历史错账；当前 planned_qty 小于待回退量时直接拒绝。
     */
    private void unlinkOrderItems(List<UUID> itemIds) {
        if (itemIds.isEmpty()) return;
        List<PlanOrderItemLink> discovered = new ArrayList<>(
                linkRepo.findActiveByPlanItemIds(itemIds));
        discovered.sort(java.util.Comparator.comparing(PlanOrderItemLink::getId));

        Map<UUID, UUID> discoveredOrderItemByLink = new HashMap<>();
        TreeSet<UUID> orderItemIds = new TreeSet<>();
        for (PlanOrderItemLink link : discovered) {
            if (link.getOrderItemId() == null) {
                throw new ApiException(ErrorCode.CONFLICT, "计划关联缺少销售订单行");
            }
            discoveredOrderItemByLink.put(link.getId(), link.getOrderItemId());
            orderItemIds.add(link.getOrderItemId());
        }

        // 与销售改量/取消保持 sales row → link 的统一锁序。
        Map<UUID, BigDecimal> lockedPlannedQty = lockOrderItemsForUnlink(orderItemIds);
        List<PlanOrderItemLink> links = new ArrayList<>(discovered.size());
        Map<UUID, BigDecimal> releaseByOrderItem = new java.util.TreeMap<>();
        for (PlanOrderItemLink link : discovered) {
            em.lock(link, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
            em.refresh(link);
            UUID discoveredOrderItemId = discoveredOrderItemByLink.get(link.getId());
            if (link.isDeleted()
                    || !Objects.equals(discoveredOrderItemId, link.getOrderItemId())) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "计划销售分摊已被删除或改绑，请刷新后重试");
            }
            BigDecimal allocated = requirePositiveAllocation(link.getAllocatedQty());
            if (hasNonZero(link.getInboundQty(), link.getProducedQty(), link.getCappedQty())) {
                throw new ApiException(ErrorCode.BUSINESS,
                        "计划关联已有报工、入库或封顶累计，不能红冲");
            }
            links.add(link);
            releaseByOrderItem.merge(link.getOrderItemId(), allocated, BigDecimal::add);
        }

        for (Map.Entry<UUID, BigDecimal> entry : releaseByOrderItem.entrySet()) {
            BigDecimal plannedQty = lockedPlannedQty.get(entry.getKey());
            if (plannedQty == null || plannedQty.signum() < 0
                    || plannedQty.compareTo(entry.getValue()) < 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "销售订单行已排产量小于计划待回退量，请先核对联动数据");
            }
        }

        OffsetDateTime now = OffsetDateTime.now();
        for (PlanOrderItemLink link : links) {
            link.setDeleted(true);
            link.setDeletedAt(now);
            linkRepo.save(link);
        }
        for (Map.Entry<UUID, BigDecimal> entry : releaseByOrderItem.entrySet()) {
            int updated = em.createNativeQuery("""
                            UPDATE sales_order_items
                            SET planned_qty = COALESCE(planned_qty,0) - :a,
                                chain_status = CASE WHEN COALESCE(chain_status,0) IN (3,4) THEN
                                    CASE WHEN COALESCE(reserved_qty,0) >= COALESCE(qty,0) - COALESCE(shipped_qty,0)
                                         + COALESCE(returned_qty,0) - COALESCE(flag_qty,0)
                                         THEN 7 ELSE 2 END
                                ELSE chain_status END
                            WHERE id = :id
                            """)
                    .setParameter("a", entry.getValue())
                    .setParameter("id", entry.getKey())
                    .executeUpdate();
            if (updated != 1) {
                throw new ApiException(ErrorCode.CONFLICT, "销售订单行回退失败");
            }
        }
    }
    private Map<UUID, BigDecimal> lockOrderItemsForUnlink(
            java.util.Collection<UUID> requestedIds) {
        TreeSet<UUID> ids = new TreeSet<>(requestedIds);
        if (ids.isEmpty()) return Map.of();
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id, planned_qty
                        FROM sales_order_items
                        WHERE id IN (:ids)
                        ORDER BY id
                        FOR UPDATE
                        """)
                .setParameter("ids", ids)
                .getResultList();
        if (rows.size() != ids.size()) {
            throw new ApiException(ErrorCode.CONFLICT, "计划关联的销售订单行不存在");
        }
        Map<UUID, BigDecimal> plannedQty = new HashMap<>();
        for (Object[] row : rows) {
            plannedQty.put((UUID) row[0], bd(row[1]));
        }
        return plannedQty;
    }

    private static BigDecimal bd(Object v) {
        return v == null ? BigDecimal.ZERO : (BigDecimal) v;
    }

    /**
     * 红冲（status 1→-1）。
     *
     * <p>红冲前锁定并校验计划行与销售来源，且要求领料/成品入库、采购申请、
     * 子计划等下游单据已先删除或红冲；通过后才精确回退订单 planned_qty。
     */
    @Transactional
    public PlanDetail reverse(UUID id) {
        tx.bind();
        ProductionPlan p = requirePlanForUpdate(id);
        access.requireWritable(p.getMakerId(), "只能操作本人负责的生产计划");
        rejectDirectLifecycleOfExecutionV1Subplan(id, "红冲");
        if (p.getStatus() == null || p.getStatus() != STATUS_APPROVED)
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        List<UUID> itemIds = lockAndValidatePlanItemsForReverse(id);
        validateNoActiveDownstream(id);
        unlinkOrderItems(itemIds); // 全部门禁通过后再软删 links + 精确回退 planned_qty
        p.setStatus(STATUS_REVERSED);
        planRepo.save(p);
        return detail(id);
    }

    /**
     * V1 自制件子计划属于父计划包的原子生命周期，不能从通用计划入口单独删除或红冲。
     * 父计划包服务会按父包→子计划的稳定锁序校验并关闭子计划、关联与物料需求；
     * 在这里直接改终态会留下仍为 CONFIRMED 的父包和失去供给来源的父需求。
     */
    private void rejectDirectLifecycleOfExecutionV1Subplan(
            UUID planId, String action) {
        List<?> links = em.createNativeQuery("""
                        SELECT link.id
                        FROM subplan_links link
                        WHERE link.subplan_id = :planId
                          AND link.is_deleted = FALSE
                          AND link.source = 'EXECUTION_V1'
                        ORDER BY link.id
                        FOR UPDATE OF link
                        """)
                .setParameter("planId", planId)
                .setMaxResults(1)
                .getResultList();
        if (!links.isEmpty()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "执行 V1 派生的自制件子计划不能单独" + action
                            + "，请从父计划的计划包执行取消或红冲");
        }
    }

    // ====================== 生产进度看板聚合 ======================

    /** 看板排序白名单：前端 sort → ORDER BY 片段（置顶恒最前，统一前置 p.is_pinned DESC）。 */
    private static final Map<String, String> PROGRESS_SORT = Map.of(
            "billDate", "p.bill_date ASC NULLS LAST, p.bill_no",
            "billDateDesc", "p.bill_date DESC NULLS LAST, p.bill_no",
            "deliveryDate", "p.delivery_date ASC NULLS LAST, p.bill_no",
            "progress", "CASE WHEN COALESCE(SUM(i.qty),0) > 0 "
                    + "THEN COALESCE(SUM(i.iqty),0) / SUM(i.qty) ELSE 0 END DESC, "
                    + "p.bill_date ASC NULLS LAST, p.bill_no");

    /**
     * 进度看板共用过滤片段。完成态必须读取主表 {@code is_closed}，因为数据库
     * 会在成品数量已完成但材料尚未退库/结清时强制保持 false；若继续只按
     * {@code qty-iqty} 实时聚合，会把材料未平账的任务错误展示为已完成。
     * 可选条件按参数非空拼入，值全部走绑定参数。
     */
    private static String progressFilters(String kw, String ws,
                                          java.time.LocalDate dateFrom, java.time.LocalDate dateTo,
                                          String ownerPredicate) {
        return """
                FROM production_plans p
                LEFT JOIN production_plan_items i ON i.plan_id = p.id AND i.is_deleted = false
                WHERE p.is_deleted = false AND p.status = 1
                  AND p.is_stopped = false AND p.is_canceled = false
                  AND p.id NOT IN (SELECT subplan_id FROM subplan_links WHERE is_deleted = false)
                  AND p.is_closed = :closed
                """
                + "  AND " + ownerPredicate + "\n"
                + (kw.isEmpty() ? ""
                        : "  AND (LOWER(p.bill_no) LIKE :kw OR LOWER(COALESCE(p.workshop_name,'')) LIKE :kw)\n")
                + (ws.isEmpty() ? "" : "  AND p.workshop_name = :ws\n")
                + (dateFrom == null ? "" : "  AND p.bill_date >= :dateFrom\n")
                + (dateTo == null ? "" : "  AND p.bill_date <= :dateTo\n")
                + """
                GROUP BY p.id, p.bill_no, p.bill_date, p.delivery_date, p.workshop_name, p.department_id,
                         p.is_pinned, p.is_important
                """;
    }

    /** 绑定 progressFilters 出现过的参数（未出现的条件不绑，避免未用参数报错）。 */
    private static void bindProgressFilters(jakarta.persistence.Query q, boolean closed, String kw,
                                            String ws, java.time.LocalDate dateFrom,
                                            java.time.LocalDate dateTo) {
        q.setParameter("closed", closed);
        if (!kw.isEmpty()) q.setParameter("kw", "%" + kw + "%");
        if (!ws.isEmpty()) q.setParameter("ws", ws);
        if (dateFrom != null) q.setParameter("dateFrom", dateFrom);
        if (dateTo != null) q.setParameter("dateTo", dateTo);
    }

    /**
     * 计划聚合进度（看板：进行中 closed=false / 已完成 closed=true，<b>服务端分页</b>）。
     * 顶层只列父计划（排除作为子计划的单），每个计划分别返回报工、成品入库进度，
     * 并带 subplans 嵌套进度与今日成品入库量；
     * 排序：置顶恒最前 + 白名单 sort（默认 billDate 开单远→近）；keyword 模糊单号/车间、
     * workshop 精确、dateFrom/dateTo 开单日期范围。页码越界自动回退到最后一页。
     */
    @Transactional(readOnly = true)
    public PageResponse<com.uten.imp.features.production.plan.dto.PlanProgressRow> progress(
            boolean closed, String sort, int page, int size,
            String keyword, String workshop, java.time.LocalDate dateFrom, java.time.LocalDate dateTo) {
        int p = Math.max(1, page);
        int sz = Math.min(Math.max(1, size), 100);
        String kw = keyword == null ? "" : keyword.trim().toLowerCase();
        String ws = workshop == null ? "" : workshop.trim();
        var ownerScope = access.nativeReadScope("p.maker_id", "progressOwners");
        String filters = progressFilters(kw, ws, dateFrom, dateTo, ownerScope.predicate());

        // 总数（跨全部页）
        var countQ = em.createNativeQuery("SELECT COUNT(*) FROM (SELECT p.id " + filters + ") t");
        bindProgressFilters(countQ, closed, kw, ws, dateFrom, dateTo);
        ownerScope.bind(countQ);
        long total = ((Number) countQ.getSingleResult()).longValue();
        int totalPages = total == 0 ? 0 : (int) ((total + sz - 1) / sz);
        if (totalPages > 0 && p > totalPages) p = totalPages; // 页码越界回退（过滤后总数变少）

        // 当前页数据
        String orderBy = PROGRESS_SORT.getOrDefault(
                sort == null ? "" : sort,
                PROGRESS_SORT.get("billDate"));
        var dataQ = em.createNativeQuery("""
                SELECT p.id, p.bill_no, p.bill_date, p.delivery_date, p.workshop_name, p.department_id,
                       COUNT(i.id), COALESCE(SUM(i.qty),0), COALESCE(SUM(i.fqty),0),
                       COALESCE(SUM(i.iqty),0),
                       MIN(i.plan_begin_date), MAX(i.plan_end_date),
                       p.is_pinned, p.is_important
                """ + filters + " ORDER BY p.is_pinned DESC, " + orderBy + " LIMIT :lim OFFSET :off");
        bindProgressFilters(dataQ, closed, kw, ws, dateFrom, dateTo);
        ownerScope.bind(dataQ);
        @SuppressWarnings("unchecked")
        List<Object[]> rs = (List<Object[]>) dataQ
                .setParameter("lim", sz).setParameter("off", (p - 1) * sz)
                .getResultList();

        // 子计划嵌套进度（按父计划批量取，避免 N+1）
        List<UUID> planIds = rs.stream().map(r -> (UUID) r[0]).toList();
        List<Object[]> subRows = List.of();
        if (!planIds.isEmpty()) {
            @SuppressWarnings("unchecked")
            List<Object[]> loadedSubRows = em.createNativeQuery("""
                    SELECT l.plan_id, sp.id, sp.bill_no, sp.workshop_name, sp.status, sp.is_closed,
                           COALESCE(SUM(i.qty),0), COALESCE(SUM(i.fqty),0),
                           COALESCE(SUM(i.iqty),0)
                    FROM subplan_links l
                    JOIN production_plans sp ON sp.id = l.subplan_id AND sp.is_deleted = false
                    LEFT JOIN production_plan_items i ON i.plan_id = sp.id AND i.is_deleted = false
                    WHERE l.is_deleted = false AND l.plan_id IN (:ids)
                    GROUP BY l.plan_id, sp.id, sp.bill_no, sp.workshop_name, sp.status, sp.is_closed
                    ORDER BY sp.bill_no
                    """).setParameter("ids", planIds).getResultList();
            subRows = loadedSubRows;
        }

        // 正式齐套只读取 CONFIRMED 计划包的执行分段投影，不能拿库存余额或未来供给承诺猜。
        // 父计划和子计划一次批量读取；各自独立计算，避免子计划就绪污染父计划状态。
        TreeSet<UUID> materialPlanIds = new TreeSet<>(planIds);
        for (Object[] s : subRows) {
            materialPlanIds.add((UUID) s[1]);
        }
        Map<UUID, MaterialProgress> materialByPlan = loadMaterialProgress(materialPlanIds);

        Map<UUID, List<com.uten.imp.features.production.plan.dto.PlanProgressRow.SubProgress>> subsByPlan =
                new java.util.HashMap<>();
        for (Object[] s : subRows) {
            BigDecimal t = bd(s[6]);
            BigDecimal reported = bd(s[7]);
            BigDecimal in = bd(s[8]);
            double pct = t.signum() > 0
                    ? Math.min(in.divide(t, 4, java.math.RoundingMode.HALF_UP).doubleValue(), 1.0) : 0;
            MaterialProgress material = materialByPlan.getOrDefault(
                    (UUID) s[1], MaterialProgress.notPlanned());
            subsByPlan.computeIfAbsent((UUID) s[0], k -> new ArrayList<>())
                    .add(new com.uten.imp.features.production.plan.dto.PlanProgressRow.SubProgress(
                            (UUID) s[1], (String) s[2], (String) s[3],
                            s[4] == null ? null : ((Number) s[4]).shortValue(),
                            Boolean.TRUE.equals(s[5]), t, reported, in,
                            material.state(), material.segmentCount(), material.readySegmentCount(),
                            material.totalQty(), material.readyQty(), material.percent(),
                            material.canStartNow(), pct));
        }
        // 今日成品入库量（按父计划批量取）：当日已审 FINISHED_IN 经 plan_draw_links 溯源，
        // Σ(数量 × 换算率) 基本单位，与 iqty 口径一致（卡片「今日 +N」标注）。
        Map<UUID, BigDecimal> todayByPlan = new java.util.HashMap<>();
        if (!planIds.isEmpty()) {
            @SuppressWarnings("unchecked")
            List<Object[]> tq = em.createNativeQuery("""
                    SELECT l.plan_id, COALESCE(SUM(i.qty * COALESCE(i.unit_rate,1)),0)
                    FROM plan_draw_links l
                    JOIN stock_documents d ON d.id = l.draw_id AND d.is_deleted = false
                         AND d.status = 1 AND d.doc_type = 'FINISHED_IN'
                         AND d.bill_date = CAST(:today AS date)
                    JOIN stock_document_items i ON i.doc_id = d.id AND i.is_deleted = false
                    WHERE l.is_deleted = false AND l.plan_id IN (:ids)
                    GROUP BY l.plan_id
                    """)
                    .setParameter("ids", planIds)
                    .setParameter("today", BusinessTime.today())
                    .getResultList();
            for (Object[] t : tq) {
                todayByPlan.put((UUID) t[0], bd(t[1]));
            }
        }
        java.time.LocalDate today = BusinessTime.today();
        java.time.LocalDate warn = today.plusDays(3);
        List<com.uten.imp.features.production.plan.dto.PlanProgressRow> out = new ArrayList<>(rs.size());
        for (Object[] r : rs) {
            BigDecimal totalQty = bd(r[7]);
            BigDecimal reported = bd(r[8]);
            BigDecimal inbound = bd(r[9]);
            double pct = totalQty.signum() > 0
                    ? inbound.divide(totalQty, 4, java.math.RoundingMode.HALF_UP).doubleValue() : 0;
            java.time.LocalDate deliver = r[3] == null ? null : NativeValueConverters.toLocalDate(r[3]);
            MaterialProgress material = materialByPlan.getOrDefault(
                    (UUID) r[0], MaterialProgress.notPlanned());
            out.add(new com.uten.imp.features.production.plan.dto.PlanProgressRow(
                    (UUID) r[0], (String) r[1],
                    r[2] == null ? null : NativeValueConverters.toLocalDate(r[2]),
                    deliver, (String) r[4], (UUID) r[5],
                    ((Number) r[6]).intValue(), totalQty, reported, inbound,
                    material.state(), material.segmentCount(), material.readySegmentCount(),
                    material.totalQty(), material.readyQty(), material.percent(),
                    material.canStartNow(),
                    r[10] == null ? null : NativeValueConverters.toLocalDate(r[10]),
                    r[11] == null ? null : NativeValueConverters.toLocalDate(r[11]),
                    Math.min(pct, 1.0), closed,
                    deliver != null && !deliver.isAfter(warn),
                    deliver != null && deliver.isBefore(today),
                    Boolean.TRUE.equals(r[12]),
                    Boolean.TRUE.equals(r[13]),
                    todayByPlan.getOrDefault((UUID) r[0], BigDecimal.ZERO),
                    subsByPlan.getOrDefault((UUID) r[0], List.of())));
        }
        return new PageResponse<>(out, p, sz, total, totalPages);
    }

    /**
     * 批量读取正式执行分段的物料齐套事实。
     *
     * <p>{@code material_ready} 已包含 DEMANDED 精确预留+领料门禁和 ZERO_MATERIAL 真值；
     * 已完成分段视为历史上通过齐套门，避免结算释放预留后进度倒退。没有正式包、V0 旧包和
     * V1 数据异常都返回独立状态且百分比为 null，不伪装成“0% 缺料”。
     */
    private Map<UUID, MaterialProgress> loadMaterialProgress(java.util.Collection<UUID> planIds) {
        if (planIds.isEmpty()) return Map.of();
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT plan.id,
                       package.id,
                       package.execution_model_version,
                       COUNT(segment.id) FILTER (
                           WHERE segment.status NOT IN ('CANCELLED', 'REVERSED')
                       ),
                       COUNT(segment.id) FILTER (
                           WHERE segment.status NOT IN ('CANCELLED', 'REVERSED')
                             AND (segment.material_ready OR segment.status = 'COMPLETED')
                       ),
                       COALESCE(SUM(segment.planned_qty) FILTER (
                           WHERE segment.status NOT IN ('CANCELLED', 'REVERSED')
                       ), 0),
                       COALESCE(SUM(segment.planned_qty) FILTER (
                           WHERE segment.status NOT IN ('CANCELLED', 'REVERSED')
                             AND (segment.material_ready OR segment.status = 'COMPLETED')
                       ), 0),
                       COALESCE(BOOL_OR(
                           segment.status = 'READY' AND segment.material_ready
                       ), FALSE)
                FROM production_plans plan
                LEFT JOIN production_planning_packages package
                  ON package.plan_id = plan.id
                 AND package.status = 'CONFIRMED'
                 AND package.is_deleted = FALSE
                LEFT JOIN v_production_execution_segments segment
                  ON segment.package_id = package.id
                 AND segment.plan_id = plan.id
                WHERE plan.id IN (:ids)
                GROUP BY plan.id, package.id, package.execution_model_version
                """).setParameter("ids", planIds).getResultList();
        Map<UUID, MaterialProgress> out = new HashMap<>();
        for (Object[] row : rows) {
            UUID packageId = (UUID) row[1];
            Integer modelVersion = row[2] == null ? null : ((Number) row[2]).intValue();
            out.put((UUID) row[0], deriveMaterialProgress(
                    packageId != null,
                    modelVersion,
                    ((Number) row[3]).intValue(),
                    ((Number) row[4]).intValue(),
                    bd(row[5]),
                    bd(row[6]),
                    Boolean.TRUE.equals(row[7])));
        }
        return out;
    }

    static MaterialProgress deriveMaterialProgress(
            boolean hasConfirmedPackage,
            Integer modelVersion,
            int segmentCount,
            int readySegmentCount,
            BigDecimal totalQty,
            BigDecimal readyQty,
            boolean canStartNow) {
        BigDecimal total = zeroIfNull(totalQty);
        BigDecimal ready = zeroIfNull(readyQty);
        if (!hasConfirmedPackage) return MaterialProgress.notPlanned();
        if (!Objects.equals(modelVersion, 1)) {
            return new MaterialProgress(
                    "LEGACY_UNSUPPORTED", segmentCount, readySegmentCount,
                    total, ready, null, false);
        }
        if (segmentCount <= 0 || total.signum() <= 0) {
            return new MaterialProgress(
                    "DATA_ERROR", segmentCount, readySegmentCount,
                    total, ready, null, false);
        }
        double percent = Math.min(
                ready.divide(total, 4, java.math.RoundingMode.HALF_UP).doubleValue(), 1.0);
        String state = ready.signum() <= 0
                ? "WAITING"
                : ready.compareTo(total) >= 0 ? "READY" : "PARTIAL";
        return new MaterialProgress(
                state, segmentCount, readySegmentCount, total, ready, percent, canStartNow);
    }

    static record MaterialProgress(
            String state,
            int segmentCount,
            int readySegmentCount,
            BigDecimal totalQty,
            BigDecimal readyQty,
            Double percent,
            boolean canStartNow) {
        static MaterialProgress notPlanned() {
            return new MaterialProgress(
                    "NOT_PLANNED", 0, 0,
                    BigDecimal.ZERO, BigDecimal.ZERO, null, false);
        }
    }

    /** 进度看板汇总（同过滤条件、跨全部页）：计划数 / Σ排产 / Σ已入库（顶部总览条）。 */
    @Transactional(readOnly = true)
    public Map<String, Object> progressSummary(boolean closed, String keyword, String workshop,
                                               java.time.LocalDate dateFrom, java.time.LocalDate dateTo) {
        String kw = keyword == null ? "" : keyword.trim().toLowerCase();
        String ws = workshop == null ? "" : workshop.trim();
        var ownerScope = access.nativeReadScope("p.maker_id", "progressOwners");
        String filters = progressFilters(kw, ws, dateFrom, dateTo, ownerScope.predicate());
        var q = em.createNativeQuery("""
                SELECT COUNT(*), COALESCE(SUM(s.sq),0), COALESCE(SUM(s.sf),0),
                       COALESCE(SUM(s.si),0)
                FROM (SELECT COALESCE(SUM(i.qty),0) AS sq,
                             COALESCE(SUM(i.fqty),0) AS sf,
                             COALESCE(SUM(i.iqty),0) AS si
                """ + filters + ") s");
        bindProgressFilters(q, closed, kw, ws, dateFrom, dateTo);
        ownerScope.bind(q);
        Object[] r = (Object[]) q.getSingleResult();
        Map<String, Object> out = new java.util.LinkedHashMap<>();
        out.put("count", ((Number) r[0]).longValue());
        out.put("sumQty", bd(r[1]));
        out.put("sumReported", bd(r[2]));
        out.put("sumInbound", bd(r[3]));
        return out;
    }

    /** 进度看板车间筛选选项（同进行中/已完成口径的去重车间名，不受当前筛选影响）。 */
    @Transactional(readOnly = true)
    public List<Map<String, String>> progressWorkshops(boolean closed) {
        var ownerScope = access.nativeReadScope("p.maker_id", "progressOwners");
        String filters = progressFilters("", "", null, null, ownerScope.predicate());
        var q = em.createNativeQuery(
                "SELECT DISTINCT s.ws FROM (SELECT p.workshop_name AS ws " + filters
                        + ") s WHERE s.ws IS NOT NULL AND s.ws <> '' ORDER BY s.ws");
        bindProgressFilters(q, closed, "", "", null, null);
        ownerScope.bind(q);
        @SuppressWarnings("unchecked")
        List<String> names = (List<String>) q.getResultList();
        return names.stream().map(n -> Map.of("name", n)).toList();
    }

    /** 看板标记：置顶 / 重要，null 字段保持不变。 */
    @Transactional
    public void updateFlags(UUID id, com.uten.imp.features.production.plan.dto.PlanFlagsRequest req) {
        tx.bind();
        ProductionPlan p = requirePlan(id);
        access.requireWritable(p.getMakerId(), "只能操作本人负责的生产计划");
        if (req.pinned() != null) p.setPinned(req.pinned());
        if (req.important() != null) p.setImportant(req.important());
        planRepo.save(p);
    }

    // ====================== is_closed 派生（CheckFulfill4 → Service） ======================

    /**
     * 重算主表 is_closed（CheckFulfill4 派生）：所有非软删明细 {@code qty - iqty ≤ 0} 时为 true。
     *
     * <p>同采购 {@code recalcRequestClosed} 范式（design §4.2 行）。
     */
    private void recomputeClosed(UUID planId) {
        em.createNativeQuery("""
                UPDATE production_plans p SET is_closed = (
                    SELECT COALESCE(bool_and(COALESCE(i.qty,0) - COALESCE(i.iqty,0) <= 0), true)
                    FROM production_plan_items i
                    WHERE i.plan_id = p.id AND COALESCE(i.is_deleted, false) = false
                ) WHERE p.id = :pid
                """).setParameter("pid", planId).executeUpdate();
    }

    // ====================== 私有辅助 ======================

    private void applyHeader(PlanSaveRequest req, ProductionPlan p) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (p.getBillNo() == null || p.getBillNo().isBlank()) {
            p.setBillNo(docNumberService.nextNumber(DocNumberPrefix.PRODUCTION_PLAN));
        }
        p.setBillDate(req.getBillDate());
        p.setFStyle(req.getFStyle());
        p.setDeliveryDate(req.getDeliveryDate());
        p.setDepartmentId(req.getDepartmentId());
        p.setWorkshopName(req.getWorkshopName());
        p.setWorkerName(req.getWorkerName());
        p.setSellerName(req.getSellerName());
        p.setSellerId(req.getSellerId());
        p.setWorkerId(req.getWorkerId());
        p.setRemark(req.getRemark());
        p.setSourceDocNo(req.getSourceDocNo());
    }

    private List<PlanItemDto> saveItems(ProductionPlan p, List<PlanItemLine> lines) {
        List<PlanItemDto> out = new ArrayList<>(lines.size());
        Set<String> usedProductNos = collectExplicitProductNos(lines);
        int auto = 1;
        for (PlanItemLine l : lines) {
            int lineNo = l.getLineNo() != null ? l.getLineNo() : auto;
            String explicitProductNo = trimmedToNull(l.getProductNo());
            String productNo = explicitProductNo != null
                    ? explicitProductNo
                    : productNoAllocator.allocate(
                            p.getId(), Set.copyOf(usedProductNos));
            usedProductNos.add(ProductionProductNoAllocator.normalize(productNo));
            ProductionPlanItem it = new ProductionPlanItem();
            it.setPlanId(p.getId());
            it.setBillNo(p.getBillNo());
            it.setBillDate(p.getBillDate());
            it.setLineNo(lineNo);
            it.setProductNo(productNo);
            it.setGoodsId(l.getGoodsId());
            it.setColorId(l.getColorId());
            it.setMgoodsId(l.getMgoodsId());
            it.setUnitId(l.getUnitId());
            it.setUnitRate(l.getUnitRate());
            it.setSalesOrderItemId(l.getSalesOrderItemId());
            it.setSalesOrderNo(l.getSalesOrderNo());
            it.setClientName(l.getClientName());
            it.setClientNo(l.getClientNo());
            it.setOqty(zeroIfNull(l.getOqty()));
            it.setQty(zeroIfNull(l.getQty()));
            it.setLqty(zeroIfNull(l.getLqty()));
            it.setIqty(zeroIfNull(l.getIqty()));
            it.setFqty(zeroIfNull(l.getFqty()));
            it.setRqty(zeroIfNull(l.getRqty()));
            it.setBqty(zeroIfNull(l.getBqty()));
            it.setTqty(zeroIfNull(l.getTqty()));
            it.setPaqty(zeroIfNull(l.getPaqty()));
            it.setIsrqty(zeroIfNull(l.getIsrqty()));
            it.setCpqty(zeroIfNull(l.getCpqty()));
            it.setPoqty(zeroIfNull(l.getPoqty()));
            it.setPiqty(zeroIfNull(l.getPiqty()));
            it.setOrderDate(l.getOrderDate());
            it.setOutboundDate(l.getOutboundDate());
            it.setPlanBeginDate(l.getPlanBeginDate());
            it.setPlanEndDate(l.getPlanEndDate());
            it.setFinishedWeight(l.getFinishedWeight());
            it.setInboundWeight(l.getInboundWeight());
            it.setLstatus(l.getLstatus());
            it.setCstatus(l.getCstatus());
            it.setStepLegacyId(l.getStepLegacyId());
            it.setVeilLegacyId(l.getVeilLegacyId());
            it.setAssTeamLegacyId(l.getAssTeamLegacyId());
            it.setFittings(l.getFittings());
            it.setRequestNote(l.getRequestNote());
            it.setCustomerModel(l.getCustomerModel());
            it.setDiscount(l.getDiscount());
            it.setLabelNo(l.getLabelNo());
            it.setPlanAppNo(l.getPlanAppNo());
            it.setSourceDocNo(l.getSourceDocNo());
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            out.add(toItemDto(it));
            auto++;
        }
        return out;
    }

    private static Set<String> collectExplicitProductNos(List<PlanItemLine> lines) {
        Set<String> normalized = new HashSet<>();
        for (PlanItemLine line : lines) {
            String value = ProductionProductNoAllocator.normalize(line.getProductNo());
            if (value != null && !normalized.add(value)) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "生产计划明细的产品编号不能重复（忽略大小写和首尾空格）");
            }
        }
        return normalized;
    }

    private static String trimmedToNull(String value) {
        if (value == null) return null;
        String trimmed = value.trim();
        return trimmed.isEmpty() ? null : trimmed;
    }

    private PlanListItem toList(ProductionPlan p) {
        return new PlanListItem(p.getId(), p.getBillNo(), p.getBillDate(), p.getDeliveryDate(),
                p.getDepartmentId(), p.getWorkshopName(), p.getWorkerName(), p.getSellerName(),
                p.getSellerId(), p.getWorkerId(),
                p.getStatus(), p.isClosed(), p.isStopped(), p.isCanceled(), p.getLegacyId());
    }

    private PlanItemDto toItemDto(ProductionPlanItem it) {
        return new PlanItemDto(it.getId(), it.getLineNo(), it.getProductNo(), it.getGoodsId(), it.getColorId(),
                it.getMgoodsId(), it.getUnitId(), it.getUnitRate(), it.getSalesOrderItemId(), it.getSalesOrderNo(),
                it.getClientName(), it.getClientNo(),
                it.getOqty(), it.getQty(), it.getLqty(), it.getIqty(), it.getFqty(), it.getRqty(),
                it.getBqty(), it.getTqty(), it.getPaqty(), it.getIsrqty(), it.getCpqty(), it.getPoqty(), it.getPiqty(),
                it.getOrderDate(), it.getOutboundDate(), it.getPlanBeginDate(), it.getPlanEndDate(),
                it.getFinishedWeight(), it.getInboundWeight(),
                it.getLstatus(), it.getCstatus(), it.getStepLegacyId(),
                it.getVeilLegacyId(), it.getAssTeamLegacyId(), it.getFittings(),
                it.getRequestNote(), it.getCustomerModel(), it.getDiscount(), it.getLabelNo(), it.getPlanAppNo(),
                it.getSourceDocNo(), it.getRemark());
    }

    private PlanDetail toDetail(ProductionPlan p, List<PlanItemDto> items) {
        return new PlanDetail(p.getId(), p.getLegacyId(), p.getBillNo(), p.getBillDate(), p.getFStyle(),
                p.getDeliveryDate(), p.getDepartmentId(), p.getWorkshopName(), p.getWorkerName(), p.getSellerName(),
                p.getSellerId(), p.getWorkerId(),
                p.getMakerId(), p.getApproverId(), p.getMakerLegacyId(), p.getApproverLegacyId(), p.getRemark(),
                p.getStatus(), p.isClosed(), p.isStopped(), p.isCanceled(), p.getSourceDocNo(),
                p.getSourceDailyReportId(),
                p.getMaterialAnalysisId(), p.getMaterialAnalysisItemId(),
                planDetailAllowedActions(p), items,
                nameResolver.nameOf(p.getMakerId()), p.getCreatedAt(),
                traceSalesOrders(p.getId()), traceMaterialDraws(p.getId()),
                tracePurchaseRequests(p.getId()), traceSubcontractApplications(p.getId()),
                traceDailyReports(p.getId()));
    }

    // ===== 计划详情的部分溯源投影：销售订单 / 库存单据 / 采购申请 =====

    /** 来源销售订单：plan_order_item_links → 订单行 → 订单（跨模块逻辑 FK，坏数据跳过不炸）。
     *  附带客户名/业务员名，计划端不用跳转即可识别订单归属。 */
    private List<PlanTraceLink> traceSalesOrders(UUID planId) {
        List<Object[]> rows = com.uten.imp.common.util.NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT source.id, source.bill_no, source.client_name, source.seller_name
                        FROM (
                            SELECT so.id, so.bill_no, c.name AS client_name, e.full_name AS seller_name
                            FROM plan_order_item_links l
                            JOIN production_plan_items pi
                              ON pi.id = l.plan_item_id
                             AND pi.is_deleted = FALSE
                            JOIN sales_order_items soi
                              ON soi.id = l.order_item_id
                             AND soi.is_deleted = FALSE
                            JOIN sales_orders so
                              ON so.id = soi.order_id
                             AND so.is_deleted = FALSE
                            LEFT JOIN clients c ON c.id = so.client_id
                            LEFT JOIN employees e ON e.id = so.seller_id
                            WHERE pi.plan_id = :planId
                              AND l.is_deleted = FALSE
                            UNION
                            SELECT so.id, so.bill_no, c.name AS client_name, e.full_name AS seller_name
                            FROM production_plans plan
                            JOIN production_material_analysis_items analysis_item
                              ON analysis_item.id = plan.material_analysis_item_id
                             AND analysis_item.analysis_id = plan.material_analysis_id
                             AND analysis_item.is_deleted = FALSE
                            JOIN sales_order_items soi
                              ON soi.id = analysis_item.sales_order_item_id
                             AND soi.is_deleted = FALSE
                            JOIN sales_orders so
                              ON so.id = soi.order_id
                             AND so.is_deleted = FALSE
                            LEFT JOIN clients c ON c.id = so.client_id
                            LEFT JOIN employees e ON e.id = so.seller_id
                            WHERE plan.id = :planId
                              AND plan.is_deleted = FALSE
                        ) source
                        ORDER BY source.bill_no
                        """).setParameter("planId", planId));
        return rows.stream()
                .map(r -> new PlanTraceLink((UUID) r[0], (String) r[1], "SALES_ORDER",
                        (String) r[2], (String) r[3]))
                .toList();
    }

    /** 已审核生产报工单：报工明细行 → 本计划行（status=1 已审核才计入权威溯源）。 */
    private List<PlanTraceLink> traceDailyReports(UUID planId) {
        List<Object[]> rows = com.uten.imp.common.util.NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT DISTINCT pd.id, pd.bill_no
                        FROM production_daily_report_items pdri
                        JOIN production_plan_items pi
                          ON pi.id = pdri.plan_item_id
                         AND pi.is_deleted = FALSE
                        JOIN production_daily_reports pd
                          ON pd.id = pdri.report_id
                         AND pd.is_deleted = FALSE
                         AND pd.status = 1
                        WHERE pi.plan_id = :planId
                          AND pdri.is_deleted = FALSE
                        ORDER BY pd.bill_no, pd.id
                        """).setParameter("planId", planId));
        return rows.stream()
                .map(r -> new PlanTraceLink((UUID) r[0], (String) r[1], "DAILY_REPORT", null, null))
                .toList();
    }

    /** 本计划关联的领料与成品入库投影；由 doc_type 决定节点类型。 */
    private List<PlanTraceLink> traceMaterialDraws(UUID planId) {
        List<Object[]> rows = com.uten.imp.common.util.NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT sd.id, sd.bill_no, sd.doc_type
                        FROM plan_draw_links l
                        JOIN stock_documents sd ON sd.id = l.draw_id AND sd.is_deleted = FALSE
                        WHERE l.plan_id = :planId AND l.is_deleted = FALSE
                          AND sd.doc_type IN ('DRAW', 'FINISHED_IN')
                        ORDER BY sd.doc_type, sd.bill_no, sd.id
                        """).setParameter("planId", planId));
        return rows.stream()
                .map(r -> new PlanTraceLink(
                        (UUID) r[0], (String) r[1], stockTraceKind((String) r[2]), null, null))
                .toList();
    }

    static String stockTraceKind(String documentType) {
        return switch (documentType) {
            case "DRAW" -> "STOCK_DRAW";
            case "FINISHED_IN" -> "FINISHED_IN";
            default -> "STOCK_DOCUMENT";
        };
    }

    /** 旧 MRP 或本计划所属分析产品的逐路径 action 生成的采购申请。 */
    private List<PlanTraceLink> tracePurchaseRequests(UUID planId) {
        List<Object[]> rows = com.uten.imp.common.util.NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT source.id, source.bill_no
                        FROM (
                            SELECT pr.id, pr.bill_no
                            FROM mrp_generations generation
                            JOIN purchase_requests pr
                              ON pr.id = generation.request_id
                             AND pr.is_deleted = FALSE
                            WHERE generation.plan_id = :planId
                              AND generation.is_deleted = FALSE
                            UNION
                            SELECT pr.id, pr.bill_no
                            FROM production_plans plan
                            JOIN production_material_analysis_materials material
                              ON material.analysis_id = plan.material_analysis_id
                             AND material.analysis_item_id = plan.material_analysis_item_id
                            JOIN preplan_supply_action_allocations allocation
                              ON allocation.analysis_id = material.analysis_id
                             AND allocation.analysis_material_id = material.id
                            JOIN preplan_supply_actions action
                              ON action.analysis_id = allocation.analysis_id
                             AND action.id = allocation.action_id
                             AND action.external_document_type = 'PURCHASE_REQUEST'
                             AND action.status IN ('CREATED', 'IN_PROGRESS', 'DONE')
                            JOIN purchase_requests pr
                              ON pr.id = action.external_document_id
                             AND pr.is_deleted = FALSE
                            WHERE plan.id = :planId
                              AND plan.is_deleted = FALSE
                        ) source
                        ORDER BY source.bill_no, source.id
                        """).setParameter("planId", planId));
        return rows.stream()
                .map(r -> new PlanTraceLink((UUID) r[0], (String) r[1], "PURCHASE_REQUEST", null, null))
                .toList();
    }

    /** 本计划所属分析产品的逐路径 action 生成的委外申请。 */
    private List<PlanTraceLink> traceSubcontractApplications(UUID planId) {
        List<Object[]> rows = com.uten.imp.common.util.NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT DISTINCT application.id, application.bill_no
                        FROM production_plans plan
                        JOIN production_material_analysis_materials material
                          ON material.analysis_id = plan.material_analysis_id
                         AND material.analysis_item_id = plan.material_analysis_item_id
                        JOIN preplan_supply_action_allocations allocation
                          ON allocation.analysis_id = material.analysis_id
                         AND allocation.analysis_material_id = material.id
                        JOIN preplan_supply_actions action
                          ON action.analysis_id = allocation.analysis_id
                         AND action.id = allocation.action_id
                         AND action.external_document_type = 'SUBCONTRACT_APPLICATION'
                         AND action.status IN ('CREATED', 'IN_PROGRESS', 'DONE')
                        JOIN subcontract_applications application
                          ON application.id = action.external_document_id
                         AND application.is_deleted = FALSE
                        WHERE plan.id = :planId
                          AND plan.is_deleted = FALSE
                        ORDER BY application.bill_no, application.id
                        """).setParameter("planId", planId));
        return rows.stream()
                .map(r -> new PlanTraceLink(
                        (UUID) r[0], (String) r[1], "SUBCONTRACT_APPLICATION", null, null))
                .toList();
    }

    private List<String> planDetailAllowedActions(ProductionPlan plan) {
        List<String> actions = new ArrayList<>();
        actions.add("VIEW");
        boolean draft = plan.getStatus() != null && plan.getStatus() == 0
                && !plan.isCanceled() && !plan.isDeleted();
        boolean writable = access.canWrite(plan.getMakerId(), access.scope());
        if (plan.getMaterialAnalysisId() != null
                && canOpenMaterialAnalysis(plan.getMaterialAnalysisId())) {
            actions.add("RETURN_TO_MATERIAL_ANALYSIS");
        } else if (draft && writable && access.hasAuthority("production_plan:edit")) {
            actions.add("EDIT");
        }
        if (draft && writable && access.hasAuthority("production_plan:approve")) {
            actions.add("APPROVE");
        }
        return List.copyOf(actions);
    }

    private boolean canOpenMaterialAnalysis(UUID analysisId) {
        if (!access.hasAuthority("production_material_analysis:view")) return false;
        List<?> makers = em.createNativeQuery("""
                SELECT maker_id FROM production_material_analyses
                WHERE id=:id AND is_deleted=FALSE
                """).setParameter("id", analysisId).getResultList();
        return !makers.isEmpty()
                && access.canRead((UUID) makers.getFirst(), access.scope());
    }

    private ProductionPlan requirePlanForUpdate(UUID id) {
        ProductionPlan plan = em.find(
                ProductionPlan.class, id, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (plan == null || plan.isDeleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "生产计划单不存在");
        }
        return plan;
    }

    /**
     * Keeps analysis-derived plan approval on the global inventory-first order. The caller then
     * locks the plan row before the source analysis row, so competing flows must never acquire an
     * inventory dimension after either document lock.
     * The reservation branch is required for historical/inactive material rows that still own
     * an effective V298/V307 pre-plan reservation.
     */
    private void lockSourceAnalysisInventoryDimensions(UUID planId) {
        List<?> sourceAnalyses = em.createNativeQuery("""
                        SELECT material_analysis_id
                        FROM production_plans
                        WHERE id = :planId
                          AND is_deleted = FALSE
                          AND material_analysis_id IS NOT NULL
                        """)
                .setParameter("planId", planId)
                .getResultList();
        if (sourceAnalyses.isEmpty()) {
            return;
        }
        UUID analysisId = (UUID) sourceAnalyses.getFirst();
        List<Object[]> dimensions = com.uten.imp.common.util.NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT dimension.goods_id, dimension.color_id
                        FROM (
                            SELECT material.goods_id, material.color_id
                            FROM production_material_analysis_materials material
                            WHERE material.analysis_id = :analysisId
                              AND material.active = TRUE
                            UNION
                            SELECT reservation.goods_id, reservation.color_id
                            FROM stock_reservations reservation
                            WHERE reservation.owner_type = 'PREPLAN_ANALYSIS'
                              AND reservation.owner_id = :analysisId
                              AND reservation.is_deleted = FALSE
                              AND reservation.status = 0
                              AND GREATEST(reservation.qty - reservation.consumed_qty
                                  - reservation.released_qty, 0) > 0
                        ) dimension
                        ORDER BY dimension.goods_id, dimension.color_id NULLS FIRST
                        """).setParameter("analysisId", analysisId));
        inventoryLock.lockAll(dimensions.stream()
                .map(row -> new InventoryKey((UUID) row[0], (UUID) row[1]))
                .toList());
    }

    private ProductionPlan requirePlan(UUID id) {
        return planRepo.findById(id).filter(p -> !p.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "生产计划单不存在"));
    }

    private static BigDecimal zeroIfNull(BigDecimal v) {
        return v != null ? v : BigDecimal.ZERO;
    }
}
