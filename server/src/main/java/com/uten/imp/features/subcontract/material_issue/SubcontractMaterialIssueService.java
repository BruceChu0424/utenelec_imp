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
import com.uten.imp.security.CommercialPriceVisibility;
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
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Service;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * 委外出仓单服务：V436 目标件新流 + V304/V221 历史材料行兼容。
 *
 * <p>V436 计划行只发订货目标件，并先消费本 planItem/warehouse 的专属统一库存预留；
 * 无足额专属预留即失败。V221 供应商处台账继续记录发出、回仓消费、退回和损耗，
 * 新流冻结换算率以把回仓单据单位转换为目标件基本单位。历史
 * {@code LEGACY_BOM_COMPONENT} 行继续按冻结 BOM 子件口径处理。
 * <b>不立应付</b>（材料发出不是加工费结算，加工费走进仓单 BOM 成本）。无 Price（amount 可空）。
 *
 * <p>红冲（1→-1）：反向 DIR_IN + 置 status=-1；已有退料/损耗/回厂消费的发料行禁止红冲
 * （先红冲下游）。成品订货行上的历史 issued_qty 不再作为权威口径，也不继续改写。
 */
@Service
@RequiredArgsConstructor
public class SubcontractMaterialIssueService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;
    private static final String OUTBOUND_EXECUTE = "subcontract_outbound:execute";

    /** 列排序白名单：前端列 key → JPA 实体属性名（发料无金额列，仅日期可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate");

    private final SubcontractMaterialIssueRepository issueRepo;
    private final SubcontractMaterialIssueItemRepository itemRepo;
    private final StockService stockService;
    // V476：叶子仓落库校验。字段注入+可空——单测手工构造时缺省跳过，Spring 环境恒注入。
    @org.springframework.beans.factory.annotation.Autowired(required = false)
    private com.uten.imp.features.master.warehouse.WarehouseScopeService warehouseScopes;
    private final TxSessionVars tx;
    private final EntityManager em;
    private final com.uten.imp.security.SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final DocNumberService docNumberService;
    private final SubcontractDocumentAccessPolicy access;
    private final com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService planService;
    private final com.uten.imp.common.concurrency.ProcurementMutationLocks mutationLocks;

    @Autowired
    private CommercialPriceVisibility commercialPriceVisibility;

    /**
     * 写操作准入：自有手工单维持 maker 归属隔离；系统按发料计划生成的单据除当前动作权限外，
     * 还必须持有委外出仓 execute 权限，确保独立撤权对旧 CRUD 端点同样生效。
     *
     * @return 单据当前挂接的计划行 id；更新时也作为不可越权替换的允许集合
     */
    private Set<UUID> requireIssueWritable(SubcontractMaterialIssue r, String actionAuthority) {
        Set<UUID> planItemIds = planItemIds(r.getId());
        if (r.getMakerId() != null) {
            access.requireWritable(r.getMakerId(), "只能操作本人负责的委外材料出仓单");
        } else if (!access.hasAuthority(actionAuthority)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "缺少委外材料出仓单操作权限");
        }
        if (!planItemIds.isEmpty() && !access.hasAuthority(OUTBOUND_EXECUTE)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "缺少委外出仓执行权限");
        }
        return planItemIds;
    }

    private Set<UUID> planItemIds(UUID issueId) {
        Set<UUID> ids = new HashSet<>();
        for (SubcontractMaterialIssueItem item : itemRepo.findByIssueIdOrderByLineNoAsc(issueId)) {
            if (item.getPlanItemId() != null) {
                ids.add(item.getPlanItemId());
            }
        }
        return ids;
    }

    @Transactional(readOnly = true)
    public PageResponse<MaterialIssueListItem> list(MaterialIssueQueryFilter f, int page, int size, String sort, String order) {
        boolean priceMasked = subcontractPriceMasked();
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
        return new PageResponse<>(p.map(row -> toList(row, priceMasked)).getContent(),
                p);
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
    @PreAuthorize("hasAuthority('subcontract_material_issue:create')")
    public MaterialIssueDetail create(MaterialIssueSaveRequest req) {
        tx.bind();
        lockIssueRequest(null,req).verifyUnchanged();
        // 计划挂接单只能由计划服务生成；旧通用新建端点不得占用/伪造计划行。
        canonicalizePlanLines(req.getItems(), Set.of(), false);
        SubcontractMaterialIssue r = new SubcontractMaterialIssue();
        applyHeader(req, r);
        r.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
        canonicalizeMaker(r);
        r.setStatus(STATUS_DRAFT);
        issueRepo.save(r);
        List<MaterialIssueItemDto> items = saveItems(r, req.getItems());
        planService.reserveDraft(r.getId(), r.getWarehouseId());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('subcontract_material_issue:edit')")
    public MaterialIssueDetail update(UUID id, MaterialIssueSaveRequest req) {
        tx.bind();
        var mutationGuard=lockIssueRequest(id,req);
        SubcontractMaterialIssue r = requireIssueForUpdate(id);
        Set<UUID> existingPlanItemIds = requireIssueWritable(r, "subcontract_material_issue:edit");
        if (r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        mutationGuard.verifyUnchanged();
        canonicalizePlanLines(req.getItems(), existingPlanItemIds, !existingPlanItemIds.isEmpty());
        applyHeader(req, r);
        itemRepo.deleteByIssueId(id);
        itemRepo.flush();
        List<MaterialIssueItemDto> items = saveItems(r, req.getItems());
        planService.reserveDraft(r.getId(), r.getWarehouseId());
        applyTotals(r, items);
        return toDetail(r, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('subcontract_material_issue:delete')")
    public void delete(UUID id) {
        tx.bind();
        var mutationGuard=mutationLocks.materialIssue(id);
        SubcontractMaterialIssue r = requireIssueForUpdate(id);
        requireIssueWritable(r, "subcontract_material_issue:delete");
        com.uten.imp.common.web.StandardDocumentLifecycleCapabilities.requireDraftForDelete(r.getStatus());
        mutationGuard.verifyUnchanged();
        planService.releaseDraftReservations(id);
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        issueRepo.save(r);
    }

    private com.uten.imp.application.concurrency.FulfillmentMutationLocks.Guard lockIssueRequest(UUID id,MaterialIssueSaveRequest req) {
        List<MaterialIssueItemLine> lines=req==null||req.getItems()==null?List.of():req.getItems();
        return mutationLocks.materialIssueInputs(id,lines.stream().filter(Objects::nonNull).map(MaterialIssueItemLine::getOrderItemId).toList(),
                lines.stream().filter(Objects::nonNull).filter(line->line.getGoodsId()!=null)
                        .map(line->new com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension(line.getGoodsId(),line.getColorId())).toList(),
                req==null?null:req.getWarehouseId());
    }

    /**
     * 保存前置校验（计划挂接行）：绑定只能来自当前系统草稿；除数量外的库存键、单位、
     * 订货/父件关系全部以计划快照覆盖客户端值。审核时另有 CAS 兜底并发超发。
     */
    void canonicalizePlanLines(List<MaterialIssueItemLine> lines,
                               Set<UUID> allowedPlanItemIds,
                               boolean planBindingRequired) {
        if (planBindingRequired && (lines == null || lines.isEmpty())) {
            throw new ApiException(ErrorCode.CONFLICT, "计划生成的出仓草稿不可移除全部计划行");
        }
        if (lines == null) {
            return;
        }
        Set<UUID> seenPlanItemIds = new HashSet<>();
        for (MaterialIssueItemLine line : lines) {
            if (line.getPlanItemId() == null) {
                if (planBindingRequired) {
                    throw new ApiException(ErrorCode.CONFLICT, "计划生成的出仓明细不可移除计划行绑定");
                }
                continue;
            }
            if (!allowedPlanItemIds.contains(line.getPlanItemId())) {
                throw new ApiException(ErrorCode.CONFLICT, "出仓明细不可新增或替换发料计划行绑定");
            }
            if (!seenPlanItemIds.add(line.getPlanItemId())) {
                throw new ApiException(ErrorCode.CONFLICT, "同一发料计划行不可重复提交");
            }
            List<Object[]> rows = jdbcRows("""
                    SELECT pi.plan_id, pi.order_item_id,
                           pi.parent_goods_id, pi.parent_color_id,
                           pi.goods_id, pi.color_id, pi.unit_id, pi.unit_rate,
                           pi.planned_qty, pi.issued_qty, p.status
                    FROM subcontract_material_plan_items pi
                    JOIN subcontract_material_plans p ON p.id = pi.plan_id AND p.is_deleted = FALSE
                    WHERE pi.id = :id AND pi.is_deleted = FALSE
                    """, line.getPlanItemId());
            if (rows.isEmpty()) {
                throw new ApiException(ErrorCode.CONFLICT, "关联的委外发料计划行不存在，请刷新后重试");
            }
            Object[] row = rows.getFirst();
            if (!"OPEN".equals(row[10])) {
                throw new ApiException(ErrorCode.CONFLICT, "发料计划已关闭或取消，禁止挂接出仓");
            }
            BigDecimal remaining = decimal(row[8]).subtract(decimal(row[9]));
            if (line.getQty() == null || line.getQty().compareTo(remaining) > 0) {
                throw new ApiException(ErrorCode.CONFLICT, "出仓量超过发料计划余量(剩余 " + remaining.stripTrailingZeros().toPlainString() + ")");
            }
            // plan_item_id 是唯一客户端引用；库存键、单位及父件/订货关系全部以计划快照回填。
            line.setOrderItemId((UUID) row[1]);
            line.setParentGoodsId((UUID) row[2]);
            line.setParentColorId((UUID) row[3]);
            line.setGoodsId((UUID) row[4]);
            line.setColorId((UUID) row[5]);
            line.setUnitId((UUID) row[6]);
            line.setUnitRate((BigDecimal) row[7]);
        }
    }

    private List<Object[]> jdbcRows(String sql, UUID id) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = (List<Object[]>) em.createNativeQuery(sql)
                .setParameter("id", id).getResultList();
        return rows;
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : (BigDecimal) value;
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
    @PreAuthorize("hasAuthority('subcontract_material_issue:approve')")
    public MaterialIssueDetail approve(UUID id) {
        tx.bind();
        var mutationGuard=mutationLocks.materialIssue(id);
        SubcontractMaterialIssue r = requireIssueForUpdate(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        // 幂等/状态门禁只依赖已加锁的单据头，必须先于权限所需的计划明细读取，
        // 避免重复审核触碰任何明细，更不能重复产生库存移动。
        requireIssueWritable(r, "subcontract_material_issue:approve");
        mutationGuard.verifyUnchanged();
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
        lockAndValidateOrderItems(r, items);
        com.uten.imp.common.finance.ProcurementOrderQuantityBounds.requireConsistentTargetBasis(em,
                items.stream().map(SubcontractMaterialIssueItem::getOrderItemId).distinct().toList());
        captureGoodsSnapshots(
                items,
                SubcontractGoodsSnapshot.ORDER_ITEM_AT_APPROVAL,
                SubcontractGoodsSnapshot.MASTER_AT_APPROVAL,
                OffsetDateTime.now());
        stockService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        planService.consumeOutboundReservations(id, r.getWarehouseId());
        OffsetDateTime now = OffsetDateTime.now();
        for (SubcontractMaterialIssueItem it : items) {
            applyMovement(r, it, StockService.DIR_OUT, now, null);
            // 冻结 BOM 版本（每单位父件耗用本子件量）+ 建供应商处子件台账（at_supplier = 发料量）。
            // 计划挂接行冻结批准时计划的 bom_unit_qty（与计划量同快照，BOM 后改不影响在途守恒）；
            // 历史手工行回落当前 goods_bom_items 首条活动边。
            it.setAtSupplierQty(it.getQty());
            it.setFrozenUnitQty(it.getPlanItemId() != null
                    ? planUnitQty(it.getPlanItemId())
                    : lookupFrozenUnitQty(it.getParentGoodsId(), it.getGoodsId()));
            itemRepo.save(it);
        }
        r.setStatus(STATUS_APPROVED);
        r.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        canonicalizeApprover(r);
        issueRepo.save(r);
        // 计划回写（同事务）：issued_qty += 本次出仓量（CAS 防超计划）；分批余量自动续生草稿。
        planService.syncAfterIssueApproved(id);
        return detail(id);
    }

    /** 计划行的冻结单耗（批准时 BOM 快照）。 */
    private BigDecimal planUnitQty(UUID planItemId) {
        List<?> rows = em.createNativeQuery("""
                SELECT bom_unit_qty FROM subcontract_material_plan_items
                WHERE id = :id AND is_deleted = FALSE
                """).setParameter("id", planItemId).getResultList();
        return rows.isEmpty() ? null : (BigDecimal) rows.getFirst();
    }

    /**
     * 审核前置：锁定并校验全部来源委外订货明细（fail-closed）。
     *
     * <ul>
     *   <li>订货明细存在且未删除；来源订货单已财务批准（status=1，才有权威 BOM 供给承诺）；</li>
     *   <li>订货单委外商与发料单委外商一致（防止把 A 商的料发给 B 商）；</li>
     *   <li>发料父件（parent_goods_id）与订货明细货品一致（parentGoodsId 是客户端值，
     *       不校验则冻结 BOM 会按错误父件查询单耗）。</li>
     * </ul>
     * FOR UPDATE 锁订货明细与头，防止审核期间订货单被红冲/改删。
     */
    private void lockAndValidateOrderItems(SubcontractMaterialIssue issue, List<SubcontractMaterialIssueItem> items) {
        List<UUID> orderItemIds = items.stream()
                .map(SubcontractMaterialIssueItem::getOrderItemId).distinct().toList();
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT soi.id, so.supplier_id, so.status, soi.goods_id
                        FROM subcontract_order_items soi
                        JOIN subcontract_orders so ON so.id = soi.order_id
                        WHERE soi.id IN (:ids)
                          AND COALESCE(soi.is_deleted, false) = false
                          AND COALESCE(so.is_deleted, false) = false
                        ORDER BY soi.id
                        FOR UPDATE OF soi, so
                        """)
                .setParameter("ids", orderItemIds)
                .getResultList();
        Map<UUID, Object[]> byId = new java.util.HashMap<>();
        rows.forEach(row -> byId.put((UUID) row[0], row));
        for (SubcontractMaterialIssueItem it : items) {
            Object[] source = byId.get(it.getOrderItemId());
            if (source == null) {
                throw new ApiException(ErrorCode.NOT_FOUND, "委外发料关联的订货明细不存在或已删除");
            }
            if (source[2] == null || ((Number) source[2]).intValue() != 1) {
                throw new ApiException(ErrorCode.BUSINESS, "委外发料只能关联已财务批准(status=1)的委外订货明细");
            }
            if (!java.util.Objects.equals((UUID) source[1], issue.getSupplierId())) {
                throw new ApiException(ErrorCode.BUSINESS, "发料单委外商与来源订货单委外商不一致");
            }
            if (!java.util.Objects.equals((UUID) source[3], it.getParentGoodsId())) {
                throw new ApiException(ErrorCode.BUSINESS, "发料父件与订货明细货品不一致，无法按 BOM 守恒消费");
            }
        }
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

    /** 红冲：1→-1。反向 DIR_IN + 计划 issued 对称回减；不再改写成品行 legacy issued_qty（无 ArAp）。 */
    @Transactional
    @PreAuthorize("hasAuthority('subcontract_material_issue:reverse')")
    public MaterialIssueDetail reverse(UUID id) {
        tx.bind();
        var mutationGuard=mutationLocks.materialIssue(id);
        SubcontractMaterialIssue r = requireIssueForUpdate(id);
        requireIssueWritable(r, "subcontract_material_issue:reverse");
        mutationGuard.verifyUnchanged();
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        List<SubcontractMaterialIssueItem> items = itemRepo.findByIssueIdOrderByLineNoAsc(id);
        if (items.stream().anyMatch(it ->
                positive(it.getReturnedQty()) || positive(it.getWastedQty())
                        || positive(it.getConsumedQty()))) {
            throw new ApiException(ErrorCode.BUSINESS, "委外发料已有退料/损耗/回厂消费记录，请先红冲下游单据");
        }
        requireReturnCapacityAfterReverse(id, items);
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
        planService.reverseOutboundReservations(id);
        r.setStatus(STATUS_REVERSED);
        issueRepo.save(r);
        // 计划回写（同事务）：issued_qty -= 红冲量；不自动补草稿（工作台「补齐出仓单」）。
        planService.syncAfterIssueReversed(id);
        return detail(id);
    }

    /**
     * 与回厂草稿 create/update 共用订货明细行锁。红冲后剩余的真实出仓 + 合法返修
     * 容量必须仍覆盖已审核回厂和活动草稿；有其它批次足额覆盖时不做无条件阻断。
     */
    private void requireReturnCapacityAfterReverse(
            UUID issueId, List<SubcontractMaterialIssueItem> items) {
        List<UUID> orderItemIds = items.stream()
                .map(SubcontractMaterialIssueItem::getOrderItemId)
                .filter(Objects::nonNull)
                .distinct()
                .sorted()
                .toList();
        if (orderItemIds.isEmpty()) return;
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT order_item.id,
                       EXISTS (
                           SELECT 1
                           FROM subcontract_material_plan_items plan_item
                           WHERE plan_item.order_item_id = order_item.id
                             AND plan_item.flow_mode IN (
                                 'DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
                             AND plan_item.is_deleted = FALSE
                       ) AS new_flow,
                       COALESCE((
                           SELECT SUM(issue_item.qty * COALESCE(issue_item.unit_rate, 1))
                           FROM subcontract_material_issue_items issue_item
                           JOIN subcontract_material_issues issue
                             ON issue.id = issue_item.issue_id
                            AND issue.status = 1
                            AND issue.is_deleted = FALSE
                           JOIN subcontract_material_plan_items plan_item
                             ON plan_item.id = issue_item.plan_item_id
                            AND plan_item.flow_mode IN (
                                'DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND')
                            AND plan_item.is_deleted = FALSE
                           WHERE issue_item.order_item_id = order_item.id
                             AND issue_item.issue_id <> :issueId
                             AND issue_item.is_deleted = FALSE
                       ), 0)
                       + COALESCE((
                           SELECT SUM(rejection.failed_base_qty)
                           FROM procurement_iqc_rejection_cases rejection
                           WHERE rejection.receipt_type = 'SUBCONTRACT'
                             AND rejection.order_item_id = order_item.id
                             AND rejection.is_deleted = FALSE
                             AND rejection.return_recorded_at IS NOT NULL
                             AND rejection.status IN (
                                 'RETURN_RECORDED','CREDIT_CONFIRMED',
                                 'CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
                       ), 0) AS authorized_base_after_reverse,
                       COALESCE((
                           SELECT SUM(receipt_item.qty * COALESCE(receipt_item.unit_rate, 1))
                           FROM subcontract_receipt_items receipt_item
                           JOIN subcontract_receipts receipt
                             ON receipt.id = receipt_item.receipt_id
                            AND receipt.status IN (0, 1)
                            AND receipt.is_deleted = FALSE
                           WHERE receipt_item.order_item_id = order_item.id
                             AND receipt_item.is_deleted = FALSE
                       ), 0) AS claimed_base
                FROM subcontract_order_items order_item
                WHERE order_item.id IN (:orderItemIds)
                  AND COALESCE(order_item.is_deleted, FALSE) = FALSE
                ORDER BY order_item.id
                FOR UPDATE OF order_item
                """).setParameter("issueId", issueId)
                .setParameter("orderItemIds", orderItemIds)
                .getResultList();
        if (rows.size() != orderItemIds.size()) {
            throw new ApiException(ErrorCode.CONFLICT, "委外出仓来源订货明细不存在或已删除");
        }
        for (Object[] row : rows) {
            if (!Boolean.TRUE.equals(row[1])) continue;
            if (decimal(row[3]).compareTo(decimal(row[2])) > 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "红冲后目标件真实出仓额度不足以覆盖已审核或草稿回厂，请先处理下游回厂单");
            }
        }
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
                direction < 0 ? null : "红冲", it.getWeight()));
    }

    private void applyHeader(MaterialIssueSaveRequest req, SubcontractMaterialIssue r) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (r.getBillNo() == null || r.getBillNo().isBlank()) {
            r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.SUB_MATERIAL_ISSUE));
        }
        r.setBillDate(req.getBillDate());
        r.setSupplierId(req.getSupplierId());
        // V476 运营红线：委外发料出仓必须落到具体叶子仓；主仓库只作查询聚合。
        if (warehouseScopes != null) {
            warehouseScopes.requireNewLeafSelection(r.getWarehouseId(), req.getWarehouseId(), "发出仓库");
        }
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
            it.setPlanItemId(l.getPlanItemId());
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

    private MaterialIssueListItem toList(SubcontractMaterialIssue r, boolean priceMasked) {
        return new MaterialIssueListItem(r.getId(), r.getBillNo(), r.getBillDate(), r.getSupplierId(),
                r.getWarehouseId(), priceMasked ? null : r.getTotalLocal(), r.getStatus(),
                r.isClosed(), r.getLegacyId(), priceMasked);
    }

    private MaterialIssueItemDto toItemDto(SubcontractMaterialIssueItem it) {
        return new MaterialIssueItemDto(it.getId(), it.getLineNo(), it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(), it.getGoodsSnapshotSource(),
                it.getGoodsSnapshotLockedAt(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getReturnedQty(), it.getWastedQty(),
                it.getAtSupplierQty(), it.getConsumedQty(), it.getFrozenUnitQty(),
                it.getOrderItemId(), it.getPlanItemId(),
                it.getParentGoodsId(), it.getParentGoodsCodeSnapshot(), it.getParentGoodsNameSnapshot(),
                it.getParentGoodsSnapshotSource(), it.getParentGoodsSnapshotLockedAt(),
                it.getParentColorId(), it.getWeight(), it.getSourceDocNo(), it.getRemark(),
                it.getBoxQty(), it.getReturnNo(), it.getOrderNo());
    }

    private MaterialIssueDetail toDetail(SubcontractMaterialIssue r, List<MaterialIssueItemDto> items) {
        boolean priceMasked = subcontractPriceMasked();
        List<MaterialIssueItemDto> safeItems = priceMasked
                ? items.stream().map(SubcontractMaterialIssueService::maskItemPrices).toList()
                : items;
        return new MaterialIssueDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getSupplierId(), r.getWarehouseId(), r.getWorkerId(), r.getMakerId(), r.getApproverId(),
                r.getDeliverDate(), r.getRemark(), priceMasked ? null : r.getTotalOriginal(),
                priceMasked ? null : r.getTotalLocal(), r.getStatus(),
                r.isClosed(), r.getSourceDocNo(), safeItems, r.getOperatorLegacyId(), r.getOperatorName(),
                r.getMakerLegacyId(),
                (r.getMakerName() != null && !r.getMakerName().isBlank()) ? r.getMakerName() : nameResolver.nameOf(r.getMakerId()),
                r.getApproverLegacyId(), r.getApproverName(), r.getCreatedAt(), priceMasked);
    }

    private boolean subcontractPriceMasked() {
        return commercialPriceVisibility == null
                || !commercialPriceVisibility.canViewSubcontractMaterialCost();
    }

    private static MaterialIssueItemDto maskItemPrices(MaterialIssueItemDto it) {
        return new MaterialIssueItemDto(it.getId(), it.getLineNo(), it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(), it.getGoodsSnapshotSource(),
                it.getGoodsSnapshotLockedAt(), it.getColorId(), it.getUnitId(), it.getUnitRate(),
                it.getQty(), null, null, null, it.getReturnedQty(), it.getWastedQty(),
                it.getAtSupplierQty(), it.getConsumedQty(), it.getFrozenUnitQty(), it.getOrderItemId(),
                it.getPlanItemId(), it.getParentGoodsId(), it.getParentGoodsCodeSnapshot(),
                it.getParentGoodsNameSnapshot(), it.getParentGoodsSnapshotSource(),
                it.getParentGoodsSnapshotLockedAt(), it.getParentColorId(), it.getWeight(),
                it.getSourceDocNo(), it.getRemark(), it.getBoxQty(), it.getReturnNo(), it.getOrderNo());
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
