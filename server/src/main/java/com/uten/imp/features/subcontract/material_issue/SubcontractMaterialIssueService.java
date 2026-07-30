package com.uten.imp.features.subcontract.material_issue;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueDetail;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemDto;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueListItem;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueQueryFilter;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest;
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
 * 委外材料出仓单服务：CRUD（主+明细）+ 审核状态机。
 *
 * <p>审核（status 0→1，同事务内，对每条明细）：
 * <ol>
 *   <li>{@link StockService#recordMovement} {@code TYPE_SUBCONTRACT_MATERIAL_ISSUE=15, DIR_OUT=-1}</li>
 *   <li>回写订货明细 {@code subcontract_order_items.issued_qty += qty}</li>
 *   <li>重算订货单 is_closed</li>
 * </ol>
 * <b>不立应付</b>（材料发出不是加工费结算，加工费走进仓单 BOM 成本）。无 Price（amount 可空）。
 *
 * <p>红冲（1→-1）：反向 DIR_IN + 回减 issued_qty + 重算 is_closed + 置 status=-1。
 *
 * <p>取代老库 E_SOut 触发器（其写 StockGoods 按月台账 + CheckChange_E 维护 SQTY 累计）。
 */
@Service
@RequiredArgsConstructor
public class SubcontractMaterialIssueService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（发料无金额列，仅日期可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate");

    private final SubcontractMaterialIssueRepository issueRepo;
    private final SubcontractMaterialIssueItemRepository itemRepo;
    private final StockService stockService;
    private final TxSessionVars tx;
    private final EntityManager em;
    private final com.uten.imp.security.SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final DocNumberService docNumberService;

    @Transactional(readOnly = true)
    public PageResponse<MaterialIssueListItem> list(MaterialIssueQueryFilter f, int page, int size, String sort, String order) {
        Specification<SubcontractMaterialIssue> spec = (Root<SubcontractMaterialIssue> root,
                                                        jakarta.persistence.criteria.CriteriaQuery<?> q,
                                                        CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(cb.like(cb.lower(root.get("billNo")), "%" + f.keyword().toLowerCase() + "%"));
            }
            if (f.supplierId() != null) ps.add(cb.equal(root.get("supplierId"), f.supplierId()));
            if (f.warehouseId() != null) ps.add(cb.equal(root.get("warehouseId"), f.warehouseId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<SubcontractMaterialIssue> p = issueRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public MaterialIssueDetail detail(UUID id) {
        SubcontractMaterialIssue r = requireIssue(id);
        List<MaterialIssueItemDto> items = itemRepo.findByIssueIdOrderByLineNoAsc(id).stream()
                .map(this::toItemDto).toList();
        return toDetail(r, items);
    }

    @Transactional
    public MaterialIssueDetail create(MaterialIssueSaveRequest req) {
        tx.bind();
        SubcontractMaterialIssue r = new SubcontractMaterialIssue();
        applyHeader(req, r);
        r.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
        r.setStatus(STATUS_DRAFT);
        issueRepo.save(r);
        List<MaterialIssueItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public MaterialIssueDetail update(UUID id, MaterialIssueSaveRequest req) {
        tx.bind();
        SubcontractMaterialIssue r = requireIssue(id);
        if (r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        applyHeader(req, r);
        itemRepo.deleteByIssueId(id);
        itemRepo.flush();
        List<MaterialIssueItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        SubcontractMaterialIssue r = requireIssue(id);
        if (r.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        }
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        issueRepo.save(r);
    }

    /**
     * 审核：0→1。库存出库（DIR_OUT）+ 回写订货 issued_qty + 重算订货 is_closed。<b>不立应付</b>。
     */
    @Transactional
    public MaterialIssueDetail approve(UUID id) {
        tx.bind();
        SubcontractMaterialIssue r = requireIssue(id);
        em.lock(r, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 并发审核/红冲互斥（多账号同单操作）
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (r.getWarehouseId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "发料单需指定发出仓");
        }
        List<SubcontractMaterialIssueItem> items = itemRepo.findByIssueIdOrderByLineNoAsc(id);
        stockService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        }
        OffsetDateTime now = OffsetDateTime.now();
        for (SubcontractMaterialIssueItem it : items) {
            // ① 出库（DIR_OUT=-1）
            applyMovement(r, it, StockService.DIR_OUT, now, null);
            // ② 回写订货明细 issued_qty + 重算 is_closed
            if (it.getOrderItemId() != null) {
                em.createNativeQuery(
                        "UPDATE subcontract_order_items SET issued_qty = COALESCE(issued_qty,0) + :q WHERE id = :id")
                        .setParameter("q", it.getQty())
                        .setParameter("id", it.getOrderItemId())
                        .executeUpdate();
                recalcOrderClosed(it.getOrderItemId());
            }
        }
        // 不立应付：材料发出不是加工费（加工费走进仓单 BOM 成本）
        r.setStatus(STATUS_APPROVED);
        r.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        issueRepo.save(r);
        return detail(id);
    }

    /** 红冲：1→-1。反向 DIR_IN + 回减 issued_qty + 重算 is_closed（无 ArAp）。 */
    @Transactional
    public MaterialIssueDetail reverse(UUID id) {
        tx.bind();
        SubcontractMaterialIssue r = requireIssue(id);
        em.lock(r, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 并发审核/红冲互斥（多账号同单操作）
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        List<SubcontractMaterialIssueItem> items = itemRepo.findByIssueIdOrderByLineNoAsc(id);
        if (items.stream().anyMatch(it ->
                positive(it.getReturnedQty()) || positive(it.getWastedQty()))) {
            throw new ApiException(ErrorCode.BUSINESS, "委外发料已有退料/损耗记录，请先红冲下游单据");
        }
        stockService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        OffsetDateTime now = OffsetDateTime.now();
        for (SubcontractMaterialIssueItem it : items) {
            applyMovement(r, it, StockService.DIR_IN, now, null);
            if (it.getOrderItemId() != null) {
                em.createNativeQuery(
                        "UPDATE subcontract_order_items SET issued_qty = COALESCE(issued_qty,0) - :q WHERE id = :id")
                        .setParameter("q", it.getQty())
                        .setParameter("id", it.getOrderItemId())
                        .executeUpdate();
                recalcOrderClosed(it.getOrderItemId());
            }
        }
        r.setStatus(STATUS_REVERSED);
        issueRepo.save(r);
        return detail(id);
    }

    private static boolean positive(BigDecimal value) {
        return value != null && value.signum() > 0;
    }

    /** 写一笔库存流水（方向由调用方给）。qty 为明细量，baseQty = qty×unit_rate。 */
    private void applyMovement(SubcontractMaterialIssue r, SubcontractMaterialIssueItem it, short direction,
                               OffsetDateTime ts, BigDecimal overrideAmount) {
        BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
        BigDecimal baseQty = it.getQty().multiply(rate);
        BigDecimal amt = overrideAmount != null ? overrideAmount : it.getAmountLocal();
        stockService.recordMovement(new StockService.MovementRequest(
                ts, StockService.TYPE_SUBCONTRACT_MATERIAL_ISSUE, StockService.SRC_SUBCONTRACT_MATERIAL_ISSUE,
                r.getId(), it.getId(), it.getGoodsId(), it.getColorId(), r.getWarehouseId(),
                direction, baseQty, it.getUnitId(), it.getUnitRate(), amt,
                direction < 0 ? null : "红冲"));
    }

    /** 重算订货单结案：所有明细 qty - received_qty + returned_qty ≤ 0 → is_closed=true。 */
    private void recalcOrderClosed(UUID orderItemId) {
        em.createNativeQuery("""
                UPDATE subcontract_orders o SET is_closed = (
                    SELECT COALESCE(bool_and(
                        COALESCE(i.qty,0) - COALESCE(i.received_qty,0) + COALESCE(i.returned_qty,0) <= 0
                    ), true)
                    FROM subcontract_order_items i
                    WHERE i.order_id = o.id AND COALESCE(i.is_deleted, false) = false
                ) WHERE o.id = (SELECT order_id FROM subcontract_order_items WHERE id = :iid)
                """).setParameter("iid", orderItemId).executeUpdate();
    }

    private void applyHeader(MaterialIssueSaveRequest req, SubcontractMaterialIssue r) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (r.getBillNo() == null || r.getBillNo().isBlank()) {
            r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.SUB_MATERIAL_ISSUE));
        }
        r.setBillDate(req.getBillDate());
        r.setSupplierId(req.getSupplierId());
        r.setWarehouseId(req.getWarehouseId());
        r.setWorkerId(req.getWorkerId());
        r.setDeliverDate(req.getDeliverDate());
        r.setRemark(req.getRemark());
        r.setOperatorLegacyId(req.getOperatorLegacyId());
        r.setOperatorName(req.getOperatorName());
        r.setMakerLegacyId(req.getMakerLegacyId());
        r.setMakerName(req.getMakerName());
        r.setApproverLegacyId(req.getApproverLegacyId());
        r.setApproverName(req.getApproverName());
    }

    private List<MaterialIssueItemDto> saveItems(SubcontractMaterialIssue r, List<MaterialIssueItemLine> lines) {
        List<MaterialIssueItemDto> out = new ArrayList<>(lines.size());
        int autoLine = 1;
        for (MaterialIssueItemLine l : lines) {
            SubcontractMaterialIssueItem it = new SubcontractMaterialIssueItem();
            it.setIssueId(r.getId());
            it.setBillNo(r.getBillNo());
            it.setBillDate(r.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : autoLine);
            it.setGoodsId(l.getGoodsId());
            it.setColorId(l.getColorId());
            it.setUnitId(l.getUnitId());
            it.setUnitRate(l.getUnitRate());
            it.setQty(l.getQty());
            it.setPrice(l.getPrice());
            it.setAmountOriginal(l.getAmountOriginal());
            it.setAmountLocal(l.getAmountLocal());
            it.setOrderItemId(l.getOrderItemId());
            it.setParentGoodsId(l.getParentGoodsId());
            it.setParentColorId(l.getParentColorId());
            it.setWeight(l.getWeight());
            it.setSourceDocNo(l.getSourceDocNo());
            it.setRemark(l.getRemark());
            it.setBoxQty(l.getBoxQty());
            it.setReturnNo(l.getReturnNo());
            it.setOrderNo(l.getOrderNo());
            itemRepo.save(it);
            out.add(toItemDto(it));
            autoLine++;
        }
        return out;
    }

    private void applyTotals(SubcontractMaterialIssue r, List<MaterialIssueItemDto> items) {
        BigDecimal local = items.stream()
                .map(i -> i.getAmountLocal() == null ? BigDecimal.ZERO : i.getAmountLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = items.stream()
                .map(i -> i.getAmountOriginal() == null ? BigDecimal.ZERO : i.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        r.setTotalLocal(local);
        r.setTotalOriginal(original);
        issueRepo.save(r);
    }

    private MaterialIssueListItem toList(SubcontractMaterialIssue r) {
        return new MaterialIssueListItem(r.getId(), r.getBillNo(), r.getBillDate(), r.getSupplierId(),
                r.getWarehouseId(), r.getTotalLocal(), r.getStatus(), r.isClosed(), r.getLegacyId());
    }

    private MaterialIssueItemDto toItemDto(SubcontractMaterialIssueItem it) {
        return new MaterialIssueItemDto(it.getId(), it.getLineNo(), it.getGoodsId(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getReturnedQty(), it.getWastedQty(), it.getOrderItemId(),
                it.getParentGoodsId(), it.getParentColorId(), it.getWeight(), it.getSourceDocNo(), it.getRemark(),
                it.getBoxQty(), it.getReturnNo(), it.getOrderNo());
    }

    private MaterialIssueDetail toDetail(SubcontractMaterialIssue r, List<MaterialIssueItemDto> items) {
        return new MaterialIssueDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getSupplierId(), r.getWarehouseId(), r.getWorkerId(), r.getMakerId(), r.getApproverId(),
                r.getDeliverDate(), r.getRemark(), r.getTotalOriginal(), r.getTotalLocal(), r.getStatus(),
                r.isClosed(), r.getSourceDocNo(), items, r.getOperatorLegacyId(), r.getOperatorName(),
                r.getMakerLegacyId(),
                (r.getMakerName() != null && !r.getMakerName().isBlank()) ? r.getMakerName() : nameResolver.nameOf(r.getMakerId()),
                r.getApproverLegacyId(), r.getApproverName(), r.getCreatedAt());
    }

    private SubcontractMaterialIssue requireIssue(UUID id) {
        return issueRepo.findById(id)
                .filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "委外材料出仓单不存在"));
    }
}
