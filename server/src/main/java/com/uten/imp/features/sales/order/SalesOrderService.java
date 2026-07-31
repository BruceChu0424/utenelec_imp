package com.uten.imp.features.sales.order;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.order.dto.OrderCostItemDto;
import com.uten.imp.features.sales.order.dto.OrderDetail;
import com.uten.imp.features.sales.order.dto.OrderItemDto;
import com.uten.imp.features.sales.order.dto.OrderItemLine;
import com.uten.imp.features.sales.order.dto.OrderListItem;
import com.uten.imp.features.sales.order.dto.OrderQueryFilter;
import com.uten.imp.features.sales.order.dto.OrderSaveRequest;
import com.uten.imp.features.production.plan.PlanOrderItemLink;
import com.uten.imp.features.production.plan.PlanOrderItemLinkRepository;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.StockReservation;
import com.uten.imp.features.stock.StockReservationService;
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

import java.time.LocalDate;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 销售订货单服务：CRUD（主+明细）+ 审核状态机。
 *
 * <p>审核（0→1）：业务链库存检查 + 软预留（V90，docs/07-业务链路/02）——逐行查全局可用量，
 * 够则全量预留（行→可发货），不够则部分预留、差额待排产；不立应收、不动库存流水。
 * 红冲 1→-1：对称释放全部预留（已发货/已排产的订单禁止红冲，走取消流程）。
 * BOM 展开子表 {@link SalesOrderCostItem} 本期只读（design 20 §一·13）。
 * is_closed 由出货/退货审核 Service 重算（{@code features.sales.shipment} / {@code .ret}）。
 */
@Service
@RequiredArgsConstructor
public class SalesOrderService {

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** 链路行状态（V90 chain_status；本类只用审核/改量落点，其余由下游 Service 推进）。 */
    private static final short CHAIN_PARTIAL_RESERVED = 1;  // 部分预留
    private static final short CHAIN_PENDING_PLAN = 2;      // 待排产
    private static final short CHAIN_PLANNED = 4;           // 已排产
    private static final short CHAIN_SHIPPABLE = 7;         // 可发货
    private static final short CHAIN_SHIPPED = 9;           // 已发货
    private static final short CHAIN_CANCELED = -1;         // 已取消

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "total", "totalLocal");

    private final SalesOrderRepository orderRepo;
    private final SalesOrderItemRepository itemRepo;
    private final SalesOrderCostItemRepository costItemRepo;
    private final StockReservationService reservationService;
    private final PlanOrderItemLinkRepository linkRepo;
    private final com.uten.imp.features.sales.quote.SalesQuoteRepository quoteRepo;
    private final com.uten.imp.features.sales.quote.SalesQuoteItemRepository quoteItemRepo;
    private final SalesPriceMasker priceMasker;
    private final SalesDocumentAccessPolicy accessPolicy;
    private final com.uten.imp.security.SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final TxSessionVars tx;
    private final DocNumberService docNumberService;
    private final EntityManager em;
    private final com.uten.imp.features.notice.ChainNoticeService chainNotice;

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_order:view')")
    public PageResponse<OrderListItem> list(OrderQueryFilter f, int page, int size, String sort, String order) {
        // 可发货置顶（工作台小项）：sort=shippable 走专用排序——有预留（可发）的单排前，
        // 次按交货日升序（临近在前）、再按开单日期倒序；此时忽略列排序。
        boolean shippableFirst = "shippable".equals(sort);
        var readScope = accessPolicy.scope();
        Specification<SalesOrder> spec = (Root<SalesOrder> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                          CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            ps.add(accessPolicy.readablePredicate(root, cb, "ownerEmployeeId", readScope));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                String kw = "%" + f.keyword().toLowerCase() + "%";
                // 关键字同时匹配 单据号 / 客户名称（生产计划选单、日常检索都按客户找单）
                jakarta.persistence.criteria.Subquery<UUID> cs = q.subquery(UUID.class);
                Root<com.uten.imp.features.master.client.Client> cr =
                        cs.from(com.uten.imp.features.master.client.Client.class);
                cs.select(cr.get("id")).where(cb.isFalse(cr.get("deleted")),
                        cb.like(cb.lower(cr.get("name")), kw));
                ps.add(cb.or(cb.like(cb.lower(root.get("billNo")), kw),
                        root.get("clientId").in(cs)));
            }
            if (f.clientId() != null) ps.add(cb.equal(root.get("clientId"), f.clientId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.closed() != null) ps.add(cb.equal(root.get("closed"), f.closed()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            // 链路状态组筛选（工作台统计卡钻取）：存在任一明细行命中即返回
            if (f.chain() != null && !f.chain().isEmpty()) {
                jakarta.persistence.criteria.Subquery<UUID> sub = q.subquery(UUID.class);
                Root<SalesOrderItem> i = sub.from(SalesOrderItem.class);
                sub.select(i.get("orderId")).where(i.get("chainStatus").in(f.chain()));
                ps.add(root.get("id").in(sub));
            }
            if (shippableFirst) {
                // 可发货置顶：Σ行预留 > 0 的单排前（CASE 1/0 DESC），次按交货日升序、开单日期倒序
                // （明细实体未映射 is_deleted，与上方 chain 钻取子查询同口径不滤删除行）
                jakarta.persistence.criteria.Subquery<BigDecimal> sum = q.subquery(BigDecimal.class);
                Root<SalesOrderItem> i2 = sum.from(SalesOrderItem.class);
                sum.select(cb.coalesce(cb.sum(i2.get("reservedQty")), BigDecimal.ZERO))
                        .where(cb.equal(i2.get("orderId"), root.get("id")));
                q.orderBy(
                        cb.desc(cb.selectCase()
                                .when(cb.gt(sum, BigDecimal.ZERO), 1).otherwise(0).as(Integer.class)),
                        cb.asc(root.get("deliverDate")),
                        cb.desc(root.get("billDate")));
            }
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                shippableFirst ? Sort.unsorted()
                        : TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<SalesOrder> p = orderRepo.findAll(spec, pageable);
        boolean canEdit = accessPolicy.hasAuthority("sales_order:edit");
        return new PageResponse<>(p.map(o -> toList(o,
                        canEdit && accessPolicy.canWrite(o.getOwnerEmployeeId(), readScope))).getContent(),
                page, size, p.getTotalElements(), p.getTotalPages());
    }

    /**
     * 批量发货可发行（SOP §一9）：已审未结案未中止订单中 reserved_qty>0 的行，
     * 按客户→交货日→单号排序（前端勾选+改本次数量，同客户合并一张出货单）。
     * 归属隔离与 list/stats 同口径。
     */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_order:view')")
    public List<com.uten.imp.features.sales.order.dto.OrderShippableLine> shippableLines() {
        var writeScope = accessPolicy.scope();
        var ownerScope = accessPolicy.nativeReadScope(
                "o.owner_employee_id", "salesOwners", writeScope);
        boolean canCreateShipment = accessPolicy.hasAuthority("sales_shipment:edit");
        String sql = """
                SELECT i.id, i.order_id, o.bill_no, o.client_id, i.deliver_date, i.goods_id, i.color_id,
                       i.unit_id, i.unit_rate, i.qty, i.shipped_qty, i.reserved_qty, i.price,
                       o.owner_employee_id
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                WHERE o.status = 1 AND o.is_closed = false AND o.is_stopped = false
                  AND COALESCE(o.is_deleted,false) = false AND COALESCE(i.is_deleted,false) = false
                  AND COALESCE(i.reserved_qty,0) > 0
                """ + " AND " + ownerScope.predicate()
                + " ORDER BY o.client_id, i.deliver_date NULLS LAST, o.bill_no, i.line_no NULLS LAST";
        var q = em.createNativeQuery(sql);
        ownerScope.bind(q);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        List<com.uten.imp.features.sales.order.dto.OrderShippableLine> out = new ArrayList<>(rows.size());
        for (Object[] r : rows) {
            out.add(new com.uten.imp.features.sales.order.dto.OrderShippableLine(
                    (UUID) r[0], (UUID) r[1], (String) r[2], (UUID) r[3],
                    r[4] == null ? null : ((java.sql.Date) r[4]).toLocalDate(),
                    (UUID) r[5], (UUID) r[6], (UUID) r[7],
                    (BigDecimal) r[8], (BigDecimal) r[9], (BigDecimal) r[10],
                    (BigDecimal) r[11], (BigDecimal) r[12],
                    canCreateShipment && accessPolicy.canWrite((UUID) r[13], writeScope)));
        }
        return out;
    }

    /**
     * 工作台统计卡（SOP §四）：待生产 / 生产中 / 待发货 / 本月完成。
     * 一单可同时落入多卡（卡片即筛选器）；口径与 list 同数据范围（sales:view:all 豁免）。
     */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_order:view')")
    public com.uten.imp.features.sales.order.dto.OrderStats stats() {
        var ownerScope = accessPolicy.nativeReadScope("o.owner_employee_id", "salesOwners");
        String sql = """
                SELECT
                  COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM sales_order_items i
                      WHERE i.order_id = o.id AND i.is_deleted = false AND i.chain_status IN (2,3,4))),
                  COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM sales_order_items i
                      WHERE i.order_id = o.id AND i.is_deleted = false AND i.chain_status IN (5,6))),
                  COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM sales_order_items i
                      WHERE i.order_id = o.id AND i.is_deleted = false
                        AND COALESCE(i.reserved_qty,0) > 0)),
                  COUNT(*) FILTER (WHERE o.is_closed
                        AND o.bill_date >= CAST(:monthStart AS date))
                FROM sales_orders o
                WHERE o.is_deleted = false AND o.status = 1
                """ + " AND " + ownerScope.predicate();
        var q = em.createNativeQuery(sql);
        ownerScope.bind(q);
        q.setParameter("monthStart", BusinessTime.today().withDayOfMonth(1));
        Object[] r = (Object[]) q.getSingleResult();
        return new com.uten.imp.features.sales.order.dto.OrderStats(
                ((Number) r[0]).longValue(), ((Number) r[1]).longValue(),
                ((Number) r[2]).longValue(), ((Number) r[3]).longValue());
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_order:view')")
    public OrderDetail detail(UUID id) {
        SalesOrder o = requireReadableOrder(id);
        List<SalesOrderItem> items = itemRepo.findByOrderIdOrderByLineNoAsc(id);
        List<OrderItemDto> itemDtos = items.stream().map(this::toItemDto).toList();
        List<OrderCostItemDto> costDtos = items.isEmpty() ? List.of()
                : costItemRepo.findByOrderItemIdIn(items.stream().map(SalesOrderItem::getId).toList())
                        .stream().map(this::toCostDto).toList();
        OrderDetail d = toDetail(o, itemDtos, costDtos,
                accessPolicy.hasAuthority("sales_order:edit")
                        && accessPolicy.canWrite(o.getOwnerEmployeeId()));
        fillQuoteTrace(o, d); // 报价转入回联：sourceQuoteId + 行级 quotePrice（价格留痕比对）
        return d;
    }

    /**
     * 排产进度（销售端看链路另一端）：每行 订货/可发/已排/已产/已发 + chain_status
     * + 关联生产计划溯源（plan_order_item_links → production_plans；含合并排产预建的草稿计划）。
     * 只读接口，归属校验与 detail 同口径（不可见单据按不存在处理）。
     */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_order:view')")
    public List<com.uten.imp.features.sales.order.dto.PlanProgressLine> planProgress(UUID id) {
        requireReadableOrder(id);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT i.id, i.line_no, g.code, g.name, g.spec, col.name, u.name,
                       i.qty, COALESCE(i.reserved_qty,0), COALESCE(i.planned_qty,0),
                       COALESCE(i.produced_qty,0), COALESCE(i.shipped_qty,0), i.chain_status
                FROM sales_order_items i
                JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors col ON col.id = i.color_id
                LEFT JOIN units u ON u.id = i.unit_id
                WHERE i.order_id = :oid AND i.is_deleted = false
                ORDER BY i.line_no NULLS LAST, i.id
                """).setParameter("oid", id).getResultList();
        List<UUID> itemIds = rows.stream().map(r -> (UUID) r[0]).toList();
        Map<UUID, List<com.uten.imp.features.sales.order.dto.PlanProgressLine.ExecutionSegmentProgress>>
                segmentsByLink = new HashMap<>();
        Map<UUID, List<com.uten.imp.features.sales.order.dto.PlanProgressLine.PlanLink>> byItem =
                new HashMap<>();
        if (!itemIds.isEmpty()) {
            @SuppressWarnings("unchecked")
            List<Object[]> segmentRows = em.createNativeQuery("""
                    SELECT allocation.plan_order_item_link_id,
                           segment.id, segment.segment_code, segment.status,
                           allocation.allocated_qty,
                           COALESCE((
                               SELECT SUM(report_item.qty)
                               FROM production_daily_report_items report_item
                               JOIN production_daily_reports report
                                 ON report.id = report_item.report_id
                               WHERE report_item.execution_segment_sales_allocation_id =
                                     allocation.id
                                 AND report_item.is_deleted = FALSE
                                 AND report.is_deleted = FALSE
                                 AND report.status = 1
                           ), 0) AS reported_qty,
                           COALESCE((
                               SELECT SUM(stock_item.qty)
                               FROM stock_document_items stock_item
                               JOIN stock_documents stock_document
                                 ON stock_document.id = stock_item.doc_id
                               WHERE stock_item.execution_segment_sales_allocation_id =
                                     allocation.id
                                 AND stock_item.is_deleted = FALSE
                                 AND stock_document.is_deleted = FALSE
                                 AND stock_document.doc_type = 'FINISHED_IN'
                                 AND stock_document.status = 1
                           ), 0) AS inbound_qty,
                           workshop.name, team.name,
                           segment.plan_begin_date, segment.plan_end_date,
                           (
                               SELECT MIN(event.created_at)
                               FROM production_execution_segment_events event
                               WHERE event.execution_segment_id = segment.id
                                 AND event.action = 'START'
                           ) AS actual_start_at,
                           (
                               segment.status <> 'COMPLETED'
                               AND segment.plan_end_date IS NOT NULL
                               AND segment.plan_end_date < CURRENT_DATE
                           ) AS delayed
                    FROM execution_segment_sales_allocations allocation
                    JOIN production_execution_segments segment
                      ON segment.id = allocation.execution_segment_id
                     AND segment.is_deleted = FALSE
                    LEFT JOIN departments workshop
                      ON workshop.id = segment.workshop_department_id
                     AND workshop.is_deleted = FALSE
                    LEFT JOIN departments team
                      ON team.id = segment.team_department_id
                     AND team.is_deleted = FALSE
                    WHERE allocation.sales_order_item_id IN (:ids)
                    ORDER BY allocation.plan_order_item_link_id,
                             segment.plan_begin_date ASC NULLS LAST,
                             segment.segment_no,
                             segment.id
                    """).setParameter("ids", itemIds).getResultList();
            for (Object[] segment : segmentRows) {
                boolean delayed = Boolean.TRUE.equals(segment[12]);
                segmentsByLink.computeIfAbsent(
                                (UUID) segment[0],
                                ignored -> new ArrayList<>())
                        .add(new com.uten.imp.features.sales.order.dto.PlanProgressLine.ExecutionSegmentProgress(
                                (UUID) segment[1],
                                (String) segment[2],
                                (String) segment[3],
                                nz((BigDecimal) segment[4]),
                                nz((BigDecimal) segment[5]),
                                nz((BigDecimal) segment[6]),
                                (String) segment[7],
                                (String) segment[8],
                                localDate(segment[9]),
                                localDate(segment[10]),
                                offsetDateTime(segment[11]),
                                delayed,
                                delayed ? "Planned completion date has passed" : null));
            }

            @SuppressWarnings("unchecked")
            List<Object[]> links = em.createNativeQuery("""
                    SELECT l.id, l.order_item_id, p.id, p.bill_no, p.status, p.is_closed, p.bill_date,
                           l.allocated_qty, COALESCE(l.produced_qty,0), COALESCE(l.inbound_qty,0)
                    FROM plan_order_item_links l
                    JOIN production_plan_items pi ON pi.id = l.plan_item_id
                    JOIN production_plans p ON p.id = pi.plan_id
                    WHERE l.order_item_id IN (:ids) AND l.is_deleted = false AND p.is_deleted = false
                    ORDER BY p.bill_date DESC NULLS LAST, p.bill_no
                    """).setParameter("ids", itemIds).getResultList();
            for (Object[] l : links) {
                byItem.computeIfAbsent((UUID) l[1], k -> new ArrayList<>())
                        .add(new com.uten.imp.features.sales.order.dto.PlanProgressLine.PlanLink(
                                (UUID) l[2], (String) l[3],
                                l[4] == null ? null : ((Number) l[4]).shortValue(),
                                Boolean.TRUE.equals(l[5]),
                                localDate(l[6]),
                                nz((BigDecimal) l[7]), nz((BigDecimal) l[8]),
                                nz((BigDecimal) l[9]),
                                segmentsByLink.getOrDefault(
                                        (UUID) l[0], List.of())));
            }
        }
        List<com.uten.imp.features.sales.order.dto.PlanProgressLine> out = new ArrayList<>(rows.size());
        for (Object[] r : rows) {
            out.add(new com.uten.imp.features.sales.order.dto.PlanProgressLine(
                    (UUID) r[0], r[1] == null ? null : ((Number) r[1]).intValue(),
                    (String) r[2], (String) r[3], (String) r[4], (String) r[5], (String) r[6],
                    nz((BigDecimal) r[7]), nz((BigDecimal) r[8]), nz((BigDecimal) r[9]),
                    nz((BigDecimal) r[10]), nz((BigDecimal) r[11]),
                    r[12] == null ? null : ((Number) r[12]).shortValue(),
                    byItem.getOrDefault((UUID) r[0], List.of())));
        }
        return out;
    }

    /** 报价转入回联（SOP §三1）：sourceDocNo 命中报价单号 → 回填来源报价 ID + 各行报价单价。 */
    private void fillQuoteTrace(SalesOrder o, OrderDetail d) {
        if (o.getSourceDocNo() == null || o.getSourceDocNo().isBlank()) return;
        quoteRepo.findByBillNo(o.getSourceDocNo()).filter(q -> !q.isDeleted()).ifPresent(q -> {
            // The order permission alone must not become a side door into an
            // inaccessible quote or its historical prices.
            if (!accessPolicy.hasAuthority("sales_quote:view")
                    || !accessPolicy.canRead(q.getMakerId())) {
                d.setSourceDocNo(null);
                return;
            }
            d.setSourceQuoteId(q.getId());
            if (!priceMasker.canView()) {
                return;
            }
            Map<Integer, BigDecimal> priceByLine = new HashMap<>();
            for (var qi : quoteItemRepo.findByQuoteIdOrderByLineNoAsc(q.getId())) {
                priceByLine.put(qi.getLineNo(), qi.getPrice());
            }
            for (OrderItemDto it : d.getItems()) {
                BigDecimal qp = priceByLine.get(it.getLineNo());
                if (qp != null) it.setQuotePrice(qp);
            }
        });
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_order:edit')")
    public OrderDetail create(OrderSaveRequest req) {
        return createInternal(req, null);
    }

    /**
     * Quote conversion entry point. The supplied owner is checked against the
     * source bill and is never trusted as a free-form owner assignment.
     */
    @Transactional
    @PreAuthorize("hasAuthority('sales_order:edit') and hasAuthority('sales_quote:view')")
    public OrderDetail createFromQuote(OrderSaveRequest req, UUID expectedQuoteOwner) {
        return createInternal(req, expectedQuoteOwner);
    }

    private OrderDetail createInternal(OrderSaveRequest req, UUID expectedQuoteOwner) {
        tx.bind();
        SalesOrder o = new SalesOrder();
        applyHeader(req, o);
        UUID sourceOwner = resolveSourceQuoteOwner(req.getSourceDocNo(), expectedQuoteOwner);
        o.setOwnerEmployeeId(accessPolicy.ownerForNewDocument(sourceOwner));
        o.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
        o.setStatus(STATUS_DRAFT);
        orderRepo.save(o);
        List<OrderItemDto> items = saveItems(o, req.getItems());
        applyTotals(o, items);
        return toDetail(o, items, List.of(), true);
    }

    private UUID resolveSourceQuoteOwner(String sourceDocNo, UUID expectedQuoteOwner) {
        if (sourceDocNo == null || sourceDocNo.isBlank()) {
            if (expectedQuoteOwner != null) {
                throw new ApiException(ErrorCode.CONFLICT, "来源报价与订货单不一致");
            }
            return null;
        }
        var source = quoteRepo.findByBillNo(sourceDocNo).filter(q -> !q.isDeleted()).orElse(null);
        if (source == null) {
            if (expectedQuoteOwner != null) {
                throw new ApiException(ErrorCode.CONFLICT, "来源报价不存在或已删除");
            }
            return null; // legacy/free-text source number
        }
        if (!accessPolicy.hasAuthority("sales_quote:view")) {
            throw new ApiException(ErrorCode.FORBIDDEN, "无权引用销售报价单");
        }
        accessPolicy.requireWritable(source.getMakerId(), "无权引用该销售报价单");
        if (expectedQuoteOwner != null && !java.util.Objects.equals(expectedQuoteOwner, source.getMakerId())) {
            throw new ApiException(ErrorCode.CONFLICT, "来源报价归属已变化，请刷新后重试");
        }
        return source.getMakerId();
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_order:edit')")
    public OrderDetail update(UUID id, OrderSaveRequest req) {
        tx.bind();
        SalesOrder o = requireWritableOrderForUpdate(id);
        if (o.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        }
        UUID sourceOwner = resolveSourceQuoteOwner(req.getSourceDocNo(), null);
        if (sourceOwner != null && !sourceOwner.equals(o.getOwnerEmployeeId())) {
            throw new ApiException(ErrorCode.CONFLICT, "来源报价与订货单归属不一致");
        }
        applyHeader(req, o);
        costItemRepo.deleteByOrderId(id);
        itemRepo.deleteByOrderId(id);
        itemRepo.flush();
        List<OrderItemDto> items = saveItems(o, req.getItems());
        applyTotals(o, items);
        return toDetail(o, items, List.of(), true);
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_order:edit')")
    public void delete(UUID id) {
        tx.bind();
        SalesOrder o = requireWritableOrderForUpdate(id);
        if (o.getStatus() == STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        }
        o.setDeleted(true);
        o.setDeletedAt(OffsetDateTime.now());
        orderRepo.save(o);
    }

    /** 审核：status 0→1。业务链：逐行库存检查 + 软预留（同事务，行锁防并发超卖）。 */
    @Transactional
    @PreAuthorize("hasAuthority('sales_order:edit')")
    public OrderDetail approve(UUID id) {
        tx.bind();
        SalesOrder o = requireWritableOrderForUpdate(id);
        if (o.getStatus() == null || o.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        List<SalesOrderItem> items = lockOrderItems(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        }
        reserveOnApprove(o, items);
        o.setStatus(STATUS_APPROVED);
        o.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        orderRepo.save(o);
        chainNotice.notifyOrderApproved(id); // 旁路通知：新订单待排产→调度（planner），提交后发送
        return detail(id);
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_order:edit')")
    public OrderDetail reverse(UUID id) {
        tx.bind();
        SalesOrder o = requireWritableOrderForUpdate(id);
        if (o.getStatus() == null || o.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        List<SalesOrderItem> items = lockOrderItems(id);
        Map<UUID, List<PlanOrderItemLink>> activeLinks = lockActivePlanLinks(items);
        for (SalesOrderItem item : items) {
            requireConsistentPlanningLedger(item, activeLinks.getOrDefault(item.getId(), List.of()));
        }
        for (SalesOrderItem it : items) {
            if (nz(it.getShippedQty()).signum() > 0) {
                throw new ApiException(ErrorCode.BUSINESS, "订单已有发货记录，不能整单红冲；请只取消未发货部分");
            }
            if (nz(it.getPlannedQty()).signum() > 0
                    || !activeLinks.getOrDefault(it.getId(), List.of()).isEmpty()) {
                throw new ApiException(ErrorCode.BUSINESS, "订单已排产，需生产部确认后走取消流程");
            }
            if (nz(it.getProducedQty()).signum() > 0) {
                throw new ApiException(ErrorCode.BUSINESS, "订单已有完工入库，需生产部确认后走取消流程");
            }
        }
        // 对称释放全部生效预留（内部兜底：已有消耗的预留拒绝释放）
        reservationService.releaseByOrderItems(items.stream().map(SalesOrderItem::getId).toList());
        for (SalesOrderItem it : items) {
            it.setReservedQty(BigDecimal.ZERO);
            it.setChainStatus((short) 0);
            itemRepo.save(it);
        }
        o.setStatus(STATUS_REVERSED);
        orderRepo.save(o);
        return detail(id);
    }

    /**
     * 审核时逐行软预留（V90）：
     * 全局可用量（账面−生效预留，基本单位）够 → 全量预留，行→可发货(7)；
     * 部分够 → 能留多少留多少，行→部分预留(1)，差额待排产；完全没货 → 待排产(2)。
     * 同一货品多行共享一个递减的可用量池，防止同单两行重复占用。
     */
    private void reserveOnApprove(SalesOrder o, List<SalesOrderItem> items) {
        reservationService.lockInventory(items.stream()
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
        Map<String, BigDecimal> pool = new HashMap<>();
        for (SalesOrderItem it : items) {
            BigDecimal rate = it.getUnitRate() != null && it.getUnitRate().signum() > 0
                    ? it.getUnitRate() : BigDecimal.ONE;
            BigDecimal needQty = outstanding(
                    it.getQty(), it.getShippedQty(), it.getReturnedQty(), it.getFlagQty())
                    .max(BigDecimal.ZERO);
            BigDecimal needBase = needQty.multiply(rate);
            String key = it.getGoodsId() + "|" + (it.getColorId() == null ? "" : it.getColorId());
            BigDecimal avail = pool.computeIfAbsent(key,
                    k -> reservationService.globalAvailableBase(it.getGoodsId(), it.getColorId()));
            BigDecimal take = needBase.min(avail.max(BigDecimal.ZERO));
            if (take.signum() > 0) {
                reservationService.reserve(it.getId(), it.getGoodsId(), it.getColorId(), take,
                        StockReservation.SOURCE_ORDER, "SALES_ORDER", o.getId());
                pool.put(key, avail.subtract(take));
            }
            it.setReservedQty(take.divide(rate, 4, RoundingMode.HALF_UP));
            it.setChainStatus(needQty.signum() == 0 ? CHAIN_SHIPPED
                    : take.compareTo(needBase) >= 0 ? CHAIN_SHIPPABLE
                    : take.signum() > 0 ? CHAIN_PARTIAL_RESERVED : CHAIN_PENDING_PLAN);
            itemRepo.save(it);
        }
    }

    /**
     * 订单改量（V100，SOP 异常段）：已审订单逐行改数量。
     * 增量重走库存检查+软预留（不足自动回调度待排产）；减量先释放预留再回退排产分摊；
     * 新数量 ≥ 已发净量（shipped−returned）；涉及已排产/已产行需生产部权限点确认。
     */
    @Transactional
    @PreAuthorize("hasAuthority('sales_order:edit')")
    public OrderDetail changeQty(UUID id, com.uten.imp.features.sales.order.dto.OrderChangeQtyRequest req) {
        tx.bind();
        SalesOrder o = requireWritableOrderForUpdate(id);
        if (o.getStatus() == null || o.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核订单可改量（草稿请直接编辑）");
        }
        if (o.isStopped()) {
            throw new ApiException(ErrorCode.BUSINESS, "已中止订单不可改量");
        }
        Map<UUID, SalesOrderItem> items = new HashMap<>();
        List<SalesOrderItem> lockedItems = lockOrderItems(id);
        for (SalesOrderItem it : lockedItems) items.put(it.getId(), it);
        Map<UUID, List<PlanOrderItemLink>> activeLinks = lockActivePlanLinks(lockedItems);
        for (SalesOrderItem item : lockedItems) {
            requireConsistentPlanningLedger(item, activeLinks.getOrDefault(item.getId(), List.of()));
        }

        // 第一遍：校验 + 是否涉及已排产/已产（触发生产确认权限点）
        java.util.Set<UUID> changedOrderItemIds = new java.util.HashSet<>();
        boolean touchesPlanned = false;
        for (var l : req.getItems()) {
            if (l.getOrderItemId() == null
                    || !changedOrderItemIds.add(l.getOrderItemId())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "改量订单行不可为空或重复");
            }
            SalesOrderItem it = items.get(l.getOrderItemId());
            if (it == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "订单行不属于本订单");
            if (l.getNewQty() == null || l.getNewQty().signum() <= 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "新数量必须大于 0");
            }
            BigDecimal floor = minimumOrderQty(
                    it.getShippedQty(), it.getReturnedQty(), it.getFlagQty());
            if (l.getNewQty().compareTo(floor) < 0) {
                throw new ApiException(ErrorCode.BUSINESS,
                        "新数量不能低于已履约净量（" + floor.stripTrailingZeros().toPlainString() + "）");
            }
            if (nz(it.getPlannedQty()).signum() > 0
                    || nz(it.getProducedQty()).signum() > 0
                    || !activeLinks.getOrDefault(it.getId(), List.of()).isEmpty()) {
                touchesPlanned = true;
            }
        }
        requireNoFrozenExecutionAllocationDecrease(req, items);
        if (touchesPlanned) requirePlannedChangePermission();

        // 第二遍：逐行应用
        for (var l : req.getItems()) {
            SalesOrderItem it = items.get(l.getOrderItemId());
            BigDecimal oldQty = nz(it.getQty());
            BigDecimal newQty = l.getNewQty();
            if (newQty.compareTo(oldQty) == 0) continue;
            BigDecimal delta = newQty.subtract(oldQty);
            BigDecimal reserved = nz(it.getReservedQty());
            BigDecimal planned = nz(it.getPlannedQty());
            boolean chained = it.getChainStatus() != null && it.getChainStatus() > 0;
            BigDecimal rate = it.getUnitRate() != null && it.getUnitRate().signum() > 0
                    ? it.getUnitRate() : BigDecimal.ONE;
            if (chained) {
                if (delta.signum() > 0) {
                    // 增量：能留多少留多少，剩余缺口自动回到调度待排产列表
                    BigDecimal take = delta.multiply(rate).min(
                            reservationService.globalAvailableBase(it.getGoodsId(), it.getColorId())
                                    .max(BigDecimal.ZERO));
                    if (take.signum() > 0) {
                        reservationService.reserve(it.getId(), it.getGoodsId(), it.getColorId(), take,
                                StockReservation.SOURCE_ORDER, "SALES_ORDER_CHANGE", o.getId());
                        reserved = reserved.add(take.divide(rate, 4, RoundingMode.HALF_UP));
                    }
                } else {
                    // 减量：先释放预留，再回退排产分摊（新→旧）
                    BigDecimal cut = delta.negate();
                    BigDecimal relRow = cut.min(reserved);
                    if (relRow.signum() > 0) {
                        reservationService.releaseForOrderItem(it.getId(), relRow.multiply(rate));
                        reserved = reserved.subtract(relRow);
                    }
                    BigDecimal rem = cut.subtract(relRow);
                    if (rem.signum() > 0) {
                        List<PlanOrderItemLink> links = new ArrayList<>(
                                activeLinks.getOrDefault(it.getId(), List.of()));
                        for (PlanOrderItemLink link : links) {
                            if (rem.signum() <= 0) break;
                            BigDecimal c = link.getAllocatedQty().subtract(link.getProducedQty()).min(rem);
                            if (c.signum() <= 0) continue;
                            if (planned.compareTo(c) < 0) {
                                throw new ApiException(ErrorCode.CONFLICT,
                                        "订单已排产累计小于联动回退量，禁止自动吞并错账");
                            }
                            if (c.compareTo(link.getAllocatedQty()) == 0) {
                                link.setDeleted(true); // 整笔分摊取消（留痕）
                                link.setDeletedAt(OffsetDateTime.now());
                            } else {
                                link.setAllocatedQty(link.getAllocatedQty().subtract(c));
                            }
                            linkRepo.save(link);
                            planned = planned.subtract(c);
                            rem = rem.subtract(c);
                        }
                        if (rem.compareTo(new BigDecimal("0.0001")) > 0) {
                            throw new ApiException(ErrorCode.BUSINESS, "减量超过可调整范围（已发/已产部分不可减）");
                        }
                    }
                }
            }
            BigDecimal open = outstanding(
                    newQty, it.getShippedQty(), it.getReturnedQty(), it.getFlagQty());
            BigDecimal unfinishedPlan = planned.subtract(nz(it.getProducedQty()))
                    .max(BigDecimal.ZERO);
            short chain = !chained ? 0
                    : open.signum() <= 0 ? CHAIN_SHIPPED
                    : reserved.compareTo(open) >= 0 ? CHAIN_SHIPPABLE
                    : unfinishedPlan.signum() > 0 ? CHAIN_PLANNED
                    : reserved.signum() > 0 ? CHAIN_PARTIAL_RESERVED : CHAIN_PENDING_PLAN;
            em.createNativeQuery("""
                    UPDATE sales_order_items
                    SET qty = :q,
                        amount_original = CASE WHEN price IS NULL THEN amount_original ELSE :q * price END,
                        amount_local    = CASE WHEN price IS NULL THEN amount_local    ELSE :q * price END,
                        reserved_qty = :r, planned_qty = :p, chain_status = :cs, updated_at = now()
                    WHERE id = :id
                    """).setParameter("q", newQty).setParameter("r", reserved)
                    .setParameter("p", planned).setParameter("cs", chain)
                    .setParameter("id", it.getId()).executeUpdate();
        }
        recalcTotalsAndClosed(id);
        return detail(id);
    }

    /**
     * 订单取消（V100，SOP 异常段）：已审未发货订单整单取消。
     * 释放全部预留（含已产成品回通用库存）+ 断开排产联动（留痕）+ 行状态 -1 + 中止位置位。
     * 已发货订单拒绝（用改量取消未发部分）；涉及已排产/已产需生产部权限点。
     */
    @Transactional
    @PreAuthorize("hasAuthority('sales_order:edit')")
    public OrderDetail cancel(UUID id) {
        tx.bind();
        SalesOrder o = requireWritableOrderForUpdate(id);
        if (o.getStatus() == null || o.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核订单可取消（草稿直接删除）");
        }
        if (o.isStopped()) {
            throw new ApiException(ErrorCode.BUSINESS, "订单已中止");
        }
        List<SalesOrderItem> items = lockOrderItems(id);
        Map<UUID, List<PlanOrderItemLink>> activeLinks = lockActivePlanLinks(items);
        for (SalesOrderItem item : items) {
            requireConsistentPlanningLedger(item, activeLinks.getOrDefault(item.getId(), List.of()));
        }
        boolean anyShipped = items.stream().anyMatch(i -> nz(i.getShippedQty()).signum() > 0);
        if (anyShipped) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "已有发货记录，不能整单取消；请用改量把数量改为已发量以取消未发部分");
        }
        boolean touchesPlanned = items.stream()
                .anyMatch(i -> cancellationRequiresProductionClearance(
                        i.getPlannedQty(),
                        i.getProducedQty(),
                        !activeLinks.getOrDefault(i.getId(), List.of()).isEmpty()));
        if (touchesPlanned) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "订单已有排产、在产或完工关联；请先取消/红冲未开工子计划，"
                            + "已领料先退料、已完工先解除订单预留，再取消订单");
        }

        // 释放全部预留（已产成品的预留一并释放=回通用库存）
        reservationService.releaseByOrderItems(items.stream().map(SalesOrderItem::getId).toList());
        for (SalesOrderItem it : items) {
            for (PlanOrderItemLink link : activeLinks.getOrDefault(it.getId(), List.of())) {
                link.setDeleted(true);
                link.setDeletedAt(OffsetDateTime.now());
                linkRepo.save(link);
            }
            it.setReservedQty(BigDecimal.ZERO);
            it.setPlannedQty(BigDecimal.ZERO);
            it.setChainStatus(CHAIN_CANCELED);
            itemRepo.save(it);
        }
        o.setStopped(true);
        orderRepo.save(o);
        chainNotice.notifyOrderCanceled(id); // 旁路通知：取消确认→销售 + 无需排产→调度，提交后发送
        return detail(id);
    }

    /**
     * V157 segment ownership is immutable.  A quantity decrease must not
     * shrink or soft-delete a plan link after a V1 package was confirmed.
     */
    private void requireNoFrozenExecutionAllocationDecrease(
            com.uten.imp.features.sales.order.dto.OrderChangeQtyRequest request,
            Map<UUID, SalesOrderItem> items) {
        List<UUID> decreasingOrderItemIds = request.getItems().stream()
                .filter(line -> {
                    SalesOrderItem item = items.get(line.getOrderItemId());
                    return item != null
                            && line.getNewQty() != null
                            && line.getNewQty().compareTo(
                                    nz(item.getQty())) < 0;
                })
                .map(line -> line.getOrderItemId())
                .distinct()
                .sorted()
                .toList();
        if (decreasingOrderItemIds.isEmpty()) {
            return;
        }
        Number frozen = (Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM execution_segment_sales_allocations allocation
                        JOIN production_execution_segments segment
                          ON segment.id = allocation.execution_segment_id
                         AND segment.is_deleted = FALSE
                        JOIN production_planning_packages package
                          ON package.id = segment.package_id
                         AND package.is_deleted = FALSE
                        WHERE allocation.sales_order_item_id IN (:ids)
                          AND package.status = 'CONFIRMED'
                          AND package.execution_model_version = 1
                          AND segment.status NOT IN ('CANCELLED', 'REVERSED')
                        """)
                .setParameter("ids", decreasingOrderItemIds)
                .getSingleResult();
        if (frozen.longValue() > 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "订单数量已被已确认执行计划包冻结；请先取消或红冲对应执行计划包后再减量");
        }
    }

    /** 生产确认权限点（V100）：改量/取消涉及已排产或已产行时必须。 */
    private void requirePlannedChangePermission() {
        var u = currentUser.get()
                .orElseThrow(() -> new ApiException(ErrorCode.FORBIDDEN, "未登录"));
        boolean ok = u.isSuperAdmin() || u.getAuthorities().stream()
                .anyMatch(a -> "sales_order:change_planned".equals(a.getAuthority()));
        if (!ok) {
            throw new ApiException(ErrorCode.FORBIDDEN, "涉及已排产/生产中的订单行，需生产部人员确认后操作");
        }
    }


    /**
     * 权限不能替代计划红冲、物料退回和成品预留解除。
     */
    static boolean cancellationRequiresProductionClearance(
            BigDecimal planned, BigDecimal produced, boolean hasActivePlanLink) {
        return nz(planned).signum() > 0
                || nz(produced).signum() > 0 || hasActivePlanLink;
    }
    /** 主表合计 + 结案重算（改量后；与出货 Service 结案口径一致）。 */
    private void recalcTotalsAndClosed(UUID orderId) {
        em.createNativeQuery("""
                UPDATE sales_orders o SET
                    total_original = (SELECT COALESCE(SUM(i.amount_original),0) FROM sales_order_items i
                        WHERE i.order_id = o.id AND COALESCE(i.is_deleted,false) = false),
                    total_local = (SELECT COALESCE(SUM(i.amount_local),0) FROM sales_order_items i
                        WHERE i.order_id = o.id AND COALESCE(i.is_deleted,false) = false),
                    is_closed = (SELECT COALESCE(bool_and(
                        COALESCE(i.qty,0) - COALESCE(i.shipped_qty,0)
                        + COALESCE(i.returned_qty,0) - COALESCE(i.flag_qty,0) <= 0), true)
                        FROM sales_order_items i
                        WHERE i.order_id = o.id AND COALESCE(i.is_deleted,false) = false),
                    updated_at = now()
                WHERE o.id = :id
                """).setParameter("id", orderId).executeUpdate();
    }

    private static BigDecimal nz(BigDecimal v) {
        return v == null ? BigDecimal.ZERO : v;
    }


    /** 订单数量不可低于已发净量再加业务核销量。 */
    static BigDecimal minimumOrderQty(
            BigDecimal shipped, BigDecimal returned, BigDecimal flagged) {
        return nz(shipped).subtract(nz(returned)).add(nz(flagged)).max(BigDecimal.ZERO);
    }

    /** 统一未交口径：订单量 - 已发 + 已退 - 核销。 */
    static BigDecimal outstanding(
            BigDecimal qty, BigDecimal shipped, BigDecimal returned, BigDecimal flagged) {
        return nz(qty).subtract(nz(shipped)).add(nz(returned)).subtract(nz(flagged));
    }
    /**
     * 中止位切换（业务链收口）：已审订单的中止=取消（释放预留/断排产联动，V100）；
     * 恢复中止=重跑库存检查+软预留（排产联动已断，缺口回到调度待排产）。草稿单仅置位。
     */
    @Transactional
    @PreAuthorize("hasAuthority('sales_order:edit')")
    public OrderDetail toggleStopped(UUID id, boolean stopped) {
        tx.bind();
        SalesOrder o = requireWritableOrderForUpdate(id);
        if (o.getStatus() != null && o.getStatus() == STATUS_APPROVED) {
            if (stopped && !o.isStopped()) {
                return cancel(id);
            }
            if (!stopped && o.isStopped()) {
                List<SalesOrderItem> items = lockOrderItems(id);
                reserveOnApprove(o, items); // 重预留（行状态 7/1/2 自动重算）
                o.setStopped(false);
                orderRepo.save(o);
                return detail(id);
            }
        }
        o.setStopped(stopped);
        orderRepo.save(o);
        return detail(id);
    }

    private void applyHeader(OrderSaveRequest req, SalesOrder o) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (o.getBillNo() == null || o.getBillNo().isBlank()) {
            o.setBillNo(docNumberService.nextNumber(DocNumberPrefix.SALES_ORDER));
        }
        o.setBillDate(req.getBillDate());
        o.setClientId(req.getClientId());
        o.setCurrencyId(req.getCurrencyId());
        o.setExchangeRate(req.getExchangeRate());
        o.setTaxRate(req.getTaxRate());
        o.setPaymentStyleId(req.getPaymentStyleId());
        o.setSellerId(req.getSellerId());
        o.setDeliverDate(req.getDeliverDate());
        o.setContractNo(req.getContractNo());
        o.setLinkPhone(req.getLinkPhone());
        o.setSignAddr(req.getSignAddr());
        o.setShipAddr(req.getShipAddr());
        o.setDeposit(req.getDeposit());
        o.setRemark(req.getRemark());
        o.setSourceDocNo(req.getSourceDocNo());
    }

    private List<OrderItemDto> saveItems(SalesOrder o, List<OrderItemLine> lines) {
        List<OrderItemDto> out = new ArrayList<>(lines.size());
        int auto = 1;
        for (OrderItemLine l : lines) {
            SalesOrderItem it = new SalesOrderItem();
            it.setOrderId(o.getId());
            it.setBillNo(o.getBillNo());
            it.setBillDate(o.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            it.setGoodsId(l.getGoodsId());
            it.setColorId(l.getColorId());
            it.setUnitId(l.getUnitId());
            it.setUnitRate(l.getUnitRate());
            it.setQty(l.getQty());
            it.setPrice(l.getPrice());
            it.setAmountOriginal(l.getAmountOriginal());
            it.setAmountLocal(l.getAmountLocal() != null ? l.getAmountLocal() : l.getAmountOriginal());
            it.setDiscount(l.getDiscount());
            it.setTaxAmount(l.getTaxAmount());
            it.setWeight(l.getWeight());
            it.setClientNo(l.getClientNo());
            it.setClientModel(l.getClientModel());
            it.setDeliverDate(l.getDeliverDate());
            it.setSourceDocNo(l.getSourceDocNo());
            it.setMachiningPrice(l.getMachiningPrice());
            it.setCircumference(l.getCircumference());
            it.setInboundQty(l.getInboundQty());
            it.setInNo(l.getInNo());
            it.setOutNo(l.getOutNo());
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            out.add(toItemDto(it));
            auto++;
        }
        return out;
    }

    private void applyTotals(SalesOrder o, List<OrderItemDto> items) {
        BigDecimal local = items.stream()
                .map(i -> i.getAmountLocal() == null ? BigDecimal.ZERO : i.getAmountLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = items.stream()
                .map(i -> i.getAmountOriginal() == null ? BigDecimal.ZERO : i.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        o.setTotalLocal(local);
        o.setTotalOriginal(original);
        orderRepo.save(o);
    }

    private OrderListItem toList(SalesOrder o, boolean writable) {
        // 延期预警：已审未结案 + 距交货日 ≤3 天（含逾期）；草稿/红冲/结案不预警
        boolean delayWarning = o.getDeliverDate() != null
                && o.getStatus() != null && o.getStatus() == STATUS_APPROVED
                && !o.isClosed() && !o.isStopped()
                && !o.getDeliverDate().isAfter(BusinessTime.today().plusDays(3));
        boolean mask = !priceMasker.canView(); // 价格脱敏（SOP §三8）：无权限置 null + priceMasked 标记
        return new OrderListItem(o.getId(), o.getBillNo(), o.getBillDate(), o.getClientId(),
                o.getCurrencyId(), mask ? null : o.getTotalLocal(), o.getStatus(), o.isClosed(), o.isStopped(),
                o.getLegacyId(), o.getDeliverDate(), delayWarning, mask, writable);
    }

    private OrderItemDto toItemDto(SalesOrderItem it) {
        return new OrderItemDto(it.getId(), it.getLineNo(), it.getGoodsId(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                it.getAmountLocal(), it.getShippedQty(), it.getReturnedQty(), it.getFlagQty(),
                it.getDiscount(), it.getTaxAmount(), it.getWeight(), it.getClientNo(), it.getClientModel(),
                it.getDeliverDate(), it.getSourceDocNo(), it.getMachiningPrice(), it.getCircumference(),
                it.getInboundQty(), it.getInNo(), it.getOutNo(), it.getRemark(),
                it.getReservedQty(), it.getPlannedQty(), it.getProducedQty(), it.getChainStatus(), null);
    }

    private OrderCostItemDto toCostDto(SalesOrderCostItem c) {
        return new OrderCostItemDto(c.getId(), c.getOrderItemId(), c.getParentId(), c.getLevel(),
                c.getClassCode(), c.getGoodsId(), c.getColorId(), c.getAltGoodsId(), c.getAltColorId(),
                c.getUnitId(), c.getQty(), c.getOrderQty(), c.getReceivedQty(), c.getDrawQty(),
                c.getPurgeQty(), c.getOtherDrawQty(), c.getSupplierId(), c.getLStatus(),
                c.getBillDate(), c.getSourceDocNo(), c.getRemark());
    }

    private OrderDetail toDetail(SalesOrder o, List<OrderItemDto> items,
                                 List<OrderCostItemDto> costItems, boolean writable) {
        boolean mask = !priceMasker.canView(); // 价格脱敏（SOP §三8）：主表金额族+明细价格族置 null
        if (mask) {
            items.forEach(this::maskItemPrices);
        }
        return new OrderDetail(o.getId(), o.getLegacyId(), o.getBillNo(), o.getBillDate(),
                o.getClientId(), o.getCurrencyId(), o.getExchangeRate(), o.getTaxRate(), o.getPaymentStyleId(),
                o.getSellerId(), o.getMakerId(), o.getApproverId(), o.getDeliverDate(), o.getContractNo(),
                o.getLinkPhone(), o.getSignAddr(), o.getShipAddr(),
                mask ? null : o.getDeposit(), o.getRemark(),
                mask ? null : o.getTotalOriginal(), mask ? null : o.getTotalLocal(),
                o.getStatus(), o.isClosed(), o.isStopped(),
                o.getSourceDocNo(), null, mask, items, costItems,
                nameResolver.nameOf(o.getMakerId()), o.getCreatedAt(), writable);
    }

    /** 价格族字段置 null（数量族/链路量保留——生产/仓库要看出欠与进度，不看钱）。 */
    private void maskItemPrices(OrderItemDto it) {
        it.setPrice(null);
        it.setAmountOriginal(null);
        it.setAmountLocal(null);
        it.setDiscount(null);
        it.setTaxAmount(null);
        it.setMachiningPrice(null);
        it.setQuotePrice(null);
    }

    private SalesOrder requireOrder(UUID id) {
        return orderRepo.findById(id).filter(o -> !o.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "销售订货单不存在"));
    }

    private SalesOrder requireReadableOrder(UUID id) {
        SalesOrder order = requireOrder(id);
        accessPolicy.requireReadable(order.getOwnerEmployeeId(), "销售订货单不存在");
        return order;
    }

    private SalesOrder requireWritableOrder(UUID id) {
        SalesOrder order = requireOrder(id);
        accessPolicy.requireWritable(order.getOwnerEmployeeId(), "只能操作本人负责的销售订货单");
        return order;
    }

    /**
     * 先做归属校验，再以数据库当前值重新加写锁并 refresh。
     * 避免普通 find 得到的受管实体在等待并发事务后仍携带旧 status/isStopped。
     */
    private SalesOrder requireWritableOrderForUpdate(UUID id) {
        SalesOrder visible = requireWritableOrder(id);
        SalesOrder locked = em.find(
                SalesOrder.class, visible.getId(),
                jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (locked == null) {
            throw new ApiException(ErrorCode.NOT_FOUND, "销售订货单不存在");
        }
        em.refresh(locked, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (locked.isDeleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "销售订货单不存在");
        }
        accessPolicy.requireWritable(locked.getOwnerEmployeeId(), "只能操作本人负责的销售订货单");
        return locked;
    }

    /**
     * 锁后核对订单累计与当前有效联动。禁止用 max(0) 掩盖历史错账。
     */
    private static void requireConsistentPlanningLedger(
            SalesOrderItem item, List<PlanOrderItemLink> links) {
        BigDecimal reserved = item.getReservedQty();
        BigDecimal planned = item.getPlannedQty();
        BigDecimal produced = item.getProducedQty();
        if (reserved == null || reserved.signum() < 0
                || planned == null || planned.signum() < 0
                || produced == null || produced.signum() < 0
                || produced.compareTo(planned) > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "订单预留/排产/完工累计异常，禁止改量或取消");
        }
        BigDecimal linkedAllocated = links.stream()
                .map(PlanOrderItemLink::getAllocatedQty)
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        if (planned.compareTo(linkedAllocated) != 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "订单已排产累计与有效分摊不一致，禁止自动修正");
        }
    }

    /** 订单头锁定后，按 UUID 稳定顺序锁定并刷新当前有效订单行。 */
    private List<SalesOrderItem> lockOrderItems(UUID orderId) {
        List<UUID> ids = com.uten.imp.common.util.NativeQueryResults.typedRows(
                em.createNativeQuery("""
                        SELECT id
                        FROM sales_order_items
                        WHERE order_id = :orderId
                          AND COALESCE(is_deleted, false) = false
                        ORDER BY id
                        FOR UPDATE
                        """).setParameter("orderId", orderId), UUID.class);
        List<SalesOrderItem> items = new ArrayList<>(ids.size());
        for (UUID itemId : ids) {
            SalesOrderItem item = em.find(
                    SalesOrderItem.class, itemId,
                    jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
            if (item == null) {
                throw new ApiException(ErrorCode.CONFLICT, "销售订货单明细已被并发删除");
            }
            em.refresh(item, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
            if (!orderId.equals(item.getOrderId())) {
                throw new ApiException(ErrorCode.CONFLICT, "销售订货单明细归属已变化");
            }
            items.add(item);
        }
        items.sort(java.util.Comparator
                .comparing(SalesOrderItem::getLineNo,
                        java.util.Comparator.nullsLast(java.util.Comparator.naturalOrder()))
                .thenComparing(SalesOrderItem::getId));
        return items;
    }

    /** 订单头/行之后锁有效排产联动，后续减量或取消只写 refresh 后的当前实体。 */
    private Map<UUID, List<PlanOrderItemLink>> lockActivePlanLinks(
            List<SalesOrderItem> items) {
        if (items.isEmpty()) return Map.of();
        List<UUID> orderItemIds = items.stream()
                .map(SalesOrderItem::getId).sorted().toList();
        List<UUID> linkIds = com.uten.imp.common.util.NativeQueryResults.typedRows(
                em.createNativeQuery("""
                        SELECT id
                        FROM plan_order_item_links
                        WHERE order_item_id IN (:orderItemIds)
                          AND COALESCE(is_deleted, false) = false
                        ORDER BY id
                        FOR UPDATE
                        """).setParameter("orderItemIds", orderItemIds), UUID.class);
        Map<UUID, List<PlanOrderItemLink>> byOrderItem = new HashMap<>();
        java.util.Set<UUID> allowed = new java.util.HashSet<>(orderItemIds);
        for (UUID linkId : linkIds) {
            PlanOrderItemLink link = em.find(
                    PlanOrderItemLink.class, linkId,
                    jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
            if (link == null) {
                throw new ApiException(ErrorCode.CONFLICT, "排产分摊已被并发删除");
            }
            em.refresh(link, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
            BigDecimal allocated = link.getAllocatedQty();
            BigDecimal produced = link.getProducedQty();
            if (link.isDeleted()
                    || !allowed.contains(link.getOrderItemId())
                    || allocated == null || allocated.signum() < 0
                    || produced == null || produced.signum() < 0
                    || produced.compareTo(allocated) > 0
                    || (link.getCappedQty() != null && link.getCappedQty().signum() < 0)) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "排产分摊状态或数量异常，禁止改量/取消");
            }
            byOrderItem.computeIfAbsent(link.getOrderItemId(), ignored -> new ArrayList<>())
                    .add(link);
        }
        for (List<PlanOrderItemLink> links : byOrderItem.values()) {
            links.sort(java.util.Comparator
                    .comparing(PlanOrderItemLink::getCreatedAt,
                            java.util.Comparator.nullsFirst(java.util.Comparator.naturalOrder()))
                    .thenComparing(PlanOrderItemLink::getId)
                    .reversed());
        }
        return byOrderItem;
    }

    private static LocalDate localDate(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate date) return date;
        return ((java.sql.Date) value).toLocalDate();
    }

    private static OffsetDateTime offsetDateTime(Object value) {
        if (value == null) return null;
        if (value instanceof OffsetDateTime dateTime) return dateTime;
        if (value instanceof java.time.ZonedDateTime dateTime) {
            return dateTime.toOffsetDateTime();
        }
        if (value instanceof java.time.Instant instant) {
            return instant.atOffset(java.time.ZoneOffset.UTC);
        }
        if (value instanceof java.sql.Timestamp timestamp) {
            return timestamp.toInstant().atOffset(java.time.ZoneOffset.UTC);
        }
        throw new IllegalArgumentException("Unsupported timestamp type: " + value.getClass());
    }
}
