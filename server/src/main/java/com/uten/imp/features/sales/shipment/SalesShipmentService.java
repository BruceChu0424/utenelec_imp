package com.uten.imp.features.sales.shipment;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.SettlementMethodReferenceResolver;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.finance.arap.ArApLedgerService.ArApPostingRequest;
import com.uten.imp.features.finance.arap.ArApLedgerService.SourceRef;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.SalesGoodsSnapshot;
import com.uten.imp.features.sales.order.SalesOrder;
import com.uten.imp.features.sales.order.SalesPriceMasker;
import com.uten.imp.features.sales.shipment.dto.ShipmentDetail;
import com.uten.imp.features.sales.shipment.dto.ShipmentItemDto;
import com.uten.imp.features.sales.shipment.dto.ShipmentItemLine;
import com.uten.imp.features.sales.shipment.dto.ShipmentListItem;
import com.uten.imp.features.sales.shipment.dto.ShipmentQueryFilter;
import com.uten.imp.features.sales.shipment.dto.ShipmentSaveRequest;
import com.uten.imp.features.stock.StockReservation;
import com.uten.imp.features.stock.StockReservationService;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.StockService;
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
import org.springframework.security.access.prepost.PreAuthorize;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.DateTimeException;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.TreeSet;
import java.util.UUID;

/**
 * 销售出货单服务：CRUD（主+明细）+ 审核状态机（库存 + 订单回写 + 立应收 + 结案）。
 *
 * <p>审核（status 0→1）同事务内：
 * <ol>
 *   <li>挂单行超发硬校验（未发余量；链上行还须 ≤ 预留量）</li>
 *   <li>消耗库存软预留（FIFO + 行锁，全局预留改绑出货仓）</li>
 *   <li>逐明细 {@link StockService#recordMovement} 出库（TYPE_SALES_OUT / DIR_OUT）</li>
 *   <li>回写 sales_order_items.shipped_qty += qty、reserved_qty -= qty、chain_status 推进 8/9（order_item_id 非空时）</li>
 *   <li>{@link ArApLedgerService#postArAp} 立应收（AR, SALES_SHIPMENT, BStyle=3, 正应收）</li>
 *   <li>ar_posted=true</li>
 *   <li>重算受影响订货单 is_closed</li>
 * </ol>
 *
 * <p>红冲（1→-1）同事务反向：先 {@link ArApLedgerService#reverseArAp}（钱流校验无收款核销，否则抛
 * "此单已经存在收款，请先反审收款单!"，对齐老库 RAISERROR）→ 反向库存 + 回减 shipped_qty
 * + 链上行重新挂预留（绑原出货仓，货回库恢复可发货）+ 结案重算 + ar_posted=false。
 *
 * <p>处理库存段 + 钱流立 M_in 段（design 20 §〇/§4.3）。
 */
@Service
@RequiredArgsConstructor
public class SalesShipmentService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 老库 BStyle=3 销售出货正应收。 */
    private static final short BSTYLE_SALES_SHIPMENT = 3;
    private static final String FINANCE_AUDIT_AUTHORITY = "finance_shipment_audit";
    private static final String REJECT_AUTHORITY = "sales_shipment:reject";
    private static final String WAREHOUSE_WORK_AUTHORITY = "sales_shipment:warehouse-work";
    private static final String SETTLEMENT_ROLE_CASH = "CASH";
    private static final int MONEY_SCALE = 4;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "total", "totalLocal");

    private final SalesShipmentRepository shipmentRepo;
    private final SalesShipmentItemRepository itemRepo;
    private final StockService stockService;
    private final StockReservationService reservationService;
    private final ArApLedgerService arApService;
    private final TxSessionVars tx;
    private final EntityManager em;
    private final DocNumberService docNumberService;
    private final SalesDocumentAccessPolicy accessPolicy;
    private final com.uten.imp.security.SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final com.uten.imp.features.notice.ChainNoticeService chainNotice;

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_shipment:view')")
    public PageResponse<ShipmentListItem> list(ShipmentQueryFilter f, int page, int size, String sort, String order) {
        var readScope = accessPolicy.scope(
                FINANCE_AUDIT_AUTHORITY, REJECT_AUTHORITY, WAREHOUSE_WORK_AUTHORITY);
        Specification<SalesShipment> spec = (Root<SalesShipment> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                             CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            ps.add(accessPolicy.readablePredicate(root, cb, "ownerEmployeeId", readScope));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                String kw = "%" + f.keyword().toLowerCase() + "%";
                // 关键字同时匹配 单据号 / 客户名称（日常检索按客户找单）
                jakarta.persistence.criteria.Subquery<java.util.UUID> cs = q.subquery(java.util.UUID.class);
                Root<com.uten.imp.features.master.client.Client> cr =
                        cs.from(com.uten.imp.features.master.client.Client.class);
                cs.select(cr.get("id")).where(cb.isFalse(cr.get("deleted")),
                        cb.like(cb.lower(cr.get("name")), kw));
                ps.add(cb.or(cb.like(cb.lower(root.get("billNo")), kw),
                        root.get("clientId").in(cs)));
            }
            if (f.clientId() != null) ps.add(cb.equal(root.get("clientId"), f.clientId()));
            if (f.warehouseId() != null) ps.add(cb.equal(root.get("warehouseId"), f.warehouseId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.arPosted() != null) ps.add(cb.equal(root.get("arPosted"), f.arPosted()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<SalesShipment> p = shipmentRepo.findAll(spec, pageable);
        boolean canEdit = accessPolicy.hasAuthority("sales_shipment:edit");
        boolean hasRejectAuthority = accessPolicy.hasAuthority(REJECT_AUTHORITY);
        boolean hasWarehouseAuthority = accessPolicy.hasAuthority(WAREHOUSE_WORK_AUTHORITY);
        var writeScope = canEdit ? accessPolicy.scope() : null;
        var rejectScope = hasRejectAuthority ? accessPolicy.scope(REJECT_AUTHORITY) : null;
        var warehouseScope = hasWarehouseAuthority
                ? accessPolicy.scope(WAREHOUSE_WORK_AUTHORITY) : null;
        return new PageResponse<>(p.map(s -> toList(
                        s,
                        canEdit && accessPolicy.canWrite(s.getOwnerEmployeeId(), writeScope),
                        hasRejectAuthority && isRejectableState(s)
                                && accessPolicy.canWrite(s.getOwnerEmployeeId(), rejectScope),
                        hasWarehouseAuthority
                                && isWarehouseManageableState(s)
                                && accessPolicy.canWrite(
                                        s.getOwnerEmployeeId(), warehouseScope))).getContent(),
                page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_shipment:view')")
    public ShipmentDetail detail(UUID id) {
        SalesShipment s = requireReadableShipment(id);
        List<SalesShipmentItem> entities = itemRepo.findByShipmentIdOrderByLineNoAsc(id);
        Set<UUID> readableOrderItems = readableOrderItemIds(entities.stream()
                .map(SalesShipmentItem::getOrderItemId).filter(Objects::nonNull).toList());
        List<ShipmentItemDto> items = entities.stream()
                .map(item -> toItemDto(item,
                        item.getOrderItemId() == null
                                || readableOrderItems.contains(item.getOrderItemId())))
                .toList();
        boolean headerSourceReadable = isOrderSourceReadable(s.getSourceOrderId());
        return toDetail(s, items, headerSourceReadable);
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_shipment:edit')")
    public ShipmentDetail create(ShipmentSaveRequest req) {
        tx.bind();
        requireOrderLinkedNewShipment(req);
        lockAndValidateDraftAllocation(req, null, true);
        LinkedSource source = validateLinkedOrderItems(req);
        assertShipmentPolicy(req);
        SalesShipment s = new SalesShipment();
        applyHeader(req, s);
        applySource(s, source);
        s.setOwnerEmployeeId(accessPolicy.ownerForNewDocument(source.ownerEmployeeId()));
        s.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
        s.setStatus(STATUS_DRAFT);
        s.setWarehouseWorkStatus(SalesShipment.WORK_PENDING_PICK);
        s.setWarehouseWorkUpdatedAt(OffsetDateTime.now());
        s.setWarehouseWorkUpdatedBy(currentUser.requireEmployeeId());
        shipmentRepo.save(s);
        List<ShipmentItemDto> items = saveItems(s, req.getItems());
        applyTotals(s, items);
        recordWarehouseEvent(
                s, null, SalesShipment.WORK_PENDING_PICK,
                "创建待拣货任务", currentUser.requireEmployeeId(),
                OffsetDateTime.now());
        chainNotice.notifyShipmentPendingPick(s.getId());
        return toDetail(s, items, true);
    }

    /**
     * 批量发货开单（SOP §一9）：按客户、归属人与商业条款分组，同组才合并一张出货草稿。
     * 逐行硬校验：订单行必须当前仍有可发预留（reserved>0）且本次数量不超预留；
     * 归属隔离与订单列表同口径（不可见归属的行直接拒绝）。
     * 草稿占用订单的可发分配额度，但不重复减少 ATP、也不扣在手；
     * 仓库开始拣货才进入实物作业边界，交接出库时再消费预留并扣库存。
     */
    @Transactional
    @PreAuthorize("hasAuthority('sales_shipment:edit')")
    public List<ShipmentDetail> batchCreate(com.uten.imp.features.sales.shipment.dto.BatchShipRequest req) {
        tx.bind();
        if (req.getLines() == null || req.getLines().isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "未选择发货行");
        }
        // 取订单行 + 订单头（客户/币种/归属）；IN 查询一次性取回
        List<UUID> ids = req.getLines().stream()
                .map(com.uten.imp.features.sales.shipment.dto.BatchShipRequest.Line::getOrderItemId).toList();
        if (Set.copyOf(ids).size() != ids.size()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "批量发货不能重复选择同一订单行");
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT i.id, i.goods_id, i.color_id, i.unit_id, i.unit_rate,
                       i.price, i.reserved_qty,
                       o.client_id, o.currency_id, o.bill_no,
                       o.owner_employee_id, o.status, o.is_stopped, o.is_closed,
                       o.tax_rate, o.payment_style_id, o.seller_id, o.id,
                       o.settlement_method_id
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                WHERE i.id IN (:ids) AND COALESCE(i.is_deleted,false) = false AND COALESCE(o.is_deleted,false) = false
                """).setParameter("ids", ids).getResultList();
        Map<UUID, Object[]> byId = new HashMap<>();
        for (Object[] r : rows) byId.put((UUID) r[0], r);

        var writeScope = accessPolicy.scope();
        // 分组键包含客户、原始 owner 与所有会影响应收的商业条款。
        Map<BatchGroupKey, List<ShipmentItemLine>> grouped = new LinkedHashMap<>();
        Map<BatchGroupKey, CommercialTerms> termsByGroup = new HashMap<>();
        for (var line : req.getLines()) {
            Object[] r = byId.get(line.getOrderItemId());
            if (r == null) {
                throw new ApiException(ErrorCode.BUSINESS, "订单行不存在或已删除：" + line.getOrderItemId());
            }
            BigDecimal reserved = r[6] instanceof BigDecimal b ? b : BigDecimal.ZERO;
            if (line.getQty() == null || line.getQty().signum() <= 0) {
                throw new ApiException(ErrorCode.BUSINESS, "本次数量必须大于 0（订单 " + r[9] + "）");
            }
            if (reserved.signum() <= 0 || line.getQty().compareTo(reserved) > 0) {
                throw new ApiException(ErrorCode.BUSINESS,
                        "订单 " + r[9] + " 可发预留不足（可发 " + reserved.stripTrailingZeros().toPlainString() + "），请刷新后重试");
            }
            if (((Number) r[11]).shortValue() != 1 || (boolean) r[12] || (boolean) r[13]) {
                throw new ApiException(ErrorCode.BUSINESS, "订单 " + r[9] + " 非已审在途状态，不可发货");
            }
            UUID owner = (UUID) r[10];
            accessPolicy.requireWritable(owner, "只能对本人负责的销售订单批量发货", writeScope);
            ShipmentItemLine l = new ShipmentItemLine();
            l.setOrderItemId(line.getOrderItemId());
            l.setGoodsId((UUID) r[1]);
            l.setColorId((UUID) r[2]);
            l.setUnitId((UUID) r[3]);
            l.setUnitRate((BigDecimal) r[4]);
            l.setQty(line.getQty());
            l.setPrice((BigDecimal) r[5]);
            l.setSourceDocNo((String) r[9]);
            Integer paymentStyle = r[15] == null
                    ? null : ((Number) r[15]).intValue();
            CommercialTerms terms = new CommercialTerms(
                    (UUID) r[8], (BigDecimal) r[14],
                    paymentStyle, (UUID) r[18], (UUID) r[16]);
            BatchGroupKey key = new BatchGroupKey(
                    (UUID) r[7], owner, terms.currencyId(),
                    normalizedDecimalKey(terms.taxRate()),
                    terms.paymentStyleId(), terms.settlementMethodId(),
                    terms.sellerId(), (UUID) r[17]);
            grouped.computeIfAbsent(key, ignored -> new ArrayList<>()).add(l);
            termsByGroup.putIfAbsent(key, terms);
        }

        List<ShipmentDetail> out = new ArrayList<>(grouped.size());
        for (var e : grouped.entrySet()) {
            ShipmentSaveRequest one = new ShipmentSaveRequest();
            one.setBillDate(req.getBillDate());
            one.setClientId(e.getKey().clientId());
            one.setWarehouseId(req.getWarehouseId());
            CommercialTerms terms = termsByGroup.get(e.getKey());
            one.setCurrencyId(terms.currencyId());
            one.setExchangeRate(null);
            one.setTaxRate(terms.taxRate());
            one.setPaymentStyleId(terms.paymentStyleId());
            one.setSettlementMethodId(terms.settlementMethodId());
            one.setSellerId(terms.sellerId());
            one.setRemark(req.getRemark() == null || req.getRemark().isBlank()
                    ? "批量发货开单" : req.getRemark());
            int lineNo = 1;
            for (ShipmentItemLine l : e.getValue()) l.setLineNo(lineNo++);
            one.setItems(e.getValue());
            out.add(create(one));
        }
        return out;
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_shipment:edit')")
    public ShipmentDetail update(UUID id, ShipmentSaveRequest req) {
        tx.bind();
        SalesShipment s = requireWritableShipmentForUpdate(id);
        if (s.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        if (s.isRejected()) {
            throw new ApiException(ErrorCode.BUSINESS, "已驳回的出货单不可编辑，请删除后重新开单");
        }
        requireFinanceAuditClearedForMutation(s);
        if (!isEditableState(s)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "仓库已开始拣货或单据处于异常处理，出货单不可直接编辑");
        }
        if (SalesShipment.WORK_PENDING_PICK.equals(s.getWarehouseWorkStatus())) {
            requireOrderLinkedNewShipment(req);
        }
        lockAndValidateDraftAllocation(
                req, id,
                SalesShipment.WORK_PENDING_PICK.equals(
                        s.getWarehouseWorkStatus()));
        LinkedSource source = validateLinkedOrderItems(req);
        assertShipmentPolicy(req);
        if (source.present() && !Objects.equals(source.ownerEmployeeId(), s.getOwnerEmployeeId())) {
            throw new ApiException(ErrorCode.CONFLICT, "来源订单与出货单归属不一致");
        }
        applyHeader(req, s);
        applySource(s, source);
        itemRepo.deleteByShipmentId(id);
        itemRepo.flush();
        List<ShipmentItemDto> items = saveItems(s, req.getItems());
        applyTotals(s, items);
        return toDetail(s, items, true);
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_shipment:edit')")
    public void delete(UUID id) {
        tx.bind();
        SalesShipment s = requireWritableShipmentForUpdate(id);
        if (s.getStatus() == null || s.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "只有草稿或已驳回草稿可删除；已出库单据必须保留历史");
        }
        requireFinanceAuditClearedForMutation(s);
        if (!SalesShipment.WORK_PENDING_PICK.equals(s.getWarehouseWorkStatus())
                && !SalesShipment.WORK_LEGACY_PENDING.equals(s.getWarehouseWorkStatus())
                && !SalesShipment.WORK_CANCELLED.equals(s.getWarehouseWorkStatus())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "仓库作业已开始或仍在异常处理；须先完成退拣并恢复待拣货，才可删除");
        }
        String fromStatus = s.getWarehouseWorkStatus();
        OffsetDateTime now = OffsetDateTime.now();
        UUID actor = currentUser.requireEmployeeId();
        s.setWarehouseWorkStatus(SalesShipment.WORK_CANCELLED);
        s.setWarehouseWorkUpdatedAt(now);
        s.setWarehouseWorkUpdatedBy(actor);
        s.setDeleted(true);
        s.setDeletedAt(now);
        shipmentRepo.save(s);
        recordWarehouseEvent(
                s, fromStatus, SalesShipment.WORK_CANCELLED,
                "销售删除未出库草稿", actor, now);
    }

    // ======================== C6 财务发货审核 ========================

    /** 现金结算由 UUID 主档的不可变 CASH system role 决定；旧整数不参与判断。 */
    private void assertFinanceAudited(SalesShipment s) {
        ClientSettlementDefaults defaults = loadClientSettlementDefaults(
                s.getClientId(), false);
        var method = resolveEffectiveSettlementMethod(s, defaults);
        assertFinanceAudited(s, isCashSettlement(method));
    }

    private void assertFinanceAudited(SalesShipment s, boolean cash) {
        if (cash && (s.getFinanceAudit() == null || s.getFinanceAudit() != 1)) {
            throw new ApiException(ErrorCode.BUSINESS, "现金结算客户须财务审核发货后再审核出货单");
        }
    }

    /** 财务审核发货：现金结算=查到款后审（审核人自行核对收款，接口返回客户未收余额辅助）；
     *  月结等其它结算=直接审。草稿/已审单据均可审（已审出货单不再允许反审）。 */
    @Transactional
    @PreAuthorize("hasAuthority('finance_shipment_audit')")
    public Map<String, Object> financeAudit(UUID id) {
        tx.bind();
        SalesShipment s = requireWritableShipmentForUpdate(id, FINANCE_AUDIT_AUTHORITY);
        requireFinanceAuditEditableState(s);
        if (s.getFinanceAudit() != null && s.getFinanceAudit() == 1) {
            throw new ApiException(ErrorCode.BUSINESS, "已财务审核，请勿重复操作");
        }
        List<SalesShipmentItem> items =
                itemRepo.findByShipmentIdOrderByLineNoAsc(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可财务审核");
        }
        lockStoredOrderTargets(items);
        assertStoredOrderLinks(s, items, true, FINANCE_AUDIT_AUTHORITY);
        requireNonNegativeStoredCommercial(items);
        requireNonNegativeTotals(s);
        s.setFinanceAudit((short) 1);
        s.setFinanceAuditorId(currentUser.requireId());
        s.setFinanceAuditedAt(OffsetDateTime.now());
        shipmentRepo.save(s);
        return financeAuditInfo(s);
    }

    /** 财务反审：仅未审核出货（status=0）的单据可回退财务审核。 */
    @Transactional
    @PreAuthorize("hasAuthority('finance_shipment_audit')")
    public Map<String, Object> financeAuditReverse(UUID id) {
        tx.bind();
        SalesShipment s = requireWritableShipmentForUpdate(id, FINANCE_AUDIT_AUTHORITY);
        requireFinanceAuditEditableState(s);
        s.setFinanceAudit((short) 0);
        s.setFinanceAuditorId(null);
        s.setFinanceAuditedAt(null);
        shipmentRepo.save(s);
        return financeAuditInfo(s);
    }

    /** 财务审核辅助信息：结算方式 + 客户未收余额（立帐−收款）。 */
    private Map<String, Object> financeAuditInfo(SalesShipment s) {
        ClientSettlementDefaults defaults = loadClientSettlementDefaults(
                s.getClientId(), false);
        var method = resolveEffectiveSettlementMethod(s, defaults);
        Object[] c = (Object[]) em.createNativeQuery("""
                SELECT c.name,
                       (SELECT COALESCE(SUM(CASE WHEN l.direction='AR' THEN l.amount_original_local ELSE 0 END),0)
                        FROM ar_ap_ledger l WHERE l.client_id=c.id AND l.is_deleted=false AND l.status=1)
                       - (SELECT COALESCE(SUM(r.amount_local),0)
                        FROM finance_receipts r WHERE r.client_id=c.id AND COALESCE(r.is_deleted,false)=false AND r.status=1)
                FROM clients c WHERE c.id = :id
                """).setParameter("id", s.getClientId()).getSingleResult();
        return Map.of(
                "shipmentId", s.getId(),
                "financeAudit", s.getFinanceAudit(),
                "clientName", c[0] == null ? "" : c[0],
                // priceStyle is retained only as a display-compatible snapshot.
                "priceStyle", method == null || method.legacyId() == null
                        ? -1 : method.legacyId(),
                "settlementMethodId", method == null ? "" : method.id().toString(),
                "settlementMethodCode", method == null || method.code() == null
                        ? "" : method.code(),
                "settlementMethodName", method == null || method.name() == null
                        ? "" : method.name(),
                "cashClient", isCashSettlement(method),
                "outstanding", c[1] == null ? java.math.BigDecimal.ZERO : c[1]);
    }

    /** 仓库作业状态机：在出货草稿上推进 待拣→拣货中→已拣/异常 等目标态，按目标态分别设防（开始拣货前必须已财务审核+明细非空+拣货容量足够；登记异常必填原因），历史无拣货事实的草稿(LEGACY_PENDING)走旧流程不放行。 */
    @Transactional
    @PreAuthorize("hasAuthority('sales_shipment:warehouse-work')")
    public ShipmentDetail transitionWarehouseWork(
            UUID id,
            com.uten.imp.features.sales.shipment.dto.WarehouseWorkTransitionRequest req) {
        tx.bind();
        SalesShipment s = requireWritableShipmentForUpdate(
                id, WAREHOUSE_WORK_AUTHORITY);
        if (s.getStatus() == null || s.getStatus() != STATUS_DRAFT
                || s.isRejected()) {
            throw new ApiException(ErrorCode.BUSINESS, "仅有效待出库草稿可执行仓库作业");
        }
        if (s.getWarehouseId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "仓库作业前必须指定出货仓");
        }
        String current = s.getWarehouseWorkStatus();
        if (SalesShipment.WORK_LEGACY_PENDING.equals(current)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "历史草稿未记录拣货事实，请按历史审核流程处理");
        }
        String target = req.getTargetStatus().trim()
                .toUpperCase(java.util.Locale.ROOT);
        String reason = req.getReason() == null ? "" : req.getReason().trim();
        validateWarehouseTransition(current, target, reason);
        OffsetDateTime now = OffsetDateTime.now();
        UUID actor = currentUser.requireEmployeeId();
        List<SalesShipmentItem> items =
                itemRepo.findByShipmentIdOrderByLineNoAsc(id);

        switch (target) {
            case SalesShipment.WORK_PICKING -> {
                requireWarehouseTransition(
                        current, SalesShipment.WORK_PENDING_PICK, target);
                if (items.isEmpty()) {
                    throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可开始拣货");
                }
                lockStoredOrderTargets(items);
                assertStoredOrderLinks(
                        s, items, true, WAREHOUSE_WORK_AUTHORITY);
                assertStoredShipmentPolicy(items);
                assertFinanceAudited(s);
                assertWarehousePickCapacity(s, items);
                s.setPickingStartedAt(now);
                s.setPickingStartedBy(actor);
                s.setWarehouseExceptionReason(null);
            }
            case SalesShipment.WORK_PICKED -> {
                requireWarehouseTransition(
                        current, SalesShipment.WORK_PICKING, target);
                s.setPickedAt(now);
                s.setPickedBy(actor);
            }
            case SalesShipment.WORK_EXCEPTION -> {
                if (current == null || !Set.of(
                        SalesShipment.WORK_PENDING_PICK,
                        SalesShipment.WORK_PICKING,
                        SalesShipment.WORK_PICKED).contains(current)) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "当前仓库状态不可登记异常：" + current);
                }
                if (reason.isBlank()) {
                    throw new ApiException(
                            ErrorCode.VALIDATION_FAILED, "仓库异常必须填写原因");
                }
                s.setWarehouseExceptionReason(reason);
            }
            case SalesShipment.WORK_PENDING_PICK -> {
                requireWarehouseTransition(
                        current, SalesShipment.WORK_EXCEPTION, target);
                if (reason.isBlank()) {
                    throw new ApiException(
                            ErrorCode.VALIDATION_FAILED, "恢复待拣货必须填写处理说明");
                }
                s.setWarehouseExceptionReason(null);
            }
            case SalesShipment.WORK_SHIPPED -> {
                requireWarehouseTransition(
                        current, SalesShipment.WORK_PICKED, target);
                s.setHandedOverAt(now);
                s.setHandedOverBy(actor);
                s.setWarehouseWorkUpdatedAt(now);
                s.setWarehouseWorkUpdatedBy(actor);
                recordWarehouseEvent(
                        s, current, target, null, actor, now);
                return approveLocked(s, WAREHOUSE_WORK_AUTHORITY);
            }
            default -> throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "仓库目标状态仅支持开始拣货、拣货完成、异常、恢复或交接出库");
        }
        s.setWarehouseWorkStatus(target);
        s.setWarehouseWorkUpdatedAt(now);
        s.setWarehouseWorkUpdatedBy(actor);
        shipmentRepo.save(s);
        recordWarehouseEvent(s, current, target, reason, actor, now);
        return detail(id);
    }

    private static void requireWarehouseTransition(
            String current, String expected, String target) {
        if (!expected.equals(current)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "仓库状态已变化，不能从 " + current + " 转为 " + target);
        }
    }

    static void validateWarehouseTransition(
            String current, String target, String reason) {
        String safeReason = reason == null ? "" : reason.trim();
        switch (target) {
            case SalesShipment.WORK_PICKING ->
                    requireWarehouseTransition(
                            current, SalesShipment.WORK_PENDING_PICK, target);
            case SalesShipment.WORK_PICKED ->
                    requireWarehouseTransition(
                            current, SalesShipment.WORK_PICKING, target);
            case SalesShipment.WORK_EXCEPTION -> {
                if (!Set.of(
                        SalesShipment.WORK_PENDING_PICK,
                        SalesShipment.WORK_PICKING,
                        SalesShipment.WORK_PICKED).contains(current)) {
                    throw new ApiException(
                            ErrorCode.CONFLICT,
                            "当前仓库状态不可登记异常：" + current);
                }
                if (safeReason.isBlank()) {
                    throw new ApiException(
                            ErrorCode.VALIDATION_FAILED,
                            "仓库异常必须填写原因");
                }
            }
            case SalesShipment.WORK_PENDING_PICK -> {
                requireWarehouseTransition(
                        current, SalesShipment.WORK_EXCEPTION, target);
                if (safeReason.isBlank()) {
                    throw new ApiException(
                            ErrorCode.VALIDATION_FAILED,
                            "恢复待拣货必须填写退拣或异常处理说明");
                }
            }
            case SalesShipment.WORK_SHIPPED ->
                    requireWarehouseTransition(
                            current, SalesShipment.WORK_PICKED, target);
            default -> throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "仓库目标状态仅支持开始拣货、拣货完成、异常、恢复或交接出库");
        }
    }

    /**
     * Starting a pick is the physical-allocation boundary. Pending drafts only
     * reserve order capacity; this check serializes the inventory dimension
     * and proves the selected warehouse can cover this task after safety stock,
     * other orders' reservations and already-started tasks.
     */
    private void assertWarehousePickCapacity(
            SalesShipment shipment, List<SalesShipmentItem> items) {
        Map<InventoryKey, BigDecimal> requested = new java.util.TreeMap<>();
        Map<InventoryKey, Set<UUID>> ownOrderItems = new java.util.TreeMap<>();
        Map<InventoryKey, BigDecimal> linkedRequested = new java.util.TreeMap<>();
        for (SalesShipmentItem item : items) {
            BigDecimal rate = item.getUnitRate() == null
                    ? BigDecimal.ONE : item.getUnitRate();
            if (item.getGoodsId() == null || item.getQty() == null
                    || item.getQty().signum() <= 0 || rate.signum() <= 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT, "出货明细缺少有效货品、数量或换算率");
            }
            InventoryKey key = new InventoryKey(
                    item.getGoodsId(), item.getColorId());
            BigDecimal base = item.getQty().multiply(rate);
            requested.merge(key, base, BigDecimal::add);
            if (item.getOrderItemId() != null) {
                ownOrderItems.computeIfAbsent(
                        key, ignored -> new java.util.TreeSet<>())
                        .add(item.getOrderItemId());
                linkedRequested.merge(key, base, BigDecimal::add);
            }
        }
        stockService.lockInventory(requested.keySet());
        for (Map.Entry<InventoryKey, BigDecimal> entry : requested.entrySet()) {
            InventoryKey key = entry.getKey();
            Set<UUID> ownIds = ownOrderItems.getOrDefault(key, Set.of());
            BigDecimal onHand = scalarDecimal(em.createNativeQuery("""
                    SELECT COALESCE((
                        SELECT qty FROM stock_balances
                        WHERE warehouse_id = :wid
                          AND goods_id = :gid
                          AND color_id IS NOT DISTINCT FROM CAST(:cid AS uuid)
                    ), 0)
                    """).setParameter("wid", shipment.getWarehouseId())
                    .setParameter("gid", key.goodsId())
                    .setParameter("cid", key.colorId()));
            BigDecimal safety = scalarDecimal(em.createNativeQuery("""
                    SELECT GREATEST(COALESCE(CAST(min_qty AS NUMERIC),0),0)
                    FROM goods WHERE id = :gid
                    """).setParameter("gid", key.goodsId()));

            String reservationExclusion = ownIds.isEmpty()
                    ? "" : " AND order_item_id NOT IN (:ownIds)";
            jakarta.persistence.Query otherReservationQuery =
                    em.createNativeQuery("""
                            SELECT COALESCE(SUM(
                                qty - consumed_qty - released_qty),0)
                            FROM stock_reservations
                            WHERE is_deleted = FALSE
                              AND status = 0
                              AND goods_id = :gid
                              AND color_id IS NOT DISTINCT FROM CAST(:cid AS uuid)
                              -- Global reservations are protected by global ATP
                              -- and are allocated by the warehouse tasks that
                              -- own them. Counting every other global promise
                              -- in every warehouse would deadlock valid
                              -- multi-warehouse fulfilment.
                              AND warehouse_id = :wid
                            """ + reservationExclusion)
                            .setParameter("gid", key.goodsId())
                            .setParameter("cid", key.colorId())
                            .setParameter("wid", shipment.getWarehouseId());
            if (!ownIds.isEmpty()) {
                otherReservationQuery.setParameter("ownIds", ownIds);
            }
            BigDecimal otherReservations =
                    scalarDecimal(otherReservationQuery);

            String activeOwnPredicate = ownIds.isEmpty()
                    ? "si.order_item_id IS NULL"
                    : "(si.order_item_id IS NULL OR si.order_item_id IN (:ownIds))";
            jakarta.persistence.Query activeQuery = em.createNativeQuery("""
                    SELECT COALESCE(SUM(
                        si.qty * COALESCE(NULLIF(si.unit_rate,0),1)),0)
                    FROM sales_shipment_items si
                    JOIN sales_shipments s ON s.id = si.shipment_id
                    WHERE s.id <> :shipmentId
                      AND s.warehouse_id = :wid
                      AND s.status = 0
                      AND COALESCE(s.rejected,false) = false
                      AND COALESCE(s.is_deleted,false) = false
                      AND COALESCE(si.is_deleted,false) = false
                      AND s.warehouse_work_status IN ('PICKING','PICKED')
                      AND si.goods_id = :gid
                      AND si.color_id IS NOT DISTINCT FROM CAST(:cid AS uuid)
                      """ + " AND " + activeOwnPredicate)
                    .setParameter("shipmentId", shipment.getId())
                    .setParameter("wid", shipment.getWarehouseId())
                    .setParameter("gid", key.goodsId())
                    .setParameter("cid", key.colorId());
            if (!ownIds.isEmpty()) activeQuery.setParameter("ownIds", ownIds);
            BigDecimal activeSameOrUnlinked = scalarDecimal(activeQuery);

            BigDecimal movable = onHand
                    .subtract(safety)
                    .subtract(otherReservations)
                    .subtract(activeSameOrUnlinked)
                    .max(BigDecimal.ZERO);
            if (entry.getValue().compareTo(movable) > 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "出货仓可拣库存不足（已扣安全库存、其它硬预留和在拣任务）：可拣 "
                                + movable.stripTrailingZeros().toPlainString()
                                + "，本单需要 "
                                + entry.getValue().stripTrailingZeros().toPlainString());
            }

            if (!ownIds.isEmpty()) {
                BigDecimal eligible = scalarDecimal(em.createNativeQuery("""
                        SELECT COALESCE(SUM(
                            qty - consumed_qty - released_qty),0)
                        FROM stock_reservations
                        WHERE is_deleted = FALSE
                          AND status = 0
                          AND order_item_id IN (:ownIds)
                          AND goods_id = :gid
                          AND color_id IS NOT DISTINCT FROM CAST(:cid AS uuid)
                              -- Global reservations are protected by global ATP
                              -- and allocated by their own warehouse tasks.
                              -- Counting every global promise in every
                              -- warehouse would deadlock valid split delivery.
                              AND (warehouse_id IS NULL OR warehouse_id = :wid)
                        """).setParameter("ownIds", ownIds)
                        .setParameter("gid", key.goodsId())
                        .setParameter("cid", key.colorId())
                        .setParameter("wid", shipment.getWarehouseId()));
                BigDecimal ownActive = scalarDecimal(em.createNativeQuery("""
                        SELECT COALESCE(SUM(
                            si.qty * COALESCE(NULLIF(si.unit_rate,0),1)),0)
                        FROM sales_shipment_items si
                        JOIN sales_shipments s ON s.id = si.shipment_id
                        WHERE s.id <> :shipmentId
                          AND s.warehouse_id = :wid
                          AND s.status = 0
                          AND COALESCE(s.rejected,false) = false
                          AND COALESCE(s.is_deleted,false) = false
                          AND COALESCE(si.is_deleted,false) = false
                          AND s.warehouse_work_status IN ('PICKING','PICKED')
                          AND si.order_item_id IN (:ownIds)
                          AND si.goods_id = :gid
                          AND si.color_id IS NOT DISTINCT FROM CAST(:cid AS uuid)
                        """).setParameter("shipmentId", shipment.getId())
                        .setParameter("wid", shipment.getWarehouseId())
                        .setParameter("ownIds", ownIds)
                        .setParameter("gid", key.goodsId())
                        .setParameter("cid", key.colorId()));
                BigDecimal need = linkedRequested
                        .getOrDefault(key, BigDecimal.ZERO)
                        .add(ownActive);
                if (eligible.compareTo(need) < 0) {
                    throw new ApiException(
                            ErrorCode.CONFLICT,
                            "订单硬预留不在当前出货仓或已由其它在拣任务占用");
                }
            }
        }
    }

    private BigDecimal scalarDecimal(jakarta.persistence.Query query) {
        Object value = query.getSingleResult();
        return value == null ? BigDecimal.ZERO
                : value instanceof BigDecimal decimal
                ? decimal : new BigDecimal(value.toString());
    }

    private void recordWarehouseEvent(
            SalesShipment shipment,
            String fromStatus,
            String toStatus,
            String reason,
            UUID actor,
            OffsetDateTime occurredAt) {
        em.createNativeQuery("""
                INSERT INTO sales_shipment_warehouse_events (
                    id, shipment_id, from_status, to_status,
                    reason, actor_employee_id, occurred_at
                ) VALUES (
                    gen_random_uuid(), :shipmentId, :fromStatus, :toStatus,
                    :reason, :actor, :occurredAt
                )
                """)
                .setParameter("shipmentId", shipment.getId())
                .setParameter("fromStatus", fromStatus)
                .setParameter("toStatus", toStatus)
                .setParameter(
                        "reason",
                        reason == null || reason.isBlank()
                                ? null : reason.trim())
                .setParameter("actor", actor)
                .setParameter("occurredAt", occurredAt)
                .executeUpdate();
    }

    static void requireFinanceAuditEditableState(SalesShipment shipment) {
        if (shipment.getStatus() == null || shipment.getStatus() != STATUS_DRAFT
                || shipment.isRejected()
                || (!SalesShipment.WORK_PENDING_PICK.equals(
                        shipment.getWarehouseWorkStatus())
                    && !SalesShipment.WORK_LEGACY_PENDING.equals(
                        shipment.getWarehouseWorkStatus()))) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "财务审核或反审只允许在仓库开始拣货前；已开始作业须先退拣并恢复待拣货");
        }
    }

    static void requireFinanceAuditClearedForMutation(
            SalesShipment shipment) {
        if (shipment.getFinanceAudit() != null
                && shipment.getFinanceAudit() == 1) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "出货单已财务审核；编辑、删除或驳回前必须先完成财务反审");
        }
    }

    /**
     * A SHIPPED state is already an outbound fact. Historical migrated rows
     * deliberately have no synthetic handover timestamp, so a missing
     * timestamp must never be interpreted as proof that the goods stayed in
     * the warehouse. Physical goods may return only through sales return and
     * receiving/quality disposition; bookkeeping reversal cannot create stock.
     */
    static void requireDirectReversalAllowed(SalesShipment shipment) {
        if (SalesShipment.WORK_SHIPPED.equals(
                    shipment.getWarehouseWorkStatus())
                || shipment.getHandedOverAt() != null) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "货物已出库或历史交接事实未知，不能直接红冲增加库存；请走销售退货与收货检验流程");
        }
        // 已审核单据若仓库执行状态缺失，则无法证实货物确未出库，同样不得直接红冲。
        // 历史迁移草稿以 WORK_LEGACY_PENDING 显式标记（且状态为草稿），不落入此分支，
        // 兼容路径保持不变；缺失状态（NULL）不等同于"货物未出库"。
        if (shipment.getStatus() != null
                && shipment.getStatus() == STATUS_APPROVED
                && shipment.getWarehouseWorkStatus() == null) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "已审核出货单缺少仓库执行状态，无法证实货物未出库，不能直接红冲增加库存；请走销售退货与收货检验流程");
        }
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_shipment:edit')")
    public ShipmentDetail approve(UUID id) {
        tx.bind();
        SalesShipment s = requireWritableShipmentForUpdate(id);
        if (!SalesShipment.WORK_LEGACY_PENDING.equals(s.getWarehouseWorkStatus())) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "新流程出货单须由仓库依次完成开始拣货、拣货完成、交接出库");
        }
        recordWarehouseEvent(
                s, SalesShipment.WORK_LEGACY_PENDING,
                SalesShipment.WORK_SHIPPED,
                "历史兼容审核，不表示已采集物流交接事实",
                currentUser.requireEmployeeId(), OffsetDateTime.now());
        return approveLocked(s);
    }

    private ShipmentDetail approveLocked(
            SalesShipment s, String... operationAuthorities) {
        UUID id = s.getId();
        if (s.getStatus() == null || s.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (s.isRejected()) {
            throw new ApiException(ErrorCode.BUSINESS, "已驳回的出货单不可审核，请删除后重新开单");
        }
        if (s.getWarehouseId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "出货单需指定仓库");
        }
        if (s.getClientId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "出货单需指定客户");
        }
        // C6 财务发货审核及 AR 账期：在任何库存变更前锁定有效客户的结账方式/账期快照。
        ClientSettlementSnapshot settlement = lockClientSettlementSnapshot(s);
        assertFinanceAudited(s, settlement.cashSettlement());
        List<SalesShipmentItem> items = itemRepo.findByShipmentIdOrderByLineNoAsc(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        }
        lockStoredOrderTargets(items);
        assertStoredOrderLinks(s, items, true, operationAuthorities);
        // The source-order comparison above is against the untouched draft.
        // Only after it succeeds may the explicit client-default UUID fallback
        // become this shipment's immutable UUID/legacy settlement snapshot.
        s.setSettlementMethodId(settlement.settlementMethodId());
        s.setPaymentStyleId(settlement.settlementStyleLegacy() == null
                ? null : settlement.settlementStyleLegacy().intValue());
        assertStoredShipmentPolicy(items);
        requireNonNegativeStoredCommercial(items);
        requireNonNegativeTotals(s);
        OffsetDateTime now = OffsetDateTime.now();
        captureGoodsSnapshots(items, true, now);
        applyFinancePostingRate(s, items);
        stockService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        for (SalesShipmentItem it : items) {
            if (it.getOrderItemId() != null) {
                validateShippable(it); // 超发硬校验（未发余量 + 链上行预留量）
                BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
                // 消耗预留（FIFO + 行锁；链上行才有预留，无预留时实耗 0 不报错——历史单兼容）
                BigDecimal needBase = it.getQty().multiply(rate);
                BigDecimal consumed = reservationService.consumeForOrderItem(
                        it.getOrderItemId(), s.getWarehouseId(), needBase);
                if (chainStatusOf(it.getOrderItemId()) > 0
                        && consumed.compareTo(needBase) != 0) {
                    throw new ApiException(
                            ErrorCode.CONFLICT,
                            "订单预留不在当前出货仓或已被占用，请刷新仓库任务");
                }
            }
            applyMovement(s, it, StockService.DIR_OUT, now, null);
            if (it.getOrderItemId() != null) {
                addShippedQty(it.getOrderItemId(), it.getQty()); // +qty
                applyReservedAndChainOnShip(it.getOrderItemId(), it.getQty().negate()); // 预留扣减 + 行状态推进
                recalcOrderClosed(it.getOrderItemId());
            }
        }

        // 立应收（AR, SALES_SHIPMENT, BStyle=3, 正应收）。原/本币金额及订单来源均取本次发运快照。
        if (!s.isArPosted()) {
            List<SourceRef> sourceRefs = salesOrderSourceRefs(s.getId());
            arApService.postArAp(new ArApPostingRequest(
                    "AR",
                    StockService.SRC_SALES_SHIPMENT,
                    s.getId(), s.getBillNo(), s.getBillDate(),
                    s.getClientId(), null,
                    s.getCurrencyId(), s.getExchangeRate(),
                    s.getTotalLocal(),
                    BSTYLE_SALES_SHIPMENT,
                    s.getRemark(),
                    s.getTotalOriginal(),
                    settlement.dueDate(),
                    settlement.settlementStyleLegacy(),
                    sourceRefs,
                    settlement.settlementMethodId()));
            s.setArPosted(true);
        }

        s.setStatus(STATUS_APPROVED);
        s.setWarehouseWorkStatus(SalesShipment.WORK_SHIPPED);
        s.setWarehouseWorkUpdatedAt(now);
        s.setWarehouseWorkUpdatedBy(currentUser.requireEmployeeId());
        s.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        s.setLastDate(now);
        shipmentRepo.save(s);
        chainNotice.notifyShipmentApproved(id); // 旁路通知：发货→订单归属销售，提交后发送
        return detail(id);
    }

    /**
     * Lock the finance-maintained currency master and make it the authoritative
     * recognition-rate snapshot for this shipment. Sales-order rate snapshots
     * are never reused for AR posting.
     */
    private void applyFinancePostingRate(
            SalesShipment shipment, List<SalesShipmentItem> items) {
        BigDecimal financeRate = lockFinancePostingRate(shipment.getCurrencyId());
        applyPostingRateSnapshot(shipment, items, financeRate);
        requirePostedLocalAmounts(shipment, items);
        itemRepo.saveAll(items);
        itemRepo.flush();
    }

    private BigDecimal lockFinancePostingRate(UUID currencyId) {
        if (currencyId == null) {
            throw new ApiException(ErrorCode.CONFLICT, "发运币别缺失，财务汇率无法确认");
        }
        @SuppressWarnings("unchecked")
        List<Object> rows = em.createNativeQuery("""
                SELECT currency.exchange_rate
                FROM currencies currency
                WHERE currency.id = :currencyId
                  AND COALESCE(currency.is_deleted, false) = false
                  AND currency.status = '使用'
                FOR SHARE
                """)
                .setParameter("currencyId", currencyId)
                .getResultList();
        if (rows.size() != 1 || rows.getFirst() == null) {
            throw new ApiException(ErrorCode.CONFLICT, "币种未启用或财务汇率缺失，禁止发运立账");
        }
        BigDecimal rate = rows.getFirst() instanceof BigDecimal decimal
                ? decimal
                : new BigDecimal(rows.getFirst().toString());
        if (rate.signum() <= 0) {
            throw new ApiException(ErrorCode.CONFLICT, "财务维护的币种汇率必须大于 0，禁止发运立账");
        }
        return rate;
    }

    /**
     * Lock the active client master used by this shipment and derive immutable
     * AR settlement metadata. {@code last_date} is an operation timestamp and
     * must never be reused as the receivable due date.
     */
    @SuppressWarnings("unchecked")
    private ClientSettlementDefaults loadClientSettlementDefaults(
            UUID clientId, boolean forShare) {
        if (clientId == null) {
            throw new ApiException(ErrorCode.CONFLICT, "发运客户缺失，无法确认应收账期");
        }
        String sql = """
                SELECT client.default_settlement_method_id,
                       client.price_style,
                       client.tday
                FROM clients client
                WHERE client.id = :clientId
                  AND COALESCE(client.is_deleted, false) = false
                  AND client.status = '使用'
                """ + (forShare ? " FOR SHARE" : "");
        List<Object[]> rows = em.createNativeQuery(sql)
                .setParameter("clientId", clientId)
                .getResultList();
        if (rows.size() != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "客户主档未启用或不存在，禁止发运立账");
        }
        Object[] row = rows.getFirst();
        return new ClientSettlementDefaults(
                row[0] == null ? null : (UUID) row[0],
                row[1] == null ? null : ((Number) row[1]).intValue(),
                row[2] == null ? null : ((Number) row[2]).intValue());
    }

    private SettlementMethodReferenceResolver.SettlementMethodReference
            resolveEffectiveSettlementMethod(
                    SalesShipment shipment,
                    ClientSettlementDefaults defaults) {
        boolean headerReferencePresent = shipment.getSettlementMethodId() != null
                || shipment.getPaymentStyleId() != null;
        UUID authoritativeId = headerReferencePresent
                ? shipment.getSettlementMethodId()
                : defaults.defaultSettlementMethodId();
        Integer legacyShadow = headerReferencePresent
                ? shipment.getPaymentStyleId()
                : defaults.legacyShadow();
        return SettlementMethodReferenceResolver.resolve(
                em, authoritativeId, legacyShadow,
                headerReferencePresent ? "出货结账方式" : "客户默认结账方式");
    }

    private static boolean isCashSettlement(
            SettlementMethodReferenceResolver.SettlementMethodReference method) {
        return method != null
                && SETTLEMENT_ROLE_CASH.equals(method.systemRole());
    }

    private ClientSettlementSnapshot lockClientSettlementSnapshot(
            SalesShipment shipment) {
        ClientSettlementDefaults defaults = loadClientSettlementDefaults(
                shipment.getClientId(), true);
        var method = resolveEffectiveSettlementMethod(shipment, defaults);
        return settlementSnapshot(
                method == null ? null : method.legacyId(),
                defaults.settlementDays(),
                shipment.getBillDate(),
                method == null ? null : method.id(),
                isCashSettlement(method));
    }

    static ClientSettlementSnapshot settlementSnapshot(
            Integer settlementStyleLegacy,
            Integer settlementDays,
            LocalDate billDate,
            UUID settlementMethodId,
            boolean cashSettlement) {
        if (billDate == null) {
            throw new ApiException(ErrorCode.CONFLICT, "发运日期缺失，无法确认应收到期日");
        }
        long days = settlementDays != null && settlementDays > 0
                ? settlementDays.longValue()
                : 0L;
        try {
            return new ClientSettlementSnapshot(
                    settlementStyleLegacy(settlementStyleLegacy),
                    billDate.plusDays(days),
                    settlementMethodId,
                    cashSettlement);
        } catch (DateTimeException ex) {
            throw new ApiException(ErrorCode.CONFLICT, "客户账期超出有效日期范围");
        }
    }

    record ClientSettlementSnapshot(
            Short settlementStyleLegacy,
            LocalDate dueDate,
            UUID settlementMethodId,
            boolean cashSettlement) {
    }

    record ClientSettlementDefaults(
            UUID defaultSettlementMethodId,
            Integer legacyShadow,
            Integer settlementDays) {
    }

    static void applyPostingRateSnapshot(
            SalesShipment shipment,
            List<SalesShipmentItem> items,
            BigDecimal financeRate) {
        if (financeRate == null || financeRate.signum() <= 0) {
            throw new ApiException(ErrorCode.CONFLICT, "财务维护的币种汇率必须大于 0，禁止发运立账");
        }
        BigDecimal totalOriginal = BigDecimal.ZERO;
        BigDecimal totalLocal = BigDecimal.ZERO;
        for (SalesShipmentItem item : items) {
            BigDecimal original = item.getAmountOriginal() == null
                    ? BigDecimal.ZERO
                    : item.getAmountOriginal();
            if (original.signum() < 0) {
                throw new ApiException(ErrorCode.CONFLICT, "发运原币金额无效，禁止发运立账");
            }
            BigDecimal local = original.multiply(financeRate)
                    .setScale(MONEY_SCALE, RoundingMode.HALF_UP);
            item.setAmountLocal(local);
            totalOriginal = totalOriginal.add(original);
            totalLocal = totalLocal.add(local);
        }
        shipment.setExchangeRate(financeRate);
        shipment.setTotalOriginal(totalOriginal);
        shipment.setTotalLocal(totalLocal);
    }

    private static void requirePostedLocalAmounts(
            SalesShipment shipment, List<SalesShipmentItem> items) {
        if (shipment.getExchangeRate() == null
                || shipment.getExchangeRate().signum() <= 0
                || shipment.getTotalLocal() == null
                || shipment.getTotalLocal().signum() < 0
                || items.stream().anyMatch(item -> item.getAmountLocal() == null
                        || item.getAmountLocal().signum() < 0)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "发运本币金额未按财务汇率形成，禁止发运立账");
        }
    }

    /**
     * 按销售订单聚合本次发运行金额，形成不可变 AR 来源快照。
     *
     * <p>只接受持久化的 shipment_item.order_item_id 链；不按单号、客户或日期猜历史关联。
     * 金额使用发运行快照，订单后续修改不会改写已经立账的来源金额。
     */
    @SuppressWarnings("unchecked")
    private List<SourceRef> salesOrderSourceRefs(UUID shipmentId) {
        List<Object[]> rows = em.createNativeQuery("""
                SELECT sales_order.id,
                       sales_order.bill_no,
                       COALESCE(SUM(shipment_item.amount_original), 0),
                       COALESCE(SUM(shipment_item.amount_local), 0)
                FROM sales_shipment_items shipment_item
                JOIN sales_order_items order_item
                  ON order_item.id = shipment_item.order_item_id
                 AND COALESCE(order_item.is_deleted, false) = false
                JOIN sales_orders sales_order
                  ON sales_order.id = order_item.order_id
                 AND COALESCE(sales_order.is_deleted, false) = false
                WHERE shipment_item.shipment_id = :shipmentId
                  AND shipment_item.order_item_id IS NOT NULL
                  AND COALESCE(shipment_item.is_deleted, false) = false
                GROUP BY sales_order.id, sales_order.bill_no
                ORDER BY sales_order.bill_no, sales_order.id
                """)
                .setParameter("shipmentId", shipmentId)
                .getResultList();
        return rows.stream()
                .map(row -> new SourceRef(
                        SourceRef.SALES_ORDER,
                        (UUID) row[0],
                        String.valueOf(row[1]),
                        row[2] == null ? BigDecimal.ZERO : (BigDecimal) row[2],
                        row[3] == null ? BigDecimal.ZERO : (BigDecimal) row[3]))
                .toList();
    }

    private static Short settlementStyleLegacy(Integer paymentStyleId) {
        if (paymentStyleId == null) {
            return null;
        }
        if (paymentStyleId < Short.MIN_VALUE || paymentStyleId > Short.MAX_VALUE) {
            throw new ApiException(ErrorCode.CONFLICT, "销售结账方式超出财务立账范围");
        }
        return paymentStyleId.shortValue();
    }

    /** 仓库驳回：草稿出货单备货异常 → 逐行释放预留 + 订单行回退待排产，缺口自动回调度待排产列表。 */
    @Transactional
    @PreAuthorize("hasAuthority('sales_shipment:reject')")
    public ShipmentDetail reject(UUID id, String reason) {
        tx.bind();
        SalesShipment s = requireWritableShipmentForUpdate(id, REJECT_AUTHORITY);
        if (s.getStatus() == null || s.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿（待备货）出货单可驳回；已审核请走红冲");
        }
        if (s.isRejected()) {
            throw new ApiException(ErrorCode.BUSINESS, "该出货单已驳回");
        }
        requireFinanceAuditClearedForMutation(s);
        if (!SalesShipment.WORK_PENDING_PICK.equals(s.getWarehouseWorkStatus())
                && !SalesShipment.WORK_LEGACY_PENDING.equals(s.getWarehouseWorkStatus())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "仓库作业已开始或仍在异常处理；须先完成退拣并恢复待拣货，才可驳回释放订单预留");
        }
        List<SalesShipmentItem> items = itemRepo.findByShipmentIdOrderByLineNoAsc(id);
        lockStoredOrderTargets(items);
        assertStoredOrderLinks(s, items, true, REJECT_AUTHORITY);
        for (SalesShipmentItem it : items) {
            if (it.getOrderItemId() == null || chainStatusOf(it.getOrderItemId()) <= 0) continue;
            BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
            // 释放该行对应预留（货损/丢失/找不到 → 这批货不再属于该订单）
            reservationService.releaseForOrderItem(it.getOrderItemId(), it.getQty().multiply(rate));
            // reserved_qty 回减 + 行状态回退：可发→7 / 已排产→4 / 否则→2 待排产（重走生产）
            int reservedUpdated = em.createNativeQuery("""
                    UPDATE sales_order_items
                    SET reserved_qty = COALESCE(reserved_qty,0) - :q,
                        chain_status = CASE WHEN COALESCE(chain_status,0) > 0 THEN
                            CASE
                              WHEN COALESCE(reserved_qty,0) - :q
                                   >= COALESCE(qty,0) - COALESCE(shipped_qty,0)
                                      + COALESCE(returned_qty,0) - COALESCE(flag_qty,0) THEN 7
                              WHEN GREATEST(COALESCE(planned_qty,0)
                                            - COALESCE(produced_qty,0), 0) > 0 THEN 4
                              WHEN COALESCE(reserved_qty,0) - :q > 0 THEN 1
                              ELSE 2
                            END
                        ELSE chain_status END
                    WHERE id = :id AND COALESCE(reserved_qty,0) >= :q
                    """).setParameter("q", it.getQty()).setParameter("id", it.getOrderItemId())
                    .executeUpdate();
            if (reservedUpdated != 1) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "订单预留累计小于出货驳回释放量，禁止自动吞并错账");
            }
        }
        String warehouseFromStatus = s.getWarehouseWorkStatus();
        s.setRejected(true);
        s.setRejectReason(reason == null || reason.isBlank() ? "仓库备货异常" : reason.trim());
        s.setWarehouseWorkStatus(SalesShipment.WORK_CANCELLED);
        s.setWarehouseWorkUpdatedAt(OffsetDateTime.now());
        s.setWarehouseWorkUpdatedBy(currentUser.requireEmployeeId());
        s.setWarehouseExceptionReason(s.getRejectReason());
        shipmentRepo.save(s);
        recordWarehouseEvent(
                s, warehouseFromStatus,
                SalesShipment.WORK_CANCELLED,
                s.getRejectReason(), s.getWarehouseWorkUpdatedBy(),
                s.getWarehouseWorkUpdatedAt());
        chainNotice.notifyShipmentRejected(id, reason); // 旁路通知：驳回→订单归属销售，提交后发送
        return detail(id);
    }

    /** 红冲：status 1→-1，先校验收款核销 → 反向库存 + 回减 shipped_qty + 结案重算 + ar_posted=false。 */
    @Transactional
    @PreAuthorize("hasAuthority('sales_shipment:edit')")
    public ShipmentDetail reverse(UUID id) {
        tx.bind();
        SalesShipment s = requireWritableShipmentForUpdate(id);
        if (s.getStatus() == null || s.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        requireDirectReversalAllowed(s);
        List<SalesShipmentItem> items = itemRepo.findByShipmentIdOrderByLineNoAsc(id);
        lockStoredOrderTargets(items);
        assertStoredOrderLinks(s, items, false);
        validateShipmentReversible(items);
        stockService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());

        // 1. 钱流先校验：若已有收款核销 → reverseArAp 抛 IllegalStateException（阻止红冲）
        if (s.isArPosted()) {
            arApService.reverseArAp(s.getId(), StockService.SRC_SALES_SHIPMENT);
            s.setArPosted(false);
        }

        // 2. 反向库存（type=3 dir=+1 倒回）+ 回减 shipped_qty
        // 反向只翻 direction；amountLocal 必须传正数（StockService.recordMovement 内部乘 direction 取符号）。
        // 若再 negate() 金额 → (-amt)×(+1) 与原 (+amt)×(-1) 同号 → 库存金额无法回滚（design §一决策）。
        OffsetDateTime now = OffsetDateTime.now();
        for (SalesShipmentItem it : items) {
            applyMovement(s, it, StockService.DIR_IN, now, null);
            if (it.getOrderItemId() != null) {
                addShippedQty(it.getOrderItemId(), it.getQty().negate()); // -qty
                // 货退回仓库：链上行重新挂预留（绑定原出货仓），恢复可发货量与行状态
                if (chainStatusOf(it.getOrderItemId()) > 0) {
                    BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
                    reservationService.reserve(it.getOrderItemId(), it.getGoodsId(), it.getColorId(),
                            s.getWarehouseId(), it.getQty().multiply(rate),
                            StockReservation.SOURCE_ORDER, "SALES_SHIPMENT_REVERSE", s.getId());
                    restoreReservedAndChainOnReverse(it.getOrderItemId(), it.getQty());
                }
                recalcOrderClosed(it.getOrderItemId());
            }
        }

        String warehouseFromStatus = s.getWarehouseWorkStatus();
        s.setStatus(STATUS_REVERSED);
        s.setWarehouseWorkStatus(SalesShipment.WORK_REVERSED);
        s.setWarehouseWorkUpdatedAt(now);
        s.setWarehouseWorkUpdatedBy(currentUser.requireEmployeeId());
        shipmentRepo.save(s);
        recordWarehouseEvent(
                s, warehouseFromStatus,
                SalesShipment.WORK_REVERSED,
                "受控账务红冲", s.getWarehouseWorkUpdatedBy(), now);
        return detail(id);
    }

    /** 写一笔库存流水（方向由调用方给）。qty 为明细量，baseQty = qty×unit_rate。 */
    private void applyMovement(SalesShipment s, SalesShipmentItem it, short direction,
                               OffsetDateTime ts, BigDecimal overrideAmount) {
        BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
        BigDecimal baseQty = it.getQty().multiply(rate);
        BigDecimal amt = overrideAmount != null ? overrideAmount : it.getAmountLocal();
        stockService.recordMovement(new StockService.MovementRequest(
                ts, StockService.TYPE_SALES_OUT, StockService.SRC_SALES_SHIPMENT,
                s.getId(), it.getId(), it.getGoodsId(), it.getColorId(), s.getWarehouseId(),
                direction, baseQty, it.getUnitId(), it.getUnitRate(), amt,
                direction < 0 ? null : "红冲"));
    }

    /** sales_order_items.shipped_qty += delta（delta=±qty）。 */
    private void addShippedQty(UUID orderItemId, BigDecimal delta) {
        em.createNativeQuery(
                "UPDATE sales_order_items SET shipped_qty = COALESCE(shipped_qty,0) + :d WHERE id = :id")
                .setParameter("d", delta)
                .setParameter("id", orderItemId)
                .executeUpdate();
    }

    /**
     * 超发硬校验（出货审核前置，服务端权威）：
     * ① 本次数量 ≤ 订单未发余量（qty − shipped + returned − flag）——所有挂单行都查；
     * ② 链上行（chain_status > 0）本次数量 ≤ 可发货量（reserved_qty）——无预留不准发。
     * 历史迁移行 chain_status=0 不查②（老单无预留概念，兼容）。
     */

    /**
     * 出货红冲前的下游与累计门禁。退货必须先红冲；同订单行多条出货明细按合计校验，
     * 防止逐行判断后把 shipped_qty 写成负数。
     */
    private void validateShipmentReversible(List<SalesShipmentItem> items) {
        Map<UUID, BigDecimal> reverseByOrderItem = new HashMap<>();
        for (SalesShipmentItem item : items) {
            requireNoActiveReturn(item);
            if (item.getQty() == null || item.getQty().signum() <= 0) {
                throw new ApiException(ErrorCode.CONFLICT, "历史出货明细数量无效，禁止自动红冲");
            }
            if (item.getOrderItemId() != null) {
                reverseByOrderItem.merge(
                        item.getOrderItemId(), item.getQty(), BigDecimal::add);
            }
        }
        if (reverseByOrderItem.isEmpty()) return;

        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id, COALESCE(shipped_qty,0)
                        FROM sales_order_items
                        WHERE id IN (:ids)
                        ORDER BY id
                        FOR UPDATE
                        """)
                .setParameter("ids", new TreeSet<>(reverseByOrderItem.keySet()))
                .getResultList();
        if (rows.size() != reverseByOrderItem.size()) {
            throw new ApiException(ErrorCode.CONFLICT, "出货红冲关联的销售订单行不存在");
        }
        for (Object[] row : rows) {
            BigDecimal currentShipped = toBd(row[1]);
            BigDecimal reversing = reverseByOrderItem.get((UUID) row[0]);
            if (!hasSufficientShippedForReverse(currentShipped, reversing)) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "销售订单已发累计小于本单红冲量，禁止自动吞并错账");
            }
        }
    }

    static void requireNoActiveReturn(SalesShipmentItem item) {
        BigDecimal returnedQty = item.getReturnedQty() == null
                ? BigDecimal.ZERO : item.getReturnedQty();
        BigDecimal returnedAmount = item.getReturnedAmount() == null
                ? BigDecimal.ZERO : item.getReturnedAmount();
        if (returnedQty.signum() != 0 || returnedAmount.signum() != 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "出货明细已有退货，请先红冲关联退货单");
        }
    }

    static boolean hasSufficientShippedForReverse(
            BigDecimal currentShipped, BigDecimal reversing) {
        return currentShipped != null && reversing != null
                && reversing.signum() > 0
                && currentShipped.compareTo(reversing) >= 0;
    }
    private void validateShippable(SalesShipmentItem it) {
        Object[] r = (Object[]) em.createNativeQuery(
                "SELECT qty, shipped_qty, returned_qty, flag_qty, reserved_qty, chain_status"
                        + " FROM sales_order_items WHERE id = :id")
                .setParameter("id", it.getOrderItemId())
                .getSingleResult();
        BigDecimal qty = toBd(r[0]);
        BigDecimal deliverable = qty.subtract(toBd(r[1])).add(toBd(r[2])).subtract(toBd(r[3]));
        if (it.getQty().compareTo(deliverable) > 0) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "发货数量超过订单未发数量（剩 " + deliverable.stripTrailingZeros().toPlainString() + "）");
        }
        short chain = r[5] == null ? 0 : ((Number) r[5]).shortValue();
        BigDecimal reserved = toBd(r[4]);
        if (chain > 0 && it.getQty().compareTo(reserved) > 0) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "发货数量超过可发货数量（预留 " + reserved.stripTrailingZeros().toPlainString() + "）");
        }
    }

    /** 订单行链路状态（0=未上链/历史行）。 */
    private short chainStatusOf(UUID orderItemId) {
        Object v = em.createNativeQuery("SELECT chain_status FROM sales_order_items WHERE id = :id")
                .setParameter("id", orderItemId)
                .getSingleResult();
        return v == null ? 0 : ((Number) v).shortValue();
    }

    /**
     * 出货审核后：reserved_qty 扣减（delta 为负）+ 行状态推进（8部分发货 / 9已发货）。
     * 须在 addShippedQty 之后执行（状态判定读最新 shipped_qty）。链上行才推进。
     */
    private void applyReservedAndChainOnShip(UUID orderItemId, BigDecimal delta) {
        int updated = em.createNativeQuery("""
                UPDATE sales_order_items
                SET reserved_qty = COALESCE(reserved_qty,0) + :d,
                    chain_status = CASE WHEN COALESCE(chain_status,0) > 0 THEN
                        CASE WHEN COALESCE(qty,0) - COALESCE(shipped_qty,0)
                                       + COALESCE(returned_qty,0) - COALESCE(flag_qty,0) <= 0
                             THEN 9 ELSE 8 END
                    ELSE COALESCE(chain_status,0) END
                WHERE id = :id AND COALESCE(reserved_qty,0) + :d >= 0
                """).setParameter("d", delta).setParameter("id", orderItemId).executeUpdate();
        if (updated != 1) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "订单预留累计小于本次出货量，禁止自动吞并错账");
        }
    }

    /**
     * 出货红冲后：reserved_qty 回补（货已回库并重新挂预留）+ 行状态回退（7可发货 / 1部分预留）。
     * 须在 addShippedQty(-qty) 之后执行。仅链上行调用。
     */
    private void restoreReservedAndChainOnReverse(UUID orderItemId, BigDecimal qtyBack) {
        em.createNativeQuery("""
                UPDATE sales_order_items
                SET reserved_qty = COALESCE(reserved_qty,0) + :d,
                    chain_status = CASE
                        WHEN COALESCE(reserved_qty,0) + :d
                                 >= COALESCE(qty,0) - COALESCE(shipped_qty,0)
                                    + COALESCE(returned_qty,0) - COALESCE(flag_qty,0)
                        THEN 7
                        ELSE 1 END
                WHERE id = :id
                """).setParameter("d", qtyBack).setParameter("id", orderItemId).executeUpdate();
    }

    private static BigDecimal toBd(Object v) {
        return v == null ? BigDecimal.ZERO : (BigDecimal) v;
    }

    /** 重算订货单结案：所有明细 qty - shipped_qty + returned_qty - flag_qty ≤ 0 → is_closed=true。 */
    private void recalcOrderClosed(UUID orderItemId) {
        em.createNativeQuery("""
                UPDATE sales_orders o SET is_closed = (
                    SELECT COALESCE(bool_and(
                        COALESCE(i.qty,0) - COALESCE(i.shipped_qty,0)
                        + COALESCE(i.returned_qty,0) - COALESCE(i.flag_qty,0) <= 0
                    ), true)
                    FROM sales_order_items i
                    WHERE i.order_id = o.id AND COALESCE(i.is_deleted, false) = false
                ) WHERE o.id = (SELECT order_id FROM sales_order_items WHERE id = :iid)
                """).setParameter("iid", orderItemId).executeUpdate();
    }

    /**
     * Resolve and validate every order-item link in one query. A linked
     * shipment will later update its source order, so source write access (not
     * merely visibility) is required at draft creation/update time.
     */
    private LinkedSource validateLinkedOrderItems(ShipmentSaveRequest req) {
        return validateLinkedOrderItems(
                req, true, true, true, new String[0]);
    }

    /**
     * A sales shipment is a fulfilment document, not a miscellaneous
     * stock-out shortcut. Every new-flow line must therefore originate from a
     * sales-order line so shipment policy, ownership and hard reservation are
     * all server-enforced. Historical LEGACY_PENDING rows remain readable and
     * approvable through the compatibility path; ad-hoc outbound belongs to
     * the dedicated other-shipment document.
     */
    private void requireOrderLinkedNewShipment(ShipmentSaveRequest request) {
        if (request.getItems() == null || request.getItems().isEmpty()
                || request.getItems().stream().anyMatch(
                        line -> line.getOrderItemId() == null)) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "销售出货必须全部从订货单引入；无订单的零星出库请使用其它出货单");
        }
    }

    private LinkedSource validateLinkedOrderItems(ShipmentSaveRequest req,
                                                   boolean requireOpenSource,
                                                   boolean rejectDuplicateLinks,
                                                   boolean enforceCommercialSource,
                                                   String... operationAuthorities) {
        if (req.getItems() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "出货明细不能为空");
        }
        List<ShipmentItemLine> linked = req.getItems().stream()
                .filter(line -> line.getOrderItemId() != null).toList();
        if (linked.isEmpty()) {
            return new LinkedSource(false, null, null, null, null);
        }
        List<UUID> ids = linked.stream().map(ShipmentItemLine::getOrderItemId).toList();
        if (rejectDuplicateLinks && Set.copyOf(ids).size() != ids.size()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "同一订单行不能在出货单中重复关联");
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT i.id, i.goods_id, i.color_id, i.unit_id, i.unit_rate,
                       o.client_id, o.owner_employee_id, o.status,
                       o.is_stopped, o.is_closed, o.bill_no,
                       o.currency_id, o.tax_rate, o.payment_style_id,
                       o.seller_id, i.price, i.amount_original, i.qty,
                       i.discount, i.machining_price, i.client_no,
                       i.client_model, i.source_doc_no, o.id,
                       o.settlement_method_id
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                WHERE i.id IN (:ids)
                  AND COALESCE(i.is_deleted,false)=false
                  AND COALESCE(o.is_deleted,false)=false
                """).setParameter("ids", ids).getResultList();
        Map<UUID, Object[]> byId = new HashMap<>();
        for (Object[] row : rows) {
            byId.put((UUID) row[0], row);
        }

        var writeScope = accessPolicy.scope(operationAuthorities);
        UUID commonOwner = null;
        boolean ownerInitialized = false;
        UUID commonOrderId = null;
        String commonOrderNo = null;
        CommercialTerms commonTerms = null;
        for (ShipmentItemLine line : linked) {
            Object[] row = byId.get(line.getOrderItemId());
            if (row == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "来源订单行不存在或已删除");
            }
            UUID owner = (UUID) row[6];
            accessPolicy.requireWritable(owner, "无权引用该销售订单行", writeScope);
            UUID orderId = (UUID) row[23];
            if (commonOrderId == null) {
                commonOrderId = orderId;
                commonOrderNo = (String) row[10];
            } else if (!commonOrderId.equals(orderId)) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "一张销售出货单只能关联同一张销售订单");
            }
            if (!ownerInitialized) {
                commonOwner = owner;
                ownerInitialized = true;
            } else if (!Objects.equals(commonOwner, owner)) {
                throw new ApiException(ErrorCode.CONFLICT, "一张出货单不能合并不同归属人的订单行");
            }
            if (!Objects.equals(req.getClientId(), row[5])) {
                throw new ApiException(ErrorCode.CONFLICT, "出货客户与来源订单客户不一致");
            }
            requireLinkedDimension(
                    line.getGoodsId(), line.getColorId(), line.getUnitId(), line.getUnitRate(),
                    (UUID) row[1], (UUID) row[2], (UUID) row[3], (BigDecimal) row[4],
                    "出货");
            short status = row[7] == null ? 0 : ((Number) row[7]).shortValue();
            if (status != STATUS_APPROVED
                    || (requireOpenSource && (Boolean.TRUE.equals(row[8]) || Boolean.TRUE.equals(row[9])))) {
                throw new ApiException(ErrorCode.BUSINESS, "来源订单 " + row[10] + " 当前不可发货");
            }
            if (enforceCommercialSource) {
                CommercialTerms terms = commercialTerms(row);
                requireValidCommercialTerms(terms, String.valueOf(row[10]));
                if (commonTerms == null) {
                    commonTerms = terms;
                } else if (!sameCommercialTerms(commonTerms, terms)) {
                    throw new ApiException(
                            ErrorCode.CONFLICT,
                            "一张出货单不能合并币种、税率、结算方式或业务员不同的订单");
                }
                normalizeCommercialLine(line, row);
            }
        }
        if (enforceCommercialSource && commonTerms != null) {
            req.setCurrencyId(commonTerms.currencyId());
            // The order rate is not a commercial term. The draft deliberately
            // carries no local posting rate; SHIPPED fixes the finance rate.
            req.setExchangeRate(null);
            req.setTaxRate(commonTerms.taxRate());
            req.setPaymentStyleId(commonTerms.paymentStyleId());
            req.setSettlementMethodId(commonTerms.settlementMethodId());
            req.setSellerId(commonTerms.sellerId());
        }
        return new LinkedSource(
                true, commonOrderId, commonOrderNo, commonOwner, commonTerms);
    }

    private static CommercialTerms commercialTerms(Object[] row) {
        Integer paymentStyleId = row[13] == null
                ? null : ((Number) row[13]).intValue();
        return new CommercialTerms(
                (UUID) row[11],
                (BigDecimal) row[12],
                paymentStyleId,
                (UUID) row[24],
                (UUID) row[14]);
    }

    private static void requireValidCommercialTerms(
            CommercialTerms terms, String sourceBillNo) {
        if (terms.taxRate() != null && terms.taxRate().signum() < 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "来源订单 " + sourceBillNo + " 税率无效，禁止生成出货应收");
        }
    }

    private static boolean sameCommercialTerms(
            CommercialTerms left, CommercialTerms right) {
        return Objects.equals(left.currencyId(), right.currencyId())
                && sameDecimal(left.taxRate(), right.taxRate())
                && Objects.equals(
                        left.paymentStyleId(), right.paymentStyleId())
                && Objects.equals(left.settlementMethodId(), right.settlementMethodId())
                && Objects.equals(left.sellerId(), right.sellerId());
    }

    private static void normalizeCommercialLine(
            ShipmentItemLine line, Object[] sourceRow) {
        BigDecimal sourcePrice = (BigDecimal) sourceRow[15];
        BigDecimal sourceOriginal = (BigDecimal) sourceRow[16];
        BigDecimal sourceQty = (BigDecimal) sourceRow[17];
        BigDecimal shipQty = line.getQty();
        if (sourceQty == null || sourceQty.signum() <= 0
                || shipQty == null || shipQty.signum() <= 0
                || shipQty.compareTo(sourceQty) > 0
                || sourcePrice == null || sourcePrice.signum() < 0
                || sourceOriginal == null || sourceOriginal.signum() < 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "来源订单 " + sourceRow[10]
                            + " 的数量或金额不是可安全出货的已审事实");
        }
        line.setPrice(sourcePrice);
        line.setAmountOriginal(authoritativeShipmentAmount(
                sourceOriginal, sourceQty, shipQty));
        // A draft has no authoritative local amount. SHIPPED recalculates it
        // from the finance-owned posting rate.
        line.setAmountLocal(null);
        line.setDiscount((BigDecimal) sourceRow[18]);
        line.setMachiningPrice((BigDecimal) sourceRow[19]);
        line.setClientNo((String) sourceRow[20]);
        line.setClientModel((String) sourceRow[21]);
        line.setSourceDocNo((String) sourceRow[10]);
        // These fields have no audited sales-order source. A caller may not
        // inject inventory cost or undocumented price components into AR.
        line.setCostAmount(null);
        line.setMaterialPrice(null);
        line.setDieCastPrice(null);
    }

    static BigDecimal authoritativeShipmentAmount(
            BigDecimal sourceAmount,
            BigDecimal sourceQty,
            BigDecimal shipmentQty) {
        if (sourceAmount == null || sourceAmount.signum() < 0
                || sourceQty == null || sourceQty.signum() <= 0
                || shipmentQty == null || shipmentQty.signum() <= 0
                || shipmentQty.compareTo(sourceQty) > 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "来源订单数量或金额无效，禁止生成出货应收");
        }
        return sourceAmount.multiply(shipmentQty)
                .divide(sourceQty, MONEY_SCALE, RoundingMode.HALF_UP);
    }

    private static boolean sameDecimal(BigDecimal left, BigDecimal right) {
        return left == null ? right == null
                : right != null && left.compareTo(right) == 0;
    }

    private static String normalizedDecimalKey(BigDecimal value) {
        return value == null ? null
                : value.stripTrailingZeros().toPlainString();
    }

    /**
     * A draft shipment is already a warehouse allocation even though it has
     * not consumed ATP. Source rows are locked before other active drafts are
     * summed, preventing concurrent clerks from assigning the same reservation
     * to multiple pick tasks.
     */
    private void lockAndValidateDraftAllocation(
            ShipmentSaveRequest req,
            UUID excludedShipmentId,
            boolean requireActivatedChain) {
        if (req.getItems() == null) return;
        List<ShipmentItemLine> linked = req.getItems().stream()
                .filter(line -> line.getOrderItemId() != null).toList();
        if (linked.isEmpty()) return;
        List<UUID> ids = linked.stream().map(ShipmentItemLine::getOrderItemId)
                .distinct().sorted().toList();
        List<UUID> orderIds = com.uten.imp.common.util.NativeQueryResults.typedRows(
                em.createNativeQuery("""
                SELECT DISTINCT order_id
                FROM sales_order_items
                WHERE id IN (:ids) AND COALESCE(is_deleted,false) = false
                ORDER BY order_id
                """).setParameter("ids", ids), UUID.class);
        if (orderIds.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, "来源订单行已变化，请刷新后重试");
        }
        List<UUID> locked = com.uten.imp.common.util.NativeQueryResults.typedRows(
                em.createNativeQuery("""
                SELECT id
                FROM sales_order_items
                WHERE order_id IN (:orderIds)
                  AND COALESCE(is_deleted,false) = false
                ORDER BY id
                FOR UPDATE
                """).setParameter("orderIds", orderIds), UUID.class);
        if (!locked.containsAll(ids)) {
            throw new ApiException(ErrorCode.CONFLICT, "来源订单行已变化，请刷新后重试");
        }

        String exclusion = excludedShipmentId == null
                ? "" : " AND s.id <> CAST(:excludedShipmentId AS uuid)\n";
        jakarta.persistence.Query allocationQuery = em.createNativeQuery("""
                SELECT i.id, COALESCE(i.reserved_qty,0), COALESCE(i.chain_status,0),
                       COALESCE(SUM(si.qty) FILTER (WHERE s.id IS NOT NULL),0)
                FROM sales_order_items i
                LEFT JOIN sales_shipment_items si
                  ON si.order_item_id = i.id
                 AND COALESCE(si.is_deleted,false) = false
                LEFT JOIN sales_shipments s
                  ON s.id = si.shipment_id
                 AND COALESCE(s.is_deleted,false) = false
                 AND s.status = 0
                 AND COALESCE(s.rejected,false) = false
                """ + exclusion + """
                WHERE i.id IN (:ids)
                GROUP BY i.id, i.reserved_qty, i.chain_status
                ORDER BY i.id
                """).setParameter("ids", ids);
        if (excludedShipmentId != null) {
            allocationQuery.setParameter("excludedShipmentId", excludedShipmentId);
        }
        Map<UUID, Object[]> capacity = new HashMap<>();
        for (Object[] row : com.uten.imp.common.util.NativeQueryResults.objectArrayRows(allocationQuery)) {
            capacity.put((UUID) row[0], row);
        }
        Map<UUID, BigDecimal> requested = new HashMap<>();
        for (ShipmentItemLine line : linked) {
            if (line.getQty() == null || line.getQty().signum() <= 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "出货数量必须大于 0");
            }
            requested.merge(line.getOrderItemId(), line.getQty(), BigDecimal::add);
        }
        for (UUID id : ids) {
            Object[] row = capacity.get(id);
            if (row == null) {
                throw new ApiException(ErrorCode.CONFLICT, "来源订单行已变化，请刷新后重试");
            }
            BigDecimal reserved = row[1] == null ? BigDecimal.ZERO : (BigDecimal) row[1];
            int chainStatus = ((Number) row[2]).intValue();
            BigDecimal drafted = row[3] == null ? BigDecimal.ZERO : (BigDecimal) row[3];
            // deliberately did not invent reservations for migrated open
            // orders. A new warehouse task must not silently turn that
            // unknown history into a hard promise. Existing LEGACY_PENDING
            // drafts retain their compatibility lane; new-flow documents fail
            // early until a per-order migration reconciliation activates the
            // chain explicitly.
            requireActivatedReservationChain(
                    requireActivatedChain, chainStatus);
            if (chainStatus > 0
                    && drafted.add(requested.getOrDefault(id, BigDecimal.ZERO))
                    .compareTo(reserved) > 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "订单可发预留已被其它待备货单占用，请刷新后重试");
            }
        }
    }

    static void requireActivatedReservationChain(
            boolean requiredForNewFlow, int chainStatus) {
        if (requiredForNewFlow && chainStatus <= 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "历史订单尚未完成库存、已发与旧排产对账，不能创建新仓库任务；请先完成订单链路激活");
        }
    }

    private void assertShipmentPolicy(ShipmentSaveRequest request) {
        Map<UUID, BigDecimal> requested = new HashMap<>();
        if (request.getItems() != null) {
            for (ShipmentItemLine line : request.getItems()) {
                if (line.getOrderItemId() != null && line.getQty() != null) {
                    requested.merge(line.getOrderItemId(), line.getQty(), BigDecimal::add);
                }
            }
        }
        assertShipmentPolicy(requested);
    }

    private void assertStoredShipmentPolicy(List<SalesShipmentItem> items) {
        Map<UUID, BigDecimal> requested = new HashMap<>();
        for (SalesShipmentItem item : items) {
            if (item.getOrderItemId() != null && item.getQty() != null) {
                requested.merge(item.getOrderItemId(), item.getQty(), BigDecimal::add);
            }
        }
        assertShipmentPolicy(requested);
    }

    /**
     * A complete shipment must cover the current outstanding quantity of every
     * open line of each referenced order. A customer confirmation is a stored
     * fact; the UI cannot bypass this check by hiding a warning.
     */
    private void assertShipmentPolicy(Map<UUID, BigDecimal> requested) {
        if (requested.isEmpty()) return;
        List<Object[]> rows = com.uten.imp.common.util.NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT i.id, i.order_id, o.bill_no, o.shipment_policy,
                               o.partial_shipment_confirmed_at,
                               GREATEST(
                                   COALESCE(i.qty,0) - COALESCE(i.shipped_qty,0)
                                   + COALESCE(i.returned_qty,0)
                                   - COALESCE(i.flag_qty,0),
                                   0)
                        FROM sales_order_items i
                        JOIN sales_orders o ON o.id = i.order_id
                        WHERE i.order_id IN (
                            SELECT DISTINCT source.order_id
                            FROM sales_order_items source
                            WHERE source.id IN (:ids)
                              AND COALESCE(source.is_deleted,false) = false
                        )
                          AND COALESCE(i.is_deleted,false) = false
                          AND COALESCE(o.is_deleted,false) = false
                        ORDER BY i.order_id, i.id
                        """).setParameter("ids", requested.keySet()));
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, "来源订单已变化，请刷新后重试");
        }
        Map<UUID, ShipmentPolicyState> states = new LinkedHashMap<>();
        Set<UUID> seenRequested = new java.util.HashSet<>();
        for (Object[] row : rows) {
            UUID itemId = (UUID) row[0];
            UUID orderId = (UUID) row[1];
            BigDecimal outstanding = toBd(row[5]);
            BigDecimal shipping = requested.getOrDefault(itemId, BigDecimal.ZERO);
            if (requested.containsKey(itemId)) seenRequested.add(itemId);
            ShipmentPolicyState state = states.computeIfAbsent(
                    orderId,
                    ignored -> new ShipmentPolicyState(
                            String.valueOf(row[2]),
                            row[3] == null
                                    ? SalesOrder.SHIPMENT_POLICY_LEGACY
                                    : String.valueOf(row[3]),
                            false));
            if (shipping.compareTo(outstanding) < 0) {
                state.partial = true;
            }
        }
        if (!seenRequested.containsAll(requested.keySet())) {
            throw new ApiException(ErrorCode.CONFLICT, "来源订单行已变化，请刷新后重试");
        }
        for (ShipmentPolicyState state : states.values()) {
            if (!state.partial) continue;
            if (SalesOrder.SHIPMENT_POLICY_REQUIRE_COMPLETE.equals(state.policy)) {
                throw new ApiException(ErrorCode.BUSINESS,
                        "订单 " + state.billNo + " 要求整单齐套，当前不可部分发货");
            }
            // CUSTOMER_CONFIRM 不再拦截：员工选了这个策略就是这个策略，不强制先登记客户同意
            // 依据——那一步（partial_shipment_confirmed_at）从没做过录入 UI，选了这个策略的
            // 订单此前实际上永远无法部分发货（问题 #16）。字段本身仍保留可选、仍落库，只是
            // 不再当成一道拦审批的门。
        }
    }

    private void assertStoredOrderLinks(SalesShipment shipment,
                                        List<SalesShipmentItem> items,
                                        boolean requireOpenSource,
                                        String... operationAuthorities) {
        ShipmentSaveRequest snapshot = new ShipmentSaveRequest();
        snapshot.setClientId(shipment.getClientId());
        snapshot.setCurrencyId(shipment.getCurrencyId());
        snapshot.setExchangeRate(shipment.getExchangeRate());
        snapshot.setTaxRate(shipment.getTaxRate());
        snapshot.setPaymentStyleId(shipment.getPaymentStyleId());
        snapshot.setSellerId(shipment.getSellerId());
        List<ShipmentItemLine> links = new ArrayList<>(items.size());
        for (SalesShipmentItem item : items) {
            if (item.getQty() == null || item.getQty().signum() <= 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "历史出货明细数量无效，禁止继续联动");
            }
            ShipmentItemLine line = new ShipmentItemLine();
            line.setOrderItemId(item.getOrderItemId());
            line.setGoodsId(item.getGoodsId());
            line.setColorId(item.getColorId());
            line.setUnitId(item.getUnitId());
            line.setUnitRate(item.getUnitRate());
            line.setQty(item.getQty());
            line.setPrice(item.getPrice());
            line.setAmountOriginal(item.getAmountOriginal());
            line.setAmountLocal(item.getAmountLocal());
            line.setCostAmount(item.getCostAmount());
            line.setClientNo(item.getClientNo());
            line.setClientModel(item.getClientModel());
            line.setMaterialPrice(item.getMaterialPrice());
            line.setDieCastPrice(item.getDieCastPrice());
            line.setMachiningPrice(item.getMachiningPrice());
            line.setDiscount(item.getDiscount());
            line.setSourceDocNo(item.getSourceDocNo());
            links.add(line);
        }
        snapshot.setItems(links);
        boolean strictCommercial = shipment.getWarehouseWorkStatus() != null
                && !SalesShipment.WORK_LEGACY_PENDING.equals(
                        shipment.getWarehouseWorkStatus());
        LinkedSource source = validateLinkedOrderItems(
                snapshot, requireOpenSource, false, strictCommercial,
                operationAuthorities);
        if (source.present()
                && !Objects.equals(source.ownerEmployeeId(), shipment.getOwnerEmployeeId())) {
            throw new ApiException(ErrorCode.CONFLICT, "来源订单与出货单归属不一致");
        }
        if (source.present()) {
            if (shipment.getSourceOrderId() == null) {
                applySource(shipment, source);
            } else if (!shipment.getSourceOrderId().equals(source.sourceOrderId())) {
                throw new ApiException(ErrorCode.CONFLICT, "出货单头来源订单与明细关联不一致");
            }
        }
        if (strictCommercial && source.present()) {
            requireStoredCommercialAuthority(
                    shipment, items, links, source.terms());
        }
    }

    private static void requireStoredCommercialAuthority(
            SalesShipment shipment,
            List<SalesShipmentItem> storedItems,
            List<ShipmentItemLine> authoritativeItems,
            CommercialTerms terms) {
        CommercialTerms storedTerms = new CommercialTerms(
                shipment.getCurrencyId(),
                shipment.getTaxRate(),
                shipment.getPaymentStyleId(),
                shipment.getSettlementMethodId(),
                shipment.getSellerId());
        if (terms == null || !sameCommercialTerms(storedTerms, terms)
                || storedItems.size() != authoritativeItems.size()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "出货商业条款与已审订货单不一致，请退回待拣货并重新生成");
        }
        for (int i = 0; i < storedItems.size(); i++) {
            SalesShipmentItem stored = storedItems.get(i);
            ShipmentItemLine expected = authoritativeItems.get(i);
            if (!sameDecimal(stored.getPrice(), expected.getPrice())
                    || !sameDecimal(
                            stored.getAmountOriginal(),
                            expected.getAmountOriginal())
                    || !sameDecimal(
                            stored.getDiscount(), expected.getDiscount())
                    || !sameDecimal(
                            stored.getMachiningPrice(),
                            expected.getMachiningPrice())
                    || stored.getCostAmount() != null
                    || stored.getMaterialPrice() != null
                    || stored.getDieCastPrice() != null
                    || !Objects.equals(
                            stored.getClientNo(), expected.getClientNo())
                    || !Objects.equals(
                            stored.getClientModel(), expected.getClientModel())
                    || !Objects.equals(
                            stored.getSourceDocNo(),
                            expected.getSourceDocNo())) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "出货行金额或来源快照与已审订货单不一致，禁止财审或出库");
            }
        }
    }

    /**
     * Linked chain quantities must remain in one identical goods/color/unit/rate dimension.
     */
    static void requireLinkedDimension(
            UUID goodsId, UUID colorId, UUID unitId, BigDecimal unitRate,
            UUID sourceGoodsId, UUID sourceColorId, UUID sourceUnitId,
            BigDecimal sourceUnitRate, String documentName) {
        if (!Objects.equals(goodsId, sourceGoodsId)
                || !Objects.equals(colorId, sourceColorId)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    documentName + "货品或颜色与来源行不一致");
        }
        if (unitId == null || sourceUnitId == null
                || !Objects.equals(unitId, sourceUnitId)
                || unitRate == null || sourceUnitRate == null
                || unitRate.signum() <= 0 || sourceUnitRate.signum() <= 0
                || unitRate.compareTo(sourceUnitRate) != 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    documentName + "单位或换算率与来源行不一致");
        }
    }

    /**
     * Lock every linked order header and line in one stable order before
     * validating or mutating shipment-chain counters.
     */
    private void lockStoredOrderTargets(List<SalesShipmentItem> items) {
        TreeSet<UUID> ids = new TreeSet<>();
        for (SalesShipmentItem item : items) {
            if (item.getOrderItemId() != null) {
                ids.add(item.getOrderItemId());
            }
        }
        if (ids.isEmpty()) return;
        List<?> locked = em.createNativeQuery("""
                        SELECT i.id
                        FROM sales_order_items i
                        JOIN sales_orders o ON o.id = i.order_id
                        WHERE i.id IN (:ids)
                        ORDER BY o.id, i.id
                        FOR UPDATE OF o, i
                        """)
                .setParameter("ids", ids)
                .getResultList();
        if (locked.size() != ids.size()) {
            throw new ApiException(ErrorCode.CONFLICT, "来源销售订单或订单行不存在");
        }
    }

    private Set<UUID> readableOrderItemIds(List<UUID> ids) {
        if (ids.isEmpty() || !accessPolicy.hasAuthority("sales_order:view")) {
            return Set.of();
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT i.id, o.owner_employee_id
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                WHERE i.id IN (:ids)
                  AND COALESCE(i.is_deleted,false)=false
                  AND COALESCE(o.is_deleted,false)=false
                """).setParameter("ids", ids).getResultList();
        var readScope = accessPolicy.scope();
        java.util.HashSet<UUID> readable = new java.util.HashSet<>();
        for (Object[] row : rows) {
            if (accessPolicy.canRead((UUID) row[1], readScope)) {
                readable.add((UUID) row[0]);
            }
        }
        return readable;
    }

    private boolean isOrderSourceReadable(UUID sourceOrderId) {
        if (sourceOrderId == null) {
            return true;
        }
        if (!accessPolicy.hasAuthority("sales_order:view")) {
            return false;
        }
        @SuppressWarnings("unchecked")
        List<UUID> owners = em.createNativeQuery("""
                SELECT owner_employee_id
                FROM sales_orders
                WHERE id = :sourceOrderId
                  AND COALESCE(is_deleted,false)=false
                """)
                .setParameter("sourceOrderId", sourceOrderId)
                .getResultList();
        return owners.size() == 1 && accessPolicy.canRead(owners.getFirst());
    }

    private static void applySource(SalesShipment shipment, LinkedSource source) {
        UUID previousSourceId = shipment.getSourceOrderId();
        shipment.setSourceOrderId(source.sourceOrderId());
        if (source.present()) {
            shipment.setSourceDocNo(source.sourceBillNo());
        } else if (previousSourceId != null) {
            shipment.setSourceDocNo(null);
        }
    }

    private void applyHeader(ShipmentSaveRequest req, SalesShipment s) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (s.getBillNo() == null || s.getBillNo().isBlank()) {
            s.setBillNo(docNumberService.nextNumber(DocNumberPrefix.SALES_SHIPMENT));
        }
        s.setBillDate(req.getBillDate());
        s.setClientId(req.getClientId());
        s.setWarehouseId(req.getWarehouseId());
        s.setCurrencyId(req.getCurrencyId());
        // Draft shipments do not carry a sales-authored posting rate.
        s.setExchangeRate(null);
        s.setTaxRate(req.getTaxRate());
        if (!(req.getSettlementMethodId() == null && req.getPaymentStyleId() == null
                && s.getSettlementMethodId() == null && s.getPaymentStyleId() != null)) {
            var settlement = com.uten.imp.common.util.SettlementMethodReferenceResolver.resolve(
                    em, req.getSettlementMethodId(), req.getPaymentStyleId(), "结帐方式");
            s.setSettlementMethodId(settlement == null ? null : settlement.id());
            s.setPaymentStyleId(settlement == null ? null : settlement.legacyId());
        }
        s.setSellerId(req.getSellerId());
        s.setSenderId(req.getSenderId());
        s.setShipAddr(req.getShipAddr());
        s.setLinkPhone(req.getLinkPhone());
        s.setParcelCount(req.getParcelCount());
        s.setLogisticsNo(trimToNull(req.getLogisticsNo()));
        s.setRemark(req.getRemark());
    }

    private static String trimToNull(String value) {
        if (value == null) return null;
        String trimmed = value.trim();
        return trimmed.isEmpty() ? null : trimmed;
    }

    private List<ShipmentItemDto> saveItems(SalesShipment s, List<ShipmentItemLine> lines) {
        Map<UUID, SalesGoodsSnapshot> orderSnapshots = SalesGoodsSnapshot.fromOrderItems(
                em,
                lines.stream().map(ShipmentItemLine::getOrderItemId).toList(),
                SalesGoodsSnapshot.ORDER_ITEM_AT_SAVE);
        Map<UUID, SalesGoodsSnapshot> masterSnapshots = SalesGoodsSnapshot.fromMaster(
                em,
                lines.stream()
                        .filter(line -> line.getOrderItemId() == null
                                || !orderSnapshots.containsKey(line.getOrderItemId()))
                        .map(ShipmentItemLine::getGoodsId)
                        .toList(),
                SalesGoodsSnapshot.MASTER_AT_SAVE);
        List<ShipmentItemDto> out = new ArrayList<>(lines.size());
        int auto = 1;
        for (ShipmentItemLine l : lines) {
            requireNonNegativeCommercialLine(l);
            SalesShipmentItem it = new SalesShipmentItem();
            it.setShipmentId(s.getId());
            it.setBillNo(s.getBillNo());
            it.setBillDate(s.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            it.setOrderItemId(l.getOrderItemId());
            it.setGoodsId(l.getGoodsId());
            applyGoodsSnapshot(
                    it,
                    preferredSnapshot(
                            orderSnapshots, l.getOrderItemId(), masterSnapshots,
                            l.getGoodsId(), "销售出货明细"),
                    null);
            it.setColorId(l.getColorId());
            it.setUnitId(l.getUnitId());
            it.setUnitRate(l.getUnitRate());
            it.setQty(l.getQty());
            it.setPrice(l.getPrice());
            it.setAmountOriginal(l.getAmountOriginal());
            // Draft input cannot author a local-currency fact. SHIPPED is the
            // only transition that writes amount_local from the finance rate.
            it.setAmountLocal(null);
            it.setCostAmount(l.getCostAmount());
            it.setWeight(l.getWeight());
            it.setParcelQty(l.getParcelQty());
            it.setCartonCount(l.getCartonCount());
            it.setClientNo(l.getClientNo());
            it.setClientModel(l.getClientModel());
            it.setMaterialPrice(l.getMaterialPrice());
            it.setDieCastPrice(l.getDieCastPrice());
            it.setMachiningPrice(l.getMachiningPrice());
            it.setCircumference(l.getCircumference());
            it.setDiscount(l.getDiscount());
            it.setSourceDocNo(l.getSourceDocNo());
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            out.add(toItemDto(it));
            auto++;
        }
        return out;
    }

    private void captureGoodsSnapshots(
            List<SalesShipmentItem> items, boolean approval, OffsetDateTime lockedAt) {
        Map<UUID, SalesGoodsSnapshot> orderSnapshots = SalesGoodsSnapshot.fromOrderItems(
                em,
                items.stream().map(SalesShipmentItem::getOrderItemId).toList(),
                approval
                        ? SalesGoodsSnapshot.ORDER_ITEM_AT_APPROVAL
                        : SalesGoodsSnapshot.ORDER_ITEM_AT_SAVE);
        Map<UUID, SalesGoodsSnapshot> masterSnapshots = SalesGoodsSnapshot.fromMaster(
                em,
                items.stream()
                        .filter(item -> item.getOrderItemId() == null
                                || !orderSnapshots.containsKey(item.getOrderItemId()))
                        .map(SalesShipmentItem::getGoodsId)
                        .toList(),
                approval
                        ? SalesGoodsSnapshot.MASTER_AT_APPROVAL
                        : SalesGoodsSnapshot.MASTER_AT_SAVE);
        for (SalesShipmentItem item : items) {
            applyGoodsSnapshot(
                    item,
                    preferredSnapshot(
                            orderSnapshots, item.getOrderItemId(), masterSnapshots,
                            item.getGoodsId(), "销售出货明细"),
                    lockedAt);
        }
    }

    private static SalesGoodsSnapshot preferredSnapshot(
            Map<UUID, SalesGoodsSnapshot> preferred,
            UUID preferredId,
            Map<UUID, SalesGoodsSnapshot> master,
            UUID goodsId,
            String subject) {
        SalesGoodsSnapshot inherited = preferredId == null ? null : preferred.get(preferredId);
        return inherited != null
                ? inherited
                : SalesGoodsSnapshot.require(master, goodsId, subject);
    }

    private static void applyGoodsSnapshot(
            SalesShipmentItem item, SalesGoodsSnapshot snapshot, OffsetDateTime lockedAt) {
        item.setGoodsCodeSnapshot(snapshot.code());
        item.setGoodsNameSnapshot(snapshot.name());
        item.setGoodsSnapshotSource(snapshot.source());
        item.setGoodsSnapshotLockedAt(lockedAt);
    }

    private void applyTotals(SalesShipment s, List<ShipmentItemDto> items) {
        BigDecimal original = items.stream()
                .map(i -> i.getAmountOriginal() == null ? BigDecimal.ZERO : i.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        s.setTotalLocal(null);
        s.setTotalOriginal(original);
        requireNonNegativeTotals(s);
        shipmentRepo.save(s);
    }

    private static void requireNonNegativeCommercialLine(
            ShipmentItemLine line) {
        if (line.getQty() == null || line.getQty().signum() <= 0
                || isNegative(line.getPrice())
                || isNegative(line.getAmountOriginal())
                || isNegative(line.getAmountLocal())
                || isNegative(line.getCostAmount())
                || isNegative(line.getMaterialPrice())
                || isNegative(line.getDieCastPrice())
                || isNegative(line.getMachiningPrice())) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "出货数量必须大于 0，价格与金额不得为负数");
        }
    }

    private static void requireNonNegativeStoredCommercial(
            List<SalesShipmentItem> items) {
        for (SalesShipmentItem item : items) {
            if (item.getQty() == null || item.getQty().signum() <= 0
                    || isNegative(item.getPrice())
                    || isNegative(item.getAmountOriginal())
                    || isNegative(item.getAmountLocal())
                    || isNegative(item.getCostAmount())
                    || isNegative(item.getMaterialPrice())
                    || isNegative(item.getDieCastPrice())
                    || isNegative(item.getMachiningPrice())) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "出货明细存在无效负数或非正数量，禁止财审或出库");
            }
        }
    }

    private static void requireNonNegativeTotals(SalesShipment shipment) {
        if (shipment.getTotalOriginal() == null
                || shipment.getTotalOriginal().signum() < 0
                || isNegative(shipment.getTotalLocal())) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "出货合计金额无效，禁止财审或出库");
        }
    }

    private static boolean isNegative(BigDecimal value) {
        return value != null && value.signum() < 0;
    }

    private ShipmentListItem toList(
            SalesShipment s, boolean writable, boolean canReject,
            boolean canManageWarehouseWork) {
        boolean canViewCommercial = canViewCommercialData();
        return new ShipmentListItem(s.getId(), s.getBillNo(), s.getBillDate(), s.getClientId(),
                s.getWarehouseId(),
                canViewCommercial ? s.getTotalLocal() : null,
                s.getStatus(), s.isClosed(), s.isArPosted(),
                s.getLegacyId(), s.isRejected(), writable && isEditableState(s), canReject,
                s.getWarehouseWorkStatus(), canManageWarehouseWork);
    }

    private ShipmentItemDto toItemDto(SalesShipmentItem it) {
        return toItemDto(it, true);
    }

    private ShipmentItemDto toItemDto(SalesShipmentItem it, boolean sourceReadable) {
        return new ShipmentItemDto(it.getId(), it.getLineNo(),
                sourceReadable ? it.getOrderItemId() : null, it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(),
                it.getGoodsSnapshotSource(), it.getGoodsSnapshotLockedAt(),
                it.getColorId(), it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(),
                it.getAmountOriginal(), it.getAmountLocal(), it.getCostAmount(), it.getReturnedQty(),
                it.getReturnedAmount(), it.getWeight(), it.getParcelQty(), it.getCartonCount(),
                it.getClientNo(), it.getClientModel(), it.getMaterialPrice(), it.getDieCastPrice(),
                it.getMachiningPrice(), it.getCircumference(), it.getDiscount(),
                sourceReadable ? it.getSourceDocNo() : null,
                it.getRemark());
    }

    private ShipmentDetail toDetail(SalesShipment s, List<ShipmentItemDto> items,
                                    boolean sourceReadable) {
        boolean canViewCommercial = canViewCommercialData();
        List<ShipmentItemDto> visibleItems = canViewCommercial
                ? items : items.stream().map(this::maskCommercial).toList();
        boolean writable = accessPolicy.hasAuthority("sales_shipment:edit")
                && isEditableState(s)
                && accessPolicy.canWrite(s.getOwnerEmployeeId());
        boolean canReject = accessPolicy.hasAuthority(REJECT_AUTHORITY)
                && isRejectableState(s)
                && accessPolicy.canWrite(s.getOwnerEmployeeId(), REJECT_AUTHORITY);
        boolean canManageWarehouseWork =
                accessPolicy.hasAuthority(WAREHOUSE_WORK_AUTHORITY)
                && isWarehouseManageableState(s)
                && accessPolicy.canWrite(
                        s.getOwnerEmployeeId(), WAREHOUSE_WORK_AUTHORITY);
        return new ShipmentDetail(s.getId(), s.getLegacyId(), s.getBillNo(), s.getBillDate(),
                s.getClientId(), s.getWarehouseId(),
                canViewCommercial ? s.getCurrencyId() : null,
                canViewCommercial ? s.getExchangeRate() : null,
                canViewCommercial ? s.getTaxRate() : null,
                canViewCommercial ? s.getPaymentStyleId() : null,
                canViewCommercial ? s.getSettlementMethodId() : null,
                s.getSellerId(), s.getSenderId(), s.getMakerId(), s.getApproverId(),
                s.getShipAddr(), s.getLinkPhone(), s.getLogisticsNo(),
                s.getParcelCount(), s.getPrintCount(), s.getLastDate(),
                s.getRemark(),
                canViewCommercial ? s.getTotalOriginal() : null,
                canViewCommercial ? s.getTotalLocal() : null,
                s.getStatus(), s.isClosed(),
                sourceReadable ? s.getSourceOrderId() : null,
                sourceReadable ? s.getSourceDocNo() : null,
                s.isArPosted(), s.isRejected(), s.getRejectReason(),
                s.getFinanceAudit(), s.getFinanceAuditedAt(),
                s.getWarehouseWorkStatus(), s.getWarehouseWorkUpdatedAt(),
                s.getPickingStartedAt(), s.getPickedAt(), s.getHandedOverAt(),
                s.getWarehouseExceptionReason(), visibleItems,
                nameResolver.nameOf(s.getMakerId()), s.getCreatedAt(), writable,
                canReject, canManageWarehouseWork, !canViewCommercial);
    }

    private ShipmentItemDto maskCommercial(ShipmentItemDto item) {
        return new ShipmentItemDto(
                item.getId(), item.getLineNo(), item.getOrderItemId(),
                item.getGoodsId(), item.getGoodsCodeSnapshot(), item.getGoodsNameSnapshot(),
                item.getGoodsSnapshotSource(), item.getGoodsSnapshotLockedAt(),
                item.getColorId(), item.getUnitId(),
                item.getUnitRate(), item.getQty(),
                null, null, null, null,
                item.getReturnedQty(), null,
                item.getWeight(), item.getParcelQty(), item.getCartonCount(),
                item.getClientNo(), item.getClientModel(),
                null, null, null,
                item.getCircumference(), null,
                item.getSourceDocNo(), item.getRemark());
    }

    private boolean canViewCommercialData() {
        return accessPolicy.hasAuthority(SalesPriceMasker.PERM)
                || accessPolicy.hasAuthority(FINANCE_AUDIT_AUTHORITY);
    }

    private boolean isRejectableState(SalesShipment shipment) {
        return shipment.getStatus() != null
                && shipment.getStatus() == STATUS_DRAFT
                && !shipment.isRejected()
                && (shipment.getFinanceAudit() == null
                    || shipment.getFinanceAudit() != 1)
                && (SalesShipment.WORK_PENDING_PICK.equals(
                        shipment.getWarehouseWorkStatus())
                    || SalesShipment.WORK_LEGACY_PENDING.equals(
                        shipment.getWarehouseWorkStatus()));
    }

    private boolean isEditableState(SalesShipment shipment) {
        return shipment.getStatus() != null
                && shipment.getStatus() == STATUS_DRAFT
                && !shipment.isRejected()
                && (shipment.getFinanceAudit() == null
                    || shipment.getFinanceAudit() != 1)
                && (SalesShipment.WORK_PENDING_PICK.equals(
                        shipment.getWarehouseWorkStatus())
                    || SalesShipment.WORK_LEGACY_PENDING.equals(
                        shipment.getWarehouseWorkStatus()));
    }

    private boolean isWarehouseManageableState(SalesShipment shipment) {
        return shipment.getStatus() != null
                && shipment.getStatus() == STATUS_DRAFT
                && !shipment.isRejected()
                && !SalesShipment.WORK_LEGACY_PENDING.equals(
                        shipment.getWarehouseWorkStatus());
    }

    private SalesShipment requireShipment(UUID id) {
        return shipmentRepo.findById(id).filter(s -> !s.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "销售出货单不存在"));
    }

    private SalesShipment requireReadableShipment(UUID id) {
        SalesShipment shipment = requireShipment(id);
        accessPolicy.requireReadable(shipment.getOwnerEmployeeId(), "销售出货单不存在",
                FINANCE_AUDIT_AUTHORITY, REJECT_AUTHORITY,
                WAREHOUSE_WORK_AUTHORITY);
        return shipment;
    }

    private SalesShipment requireWritableShipmentForUpdate(
            UUID id, String... operationAuthorities) {
        SalesShipment shipment = em.find(
                SalesShipment.class, id, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (shipment == null || shipment.isDeleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "销售出货单不存在");
        }
        accessPolicy.requireWritable(shipment.getOwnerEmployeeId(), "无权操作该销售出货单",
                operationAuthorities);
        return shipment;
    }

    private record LinkedSource(
            boolean present,
            UUID sourceOrderId,
            String sourceBillNo,
            UUID ownerEmployeeId,
            CommercialTerms terms) {}
    private record CommercialTerms(
            UUID currencyId,
            BigDecimal taxRate,
            Integer paymentStyleId,
            UUID settlementMethodId,
            UUID sellerId) {}
    private record BatchGroupKey(
            UUID clientId,
            UUID ownerEmployeeId,
            UUID currencyId,
            String taxRate,
            Integer paymentStyleId,
            UUID settlementMethodId,
            UUID sellerId,
            UUID sourceOrderId) {}

    private static final class ShipmentPolicyState {
        private final String billNo;
        private final String policy;
        private boolean partial;

        private ShipmentPolicyState(String billNo, String policy, boolean partial) {
            this.billNo = billNo;
            this.policy = policy;
            this.partial = partial;
        }
    }
}
