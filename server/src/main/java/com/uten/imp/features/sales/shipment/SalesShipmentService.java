package com.uten.imp.features.sales.shipment;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.finance.arap.ArApLedgerService.ArApPostingRequest;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
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
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * 销售出货单服务：CRUD（主+明细）+ 审核状态机（库存 + 订单回写 + 立应收 + 结案）。
 *
 * <p>审核（status 0→1）同事务内：
 * <ol>
 *   <li>挂单行超发硬校验（未发余量；链上行还须 ≤ 预留量，V90）</li>
 *   <li>消耗库存软预留（FIFO + 行锁，全局预留改绑出货仓，V90）</li>
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
 * <p>取代老库 S_Out 触发器 TRI_SOStockItem（库存段）+ 钱流立 M_in 段（design 20 §〇/§4.3）。
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
        var readScope = accessPolicy.scope(FINANCE_AUDIT_AUTHORITY, REJECT_AUTHORITY);
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
        var writeScope = canEdit ? accessPolicy.scope() : null;
        var rejectScope = hasRejectAuthority ? accessPolicy.scope(REJECT_AUTHORITY) : null;
        return new PageResponse<>(p.map(s -> toList(
                        s,
                        canEdit && accessPolicy.canWrite(s.getOwnerEmployeeId(), writeScope),
                        hasRejectAuthority && isRejectableState(s)
                                && accessPolicy.canWrite(s.getOwnerEmployeeId(), rejectScope))).getContent(),
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
                        item.getOrderItemId() == null || readableOrderItems.contains(item.getOrderItemId())))
                .toList();
        boolean hasLinkedSource = entities.stream().anyMatch(item -> item.getOrderItemId() != null);
        boolean headerSourceReadable = s.getSourceDocNo() == null || s.getSourceDocNo().isBlank()
                || (hasLinkedSource
                ? entities.stream()
                        .filter(item -> item.getOrderItemId() != null)
                        .allMatch(item -> readableOrderItems.contains(item.getOrderItemId()))
                : isOrderSourceDocReadable(s.getSourceDocNo()));
        return toDetail(s, items, headerSourceReadable);
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_shipment:edit')")
    public ShipmentDetail create(ShipmentSaveRequest req) {
        tx.bind();
        LinkedSource source = validateLinkedOrderItems(req);
        SalesShipment s = new SalesShipment();
        applyHeader(req, s);
        s.setOwnerEmployeeId(accessPolicy.ownerForNewDocument(source.ownerEmployeeId()));
        s.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
        s.setStatus(STATUS_DRAFT);
        shipmentRepo.save(s);
        List<ShipmentItemDto> items = saveItems(s, req.getItems());
        applyTotals(s, items);
        return toDetail(s, items, true);
    }

    /**
     * 批量发货开单（SOP §一9）：按客户 + 归属人分组，同组才合并一张出货草稿。
     * 逐行硬校验：订单行必须当前仍有可发预留（reserved>0）且本次数量不超预留；
     * 归属隔离与订单列表同口径（不可见归属的行直接拒绝）。
     * 草稿不锁定库存——审核时既有超发硬校验 + FIFO 消耗预留兜底（行锁防并发超卖）。
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
                SELECT i.id, i.goods_id, i.color_id, i.unit_id, i.unit_rate, i.price, i.reserved_qty,
                       o.client_id, o.currency_id, o.bill_no, o.owner_employee_id, o.status, o.is_stopped, o.is_closed
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                WHERE i.id IN (:ids) AND COALESCE(i.is_deleted,false) = false AND COALESCE(o.is_deleted,false) = false
                """).setParameter("ids", ids).getResultList();
        Map<UUID, Object[]> byId = new HashMap<>();
        for (Object[] r : rows) byId.put((UUID) r[0], r);

        var writeScope = accessPolicy.scope();
        // 分组键同时包含客户与原始 owner，绝不跨归属合并。
        Map<BatchGroupKey, List<ShipmentItemLine>> grouped = new LinkedHashMap<>();
        Map<BatchGroupKey, UUID> currencyByGroup = new HashMap<>();
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
            BatchGroupKey key = new BatchGroupKey((UUID) r[7], owner);
            grouped.computeIfAbsent(key, ignored -> new ArrayList<>()).add(l);
            currencyByGroup.putIfAbsent(key, (UUID) r[8]);
        }

        List<ShipmentDetail> out = new ArrayList<>(grouped.size());
        for (var e : grouped.entrySet()) {
            ShipmentSaveRequest one = new ShipmentSaveRequest();
            one.setBillDate(req.getBillDate());
            one.setClientId(e.getKey().clientId());
            one.setWarehouseId(req.getWarehouseId());
            one.setCurrencyId(currencyByGroup.get(e.getKey()));
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
        SalesShipment s = requireWritableShipment(id);
        if (s.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        if (s.isRejected()) {
            throw new ApiException(ErrorCode.BUSINESS, "已驳回的出货单不可编辑，请删除后重新开单");
        }
        LinkedSource source = validateLinkedOrderItems(req);
        if (source.present() && !Objects.equals(source.ownerEmployeeId(), s.getOwnerEmployeeId())) {
            throw new ApiException(ErrorCode.CONFLICT, "来源订单与出货单归属不一致");
        }
        applyHeader(req, s);
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
        SalesShipment s = requireWritableShipment(id);
        if (s.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        }
        s.setDeleted(true);
        s.setDeletedAt(OffsetDateTime.now());
        shipmentRepo.save(s);
    }

    // ======================== C6 财务发货审核 ========================

    /** 现金结算客户（price_style=1）出货前闸门：finance_audit 须为 1。月结等其它结算方式不拦截。 */
    private void assertFinanceAudited(SalesShipment s) {
        Object ps = em.createNativeQuery("SELECT price_style FROM clients WHERE id = :id")
                .setParameter("id", s.getClientId()).getSingleResult();
        boolean cash = ps != null && ((Number) ps).intValue() == 1;
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
        SalesShipment s = requireWritableShipment(id, FINANCE_AUDIT_AUTHORITY);
        em.lock(s, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (s.getFinanceAudit() != null && s.getFinanceAudit() == 1) {
            throw new ApiException(ErrorCode.BUSINESS, "已财务审核，请勿重复操作");
        }
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
        SalesShipment s = requireWritableShipment(id, FINANCE_AUDIT_AUTHORITY);
        em.lock(s, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (s.getStatus() != null && s.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核出货的单据不可财务反审");
        }
        s.setFinanceAudit((short) 0);
        s.setFinanceAuditorId(null);
        s.setFinanceAuditedAt(null);
        shipmentRepo.save(s);
        return financeAuditInfo(s);
    }

    /** 财务审核辅助信息：结算方式 + 客户未收余额（立帐−收款）。 */
    private Map<String, Object> financeAuditInfo(SalesShipment s) {
        Object[] c = (Object[]) em.createNativeQuery("""
                SELECT c.name, c.price_style,
                       (SELECT COALESCE(SUM(CASE WHEN l.direction='AR' THEN l.amount_original_local ELSE 0 END),0)
                        FROM ar_ap_ledger l WHERE l.client_id=c.id AND l.is_deleted=false AND l.status=1)
                       - (SELECT COALESCE(SUM(r.amount_local),0)
                        FROM finance_receipts r WHERE r.client_id=c.id AND COALESCE(r.is_deleted,false)=false AND r.status=1)
                FROM clients c WHERE c.id = :id
                """).setParameter("id", s.getClientId()).getSingleResult();
        Integer priceStyle = c[1] == null ? null : ((Number) c[1]).intValue();
        return Map.of(
                "shipmentId", s.getId(),
                "financeAudit", s.getFinanceAudit(),
                "clientName", c[0] == null ? "" : c[0],
                "priceStyle", priceStyle == null ? -1 : priceStyle,
                "cashClient", priceStyle != null && priceStyle == 1,
                "outstanding", c[2] == null ? java.math.BigDecimal.ZERO : c[2]);
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_shipment:edit')")
    public ShipmentDetail approve(UUID id) {
        tx.bind();
        SalesShipment s = requireWritableShipment(id);
        em.lock(s, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 并发审核/红冲互斥（多账号同单操作）
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
        // C6 财务发货审核：现金结算客户（clients.price_style=1）须财务审核「已审发货」后才允许仓库审核出货
        assertFinanceAudited(s);
        List<SalesShipmentItem> items = itemRepo.findByShipmentIdOrderByLineNoAsc(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        }
        assertStoredOrderLinks(s, items, true);
        stockService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());

        OffsetDateTime now = OffsetDateTime.now();
        for (SalesShipmentItem it : items) {
            if (it.getOrderItemId() != null) {
                validateShippable(it); // 超发硬校验（未发余量 + 链上行预留量）
                BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
                // 消耗预留（FIFO + 行锁；链上行才有预留，无预留时实耗 0 不报错——历史单兼容）
                reservationService.consumeForOrderItem(it.getOrderItemId(), s.getWarehouseId(),
                        it.getQty().multiply(rate));
            }
            applyMovement(s, it, StockService.DIR_OUT, now, null);
            if (it.getOrderItemId() != null) {
                addShippedQty(it.getOrderItemId(), it.getQty()); // +qty
                applyReservedAndChainOnShip(it.getOrderItemId(), it.getQty().negate()); // 预留扣减 + 行状态推进
                recalcOrderClosed(it.getOrderItemId());
            }
        }

        // 立应收（AR, SALES_SHIPMENT, BStyle=3, 正应收）。金额为本币总额（正数）。
        if (!s.isArPosted()) {
            arApService.postArAp(new ArApPostingRequest(
                    "AR",
                    StockService.SRC_SALES_SHIPMENT,
                    s.getId(), s.getBillNo(), s.getBillDate(),
                    s.getClientId(), null,
                    s.getCurrencyId(), s.getExchangeRate(),
                    s.getTotalLocal(),
                    BSTYLE_SALES_SHIPMENT,
                    s.getRemark()));
            s.setArPosted(true);
        }

        s.setStatus(STATUS_APPROVED);
        s.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        s.setLastDate(now);
        shipmentRepo.save(s);
        chainNotice.notifyShipmentApproved(id); // 旁路通知：发货→订单归属销售，提交后发送
        return detail(id);
    }

    /** 仓库驳回（V96）：草稿出货单备货异常 → 逐行释放预留 + 订单行回退待排产，缺口自动回调度待排产列表。 */
    @Transactional
    @PreAuthorize("hasAuthority('sales_shipment:reject')")
    public ShipmentDetail reject(UUID id, String reason) {
        tx.bind();
        SalesShipment s = requireWritableShipment(id, REJECT_AUTHORITY);
        em.lock(s, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 并发互斥
        if (s.getStatus() == null || s.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿（待备货）出货单可驳回；已审核请走红冲");
        }
        if (s.isRejected()) {
            throw new ApiException(ErrorCode.BUSINESS, "该出货单已驳回");
        }
        List<SalesShipmentItem> items = itemRepo.findByShipmentIdOrderByLineNoAsc(id);
        assertStoredOrderLinks(s, items, true, REJECT_AUTHORITY);
        for (SalesShipmentItem it : items) {
            if (it.getOrderItemId() == null || chainStatusOf(it.getOrderItemId()) <= 0) continue;
            BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
            // 释放该行对应预留（货损/丢失/找不到 → 这批货不再属于该订单）
            reservationService.releaseForOrderItem(it.getOrderItemId(), it.getQty().multiply(rate));
            // reserved_qty 回减 + 行状态回退：可发→7 / 已排产→4 / 否则→2 待排产（重走生产）
            em.createNativeQuery("""
                    UPDATE sales_order_items
                    SET reserved_qty = GREATEST(0, COALESCE(reserved_qty,0) - :q),
                        chain_status = CASE WHEN COALESCE(chain_status,0) > 0 THEN
                            CASE
                              WHEN GREATEST(0, COALESCE(reserved_qty,0) - :q)
                                   >= COALESCE(qty,0) - COALESCE(shipped_qty,0) THEN 7
                              WHEN COALESCE(planned_qty,0) > 0 THEN 4
                              ELSE 2 END
                        ELSE chain_status END
                    WHERE id = :id
                    """).setParameter("q", it.getQty()).setParameter("id", it.getOrderItemId())
                    .executeUpdate();
        }
        s.setRejected(true);
        s.setRejectReason(reason == null || reason.isBlank() ? "仓库备货异常" : reason.trim());
        shipmentRepo.save(s);
        chainNotice.notifyShipmentRejected(id, reason); // 旁路通知：驳回→订单归属销售，提交后发送
        return detail(id);
    }

    /** 红冲：status 1→-1，先校验收款核销 → 反向库存 + 回减 shipped_qty + 结案重算 + ar_posted=false。 */
    @Transactional
    @PreAuthorize("hasAuthority('sales_shipment:edit')")
    public ShipmentDetail reverse(UUID id) {
        tx.bind();
        SalesShipment s = requireWritableShipment(id);
        em.lock(s, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 并发审核/红冲互斥（多账号同单操作）
        if (s.getStatus() == null || s.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        List<SalesShipmentItem> items = itemRepo.findByShipmentIdOrderByLineNoAsc(id);
        assertStoredOrderLinks(s, items, false);
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

        s.setStatus(STATUS_REVERSED);
        shipmentRepo.save(s);
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
        em.createNativeQuery("""
                UPDATE sales_order_items
                SET reserved_qty = GREATEST(0, COALESCE(reserved_qty,0) + :d),
                    chain_status = CASE WHEN COALESCE(chain_status,0) > 0 THEN
                        CASE WHEN COALESCE(qty,0) - COALESCE(shipped_qty,0) <= 0 THEN 9 ELSE 8 END
                    ELSE COALESCE(chain_status,0) END
                WHERE id = :id
                """).setParameter("d", delta).setParameter("id", orderItemId).executeUpdate();
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
                        WHEN COALESCE(reserved_qty,0) + :d >= COALESCE(qty,0) - COALESCE(shipped_qty,0) THEN 7
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
        return validateLinkedOrderItems(req, true, true, new String[0]);
    }

    private LinkedSource validateLinkedOrderItems(ShipmentSaveRequest req,
                                                   boolean requireOpenSource,
                                                   boolean rejectDuplicateLinks,
                                                   String... operationAuthorities) {
        if (req.getItems() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "出货明细不能为空");
        }
        List<ShipmentItemLine> linked = req.getItems().stream()
                .filter(line -> line.getOrderItemId() != null).toList();
        if (linked.isEmpty()) {
            return new LinkedSource(false, null);
        }
        List<UUID> ids = linked.stream().map(ShipmentItemLine::getOrderItemId).toList();
        if (rejectDuplicateLinks && Set.copyOf(ids).size() != ids.size()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "同一订单行不能在出货单中重复关联");
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT i.id, i.goods_id, o.client_id, o.owner_employee_id,
                       o.status, o.is_stopped, o.is_closed, o.bill_no
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
        for (ShipmentItemLine line : linked) {
            Object[] row = byId.get(line.getOrderItemId());
            if (row == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "来源订单行不存在或已删除");
            }
            UUID owner = (UUID) row[3];
            accessPolicy.requireWritable(owner, "无权引用该销售订单行", writeScope);
            if (!ownerInitialized) {
                commonOwner = owner;
                ownerInitialized = true;
            } else if (!Objects.equals(commonOwner, owner)) {
                throw new ApiException(ErrorCode.CONFLICT, "一张出货单不能合并不同归属人的订单行");
            }
            if (!Objects.equals(req.getClientId(), row[2])) {
                throw new ApiException(ErrorCode.CONFLICT, "出货客户与来源订单客户不一致");
            }
            if (!Objects.equals(line.getGoodsId(), row[1])) {
                throw new ApiException(ErrorCode.CONFLICT, "出货货品与来源订单行不一致");
            }
            short status = row[4] == null ? 0 : ((Number) row[4]).shortValue();
            if (status != STATUS_APPROVED
                    || (requireOpenSource && (Boolean.TRUE.equals(row[5]) || Boolean.TRUE.equals(row[6])))) {
                throw new ApiException(ErrorCode.BUSINESS, "来源订单 " + row[7] + " 当前不可发货");
            }
        }
        return new LinkedSource(true, commonOwner);
    }

    private void assertStoredOrderLinks(SalesShipment shipment,
                                        List<SalesShipmentItem> items,
                                        boolean requireOpenSource,
                                        String... operationAuthorities) {
        ShipmentSaveRequest snapshot = new ShipmentSaveRequest();
        snapshot.setClientId(shipment.getClientId());
        List<ShipmentItemLine> links = new ArrayList<>(items.size());
        for (SalesShipmentItem item : items) {
            ShipmentItemLine line = new ShipmentItemLine();
            line.setOrderItemId(item.getOrderItemId());
            line.setGoodsId(item.getGoodsId());
            links.add(line);
        }
        snapshot.setItems(links);
        LinkedSource source = validateLinkedOrderItems(
                snapshot, requireOpenSource, false, operationAuthorities);
        if (source.present()
                && !Objects.equals(source.ownerEmployeeId(), shipment.getOwnerEmployeeId())) {
            throw new ApiException(ErrorCode.CONFLICT, "来源订单与出货单归属不一致");
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

    private boolean isOrderSourceDocReadable(String sourceDocNo) {
        @SuppressWarnings("unchecked")
        List<UUID> owners = em.createNativeQuery("""
                SELECT owner_employee_id
                FROM sales_orders
                WHERE bill_no = :billNo
                  AND COALESCE(is_deleted,false)=false
                LIMIT 1
                """)
                .setParameter("billNo", sourceDocNo)
                .getResultList();
        // A free-form external reference is part of this shipment itself. Only
        // an actual internal order reference needs cross-document protection.
        return owners.isEmpty()
                || accessPolicy.hasAuthority("sales_order:view")
                && accessPolicy.canRead(owners.getFirst());
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
        s.setExchangeRate(req.getExchangeRate());
        s.setTaxRate(req.getTaxRate());
        s.setPaymentStyleId(req.getPaymentStyleId());
        s.setSellerId(req.getSellerId());
        s.setSenderId(req.getSenderId());
        s.setShipAddr(req.getShipAddr());
        s.setLinkPhone(req.getLinkPhone());
        s.setParcelCount(req.getParcelCount());
        s.setRemark(req.getRemark());
    }

    private List<ShipmentItemDto> saveItems(SalesShipment s, List<ShipmentItemLine> lines) {
        List<ShipmentItemDto> out = new ArrayList<>(lines.size());
        int auto = 1;
        for (ShipmentItemLine l : lines) {
            SalesShipmentItem it = new SalesShipmentItem();
            it.setShipmentId(s.getId());
            it.setBillNo(s.getBillNo());
            it.setBillDate(s.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            it.setOrderItemId(l.getOrderItemId());
            it.setGoodsId(l.getGoodsId());
            it.setColorId(l.getColorId());
            it.setUnitId(l.getUnitId());
            it.setUnitRate(l.getUnitRate());
            it.setQty(l.getQty());
            it.setPrice(l.getPrice());
            it.setAmountOriginal(l.getAmountOriginal());
            it.setAmountLocal(l.getAmountLocal() != null ? l.getAmountLocal() : l.getAmountOriginal());
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

    private void applyTotals(SalesShipment s, List<ShipmentItemDto> items) {
        BigDecimal local = items.stream()
                .map(i -> i.getAmountLocal() == null ? BigDecimal.ZERO : i.getAmountLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = items.stream()
                .map(i -> i.getAmountOriginal() == null ? BigDecimal.ZERO : i.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        s.setTotalLocal(local);
        s.setTotalOriginal(original);
        shipmentRepo.save(s);
    }

    private ShipmentListItem toList(SalesShipment s, boolean writable, boolean canReject) {
        return new ShipmentListItem(s.getId(), s.getBillNo(), s.getBillDate(), s.getClientId(),
                s.getWarehouseId(), s.getTotalLocal(), s.getStatus(), s.isClosed(), s.isArPosted(),
                s.getLegacyId(), s.isRejected(), writable, canReject);
    }

    private ShipmentItemDto toItemDto(SalesShipmentItem it) {
        return toItemDto(it, true);
    }

    private ShipmentItemDto toItemDto(SalesShipmentItem it, boolean sourceReadable) {
        return new ShipmentItemDto(it.getId(), it.getLineNo(),
                sourceReadable ? it.getOrderItemId() : null, it.getGoodsId(),
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
        boolean writable = accessPolicy.hasAuthority("sales_shipment:edit")
                && accessPolicy.canWrite(s.getOwnerEmployeeId());
        boolean canReject = accessPolicy.hasAuthority(REJECT_AUTHORITY)
                && isRejectableState(s)
                && accessPolicy.canWrite(s.getOwnerEmployeeId(), REJECT_AUTHORITY);
        return new ShipmentDetail(s.getId(), s.getLegacyId(), s.getBillNo(), s.getBillDate(),
                s.getClientId(), s.getWarehouseId(), s.getCurrencyId(), s.getExchangeRate(), s.getTaxRate(),
                s.getPaymentStyleId(), s.getSellerId(), s.getSenderId(), s.getMakerId(), s.getApproverId(),
                s.getShipAddr(), s.getLinkPhone(), s.getParcelCount(), s.getPrintCount(), s.getLastDate(),
                s.getRemark(), s.getTotalOriginal(), s.getTotalLocal(), s.getStatus(), s.isClosed(),
                sourceReadable ? s.getSourceDocNo() : null,
                s.isArPosted(), s.isRejected(), s.getRejectReason(),
                s.getFinanceAudit(), s.getFinanceAuditedAt(), items,
                nameResolver.nameOf(s.getMakerId()), s.getCreatedAt(), writable, canReject);
    }

    private boolean isRejectableState(SalesShipment shipment) {
        return shipment.getStatus() != null
                && shipment.getStatus() == STATUS_DRAFT
                && !shipment.isRejected();
    }

    private SalesShipment requireShipment(UUID id) {
        return shipmentRepo.findById(id).filter(s -> !s.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "销售出货单不存在"));
    }

    private SalesShipment requireReadableShipment(UUID id) {
        SalesShipment shipment = requireShipment(id);
        accessPolicy.requireReadable(shipment.getOwnerEmployeeId(), "销售出货单不存在",
                FINANCE_AUDIT_AUTHORITY, REJECT_AUTHORITY);
        return shipment;
    }

    private SalesShipment requireWritableShipment(UUID id, String... operationAuthorities) {
        SalesShipment shipment = requireShipment(id);
        accessPolicy.requireWritable(shipment.getOwnerEmployeeId(), "无权操作该销售出货单",
                operationAuthorities);
        return shipment;
    }

    private record LinkedSource(boolean present, UUID ownerEmployeeId) {}
    private record BatchGroupKey(UUID clientId, UUID ownerEmployeeId) {}
}
