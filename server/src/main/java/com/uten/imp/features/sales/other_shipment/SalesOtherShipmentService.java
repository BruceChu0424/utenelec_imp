package com.uten.imp.features.sales.other_shipment;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.SalesGoodsSnapshot;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentDetail;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentItemDto;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentItemLine;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentListItem;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentQueryFilter;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentSaveRequest;
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
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * 其它出货单服务：CRUD + 审核状态机。
 *
 * <p>审核（status 0→1）：**仅**库存出库（TYPE_SALES_OTHER_OUT / DIR_OUT）。
 * <b>不</b>回写订单（即使 order_item_id 字段在，Service 不动它）；
 * <b>不</b>调 ArApService（不立应收）—— 尊重老库 TRI_OCStockItem 对应段已注释的语义
 * （design 20 §〇/§4.1）。红冲反向入库，无 ar 校验。
 *
 * <p>无 ar_posted 列；无 reverseArAp 调用。是销售四单据中约束最简的一类。
 */
@Service
@RequiredArgsConstructor
public class SalesOtherShipmentService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "total", "totalLocal");

    private final SalesOtherShipmentRepository shipmentRepo;
    private final SalesOtherShipmentItemRepository itemRepo;
    private final StockService stockService;
    private final TxSessionVars tx;
    private final DocNumberService docNumberService;
    private final EntityManager em;
    private final com.uten.imp.security.SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final SalesDocumentAccessPolicy accessPolicy;
    // 客户收货地址簿学习（V300）：保存时记住本次地址+电话，ADR-017 全限定名内联。
    private final com.uten.imp.features.master.client.ClientShipAddressService clientShipAddressService;

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_other_shipment:view')")
    public PageResponse<OtherShipmentListItem> list(OtherShipmentQueryFilter f, int page, int size, String sort, String order) {
        var readScope = accessPolicy.scope();
        Specification<SalesOtherShipment> spec = (Root<SalesOtherShipment> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
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
            if (f.outType() != null && !f.outType().isBlank()) ps.add(cb.equal(root.get("outType"), f.outType()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<SalesOtherShipment> p = shipmentRepo.findAll(spec, pageable);
        boolean canEdit = hasObjectActionAuthority();
        return new PageResponse<>(p.map(s -> toList(s,
                        canEdit && accessPolicy.canWrite(s.getOwnerEmployeeId(), readScope))).getContent(),
                page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_other_shipment:view')")
    public OtherShipmentDetail detail(UUID id) {
        SalesOtherShipment s = requireReadableShipment(id);
        List<SalesOtherShipmentItem> entities = itemRepo.findByShipmentIdOrderByLineNoAsc(id);
        Set<UUID> readableOrderItems = readableOrderItemIds(entities.stream()
                .map(SalesOtherShipmentItem::getOrderItemId).filter(Objects::nonNull).toList());
        List<OtherShipmentItemDto> items = entities.stream()
                .map(item -> toItemDto(item,
                        item.getOrderItemId() == null || readableOrderItems.contains(item.getOrderItemId())))
                .toList();
        boolean headerSourceReadable = isOrderSourceReadable(s.getSourceOrderId());
        return toDetail(s, items, headerSourceReadable,
                hasObjectActionAuthority()
                        && accessPolicy.canWrite(s.getOwnerEmployeeId()));
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_other_shipment:create')")
    public OtherShipmentDetail create(OtherShipmentSaveRequest req) {
        tx.bind();
        LinkedSource source = validateLinkedOrderItems(req);
        SalesOtherShipment s = new SalesOtherShipment();
        applyHeader(req, s);
        applySource(s, source);
        s.setOwnerEmployeeId(accessPolicy.ownerForNewDocument(source.ownerEmployeeId()));
        s.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
        s.setStatus(STATUS_DRAFT);
        shipmentRepo.save(s);
        List<OtherShipmentItemDto> items = saveItems(s, req.getItems());
        applyTotals(s, items);
        clientShipAddressService.learn(s.getClientId(), s.getShipAddr(), s.getLinkPhone());
        return toDetail(s, items, true, true);
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_other_shipment:edit')")
    public OtherShipmentDetail update(UUID id, OtherShipmentSaveRequest req) {
        tx.bind();
        SalesOtherShipment s = requireWritableShipment(id);
        if (s.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        LinkedSource source = validateLinkedOrderItems(req);
        if (source.present() && !Objects.equals(source.ownerEmployeeId(), s.getOwnerEmployeeId())) {
            throw new ApiException(ErrorCode.CONFLICT, "来源订单与其它出货单归属不一致");
        }
        applyHeader(req, s);
        applySource(s, source);
        itemRepo.deleteByShipmentId(id);
        itemRepo.flush();
        List<OtherShipmentItemDto> items = saveItems(s, req.getItems());
        applyTotals(s, items);
        clientShipAddressService.learn(s.getClientId(), s.getShipAddr(), s.getLinkPhone());
        return toDetail(s, items, true, true);
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_other_shipment:delete')")
    public void delete(UUID id) {
        tx.bind();
        SalesOtherShipment s = requireWritableShipment(id);
        if (s.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        }
        s.setDeleted(true);
        s.setDeletedAt(OffsetDateTime.now());
        shipmentRepo.save(s);
    }

    /**
     * 审核：status 0→1，仅库存出库（TYPE_SALES_OTHER_OUT / DIR_OUT）。
     * 不回写订单、不立应收（design 20 §4.1）。client_id 可空（内部领用）。
     */
    @Transactional
    @PreAuthorize("hasAuthority('sales_other_shipment:approve')")
    public OtherShipmentDetail approve(UUID id) {
        tx.bind();
        SalesOtherShipment s = requireWritableShipment(id);
        em.refresh(s, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 锁行并重读最新状态，防陈旧快照绕过状态守卫（TOCTOU，对齐 M28）
        if (s.getStatus() == null || s.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (s.getWarehouseId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "出货单需指定仓库");
        }
        List<SalesOtherShipmentItem> items = itemRepo.findByShipmentIdOrderByLineNoAsc(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        }
        stockService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        OffsetDateTime now = OffsetDateTime.now();
        captureGoodsSnapshots(items, true, now);
        for (SalesOtherShipmentItem it : items) {
            applyMovement(s, it, StockService.DIR_OUT, now, null);
            // 刻意不回写 order_item_id（业务上不挂订单）
        }
        s.setStatus(STATUS_APPROVED);
        s.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        s.setLastDate(now);
        shipmentRepo.save(s);
        return detail(id);
    }

    /** 红冲：status 1→-1，反向入库（无 ar 校验，无回写）。 */
    @Transactional
    @PreAuthorize("hasAuthority('sales_other_shipment:reverse')")
    public OtherShipmentDetail reverse(UUID id) {
        tx.bind();
        SalesOtherShipment s = requireWritableShipment(id);
        em.refresh(s, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 锁行并重读最新状态，防陈旧快照绕过状态守卫（TOCTOU，对齐 M28）
        if (s.getStatus() == null || s.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        List<SalesOtherShipmentItem> items = itemRepo.findByShipmentIdOrderByLineNoAsc(id);
        stockService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        OffsetDateTime now = OffsetDateTime.now();
        // 反向只翻 direction；amountLocal 传正数（StockService 内部乘 direction）。negate 会致金额符号不回滚。
        for (SalesOtherShipmentItem it : items) {
            applyMovement(s, it, StockService.DIR_IN, now, null);
        }
        s.setStatus(STATUS_REVERSED);
        shipmentRepo.save(s);
        return detail(id);
    }

    private void applyMovement(SalesOtherShipment s, SalesOtherShipmentItem it, short direction,
                               OffsetDateTime ts, BigDecimal overrideAmount) {
        BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
        BigDecimal baseQty = it.getQty().multiply(rate);
        BigDecimal amt = overrideAmount != null ? overrideAmount : it.getAmountLocal();
        stockService.recordMovement(new StockService.MovementRequest(
                ts, StockService.TYPE_SALES_OTHER_OUT, StockService.SRC_SALES_OTHER_SHIPMENT,
                s.getId(), it.getId(), it.getGoodsId(), it.getColorId(), s.getWarehouseId(),
                direction, baseQty, it.getUnitId(), it.getUnitRate(), amt,
                direction < 0 ? null : "红冲"));
    }

    private LinkedSource validateLinkedOrderItems(OtherShipmentSaveRequest req) {
        if (req.getItems() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "其它出货明细不能为空");
        }
        List<OtherShipmentItemLine> linked = req.getItems().stream()
                .filter(line -> line.getOrderItemId() != null).toList();
        if (linked.isEmpty()) {
            return new LinkedSource(false, null, null, null);
        }
        if (!accessPolicy.hasAuthority("sales_order:view")) {
            throw new ApiException(ErrorCode.FORBIDDEN, "无权引用销售订单");
        }
        List<UUID> ids = linked.stream().map(OtherShipmentItemLine::getOrderItemId).toList();
        if (Set.copyOf(ids).size() != ids.size()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "同一订单行不能重复关联");
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT i.id, i.goods_id, o.client_id, o.owner_employee_id, o.status,
                       o.id, o.bill_no
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
        var writeScope = accessPolicy.scope();
        UUID commonOwner = null;
        boolean ownerInitialized = false;
        UUID commonOrderId = null;
        String commonOrderNo = null;
        for (OtherShipmentItemLine line : linked) {
            Object[] row = byId.get(line.getOrderItemId());
            if (row == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "来源订单行不存在或已删除");
            }
            UUID owner = (UUID) row[3];
            accessPolicy.requireWritable(owner, "无权引用该销售订单行", writeScope);
            UUID orderId = (UUID) row[5];
            if (commonOrderId == null) {
                commonOrderId = orderId;
                commonOrderNo = (String) row[6];
            } else if (!commonOrderId.equals(orderId)) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "一张其它出货单只能关联同一张销售订单");
            }
            if (!ownerInitialized) {
                commonOwner = owner;
                ownerInitialized = true;
            } else if (!Objects.equals(commonOwner, owner)) {
                throw new ApiException(ErrorCode.CONFLICT, "一张其它出货单不能合并不同归属人的订单行");
            }
            if (!Objects.equals(req.getClientId(), row[2])) {
                throw new ApiException(ErrorCode.CONFLICT, "其它出货客户与来源订单客户不一致");
            }
            if (!Objects.equals(line.getGoodsId(), row[1])) {
                throw new ApiException(ErrorCode.CONFLICT, "其它出货货品与来源订单行不一致");
            }
            if (row[4] == null || ((Number) row[4]).shortValue() != STATUS_APPROVED) {
                throw new ApiException(ErrorCode.BUSINESS, "仅可引用已审核销售订单");
            }
        }
        return new LinkedSource(true, commonOrderId, commonOrderNo, commonOwner);
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

    private static void applySource(
            SalesOtherShipment shipment, LinkedSource source) {
        UUID previousSourceId = shipment.getSourceOrderId();
        shipment.setSourceOrderId(source.sourceOrderId());
        if (source.present()) {
            shipment.setSourceDocNo(source.sourceBillNo());
        } else if (previousSourceId != null) {
            shipment.setSourceDocNo(null);
        }
    }

    private void applyHeader(OtherShipmentSaveRequest req, SalesOtherShipment s) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (s.getBillNo() == null || s.getBillNo().isBlank()) {
            s.setBillNo(docNumberService.nextNumber(DocNumberPrefix.SALES_OTHER_SHIPMENT));
        }
        s.setBillDate(req.getBillDate());
        s.setClientId(req.getClientId());
        s.setWarehouseId(req.getWarehouseId());
        s.setCurrencyId(req.getCurrencyId());
        s.setExchangeRate(req.getExchangeRate());
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
        s.setOutType(req.getOutType());
        s.setRemark(req.getRemark());
    }

    private List<OtherShipmentItemDto> saveItems(SalesOtherShipment s, List<OtherShipmentItemLine> lines) {
        Map<UUID, SalesGoodsSnapshot> orderSnapshots = SalesGoodsSnapshot.fromOrderItems(
                em,
                lines.stream().map(OtherShipmentItemLine::getOrderItemId).toList(),
                SalesGoodsSnapshot.ORDER_ITEM_AT_SAVE);
        Map<UUID, SalesGoodsSnapshot> masterSnapshots = SalesGoodsSnapshot.fromMaster(
                em,
                lines.stream()
                        .filter(line -> line.getOrderItemId() == null
                                || !orderSnapshots.containsKey(line.getOrderItemId()))
                        .map(OtherShipmentItemLine::getGoodsId)
                        .toList(),
                SalesGoodsSnapshot.MASTER_AT_SAVE);
        List<OtherShipmentItemDto> out = new ArrayList<>(lines.size());
        int auto = 1;
        for (OtherShipmentItemLine l : lines) {
            SalesOtherShipmentItem it = new SalesOtherShipmentItem();
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
                            l.getGoodsId(), "销售其他出库明细"),
                    null);
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

    private void captureGoodsSnapshots(
            List<SalesOtherShipmentItem> items, boolean approval, OffsetDateTime lockedAt) {
        Map<UUID, SalesGoodsSnapshot> orderSnapshots = SalesGoodsSnapshot.fromOrderItems(
                em,
                items.stream().map(SalesOtherShipmentItem::getOrderItemId).toList(),
                approval
                        ? SalesGoodsSnapshot.ORDER_ITEM_AT_APPROVAL
                        : SalesGoodsSnapshot.ORDER_ITEM_AT_SAVE);
        Map<UUID, SalesGoodsSnapshot> masterSnapshots = SalesGoodsSnapshot.fromMaster(
                em,
                items.stream()
                        .filter(item -> item.getOrderItemId() == null
                                || !orderSnapshots.containsKey(item.getOrderItemId()))
                        .map(SalesOtherShipmentItem::getGoodsId)
                        .toList(),
                approval
                        ? SalesGoodsSnapshot.MASTER_AT_APPROVAL
                        : SalesGoodsSnapshot.MASTER_AT_SAVE);
        for (SalesOtherShipmentItem item : items) {
            applyGoodsSnapshot(
                    item,
                    preferredSnapshot(
                            orderSnapshots, item.getOrderItemId(), masterSnapshots,
                            item.getGoodsId(), "销售其他出库明细"),
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
            SalesOtherShipmentItem item, SalesGoodsSnapshot snapshot, OffsetDateTime lockedAt) {
        item.setGoodsCodeSnapshot(snapshot.code());
        item.setGoodsNameSnapshot(snapshot.name());
        item.setGoodsSnapshotSource(snapshot.source());
        item.setGoodsSnapshotLockedAt(lockedAt);
    }

    private void applyTotals(SalesOtherShipment s, List<OtherShipmentItemDto> items) {
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

    private OtherShipmentListItem toList(SalesOtherShipment s, boolean writable) {
        return new OtherShipmentListItem(s.getId(), s.getBillNo(), s.getBillDate(), s.getClientId(),
                s.getWarehouseId(), s.getOutType(), s.getTotalLocal(), s.getStatus(), s.isClosed(),
                s.getLegacyId(), writable);
    }

    private OtherShipmentItemDto toItemDto(SalesOtherShipmentItem it) {
        return toItemDto(it, true);
    }

    private OtherShipmentItemDto toItemDto(SalesOtherShipmentItem it, boolean sourceReadable) {
        return new OtherShipmentItemDto(it.getId(), it.getLineNo(),
                sourceReadable ? it.getOrderItemId() : null, it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(),
                it.getGoodsSnapshotSource(), it.getGoodsSnapshotLockedAt(),
                it.getColorId(), it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(),
                it.getAmountOriginal(), it.getAmountLocal(), it.getCostAmount(), it.getWeight(),
                it.getParcelQty(), it.getCartonCount(), it.getClientNo(), it.getClientModel(),
                it.getMaterialPrice(), it.getDieCastPrice(), it.getMachiningPrice(), it.getCircumference(),
                it.getDiscount(), it.getReturnedQty(), it.getReturnedAmount(),
                sourceReadable ? it.getSourceDocNo() : null,
                it.getRemark());
    }

    private OtherShipmentDetail toDetail(SalesOtherShipment s, List<OtherShipmentItemDto> items,
                                         boolean sourceReadable, boolean writable) {
        return new OtherShipmentDetail(s.getId(), s.getLegacyId(), s.getBillNo(), s.getBillDate(),
                s.getClientId(), s.getWarehouseId(), s.getCurrencyId(), s.getExchangeRate(), s.getTaxRate(),
                s.getPaymentStyleId(), s.getSettlementMethodId(), s.getSellerId(), s.getSenderId(),
                s.getMakerId(), s.getApproverId(),
                s.getShipAddr(), s.getLinkPhone(), s.getParcelCount(), s.getPrintCount(), s.getLastDate(),
                s.getOutType(), s.getRemark(), s.getTotalOriginal(), s.getTotalLocal(), s.getStatus(),
                s.isClosed(), sourceReadable ? s.getSourceOrderId() : null,
                sourceReadable ? s.getSourceDocNo() : null, items,
                nameResolver.nameOf(s.getMakerId()), s.getCreatedAt(), writable);
    }

    private boolean hasObjectActionAuthority() {
        return accessPolicy.hasAuthority("sales_other_shipment:edit")
                || accessPolicy.hasAuthority("sales_other_shipment:delete")
                || accessPolicy.hasAuthority("sales_other_shipment:approve")
                || accessPolicy.hasAuthority("sales_other_shipment:reverse");
    }

    private SalesOtherShipment requireShipment(UUID id) {
        return shipmentRepo.findById(id).filter(s -> !s.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "其它出货单不存在"));
    }

    private SalesOtherShipment requireReadableShipment(UUID id) {
        SalesOtherShipment shipment = requireShipment(id);
        accessPolicy.requireReadable(shipment.getOwnerEmployeeId(), "其它出货单不存在");
        return shipment;
    }

    private SalesOtherShipment requireWritableShipment(UUID id) {
        SalesOtherShipment shipment = requireShipment(id);
        accessPolicy.requireWritable(shipment.getOwnerEmployeeId(), "只能操作本人负责的其它出货单");
        return shipment;
    }

    private record LinkedSource(
            boolean present,
            UUID sourceOrderId,
            String sourceBillNo,
            UUID ownerEmployeeId) {}
}
