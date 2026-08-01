package com.uten.imp.features.subcontract.waste;

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
import com.uten.imp.features.subcontract.waste.dto.WasteDetail;
import com.uten.imp.features.subcontract.waste.dto.WasteItemDto;
import com.uten.imp.features.subcontract.waste.dto.WasteItemLine;
import com.uten.imp.features.subcontract.waste.dto.WasteListItem;
import com.uten.imp.features.subcontract.waste.dto.WasteQueryFilter;
import com.uten.imp.features.subcontract.waste.dto.WasteSaveRequest;
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
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 委外材料损耗单服务：CRUD（主+明细）+ 审核状态机。
 *
 * <p>审核（status 0→1，同事务内，对每条明细）：
 * <ol>
 *   <li><b>回写 {@code subcontract_material_issue_items.wasted_qty += qty}</b>
 *       —— 新库补全老库 E_SWaste 触发器缺失的“损耗→冲减发料已发量”链路
 *       （design doc 22 §一决策6 / §六；老库仅写库存台账，未回写发料累计，新库 Service 闭环）</li>
 * </ol>
 * 发料审核已经把材料移出公司仓；供应商处损耗不得再次扣公司仓库存。
 * <b>不立应付</b>（损耗是加工过程损耗，不是加工费结算）。
 *
 * <p>红冲（1→-1）：回减 wasted_qty；仅对旧版本实际写过的公司仓
 * DIR_OUT 流水逐行补 DIR_IN（无 ArAp）。
 *
 * <p>注：wasted_qty 是子件维度的累计量（在发料明细上），不直接影响订货单 is_closed
 * （订货结案由 received/returned 决定，损耗仅是发料后的状态记录）。
 */
@Service
@RequiredArgsConstructor
public class SubcontractWasteService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（损耗无金额列，有总重数量列；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "totalWeight", "totalWeight");

    private final SubcontractWasteRepository wasteRepo;
    private final SubcontractWasteItemRepository itemRepo;
    private final StockService stockService;
    private final LinkedDocumentIntegrityService sourceIntegrity;
    private final TxSessionVars tx;
    private final EntityManager em;
    private final com.uten.imp.security.SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final DocNumberService docNumberService;

    @Transactional(readOnly = true)
    public PageResponse<WasteListItem> list(WasteQueryFilter f, int page, int size, String sort, String order) {
        Specification<SubcontractWaste> spec = (Root<SubcontractWaste> root,
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
        Page<SubcontractWaste> p = wasteRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public WasteDetail detail(UUID id) {
        SubcontractWaste r = requireWaste(id);
        List<WasteItemDto> items = itemRepo.findByWasteIdOrderByLineNoAsc(id).stream()
                .map(this::toItemDto).toList();
        return toDetail(r, items);
    }

    @Transactional
    public WasteDetail create(WasteSaveRequest req) {
        tx.bind();
        SubcontractWaste r = new SubcontractWaste();
        applyHeader(req, r);
        r.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
        r.setStatus(STATUS_DRAFT);
        wasteRepo.save(r);
        List<WasteItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public WasteDetail update(UUID id, WasteSaveRequest req) {
        tx.bind();
        SubcontractWaste r = requireWasteForUpdate(id);
        if (r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        applyHeader(req, r);
        itemRepo.deleteByWasteId(id);
        itemRepo.flush();
        List<WasteItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        SubcontractWaste r = requireWasteForUpdate(id);
        if (r.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        }
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        wasteRepo.save(r);
    }

    /**
     * 审核：0→1。<b>只回写 material_issue_items.wasted_qty</b>。
     * 发料时公司仓库存已扣减，供应商处损耗不得再次扣公司仓。
     * 不立应付（损耗不是加工费）。不影响订货 is_closed（损耗是发料后状态，非成品维度）。
     */
    @Transactional
    public WasteDetail approve(UUID id) {
        tx.bind();
        SubcontractWaste r = requireWasteForUpdate(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (r.getWarehouseId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "损耗单需指定仓库");
        }
        List<SubcontractWasteItem> items = itemRepo.findByWasteIdOrderByLineNoAsc(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        }
        sourceIntegrity.validateSubcontractWaste(
                r.getSupplierId(),
                items.stream()
                        .map(it -> LinkedDocumentIntegrityService.LinkedLine.materialIssueSource(
                                it.getMaterialIssueItemId(),
                                null,
                                it.getGoodsId(),
                                it.getColorId(),
                                it.getUnitId(),
                                it.getUnitRate(),
                                null,
                                null))
                        .toList());
        for (SubcontractWasteItem it : items) {
            // 发料审核已经 DIR_OUT；损耗发生在供应商处，只核销在外料。
            if (it.getMaterialIssueItemId() != null) {
                em.createNativeQuery(
                        "UPDATE subcontract_material_issue_items SET wasted_qty = COALESCE(wasted_qty,0) + :q WHERE id = :id")
                        .setParameter("q", it.getQty())
                        .setParameter("id", it.getMaterialIssueItemId())
                        .executeUpdate();
            }
        }
        // 不立应付：损耗是加工过程损耗
        r.setStatus(STATUS_APPROVED);
        r.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        wasteRepo.save(r);
        return detail(id);
    }

    /**
     * 红冲：1→-1。新单仅回减 wasted_qty；历史版本若确实写过公司仓
     * DIR_OUT 流水，则逐行补一笔 DIR_IN，兼容历史且避免凭状态猜测。
     */
    @Transactional
    public WasteDetail reverse(UUID id) {
        tx.bind();
        SubcontractWaste r = requireWasteForUpdate(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        List<SubcontractWasteItem> items = itemRepo.findByWasteIdOrderByLineNoAsc(id);
        Set<UUID> historicalWarehouseOutItems = historicalWarehouseOutItems(id);
        if (!historicalWarehouseOutItems.isEmpty()) {
            stockService.lockInventory(items.stream()
                    .filter(it -> historicalWarehouseOutItems.contains(it.getId()))
                    .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                    .toList());
        }
        OffsetDateTime now = OffsetDateTime.now();
        for (SubcontractWasteItem it : items) {
            if (historicalWarehouseOutItems.contains(it.getId())) {
                applyMovement(r, it, StockService.DIR_IN, now, null);
            }
            if (it.getMaterialIssueItemId() != null) {
                em.createNativeQuery(
                        "UPDATE subcontract_material_issue_items SET wasted_qty = COALESCE(wasted_qty,0) - :q WHERE id = :id")
                        .setParameter("q", it.getQty())
                        .setParameter("id", it.getMaterialIssueItemId())
                        .executeUpdate();
            }
        }
        r.setStatus(STATUS_REVERSED);
        wasteRepo.save(r);
        return detail(id);
    }

    private Set<UUID> historicalWarehouseOutItems(UUID wasteId) {
        List<?> rows = em.createNativeQuery("""
                        SELECT DISTINCT source_item_id
                        FROM stock_movements
                        WHERE source_doc_type = :sourceDocType
                          AND source_doc_id = :sourceDocId
                          AND movement_type = :movementType
                          AND direction = :direction
                          AND source_item_id IS NOT NULL
                        """)
                .setParameter("sourceDocType", StockService.SRC_SUBCONTRACT_WASTE)
                .setParameter("sourceDocId", wasteId)
                .setParameter("movementType", StockService.TYPE_SUBCONTRACT_WASTE)
                .setParameter("direction", StockService.DIR_OUT)
                .getResultList();
        Set<UUID> ids = new HashSet<>();
        for (Object row : rows) {
            ids.add((UUID) row);
        }
        return ids;
    }

    /** 写一笔库存流水（方向由调用方给）。qty 为明细量，baseQty = qty×unit_rate。 */
    private void applyMovement(SubcontractWaste r, SubcontractWasteItem it, short direction,
                               OffsetDateTime ts, BigDecimal overrideAmount) {
        BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
        BigDecimal baseQty = it.getQty().multiply(rate);
        BigDecimal amt = overrideAmount != null ? overrideAmount : it.getAmountLocal();
        stockService.recordMovement(new StockService.MovementRequest(
                ts, StockService.TYPE_SUBCONTRACT_WASTE, StockService.SRC_SUBCONTRACT_WASTE,
                r.getId(), it.getId(), it.getGoodsId(), it.getColorId(), r.getWarehouseId(),
                direction, baseQty, it.getUnitId(), it.getUnitRate(), amt,
                direction < 0 ? null : "红冲"));
    }

    private void applyHeader(WasteSaveRequest req, SubcontractWaste r) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (r.getBillNo() == null || r.getBillNo().isBlank()) {
            r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.SUB_WASTE));
        }
        r.setBillDate(req.getBillDate());
        r.setSupplierId(req.getSupplierId());
        r.setWarehouseId(req.getWarehouseId());
        r.setWorkerId(req.getWorkerId());
        r.setTotalWeight(req.getTotalWeight());
        r.setRemark(req.getRemark());
    }

    private List<WasteItemDto> saveItems(SubcontractWaste r, List<WasteItemLine> lines) {
        List<WasteItemDto> out = new ArrayList<>(lines.size());
        int autoLine = 1;
        for (WasteItemLine l : lines) {
            SubcontractWasteItem it = new SubcontractWasteItem();
            it.setWasteId(r.getId());
            it.setBillNo(r.getBillNo());
            it.setBillDate(r.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : autoLine);
            it.setGoodsId(l.getGoodsId());
            it.setColorId(l.getColorId());
            it.setUnitId(l.getUnitId());
            it.setUnitRate(l.getUnitRate());
            it.setQty(l.getQty());
            it.setEndingQty(l.getEndingQty());
            it.setStandardQty(l.getStandardQty());
            it.setWasteRate(l.getWasteRate());
            it.setCause(l.getCause());
            it.setMaterialIssueItemId(l.getMaterialIssueItemId());
            it.setPrice(l.getPrice());
            it.setAmountOriginal(l.getAmountOriginal());
            it.setAmountLocal(l.getAmountLocal());
            it.setWeight(l.getWeight());
            it.setSourceDocNo(l.getSourceDocNo());
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            out.add(toItemDto(it));
            autoLine++;
        }
        return out;
    }

    private void applyTotals(SubcontractWaste r, List<WasteItemDto> items) {
        BigDecimal local = items.stream()
                .map(i -> i.getAmountLocal() == null ? BigDecimal.ZERO : i.getAmountLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = items.stream()
                .map(i -> i.getAmountOriginal() == null ? BigDecimal.ZERO : i.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal weight = items.stream()
                .map(i -> i.getWeight() == null ? BigDecimal.ZERO : i.getWeight())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        r.setTotalLocal(local);
        r.setTotalOriginal(original);
        // 若主表未传 totalWeight，按明细汇总回填（老库 Weight 主表汇总口径）
        if (r.getTotalWeight() == null) {
            r.setTotalWeight(weight);
        }
        wasteRepo.save(r);
    }

    private WasteListItem toList(SubcontractWaste r) {
        return new WasteListItem(r.getId(), r.getBillNo(), r.getBillDate(), r.getSupplierId(),
                r.getWarehouseId(), r.getTotalWeight(), r.getTotalLocal(), r.getStatus(), r.isClosed(), r.getLegacyId());
    }

    private WasteItemDto toItemDto(SubcontractWasteItem it) {
        return new WasteItemDto(it.getId(), it.getLineNo(), it.getGoodsId(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getEndingQty(), it.getStandardQty(),
                it.getWasteRate(), it.getCause(), it.getMaterialIssueItemId(), it.getPrice(),
                it.getAmountOriginal(), it.getAmountLocal(), it.getWeight(), it.getSourceDocNo(), it.getRemark());
    }

    private WasteDetail toDetail(SubcontractWaste r, List<WasteItemDto> items) {
        return new WasteDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getSupplierId(), r.getWarehouseId(), r.getWorkerId(), r.getMakerId(), r.getApproverId(),
                r.getTotalWeight(), r.getRemark(), r.getTotalOriginal(), r.getTotalLocal(), r.getStatus(),
                r.isClosed(), r.getSourceDocNo(), items,
                nameResolver.nameOf(r.getMakerId()), r.getCreatedAt());
    }

    private SubcontractWaste requireWaste(UUID id) {
        return wasteRepo.findById(id)
                .filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "委外损耗单不存在"));
    }
    private SubcontractWaste requireWasteForUpdate(UUID id) {
        SubcontractWaste waste = em.find(
                SubcontractWaste.class, id, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        return waste == null || waste.isDeleted()
                ? requireWaste(id)
                : waste;
    }
}
