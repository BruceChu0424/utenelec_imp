package com.uten.imp.features.sales.ret;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.saleschain.SalesChainStatus;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.integrity.NonNegativeCommercialSignGuard;
import com.uten.imp.features.finance.arap.ArApLedgerService;
import com.uten.imp.features.finance.arap.ArApLedgerService.ArApPostingRequest;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.SalesGoodsSnapshot;
import com.uten.imp.features.sales.ret.dto.CustomerDispositionRequest;
import com.uten.imp.features.sales.ret.dto.ReturnDetail;
import com.uten.imp.features.sales.ret.dto.ReturnItemDto;
import com.uten.imp.features.sales.ret.dto.ReturnItemLine;
import com.uten.imp.features.sales.ret.dto.ReturnListItem;
import com.uten.imp.features.sales.ret.dto.ReturnQueryFilter;
import com.uten.imp.features.sales.ret.dto.ReturnSaveRequest;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.StockReservation;
import com.uten.imp.features.stock.StockReservationService;
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
import java.math.RoundingMode;
import java.nio.charset.StandardCharsets;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.TreeSet;
import java.util.UUID;

/**
 * 销售退货单服务：CRUD（主+明细）+ 质检冻结审核状态机。
 *
 * <p>审核（status 0→1）同事务内：
 * <ol>
 *   <li>逐明细创建质检冻结数量和追加式收货事件；审核本身不增加可售库存</li>
 *   <li>双挂回写：sales_shipment_items.returned_qty/returned_amount += qty/amt（out_item_id 非空时）
 *       + sales_order_items.returned_qty += qty（order_item_id 非空时）+ 订货结案重算</li>
 *   <li>{@link ArApLedgerService#postArAp} 立红字应收（AR, SALES_RETURN, BStyle=18, amountOriginalLocal=负数）</li>
 *   <li>ar_posted=true</li>
 * </ol>
 *
 * <p>红冲（1→-1）同事务反向：先 {@link ArApLedgerService#reverseArAp}（钱流校验无收款核销，否则抛
 * "此单已经存在收/付款，请先反审"），再反向未处置的冻结收货。已有质检处置时拒绝整单普通红冲；
 * 无质检行的历史已审退货仍精确反向原库存流水。两条路径都回减 returned_qty、重算订货结案并清除 ar_posted。
 *
 * <p>处理库存段 + 钱流立 M_in 红字段（design 20 §〇/§4.4）。
 *
 * <p>金额口径（design 20 §6.1/§7.3）：明细 amount 与主表 total 均为正数；红字负数仅在 ar_ap_ledger
 * 立帐时由 Service 取负传入（amountOriginalLocal = -totalLocal）。
 */
@Service
@RequiredArgsConstructor
public class SalesReturnService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 老库 BStyle=18 销售退货红字应收。 */
    private static final short BSTYLE_SALES_RETURN = 18;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "total", "totalLocal");

    private final SalesReturnRepository returnRepo;
    private final SalesReturnItemRepository itemRepo;
    private final StockService stockService;
    private final StockReservationService reservationService;
    private final ArApLedgerService arApService;
    private final TxSessionVars tx;
    private final EntityManager em;
    // V476：叶子仓落库校验。字段注入+可空——单测手工构造时缺省跳过，Spring 环境恒注入。
    @org.springframework.beans.factory.annotation.Autowired(required = false)
    private com.uten.imp.features.master.warehouse.WarehouseScopeService warehouseScopes;
    private final com.uten.imp.security.SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final DocNumberService docNumberService;
    private final SalesDocumentAccessPolicy accessPolicy;
    private final SalesReturnQualityService qualityService;
    private final SalesReturnAmountAuthority returnAmountAuthority;
    private final com.uten.imp.features.sales.SalesMutationFootprintService mutationFootprint;
    private final com.uten.imp.application.port.SalesReturnInventoryValuePort inventoryValue;

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_return:view')")
    public PageResponse<ReturnListItem> list(ReturnQueryFilter f, int page, int size, String sort, String order) {
        var readScope = accessPolicy.scope();
        Specification<SalesReturn> spec = (Root<SalesReturn> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
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
        Page<SalesReturn> p = returnRepo.findAll(spec, pageable);
        boolean canEdit = hasObjectActionAuthority();
        return new PageResponse<>(p.map(r -> toList(r,
                        canEdit && accessPolicy.canWrite(r.getOwnerEmployeeId(), readScope))).getContent(),
                p);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_return:view')")
    public ReturnDetail detail(UUID id) {
        SalesReturn r = requireReadableReturn(id);
        List<SalesReturnItem> entities = itemRepo.findByReturnIdOrderByLineNoAsc(id);
        Set<UUID> readableShipmentItems = readableShipmentItemIds(entities.stream()
                .map(SalesReturnItem::getOutItemId).filter(Objects::nonNull).toList());
        Set<UUID> readableOrderItems = readableOrderItemIds(entities.stream()
                .map(SalesReturnItem::getOrderItemId).filter(Objects::nonNull).toList());
        List<ReturnItemDto> items = entities.stream().map(item -> {
            boolean shipmentReadable = item.getOutItemId() == null
                    || readableShipmentItems.contains(item.getOutItemId());
            boolean orderReadable = item.getOrderItemId() == null
                    || readableOrderItems.contains(item.getOrderItemId());
            return toItemDto(item, shipmentReadable, orderReadable);
        }).toList();
        boolean headerSourceReadable = isShipmentSourceReadable(r.getSourceShipmentId());
        return toDetail(r, items, headerSourceReadable,
                hasObjectActionAuthority()
                        && accessPolicy.canWrite(r.getOwnerEmployeeId()));
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_return:create')")
    public ReturnDetail create(ReturnSaveRequest req) {
        tx.bind();
        mutationFootprint.lockReturn(null, requestedFootprint(req));
        LinkedSource source = validateLinkedSources(req);
        SalesReturn r = new SalesReturn();
        applyHeader(req, r);
        applySource(r, source);
        r.setOwnerEmployeeId(accessPolicy.ownerForNewDocument(source.ownerEmployeeId()));
        r.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
        r.setStatus(STATUS_DRAFT);
        returnRepo.save(r);
        List<ReturnItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items, true, true);
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_return:edit')")
    public ReturnDetail update(UUID id, ReturnSaveRequest req) {
        tx.bind();
        SalesReturn r = requireWritableReturnForUpdate(id, requestedFootprint(req));
        if (r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        LinkedSource source = validateLinkedSources(req);
        if (source.present() && !Objects.equals(source.ownerEmployeeId(), r.getOwnerEmployeeId())) {
            throw new ApiException(ErrorCode.CONFLICT, "来源单据与退货单归属不一致");
        }
        applyHeader(req, r);
        applySource(r, source);
        itemRepo.deleteByReturnId(id);
        itemRepo.flush();
        List<ReturnItemDto> items = saveItems(r, req.getItems());
        applyTotals(r, items);
        return toDetail(r, items, true, true);
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_return:delete')")
    public void delete(UUID id) {
        tx.bind();
        SalesReturn r = requireWritableReturnForUpdate(id);
        com.uten.imp.common.web.StandardDocumentLifecycleCapabilities.requireDraftForDelete(r.getStatus());
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        returnRepo.save(r);
    }

    /**
     * 审核：status 0→1，创建质检冻结（不进可售库存），双挂回写 shipment/order
     * 的 returned_qty，立红字应收，并重算订货结案。
     */
    @Transactional
    @PreAuthorize("hasAuthority('sales_return:approve')")
    public ReturnDetail approve(UUID id) {
        tx.bind();
        SalesReturn r = requireWritableReturnForUpdate(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        if (r.getWarehouseId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "退货单需指定仓库");
        }
        if (warehouseScopes != null) {
            warehouseScopes.requireActiveLeafWarehouse(r.getWarehouseId(), "入库仓库");
        }
        if (r.getClientId() == null) {
            throw new ApiException(ErrorCode.BUSINESS, "退货单需指定客户");
        }
        List<SalesReturnItem> items = itemRepo.findByReturnIdOrderByLineNoAsc(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        }
        requireNonNegativeStoredCommercial(r, items);
        lockStoredSourceGraph(items);
        assertStoredSources(r, items, true);
        validateReturnWritebackCapacity(items, +1);
        boolean freeCustomerSource=returnAmountAuthority.apply(r, items);
        OffsetDateTime now = OffsetDateTime.now();
        captureGoodsSnapshots(items, true, now);
        // receipt is physically acknowledged into a separate quality
        // quarantine. It is intentionally absent from stock_balances/ATP until
        // an authorized GOOD_RELEASE disposition.
        qualityService.receive(r, items, now);
        for (SalesReturnItem it : items) {
            writeback(it, +1);
        }

        // 立红字应收（AR, SALES_RETURN, BStyle=18）。金额为本币总额的负数（红字，直接冲减客户应收余额）。
        // 主表 totalLocal 为正数（与明细同号），ar_ap_ledger 端取负。
        if (!r.isArPosted() && !freeCustomerSource) {
            BigDecimal negAmount = r.getTotalLocal() == null ? BigDecimal.ZERO : r.getTotalLocal().negate();
            BigDecimal negOriginal = r.getTotalOriginal() == null
                    ? negAmount
                    : r.getTotalOriginal().negate();
            arApService.postArAp(new ArApPostingRequest(
                    "AR",
                    StockService.SRC_SALES_RETURN,
                    r.getId(), r.getBillNo(), r.getBillDate(),
                    r.getClientId(), null,
                    r.getCurrencyId(), r.getExchangeRate(),
                    negAmount,
                    BSTYLE_SALES_RETURN,
                    r.getRemark(),
                    negOriginal,
                    r.getSettlementMethodId()));
            r.setArPosted(true);
        }

        r.setStatus(STATUS_APPROVED);
        r.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        r.setLastDate(now);
        returnRepo.saveAndFlush(r);
        inventoryValue.receivedForInspection(r.getId(),currentUser.requireId());
        return detail(id);
    }

    /**
     * 红冲：status 1→-1。未处置的冻结收货受控反向；无质检行的历史单据反向原库存流水。
     * 已有处置时拒绝整单红冲。随后回减 returned_qty、重算订货结案并清除 ar_posted。
     */
    @Transactional
    @PreAuthorize("hasAuthority('sales_return:reverse')")
    public ReturnDetail reverse(UUID id) {
        tx.bind();
        SalesReturn r = requireWritableReturnForUpdate(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        if (!"PENDING".equals(r.getDispositionStatus())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "退货已确认客户处置(" + r.getCustomerDisposition()
                            + ")，不能直接红冲；请走受控补偿流程后再处理");
        }
        List<SalesReturnItem> items = itemRepo.findByReturnIdOrderByLineNoAsc(id);
        requireNonNegativeStoredCommercial(r, items);
        lockStoredSourceGraph(items);
        assertStoredSources(r, items, false);
        validateReturnWritebackCapacity(items, -1);
        OffsetDateTime now = OffsetDateTime.now();
        // New receipts never entered saleable stock. Historical approved
        // returns have no quality rows and retain the original stock reversal
        // behavior; we do not backfill invented inspection evidence.
        boolean qualityManaged = qualityService.reverseUntouchedReceipt(
                r.getId(), items.size(), now);
        if (!qualityManaged) {
            stockService.lockInventory(items.stream()
                    .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                    .toList());
        }

        // 1. 钱流先校验：若已有收款核销 → reverseArAp 抛 IllegalStateException（阻止红冲）
        if (r.isArPosted()) {
            arApService.reverseArAp(r.getId(), StockService.SRC_SALES_RETURN);
            r.setArPosted(false);
        }

        // 2. 新单只反向未处置冻结；无质检行的历史单才反向原库存流水。
        // 历史反向只翻 direction；amountLocal 传正数，StockService 内部乘 direction。
        for (SalesReturnItem it : items) {
            if (!qualityManaged) {
                applyMovement(r, it, StockService.DIR_OUT, now, null);
            }
            writeback(it, -1);
        }

        r.setStatus(STATUS_REVERSED);
        returnRepo.saveAndFlush(r);
        if(qualityManaged) inventoryValue.untouchedReceiptReversed(r.getId(),currentUser.requireId());
        return detail(id);
    }

    /**
     * 客户处置确认：销售对已审核退货确认客户结论——退款结案/换货/补发/维修后返还。
     *
     * <p>确定影响（SOP：不自动补产、默认不自动加预留）：
     * <ul>
     *   <li>RESHIP / EXCHANGE：重开替换履约——对每条订单行的未满足 outstanding 重新软预留
     *       （BUG-S1 修复；approve 只重算 outstanding 却从不建预留），reserved_qty↑、chain 重算。
     *       仅让需求可见，不自动排产。</li>
     *   <li>REFUND_CLOSED / REPAIR_RETURN：不补产、不发替换——以 flag_qty 关闭替换需求
     *       （outstanding 回落、可能结案），红字应收即最终退款结算。</li>
     * </ul>
     * 处置确认后禁止整单普通红冲（须受控补偿）；决策记入追加式 sales_return_disposition_events。
     */
    @Transactional
    @PreAuthorize("hasAuthority('sales_return:disposition')")
    public ReturnDetail setDisposition(UUID id, CustomerDispositionRequest req) {
        tx.bind();
        var sourceGuard = mutationFootprint.beginReturn(id);
        SalesReturn r = requireWritableReturnAfterPrefix(id);
        if (r.getStatus() == null || r.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核退货单可确认客户处置");
        }
        if (req == null || req.disposition() == null || req.reason() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "客户处置请求不完整");
        }
        String disposition = normalizeDisposition(req.disposition());
        String reason = req.reason().trim();
        if (reason.isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "客户处置原因不能为空");
        }
        if (reason.length() > 500) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "客户处置原因不能超过 500 个字符");
        }
        String idempotencyKey = normalizeIdempotencyKey(req.idempotencyKey());

        // 已决策：同决策幂等返回，不同决策拒绝（one-time，无在线改判）。
        if (!"PENDING".equals(r.getDispositionStatus())) {
            if (disposition.equals(r.getCustomerDisposition()) && reason.equals(r.getDispositionReason())) {
                return detail(id);
            }
            throw new ApiException(ErrorCode.CONFLICT,
                    "该退货单已确认客户处置(" + r.getCustomerDisposition()
                            + ")，如需更改请先走受控补偿流程");
        }
        sourceGuard.verifyUnchanged();

        List<SalesReturnItem> items = itemRepo.findByReturnIdOrderByLineNoAsc(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，无法确认客户处置");
        }
        OffsetDateTime now = OffsetDateTime.now();
        UUID actor = currentUser.requireEmployeeId();

        if ("RESHIP".equals(disposition) || "EXCHANGE".equals(disposition)) {
            reopenFulfilment(r, items);
            r.setFulfilmentReopened(true);
        } else {
            // REFUND_CLOSED / REPAIR_RETURN：不补产、不发替换。
            closeReplacementDemand(items);
        }

        r.setCustomerDisposition(disposition);
        r.setDispositionStatus("DECIDED");
        r.setDispositionDecidedBy(actor);
        r.setDispositionDecidedAt(now);
        r.setDispositionReason(reason);
        returnRepo.save(r);

        appendDispositionEvent(
                dispositionEventId(r.getId(), idempotencyKey),
                r.getId(), disposition, reason, actor, now);
        return detail(id);
    }

    /**
     * 重开替换履约预留（镜像 SalesOrderService.reserveOnApprove）：对每条订单行，把"退货重开的
     * 未满足 outstanding"按当前全局可用量尽量软预留。同货品多行共享递减可用量池，防重复占用。
     * 只让需求可见，不自动排产。
     */
    private void reopenFulfilment(SalesReturn salesReturn, List<SalesReturnItem> items) {
        Map<UUID, List<SalesReturnItem>> byOrder = new java.util.LinkedHashMap<>();
        for (SalesReturnItem it : items) {
            if (it.getOrderItemId() != null) {
                byOrder.computeIfAbsent(it.getOrderItemId(), k -> new ArrayList<>()).add(it);
            }
        }
        if (byOrder.isEmpty()) return;
        reservationService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        Map<String, BigDecimal> pool = new HashMap<>();
        for (UUID orderItemId : byOrder.keySet()) {
            @SuppressWarnings("unchecked")
            List<Object[]> rows = em.createNativeQuery("""
                            SELECT goods_id, color_id, qty, shipped_qty, returned_qty,
                                   flag_qty, reserved_qty, unit_rate
                            FROM sales_order_items
                            WHERE id = :id
                            FOR UPDATE
                            """)
                    .setParameter("id", orderItemId)
                    .getResultList();
            if (rows.size() != 1) continue;
            Object[] row = rows.getFirst();
            UUID goodsId = (UUID) row[0];
            UUID colorId = (UUID) row[1];
            BigDecimal qty = bd(row[2]), shipped = bd(row[3]), returned = bd(row[4]),
                    flagged = bd(row[5]), reserved = bd(row[6]);
            BigDecimal rate = bd(row[7]);
            if (rate.signum() <= 0) rate = BigDecimal.ONE;
            BigDecimal outstanding = qty.subtract(shipped).add(returned).subtract(flagged)
                    .max(BigDecimal.ZERO);
            BigDecimal gap = outstanding.subtract(reserved).max(BigDecimal.ZERO);
            if (gap.signum() <= 0) continue;
            BigDecimal gapBase = gap.multiply(rate);
            String key = goodsId + "|" + (colorId == null ? "" : colorId);
            BigDecimal avail = pool.computeIfAbsent(key,
                    k -> reservationService.globalAvailableBase(goodsId, colorId));
            BigDecimal take = gapBase.min(avail.max(BigDecimal.ZERO));
            if (take.signum() <= 0) continue;
            reservationService.reserve(orderItemId, goodsId, colorId, take,
                    StockReservation.SOURCE_ORDER, "SALES_RETURN_RESHIP", salesReturn.getId());
            pool.put(key, avail.subtract(take));
            BigDecimal addDoc = take.divide(rate, 4, RoundingMode.HALF_UP);
            em.createNativeQuery("""
                    UPDATE sales_order_items
                    SET reserved_qty = COALESCE(reserved_qty, 0) + :add
                    WHERE id = :id
                    """)
                    .setParameter("add", addDoc)
                    .setParameter("id", orderItemId)
                    .executeUpdate();
            recomputeOrderItemChain(orderItemId);
        }
    }

    /**
     * 关闭替换需求（REFUND_CLOSED / REPAIR_RETURN）：把退货量计入 flag_qty，使 outstanding
     * 回落（可能结案），表示公司不补产、不发替换货。flag_qty 此前无人写入（休眠列），
     * 此处赋予"已退款/返修不补产"的确定语义。
     */
    private void closeReplacementDemand(List<SalesReturnItem> items) {
        Map<UUID, BigDecimal> flagByOrder = new java.util.LinkedHashMap<>();
        for (SalesReturnItem it : items) {
            if (it.getOrderItemId() != null && it.getQty() != null && it.getQty().signum() > 0) {
                flagByOrder.merge(it.getOrderItemId(), it.getQty(), BigDecimal::add);
            }
        }
        for (Map.Entry<UUID, BigDecimal> e : flagByOrder.entrySet()) {
            em.createNativeQuery("""
                    UPDATE sales_order_items
                    SET flag_qty = COALESCE(flag_qty, 0) + :q
                    WHERE id = :id
                    """)
                    .setParameter("q", e.getValue())
                    .setParameter("id", e.getKey())
                    .executeUpdate();
            recomputeOrderItemChain(e.getKey());
            recalcOrderClosed(e.getKey());
        }
    }

    private void appendDispositionEvent(UUID eventId, UUID returnId, String disposition,
                                        String reason, UUID actor, OffsetDateTime occurredAt) {
        em.createNativeQuery("""
                INSERT INTO sales_return_disposition_events (
                    id, return_id, action, disposition, reason, actor_employee_id, occurred_at
                ) VALUES (
                    :id, :returnId, 'DISPOSITION_DECIDED', :disposition, :reason, :actor, :occurredAt
                )
                """)
                .setParameter("id", eventId)
                .setParameter("returnId", returnId)
                .setParameter("disposition", disposition)
                .setParameter("reason", reason)
                .setParameter("actor", actor)
                .setParameter("occurredAt", occurredAt)
                .executeUpdate();
    }

    static String normalizeDisposition(String disposition) {
        String normalized = disposition == null ? "" : disposition.trim().toUpperCase(Locale.ROOT);
        if (!Objects.equals(normalized, "REFUND_CLOSED")
                && !Objects.equals(normalized, "EXCHANGE")
                && !Objects.equals(normalized, "RESHIP")
                && !Objects.equals(normalized, "REPAIR_RETURN")) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "客户处置仅支持 REFUND_CLOSED/EXCHANGE/RESHIP/REPAIR_RETURN");
        }
        return normalized;
    }

    static String normalizeIdempotencyKey(String key) {
        String normalized = key == null ? "" : key.strip();
        if (normalized.length() < 8 || normalized.length() > 128
                || !normalized.matches("[A-Za-z0-9._:-]+")) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "客户处置幂等键必须为 8 到 128 位字母、数字或 ._:-");
        }
        return normalized;
    }

    static UUID dispositionEventId(UUID returnId, String idempotencyKey) {
        String canonical = "SALES_RETURN_DISPOSITION|"
                + returnId + "|" + normalizeIdempotencyKey(idempotencyKey);
        return UUID.nameUUIDFromBytes(canonical.getBytes(StandardCharsets.UTF_8));
    }

    /** 写一笔库存流水（方向由调用方给）。qty 为明细量，baseQty = qty×unit_rate。 */
    private void applyMovement(SalesReturn r, SalesReturnItem it, short direction,
                               OffsetDateTime ts, BigDecimal overrideAmount) {
        BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
        BigDecimal baseQty = it.getQty().multiply(rate);
        BigDecimal amt = overrideAmount != null ? overrideAmount : it.getAmountLocal();
        stockService.recordMovement(new StockService.MovementRequest(
                ts, StockService.TYPE_SALES_RETURN, StockService.SRC_SALES_RETURN,
                r.getId(), it.getId(), it.getGoodsId(), it.getColorId(), r.getWarehouseId(),
                direction, baseQty, it.getUnitId(), it.getUnitRate(), amt,
                direction > 0 ? null : "红冲", it.getWeight()));
    }

    /**
     * 双挂回写（sign=+1 审核 / -1 红冲）：
     * <ul>
     *   <li>out_item_id 非空：sales_shipment_items.returned_qty += sign×qty, returned_amount += sign×amountLocal</li>
     *   <li>order_item_id 非空：sales_order_items.returned_qty += sign×qty + 订货结案重算</li>
     * </ul>
     */
    private void writeback(SalesReturnItem it, int sign) {
        BigDecimal amt = it.getAmountLocal() == null ? BigDecimal.ZERO : it.getAmountLocal();
        if (it.getOutItemId() != null) {
            em.createNativeQuery(
                    "UPDATE sales_shipment_items SET returned_qty = COALESCE(returned_qty,0) + (:q * :s), "
                            + "returned_amount = COALESCE(returned_amount,0) + (:a * :s) WHERE id = :id")
                    .setParameter("q", it.getQty()).setParameter("a", amt).setParameter("s", sign)
                    .setParameter("id", it.getOutItemId()).executeUpdate();
        }
        if (it.getOrderItemId() != null) {
            em.createNativeQuery(
                    "UPDATE sales_order_items SET returned_qty = COALESCE(returned_qty,0) + (:q * :s) WHERE id = :id")
                    .setParameter("q", it.getQty()).setParameter("s", sign)
                    .setParameter("id", it.getOrderItemId()).executeUpdate();
            recomputeOrderItemChain(it.getOrderItemId());
            recalcOrderClosed(it.getOrderItemId());
            if (sign > 0) {
                clearStalePartialShipmentConfirmation(
                        it.getOrderItemId());
            }
        }
    }

    /**
     * A customer confirmation describes the fulfilment picture that existed
     * when it was captured. An approved return reopens demand, so reusing that
     * old confirmation for replacement delivery would be a false business
     * fact. Return reversal does not restore it; sales must confirm again.
     */
    private void clearStalePartialShipmentConfirmation(UUID orderItemId) {
        em.createNativeQuery("""
                UPDATE sales_orders o
                SET partial_shipment_confirmed_at = NULL,
                    partial_shipment_confirmed_by = NULL,
                    partial_shipment_confirmation_reason = NULL
                WHERE o.id = (
                    SELECT i.order_id
                    FROM sales_order_items i
                    WHERE i.id = :orderItemId
                )
                  AND o.shipment_policy = 'CUSTOMER_CONFIRM'
                """)
                .setParameter("orderItemId", orderItemId)
                .executeUpdate();
    }

    /**
     * Re-open a fulfilled line after return and close it again after return
     * reversal. All branches use the same authoritative outstanding formula.
     */
    private void recomputeOrderItemChain(UUID orderItemId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT chain_status, qty, shipped_qty, returned_qty, flag_qty,
                               reserved_qty, planned_qty, produced_qty
                        FROM sales_order_items
                        WHERE id = :id
                        FOR UPDATE
                        """)
                .setParameter("id", orderItemId)
                .getResultList();
        if (rows.size() != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "退货关联的销售订单行不存在");
        }
        Object[] row = rows.getFirst();
        short current = row[0] == null ? 0 : ((Number) row[0]).shortValue();
        short next = chainAfterReturn(
                current, bd(row[1]), bd(row[2]), bd(row[3]), bd(row[4]),
                bd(row[5]), bd(row[6]), bd(row[7]));
        em.createNativeQuery("""
                        UPDATE sales_order_items
                        SET chain_status = :chain
                        WHERE id = :id
                        """)
                .setParameter("chain", next)
                .setParameter("id", orderItemId)
                .executeUpdate();
    }

    /** V545：退货/退货红冲后的行状态走统一派生（剩余未排量优先），见 {@link SalesChainStatus#derive}。 */
    static short chainAfterReturn(
            short current, BigDecimal qty, BigDecimal shipped, BigDecimal returned,
            BigDecimal flagged, BigDecimal reserved, BigDecimal planned, BigDecimal produced) {
        return SalesChainStatus.derive(
                current, qty, shipped, returned, flagged, reserved, planned, produced);
    }

    private static BigDecimal bd(Object value) {
        return value == null ? BigDecimal.ZERO : (BigDecimal) value;
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
     * Validate the complete return source chain before persisting the draft.
     * Shipment links automatically inherit their order-item link, preventing a
     * caller from returning against one shipment while writing back another
     * order.
     */
    private LinkedSource validateLinkedSources(ReturnSaveRequest req) {
        if (req.getItems() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "退货明细不能为空");
        }
        List<ReturnItemLine> lines = req.getItems();
        List<UUID> outIds = lines.stream().map(ReturnItemLine::getOutItemId)
                .filter(Objects::nonNull).toList();
        if (Set.copyOf(outIds).size() != outIds.size()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "同一出货行不能在退货单中重复关联");
        }
        if (!outIds.isEmpty() && !accessPolicy.hasAuthority("sales_shipment:view")) {
            throw new ApiException(ErrorCode.FORBIDDEN, "无权引用销售出货单");
        }
        Map<UUID, Object[]> outById = new HashMap<>();
        if (!outIds.isEmpty()) {
            @SuppressWarnings("unchecked")
            List<Object[]> rows = em.createNativeQuery("""
                    SELECT i.id, i.goods_id, i.color_id, i.unit_id, i.unit_rate,
                           o.client_id, o.owner_employee_id,
                           i.order_item_id, o.status, o.id, o.bill_no
                    FROM sales_shipment_items i
                    JOIN sales_shipments o ON o.id = i.shipment_id
                    WHERE i.id IN (:ids)
                      AND COALESCE(i.is_deleted,false)=false
                      AND COALESCE(o.is_deleted,false)=false
                    """).setParameter("ids", outIds).getResultList();
            for (Object[] row : rows) {
                outById.put((UUID) row[0], row);
            }
        }

        for (ReturnItemLine line : lines) {
            if (line.getOutItemId() == null) {
                continue;
            }
            Object[] out = outById.get(line.getOutItemId());
            if (out == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "来源出货行不存在或已删除");
            }
            UUID sourceOrderItemId = (UUID) out[7];
            if (sourceOrderItemId != null) {
                if (line.getOrderItemId() == null) {
                    line.setOrderItemId(sourceOrderItemId);
                } else if (!sourceOrderItemId.equals(line.getOrderItemId())) {
                    throw new ApiException(ErrorCode.CONFLICT, "退货关联的出货行与订单行不一致");
                }
            }
        }

        List<UUID> orderIds = lines.stream().map(ReturnItemLine::getOrderItemId)
                .filter(Objects::nonNull).toList();
        if (!orderIds.isEmpty() && !accessPolicy.hasAuthority("sales_order:view")) {
            throw new ApiException(ErrorCode.FORBIDDEN, "无权引用销售订单");
        }
        Map<UUID, Object[]> orderById = new HashMap<>();
        if (!orderIds.isEmpty()) {
            @SuppressWarnings("unchecked")
            List<Object[]> rows = em.createNativeQuery("""
                    SELECT i.id, i.goods_id, i.color_id, i.unit_id, i.unit_rate,
                           o.client_id, o.owner_employee_id, o.status
                    FROM sales_order_items i
                    JOIN sales_orders o ON o.id = i.order_id
                    WHERE i.id IN (:ids)
                      AND COALESCE(i.is_deleted,false)=false
                      AND COALESCE(o.is_deleted,false)=false
                    """).setParameter("ids", orderIds).getResultList();
            for (Object[] row : rows) {
                orderById.put((UUID) row[0], row);
            }
        }

        var writeScope = accessPolicy.scope();
        List<UUID> sourceOwners = new ArrayList<>();
        UUID commonShipmentId = null;
        String commonShipmentNo = null;
        for (ReturnItemLine line : lines) {
            if (line.getOutItemId() != null) {
                Object[] out = outById.get(line.getOutItemId());
                UUID owner = (UUID) out[6];
                accessPolicy.requireWritable(owner, "无权引用该销售出货行", writeScope);
                sourceOwners.add(owner);
                UUID shipmentId = (UUID) out[9];
                if (commonShipmentId == null) {
                    commonShipmentId = shipmentId;
                    commonShipmentNo = (String) out[10];
                } else if (!commonShipmentId.equals(shipmentId)) {
                    throw new ApiException(
                            ErrorCode.CONFLICT,
                            "一张销售退货单只能关联同一张销售出货单");
                }
                if (!Objects.equals(req.getClientId(), out[5])) {
                    throw new ApiException(ErrorCode.CONFLICT, "退货客户与来源出货客户不一致");
                }
                requireLinkedDimension(
                        line.getGoodsId(), line.getColorId(), line.getUnitId(), line.getUnitRate(),
                        (UUID) out[1], (UUID) out[2], (UUID) out[3], (BigDecimal) out[4],
                        "退货与来源出货");
                if (out[8] == null || ((Number) out[8]).shortValue() != STATUS_APPROVED) {
                    throw new ApiException(ErrorCode.BUSINESS, "仅可退已审核的销售出货");
                }
            }
            if (line.getOrderItemId() != null) {
                Object[] order = orderById.get(line.getOrderItemId());
                if (order == null) {
                    throw new ApiException(ErrorCode.VALIDATION_FAILED, "来源订单行不存在或已删除");
                }
                UUID owner = (UUID) order[6];
                accessPolicy.requireWritable(owner, "无权引用该销售订单行", writeScope);
                sourceOwners.add(owner);
                if (!Objects.equals(req.getClientId(), order[5])) {
                    throw new ApiException(ErrorCode.CONFLICT, "退货客户与来源订单客户不一致");
                }
                requireLinkedDimension(
                        line.getGoodsId(), line.getColorId(), line.getUnitId(), line.getUnitRate(),
                        (UUID) order[1], (UUID) order[2], (UUID) order[3], (BigDecimal) order[4],
                        "退货与来源订单");
                if (order[7] == null || ((Number) order[7]).shortValue() != STATUS_APPROVED) {
                    throw new ApiException(ErrorCode.BUSINESS, "仅可引用已审核销售订单");
                }
            }
        }
        if (sourceOwners.isEmpty()) {
            return new LinkedSource(false, null, null, null);
        }
        UUID commonOwner = sourceOwners.get(0);
        if (sourceOwners.stream().anyMatch(owner -> !Objects.equals(commonOwner, owner))) {
            throw new ApiException(ErrorCode.CONFLICT, "退货来源单据归属不一致");
        }
        return new LinkedSource(
                true, commonShipmentId, commonShipmentNo, commonOwner);
    }

    static void requireLinkedDimension(
            UUID goodsId, UUID colorId, UUID unitId, BigDecimal unitRate,
            UUID sourceGoodsId, UUID sourceColorId, UUID sourceUnitId,
            BigDecimal sourceUnitRate, String documentName) {
        if (!Objects.equals(goodsId, sourceGoodsId)
                || !Objects.equals(colorId, sourceColorId)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    documentName + "货品或颜色不一致");
        }
        if (unitId == null || sourceUnitId == null
                || !Objects.equals(unitId, sourceUnitId)
                || unitRate == null || sourceUnitRate == null
                || unitRate.signum() <= 0 || sourceUnitRate.signum() <= 0
                || unitRate.compareTo(sourceUnitRate) != 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    documentName + "单位或换算率不一致");
        }
    }

    /**
     * Lock the persisted shipment and order source graph in stable UUID order.
     * Old drafts that only stored out_item_id are resolved before locking their
     * order target, so approval cannot race shipment reversal or order changes.
     */
    private void lockStoredSourceGraph(List<SalesReturnItem> items) {
        TreeSet<UUID> outItemIds = new TreeSet<>();
        TreeSet<UUID> orderItemIds = new TreeSet<>();
        for (SalesReturnItem item : items) {
            if (item.getOutItemId() != null) outItemIds.add(item.getOutItemId());
            if (item.getOrderItemId() != null) orderItemIds.add(item.getOrderItemId());
        }

        if (!outItemIds.isEmpty()) {
            @SuppressWarnings("unchecked")
            List<Object[]> rows = em.createNativeQuery("""
                            SELECT i.id, i.order_item_id
                            FROM sales_shipment_items i
                            JOIN sales_shipments s ON s.id = i.shipment_id
                            WHERE i.id IN (:ids)
                            ORDER BY s.id, i.id
                            FOR UPDATE OF s, i
                            """)
                    .setParameter("ids", outItemIds)
                    .getResultList();
            if (rows.size() != outItemIds.size()) {
                throw new ApiException(ErrorCode.CONFLICT, "退货关联的销售出货或出货行不存在");
            }
            for (Object[] row : rows) {
                if (row[1] != null) orderItemIds.add((UUID) row[1]);
            }
        }

        if (!orderItemIds.isEmpty()) {
            List<?> rows = em.createNativeQuery("""
                            SELECT i.id
                            FROM sales_order_items i
                            JOIN sales_orders o ON o.id = i.order_id
                            WHERE i.id IN (:ids)
                            ORDER BY o.id, i.id
                            FOR UPDATE OF o, i
                            """)
                    .setParameter("ids", orderItemIds)
                    .getResultList();
            if (rows.size() != orderItemIds.size()) {
                throw new ApiException(ErrorCode.CONFLICT, "退货关联的销售订单或订单行不存在");
            }
        }
    }

    /**
     * Validate every cumulative write before inventory, AR/AP, or source
     * counters change. Aggregation prevents two lines in one document from
     * passing independent capacity checks.
     */
    private void validateReturnWritebackCapacity(List<SalesReturnItem> items, int sign) {
        Map<UUID, BigDecimal> byShipmentItem = new HashMap<>();
        Map<UUID, BigDecimal> byOrderItem = new HashMap<>();
        for (SalesReturnItem item : items) {
            BigDecimal quantity = item.getQty();
            if (quantity == null || quantity.signum() <= 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "退货明细数量必须大于 0");
            }
            if (item.getOutItemId() != null) {
                byShipmentItem.merge(item.getOutItemId(), quantity, BigDecimal::add);
            }
            if (item.getOrderItemId() != null) {
                byOrderItem.merge(item.getOrderItemId(), quantity, BigDecimal::add);
            }
        }

        if (!byShipmentItem.isEmpty()) {
            @SuppressWarnings("unchecked")
            List<Object[]> rows = em.createNativeQuery("""
                            SELECT id, qty, COALESCE(returned_qty,0)
                            FROM sales_shipment_items
                            WHERE id IN (:ids)
                            ORDER BY id
                            FOR UPDATE
                            """)
                    .setParameter("ids", new TreeSet<>(byShipmentItem.keySet()))
                    .getResultList();
            if (rows.size() != byShipmentItem.size()) {
                throw new ApiException(ErrorCode.CONFLICT, "退货关联的销售出货行不存在");
            }
            for (Object[] row : rows) {
                BigDecimal request = byShipmentItem.get((UUID) row[0]);
                BigDecimal shipped = bd(row[1]);
                BigDecimal returned = bd(row[2]);
                if ((sign > 0 && returned.add(request).compareTo(shipped) > 0)
                        || (sign < 0 && returned.compareTo(request) < 0)) {
                    throw new ApiException(ErrorCode.CONFLICT, "退货数量超过来源出货行可退或可回退数量");
                }
            }
        }

        if (!byOrderItem.isEmpty()) {
            @SuppressWarnings("unchecked")
            List<Object[]> rows = em.createNativeQuery("""
                            SELECT id, COALESCE(shipped_qty,0), COALESCE(returned_qty,0),
                                   COALESCE(qty,0), COALESCE(flag_qty,0),
                                   COALESCE(reserved_qty,0), COALESCE(planned_qty,0),
                                   COALESCE(produced_qty,0)
                            FROM sales_order_items
                            WHERE id IN (:ids)
                            ORDER BY id
                            FOR UPDATE
                            """)
                    .setParameter("ids", new TreeSet<>(byOrderItem.keySet()))
                    .getResultList();
            if (rows.size() != byOrderItem.size()) {
                throw new ApiException(ErrorCode.CONFLICT, "退货关联的销售订单行不存在");
            }
            for (Object[] row : rows) {
                BigDecimal request = byOrderItem.get((UUID) row[0]);
                BigDecimal shipped = bd(row[1]);
                BigDecimal returned = bd(row[2]);
                if ((sign > 0 && returned.add(request).compareTo(shipped) > 0)
                        || (sign < 0 && returned.compareTo(request) < 0)) {
                    throw new ApiException(ErrorCode.CONFLICT, "退货数量超过来源订单行已发或可回退数量");
                }
                if (sign < 0 && !canReverseWithoutStrandingCommitment(
                        bd(row[3]), shipped, returned, bd(row[4]),
                        bd(row[5]), bd(row[6]), bd(row[7]), request)) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "退货红冲后的未交量不足以覆盖预留或未完计划，"
                                    + "请先释放预留并红冲/取消返补计划");
                }
                }
            }
        }

    static boolean canReverseWithoutStrandingCommitment(
            BigDecimal qty, BigDecimal shipped, BigDecimal returned,
            BigDecimal flagged, BigDecimal reserved, BigDecimal planned,
            BigDecimal produced, BigDecimal reversingReturn) {
        if (qty == null || shipped == null || returned == null || flagged == null
                || reserved == null || planned == null || produced == null
                || reversingReturn == null
                || qty.signum() < 0 || shipped.signum() < 0 || returned.signum() < 0
                || flagged.signum() < 0 || reserved.signum() < 0
                || planned.signum() < 0 || produced.signum() < 0
                || reversingReturn.signum() <= 0
                || returned.compareTo(reversingReturn) < 0
                || produced.compareTo(planned) > 0) {
            return false;
        }
        BigDecimal postOutstanding = qty.subtract(shipped)
                .add(returned.subtract(reversingReturn)).subtract(flagged);
        BigDecimal commitment = reserved.add(planned.subtract(produced));
        return postOutstanding.compareTo(commitment) >= 0;
    }

    private void assertStoredSources(SalesReturn salesReturn,
                                     List<SalesReturnItem> items,
                                     boolean completeMissingOrderLink) {
        ReturnSaveRequest snapshot = new ReturnSaveRequest();
        snapshot.setClientId(salesReturn.getClientId());
        List<ReturnItemLine> links = new ArrayList<>(items.size());
        for (SalesReturnItem item : items) {
            ReturnItemLine line = new ReturnItemLine();
            line.setOutItemId(item.getOutItemId());
            line.setOrderItemId(item.getOrderItemId());
            if (item.getQty() == null || item.getQty().signum() <= 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "历史退货明细数量无效，禁止继续联动");
            }
            line.setGoodsId(item.getGoodsId());
            line.setColorId(item.getColorId());
            line.setUnitId(item.getUnitId());
            line.setUnitRate(item.getUnitRate());
            links.add(line);
        }
        snapshot.setItems(links);
        LinkedSource source = validateLinkedSources(snapshot);
        if (source.present()
                && !Objects.equals(source.ownerEmployeeId(), salesReturn.getOwnerEmployeeId())) {
            throw new ApiException(ErrorCode.CONFLICT, "来源单据与退货单归属不一致");
        }
        if (source.sourceShipmentId() != null) {
            if (salesReturn.getSourceShipmentId() == null) {
                applySource(salesReturn, source);
            } else if (!salesReturn.getSourceShipmentId().equals(source.sourceShipmentId())) {
                throw new ApiException(ErrorCode.CONFLICT, "退货单头来源出货单与明细关联不一致");
            }
        }
        // Old drafts may only have out_item_id. Complete the safe dual link
        // before approval so shipment and order counters stay in sync.
        if (completeMissingOrderLink) {
            for (int index = 0; index < items.size(); index++) {
                SalesReturnItem item = items.get(index);
                UUID resolvedOrderItemId = links.get(index).getOrderItemId();
                if (item.getOrderItemId() == null && resolvedOrderItemId != null) {
                    item.setOrderItemId(resolvedOrderItemId);
                    itemRepo.save(item);
                }
            }
        }
    }

    private Set<UUID> readableShipmentItemIds(List<UUID> ids) {
        if (ids.isEmpty() || !accessPolicy.hasAuthority("sales_shipment:view")) {
            return Set.of();
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT i.id, o.owner_employee_id
                FROM sales_shipment_items i
                JOIN sales_shipments o ON o.id = i.shipment_id
                WHERE i.id IN (:ids)
                  AND COALESCE(i.is_deleted,false)=false
                  AND COALESCE(o.is_deleted,false)=false
                """).setParameter("ids", ids).getResultList();
        var readScope = accessPolicy.scope("finance_shipment_audit", "sales_shipment:reject");
        java.util.HashSet<UUID> readable = new java.util.HashSet<>();
        for (Object[] row : rows) {
            if (accessPolicy.canRead((UUID) row[1], readScope)) {
                readable.add((UUID) row[0]);
            }
        }
        return readable;
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

    private boolean isShipmentSourceReadable(UUID sourceShipmentId) {
        if (sourceShipmentId == null) {
            return true;
        }
        if (!accessPolicy.hasAuthority("sales_shipment:view")) {
            return false;
        }
        @SuppressWarnings("unchecked")
        List<UUID> owners = em.createNativeQuery("""
                SELECT owner_employee_id
                FROM sales_shipments
                WHERE id = :sourceShipmentId
                  AND COALESCE(is_deleted,false)=false
                """)
                .setParameter("sourceShipmentId", sourceShipmentId)
                .getResultList();
        var shipmentScope = accessPolicy.scope(
                "finance_shipment_audit", "sales_shipment:reject");
        return owners.size() == 1
                && accessPolicy.canRead(owners.getFirst(), shipmentScope);
    }

    private static void applySource(SalesReturn salesReturn, LinkedSource source) {
        UUID previousSourceId = salesReturn.getSourceShipmentId();
        salesReturn.setSourceShipmentId(source.sourceShipmentId());
        if (source.sourceShipmentId() != null) {
            salesReturn.setSourceDocNo(source.sourceBillNo());
        } else if (previousSourceId != null) {
            salesReturn.setSourceDocNo(null);
        }
    }

    private void applyHeader(ReturnSaveRequest req, SalesReturn r) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (r.getBillNo() == null || r.getBillNo().isBlank()) {
            r.setBillNo(docNumberService.nextNumber(DocNumberPrefix.SALES_RETURN));
        }
        r.setBillDate(req.getBillDate());
        r.setClientId(req.getClientId());
        // V476 运营红线：退货入库必须落到具体叶子仓。
        if (warehouseScopes != null) {
            warehouseScopes.requireNewLeafSelection(r.getWarehouseId(), req.getWarehouseId(), "仓库");
        }
        r.setWarehouseId(req.getWarehouseId());
        r.setCurrencyId(req.getCurrencyId());
        r.setExchangeRate(req.getExchangeRate());
        r.setTaxRate(req.getTaxRate());
        if (!(req.getSettlementMethodId() == null && req.getPaymentStyleId() == null
                && r.getSettlementMethodId() == null && r.getPaymentStyleId() != null)) {
            var settlement = com.uten.imp.common.util.SettlementMethodReferenceResolver.resolve(
                    em, req.getSettlementMethodId(), req.getPaymentStyleId(), "结帐方式");
            r.setSettlementMethodId(settlement == null ? null : settlement.id());
            r.setPaymentStyleId(settlement == null ? null : settlement.legacyId());
        }
        r.setSellerId(req.getSellerId());
        r.setRemark(req.getRemark());
        r.setReturnReason(req.getReturnReason());
    }

    private List<ReturnItemDto> saveItems(SalesReturn r, List<ReturnItemLine> lines) {
        Map<UUID, SalesGoodsSnapshot> shipmentSnapshots = SalesGoodsSnapshot.fromShipmentItems(
                em,
                lines.stream().map(ReturnItemLine::getOutItemId).toList(),
                SalesGoodsSnapshot.SHIPMENT_ITEM_AT_SAVE);
        Map<UUID, SalesGoodsSnapshot> orderSnapshots = SalesGoodsSnapshot.fromOrderItems(
                em,
                lines.stream().map(ReturnItemLine::getOrderItemId).toList(),
                SalesGoodsSnapshot.ORDER_ITEM_AT_SAVE);
        Map<UUID, SalesGoodsSnapshot> masterSnapshots = SalesGoodsSnapshot.fromMaster(
                em,
                lines.stream()
                        .filter(line -> (line.getOutItemId() == null
                                || !shipmentSnapshots.containsKey(line.getOutItemId()))
                                && (line.getOrderItemId() == null
                                || !orderSnapshots.containsKey(line.getOrderItemId())))
                        .map(ReturnItemLine::getGoodsId)
                        .toList(),
                SalesGoodsSnapshot.MASTER_AT_SAVE);
        List<ReturnItemDto> out = new ArrayList<>(lines.size());
        int auto = 1;
        for (ReturnItemLine l : lines) {
            NonNegativeCommercialSignGuard.requireRequestLine(
                    "销售退货", l.getQty(), l.getPrice(),
                    l.getAmountOriginal(), l.getAmountLocal(), l.getCostAmount());
            SalesReturnItem it = new SalesReturnItem();
            it.setReturnId(r.getId());
            it.setBillNo(r.getBillNo());
            it.setBillDate(r.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            it.setOutItemId(l.getOutItemId());
            it.setOrderItemId(l.getOrderItemId());
            it.setGoodsId(l.getGoodsId());
            applyGoodsSnapshot(
                    it,
                    preferredSnapshot(
                            shipmentSnapshots, l.getOutItemId(),
                            orderSnapshots, l.getOrderItemId(),
                            masterSnapshots, l.getGoodsId(), "销售退货明细"),
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
            it.setClientNo(l.getClientNo());
            it.setClientModel(l.getClientModel());
            it.setSolution(l.getSolution());
            it.setResponsible(l.getResponsible());
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
            List<SalesReturnItem> items, boolean approval, OffsetDateTime lockedAt) {
        Map<UUID, SalesGoodsSnapshot> shipmentSnapshots = SalesGoodsSnapshot.fromShipmentItems(
                em,
                items.stream().map(SalesReturnItem::getOutItemId).toList(),
                approval
                        ? SalesGoodsSnapshot.SHIPMENT_ITEM_AT_APPROVAL
                        : SalesGoodsSnapshot.SHIPMENT_ITEM_AT_SAVE);
        Map<UUID, SalesGoodsSnapshot> orderSnapshots = SalesGoodsSnapshot.fromOrderItems(
                em,
                items.stream().map(SalesReturnItem::getOrderItemId).toList(),
                approval
                        ? SalesGoodsSnapshot.ORDER_ITEM_AT_APPROVAL
                        : SalesGoodsSnapshot.ORDER_ITEM_AT_SAVE);
        Map<UUID, SalesGoodsSnapshot> masterSnapshots = SalesGoodsSnapshot.fromMaster(
                em,
                items.stream()
                        .filter(item -> (item.getOutItemId() == null
                                || !shipmentSnapshots.containsKey(item.getOutItemId()))
                                && (item.getOrderItemId() == null
                                || !orderSnapshots.containsKey(item.getOrderItemId())))
                        .map(SalesReturnItem::getGoodsId)
                        .toList(),
                approval
                        ? SalesGoodsSnapshot.MASTER_AT_APPROVAL
                        : SalesGoodsSnapshot.MASTER_AT_SAVE);
        for (SalesReturnItem item : items) {
            applyGoodsSnapshot(
                    item,
                    preferredSnapshot(
                            shipmentSnapshots, item.getOutItemId(),
                            orderSnapshots, item.getOrderItemId(),
                            masterSnapshots, item.getGoodsId(), "销售退货明细"),
                    lockedAt);
        }
    }

    private static SalesGoodsSnapshot preferredSnapshot(
            Map<UUID, SalesGoodsSnapshot> shipmentSnapshots,
            UUID shipmentItemId,
            Map<UUID, SalesGoodsSnapshot> orderSnapshots,
            UUID orderItemId,
            Map<UUID, SalesGoodsSnapshot> masterSnapshots,
            UUID goodsId,
            String subject) {
        SalesGoodsSnapshot shipment = shipmentItemId == null
                ? null : shipmentSnapshots.get(shipmentItemId);
        if (shipment != null) {
            return shipment;
        }
        SalesGoodsSnapshot order = orderItemId == null
                ? null : orderSnapshots.get(orderItemId);
        return order != null
                ? order
                : SalesGoodsSnapshot.require(masterSnapshots, goodsId, subject);
    }

    private static void applyGoodsSnapshot(
            SalesReturnItem item, SalesGoodsSnapshot snapshot, OffsetDateTime lockedAt) {
        item.setGoodsCodeSnapshot(snapshot.code());
        item.setGoodsNameSnapshot(snapshot.name());
        item.setGoodsSnapshotSource(snapshot.source());
        item.setGoodsSnapshotLockedAt(lockedAt);
    }

    private static void requireNonNegativeStoredCommercial(
            SalesReturn salesReturn, List<SalesReturnItem> items) {
        NonNegativeCommercialSignGuard.requireStoredTotals(
                "销售退货", salesReturn.getTotalOriginal(), salesReturn.getTotalLocal());
        for (SalesReturnItem item : items) {
            NonNegativeCommercialSignGuard.requireStoredLine(
                    "销售退货", item.getQty(), item.getPrice(), item.getAmountOriginal(),
                    item.getAmountLocal(), item.getCostAmount());
        }
    }

    private void applyTotals(SalesReturn r, List<ReturnItemDto> items) {
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

    private ReturnListItem toList(SalesReturn r, boolean writable) {
        return new ReturnListItem(r.getId(), r.getBillNo(), r.getBillDate(), r.getClientId(),
                r.getWarehouseId(), r.getTotalLocal(), r.getStatus(), r.isClosed(), r.isArPosted(),
                r.getLegacyId(), writable,
                r.getCurrencyId(), r.getSellerId(), nameResolver.nameOf(r.getSellerId()));
    }

    private ReturnItemDto toItemDto(SalesReturnItem it) {
        return toItemDto(it, true, true);
    }

    private ReturnItemDto toItemDto(SalesReturnItem it, boolean shipmentReadable, boolean orderReadable) {
        boolean sourceReadable = shipmentReadable && orderReadable;
        return new ReturnItemDto(it.getId(), it.getLineNo(),
                shipmentReadable ? it.getOutItemId() : null,
                orderReadable ? it.getOrderItemId() : null,
                it.getGoodsId(), it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(),
                it.getGoodsSnapshotSource(), it.getGoodsSnapshotLockedAt(),
                it.getColorId(), it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(),
                it.getAmountOriginal(), it.getAmountLocal(), it.getCostAmount(), it.getWeight(),
                it.getClientNo(), it.getClientModel(), it.getSolution(), it.getResponsible(),
                it.getDiscount(), sourceReadable ? it.getSourceDocNo() : null, it.getRemark());
    }

    private ReturnDetail toDetail(SalesReturn r, List<ReturnItemDto> items,
                                  boolean sourceReadable, boolean writable) {
        return new ReturnDetail(r.getId(), r.getLegacyId(), r.getBillNo(), r.getBillDate(),
                r.getClientId(), r.getWarehouseId(), r.getCurrencyId(), r.getExchangeRate(), r.getTaxRate(),
                r.getPaymentStyleId(), r.getSettlementMethodId(), r.getSellerId(), r.getMakerId(), r.getApproverId(),
                r.getLastDate(), r.getRemark(), r.getTotalOriginal(), r.getTotalLocal(), r.getStatus(),
                r.isClosed(), sourceReadable ? r.getSourceShipmentId() : null,
                sourceReadable ? r.getSourceDocNo() : null, r.isArPosted(), items,
                nameResolver.nameOf(r.getMakerId()), r.getCreatedAt(), writable, r.getReturnReason(),
                r.getCustomerDisposition(), r.getDispositionStatus(), r.getDispositionDecidedBy(),
                r.getDispositionDecidedAt(), r.getDispositionReason(), r.isFulfilmentReopened());
    }

    private boolean hasObjectActionAuthority() {
        return accessPolicy.hasAuthority("sales_return:edit")
                || accessPolicy.hasAuthority("sales_return:delete")
                || accessPolicy.hasAuthority("sales_return:approve")
                || accessPolicy.hasAuthority("sales_return:reverse")
                || accessPolicy.hasAuthority("sales_return:disposition");
    }

    private SalesReturn requireReturn(UUID id) {
        return returnRepo.findById(id).filter(r -> !r.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "销售退货单不存在"));
    }

    private SalesReturn requireReadableReturn(UUID id) {
        SalesReturn salesReturn = requireReturn(id);
        accessPolicy.requireReadable(salesReturn.getOwnerEmployeeId(), "销售退货单不存在");
        return salesReturn;
    }

    private SalesReturn requireWritableReturnForUpdate(UUID id) {
        return requireWritableReturnForUpdate(id, List.of());
    }

    private SalesReturn requireWritableReturnForUpdate(UUID id,
            List<com.uten.imp.features.sales.SalesMutationFootprintService.RequestedLine> requested) {
        mutationFootprint.lockReturn(id, requested);
        return requireWritableReturnAfterPrefix(id);
    }

    private SalesReturn requireWritableReturnAfterPrefix(UUID id) {
        SalesReturn salesReturn = em.find(
                SalesReturn.class, id, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (salesReturn != null) em.refresh(salesReturn, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (salesReturn == null || salesReturn.isDeleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "销售退货单不存在");
        }
        accessPolicy.requireWritable(salesReturn.getOwnerEmployeeId(), "只能操作本人负责的销售退货单");
        return salesReturn;
    }

    private static List<com.uten.imp.features.sales.SalesMutationFootprintService.RequestedLine> requestedFootprint(
            ReturnSaveRequest request) {
        return request.getItems() == null ? List.of() : request.getItems().stream()
                .map(line -> new com.uten.imp.features.sales.SalesMutationFootprintService.RequestedLine(
                        line.getGoodsId(), line.getColorId(), line.getOrderItemId(), line.getOutItemId())).toList();
    }

    private record LinkedSource(
            boolean present,
            UUID sourceShipmentId,
            String sourceBillNo,
            UUID ownerEmployeeId) {}
}
