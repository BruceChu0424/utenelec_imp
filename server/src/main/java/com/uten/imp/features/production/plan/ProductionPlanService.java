package com.uten.imp.features.production.plan;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.plan.dto.PlanDetail;
import com.uten.imp.features.production.plan.dto.PlanItemDto;
import com.uten.imp.features.production.plan.dto.PlanItemLine;
import com.uten.imp.features.production.plan.dto.PlanListItem;
import com.uten.imp.features.production.plan.dto.PlanQueryFilter;
import com.uten.imp.features.production.plan.dto.PlanSaveRequest;
import com.uten.imp.features.production.mrp.MrpRow;
import com.uten.imp.features.production.mrp.MrpService;
import com.uten.imp.security.SecurityContextCurrentUser;
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
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 生产计划服务：CRUD（主+明细）+ 审核状态机 + is_closed 派生。
 *
 * <p><b>审核（status 0→1）</b>：
 * <ul>
 *   <li>业务链排产联动（V90）：写 plan_order_item_links + 回写 sales_order_items.planned_qty
 *       + BOM 缺料检查（缺料行→3待物料 / 料够→4已排产）+ 防超排硬校验</li>
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

    /** 订单行链路状态（V90 chain_status）：排产落点两态。 */
    private static final short CHAIN_WAIT_MATERIAL = 3;  // 待物料（缺料）
    private static final short CHAIN_PLANNED = 4;        // 已排产

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of(
            "billDate", "billDate",
            "deliveryDate", "deliveryDate");

    private final ProductionPlanRepository planRepo;
    private final ProductionPlanItemRepository itemRepo;
    private final PlanOrderItemLinkRepository linkRepo;
    private final MrpService mrpService;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final EntityManager em;
    private final DocNumberService docNumberService;
    private final ChainNoticeService chainNotice;

    @Transactional(readOnly = true)
    public PageResponse<PlanListItem> list(PlanQueryFilter f, int page, int size, String sort, String order) {
        Specification<ProductionPlan> spec = (Root<ProductionPlan> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                              CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
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
        saveItems(p, req.getItems());
        recomputeClosed(p.getId());
        return detail(p.getId());
    }

    @Transactional
    public PlanDetail update(UUID id, PlanSaveRequest req) {
        tx.bind();
        ProductionPlan p = requirePlan(id);
        if (p.getStatus() != STATUS_DRAFT) throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
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
        ProductionPlan p = requirePlan(id);
        if (p.getStatus() == STATUS_APPROVED) throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        p.setDeleted(true);
        p.setDeletedAt(OffsetDateTime.now());
        planRepo.save(p);
    }

    /**
     * 审核（status 0→1）。
     *
     * <p>本期：仅置 status=1 + 重算 is_closed（CheckFulfill4 派生）。
     * <p>【本期后置】回写 sales_order_items / 设 step_legacy_id / 填 F_ProductingItem 归未来模块。
     */
    @Transactional
    public PlanDetail approve(UUID id) {
        tx.bind();
        ProductionPlan p = requirePlan(id);
        em.lock(p, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 并发审核/红冲互斥（多账号同单操作）
        if (p.getStatus() == null || p.getStatus() != STATUS_DRAFT)
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        if (itemRepo.findByPlanIdOrderByLineNoAsc(id).isEmpty())
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        p.setStatus(STATUS_APPROVED);
        p.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        planRepo.save(p);
        boolean shortage = linkOrderItems(id); // 业务链：写 plan_order_item_links + 回写 planned_qty + BOM 缺料标状态（V90）
        recomputeClosed(id);
        chainNotice.notifyPlanScheduled(id, shortage); // 旁路通知：排产→销售（缺料→采购/调度），提交后发送
        return detail(id);
    }

    /**
     * 排产联动（V90，docs/07-业务链路/02 §三）。两种来源：
     * ① 合并排产（调度工作台）：links 已在创建时预建（一行可挂多订单行），审核只做校验+回写；
     * ② 手工计划单：明细行带 salesOrderItemId（1:1），审核时按 qty 建行。
     * 每笔分摊都做防超排硬校验（累计排产 ≤ 订货量 − 已预留 − 已排产）；
     * 行状态推进：缺料→3待物料 / 料够→4已排产（只从 1/2 低态推进，不覆盖 6+ 后段状态）。
     * @return 是否缺料（BOM 净需求 > 0），供审核后发缺料通知
     */
    private boolean linkOrderItems(UUID planId) {
        List<ProductionPlanItem> items = itemRepo.findByPlanIdOrderByLineNoAsc(planId).stream()
                .filter(i -> zeroIfNull(i.getQty()).signum() > 0)
                .toList();
        if (items.isEmpty()) return false;
        short chain = materialShortage(planId) ? CHAIN_WAIT_MATERIAL : CHAIN_PLANNED;
        for (ProductionPlanItem it : items) {
            List<PlanOrderItemLink> prebuilt = linkRepo.findActiveByPlanItemIds(List.of(it.getId()));
            if (!prebuilt.isEmpty()) {
                // 合并排产：按预建 links 逐笔校验 + 回写
                for (PlanOrderItemLink l : prebuilt) {
                    applyAllocation(l.getOrderItemId(), l.getAllocatedQty(), chain);
                }
            } else if (it.getSalesOrderItemId() != null) {
                // 手工计划单：1:1 建行
                BigDecimal alloc = zeroIfNull(it.getQty());
                applyAllocation(it.getSalesOrderItemId(), alloc, chain);
                PlanOrderItemLink link = new PlanOrderItemLink();
                link.setPlanItemId(it.getId());
                link.setOrderItemId(it.getSalesOrderItemId());
                link.setAllocatedQty(alloc);
                linkRepo.save(link);
            }
        }
        return chain == CHAIN_WAIT_MATERIAL;
    }

    /** 防超排校验 + planned_qty 回写 + 行状态推进（一笔分摊）。 */
    private void applyAllocation(UUID orderItemId, BigDecimal alloc, short chain) {
        Object[] r = (Object[]) em.createNativeQuery(
                "SELECT qty, reserved_qty, planned_qty FROM sales_order_items WHERE id = :id")
                .setParameter("id", orderItemId).getSingleResult();
        BigDecimal need = bd(r[0]).subtract(bd(r[1])).subtract(bd(r[2]));
        if (alloc.compareTo(need) > 0) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "排产量超过订单未满足需求（剩余可排 " + need.stripTrailingZeros().toPlainString() + "）");
        }
        em.createNativeQuery("""
                UPDATE sales_order_items
                SET planned_qty = COALESCE(planned_qty,0) + :a,
                    chain_status = CASE WHEN COALESCE(chain_status,0) IN (1,2) THEN :st
                                   ELSE chain_status END
                WHERE id = :id
                """).setParameter("a", alloc).setParameter("st", chain)
                .setParameter("id", orderItemId).executeUpdate();
    }

    /** BOM 物料检查：任一外购物料净需求 > 0 即缺料（复用 MRP-lite 展开口径；无 BOM 视为不缺料）。 */
    private boolean materialShortage(UUID planId) {
        return mrpService.preview(planId).stream()
                .anyMatch(r -> !r.selfMade() && r.net() != null && r.net().signum() > 0);
    }

    /**
     * 红冲联动：软删 plan_order_item_links（留痕）+ 回退 planned_qty + 行状态回退
     * （预留已覆盖→7可发货 / 未覆盖→2待排产）。已报工/已入库的计划禁止红冲。
     */
    private void unlinkOrderItems(UUID planId) {
        List<UUID> itemIds = itemRepo.findByPlanIdOrderByLineNoAsc(planId).stream()
                .map(ProductionPlanItem::getId).toList();
        if (itemIds.isEmpty()) return;
        for (PlanOrderItemLink l : linkRepo.findActiveByPlanItemIds(itemIds)) {
            if (l.getInboundQty().signum() > 0 || l.getProducedQty().signum() > 0) {
                throw new ApiException(ErrorCode.BUSINESS, "已有报工/完工入库，不能红冲计划");
            }
            l.setDeleted(true);
            l.setDeletedAt(OffsetDateTime.now());
            linkRepo.save(l);
            em.createNativeQuery("""
                    UPDATE sales_order_items
                    SET planned_qty = GREATEST(0, COALESCE(planned_qty,0) - :a),
                        chain_status = CASE WHEN COALESCE(chain_status,0) IN (3,4) THEN
                            CASE WHEN COALESCE(reserved_qty,0) >= COALESCE(qty,0) - COALESCE(shipped_qty,0)
                                 THEN 7 ELSE 2 END
                        ELSE chain_status END
                    WHERE id = :id
                    """).setParameter("a", l.getAllocatedQty())
                    .setParameter("id", l.getOrderItemId()).executeUpdate();
        }
    }

    private static BigDecimal bd(Object v) {
        return v == null ? BigDecimal.ZERO : (BigDecimal) v;
    }

    /**
     * 红冲（status 1→-1）。
     *
     * <p>本期仅置状态：生产计划本身不动库存、不立帐，无需反向冲销；
     * 累计量（iqty/rqty/...）由下游单据（仓库/采购/委外）各自负责回写，红冲计划不级联。
     */
    @Transactional
    public PlanDetail reverse(UUID id) {
        tx.bind();
        ProductionPlan p = requirePlan(id);
        em.lock(p, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 并发审核/红冲互斥
        if (p.getStatus() == null || p.getStatus() != STATUS_APPROVED)
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        unlinkOrderItems(id); // 业务链：links 软删 + planned_qty 回退（已报工/入库则拒绝）
        p.setStatus(STATUS_REVERSED);
        planRepo.save(p);
        return detail(id);
    }

    // ====================== is_closed 派生（CheckFulfill4 → Service） ======================

    /**
     * 重算主表 is_closed（CheckFulfill4 派生）：所有非软删明细 {@code qty - iqty ≤ 0} 时为 true。
     *
     * <p>取代老库触发器 CheckFulfill4（design §4.2 行）。同采购 {@code recalcRequestClosed} 范式。
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
        int auto = 1;
        for (PlanItemLine l : lines) {
            ProductionPlanItem it = new ProductionPlanItem();
            it.setPlanId(p.getId());
            it.setBillNo(p.getBillNo());
            it.setBillDate(p.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            it.setProductNo(l.getProductNo());
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
                p.getStatus(), p.isClosed(), p.isStopped(), p.isCanceled(), p.getSourceDocNo(), items,
                nameResolver.nameOf(p.getMakerId()), p.getCreatedAt());
    }

    private ProductionPlan requirePlan(UUID id) {
        return planRepo.findById(id).filter(p -> !p.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "生产计划单不存在"));
    }

    private static BigDecimal zeroIfNull(BigDecimal v) {
        return v != null ? v : BigDecimal.ZERO;
    }
}
