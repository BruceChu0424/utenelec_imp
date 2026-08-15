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
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.SubcontractGoodsSnapshot;
import com.uten.imp.features.subcontract.SubcontractGoodsKeyword;
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
 * <p>新单审核当前 fail-closed：在委外订货冻结 BOM 版本和子件发料权威台账
 * 落地前，不允许产生新的库存出库。禁止把不同子件数量累计到成品订货行。
 * <b>不立应付</b>（材料发出不是加工费结算，加工费走进仓单 BOM 成本）。无 Price（amount 可空）。
 *
 * <p>红冲（1→-1）：反向 DIR_IN + 置 status=-1；成品订货行上的历史
 * issued_qty 不再作为权威口径，也不继续改写。
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
    private final SubcontractDocumentAccessPolicy access;

    @Transactional(readOnly = true)
    public PageResponse<MaterialIssueListItem> list(MaterialIssueQueryFilter f, int page, int size, String sort, String order) {
        var readScope = access.scope();
        Specification<SubcontractMaterialIssue> spec = (Root<SubcontractMaterialIssue> root,
                                                        jakarta.persistence.criteria.CriteriaQuery<?> q,
                                                        CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            ps.add(access.readablePredicate(root, cb, "makerId", readScope));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(SubcontractGoodsKeyword.predicate(
                        cb, q, root, SubcontractMaterialIssueItem.class, "issueId", f.keyword()));
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
        access.requireReadable(r.getMakerId(), "委外材料出仓单不存在");
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
        canonicalizeMaker(r);
        r.setStatus(STATUS_DRAFT);
        issueRepo.save(r);
        List<MaterialIssueItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public MaterialIssueDetail update(UUID id, MaterialIssueSaveRequest req) {
        tx.bind();
        SubcontractMaterialIssue r = requireIssueForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外材料出仓单");
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
        SubcontractMaterialIssue r = requireIssueForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外材料出仓单");
        if (r.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        }
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        issueRepo.save(r);
    }

    /**
     * 审核：0→1。冻结 BOM 版本 + 建供应商处子件台账（at_supplier_qty = 发料量）+ 材料出库（type15, DIR_OUT）。
     *
     * <p>放开原 fail-closed 门禁：发料现在有权威台账，回厂进仓可按冻结 BOM 守恒消费
     * （supplier_ending = at_supplier − consumed − returned − wasted，DB 强制 ≥ 0）。
     * 要求每条明细挂委外订货明细（order_item_id），以便回厂按父件 BOM 消费。
     * 不立应付（材料发出不是加工费结算，加工费走进仓单 BOM 成本）。
     */
    @Transactional
    public MaterialIssueDetail approve(UUID id) {
        tx.bind();
        SubcontractMaterialIssue r = requireIssueForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外材料出仓单");
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (r.getWarehouseId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "发料单需指定发出仓");
        }
        List<SubcontractMaterialIssueItem> items = itemRepo.findByIssueIdOrderByLineNoAsc(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        }
        for (SubcontractMaterialIssueItem it : items) {
            if (it.getOrderItemId() == null) {
                throw new ApiException(ErrorCode.BUSINESS, "委外发料明细须关联委外订货明细，以便回厂按 BOM 守恒消费");
            }
            if (it.getQty() == null || it.getQty().signum() <= 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "发料明细数量必须大于 0");
            }
        }
        captureGoodsSnapshots(
                items,
                SubcontractGoodsSnapshot.ORDER_ITEM_AT_APPROVAL,
                SubcontractGoodsSnapshot.MASTER_AT_APPROVAL,
                OffsetDateTime.now());
        stockService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        OffsetDateTime now = OffsetDateTime.now();
        for (SubcontractMaterialIssueItem it : items) {
            applyMovement(r, it, StockService.DIR_OUT, now, null);
            // 冻结 BOM 版本（每单位父件耗用本子件量）+ 建供应商处子件台账（at_supplier = 发料量）
            it.setAtSupplierQty(it.getQty());
            it.setFrozenUnitQty(lookupFrozenUnitQty(it.getParentGoodsId(), it.getGoodsId()));
            itemRepo.save(it);
        }
        r.setStatus(STATUS_APPROVED);
        r.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        canonicalizeApprover(r);
        issueRepo.save(r);
        return detail(id);
    }

    /**
     * 查当前 goods_bom_items 的子件单位用量（每单位父件耗用本子件），作为本次发料的冻结 BOM 版本。
     * 无 BOM 边返回 null（该子件不按 BOM 消费；回厂消费将跳过此子件）。
     */
    private BigDecimal lookupFrozenUnitQty(UUID parentGoodsId, UUID componentGoodsId) {
        if (parentGoodsId == null || componentGoodsId == null) return null;
        @SuppressWarnings("unchecked")
        List<BigDecimal> rows = em.createNativeQuery("""
                SELECT qty FROM goods_bom_items
                WHERE goods_id = :parent AND component_goods_id = :component
                  AND COALESCE(is_deleted, false) = false
                ORDER BY sort_order ASC NULLS LAST, id ASC
                LIMIT 1
                """)
                .setParameter("parent", parentGoodsId)
                .setParameter("component", componentGoodsId)
                .getResultList();
        return rows.isEmpty() ? null : rows.getFirst();
    }

    /** 红冲：1→-1。反向 DIR_IN；不再改写成品行 legacy issued_qty（无 ArAp）。 */
    @Transactional
    public MaterialIssueDetail reverse(UUID id) {
        tx.bind();
        SubcontractMaterialIssue r = requireIssueForUpdate(id);
        access.requireWritable(r.getMakerId(), "只能操作本人负责的委外材料出仓单");
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        List<SubcontractMaterialIssueItem> items = itemRepo.findByIssueIdOrderByLineNoAsc(id);
        if (items.stream().anyMatch(it ->
                positive(it.getReturnedQty()) || positive(it.getWastedQty())
                        || positive(it.getConsumedQty()))) {
            throw new ApiException(ErrorCode.BUSINESS, "委外发料已有退料/损耗/回厂消费记录，请先红冲下游单据");
        }
        stockService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        OffsetDateTime now = OffsetDateTime.now();
        for (SubcontractMaterialIssueItem it : items) {
            applyMovement(r, it, StockService.DIR_IN, now, null);
            // 物料回到公司仓：清零供应商处台账（at_supplier 归零；consumed/returned/wasted 已校验为 0）
            it.setAtSupplierQty(BigDecimal.ZERO);
            itemRepo.save(it);
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

    private void applyHeader(MaterialIssueSaveRequest req, SubcontractMaterialIssue r) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (r.getBillNo() == null || r.getBillNo().isBlank()) {
            r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.SUB_MATERIAL_ISSUE));
        }
        r.setBillDate(req.getBillDate());
        r.setSupplierId(req.getSupplierId());
        r.setWarehouseId(req.getWarehouseId());
        var operator = nameResolver.resolveForWrite(
                req.getWorkerId(), req.getOperatorLegacyId(), req.getOperatorName(), "经办人");
        if (!(operator == null && r.getLegacyId() != null && r.getWorkerId() == null)) {
            r.setWorkerId(operator == null ? null : operator.id());
            r.setOperatorLegacyId(operator == null ? null : operator.legacyId());
            r.setOperatorName(operator == null ? null : operator.name());
        }
        r.setDeliverDate(req.getDeliverDate());
        r.setRemark(req.getRemark());
        canonicalizeMaker(r);
        canonicalizeApprover(r);
    }

    private void canonicalizeMaker(SubcontractMaterialIssue issue) {
        if (issue.getMakerId() == null) return;
        issue.setMakerLegacyId(null); // historical Sys_Operator ids are a different namespace
        issue.setMakerName(nameResolver.nameOf(issue.getMakerId()));
    }

    private void canonicalizeApprover(SubcontractMaterialIssue issue) {
        if (issue.getApproverId() == null) return;
        issue.setApproverLegacyId(null);
        issue.setApproverName(nameResolver.nameOf(issue.getApproverId()));
    }

    private List<MaterialIssueItemDto> saveItems(SubcontractMaterialIssue r, List<MaterialIssueItemLine> lines) {
        List<MaterialIssueItemDto> out = new ArrayList<>(lines.size());
        Map<UUID, SubcontractGoodsSnapshot> orderSnapshots =
                SubcontractGoodsSnapshot.fromOrderItems(
                        em,
                        lines.stream().map(MaterialIssueItemLine::getOrderItemId).toList(),
                        SubcontractGoodsSnapshot.ORDER_ITEM_AT_SAVE);
        List<UUID> masterGoodsIds = new ArrayList<>();
        lines.forEach(line -> {
            masterGoodsIds.add(line.getGoodsId());
            masterGoodsIds.add(line.getParentGoodsId());
        });
        Map<UUID, SubcontractGoodsSnapshot> master = SubcontractGoodsSnapshot.fromMaster(
                em, masterGoodsIds, SubcontractGoodsSnapshot.MASTER_AT_SAVE);
        int autoLine = 1;
        for (MaterialIssueItemLine l : lines) {
            SubcontractMaterialIssueItem it = new SubcontractMaterialIssueItem();
            it.setIssueId(r.getId());
            it.setBillNo(r.getBillNo());
            it.setBillDate(r.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : autoLine);
            it.setGoodsId(l.getGoodsId());
            applyChildSnapshot(it, SubcontractGoodsSnapshot.require(
                    master, l.getGoodsId(), "委外发料子件"), null);
            it.setColorId(l.getColorId());
            it.setUnitId(l.getUnitId());
            it.setUnitRate(l.getUnitRate());
            it.setQty(l.getQty());
            it.setPrice(l.getPrice());
            it.setAmountOriginal(l.getAmountOriginal());
            it.setAmountLocal(l.getAmountLocal());
            it.setOrderItemId(l.getOrderItemId());
            it.setParentGoodsId(l.getParentGoodsId());
            applyParentSnapshot(
                    it,
                    SubcontractGoodsSnapshot.optionalPreferred(
                            orderSnapshots,
                            l.getOrderItemId(),
                            master,
                            l.getParentGoodsId(),
                            "委外发料父件"),
                    null);
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

    private void captureGoodsSnapshots(
            List<SubcontractMaterialIssueItem> items,
            String orderSource,
            String masterSource,
            OffsetDateTime lockedAt) {
        Map<UUID, SubcontractGoodsSnapshot> orders = SubcontractGoodsSnapshot.fromOrderItems(
                em, items.stream().map(SubcontractMaterialIssueItem::getOrderItemId).toList(), orderSource);
        List<UUID> masterGoodsIds = new ArrayList<>();
        items.forEach(item -> {
            masterGoodsIds.add(item.getGoodsId());
            masterGoodsIds.add(item.getParentGoodsId());
        });
        Map<UUID, SubcontractGoodsSnapshot> master =
                SubcontractGoodsSnapshot.fromMaster(em, masterGoodsIds, masterSource);
        for (SubcontractMaterialIssueItem item : items) {
            applyChildSnapshot(item, SubcontractGoodsSnapshot.require(
                    master, item.getGoodsId(), "委外发料子件"), lockedAt);
            applyParentSnapshot(
                    item,
                    SubcontractGoodsSnapshot.optionalPreferred(
                            orders,
                            item.getOrderItemId(),
                            master,
                            item.getParentGoodsId(),
                            "委外发料父件"),
                    lockedAt);
        }
        itemRepo.saveAll(items);
        itemRepo.flush();
    }

    private static void applyChildSnapshot(
            SubcontractMaterialIssueItem item,
            SubcontractGoodsSnapshot snapshot,
            OffsetDateTime lockedAt) {
        item.setGoodsCodeSnapshot(snapshot.code());
        item.setGoodsNameSnapshot(snapshot.name());
        item.setGoodsSnapshotSource(snapshot.source());
        item.setGoodsSnapshotLockedAt(lockedAt);
    }

    private static void applyParentSnapshot(
            SubcontractMaterialIssueItem item,
            SubcontractGoodsSnapshot snapshot,
            OffsetDateTime lockedAt) {
        item.setParentGoodsCodeSnapshot(snapshot == null ? null : snapshot.code());
        item.setParentGoodsNameSnapshot(snapshot == null ? null : snapshot.name());
        item.setParentGoodsSnapshotSource(snapshot == null ? null : snapshot.source());
        item.setParentGoodsSnapshotLockedAt(snapshot == null ? null : lockedAt);
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
        return new MaterialIssueItemDto(it.getId(), it.getLineNo(), it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(), it.getGoodsSnapshotSource(),
                it.getGoodsSnapshotLockedAt(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getReturnedQty(), it.getWastedQty(), it.getOrderItemId(),
                it.getParentGoodsId(), it.getParentGoodsCodeSnapshot(), it.getParentGoodsNameSnapshot(),
                it.getParentGoodsSnapshotSource(), it.getParentGoodsSnapshotLockedAt(),
                it.getParentColorId(), it.getWeight(), it.getSourceDocNo(), it.getRemark(),
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
    private SubcontractMaterialIssue requireIssueForUpdate(UUID id) {
        SubcontractMaterialIssue issue = em.find(
                SubcontractMaterialIssue.class, id, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        return issue == null || issue.isDeleted()
                ? requireIssue(id)
                : issue;
    }
}
