package com.uten.imp.features.purchase.order;

import com.uten.imp.application.port.ProcurementArrivalControlPort;
import com.uten.imp.application.port.ProcurementOrderApprovalPort;
import com.uten.imp.application.port.PreplanPublicSupplyCapturePort;
import com.uten.imp.application.port.ProcurementOrderApprovalPort.ItemSnapshot;
import com.uten.imp.application.port.ProcurementOrderApprovalPort.OrderSnapshot;
import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.finance.ProcurementCommercialSnapshotPolicy;
import com.uten.imp.common.integrity.LinkedDocumentIntegrityService;
import com.uten.imp.common.integrity.ProductionSupplySourceGuard;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeItem;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest;
import com.uten.imp.features.finance.procurement.ProcurementApprovalProjectionQuery;
import com.uten.imp.features.purchase.PurchaseDocumentAccessPolicy;
import com.uten.imp.features.purchase.PurchaseGoodsSnapshot;
import com.uten.imp.features.purchase.common.PurchaseLineUnitPolicy;
import com.uten.imp.features.purchase.order.dto.OrderDetail;
import com.uten.imp.features.purchase.order.dto.OrderItemDto;
import com.uten.imp.features.purchase.order.dto.OrderItemLine;
import com.uten.imp.features.purchase.order.dto.OrderListItem;
import com.uten.imp.features.purchase.order.dto.OrderQueryFilter;
import com.uten.imp.features.purchase.order.dto.OrderSaveRequest;
import com.uten.imp.security.CommercialPriceVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
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
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.Objects;
import java.util.stream.Collectors;

/**
 * 采购订货单服务：CRUD（主+明细）+ 审核状态机。
 *
 * <p>审核（0→1）：回写申请明细 ordered_qty + 重算申请单 is_closed（订货不入库，不碰库存）。
 * 红冲（1→-1）反向。2026-09 起订货允许超过申请剩余量（超采备货）：
 * ordered_qty 可大于申请 qty、剩余量为负时申请照常结案，不设上限校验。
 */
@Service
@RequiredArgsConstructor
public class PurchaseOrderService implements ProcurementOrderApprovalPort {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;
    /** 2026-09-05 起：草稿单可「取消」——保留单据轨迹（区别于删除），不回写 -1。 */
    private static final short STATUS_CANCELED = 2;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "total", "totalLocal");

    private final PurchaseOrderRepository orderRepo;
    private final PurchaseOrderItemRepository itemRepo;
    private final LinkedDocumentIntegrityService sourceIntegrity;
    private final ProductionSupplyTransitionPort productionSupply;
    private PreplanPublicSupplyCapturePort publicSupplyCapture =
            PreplanPublicSupplyCapturePort.NOOP;

    @Autowired
    void setPublicSupplyCapture(PreplanPublicSupplyCapturePort value) {
        this.publicSupplyCapture = value;
    }
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final EntityManager em;
    // V476：叶子仓落库校验。字段注入+可空——单测手工构造时缺省跳过，Spring 环境恒注入。
    @org.springframework.beans.factory.annotation.Autowired(required = false)
    private com.uten.imp.features.master.warehouse.WarehouseScopeService warehouseScopes;
    private final DocNumberService docNumberService;
    private final ProductionSupplySourceGuard productionSourceGuard;
    private final PurchaseLineUnitPolicy lineUnitPolicy;
    private final ProcurementApprovalProjectionQuery approvalProjection;
    private final com.uten.imp.features.finance.procurement.ProcurementApprovalReconfirmationService reconfirmation;
    private final com.uten.imp.features.notice.ChainNoticeService chainNotice;
    private final ProcurementArrivalControlPort arrivalControl;
    private final PurchaseDocumentAccessPolicy access;
    private final MasterReferenceValidationPort references;
    private final com.uten.imp.application.port.ProcurementReviewCancellationPort reviewCancellation;
    private final com.uten.imp.application.port.ProcurementOrderSourceRevisionPort sourceRevision;
    private final com.uten.imp.common.concurrency.ProcurementMutationLocks mutationLocks;

    /** Spring injects this in production; direct-construction tests fail closed. */
    @Autowired
    private CommercialPriceVisibility commercialPriceVisibility;

    @Transactional(readOnly = true)
    public PageResponse<OrderListItem> list(OrderQueryFilter f, int page, int size, String sort, String order) {
        boolean priceMasked = purchasePriceMasked();
        var readScope = access.scope();
        Specification<PurchaseOrder> spec = (Root<PurchaseOrder> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                             CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            ps.add(access.readablePredicate(root, cb, "makerId", readScope));
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
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"),
                        priceMasked ? Map.of("billDate", "billDate") : ALLOWED_SORT));
        Page<PurchaseOrder> p = orderRepo.findAll(spec, pageable);
        Map<UUID, FinanceApproval> approvals = approvalProjection.latestForOrders(
                orderType(),
                p.getContent().stream().collect(Collectors.toMap(
                        PurchaseOrder::getId,
                        row -> row.getStatus())));
        List<OrderListItem> items = p.getContent().stream()
                .map(row -> toList(row, approvals.get(row.getId()), priceMasked))
                .toList();
        return new PageResponse<>(
                items, p);
    }

    @Transactional(readOnly = true)
    public OrderDetail detail(UUID id) {
        PurchaseOrder o = requireOrder(id);
        if (!access.canRead(o.getMakerId())
                && !approvalProjection.canCurrentActorReviewPending(orderType(), id)) {
            throw new ApiException(ErrorCode.NOT_FOUND, "采购订货单不存在");
        }
        return assembleDetail(o);
    }

    private OrderDetail assembleDetail(PurchaseOrder o) {
        List<PurchaseOrderItem> items = itemRepo.findByOrderIdOrderByLineNoAsc(o.getId());
        Map<UUID, List<Object[]>> sources = orderItemSources(
                items.stream().map(PurchaseOrderItem::getId).toList());
        List<OrderItemDto> itemDtos = items.stream()
                .map(it -> toItemDto(it, sourceRequestDocs(sources.getOrDefault(it.getId(), List.of()))))
                .toList();
        return toDetail(o, itemDtos);
    }

    /** sources 原始行 → 结构化来源申请引用（明细 id + 申请单 id + 单号）。 */
    private static List<OrderItemDto.SourceRequestDoc> sourceRequestDocs(List<Object[]> rows) {
        return rows.stream()
                .map(row -> new OrderItemDto.SourceRequestDoc(
                        (UUID) row[1], (UUID) row[4], row[2] == null ? null : row[2].toString()))
                .toList();
    }

    /**
     * 订货行 → 来源分配行（order_item_id → [order_item_id, 来源申请明细 id,
     * 申请单号, alloc_qty, 申请单 id]，按 line_no/id 稳定排序）。V463 多来源锚定的统一读取入口。
     */
    private Map<UUID, List<Object[]>> orderItemSources(List<UUID> orderItemIds) {
        if (orderItemIds == null || orderItemIds.isEmpty()) {
            return Map.of();
        }
        List<Object[]> rows = com.uten.imp.common.util.NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT src.order_item_id, src.request_item_id,
                               request.bill_no, src.alloc_qty, request.id AS request_id
                        FROM purchase_order_item_sources src
                        JOIN purchase_request_items item ON item.id = src.request_item_id
                        LEFT JOIN purchase_requests request ON request.id = item.request_id
                        WHERE src.order_item_id IN (:ids)
                        ORDER BY src.order_item_id, src.line_no, src.id
                        """).setParameter("ids", orderItemIds));
        Map<UUID, List<Object[]>> out = new java.util.HashMap<>();
        for (Object[] row : rows) {
            out.computeIfAbsent((UUID) row[0], ignored -> new ArrayList<>()).add(row);
        }
        return out;
    }

    @Transactional
    @PreAuthorize("hasAuthority('purchase_order:create') and hasAuthority('purchase_order:decompose')")
    public OrderDetail create(OrderSaveRequest req) {
        tx.bind();
        requireRowsMatchHeaderSupplier(req);
        requireRowsMatchHeaderCommercial(req);
        requireHeaderSettlement(req);
        var mutationGuard=lockOrderRequest(null,req);
        mutationGuard.verifyUnchanged();
        PurchaseOrder o = new PurchaseOrder();
        applyHeader(req, o);
        o.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
        o.setStatus(STATUS_DRAFT);
        mutationLocks.expectCreatedOrder(orderType(),o.getId());
        orderRepo.save(o);
        orderRepo.flush();
        mutationLocks.registerCreatedOrder(orderType(),o.getId());
        List<OrderItemDto> items = saveItems(o, req.getItems());
        applyTotals(o, items);
        return toDetail(o, items);
    }

    /**
     * 按明细级「供应商+商业条款」组合拆单创建（保留「一张订货单一个供应商一套条款」
     * 归集）：每行各字段为空时回落表头，按组合分组在同一事务内生成 N 张订货单
     * （多数情况 1 张），每组条款写入该张单的头字段。返回按分组顺序的明细。
     */
    @Transactional
    @PreAuthorize("hasAuthority('purchase_order:create') and hasAuthority('purchase_order:decompose')")
    public List<OrderDetail> createBatch(OrderSaveRequest req) {
        tx.bind();
        Map<CommercialGroupKey, List<OrderItemLine>> groups = groupByCommercial(req);
        lockOrderRequest(null,req).verifyUnchanged();
        List<OrderDetail> created = new ArrayList<>();
        for (Map.Entry<CommercialGroupKey, List<OrderItemLine>> entry : groups.entrySet()) {
            CommercialGroupKey key = entry.getKey();
            OrderSaveRequest sub = new OrderSaveRequest();
            sub.setBillDate(req.getBillDate());
            sub.setSupplierId(key.supplierId());
            sub.setWarehouseId(req.getWarehouseId());
            sub.setCurrencyId(key.currencyId());
            sub.setExchangeRate(key.exchangeRate());
            sub.setTaxRate(key.taxRate());
            // 拆单必须携带结算方式，否则生成的订货单无法通过送审校验
            sub.setSettlementMethodId(key.settlementMethodId());
            sub.setSettlementStyleLegacy(req.getSettlementStyleLegacy());
            sub.setPurchaserId(req.getPurchaserId());
            sub.setDeliverDate(req.getDeliverDate());
            sub.setRemark(req.getRemark());
            sub.setItems(entry.getValue());
            created.add(create(sub));
        }
        return created;
    }

    /** 商业拆单分组键：供应商 + 结账方式 + 币种 + 汇率 + 税率（数值按值等价，2.0 与 2 同组）。 */
    record CommercialGroupKey(
            UUID supplierId,
            UUID settlementMethodId,
            UUID currencyId,
            BigDecimal exchangeRate,
            BigDecimal taxRate) {
        CommercialGroupKey {
            exchangeRate = normalizeDecimal(exchangeRate);
            taxRate = normalizeDecimal(taxRate);
        }

        private static BigDecimal normalizeDecimal(BigDecimal value) {
            if (value == null) return null;
            BigDecimal stripped = value.stripTrailingZeros();
            if (stripped.signum() == 0) return BigDecimal.ZERO;
            // toPlainString 消除 stripTrailingZeros 产生的负 scale（如 2E+1），保证 equals 语义稳定
            return new BigDecimal(stripped.toPlainString());
        }
    }

    /**
     * 行级商业条款分组（包内可见，供单测锁定拆单口径）：每行字段为空回落表头，
     * 按「供应商+结账方式+币种+汇率+税率」组合分组（LinkedHashMap 保序）。
     * 逐行校验组合完整性：供应商/结账方式/币种必填，汇率大于 0，税率 0-100。
     * 业务上订货允许超过申请剩余量（2026-09 放开超采），此处不做数量上限校验。
     */
    static Map<CommercialGroupKey, List<OrderItemLine>> groupByCommercial(OrderSaveRequest req) {
        if (req.getItems() == null || req.getItems().isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "订货明细不能为空");
        }
        Map<CommercialGroupKey, List<OrderItemLine>> groups = new LinkedHashMap<>();
        for (OrderItemLine item : req.getItems()) {
            UUID supplier = item.getSupplierId() != null
                    ? item.getSupplierId()
                    : req.getSupplierId();
            if (supplier == null) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "每一行都必须指定供应商(明细级或表头)");
            }
            UUID settlement = item.getSettlementMethodId() != null
                    ? item.getSettlementMethodId()
                    : req.getSettlementMethodId();
            if (settlement == null) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "每一行都必须指定结账方式(明细级或表头)");
            }
            UUID currency = item.getCurrencyId() != null
                    ? item.getCurrencyId()
                    : req.getCurrencyId();
            if (currency == null) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "每一行都必须指定币种(明细级或表头)");
            }
            BigDecimal rate = item.getExchangeRate() != null
                    ? item.getExchangeRate()
                    : req.getExchangeRate();
            if (rate == null || rate.signum() <= 0) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "每一行的汇率必须大于 0(明细级或表头)");
            }
            BigDecimal tax = item.getTaxRate() != null
                    ? item.getTaxRate()
                    : req.getTaxRate();
            if (tax == null || tax.signum() < 0 || tax.compareTo(BigDecimal.valueOf(100)) > 0) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "每一行的税率必须在 0 至 100 之间(明细级或表头)");
            }
            groups.computeIfAbsent(
                    new CommercialGroupKey(supplier, settlement, currency, rate, tax),
                    k -> new ArrayList<>()).add(item);
        }
        return groups;
    }

    /**
     * 货品 → 最近一次订货供应商（订货编辑页行级供应商「学习预填」：选货品后自动
     * 带出上次该货品的订货供应商，减少逐行手选）。批量一次查询；无历史返回空 Map。
     */
    @Transactional(readOnly = true)
    public Map<UUID, UUID> lastSuppliersPerGoods(Collection<UUID> goodsIds) {
        if (goodsIds == null || goodsIds.isEmpty()) {
            return Map.of();
        }
        Map<UUID, UUID> result = new LinkedHashMap<>();
        for (Object[] row : itemRepo.findLastSupplierPerGoods(goodsIds)) {
            result.put((UUID) row[0], (UUID) row[1]);
        }
        return result;
    }

    /**
     * 货品 → 最近一次订货商业条款（行级条款「学习预填」：同一货品下次建单自动带出
     * 上次的供应商/结账方式/币种/汇率/税率）。取每个货品最新一张未删订货单的头条款；
     * 供应商是否可用（停用/内部车间）由前端在回填时判断。批量一次查询；无历史返回空 Map。
     */
    @Transactional(readOnly = true)
    public Map<UUID, LastTermsPerGoods> lastTermsPerGoods(Collection<UUID> goodsIds) {
        if (goodsIds == null || goodsIds.isEmpty()) {
            return Map.of();
        }
        Map<UUID, LastTermsPerGoods> result = new LinkedHashMap<>();
        for (Object[] row : itemRepo.findLastTermsPerGoods(goodsIds)) {
            result.put((UUID) row[0], new LastTermsPerGoods(
                    (UUID) row[1], (UUID) row[2], (UUID) row[3],
                    (BigDecimal) row[4], (BigDecimal) row[5]));
        }
        return result;
    }

    /** 行级条款学习记忆视图（/last-terms 返回体；金额口径字段见 purchase_orders 头）。 */
    public record LastTermsPerGoods(
            UUID supplierId,
            UUID settlementMethodId,
            UUID currencyId,
            BigDecimal exchangeRate,
            BigDecimal taxRate) {}

    @Transactional
    @PreAuthorize("hasAuthority('purchase_order:edit')")
    public OrderDetail update(UUID id, OrderSaveRequest req) {
        tx.bind();
        var mutationGuard=lockOrderRequest(id,req);
        PurchaseOrder o = requireOrderForUpdate(id);
        access.requireWritable(o.getMakerId(), "只能操作本人负责的采购订货单");
        if (o.getStatus() != STATUS_DRAFT) throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        approvalProjection.requireMutable(orderType(), id);
        mutationGuard.verifyUnchanged();
        requireRowsMatchHeaderSupplier(req);
        requireRowsMatchHeaderCommercial(req);
        requireHeaderSettlement(req);
        applyHeader(req, o);
        itemRepo.deleteByOrderId(id);
        itemRepo.flush();
        List<OrderItemDto> items = saveItems(o, req.getItems());
        applyTotals(o, items);
        return toDetail(o, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('purchase_order:delete')")
    public void delete(UUID id) {
        tx.bind();
        var mutationGuard=mutationLocks.order(orderType(),id);
        PurchaseOrder o = requireOrderForUpdate(id);
        access.requireWritable(o.getMakerId(), "只能操作本人负责的采购订货单");
        com.uten.imp.common.web.StandardDocumentLifecycleCapabilities.requireDraftForDelete(o.getStatus());
        approvalProjection.requireMutable(orderType(), id);
        mutationGuard.verifyUnchanged();
        o.setDeleted(true);
        o.setDeletedAt(OffsetDateTime.now());
        orderRepo.save(o);
    }

    @Override
    public String orderType() {
        return "PURCHASE";
    }

    private com.uten.imp.application.concurrency.FulfillmentMutationLocks.Guard lockOrderRequest(UUID id,OrderSaveRequest req) {
        List<OrderItemLine> lines=req==null||req.getItems()==null?List.of():req.getItems();
        return mutationLocks.orderInputs(orderType(),id,lines.stream().filter(Objects::nonNull)
                        .flatMap(line->line.resolvedRequestItemIds().stream()).toList(),
                lines.stream().filter(Objects::nonNull).filter(line->line.getGoodsId()!=null)
                        .map(line->new com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension(line.getGoodsId(),line.getColorId())).toList(),
                req==null?null:req.getWarehouseId());
    }

    /**
     * 取消订货单（2026-09-05）：仅草稿单可取消——含已提交财务审核的在审单：
     * PENDING 审批 case 同步置 CANCELED（财务任务中心不再显示）并按 case
     * 聚合撤回「待财务审核」弹卡；财务驳回后的草稿同样可取消。已审单走红冲，
     * 不在此列。取消保留单据轨迹（status=2），不删除。
     */
    @Transactional
    @PreAuthorize("hasAuthority('purchase_order:cancel')")
    public OrderDetail cancel(UUID id) {
        tx.bind();
        var mutationGuard=mutationLocks.order(orderType(),id);
        PurchaseOrder o = requireOrderForUpdate(id);
        access.requireWritable(o.getMakerId(), "只能操作本人负责的采购订货单");
        if (o.getStatus() == null || o.getStatus() != STATUS_DRAFT) {
            throw new ApiException(
                    ErrorCode.BUSINESS, "仅草稿订货单可取消；已审核单请使用红冲");
        }
        mutationGuard.verifyUnchanged();
        reviewCancellation.cancelUnclaimedPending(orderType(),id,"ORDER_CANCELED");
        o.setStatus(STATUS_CANCELED);
        orderRepo.save(o);
        orderRepo.flush();
        return assembleDetail(o);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireFinanceSubmitterWritable(UUID id) {
        PurchaseOrder order = requireOrderForUpdate(id);
        access.requireWritable(
                order.getMakerId(),
                "只能提交本人负责或已正式交接的采购订货单");
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public OrderSnapshot lockAndValidateFinanceSubmission(UUID id) {
        PurchaseOrder order = requireOrderForUpdate(id);
        if (order.getStatus() == null || order.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.CONFLICT, "仅草稿订货单可提交或执行财务审核");
        }
        if (order.getSupplierId() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "采购订货单必须指定供应商");
        }
        List<PurchaseOrderItem> items = itemRepo.findByOrderIdOrderByLineNoAsc(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "订货明细不能为空");
        }
        if (items.stream().anyMatch(item -> item.getRequestItemId() == null)) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "采购订货每一行都必须关联计划下达的采购申请明细");
        }
        normalizePersistedItemUnits(items);
        requireActiveSettlementMethod(order.getSettlementMethodId(), "采购订货");
        ProcurementCommercialSnapshotPolicy.requireComplete(
                em,
                order.getCurrencyId(),
                order.getExchangeRate(),
                order.getTaxRate(),
                "采购订货");
        requireFinanceCommercialAuthority(order, items);
        // V463：送审完整性按「来源分配行」逐条校验（合并行的每个来源申请行
        // 都必须维度一致、已下达且未中止）；无 sources 的历史行退回主锚点整行。
        Map<UUID, List<Object[]>> submitSources = orderItemSources(
                items.stream().map(PurchaseOrderItem::getId).toList());
        List<com.uten.imp.common.integrity.LinkedDocumentIntegrityService.QuantityLinkedLine>
                linkedLines = new ArrayList<>();
        for (PurchaseOrderItem item : items) {
            List<Object[]> sources = submitSources.getOrDefault(item.getId(), List.of());
            if (sources.isEmpty()) {
                linkedLines.add(new com.uten.imp.common.integrity.LinkedDocumentIntegrityService.QuantityLinkedLine(
                        item.getRequestItemId(), item.getGoodsId(), item.getColorId(),
                        item.getUnitId(), item.getUnitRate(), item.getQty()));
                continue;
            }
            for (Object[] source : sources) {
                linkedLines.add(new com.uten.imp.common.integrity.LinkedDocumentIntegrityService.QuantityLinkedLine(
                        (UUID) source[1], item.getGoodsId(), item.getColorId(),
                        item.getUnitId(), item.getUnitRate(), (BigDecimal) source[3]));
            }
        }
        sourceIntegrity.validatePurchaseOrder(linkedLines);
        return snapshot(order, items);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void applyFinanceApproval(UUID id, UUID approverEmployeeId) {
        PurchaseOrder order = requireOrderForUpdate(id);
        if (order.getStatus() == null || order.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.CONFLICT, "订货单已不再是待生效草稿");
        }
        references.requireSelectableSupplier(order.getSupplierId());
        List<PurchaseOrderItem> items = itemRepo.findByOrderIdOrderByLineNoAsc(id);
        captureGoodsSnapshots(
                items,
                PurchaseGoodsSnapshot.REQUEST_ITEM_AT_APPROVAL,
                PurchaseGoodsSnapshot.MASTER_AT_APPROVAL,
                OffsetDateTime.now());
        productionSupply.onPurchaseOrderApproved(id);
        // V463：ordered_qty 按来源分配份额回写（合并行的数量分摊到各申请行）；
        // 无 sources 的历史/异常行退回整行数量回写主锚点。
        Map<UUID, List<Object[]>> sourceRows = orderItemSources(
                items.stream().map(PurchaseOrderItem::getId).toList());
        java.util.Set<UUID> closedRequestItems = new java.util.LinkedHashSet<>();
        for (PurchaseOrderItem item : items) {
            List<Object[]> sources = sourceRows.getOrDefault(item.getId(), List.of());
            if (sources.isEmpty()) {
                if (item.getRequestItemId() == null) {
                    continue;
                }
                sources = List.<Object[]>of(new Object[]{
                        item.getId(), item.getRequestItemId(), null, item.getQty()});
            }
            for (Object[] source : sources) {
                UUID requestItemId = (UUID) source[1];
                em.createNativeQuery("""
                        UPDATE purchase_request_items
                        SET ordered_qty = COALESCE(ordered_qty, 0) + :qty
                        WHERE id = :id
                        """)
                        .setParameter("qty", (BigDecimal) source[3])
                        .setParameter("id", requestItemId)
                        .executeUpdate();
                closedRequestItems.add(requestItemId);
            }
        }
        closedRequestItems.forEach(this::recalcRequestClosed);
        order.setStatus(STATUS_APPROVED);
        order.setApproverId(approverEmployeeId);
        orderRepo.save(order);
        orderRepo.flush();
        publicSupplyCapture.afterOrderApproved(
                PreplanPublicSupplyCapturePort.PURCHASE, id);
    }

    @Transactional
    @PreAuthorize("hasAuthority('purchase_order:reverse')")
    public OrderDetail reverse(UUID id) {
        tx.bind();
        var mutationGuard=mutationLocks.order(orderType(),id);
        PurchaseOrder o = requireOrderForUpdate(id);
        access.requireWritable(o.getMakerId(), "只能操作本人负责的采购订货单");
        if (o.getStatus() == null || o.getStatus() != STATUS_APPROVED)
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        mutationGuard.verifyUnchanged();
        reviewCancellation.cancelUnclaimedPending(orderType(),id,"ORDER_REVERSED");
        List<PurchaseOrderItem> items = itemRepo.findByOrderIdOrderByLineNoAsc(id);
        if (items.stream().anyMatch(it ->
                positive(it.getReceivedQty()) || positive(it.getReturnedQty()))) {
            throw new ApiException(ErrorCode.BUSINESS, "采购订货已有收货/退货记录，请先红冲下游单据");
        }
        Map<UUID, List<Object[]>> reverseSources = orderItemSources(
                items.stream().map(PurchaseOrderItem::getId).toList());
        sourceIntegrity.lockPurchaseRequestItemsForReversal(
                reverseSources.values().stream().flatMap(List::stream)
                        .map(row -> (UUID) row[1]).distinct().toList());
        productionSupply.onPurchaseOrderReversed(id);
        // V463：红冲按来源分配份额对称扣回（与审批回写同口径）。
        java.util.Set<UUID> reopenedRequestItems = new java.util.LinkedHashSet<>();
        for (PurchaseOrderItem it : items) {
            if (it.getRequestItemId() == null) {
                continue;
            }
            List<Object[]> sources = reverseSources.getOrDefault(it.getId(), List.of());
            if (sources.isEmpty()) {
                sources = List.<Object[]>of(new Object[]{
                        it.getId(), it.getRequestItemId(), null, it.getQty()});
            }
            for (Object[] source : sources) {
                em.createNativeQuery(
                        "UPDATE purchase_request_items SET ordered_qty = COALESCE(ordered_qty,0) - :q WHERE id = :id")
                        .setParameter("q", (BigDecimal) source[3])
                        .setParameter("id", (UUID) source[1])
                        .executeUpdate();
                reopenedRequestItems.add((UUID) source[1]);
            }
        }
        reopenedRequestItems.forEach(this::recalcRequestClosed);
        arrivalControl.cancelForOrderReversal(
                ProcurementArrivalControlPort.PURCHASE, id);
        o.setStatus(STATUS_REVERSED);
        orderRepo.save(o);
        orderRepo.flush();
        publicSupplyCapture.afterOrderReversed(
                PreplanPublicSupplyCapturePort.PURCHASE, id);
        return assembleDetail(o);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public boolean isFinanceApproved(UUID id) {
        PurchaseOrder order = requireOrderForUpdate(id);
        return order.getStatus() != null && order.getStatus() == STATUS_APPROVED;
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public OrderSnapshot lockFinanceReconfirmationSnapshot(UUID id) {
        PurchaseOrder order = requireOrderForUpdate(id);
        if (order.getStatus() == null || order.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.CONFLICT, "采购订货单已不在已批准状态，请刷新");
        }
        return snapshot(order, itemRepo.findByOrderIdOrderByLineNoAsc(id));
    }

    /**
     * V486 财务批准后受控改量（对齐销售 V482）：立即生效 + 自动开财务复核 case
     * 重回审批队列 + 逐行 old→new 事实账。最低量取精确实收、普通/IQC实退及
     * 同收货行有效超到事实；来源份额与生产供给在同一受控变更中对账。
     * 预计到货同时处理OPEN/CLOSED，不把展示状态或过期accepted投影当物理事实。
     */
    @Transactional
    @PreAuthorize("hasAuthority('purchase_order:change_qty')")
    public OrderDetail changeQty(
            UUID id, OrderQtyChangeRequest request) {
        tx.bind();
        var mutationGuard=mutationLocks.order(orderType(),id);
        PurchaseOrder order = requireOrderForUpdate(id);
        access.requireWritable(order.getMakerId(), "只能操作本人负责的采购订货单");
        if (order.getStatus() == null || order.getStatus() != STATUS_APPROVED) {
            throw new ApiException(
                    ErrorCode.BUSINESS, "仅财务批准后的采购订货单可改量");
        }
        mutationGuard.verifyUnchanged();
        requireNoPendingApprovalCase(id);
        List<PurchaseOrderItem> items = itemRepo.findByOrderIdOrderByLineNoAsc(id);
        Map<UUID, PurchaseOrderItem> byId = items.stream()
                .collect(Collectors.toMap(
                        PurchaseOrderItem::getId, it -> it, (a, b) -> a,
                        LinkedHashMap::new));
        List<Object[]> changes = new ArrayList<>();
        for (OrderQtyChangeItem change : request.items()) {
            PurchaseOrderItem item = byId.get(change.orderItemId());
            if (item == null) {
                throw new ApiException(
                        ErrorCode.NOT_FOUND,
                        "改量行不存在或已不属于本订货单：" + change.orderItemId());
            }
            BigDecimal newQty = change.newQty();
            BigDecimal oldQty = item.getQty();
            if (newQty.compareTo(oldQty) == 0) {
                continue;
            }
            var receiptBound=com.uten.imp.common.finance.ProcurementOrderQuantityBounds.receipts(em,orderType(),item.getId());
            BigDecimal unitRate=item.getUnitRate()==null ? BigDecimal.ONE : item.getUnitRate();
            BigDecimal locked = receiptBound.minimumOrderedQty(unitRate);
            if (newQty.compareTo(locked) < 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "第 " + item.getLineNo() + " 行至少需保留订货数量 "
                                + locked.stripTrailingZeros().toPlainString());
            }
            changes.add(new Object[]{item, oldQty, newQty,receiptBound,UUID.randomUUID()});
        }
        if (changes.isEmpty()) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED, "没有任何数量变化");
        }
        BigDecimal rate = order.getExchangeRate() == null
                ? BigDecimal.ONE : order.getExchangeRate();
        sourceRevision.prepare(orderType(),id,changes.stream().map(change -> {
            PurchaseOrderItem item=(PurchaseOrderItem)change[0];
            return new com.uten.imp.application.port.ProcurementOrderSourceRevisionPort.Line((UUID)change[4],item.getId(),
                    (BigDecimal)change[1],(BigDecimal)change[2],item.getUnitRate()==null?BigDecimal.ONE:item.getUnitRate());
        }).toList());
        for (Object[] change : changes) {
            PurchaseOrderItem item = (PurchaseOrderItem) change[0];
            BigDecimal newQty = (BigDecimal) change[2];
            item.setQty(newQty);
            BigDecimal amountOriginal = item.getPrice() == null
                    ? null : money(newQty.multiply(item.getPrice()));
            item.setAmountOriginal(amountOriginal);
            item.setAmountLocal(amountOriginal == null
                    ? null : money(amountOriginal.multiply(rate)));
            itemRepo.save(item);
        }
        recalcOrderTotals(order, items);
        orderRepo.save(order);
        orderRepo.flush();
        sourceRevision.apply(orderType(),id,changes.stream().map(change ->(UUID)change[4]).toList());
        for(Object[] change:changes) {
            PurchaseOrderItem item=(PurchaseOrderItem)change[0];
            com.uten.imp.common.finance.ProcurementOrderQuantityBounds.synchronizeExpectation(em,orderType(),
                    item.getId(),(BigDecimal)change[2],item.getUnitRate()==null ? BigDecimal.ONE : item.getUnitRate(),
                    (com.uten.imp.common.finance.ProcurementOrderQuantityBounds.ReceiptBound)change[3]);
        }
        com.uten.imp.common.finance.ProcurementOrderClosurePolicy.recalculate(em,orderType(),
                ((PurchaseOrderItem)changes.getFirst()[0]).getId());
        em.refresh(order);
        OrderSnapshot postChange = snapshot(order, items);
        UUID caseId = reconfirmation.openReconfirmationCase(
                postChange, changes.size());
        UUID actorEmployee = currentUser.requireEmployeeId();
        for (Object[] change : changes) {
            PurchaseOrderItem item = (PurchaseOrderItem) change[0];
            em.createNativeQuery("""
                    INSERT INTO procurement_order_qty_change_logs(
                        id, order_type, order_id, order_item_id,
                        old_qty, new_qty, case_id, changed_by_employee_id)
                    VALUES (?, 'PURCHASE', ?, ?, ?, ?, ?, ?)
                    """)
                    .setParameter(1, change[4])
                    .setParameter(2, id)
                    .setParameter(3, item.getId())
                    .setParameter(4, change[1])
                    .setParameter(5, change[2])
                    .setParameter(6, caseId)
                    .setParameter(7, actorEmployee)
                    .executeUpdate();
        }
        return assembleDetail(order);
    }

    private void requireNoPendingApprovalCase(UUID id) {
        Boolean pending = (Boolean) em.createNativeQuery("""
                SELECT EXISTS(
                    SELECT 1
                    FROM procurement_order_approval_cases
                    WHERE order_type = 'PURCHASE' AND order_id = :id
                      AND status = 'PENDING')
                """).setParameter("id", id).getSingleResult();
        if (Boolean.TRUE.equals(pending)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "订货单已在财务复核中，复核办结后才可再次改量");
        }
    }

    private void recalcOrderTotals(PurchaseOrder order, List<PurchaseOrderItem> items) {
        BigDecimal original = BigDecimal.ZERO;
        BigDecimal local = BigDecimal.ZERO;
        for (PurchaseOrderItem item : items) {
            original = original.add(item.getAmountOriginal() == null
                    ? BigDecimal.ZERO : item.getAmountOriginal());
            local = local.add(item.getAmountLocal() == null
                    ? BigDecimal.ZERO : item.getAmountLocal());
        }
        order.setTotalOriginal(original);
        order.setTotalLocal(local);
    }

    /** 单张创建/编辑：结账方式表头必填（批量拆单路径按组合逐行校验，见 groupByCommercial）。 */
    static void requireHeaderSettlement(OrderSaveRequest req) {
        if (req.getSettlementMethodId() == null) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "采购订货单必须选择结账方式");
        }
    }

    /**
     * 单张创建/编辑：行级商业条款（若携带）必须与表头一致——一张订货单只落一套条款
     * （保存到单头）。行值为空表示回落表头（合法）；行级多条款拆单只发生在批量创建
     * （{@link #groupByCommercial}）。
     */
    static void requireRowsMatchHeaderCommercial(OrderSaveRequest req) {
        if (req.getItems() == null) return;
        for (OrderItemLine line : req.getItems()) {
            boolean carriesCommercial = line.getSettlementMethodId() != null
                    || line.getCurrencyId() != null
                    || line.getExchangeRate() != null
                    || line.getTaxRate() != null;
            if (!carriesCommercial) continue;
            boolean same = matchesHeader(line.getSettlementMethodId(), req.getSettlementMethodId())
                    && matchesHeader(line.getCurrencyId(), req.getCurrencyId())
                    && matchesHeaderDecimal(line.getExchangeRate(), req.getExchangeRate())
                    && matchesHeaderDecimal(line.getTaxRate(), req.getTaxRate());
            if (!same) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "既有采购订货单必须保持一套商业条款；多条款新单请使用批量拆单接口");
            }
        }
    }

    private static boolean matchesHeader(UUID lineValue, UUID headerValue) {
        return lineValue == null || java.util.Objects.equals(lineValue, headerValue);
    }

    private static boolean matchesHeaderDecimal(BigDecimal lineValue, BigDecimal headerValue) {
        return lineValue == null
                || (headerValue != null && lineValue.compareTo(headerValue) == 0);
    }

    private void requireActiveSettlementMethod(UUID settlementMethodId, String subject) {
        if (settlementMethodId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, subject + "必须选择结算方式");
        }
        long count = ((Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM settlement_methods
                WHERE id=:id AND status='使用' AND COALESCE(is_deleted,FALSE)=FALSE
                """).setParameter("id", settlementMethodId).getSingleResult()).longValue();
        if (count != 1) {
            throw new ApiException(ErrorCode.CONFLICT,
                    subject + "结算方式不存在、已停用或未经财务核验");
        }
    }

    private static void requireFinanceCommercialAuthority(
            PurchaseOrder order, List<PurchaseOrderItem> items) {
        BigDecimal rate = order.getExchangeRate();
        BigDecimal totalOriginal = BigDecimal.ZERO;
        BigDecimal totalLocal = BigDecimal.ZERO;
        for (PurchaseOrderItem item : items) {
            if (item.getQty() == null || item.getQty().signum() <= 0
                    || item.getPrice() == null || item.getPrice().signum() < 0
                    || item.getAmountOriginal() == null
                    || item.getAmountOriginal().signum() < 0
                    || item.getAmountLocal() == null
                    || item.getAmountLocal().signum() < 0) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "采购订货数量、单价和金额必须完整且不能为负");
            }
            BigDecimal expectedOriginal =
                    money(item.getQty().multiply(item.getPrice()));
            BigDecimal expectedLocal = money(expectedOriginal.multiply(rate));
            if (money(item.getAmountOriginal()).compareTo(expectedOriginal) != 0
                    || money(item.getAmountLocal()).compareTo(expectedLocal) != 0) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "采购订货金额与数量、单价或汇率不一致");
            }
            totalOriginal = totalOriginal.add(expectedOriginal);
            totalLocal = totalLocal.add(expectedLocal);
        }
        if (order.getTotalOriginal() == null
                || order.getTotalLocal() == null
                || money(order.getTotalOriginal()).compareTo(money(totalOriginal)) != 0
                || money(order.getTotalLocal()).compareTo(money(totalLocal)) != 0) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "采购订货表头金额与明细汇总不一致");
        }
    }

    private OrderSnapshot snapshot(
            PurchaseOrder order, List<PurchaseOrderItem> items) {
        return new OrderSnapshot(
                orderType(),
                order.getId(),
                order.getBillNo(),
                order.getBillDate(),
                order.getSupplierId(),
                order.getWarehouseId(),
                order.getCurrencyId(),
                order.getExchangeRate(),
                order.getSettlementMethodId(),
                order.getTaxRate(),
                order.getPurchaserId(),
                order.getMakerId(),
                order.getDeliverDate(),
                order.getTotalOriginal(),
                order.getTotalLocal(),
                items.stream()
                        .map(item -> new ItemSnapshot(
                                item.getId(),
                                item.getLineNo(),
                                item.getRequestItemId(),
                                item.getGoodsId(),
                                item.getColorId(),
                                item.getUnitId(),
                                item.getUnitRate(),
                                item.getQty(),
                                item.getPrice(),
                                item.getAmountOriginal(),
                                item.getAmountLocal(),
                                item.getDeliverDate()))
                        .toList());
    }

    private static BigDecimal money(BigDecimal value) {
        return com.uten.imp.common.util.FinancialExactAmount.canonicalMoney(value,"采购订货金额");
    }

    private static boolean positive(BigDecimal value) {
        return value != null && value.signum() > 0;
    }

    private void recalcRequestClosed(UUID requestItemId) {
        em.createNativeQuery("""
                UPDATE purchase_requests r SET is_closed = (
                    SELECT COALESCE(bool_and(COALESCE(i.qty,0) - COALESCE(i.ordered_qty,0) <= 0), true)
                    FROM purchase_request_items i
                    WHERE i.request_id = r.id AND COALESCE(i.is_deleted, false) = false
                ) WHERE r.id = (SELECT request_id FROM purchase_request_items WHERE id = :iid)
                """).setParameter("iid", requestItemId).executeUpdate();
    }

    private void applyHeader(OrderSaveRequest req, PurchaseOrder o) {
        if (o.getSupplierId() == null
                || !java.util.Objects.equals(o.getSupplierId(), req.getSupplierId())) {
            references.requireSelectableSupplier(req.getSupplierId());
        }
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (o.getBillNo() == null || o.getBillNo().isBlank()) {
            o.setBillNo(docNumberService.nextNumber(DocNumberPrefix.PURCHASE_ORDER));
        }
        o.setBillDate(req.getBillDate());
        o.setSupplierId(req.getSupplierId());
        // V476 运营红线：订货仓库必须选具体叶子仓（收货沿用同仓）。
        if (warehouseScopes != null) {
            warehouseScopes.requireNewLeafSelection(o.getWarehouseId(), req.getWarehouseId(), "仓库");
        }
        o.setWarehouseId(req.getWarehouseId());
        o.setCurrencyId(req.getCurrencyId());
        o.setExchangeRate(req.getExchangeRate()==null?null:com.uten.imp.common.util.FinancialExactAmount.rate(req.getExchangeRate(),"采购汇率"));
        o.setTaxRate(req.getTaxRate());
        o.setPurchaserId(req.getPurchaserId());
        if (!(req.getSettlementMethodId() == null && req.getSettlementStyleLegacy() == null
                && o.getSettlementMethodId() == null && o.getSettlementStyleLegacy() != null)) {
            var settlement = com.uten.imp.common.util.SettlementMethodReferenceResolver.resolve(
                    em, req.getSettlementMethodId(), req.getSettlementStyleLegacy(), "结帐方式");
            o.setSettlementMethodId(settlement == null ? null : settlement.id());
            o.setSettlementStyleLegacy(settlement == null || settlement.legacyId() == null
                    ? null : settlement.legacyId().shortValue());
        }
        o.setDeliverDate(req.getDeliverDate());
        o.setRemark(req.getRemark());
    }

    static void requireRowsMatchHeaderSupplier(OrderSaveRequest req) {
        UUID header = req.getSupplierId();
        if (req.getItems() == null) return;
        for (OrderItemLine line : req.getItems()) {
            if (line.getSupplierId() != null
                    && !java.util.Objects.equals(line.getSupplierId(), header)) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "既有采购订货单必须保持一单一商；多供应商新单请使用批量拆单接口");
            }
        }
    }

    private List<OrderItemDto> saveItems(PurchaseOrder o, List<OrderItemLine> lines) {
        List<OrderItemDto> out = new ArrayList<>(lines.size());
        for (int index = 0; index < lines.size(); index++) {
            OrderItemLine line = lines.get(index);
            int lineNo = line.getLineNo() != null ? line.getLineNo() : index + 1;
            if (line.getRequestItemId() == null) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "第 " + lineNo + " 行必须关联采购申请明细");
            }
            if (line.getQty() == null || line.getQty().signum() <= 0) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "第 " + lineNo + " 行数量必须大于 0");
            }
        }
        // V463 同货品合并行：行数量按各申请行剩余量 FIFO 拆分到 sources
        //（末位来源吸收超额），request_item_id 落首来源（主锚点）。
        Map<OrderItemLine, List<SourceSplit>> splits = planSourceSplits(lines);
        Map<UUID, PurchaseGoodsSnapshot> requestSnapshots =
                PurchaseGoodsSnapshot.fromRequestItems(
                        em,
                        splits.values().stream().flatMap(List::stream)
                                .map(SourceSplit::requestItemId).distinct().toList(),
                        PurchaseGoodsSnapshot.REQUEST_ITEM_AT_SAVE);
        // 谱系继承：订货行从首来源申请行继承 来源计划号/销售订单号/需求日期，
        // 采购全程可溯源到销售来源（合并行跨申请时取首来源=最早需求日的谱系）。
        Map<UUID, Object[]> requestLineage = requestItemLineage(
                splits.values().stream().flatMap(List::stream)
                        .map(SourceSplit::requestItemId).distinct().toList());
        Map<UUID, PurchaseGoodsSnapshot> masterSnapshots =
                PurchaseGoodsSnapshot.fromMaster(
                        em,
                        lines.stream().map(OrderItemLine::getGoodsId).toList(),
                        PurchaseGoodsSnapshot.MASTER_AT_SAVE);
        UUID actorId = currentUser.requireId();
        int auto = 1;
        for (OrderItemLine l : lines) {
            int lineNo = l.getLineNo() != null ? l.getLineNo() : auto;
            PurchaseLineUnitPolicy.ResolvedUnit resolvedUnit =
                    lineUnitPolicy.normalizeAndValidate(
                            l.getGoodsId(), l.getUnitId(), l.getUnitRate(), lineNo);
            List<SourceSplit> lineSplits = splits.getOrDefault(l, List.of());
            UUID primarySource = lineSplits.getFirst().requestItemId();
            PurchaseOrderItem it = new PurchaseOrderItem();
            it.setOrderId(o.getId());
            it.setBillNo(o.getBillNo());
            it.setBillDate(o.getBillDate());
            it.setLineNo(lineNo);
            it.setGoodsId(l.getGoodsId());
            applyGoodsSnapshot(
                    it,
                    PurchaseGoodsSnapshot.preferred(
                            requestSnapshots,
                            primarySource,
                            masterSnapshots,
                            l.getGoodsId(),
                            "采购订货明细"),
                    null);
            it.setColorId(l.getColorId());
            it.setUnitId(resolvedUnit.unitId());
            it.setUnitRate(resolvedUnit.unitRate());
            it.setQty(l.getQty());
            it.setPrice(l.getPrice()==null?null:com.uten.imp.common.util.FinancialExactAmount.unitPrice(l.getPrice(),"采购单价"));
            it.setAmountOriginal(l.getAmountOriginal());
            it.setAmountLocal(l.getAmountLocal() != null ? l.getAmountLocal() : l.getAmountOriginal());
            it.setGiftQty(l.getGiftQty() != null ? l.getGiftQty() : BigDecimal.ZERO);
            it.setRequestItemId(primarySource);
            it.setDeliverDate(l.getDeliverDate());
            it.setWeight(l.getWeight());
            it.setSourceDocNo(l.getSourceDocNo());
            // 谱系继承：优先取首来源申请行的计划号/销售单号/需求日（客户端不传也不丢溯源）。
            Object[] lineage = requestLineage.get(primarySource);
            if (lineage != null) {
                if (it.getSourceDocNo() == null || it.getSourceDocNo().isBlank()) {
                    it.setSourceDocNo((String) lineage[0]);
                }
                if (it.getDeliverDate() == null) {
                    it.setDeliverDate(toLocalDate(lineage[3]));
                }
                it.setProductionPlanNo((String) lineage[1]);
                it.setSalesOrderNo((String) lineage[2]);
            }
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            itemRepo.flush();
            int sourceLine = 1;
            for (SourceSplit split : lineSplits) {
                em.createNativeQuery("""
                        INSERT INTO purchase_order_item_sources (
                            order_item_id, request_item_id, alloc_qty, line_no, created_by)
                        VALUES (:orderItemId, :requestItemId, :allocQty, :lineNo, :actorId)
                        """)
                        .setParameter("orderItemId", it.getId())
                        .setParameter("requestItemId", split.requestItemId())
                        .setParameter("allocQty", split.allocQty())
                        .setParameter("lineNo", sourceLine++)
                        .setParameter("actorId", actorId)
                        .executeUpdate();
            }
            out.add(toItemDto(it, List.of()));
            auto++;
        }
        return out;
    }

    /** V463 合并行来源分配结果：requestItemId + 归属本行的数量份额。 */
    record SourceSplit(UUID requestItemId, BigDecimal allocQty) {}

    /**
     * 同货品合并行的来源 FIFO 拆分：按各申请行当前剩余量
     *（qty - ordered_qty - 待财务审核订货占用，与分解预览同口径）在
     *「需求日期升序、id 升序」稳定顺序上先到先得，末位来源吸收超额（超采）；
     * 份额为 0 的来源丢弃。单来源行退化为 alloc = 行数量（与历史单锚一致）。
     */
    private Map<OrderItemLine, List<SourceSplit>> planSourceSplits(List<OrderItemLine> lines) {
        List<UUID> allIds = lines.stream()
                .flatMap(line -> line.resolvedRequestItemIds().stream())
                .distinct().toList();
        Map<OrderItemLine, List<SourceSplit>> result = new java.util.LinkedHashMap<>();
        if (allIds.isEmpty()) {
            return result;
        }
        List<Object[]> rows = com.uten.imp.common.util.NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT item.id,
                               GREATEST(COALESCE(item.qty, 0) - COALESCE(item.ordered_qty, 0)
                                        - COALESCE(pending.pending_qty, 0), 0) AS remaining_qty,
                               COALESCE(item.deliver_date, request.need_date) AS need_date
                        FROM purchase_request_items item
                        JOIN purchase_requests request ON request.id = item.request_id
                        LEFT JOIN (
                            SELECT src.request_item_id, SUM(COALESCE(src.alloc_qty, 0)) AS pending_qty
                            FROM procurement_order_approval_cases approval
                            JOIN purchase_orders po
                              ON approval.order_type = 'PURCHASE'
                             AND approval.order_id = po.id
                             AND approval.status = 'PENDING'
                            JOIN purchase_order_items oi ON oi.order_id = po.id
                            JOIN purchase_order_item_sources src ON src.order_item_id = oi.id
                            WHERE po.status = 0
                              AND po.is_deleted = FALSE
                              AND oi.is_deleted = FALSE
                              AND src.request_item_id IN (:ids)
                            GROUP BY src.request_item_id
                        ) pending ON pending.request_item_id = item.id
                        WHERE item.id IN (:ids)
                        ORDER BY CASE WHEN EXISTS (
                                     SELECT 1 FROM preplan_supply_actions action
                                     WHERE action.public_surplus_external_item_id = item.id
                                   ) THEN 1 ELSE 0 END,
                                 COALESCE(item.deliver_date, request.need_date) NULLS LAST,
                                 item.id
                        """).setParameter("ids", allIds));
        Map<UUID, BigDecimal> remaining = new java.util.HashMap<>();
        List<UUID> stableOrder = new ArrayList<>();
        for (Object[] row : rows) {
            UUID id = (UUID) row[0];
            remaining.put(id, (BigDecimal) row[1]);
            stableOrder.add(id);
        }
        for (OrderItemLine line : lines) {
            List<UUID> ordered = line.resolvedRequestItemIds().stream()
                    .sorted(java.util.Comparator.comparing(
                            id -> stableOrder.contains(id)
                                    ? stableOrder.indexOf(id)
                                    : Integer.MAX_VALUE))
                    .toList();
            BigDecimal budget = line.getQty();
            List<SourceSplit> splits = new ArrayList<>();
            for (int index = 0; index < ordered.size(); index++) {
                UUID sourceId = ordered.get(index);
                boolean last = index == ordered.size() - 1;
                BigDecimal take = last
                        ? budget.max(BigDecimal.ZERO)
                        : budget.min(remaining.getOrDefault(sourceId, BigDecimal.ZERO))
                                .max(BigDecimal.ZERO);
                if (take.signum() <= 0) {
                    continue;
                }
                splits.add(new SourceSplit(sourceId, take));
                budget = budget.subtract(take);
                if (budget.signum() <= 0 && !last) {
                    break;
                }
            }
            if (splits.isEmpty()) {
                // 全部来源剩余量为 0 的极端退化：首来源承接全量（超采口径）。
                splits.add(new SourceSplit(line.getRequestItemId(), line.getQty()));
            }
            result.put(line, splits);
        }
        return result;
    }

    private void captureGoodsSnapshots(
            List<PurchaseOrderItem> items,
            String requestSource,
            String masterSource,
            OffsetDateTime lockedAt) {
        Map<UUID, PurchaseGoodsSnapshot> requestSnapshots =
                PurchaseGoodsSnapshot.fromRequestItems(
                        em,
                        items.stream().map(PurchaseOrderItem::getRequestItemId).toList(),
                        requestSource);
        Map<UUID, PurchaseGoodsSnapshot> masterSnapshots =
                PurchaseGoodsSnapshot.fromMaster(
                        em,
                        items.stream().map(PurchaseOrderItem::getGoodsId).toList(),
                        masterSource);
        for (PurchaseOrderItem item : items) {
            PurchaseGoodsSnapshot snapshot = PurchaseGoodsSnapshot.preferred(
                    requestSnapshots,
                    item.getRequestItemId(),
                    masterSnapshots,
                    item.getGoodsId(),
                    "采购订货明细");
            int updated = em.createNativeQuery("""
                    UPDATE purchase_order_items
                    SET goods_code_snapshot = :code,
                        goods_name_snapshot = :name,
                        goods_snapshot_source = :source,
                        goods_snapshot_locked_at = :lockedAt
                    WHERE id = :id
                      AND goods_snapshot_locked_at IS NULL
                    """)
                    .setParameter("code", snapshot.code())
                    .setParameter("name", snapshot.name())
                    .setParameter("source", snapshot.source())
                    .setParameter("lockedAt", lockedAt)
                    .setParameter("id", item.getId())
                    .executeUpdate();
            if (updated != 1) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "采购订货明细货品快照已锁定或不存在，请刷新后重试");
            }
        }
    }

    private static void applyGoodsSnapshot(
            PurchaseOrderItem item,
            PurchaseGoodsSnapshot snapshot,
            OffsetDateTime lockedAt) {
        item.setGoodsCodeSnapshot(snapshot.code());
        item.setGoodsNameSnapshot(snapshot.name());
        item.setGoodsSnapshotSource(snapshot.source());
        item.setGoodsSnapshotLockedAt(lockedAt);
    }

    private void normalizePersistedItemUnits(List<PurchaseOrderItem> items) {
        int fallbackLineNo = 1;
        for (PurchaseOrderItem item : items) {
            int lineNo = item.getLineNo() != null ? item.getLineNo() : fallbackLineNo;
            PurchaseLineUnitPolicy.ResolvedUnit resolvedUnit =
                    lineUnitPolicy.normalizeAndValidate(
                            item.getGoodsId(), item.getUnitId(), item.getUnitRate(), lineNo);
            item.setUnitId(resolvedUnit.unitId());
            item.setUnitRate(resolvedUnit.unitRate());
            fallbackLineNo++;
        }
        itemRepo.saveAll(items);
    }

    private void applyTotals(PurchaseOrder o, List<OrderItemDto> items) {
        BigDecimal local = items.stream().map(i -> i.getAmountLocal() == null ? BigDecimal.ZERO : i.getAmountLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = items.stream().map(i -> i.getAmountOriginal() == null ? BigDecimal.ZERO : i.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        o.setTotalLocal(local);
        o.setTotalOriginal(original);
        orderRepo.save(o);
    }

    private OrderListItem toList(
            PurchaseOrder order, FinanceApproval approval, boolean priceMasked) {
        return new OrderListItem(
                order.getId(),
                order.getBillNo(),
                order.getBillDate(),
                order.getSupplierId(),
                priceMasked ? null : order.getTotalLocal(),
                order.getStatus(),
                order.isClosed(),
                order.getLegacyId(),
                approval,
                priceMasked);
    }

    /** 原生查询 DATE 列（驱动返回 java.sql.Date）安全转 LocalDate。 */
    private static java.time.LocalDate toLocalDate(Object value) {
        if (value == null) return null;
        if (value instanceof java.time.LocalDate localDate) return localDate;
        if (value instanceof java.sql.Date sqlDate) return sqlDate.toLocalDate();
        if (value instanceof java.time.OffsetDateTime odt) return odt.toLocalDate();
        return java.time.LocalDate.parse(value.toString());
    }

    /** 申请行谱系：id → [source_doc_no, production_plan_no, sales_order_no, deliver_date]，供订货行继承。 */
    @SuppressWarnings("unchecked")
    private Map<UUID, Object[]> requestItemLineage(List<UUID> requestItemIds) {
        if (requestItemIds == null || requestItemIds.isEmpty()) return Map.of();
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id, source_doc_no, production_plan_no, sales_order_no, deliver_date
                        FROM purchase_request_items
                        WHERE id IN (:ids)
                        """)
                .setParameter("ids", requestItemIds)
                .getResultList();
        Map<UUID, Object[]> out = new java.util.HashMap<>();
        for (Object[] row : rows) {
            out.put((UUID) row[0], new Object[]{row[1], row[2], row[3], row[4]});
        }
        return out;
    }

    private OrderItemDto toItemDto(PurchaseOrderItem it) {
        return toItemDto(it, List.of());
    }

    /** V463：明细同时暴露全部来源申请（合并行多来源展示/编辑回显）。 */
    private OrderItemDto toItemDto(
            PurchaseOrderItem it,
            List<OrderItemDto.SourceRequestDoc> sourceRequests) {
        return new OrderItemDto(it.getId(), it.getLineNo(), it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(), it.getGoodsSnapshotSource(),
                it.getGoodsSnapshotLockedAt(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getReceivedQty(), it.getReturnedQty(), it.getGiftQty(),
                it.getRequestItemId(), it.getDeliverDate(), it.getWeight(), it.getSourceDocNo(),
                it.getProductionPlanNo(), it.getSalesOrderNo(), it.getRemark(),
                sourceRequests);
    }

    private OrderDetail toDetail(PurchaseOrder order, List<OrderItemDto> items) {
        FinanceApproval approval = approvalProjection.latestForOrder(
                orderType(), order.getId(), order.getStatus());
        return toDetail(order, items, approval);
    }

    private OrderDetail toDetail(
            PurchaseOrder order,
            List<OrderItemDto> items,
            FinanceApproval approval) {
        boolean priceMasked = purchasePriceMasked();
        boolean productionLinked =
                productionSourceGuard.isPurchaseOrderLinked(order.getId());
        boolean pending = approval != null
                && "PENDING".equals(approval.status());
        boolean canEdit = order.getStatus() == STATUS_DRAFT
                && !pending;
        OrderSourceRef sourceRequest = singleRequestSource(items);
        List<OrderItemDto> safeItems = priceMasked
                ? items.stream().map(PurchaseOrderService::maskItemPrices).toList()
                : items;
        return new OrderDetail(
                order.getId(), order.getLegacyId(), order.getBillNo(), order.getBillDate(),
                order.getSupplierId(), order.getWarehouseId(), priceMasked ? null : order.getCurrencyId(),
                priceMasked ? null : order.getExchangeRate(), priceMasked ? null : order.getTaxRate(),
                order.getPurchaserId(), priceMasked ? null : order.getSettlementMethodId(),
                priceMasked || order.getSettlementStyleLegacy() == null
                        ? null : order.getSettlementStyleLegacy().intValue(),
                order.getMakerId(), order.getApproverId(), order.getDeliverDate(),
                order.getRemark(), priceMasked ? null : order.getTotalOriginal(),
                priceMasked ? null : order.getTotalLocal(),
                order.getStatus(), order.isClosed(), order.getSourceDocNo(), safeItems,
                nameResolver.nameOf(order.getMakerId()), order.getCreatedAt(),
                productionLinked, canEdit, canEdit,
                order.getStatus() == STATUS_APPROVED,
                restrictionReason(pending),
                approval,
                sourceRequest == null ? null : sourceRequest.id(),
                sourceRequest == null ? null : sourceRequest.billNo(),
                priceMasked);
    }

    private boolean purchasePriceMasked() {
        return commercialPriceVisibility == null
                || !commercialPriceVisibility.canViewPurchaseOrder();
    }

    private static OrderItemDto maskItemPrices(OrderItemDto it) {
        return new OrderItemDto(it.getId(), it.getLineNo(), it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(), it.getGoodsSnapshotSource(),
                it.getGoodsSnapshotLockedAt(), it.getColorId(), it.getUnitId(), it.getUnitRate(),
                it.getQty(), null, null, null, it.getReceivedQty(), it.getReturnedQty(),
                it.getGiftQty(), it.getRequestItemId(), it.getDeliverDate(), it.getWeight(),
                it.getSourceDocNo(), it.getProductionPlanNo(), it.getSalesOrderNo(), it.getRemark(),
                it.getSourceRequests());
    }

    /** 全部明细（含 V463 合并行全部来源）同属一张采购申请时返回该申请 (id, billNo)；否则 null。 */
    private OrderSourceRef singleRequestSource(List<OrderItemDto> items) {
        List<UUID> requestItemIds = items.stream()
                .flatMap(it -> it.getSourceRequests() != null && !it.getSourceRequests().isEmpty()
                        ? it.getSourceRequests().stream()
                                .map(OrderItemDto.SourceRequestDoc::requestItemId)
                        : java.util.stream.Stream.of(it.getRequestItemId()))
                .filter(id -> id != null).distinct().toList();
        if (requestItemIds.isEmpty()) return null;
        List<Object[]> rows = com.uten.imp.common.util.NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT DISTINCT pr.id, pr.bill_no
                        FROM purchase_request_items i
                        JOIN purchase_requests pr ON pr.id = i.request_id
                        WHERE i.id IN (:ids)
                        """).setParameter("ids", requestItemIds));
        return rows.size() == 1 ? new OrderSourceRef((UUID) rows.getFirst()[0], (String) rows.getFirst()[1]) : null;
    }

    /** 详情头溯源引用（id 供跳转、billNo 供展示）。 */
    public record OrderSourceRef(UUID id, String billNo) {
    }



    private String restrictionReason(boolean financePending) {
        if (financePending) {
            return "该采购订单正在财务审核，驳回后方可修改或删除";
        }
        return null;
    }

    private PurchaseOrder requireOrder(UUID id) {
        return orderRepo.findById(id).filter(o -> !o.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "采购订货单不存在"));
    }
    private PurchaseOrder requireOrderForUpdate(UUID id) {
        PurchaseOrder order = em.find(
                PurchaseOrder.class, id, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        return order == null || order.isDeleted()
                ? requireOrder(id)
                : order;
    }
}
