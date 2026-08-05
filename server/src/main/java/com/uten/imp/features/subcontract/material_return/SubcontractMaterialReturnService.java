package com.uten.imp.features.subcontract.material_return;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.integrity.LinkedDocumentIntegrityService;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.features.subcontract.material_return.dto.MaterialReturnDetail;
import com.uten.imp.features.subcontract.material_return.dto.MaterialReturnItemDto;
import com.uten.imp.features.subcontract.material_return.dto.MaterialReturnItemLine;
import com.uten.imp.features.subcontract.material_return.dto.MaterialReturnListItem;
import com.uten.imp.features.subcontract.material_return.dto.MaterialReturnQueryFilter;
import com.uten.imp.features.subcontract.material_return.dto.MaterialReturnSaveRequest;
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
 * 委外材料退货单服务：CRUD（主+明细）+ 审核状态机。
 *
 * <p>审核（status 0→1，同事务内，对每条明细）：
 * <ol>
 *   <li>{@link StockService#recordMovement} {@code TYPE_SUBCONTRACT_MATERIAL_RETURN=16, DIR_IN=+1}</li>
 *   <li>只回写子件权威来源：{@code material_issue_items.returned_qty += qty}</li>
 * </ol>
 * <b>不立应付</b>（材料退回不是加工费结算）。无 Price。
 *
 * <p>红冲（1→-1）：反向 DIR_OUT + 回减 returned_qty（无 ArAp）。
 */
@Service
@RequiredArgsConstructor
public class SubcontractMaterialReturnService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（材料退无金额列，仅日期可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate");

    private final SubcontractMaterialReturnRepository returnRepo;
    private final SubcontractMaterialReturnItemRepository itemRepo;
    private final StockService stockService;
    private final LinkedDocumentIntegrityService sourceIntegrity;
    private final TxSessionVars tx;
    private final EntityManager em;
    private final com.uten.imp.security.SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final DocNumberService docNumberService;

    @Transactional(readOnly = true)
    public PageResponse<MaterialReturnListItem> list(MaterialReturnQueryFilter f, int page, int size, String sort, String order) {
        Specification<SubcontractMaterialReturn> spec = (Root<SubcontractMaterialReturn> root,
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
        Page<SubcontractMaterialReturn> p = returnRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public MaterialReturnDetail detail(UUID id) {
        SubcontractMaterialReturn r = requireReturn(id);
        List<MaterialReturnItemDto> items = itemRepo.findByMaterialReturnIdOrderByLineNoAsc(id).stream()
                .map(this::toItemDto).toList();
        return toDetail(r, items);
    }

    @Transactional
    public MaterialReturnDetail create(MaterialReturnSaveRequest req) {
        tx.bind();
        SubcontractMaterialReturn r = new SubcontractMaterialReturn();
        applyHeader(req, r);
        r.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
        r.setStatus(STATUS_DRAFT);
        returnRepo.save(r);
        List<MaterialReturnItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public MaterialReturnDetail update(UUID id, MaterialReturnSaveRequest req) {
        tx.bind();
        SubcontractMaterialReturn r = requireReturnForUpdate(id);
        if (r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        applyHeader(req, r);
        itemRepo.deleteByMaterialReturnId(id);
        itemRepo.flush();
        List<MaterialReturnItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        SubcontractMaterialReturn r = requireReturnForUpdate(id);
        if (r.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        }
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        returnRepo.save(r);
    }

    /**
     * 审核：0→1。库存入库（DIR_IN）+ 回写发料子件 returned_qty。<b>不立应付</b>。
     */
    @Transactional
    public MaterialReturnDetail approve(UUID id) {
        tx.bind();
        SubcontractMaterialReturn r = requireReturnForUpdate(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (r.getWarehouseId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "材料退货单需指定入库仓");
        }
        List<SubcontractMaterialReturnItem> items = itemRepo.findByMaterialReturnIdOrderByLineNoAsc(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        }
        sourceIntegrity.validateSubcontractMaterialReturn(
                r.getSupplierId(),
                items.stream()
                        .map(it -> LinkedDocumentIntegrityService.LinkedLine.materialIssueSource(
                                it.getMaterialIssueItemId(),
                                it.getOrderItemId(),
                                it.getGoodsId(),
                                it.getColorId(),
                                it.getUnitId(),
                                it.getUnitRate(),
                                it.getParentGoodsId(),
                                it.getParentColorId()))
                        .toList());
        stockService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        OffsetDateTime now = OffsetDateTime.now();
        for (SubcontractMaterialReturnItem it : items) {
            // ① 入库（DIR_IN=+1）
            applyMovement(r, it, StockService.DIR_IN, now, null);
            // ② 只回写发料子件权威累计；不同子件量禁止汇总到成品订货行。
            // CAS 上限：已退 + 已损耗 + 本次 ≤ 已发，原子挡超退（并发两单也只过一笔）。
            if (it.getMaterialIssueItemId() != null) {
                int updated = em.createNativeQuery("""
                        UPDATE subcontract_material_issue_items
                        SET returned_qty = COALESCE(returned_qty,0) + :q
                        WHERE id = :id
                          AND COALESCE(qty,0) >= COALESCE(returned_qty,0) + COALESCE(wasted_qty,0) + :q
                        """)
                        .setParameter("q", it.getQty())
                        .setParameter("id", it.getMaterialIssueItemId())
                        .executeUpdate();
                if (updated != 1) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "委外退料量超过可退余量（已发 − 已退 − 已损耗），禁止超退");
                }
            }
        }
        // 不立应付：材料退回不是加工费
        r.setStatus(STATUS_APPROVED);
        r.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        returnRepo.save(r);
        return detail(id);
    }

    /** 红冲：1→-1。反向 DIR_OUT + 回减发料子件 returned_qty（无 ArAp）。 */
    @Transactional
    public MaterialReturnDetail reverse(UUID id) {
        tx.bind();
        SubcontractMaterialReturn r = requireReturnForUpdate(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        List<SubcontractMaterialReturnItem> items = itemRepo.findByMaterialReturnIdOrderByLineNoAsc(id);
        stockService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        OffsetDateTime now = OffsetDateTime.now();
        for (SubcontractMaterialReturnItem it : items) {
            applyMovement(r, it, StockService.DIR_OUT, now, null);
            if (it.getMaterialIssueItemId() != null) {
                int updated = em.createNativeQuery("""
                        UPDATE subcontract_material_issue_items
                        SET returned_qty = COALESCE(returned_qty,0) - :q
                        WHERE id = :id
                          AND COALESCE(returned_qty,0) >= :q
                        """)
                        .setParameter("q", it.getQty())
                        .setParameter("id", it.getMaterialIssueItemId())
                        .executeUpdate();
                if (updated != 1) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "委外退料红冲量超过已退量（可能已被其它单据改动），禁止负数");
                }
            }
        }
        r.setStatus(STATUS_REVERSED);
        returnRepo.save(r);
        return detail(id);
    }

    /** 写一笔库存流水（方向由调用方给）。qty 为明细量，baseQty = qty×unit_rate。 */
    private void applyMovement(SubcontractMaterialReturn r, SubcontractMaterialReturnItem it, short direction,
                               OffsetDateTime ts, BigDecimal overrideAmount) {
        BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
        BigDecimal baseQty = it.getQty().multiply(rate);
        BigDecimal amt = overrideAmount != null ? overrideAmount : it.getAmountLocal();
        stockService.recordMovement(new StockService.MovementRequest(
                ts, StockService.TYPE_SUBCONTRACT_MATERIAL_RETURN, StockService.SRC_SUBCONTRACT_MATERIAL_RETURN,
                r.getId(), it.getId(), it.getGoodsId(), it.getColorId(), r.getWarehouseId(),
                direction, baseQty, it.getUnitId(), it.getUnitRate(), amt,
                direction < 0 ? "红冲" : null));
    }

    private void applyHeader(MaterialReturnSaveRequest req, SubcontractMaterialReturn r) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (r.getBillNo() == null || r.getBillNo().isBlank()) {
            r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.SUB_MATERIAL_RETURN));
        }
        r.setBillDate(req.getBillDate());
        r.setSupplierId(req.getSupplierId());
        r.setWarehouseId(req.getWarehouseId());
        r.setWorkerId(req.getWorkerId());
        r.setBStyle(req.getBStyle());
        r.setRemark(req.getRemark());
        r.setOperatorLegacyId(req.getOperatorLegacyId());
        r.setOperatorName(req.getOperatorName());
        r.setMakerLegacyId(req.getMakerLegacyId());
        r.setMakerName(req.getMakerName());
        r.setApproverLegacyId(req.getApproverLegacyId());
        r.setApproverName(req.getApproverName());
    }

    private List<MaterialReturnItemDto> saveItems(SubcontractMaterialReturn r, List<MaterialReturnItemLine> lines) {
        List<MaterialReturnItemDto> out = new ArrayList<>(lines.size());
        int autoLine = 1;
        for (MaterialReturnItemLine l : lines) {
            SubcontractMaterialReturnItem it = new SubcontractMaterialReturnItem();
            it.setMaterialReturnId(r.getId());
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
            it.setMaterialIssueItemId(l.getMaterialIssueItemId());
            it.setOrderItemId(l.getOrderItemId());
            it.setParentGoodsId(l.getParentGoodsId());
            it.setParentColorId(l.getParentColorId());
            it.setWeight(l.getWeight());
            it.setSourceDocNo(l.getSourceDocNo());
            it.setRemark(l.getRemark());
            it.setGirthQty(l.getGirthQty());
            it.setIssueNo(l.getIssueNo());
            it.setOrderNo(l.getOrderNo());
            itemRepo.save(it);
            out.add(toItemDto(it));
            autoLine++;
        }
        return out;
    }

    private void applyTotals(SubcontractMaterialReturn r, List<MaterialReturnItemDto> items) {
        BigDecimal local = items.stream()
                .map(i -> i.getAmountLocal() == null ? BigDecimal.ZERO : i.getAmountLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = items.stream()
                .map(i -> i.getAmountOriginal() == null ? BigDecimal.ZERO : i.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        r.setTotalLocal(local);
        r.setTotalOriginal(original);
        returnRepo.save(r);
    }

    private MaterialReturnListItem toList(SubcontractMaterialReturn r) {
        return new MaterialReturnListItem(r.getId(), r.getBillNo(), r.getBillDate(), r.getSupplierId(),
                r.getWarehouseId(), r.getTotalLocal(), r.getStatus(), r.isClosed(), r.getLegacyId());
    }

    private MaterialReturnItemDto toItemDto(SubcontractMaterialReturnItem it) {
        return new MaterialReturnItemDto(it.getId(), it.getLineNo(), it.getGoodsId(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getMaterialIssueItemId(), it.getOrderItemId(),
                it.getParentGoodsId(), it.getParentColorId(), it.getWeight(), it.getSourceDocNo(), it.getRemark(),
                it.getGirthQty(), it.getIssueNo(), it.getOrderNo());
    }

    private MaterialReturnDetail toDetail(SubcontractMaterialReturn r, List<MaterialReturnItemDto> items) {
        return new MaterialReturnDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getSupplierId(), r.getWarehouseId(), r.getWorkerId(), r.getMakerId(), r.getApproverId(),
                r.getBStyle(), r.getRemark(), r.getTotalOriginal(), r.getTotalLocal(), r.getStatus(),
                r.isClosed(), r.getSourceDocNo(), items, r.getOperatorLegacyId(), r.getOperatorName(),
                r.getMakerLegacyId(),
                (r.getMakerName() != null && !r.getMakerName().isBlank()) ? r.getMakerName() : nameResolver.nameOf(r.getMakerId()),
                r.getApproverLegacyId(), r.getApproverName(), r.getCreatedAt());
    }

    private SubcontractMaterialReturn requireReturn(UUID id) {
        return returnRepo.findById(id)
                .filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "委外材料退货单不存在"));
    }
    private SubcontractMaterialReturn requireReturnForUpdate(UUID id) {
        SubcontractMaterialReturn materialReturn = em.find(
                SubcontractMaterialReturn.class, id, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        return materialReturn == null || materialReturn.isDeleted()
                ? requireReturn(id)
                : materialReturn;
    }
}
