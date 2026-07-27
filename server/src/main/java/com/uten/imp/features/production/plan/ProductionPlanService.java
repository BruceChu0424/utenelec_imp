package com.uten.imp.features.production.plan;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.features.production.plan.dto.PlanDetail;
import com.uten.imp.features.production.plan.dto.PlanItemDto;
import com.uten.imp.features.production.plan.dto.PlanItemLine;
import com.uten.imp.features.production.plan.dto.PlanListItem;
import com.uten.imp.features.production.plan.dto.PlanQueryFilter;
import com.uten.imp.features.production.plan.dto.PlanSaveRequest;
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
 * <p><b>审核（status 0→1）</b>（design §4.1）：
 * <ul>
 *   <li>重算主表 {@code is_closed}（CheckFulfill4 派生：所有明细 {@code qty - iqty ≤ 0}）</li>
 *   <li>【本期后置】回写 sales_order_items 的 PQTY/LQTY/PlanNo（销售模块上线后）</li>
 *   <li>【本期后置】设 plan_items.step_legacy_id 首工序（车间模块上线后）</li>
 *   <li>【本期后置】填充 F_ProductingItem 按日产能（排产模块上线后）</li>
 * </ul>
 *
 * <p><b>不调</b> {@code StockService}（计划不动库存）；<b>不调</b> {@code ArApLedgerService}（计划不立帐）。
 *
 * <p><b>红冲（1→-1）</b>：仅置状态（无库存/立帐可冲；下游累计量本期由仓库/采购/委外模块各自负责回写）。
 */
@Service
@RequiredArgsConstructor
public class ProductionPlanService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of(
            "billDate", "billDate",
            "deliveryDate", "deliveryDate");

    private final ProductionPlanRepository planRepo;
    private final ProductionPlanItemRepository itemRepo;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final EntityManager em;

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
        p.setMakerId(currentUser.requireId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
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
        if (p.getStatus() == null || p.getStatus() != STATUS_DRAFT)
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        if (itemRepo.findByPlanIdOrderByLineNoAsc(id).isEmpty())
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        p.setStatus(STATUS_APPROVED);
        p.setApproverId(currentUser.requireId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        planRepo.save(p);
        recomputeClosed(id);
        // 本期后置：销售模块/车间模块/排产模块上线后在此回写 sales_order_items 与 F_ProductingItem（design §4.1）
        return detail(id);
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
        if (p.getStatus() == null || p.getStatus() != STATUS_APPROVED)
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
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
        p.setBillNo(req.getBillNo());
        p.setBillDate(req.getBillDate());
        p.setFStyle(req.getFStyle());
        p.setDeliveryDate(req.getDeliveryDate());
        p.setDepartmentId(req.getDepartmentId());
        p.setWorkshopName(req.getWorkshopName());
        p.setWorkerName(req.getWorkerName());
        p.setSellerName(req.getSellerName());
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
                p.getMakerId(), p.getApproverId(), p.getMakerLegacyId(), p.getApproverLegacyId(), p.getRemark(),
                p.getStatus(), p.isClosed(), p.isStopped(), p.isCanceled(), p.getSourceDocNo(), items);
    }

    private ProductionPlan requirePlan(UUID id) {
        return planRepo.findById(id).filter(p -> !p.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "生产计划单不存在"));
    }

    private static BigDecimal zeroIfNull(BigDecimal v) {
        return v != null ? v : BigDecimal.ZERO;
    }
}
