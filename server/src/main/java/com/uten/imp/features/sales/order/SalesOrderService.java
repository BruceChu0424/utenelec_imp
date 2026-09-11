package com.uten.imp.features.sales.order;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.saleschain.SalesChainStatus;
import com.uten.imp.common.saleschain.SalesOrderChainSql;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.SalesGoodsSnapshot;
import com.uten.imp.features.sales.SalesMasterReferenceValidator;
import com.uten.imp.features.sales.order.dto.OrderCostItemDto;
import com.uten.imp.features.sales.order.dto.OrderDetail;
import com.uten.imp.features.sales.order.dto.OrderProgressRow;
import com.uten.imp.features.sales.order.dto.OrderItemDto;
import com.uten.imp.features.sales.order.dto.OrderItemLine;
import com.uten.imp.features.sales.order.dto.OrderPriorityRequest;
import com.uten.imp.features.sales.order.dto.OrderYieldRequest;
import com.uten.imp.features.sales.order.dto.ScarceStockReservationView;
import com.uten.imp.features.sales.order.dto.OrderListItem;
import com.uten.imp.features.sales.order.dto.OrderQueryFilter;
import com.uten.imp.features.sales.order.dto.OrderSaveRequest;
import com.uten.imp.features.sales.quote.SalesQuoteItem;
import com.uten.imp.features.production.plan.PlanOrderItemLink;
import com.uten.imp.features.production.plan.PlanOrderItemLinkRepository;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.StockReservation;
import com.uten.imp.features.stock.StockReservationService;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 销售订货单服务：CRUD（主+明细）+ 审核状态机。
 *
 * <p>审核（0→1）：业务链库存检查 + 软预留（docs/07-业务链路/02）——逐行查全局可用量，
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
    /** 并发认领目标类型（与 TaskClaimPolicy 登记的 SALES_ORDER_APPROVE 对齐）。 */
    private static final String TASK_TYPE_APPROVE = "SALES_ORDER_APPROVE";

    /** 链路行状态（chain_status）：派生口径统一在 {@link SalesOrderChainSql}/{@link SalesChainStatus}；本类只直写取消态。 */
    private static final short CHAIN_CANCELED = -1;         // 已取消

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "total", "totalOriginal");

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
    private final SalesOrderPlanProgressQuery planProgressQuery;
    private final com.uten.imp.features.notice.ChainNoticeService chainNotice;
    private final AuditService auditService;
    private final SalesMasterReferenceValidator referenceValidator;
    private final TaskClaimService taskClaim;
    private final SalesOrderRevisionService revisions;
    private final com.uten.imp.features.sales.SalesMutationFootprintService mutationFootprint;

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
            if (f.sellerId() != null) ps.add(cb.equal(root.get("sellerId"), f.sellerId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.closed() != null) ps.add(cb.equal(root.get("closed"), f.closed()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            // 链路状态组筛选（工作台统计卡钻取）：存在任一明细行命中即返回
            if (f.chain() != null && !f.chain().isEmpty()) {
                jakarta.persistence.criteria.Subquery<UUID> sub = q.subquery(UUID.class);
                Root<SalesOrderItem> i = sub.from(SalesOrderItem.class);
                sub.select(i.get("orderId")).where(
                        cb.isFalse(i.get("deleted")),
                        i.get("chainStatus").in(f.chain()));
                ps.add(root.get("id").in(sub));
            }
            // V545 数量派生大类（待生产/生产中）：与 stats() 同口径，存在任一命中行即返回。
            if (f.chainGroup() != null && !f.chainGroup().isBlank()) {
                jakarta.persistence.criteria.Subquery<UUID> sub = q.subquery(UUID.class);
                Root<SalesOrderItem> i = sub.from(SalesOrderItem.class);
                sub.select(i.get("orderId")).where(
                        cb.isFalse(i.get("deleted")),
                        chainGroupPredicate(cb, i, f.chainGroup()));
                ps.add(root.get("id").in(sub));
            }
            if (shippableFirst) {
                // 可发货置顶：Σ行预留 > 0 的单排前（CASE 1/0 DESC），次按交货日升序、开单日期倒序
                jakarta.persistence.criteria.Subquery<BigDecimal> sum = q.subquery(BigDecimal.class);
                Root<SalesOrderItem> i2 = sum.from(SalesOrderItem.class);
                sum.select(cb.coalesce(cb.sum(i2.get("reservedQty")), BigDecimal.ZERO))
                        .where(
                                cb.equal(i2.get("orderId"), root.get("id")),
                                cb.isFalse(i2.get("deleted")));
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
        boolean canEdit = hasObjectActionAuthority();
        return new PageResponse<>(p.map(o -> toList(o,
                        nameResolver.nameOf(o.getSellerId()),
                        canEdit && accessPolicy.canWrite(o.getOwnerEmployeeId(), readScope))).getContent(),
                p);
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
        boolean canCreateShipment = accessPolicy.hasAuthority("sales_shipment:create");
        String sql = """
                SELECT i.id, i.order_id, o.bill_no, o.client_id, i.deliver_date, i.goods_id, i.color_id,
                       i.unit_id, i.unit_rate, i.qty, i.shipped_qty,
                       GREATEST(COALESCE(i.reserved_qty,0)
                           - COALESCE(draft.allocated_qty,0), 0) AS available_to_draft,
                       i.price,
                       o.owner_employee_id
                FROM sales_order_items i
                JOIN sales_orders o ON o.id = i.order_id
                LEFT JOIN (
                    SELECT si.order_item_id, SUM(si.qty) AS allocated_qty
                    FROM sales_shipment_items si
                    JOIN sales_shipments s ON s.id = si.shipment_id
                    WHERE COALESCE(si.is_deleted,false) = false
                      AND COALESCE(s.is_deleted,false) = false
                      AND s.status = 0
                      AND COALESCE(s.rejected,false) = false
                    GROUP BY si.order_item_id
                ) draft ON draft.order_item_id = i.id
                WHERE o.status = 1 AND o.is_closed = false AND o.is_stopped = false
                  AND o.finance_confirmed = true
                  AND COALESCE(o.finance_rejected, false) = false
                  AND COALESCE(o.is_deleted,false) = false AND COALESCE(i.is_deleted,false) = false
                  AND GREATEST(COALESCE(i.reserved_qty,0)
                      - COALESCE(draft.allocated_qty,0), 0) > 0
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
                    r[4] == null ? null : localDate(r[4]),
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
        // V545：待生产/生产中按数量派生（SalesOrderChainSql），部分排产的单同时落两卡。
        String sql = """
                SELECT
                  COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM sales_order_items i
                      WHERE i.order_id = o.id AND i.is_deleted = false AND %s)),
                  COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM sales_order_items i
                      WHERE i.order_id = o.id AND i.is_deleted = false AND %s)),
                  COUNT(*) FILTER (WHERE o.finance_confirmed = true
                      AND EXISTS (SELECT 1 FROM sales_order_items i
                      WHERE i.order_id = o.id AND i.is_deleted = false
                        AND COALESCE(i.reserved_qty,0) > 0)),
                  COUNT(*) FILTER (WHERE o.is_closed
                        AND o.bill_date >= CAST(:monthStart AS date))
                FROM sales_orders o
                WHERE o.is_deleted = false AND o.status = 1
                """.formatted(SalesOrderChainSql.pendingPlanLinePredicate("i"),
                        SalesOrderChainSql.inProductionLinePredicate("i"))
                + " AND " + ownerScope.predicate();
        var q = em.createNativeQuery(sql);
        ownerScope.bind(q);
        q.setParameter("monthStart", BusinessTime.today().withDayOfMonth(1));
        Object[] r = (Object[]) q.getSingleResult();
        return new com.uten.imp.features.sales.order.dto.OrderStats(
                ((Number) r[0]).longValue(), ((Number) r[1]).longValue(),
                ((Number) r[2]).longValue(), ((Number) r[3]).longValue());
    }

    /** 订单进度看板（订单进度查询卡）：已审订单按明细聚合 订货/已排/已产/已发/可发 + 派生生产进度与链路阶段。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_order:view')")
    public PageResponse<OrderProgressRow> progress(
            int page, int size, String stage, String keyword, LocalDate dateFrom, LocalDate dateTo) {
        int safeSize = Math.max(1, Math.min(size, 100));
        int safePage = Math.max(1, page);
        String normalizedStage = normalizeProgressStage(stage);
        String normalizedKeyword = keyword == null ? "" : keyword.strip().toLowerCase();
        var ownerScope = accessPolicy.nativeReadScope("o.owner_employee_id", "salesOwners");
        // 阶段筛选下沉到数据库：COUNT 与列表同一谓词，分页 total 即当前阶段真实总数。
        // 日期（bill_date 为 ISO 文本，字典序与日期序一致）与关键字（单号/客户）
        // 为可选过滤，null/'' 判空放行。
        String stageFilter = progressStagePredicate()
                + """
                  AND (CAST(:date_from AS date) IS NULL OR t.bill_date >= CAST(:date_from AS text))
                  AND (CAST(:date_to AS date) IS NULL OR t.bill_date <= CAST(:date_to AS text))
                  AND (CAST(:keyword AS text) IS NULL OR :keyword = ''
                       OR LOWER(COALESCE(t.bill_no, '')) LIKE :keyword_pattern
                       OR LOWER(COALESCE(t.name, '')) LIKE :keyword_pattern)
                """;
        var cq = em.createNativeQuery(
                "SELECT COUNT(*) FROM (" + progressGroupedSql(ownerScope) + ") t WHERE " + stageFilter);
        ownerScope.bind(cq);
        cq.setParameter("stage", normalizedStage);
        cq.setParameter("keyword", normalizedKeyword);
        cq.setParameter("keyword_pattern", "%" + normalizedKeyword + "%");
        cq.setParameter("date_from", dateFrom);
        cq.setParameter("date_to", dateTo);
        long total = ((Number) cq.getSingleResult()).longValue();
        String rowsSql = "SELECT t.* FROM (" + progressGroupedSql(ownerScope) + ") t WHERE " + stageFilter
                + " ORDER BY t.bill_date DESC NULLS LAST, t.bill_no DESC";
        var rq = em.createNativeQuery(rowsSql);
        ownerScope.bind(rq);
        rq.setParameter("stage", normalizedStage);
        rq.setParameter("keyword", normalizedKeyword);
        rq.setParameter("keyword_pattern", "%" + normalizedKeyword + "%");
        rq.setParameter("date_from", dateFrom);
        rq.setParameter("date_to", dateTo);
        rq.setFirstResult((safePage - 1) * safeSize).setMaxResults(safeSize);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = rq.getResultList();
        List<OrderProgressRow> items = rows.stream().map(row -> {
            double orderQty = pgNum(row, 5);
            double producedQty = pgNum(row, 6);
            double shippedQty = pgNum(row, 7);
            double reservedQty = pgNum(row, 8);
            double plannedQty = pgNum(row, 9);
            double unplannedQty = pgNum(row, 17);
            boolean financeConfirmed = Boolean.TRUE.equals(row[10]);
            boolean financeRejected = Boolean.TRUE.equals(row[11]);
            boolean stopped = Boolean.TRUE.equals(row[15]);
            boolean closed = Boolean.TRUE.equals(row[16]);
            double pct = orderQty > 0 ? Math.min(1.0, producedQty / orderQty) : 0.0;
            return new OrderProgressRow(
                    pgStr(row, 0), pgStr(row, 1), pgStr(row, 2), pgStr(row, 3), pgStr(row, 4),
                    orderQty, producedQty, shippedQty, reservedQty, plannedQty, unplannedQty,
                    pct, progressStageOf(
                            orderQty, producedQty, shippedQty,
                            reservedQty, plannedQty, unplannedQty,
                            financeRejected, stopped, closed),
                    financeConfirmed,
                    financeRejected,
                    pgStr(row, 12),
                    pgStr(row, 13),
                    offsetDateTime(row[14]),
                    stopped,
                    closed);
        }).toList();
        int totalPages = (int) Math.ceil((double) total / safeSize);
        return new PageResponse<>(items, safePage, safeSize, total, totalPages);
    }

    /**
     * 客户 → 最近一次销售订货条款（新建单「学习预填」）：选客户后自动带出上次的
     * 结账方式/发运策略/币种，前端只回填空字段并黄标提醒核对。无历史订单返回 null。
     * 授权在 Controller（sales_order:view），与采购 /last-terms 同口径。
     */
    @Transactional(readOnly = true)
    public LastTermsForClient lastTermsForClient(UUID clientId) {
        var rows = orderRepo.findLastTermsByClientId(clientId, PageRequest.of(0, 1));
        if (rows.isEmpty()) {
            return null;
        }
        Object[] row = rows.get(0);
        return new LastTermsForClient((UUID) row[0], (String) row[1], (UUID) row[2]);
    }

    /** 客户最近一次订货条款（结账方式/发运策略/币种，均可空——历史单未必全填）。 */
    public record LastTermsForClient(UUID settlementMethodId, String shipmentPolicy, UUID currencyId) {}

    /** 订单进度各阶段计数（顶部筛选卡口径）：全部已审订单按阶段聚合，不受分页/当前阶段筛选影响。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_order:view')")
    public Map<String, Long> progressStageCounts() {
        var ownerScope = accessPolicy.nativeReadScope("o.owner_employee_id", "salesOwners");
        var q = em.createNativeQuery(
                "SELECT (" + progressStageExpr() + "), COUNT(*) FROM ("
                        + progressGroupedSql(ownerScope) + ") t GROUP BY 1");
        ownerScope.bind(q);
        Map<String, Long> counts = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(q)) {
            counts.put((String) row[0], ((Number) row[1]).longValue());
        }
        return counts;
    }

    /**
     * 列表大类筛选的 Criteria 镜像（V545）：pending = 剩余未排量 > 0；production = 未完工计划量 > 0
     * 或行已在 5/6。公式与 {@link SalesOrderChainSql#pendingPlanLinePredicate} /
     * {@link SalesOrderChainSql#inProductionLinePredicate} 逐项对应（Criteria 无法内嵌原生片段），
     * 由 FullChainEndToEndTest 用同一单据校验 list 与 stats 计数一致。
     */
    static Predicate chainGroupPredicate(CriteriaBuilder cb, Root<SalesOrderItem> i, String group) {
        jakarta.persistence.criteria.Expression<BigDecimal> zero = cb.literal(BigDecimal.ZERO);
        jakarta.persistence.criteria.Expression<BigDecimal> outstanding = cb.diff(
                cb.sum(cb.diff(cb.coalesce(i.<BigDecimal>get("qty"), zero),
                                cb.coalesce(i.<BigDecimal>get("shippedQty"), zero)),
                        cb.coalesce(i.<BigDecimal>get("returnedQty"), zero)),
                cb.coalesce(i.<BigDecimal>get("flagQty"), zero));
        jakarta.persistence.criteria.Expression<BigDecimal> unfinished = cb.function(
                "greatest", BigDecimal.class,
                cb.diff(cb.coalesce(i.<BigDecimal>get("plannedQty"), zero),
                        cb.coalesce(i.<BigDecimal>get("producedQty"), zero)),
                zero);
        Predicate activeChain = cb.between(i.<Short>get("chainStatus"), (short) 1, (short) 8);
        return switch (group) {
            case "pending" -> cb.and(activeChain, cb.gt(
                    cb.diff(cb.diff(outstanding, cb.coalesce(i.<BigDecimal>get("reservedQty"), zero)),
                            unfinished),
                    zero));
            case "production" -> cb.and(activeChain, cb.or(
                    cb.gt(unfinished, zero),
                    i.get("chainStatus").in((short) 5, (short) 6)));
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "chainGroup 只支持 pending/production");
        };
    }

    /** 订单进度按单聚合子查询（progress 列表/计数与阶段计数共用，避免口径漂移）。 */
    static String progressGroupedSql(NativeReadScope ownerScope) {
        String base = """
                FROM sales_orders o
                LEFT JOIN clients c ON c.id = o.client_id
                LEFT JOIN employees finance_reviewer
                  ON finance_reviewer.id = o.finance_rejected_by
                LEFT JOIN sales_order_items i ON i.order_id = o.id AND i.is_deleted = false
                WHERE o.is_deleted = false
                  AND (
                    o.status = 1
                    OR (o.status = 0
                        AND o.finance_confirmed = false
                        AND o.finance_rejected = true)
                  )
                """ + " AND " + ownerScope.predicate();
        return """
                SELECT o.id::text, o.bill_no,
                       CAST(o.bill_date AS text), CAST(o.deliver_date AS text),
                       c.name,
                       COALESCE(SUM(i.qty),0) AS order_qty, COALESCE(SUM(i.produced_qty),0) AS produced_qty,
                       COALESCE(SUM(i.shipped_qty),0) AS shipped_qty, COALESCE(SUM(i.reserved_qty),0) AS reserved_qty,
                       COALESCE(SUM(i.planned_qty),0) AS planned_qty,
                       o.finance_confirmed, o.finance_rejected,
                       o.finance_rejected_reason,
                       COALESCE(finance_reviewer.full_name, ''),
                       o.finance_rejected_at,
                       o.is_stopped, o.is_closed,
                       COALESCE(SUM(%s),0) AS unplanned_qty
                """.formatted(SalesOrderChainSql.unplannedQtySql("i")) + base + "\n" + """
                GROUP BY o.id, o.bill_no, o.bill_date, o.deliver_date, c.name,
                         o.finance_confirmed, o.finance_rejected,
                         o.finance_rejected_reason, finance_reviewer.full_name,
                         o.finance_rejected_at, o.is_stopped, o.is_closed
                """;
    }

    /**
     * 阶段派生 SQL（作用于聚合子查询别名 t）：口径必须与 {@link #progressStageOf} 保持一致。
     * CANCELED（整单取消/中止）与 CLOSED（已结案）是终态：不占活跃阶段段（待排产/生产中/
     * 可发货）与阶段计数徽章，只在历史记录（stage='' 全量口径）中可见。
     * V545：剩余未排量（Σ行 {@link SalesOrderChainSql#unplannedQtySql}）> 0 即 PENDING——
     * 部分排产（订 10 排 4）的单留在待排产，不因已排/已产 > 0 提前进生产中。
     */
    static String progressStageExpr() {
        return """
                CASE
                  WHEN t.finance_rejected THEN 'REJECTED'
                  WHEN t.is_stopped THEN 'CANCELED'
                  WHEN t.is_closed THEN 'CLOSED'
                  WHEN t.order_qty <= 0 THEN 'PENDING'
                  WHEN t.shipped_qty >= t.order_qty - 0.000001 THEN 'SHIPPED'
                  WHEN t.reserved_qty > 0.000001 THEN 'SHIPPABLE'
                  WHEN t.unplanned_qty > 0.000001 THEN 'PENDING'
                  WHEN t.produced_qty > 0 OR t.planned_qty > 0 THEN 'PRODUCING'
                  ELSE 'PENDING'
                END
                """;
    }

    /**
     * stage 筛选谓词：'' = 全部（历史记录口径，含驳回/进行中/已发货/已中止/已结案）；
     * 'OPEN' = 待完成（活跃在途，即非 SHIPPED/CANCELED/CLOSED 三个终态）；其余按阶段精确匹配。
     */
    static String progressStagePredicate() {
        String expr = progressStageExpr();
        return "(:stage = '' OR (:stage = 'OPEN' AND (" + expr + ") NOT IN"
                + " ('SHIPPED','CANCELED','CLOSED'))"
                + " OR (:stage <> 'OPEN' AND (" + expr + ") = :stage))";
    }

    static String normalizeProgressStage(String stage) {
        String normalized = stage == null ? "" : stage.strip().toUpperCase();
        return switch (normalized) {
            case "", "OPEN", "REJECTED", "PENDING", "PRODUCING", "SHIPPABLE", "SHIPPED",
                    "CANCELED", "CLOSED" -> normalized;
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "订单进度阶段无效");
        };
    }

    private static double pgNum(Object[] r, int i) {
        return r[i] == null ? 0.0 : ((Number) r[i]).doubleValue();
    }

    private static String pgStr(Object[] r, int i) {
        return r[i] == null ? null : r[i].toString();
    }

    static String progressStageOf(
            double orderQty,
            double producedQty,
            double shippedQty,
            double reservedQty,
            double plannedQty,
            double unplannedQty) {
        return progressStageOf(
                orderQty, producedQty, shippedQty, reservedQty, plannedQty, unplannedQty, false);
    }

    static String progressStageOf(
            double orderQty,
            double producedQty,
            double shippedQty,
            double reservedQty,
            double plannedQty,
            double unplannedQty,
            boolean financeRejected) {
        return progressStageOf(
                orderQty, producedQty, shippedQty, reservedQty, plannedQty, unplannedQty,
                financeRejected, false, false);
    }

    /** Java 镜像：unplannedQty = Σ行剩余未排量（与 {@link #progressStageExpr} 同序）。 */
    static String progressStageOf(
            double orderQty,
            double producedQty,
            double shippedQty,
            double reservedQty,
            double plannedQty,
            double unplannedQty,
            boolean financeRejected,
            boolean stopped,
            boolean closed) {
        if (financeRejected) return "REJECTED";
        if (stopped) return "CANCELED";
        if (closed) return "CLOSED";
        if (orderQty <= 0) return "PENDING";
        if (shippedQty + 1e-6 >= orderQty) return "SHIPPED";
        if (reservedQty > 1e-6) return "SHIPPABLE";
        if (unplannedQty > 1e-6) return "PENDING";
        if (producedQty > 0 || plannedQty > 0) return "PRODUCING";
        return "PENDING";
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_order:view')")
    public OrderDetail detail(UUID id) {
        SalesOrder o = requireReadableOrder(id);
        List<SalesOrderItem> items =
                itemRepo.findByOrderIdAndDeletedFalseOrderByLineNoAsc(id);
        List<OrderItemDto> itemDtos = items.stream().map(this::toItemDto).toList();
        List<OrderCostItemDto> costDtos = items.isEmpty() ? List.of()
                : costItemRepo.findByOrderItemIdIn(items.stream().map(SalesOrderItem::getId).toList())
                        .stream().map(this::toCostDto).toList();
        OrderDetail d = toDetail(o, itemDtos, costDtos,
                hasObjectActionAuthority()
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
                       COALESCE(i.produced_qty,0), COALESCE(i.shipped_qty,0), i.chain_status,
                       %s AS unplanned_qty
                FROM sales_order_items i
                JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors col ON col.id = i.color_id
                LEFT JOIN units u ON u.id = i.unit_id
                WHERE i.order_id = :oid AND i.is_deleted = false
                ORDER BY i.line_no NULLS LAST, i.id
                """.formatted(SalesOrderChainSql.unplannedQtySql("i")))
                .setParameter("oid", id).getResultList();
        List<UUID> itemIds = rows.stream().map(r -> (UUID) r[0]).toList();
        Map<UUID, List<com.uten.imp.features.sales.order.dto.PlanProgressLine.MaterialAnalysisProgress>>
                analysesByItem = planProgressQuery.load(itemIds);
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
                    SELECT child.formal_link_id, child.order_item_id,
                           child.plan_id, child.plan_no, child.plan_status,
                           child.plan_closed, child.bill_date,
                           child.allocated_qty, child.produced_qty,
                           child.inbound_qty, child.allocation_status
                    FROM (
                        SELECT l.id AS formal_link_id, l.order_item_id,
                               p.id AS plan_id, p.bill_no AS plan_no,
                               p.status AS plan_status, p.is_closed AS plan_closed,
                               p.bill_date, l.allocated_qty,
                               COALESCE(l.produced_qty,0) AS produced_qty,
                               COALESCE(l.inbound_qty,0) AS inbound_qty,
                               analysis_link.allocation_status
                        FROM plan_order_item_links l
                        JOIN production_plan_items pi ON pi.id = l.plan_item_id
                        JOIN production_plans p ON p.id = pi.plan_id
                        LEFT JOIN production_material_analysis_plan_links analysis_link
                          ON analysis_link.plan_id = p.id
                        WHERE l.order_item_id IN (:ids)
                          AND l.is_deleted = FALSE
                          AND p.is_deleted = FALSE

                        UNION ALL

                        SELECT NULL::uuid AS formal_link_id,
                               analysis_item.sales_order_item_id AS order_item_id,
                               p.id AS plan_id, p.bill_no AS plan_no,
                               p.status AS plan_status, p.is_closed AS plan_closed,
                               p.bill_date, analysis_link.submitted_qty AS allocated_qty,
                               0::numeric AS produced_qty,
                               0::numeric AS inbound_qty,
                               analysis_link.allocation_status
                        FROM production_material_analysis_plan_links analysis_link
                        JOIN production_material_analysis_items analysis_item
                          ON analysis_item.id = analysis_link.analysis_item_id
                         AND analysis_item.analysis_id = analysis_link.analysis_id
                        JOIN production_plans p ON p.id = analysis_link.plan_id
                        WHERE analysis_item.sales_order_item_id IN (:ids)
                          AND NOT EXISTS (
                              SELECT 1
                              FROM production_plan_items formal_item
                              JOIN plan_order_item_links formal_link
                                ON formal_link.plan_item_id = formal_item.id
                               AND formal_link.order_item_id =
                                   analysis_item.sales_order_item_id
                               AND formal_link.is_deleted = FALSE
                              WHERE formal_item.plan_id = p.id
                                AND p.is_deleted = FALSE
                          )
                    ) child
                    ORDER BY child.bill_date DESC NULLS LAST,
                             child.plan_no, child.plan_id
                    """).setParameter("ids", itemIds).getResultList();
            for (Object[] l : links) {
                byItem.computeIfAbsent((UUID) l[1], k -> new ArrayList<>())
                        .add(new com.uten.imp.features.sales.order.dto.PlanProgressLine.PlanLink(
                                (UUID) l[2], (String) l[3],
                                l[4] == null ? null : ((Number) l[4]).shortValue(),
                                (String) l[10],
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
                    nz((BigDecimal) r[13]),
                    analysesByItem.getOrDefault((UUID) r[0], List.of()),
                    byItem.getOrDefault((UUID) r[0], List.of())));
        }
        return out;
    }

    /** 报价转入回联（SOP §三1）：只按 sourceQuoteId 回联；sourceDocNo 仅作历史显示快照。 */
    private void fillQuoteTrace(SalesOrder o, OrderDetail d) {
        if (o.getSourceQuoteId() == null) return;
        quoteRepo.findById(o.getSourceQuoteId()).filter(q -> !q.isDeleted()).ifPresent(q -> {
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
    @PreAuthorize("hasAuthority('sales_order:create')")
    public OrderDetail create(OrderSaveRequest req) {
        // 发运策略必选（2026-08-18 起）：新单必须显式选择 允许分批 / 整单齐套，
        // 不再允许留空（留空草稿到审核也会被拦，提前到保存点报错更友好）。
        requireSelectableShipmentPolicy(req == null ? null : req.getShipmentPolicy());
        return createInternal(req, null, null);
    }

    /**
     * Quote conversion entry point. The supplied owner is checked against the
     * source bill and is never trusted as a free-form owner assignment.
     */
    @Transactional
    @PreAuthorize("hasAuthority('sales_quote:convert') and hasAuthority('sales_order:create')")
    public OrderDetail createFromQuote(
            OrderSaveRequest req, UUID sourceQuoteId, UUID expectedQuoteOwner) {
        return createInternal(req, sourceQuoteId, expectedQuoteOwner);
    }

    private OrderDetail createInternal(
            OrderSaveRequest req, UUID sourceQuoteId, UUID expectedQuoteOwner) {
        tx.bind();
        referenceValidator.validate(req);
        if (expectedQuoteOwner != null && req.getCurrencyId() == null) {
            // 报价单本身没有币种字段；一键转订单只能使用唯一、明确的启用人民币主档，禁止按汇率猜测。
            req.setCurrencyId(resolveQuoteConversionCurrencyId());
        }
        var sourceQuote = resolveSourceQuote(sourceQuoteId, expectedQuoteOwner);
        SalesOrder o = new SalesOrder();
        applyHeader(req, o);
        if (sourceQuote != null) {
            o.setSourceQuoteId(sourceQuote.getId());
            o.setSourceDocNo(sourceQuote.getBillNo());
        }
        UUID sourceOwner = sourceQuote == null ? null : sourceQuote.getMakerId();
        o.setOwnerEmployeeId(accessPolicy.ownerForNewDocument(sourceOwner));
        o.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
        o.setStatus(STATUS_DRAFT);
        orderRepo.save(o);
        // 普通开单的单价只取货品主档；报价转单则只取已审核报价明细快照。
        // 两条路径都不把 OrderItemLine.price / amount* 当成客户端权威。
        List<SalesQuoteItem> quoteItems =
                sourceQuote == null
                        ? null
                        : quoteItemRepo.findByQuoteIdOrderByLineNoAsc(sourceQuote.getId());
        List<OrderItemDto> items = saveItems(o, req.getItems(), List.of(), quoteItems);
        applyTotals(o, items);
        OrderDetail detail = toDetail(o, items, List.of(), true);
        fillQuoteTrace(o, detail);
        return detail;
    }

    private com.uten.imp.features.sales.quote.SalesQuote resolveSourceQuote(
            UUID sourceQuoteId, UUID expectedQuoteOwner) {
        if (sourceQuoteId == null) {
            if (expectedQuoteOwner != null) {
                throw new ApiException(ErrorCode.CONFLICT, "来源报价与订货单不一致");
            }
            return null;
        }
        var source = quoteRepo.findById(sourceQuoteId).filter(q -> !q.isDeleted()).orElse(null);
        if (source == null) {
            throw new ApiException(ErrorCode.CONFLICT, "来源报价不存在或已删除");
        }
        if (!accessPolicy.hasAuthority("sales_quote:view")) {
            throw new ApiException(ErrorCode.FORBIDDEN, "无权引用销售报价单");
        }
        accessPolicy.requireWritable(source.getMakerId(), "无权引用该销售报价单");
        if (expectedQuoteOwner != null && !java.util.Objects.equals(expectedQuoteOwner, source.getMakerId())) {
            throw new ApiException(ErrorCode.CONFLICT, "来源报价归属已变化，请刷新后重试");
        }
        return source;
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_order:edit')")
    public OrderDetail update(UUID id, OrderSaveRequest req) {
        tx.bind();
        SalesOrder o = requireWritableOrderForUpdate(id, req.getItems() == null ? List.of()
                : req.getItems().stream().filter(line -> line.getGoodsId() != null)
                    .map(line -> new com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension(
                            line.getGoodsId(), line.getColorId())).toList());
        boolean rejectedRevision = o.isFinanceRejected()
                && !o.isFinanceConfirmed()
                && (o.getStatus() == STATUS_APPROVED || o.getStatus() == STATUS_DRAFT);
        boolean approvedRevision = o.getStatus() == STATUS_APPROVED;
        if (o.getStatus() != STATUS_DRAFT && !approvedRevision) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿或有效已审核订单可编辑");
        }
        // 历史单只读保留 CUSTOMER_CONFIRM：不允许把其它策略的订单改回该历史值。
        if (req.getShipmentPolicy() != null
                && SalesOrder.SHIPMENT_POLICY_CUSTOMER_CONFIRM.equalsIgnoreCase(
                        req.getShipmentPolicy().trim())
                && !SalesOrder.SHIPMENT_POLICY_CUSTOMER_CONFIRM.equals(o.getShipmentPolicy())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "「客户确认后分批」仅历史单保留，请选择允许分批发货或整单齐套后发货");
        }
        referenceValidator.validate(req);
        if (rejectedRevision || approvedRevision) {
            String before = revisions.snapshot(id);
            OrderDetail revised = reviseApprovedOrder(o, req);
            if (revisions.record(id, before)) {
                o.setFinanceReviewRevision(o.getFinanceReviewRevision() + 1);
                orderRepo.save(o);
                orderRepo.flush();
            }
            // 已审核订单修改后自动重新送财务；驳回修订继续由销售检查草稿后自行审核。
            if (approvedRevision && !rejectedRevision) {
                return approve(id);
            }
            return revised;
        }
        applyHeader(req, o);
        // 发运策略必选：保存后草稿不得处于未选/历史未指定状态（历史草稿补选后才能保存）。
        if (o.getShipmentPolicy() == null || o.getShipmentPolicy().isBlank()
                || SalesOrder.SHIPMENT_POLICY_LEGACY.equals(o.getShipmentPolicy())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "请选择发运策略(允许分批发货 / 整单齐套后发货)");
        }
        // 同一草稿行保留首次落单时冻结的单价，避免货品主档后来调价静默改写商业快照；
        // 新增/换货行才读取当前货品主档价。旧客户端没有行 UUID 时按稳定商业身份兜底匹配。
        List<SalesOrderItem> existingItems =
                itemRepo.findByOrderIdAndDeletedFalseOrderByLineNoAsc(id);
        costItemRepo.deleteByOrderId(id);
        itemRepo.deleteByOrderId(id);
        itemRepo.flush();
        List<OrderItemDto> items = saveItems(o, req.getItems(), existingItems, null);
        applyTotals(o, items);
        return toDetail(o, items, List.of(), true);
    }

    /**
     * 财务驳回后的受控修订。已审核订单先确认没有任何不可逆下游事实，再释放有效预留；
     * 旧行通过 is_deleted 留存，避免库存预留台账的 order_item_id 变成悬空引用。
     */
    private OrderDetail reviseApprovedOrder(
            SalesOrder order, OrderSaveRequest req) {
        if (order.isStopped() || order.isClosed()) {
            throw new ApiException(ErrorCode.CONFLICT, "已中止或已结案订单不可直接修订");
        }

        List<SalesOrderItem> existing = lockOrderItems(order.getId());
        if (existing.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, "订单没有可修订的有效明细");
        }
        Map<UUID, List<PlanOrderItemLink>> activeLinks = lockActivePlanLinks(existing);
        for (SalesOrderItem item : existing) {
            if (hasRejectedRevisionBlockingLineFacts(item)) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "订单已有发货、退货、核销、排产或完工事实，不能直接修订");
            }
            List<PlanOrderItemLink> links =
                    activeLinks.getOrDefault(item.getId(), List.of());
            requireConsistentPlanningLedger(item, links);
            if (!links.isEmpty()) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "订单已有活动排产关联，须先完成受控反向后再修订");
            }
        }
        assertNoShipmentReferences(order.getId());
        assertNoFinanceFactsForRevision(order.getId());
        assertNoMaterialAnalysisForRevision(
                existing.stream().map(SalesOrderItem::getId).toList());

        reservationService.releaseByOrderItems(
                existing.stream().map(SalesOrderItem::getId).toList());

        applyHeader(req, order);
        if (order.getShipmentPolicy() == null || order.getShipmentPolicy().isBlank()
                || SalesOrder.SHIPMENT_POLICY_LEGACY.equals(order.getShipmentPolicy())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "请选择发运策略(允许分批发货 / 整单齐套后发货)");
        }
        List<OrderItemDto> revised =
                reconcileRejectedRevisionItems(order, existing, req.getItems());
        order.setStatus(STATUS_DRAFT);
        order.setFinanceConfirmed(false);
        clearPartialShipmentConfirmation(order);
        orderRepo.save(order);
        applyTotals(order, revised);
        return toDetail(order, revised, List.of(), true);
    }

    static boolean hasRejectedRevisionBlockingLineFacts(SalesOrderItem item) {
        return nz(item.getShippedQty()).signum() != 0
                || nz(item.getReturnedQty()).signum() != 0
                || nz(item.getFlagQty()).signum() != 0
                || nz(item.getPlannedQty()).signum() != 0
                || nz(item.getProducedQty()).signum() != 0
                || nz(item.getInboundQty()).signum() != 0;
    }

    private void assertNoShipmentReferences(UUID orderId) {
        @SuppressWarnings("unchecked")
        List<String> shipmentNos = em.createNativeQuery("""
                SELECT DISTINCT shipment.bill_no
                FROM sales_shipment_items shipment_item
                JOIN sales_shipments shipment
                  ON shipment.id = shipment_item.shipment_id
                JOIN sales_order_items order_item
                  ON order_item.id = shipment_item.order_item_id
                WHERE order_item.order_id = :orderId
                  AND COALESCE(shipment_item.is_deleted, FALSE) = FALSE
                  AND COALESCE(shipment.is_deleted, FALSE) = FALSE
                ORDER BY shipment.bill_no
                """, String.class)
                .setParameter("orderId", orderId)
                .getResultList();
        if (!shipmentNos.isEmpty()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "订单已有出货作业，须先撤销相关出货单："
                            + String.join("、", shipmentNos));
        }
    }

    private void assertNoFinanceFactsForRevision(UUID orderId) {
        long count = ((Number) em.createNativeQuery("""
                SELECT CASE WHEN EXISTS(
                    SELECT 1
                    FROM finance_receipts receipt
                    WHERE receipt.sales_order_id = :orderId
                      AND receipt.status = 1
                      AND COALESCE(receipt.is_deleted, FALSE) = FALSE)
                  OR EXISTS(
                    SELECT 1
                    FROM customer_open_item_offsets offset_row
                    WHERE offset_row.sales_order_id = :orderId
                      AND offset_row.status = 'APPLIED')
                  OR EXISTS(
                    SELECT 1
                    FROM ar_ap_source_refs source_ref
                    WHERE source_ref.source_type = 'SALES_ORDER'
                      AND source_ref.source_id = :orderId)
                  THEN 1 ELSE 0 END
                """)
                .setParameter("orderId", orderId)
                .getSingleResult()).longValue();
        if (count > 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "订单已有预收、核销或应收来源事实，不能通过普通修订改写商业内容");
        }
    }

    private void assertNoMaterialAnalysisForRevision(List<UUID> orderItemIds) {
        if (orderItemIds.isEmpty()) return;
        long count = ((Number) em.createNativeQuery("""
                SELECT COUNT(*)
                FROM production_material_analysis_items analysis_item
                WHERE analysis_item.sales_order_item_id IN (:ids)
                  AND COALESCE(analysis_item.is_deleted, FALSE) = FALSE
                """)
                .setParameter("ids", orderItemIds)
                .getSingleResult()).longValue();
        if (count > 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "订单已有物料分析事实；数量调整请使用改量，其余商业内容须先受控处理下游再修订");
        }
    }

    private List<OrderItemDto> reconcileRejectedRevisionItems(
            SalesOrder order,
            List<SalesOrderItem> existing,
            List<OrderItemLine> requested) {
        if (requested == null || requested.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "订货明细不能为空");
        }
        Map<UUID, SalesOrderItem> existingById = existing.stream()
                .collect(java.util.stream.Collectors.toMap(
                        SalesOrderItem::getId, item -> item));
        java.util.Set<UUID> seenExistingIds = new java.util.HashSet<>();
        Map<UUID, SalesGoodsSnapshot> goodsSnapshots = SalesGoodsSnapshot.fromMaster(
                em,
                requested.stream().map(OrderItemLine::getGoodsId).toList(),
                SalesGoodsSnapshot.MASTER_AT_SAVE);
        Map<UUID, BigDecimal> masterPrices = loadMasterOrderPrices(requested);
        List<OrderItemDto> result = new ArrayList<>(requested.size());
        int autoLine = 1;
        for (OrderItemLine line : requested) {
            SalesOrderItem target = null;
            if (line.getId() != null) {
                if (!seenExistingIds.add(line.getId())) {
                    throw new ApiException(
                            ErrorCode.VALIDATION_FAILED, "修订明细 UUID 不能重复");
                }
                SalesOrderItem stored = existingById.get(line.getId());
                if (stored == null) {
                    throw new ApiException(
                            ErrorCode.CONFLICT, "修订明细不存在、已删除或不属于本订单");
                }
                if (sameRejectedRevisionIdentity(stored, line)) {
                    target = stored;
                } else {
                    stored.setDeleted(true);
                    itemRepo.save(stored);
                }
            }
            BigDecimal authoritativePrice = target == null ? null : target.getPrice();
            if (target == null) {
                target = new SalesOrderItem();
                target.setOrderId(order.getId());
            }
            // 商业身份未变的既有行保留冻结单价；新增/换货行只取当前主档价。
            if (authoritativePrice == null) {
                authoritativePrice = requireMasterOrderPrice(
                        line.getGoodsId(), masterPrices.get(line.getGoodsId()));
            }
            BigDecimal normalizedDiscount = normalizeOrderDiscountForWrite(line.getDiscount());
            requirePreviewPriceMatches(line, authoritativePrice);
            requireSafeCommercialLine(line, authoritativePrice);
            applyRejectedRevisionLine(
                    order,
                    target,
                    line,
                    autoLine,
                    goodsSnapshots,
                    authoritativePrice,
                    normalizedDiscount);
            itemRepo.save(target);
            result.add(toItemDto(target));
            autoLine++;
        }
        for (SalesOrderItem stored : existing) {
            if (!seenExistingIds.contains(stored.getId())) {
                stored.setDeleted(true);
                itemRepo.save(stored);
            }
        }
        itemRepo.flush();
        return result;
    }

    static boolean sameRejectedRevisionIdentity(
            SalesOrderItem stored, OrderItemLine requested) {
        return java.util.Objects.equals(stored.getGoodsId(), requested.getGoodsId())
                && java.util.Objects.equals(stored.getColorId(), requested.getColorId())
                && java.util.Objects.equals(stored.getUnitId(), requested.getUnitId())
                && sameDecimal(stored.getUnitRate(), requested.getUnitRate());
    }

    private static boolean sameDecimal(BigDecimal left, BigDecimal right) {
        if (left == null || right == null) return left == right;
        return left.compareTo(right) == 0;
    }

    private void applyRejectedRevisionLine(
            SalesOrder order,
            SalesOrderItem item,
            OrderItemLine line,
            int autoLine,
            Map<UUID, SalesGoodsSnapshot> goodsSnapshots,
            BigDecimal authoritativePrice,
            BigDecimal normalizedDiscount) {
        item.setDeleted(false);
        item.setBillNo(order.getBillNo());
        item.setBillDate(order.getBillDate());
        item.setLineNo(line.getLineNo() == null ? autoLine : line.getLineNo());
        item.setGoodsId(line.getGoodsId());
        applyGoodsSnapshot(
                item,
                SalesGoodsSnapshot.require(
                        goodsSnapshots, line.getGoodsId(), "销售订单修订明细"),
                null);
        item.setColorId(line.getColorId());
        item.setUnitId(line.getUnitId());
        item.setUnitRate(line.getUnitRate());
        item.setQty(line.getQty());
        item.setPrice(authoritativePrice);
        item.setAmountOriginal(authoritativeOrderAmount(
                line.getQty(), authoritativePrice, normalizedDiscount));
        item.setAmountLocal(null);
        item.setShippedQty(BigDecimal.ZERO);
        item.setReturnedQty(BigDecimal.ZERO);
        item.setFlagQty(BigDecimal.ZERO);
        item.setDiscount(normalizedDiscount);
        item.setTaxAmount(BigDecimal.ZERO);
        item.setWeight(line.getWeight());
        item.setClientNo(line.getClientNo());
        item.setClientModel(line.getClientModel());
        item.setDeliverDate(line.getDeliverDate());
        item.setSourceDocNo(line.getSourceDocNo());
        item.setMachiningPrice(line.getMachiningPrice());
        item.setCircumference(line.getCircumference());
        item.setInboundQty(BigDecimal.ZERO);
        item.setInNo(null);
        item.setOutNo(null);
        item.setReservedQty(BigDecimal.ZERO);
        item.setPlannedQty(BigDecimal.ZERO);
        item.setProducedQty(BigDecimal.ZERO);
        item.setChainStatus((short) 0);
        item.setRemark(line.getRemark());
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_order:delete')")
    public void delete(UUID id) {
        tx.bind();
        SalesOrder o = requireWritableOrderForUpdate(id);
        com.uten.imp.common.web.StandardDocumentLifecycleCapabilities.requireDraftForDelete(o.getStatus());
        o.setDeleted(true);
        o.setDeletedAt(OffsetDateTime.now());
        orderRepo.save(o);
    }

    /** 审核：status 0→1。业务链：逐行库存检查 + 软预留（同事务，行锁防并发超卖）。 */
    @Transactional
    @PreAuthorize("hasAuthority('sales_order:approve')")
    public OrderDetail approve(UUID id) {
        tx.bind();
        // 并发认领守卫：他人正审核同一单时拒绝重复操作（UX 层；下方悲观锁+状态前置仍是底线）。
        taskClaim.requireNoActiveClaimByOther(TASK_TYPE_APPROVE, id.toString());
        SalesOrder o = requireWritableOrderForUpdate(id);
        if (o.getStatus() == null || o.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        }
        // 发运策略必选（与保存同口径）：历史未指定/未选草稿须先编辑补选再审核。
        if (o.getShipmentPolicy() == null || o.getShipmentPolicy().isBlank()
                || SalesOrder.SHIPMENT_POLICY_LEGACY.equals(o.getShipmentPolicy())) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "请先编辑订单选择发运策略(允许分批发货 / 整单齐套后发货)再审核");
        }
        List<SalesOrderItem> items = lockOrderItems(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        }
        referenceValidator.validateStoredOrder(o.getClientId(), items);
        // 销售订单只确认币种；汇率在 SHIPPED 正式立账时由财务主档提供。
        requireActiveCurrency(o.getCurrencyId(), ErrorCode.CONFLICT);
        requireSafeStoredCommercialOrder(o, items);
        clearSalesStageLocalFacts(o, items);
        captureGoodsSnapshots(
                items, SalesGoodsSnapshot.MASTER_AT_APPROVAL, OffsetDateTime.now());
        reserveOnApprove(o, items);
        o.setStatus(STATUS_APPROVED);
        o.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（报表按 approver_id 解析审核员）
        if (o.isFinanceRejected()) {
            // 当前驳回已由销售显式修订并重新审核；保留最后一次原因/人员/时间供时间线展示。
            o.setFinanceRejected(false);
        }
        orderRepo.save(o);
        // V294 闸门：审核后先通知财务确认；财务确认后才通知计划部接手物料分析。
        if (o.getFinanceReviewRevision() > 0) {
            chainNotice.notifyOrderPendingFinanceConfirmation(id, true);
        } else {
            chainNotice.notifyOrderPendingFinanceConfirmation(id);
        }
        return detail(id);
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_order:reverse')")
    public OrderDetail reverse(UUID id) {
        tx.bind();
        SalesOrder o = requireWritableOrderForUpdate(id);
        if (o.getStatus() == null || o.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        }
        List<SalesOrderItem> items = lockOrderItems(id);
        assertNoActiveShipmentWork(
                items.stream().map(SalesOrderItem::getId).toList(), "红冲订单");
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
        clearPartialShipmentConfirmation(o);
        orderRepo.save(o);
        return detail(id);
    }

    /**
     * 审核时逐行软预留：
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
            // V545：上链落点走统一派生（未交付=0→9；预留够→7；否则按剩余未排量落 1/2）。
            it.setChainStatus(SalesChainStatus.deriveOnChain((short) 0,
                    it.getQty(), it.getShippedQty(), it.getReturnedQty(), it.getFlagQty(),
                    it.getReservedQty(), it.getPlannedQty(), it.getProducedQty()));
            itemRepo.save(it);
        }
    }

    /**
     * 订单改量（SOP 异常段）：已审订单逐行改数量。
     * 增量重走库存检查+软预留（不足自动回调度待排产）；减量先释放预留再回退排产分摊；
     * 新数量 ≥ 已发净量（shipped−returned）；涉及已排产/已产行需生产部权限点确认。
     */
    @Transactional
    @PreAuthorize("hasAuthority('sales_order:change_qty')")
    public OrderDetail changeQty(UUID id, com.uten.imp.features.sales.order.dto.OrderChangeQtyRequest req) {
        tx.bind();
        SalesOrder o = requireWritableOrderForUpdate(id);
        if (o.getStatus() == null || o.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核订单可改量(草稿请直接编辑)");
        }
        // 2026-09-05 用户口径（反转）：财务确认后「允许」改量，但改完自动回到
        // 「待财务确认」——重新进入财务队列，财务按修改清单（以前→现在）复核。
        // 驳回单仍走上面的受控修订。
        final boolean wasFinanceConfirmed = o.isFinanceConfirmed();
        final boolean wasFinanceRejected = o.isFinanceRejected();
        if (o.isStopped()) {
            throw new ApiException(ErrorCode.BUSINESS, "已中止订单不可改量");
        }
        Map<UUID, SalesOrderItem> items = new HashMap<>();
        List<SalesOrderItem> lockedItems = lockOrderItems(id);
        // A quantity change can touch a historical order that still carries a
        // sales-stage local shadow. Clear every line, not only changed lines.
        clearSalesStageLocalFacts(o, lockedItems);
        orderRepo.save(o);
        itemRepo.saveAll(lockedItems);
        for (SalesOrderItem it : lockedItems) items.put(it.getId(), it);
        Map<UUID, List<PlanOrderItemLink>> activeLinks = lockActivePlanLinks(lockedItems);
        for (SalesOrderItem item : lockedItems) {
            requireConsistentPlanningLedger(item, activeLinks.getOrDefault(item.getId(), List.of()));
        }

        // 第一遍：校验 + 是否涉及已排产/已产（触发生产确认权限点）
        java.util.Set<UUID> changedOrderItemIds = new java.util.HashSet<>();
        boolean touchesPlanned = false;
        boolean actualQtyChanged = false;
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
                        "新数量不能低于已履约净量(" + floor.stripTrailingZeros().toPlainString() + ")");
            }
            if (l.getNewQty().compareTo(nz(it.getQty())) != 0) {
                actualQtyChanged = true;
                assertNoActiveShipmentWork(List.of(it.getId()), "修改订单数量");
            }
            if (nz(it.getPlannedQty()).signum() > 0
                    || nz(it.getProducedQty()).signum() > 0
                    || !activeLinks.getOrDefault(it.getId(), List.of()).isEmpty()) {
                touchesPlanned = true;
            }
        }
        requireNoFrozenExecutionAllocationDecrease(req, items);
        if (touchesPlanned) requirePlannedChangePermission();

        // 第二遍：逐行应用（同时记录改量事实，供财务确认页「修改清单」对照）。
        List<Object[]> qtyChangeFacts = new ArrayList<>();
        for (var l : req.getItems()) {
            SalesOrderItem it = items.get(l.getOrderItemId());
            BigDecimal oldQty = nz(it.getQty());
            BigDecimal newQty = l.getNewQty();
            if (newQty.compareTo(oldQty) == 0) continue;
            qtyChangeFacts.add(new Object[]{it.getId(), oldQty, newQty});
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
                            throw new ApiException(ErrorCode.BUSINESS, "减量超过可调整范围(已发/已产部分不可减)");
                        }
                    }
                }
            }
            BigDecimal open = outstanding(
                    newQty, it.getShippedQty(), it.getReturnedQty(), it.getFlagQty());
            // BUG-S2：open<=0 表示该行已无可发（已发足/已退还），残余预留是孤儿——释放，避免永久占 ATP
            // 且从稀缺仲裁 UI（按 is_closed=false 过滤）消失成不可见泄漏。
            if (chained && open.signum() <= 0 && reserved.signum() > 0) {
                reservationService.releaseForOrderItem(it.getId(), reserved.multiply(rate));
                reserved = BigDecimal.ZERO;
            }
            // V545 统一派生（剩余未排量优先：改量后仍有未排量的行回 1/2；原值 3/5 粘性同 SQL 口径）。
            short chain = !chained ? 0
                    : SalesChainStatus.derive(it.getChainStatus(), newQty, it.getShippedQty(),
                            it.getReturnedQty(), it.getFlagQty(), reserved, planned,
                            it.getProducedQty());
            BigDecimal amountOriginal = it.getPrice() == null
                    ? it.getAmountOriginal()
                    : authoritativeOrderAmount(newQty, it.getPrice(), it.getDiscount());
            em.createNativeQuery("""
                    UPDATE sales_order_items
                    SET qty = :q,
                        amount_original = :amountOriginal,
                        amount_local    = NULL,
                        reserved_qty = :r, planned_qty = :p, chain_status = :cs, updated_at = now()
                    WHERE id = :id
                    """).setParameter("q", newQty)
                    .setParameter("amountOriginal", amountOriginal)
                    .setParameter("r", reserved)
                    .setParameter("p", planned).setParameter("cs", chain)
                    .setParameter("id", it.getId()).executeUpdate();
        }
        if (actualQtyChanged) {
            em.createNativeQuery("""
                    UPDATE sales_orders
                    SET partial_shipment_confirmed_at = NULL,
                        partial_shipment_confirmed_by = NULL,
                        partial_shipment_confirmation_reason = NULL,
                        updated_at = now()
                    WHERE id = :id
                    """).setParameter("id", id).executeUpdate();
        }
        if (!qtyChangeFacts.isEmpty()) {
            UUID actorEmployeeId = currentUser.requireEmployeeId();
            for (Object[] fact : qtyChangeFacts) {
                em.createNativeQuery("""
                        INSERT INTO sales_order_qty_change_logs(
                            order_id, order_item_id, old_qty, new_qty,
                            changed_by_employee_id, changed_at)
                        VALUES (:orderId, :itemId, :oldQty, :newQty,
                                :employeeId, clock_timestamp())
                        """)
                        .setParameter("orderId", id)
                        .setParameter("itemId", (UUID) fact[0])
                        .setParameter("oldQty", (BigDecimal) fact[1])
                        .setParameter("newQty", (BigDecimal) fact[2])
                        .setParameter("employeeId", actorEmployeeId)
                        .executeUpdate();
            }
            em.createNativeQuery("""
                    UPDATE sales_orders
                    SET finance_review_revision = finance_review_revision + 1
                    WHERE id = :id
                    """).setParameter("id", id).executeUpdate();
            if (wasFinanceConfirmed || wasFinanceRejected) {
                // 确认后改量：置回待确认重新入队（保留上次确认时间作为修改清单
                // 的对照基线；重新确认后 finance_confirmed_at 前进、清单自然隐藏）。
                em.createNativeQuery("""
                        UPDATE sales_orders
                        SET finance_confirmed = FALSE, finance_rejected = FALSE, updated_at = now()
                        WHERE id = :id
                        """).setParameter("id", id).executeUpdate();
            }
            chainNotice.notifyOrderPendingFinanceConfirmation(id, true);
        }
        recalcTotalsAndClosed(id);
        em.flush();
        em.clear();
        return detail(id);
    }

    /**
     * 订单取消（SOP 异常段）：已审未发货订单整单取消。
     * 释放全部预留（含已产成品回通用库存）+ 断开排产联动（留痕）+ 行状态 -1 + 中止位置位。
     * 已发货订单拒绝（用改量取消未发部分）；涉及已排产/已产需生产部权限点。
     */
    @Transactional
    @PreAuthorize("hasAuthority('sales_order:cancel')")
    public OrderDetail cancel(UUID id) {
        tx.bind();
        SalesOrder o = requireWritableOrderForUpdate(id);
        if (o.getStatus() == null || o.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核订单可取消(草稿直接删除)");
        }
        if (o.isStopped()) {
            throw new ApiException(ErrorCode.BUSINESS, "订单已中止");
        }
        assertNoApprovedCustomerPrepayment(id);
        List<SalesOrderItem> items = lockOrderItems(id);
        assertNoActiveShipmentWork(
                items.stream().map(SalesOrderItem::getId).toList(), "取消订单");
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
        if (o.isFinanceRejected()) {
            // 取消是本次驳回的终止处置；保留原因/人员/时间作历史，只清当前返工态。
            o.setFinanceRejected(false);
        }
        clearPartialShipmentConfirmation(o);
        orderRepo.save(o);
        chainNotice.notifyOrderCanceled(id); // 旁路通知：取消确认→销售 + 无需排产→调度，提交后发送
        return detail(id);
    }

    private void assertNoApprovedCustomerPrepayment(UUID orderId) {
        long count = ((Number) em.createNativeQuery("""
                SELECT CASE WHEN EXISTS(
                    SELECT 1 FROM finance_receipts receipt
                    WHERE receipt.sales_order_id=:orderId
                      AND receipt.receipt_kind='CUSTOMER_PREPAYMENT'
                      AND receipt.status=1 AND COALESCE(receipt.is_deleted,FALSE)=FALSE)
                  OR EXISTS(
                    SELECT 1 FROM customer_open_item_offsets offset_row
                    WHERE offset_row.sales_order_id=:orderId AND offset_row.status='APPLIED')
                  THEN 1 ELSE 0 END
                """).setParameter("orderId", orderId).getSingleResult()).longValue();
        if (count > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "订单存在可用或已应用的客户预收，必须先由财务退款、反转或转移后才能取消；"
                            + "客户预收退款模块本期尚未开放，禁止绕过资金处理直接中止订单");
        }
    }

    /**
     * Records a human-confirmed customer decision. It is intentionally
     * separate from order approval: the fact can be obtained later when only
     * part of a mixed-availability order is ready.
     */
    @Transactional
    @PreAuthorize("hasAuthority('sales_order:confirm_partial_shipment')")
    public OrderDetail setPartialShipmentConfirmation(
            UUID id,
            com.uten.imp.features.sales.order.dto.PartialShipmentConfirmationRequest req) {
        tx.bind();
        // The dedicated action permission does not by itself grant cross-owner
        // access. Supervisors that must confirm another salesperson's order
        // also need the normal delegated/view-all sales scope.
        SalesOrder order = requireWritableOrderForUpdate(id);
        if (order.getStatus() == null || order.getStatus() != STATUS_APPROVED
                || order.isStopped() || order.isClosed()) {
            throw new ApiException(ErrorCode.BUSINESS, "仅可为履约中的已审核订单记录分批发货确认");
        }
        if (!SalesOrder.SHIPMENT_POLICY_CUSTOMER_CONFIRM.equals(
                order.getShipmentPolicy())) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "当前订单策略不使用客户分批确认；请按订单发运策略执行");
        }
        boolean confirmed = Boolean.TRUE.equals(req.getConfirmed());
        if (!confirmed) {
            List<SalesOrderItem> items = lockOrderItems(id);
            assertNoActiveShipmentWork(
                    items.stream().map(SalesOrderItem::getId).toList(),
                    "撤销客户分批确认");
        }
        OffsetDateTime now = OffsetDateTime.now();
        order.setPartialShipmentConfirmedAt(confirmed ? now : null);
        order.setPartialShipmentConfirmedBy(
                confirmed ? currentUser.requireEmployeeId() : null);
        order.setPartialShipmentConfirmationReason(
                confirmed ? req.getReason().trim() : null);
        orderRepo.save(order);
        currentUser.get().ifPresent(u -> auditService.logCommitted(
                u.getId(), u.getUsername(),
                confirmed
                        ? "sales_partial_shipment_confirm"
                        : "sales_partial_shipment_revoke",
                "sales_order",
                "订单=" + id + "；原因=已填写",
                "success"));
        return detail(id);
    }

    // ======================= 预留生命周期 + 稀缺仲裁 =======================

    /**
     * 设置订单行优先级：1急单 / 2普通 / 3现货。设为急单须填原因。
     * 优先级仅用于稀缺手动让单的决策与排序，不触发任何自动抢占；全程显式审计 + DB 触发器。
     */
    @Transactional
    @PreAuthorize("hasAuthority('sales_order:priority')")
    public OrderDetail setLinePriority(UUID orderItemId, OrderPriorityRequest req) {
        tx.bind();
        if (req == null || req.getPriority() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "优先级必填(1急单/2普通/3现货)");
        }
        short priority = req.getPriority();
        if (priority < 1 || priority > 3) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "优先级取值 1急单/2普通/3现货");
        }
        if (priority == 1 && (req.getReason() == null || req.getReason().isBlank())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "设为急单须填写原因");
        }
        UUID orderId = mutationFootprint.lockOrderItem(orderItemId);
        SalesOrderItem it = em.find(SalesOrderItem.class, orderItemId, LockModeType.PESSIMISTIC_WRITE);
        if (it == null || isDeletedOrderItem(orderItemId)) {
            throw new ApiException(ErrorCode.NOT_FOUND, "订单行不存在");
        }
        em.refresh(it, LockModeType.PESSIMISTIC_WRITE);
        if (!orderId.equals(it.getOrderId())) throw new ApiException(ErrorCode.CONFLICT, "订单行来源已变化，请刷新");
        SalesOrder order = requireWritableOrderForUpdate(orderId, "sales_order:priority");
        accessPolicy.requireWritable(order.getOwnerEmployeeId(), "无权设置该订单行优先级",
                "sales_order:priority");
        if (order.isFinanceRejected()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "订单已被财务驳回，请先使用“修改订单”完成受控修订");
        }
        short old = it.getPriority() == null ? 3 : it.getPriority();
        it.setPriority(priority);
        itemRepo.save(it);
        String reason = req.getReason() == null ? "" : req.getReason().trim();
        currentUser.get().ifPresent(u -> auditService.logCommitted(u.getId(), u.getUsername(),
                "sales_order_priority", "sales_order_item",
                "订单行=" + orderItemId + "；优先级=" + old + "→" + priority
                        + (reason.isEmpty() ? "" : "；原因=已填写"),
                "success"));
        return detail(it.getOrderId());
    }

    /**
     * 稀缺让单重排：主管释放某低优先级订单行的部分/全部现货预留。
     * 库存回到可分配池；该行 reserved_qty 回减 + chain_status 回退待排产（缺口自动回调度转生产补足），
     * 并通知其归属销售。不自动给急单预留——急单销售随后经改量/新建审核走正常预留链占用释放出的库存。
     *
     * <p>数据安全：复用 {@code releaseForOrderItem}（FIFO + 行锁 + advisory lock），
     * chain_status 回退与出货驳回 {@code SalesShipmentService.reject} 共用
     * {@link SalesOrderChainSql#chainStatusCaseSql} 统一派生（V545），
     * {@code updated!=1} 抛错防吞并错账。已发货订单行无生效预留，自然拦在 reserved 校验。
     */
    @Transactional
    @PreAuthorize("hasAuthority('sales_order:reallocate')")
    public OrderDetail yieldReservation(UUID orderItemId, OrderYieldRequest req) {
        tx.bind();
        if (req == null || req.getQty() == null || req.getQty().signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "让单数量必须大于 0");
        }
        if (req.getReason() == null || req.getReason().isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "让单须填写原因");
        }
        UUID orderId = mutationFootprint.lockOrderItem(orderItemId);
        SalesOrderItem it = em.find(SalesOrderItem.class, orderItemId, LockModeType.PESSIMISTIC_WRITE);
        if (it == null || isDeletedOrderItem(orderItemId)) {
            throw new ApiException(ErrorCode.NOT_FOUND, "订单行不存在");
        }
        em.refresh(it, LockModeType.PESSIMISTIC_WRITE);
        if (!orderId.equals(it.getOrderId())) throw new ApiException(ErrorCode.CONFLICT, "订单行来源已变化，请刷新");
        SalesOrder o = requireWritableOrderForUpdate(orderId, "sales_order:reallocate");
        accessPolicy.requireWritable(o.getOwnerEmployeeId(), "无权让出该订单行预留",
                "sales_order:reallocate");
        if (o.isFinanceRejected()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "订单已被财务驳回，请先使用“修改订单”完成受控修订");
        }
        if (o.getStatus() == null || o.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核订单的预留可让单");
        }
        assertNoActiveShipmentWork(List.of(orderItemId), "让出订单预留");
        BigDecimal reserved = nz(it.getReservedQty());
        if (reserved.signum() <= 0) {
            throw new ApiException(ErrorCode.BUSINESS, "该行无生效预留可让单");
        }
        BigDecimal yieldRow = req.getQty().min(reserved); // 截断到生效预留，防超让
        BigDecimal rate = (it.getUnitRate() != null && it.getUnitRate().signum() > 0)
                ? it.getUnitRate() : BigDecimal.ONE;
        // 1) 释放预留（基本单位；FIFO + 行锁 + advisory lock，已有原语）
        reservationService.releaseForOrderItem(orderItemId, yieldRow.multiply(rate));
        // 2) 回减 reserved_qty + 行状态回退（行单位；V545 统一派生，剩余未排量优先）
        int updated = em.createNativeQuery("UPDATE sales_order_items\n"
                + "SET reserved_qty = COALESCE(reserved_qty,0) - :q,\n"
                + "    chain_status = "
                + SalesOrderChainSql.chainStatusCaseSql(
                        SalesOrderChainSql.ChainStatusInputs.of("").reservedDelta(" - :q"))
                + "\nWHERE id = :id AND COALESCE(reserved_qty,0) >= :q")
                .setParameter("q", yieldRow).setParameter("id", orderItemId).executeUpdate();
        if (updated != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "订单预留累计小于让单量，禁止自动吞并错账");
        }
        String reason = req.getReason().trim();
        currentUser.get().ifPresent(u -> auditService.logCommitted(u.getId(), u.getUsername(),
                "sales_reservation_yield", "sales_order_item",
                "订单行=" + orderItemId + "；释放预留="
                        + yieldRow.stripTrailingZeros().toPlainString() + "；原因=已填写",
                "success"));
        // 3) 旁路通知被让单的归属销售（缺口已回待排产，提交后发送）
        chainNotice.notifyReservationYielded(orderItemId, yieldRow.stripTrailingZeros().toPlainString(),
                reason, req.getYielderOrderNo());
        return detail(o.getId());
    }

    /**
     * 稀缺库存占用视图：某货品+颜色的全部生效预留 + 订单上下文 + 持有逾期天数，
     * 供主管"稀缺让单"面板判断让谁、让多少。按优先级升序、创建时间升序（急单在前、先占的在前）。
     */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_order:reallocate')")
    public List<ScarceStockReservationView> scarceReservations(UUID goodsId, UUID colorId) {
        if (goodsId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "货品必填");
        }
        int grace = StockReservationService.HOLD_GRACE_DAYS;
        List<ScarceStockReservationView> out = new ArrayList<>();
        for (Object[] row : com.uten.imp.common.util.NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT r.id, r.order_item_id, o.id, o.bill_no, g.code,
                       o.client_id, c.name, i.priority, i.deliver_date,
                       CASE WHEN COALESCE(i.unit_rate,0) > 0
                            THEN (r.qty - r.consumed_qty - r.released_qty) / i.unit_rate
                            ELSE (r.qty - r.consumed_qty - r.released_qty) END AS reserved_row,
                       r.hold_until
                FROM stock_reservations r
                JOIN sales_order_items i ON i.id = r.order_item_id
                JOIN sales_orders o ON o.id = i.order_id
                LEFT JOIN goods g ON g.id = r.goods_id
                LEFT JOIN clients c ON c.id = o.client_id
                WHERE r.is_deleted = FALSE AND r.status = 0
                  AND COALESCE(i.is_deleted, FALSE) = FALSE
                  AND (r.qty - r.consumed_qty - r.released_qty) > 0
                  AND r.goods_id = :gid
                  AND (CAST(:cid AS uuid) IS NULL
                       OR r.color_id IS NOT DISTINCT FROM CAST(:cid AS uuid))
                  AND o.status = 1
                  AND COALESCE(o.is_closed, FALSE) = FALSE
                ORDER BY i.priority ASC NULLS LAST, r.created_at ASC
                """).setParameter("gid", goodsId).setParameter("cid", colorId))) {
            OffsetDateTime holdUntil = toOffsetDateTime(row[10]);
            LocalDate deliverDate = toLocalDate(row[8]);
            out.add(new ScarceStockReservationView(
                    (UUID) row[0], (UUID) row[1], (UUID) row[2], strOf(row[3]), strOf(row[4]),
                    (UUID) row[5], strOf(row[6]),
                    row[7] == null ? null : ((Number) row[7]).shortValue(),
                    deliverDate,
                    toBigDecimal(row[9]),
                    holdUntil,
                    overdueDays(deliverDate, holdUntil, grace)));
        }
        return out;
    }

    /** 持有逾期天数：截止 = COALESCE(hold_until, 交货日+宽限)；截止已过且未发完(调用方已过滤生效预留) → 距今天数，否则 null。 */
    private static Long overdueDays(LocalDate deliverDate, OffsetDateTime holdUntil, int grace) {
        java.time.Instant deadline;
        if (holdUntil != null) {
            deadline = holdUntil.toInstant();
        } else if (deliverDate != null) {
            deadline = deliverDate.plusDays(grace).atStartOfDay(java.time.ZoneOffset.UTC).toInstant();
        } else {
            return null;
        }
        java.time.Instant now = java.time.Instant.now();
        if (!deadline.isBefore(now)) return null;
        return Math.max(0, java.time.Duration.between(deadline, now).toDays());
    }

    /** JPA 原生查询日期列类型随驱动/Hibernate 版本而变，统一健壮提取，防 ClassCastException。 */
    private static LocalDate toLocalDate(Object v) {
        if (v == null) return null;
        if (v instanceof LocalDate ld) return ld;
        if (v instanceof java.sql.Date d) return d.toLocalDate();
        if (v instanceof java.sql.Timestamp t) return t.toLocalDateTime().toLocalDate();
        if (v instanceof java.util.Date d) return d.toInstant().atZone(java.time.ZoneOffset.UTC).toLocalDate();
        return null;
    }

    private static OffsetDateTime toOffsetDateTime(Object v) {
        if (v == null) return null;
        if (v instanceof OffsetDateTime odt) return odt;
        if (v instanceof java.time.Instant instant) return instant.atOffset(java.time.ZoneOffset.UTC);
        if (v instanceof java.sql.Timestamp t) return t.toInstant().atOffset(java.time.ZoneOffset.UTC);
        if (v instanceof java.util.Date d) return d.toInstant().atOffset(java.time.ZoneOffset.UTC);
        return null;
    }

    private static BigDecimal toBigDecimal(Object v) {
        if (v == null) return null;
        if (v instanceof BigDecimal bd) return bd;
        if (v instanceof Number n) return BigDecimal.valueOf(n.doubleValue());
        return null;
    }

    private static String strOf(Object v) {
        return v == null ? null : v.toString();
    }

    /**
     * segment ownership is immutable.  A quantity decrease must not
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

    /** 生产确认权限点：改量/取消涉及已排产或已产行时必须。 */
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
                    total_local = NULL,
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
     * 中止位切换（业务链收口）：已审订单的中止=取消（释放预留/断排产联动）；
     * 恢复中止=重跑库存检查+软预留（排产联动已断，缺口回到调度待排产）。草稿单仅置位。
     */
    @Transactional
    @PreAuthorize("hasAuthority('sales_order:stop')")
    public OrderDetail toggleStopped(UUID id, boolean stopped) {
        tx.bind();
        SalesOrder o = requireWritableOrderForUpdate(id);
        if (o.getStatus() != null && o.getStatus() == STATUS_APPROVED) {
            if (stopped && !o.isStopped()) {
                return cancel(id);
            }
            if (!stopped && o.isStopped()) {
                if (!o.isFinanceConfirmed()
                        && o.getFinanceRejectedAt() != null) {
                    throw new ApiException(
                            ErrorCode.CONFLICT,
                            "曾被财务驳回的取消订单不能直接恢复，请重新修订并走销售/财务审核");
                }
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
        // 销售阶段只确认启用币种，不读取参考汇率，也不接受客户端汇率。
        requireActiveCurrency(req.getCurrencyId(), ErrorCode.VALIDATION_FAILED);
        BigDecimal taxRate = req.getTaxRate() == null
                ? BigDecimal.ZERO : req.getTaxRate();
        if (taxRate.signum() < 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "订单税率不得为负数");
        }
        o.setCurrencyId(req.getCurrencyId());
        o.setExchangeRate(null);
        o.setTaxRate(taxRate);
        if (!(req.getSettlementMethodId() == null && req.getPaymentStyleId() == null
                && o.getSettlementMethodId() == null && o.getPaymentStyleId() != null)) {
            var settlement = com.uten.imp.common.util.SettlementMethodReferenceResolver.resolve(
                    em, req.getSettlementMethodId(), req.getPaymentStyleId(), "结帐方式");
            o.setSettlementMethodId(settlement == null ? null : settlement.id());
            o.setPaymentStyleId(settlement == null ? null : settlement.legacyId());
        }
        o.setSellerId(req.getSellerId());
        o.setDeliverDate(req.getDeliverDate());
        o.setContractNo(req.getContractNo());
        o.setLinkPhone(req.getLinkPhone());
        o.setSignAddr(req.getSignAddr());
        o.setShipAddr(req.getShipAddr());
        // Sales may not create or rewrite cash facts. New rows store zero; edits preserve
        // an imported legacy commercial snapshot for audit only.
        if (o.getCreatedAt() == null) {
            o.setDeposit(BigDecimal.ZERO.setScale(4));
        }
        o.setRemark(req.getRemark());
        // 来源报价关系仅能由报价转换入口按 UUID 设置。普通创建允许记录自由文本快照；
        // 编辑时请求未带 sourceDocNo 则保留既有快照，避免旧客户端清空来源。
        if (o.getSourceQuoteId() == null
                && (o.getBillNo() == null || req.getSourceDocNo() != null)) {
            o.setSourceDocNo(req.getSourceDocNo());
        }
        if (req.getShipmentPolicy() != null) {
            o.setShipmentPolicy(normalizeShipmentPolicy(req.getShipmentPolicy()));
        }
        // 新单未选发运策略时保留 null（销售自填），不再默认 CUSTOMER_CONFIRM。
    }

    /**
     * 订单新建、编辑和审核的币种主档守卫。销售阶段只要求币种存在、未删除且启用，
     * 不读取参考汇率；正式本币金额只在 SHIPPED 时形成。
     */
    private void requireActiveCurrency(
            UUID currencyId, ErrorCode errorCode) {
        if (currencyId == null) {
            throw new ApiException(errorCode, "订单币种不能为空");
        }
        @SuppressWarnings("unchecked")
        List<Object> rows = em.createNativeQuery("""
                        SELECT currency.id
                        FROM currencies currency
                        WHERE currency.id = :currencyId
                          AND COALESCE(currency.is_deleted, false) = false
                          AND currency.status = '使用'
                        FOR SHARE
                        """)
                .setParameter("currencyId", currencyId)
                .getResultList();
        if (rows.size() != 1) {
            throw new ApiException(errorCode, "订单币种不存在、已禁用或已删除");
        }
    }

    /** 报价转订单只使用 V403 冻结到币种 UUID 的唯一启用本位币。 */
    private UUID resolveQuoteConversionCurrencyId() {
        List<UUID> baseCurrencies = com.uten.imp.common.util.NativeQueryResults.typedRows(
                em.createNativeQuery("""
                        SELECT id
                        FROM currencies
                        WHERE COALESCE(is_deleted, false) = false
                          AND status = '使用'
                          AND is_base_currency
                        """), UUID.class);
        if (baseCurrencies.size() == 1) {
            return baseCurrencies.getFirst();
        }
        throw new ApiException(
                ErrorCode.CONFLICT,
                "报价转订货前必须存在唯一启用的本位币 UUID 权威");
    }

    private String normalizeShipmentPolicy(String raw) {
        String policy = raw == null ? "" : raw.trim().toUpperCase(java.util.Locale.ROOT);
        return switch (policy) {
            case SalesOrder.SHIPMENT_POLICY_ALLOW_PARTIAL,
                    SalesOrder.SHIPMENT_POLICY_REQUIRE_COMPLETE,
                    SalesOrder.SHIPMENT_POLICY_CUSTOMER_CONFIRM -> policy;
            default -> throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "发运策略仅支持允许分批、整单齐套或客户确认后分批");
        };
    }

    /** 新单发运策略必选（仅允许新单可选值；CUSTOMER_CONFIRM 为历史保留值，不接受新选）。 */
    private void requireSelectableShipmentPolicy(String raw) {
        String policy = raw == null ? "" : raw.trim().toUpperCase(java.util.Locale.ROOT);
        if (!SalesOrder.SHIPMENT_POLICY_ALLOW_PARTIAL.equals(policy)
                && !SalesOrder.SHIPMENT_POLICY_REQUIRE_COMPLETE.equals(policy)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "请选择发运策略(允许分批发货 / 整单齐套后发货)");
        }
    }

    /**
     * A customer decision is valid only for the current fulfilment lifecycle.
     * Reversal/cancellation must not leave an old confirmation that could be
     * reused after an order is restored or copied into a later shipment flow.
     */
    private void clearPartialShipmentConfirmation(SalesOrder order) {
        order.setPartialShipmentConfirmedAt(null);
        order.setPartialShipmentConfirmedBy(null);
        order.setPartialShipmentConfirmationReason(null);
    }

    private List<OrderItemDto> saveItems(
            SalesOrder o,
            List<OrderItemLine> lines,
            List<SalesOrderItem> existingItems,
            List<SalesQuoteItem> trustedQuoteItems) {
        if (lines == null || lines.isEmpty()) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED, "订货明细不能为空");
        }
        Map<UUID, SalesGoodsSnapshot> goodsSnapshots = SalesGoodsSnapshot.fromMaster(
                em,
                lines.stream().map(OrderItemLine::getGoodsId).toList(),
                SalesGoodsSnapshot.MASTER_AT_SAVE);
        ExistingOrderPriceBook existingPrices = new ExistingOrderPriceBook(existingItems);
        TrustedQuotePriceBook quotePrices = trustedQuoteItems == null
                ? null : new TrustedQuotePriceBook(trustedQuoteItems);
        List<BigDecimal> authoritativePrices = new ArrayList<>(lines.size());
        List<BigDecimal> normalizedDiscounts = new ArrayList<>(lines.size());
        List<OrderItemLine> needsMasterPrice = new ArrayList<>();
        for (OrderItemLine line : lines) {
            BigDecimal price;
            if (quotePrices != null) {
                price = quotePrices.take(line);
                if (price == null) {
                    throw new ApiException(
                            ErrorCode.CONFLICT,
                            "报价转订货的明细或单价快照已变化，请刷新报价后重试");
                }
            } else {
                price = existingPrices.take(line);
                if (price == null) needsMasterPrice.add(line);
            }
            authoritativePrices.add(price);
            normalizedDiscounts.add(normalizeOrderDiscountForWrite(line.getDiscount()));
        }
        // 新行只需一次批量读主档价；同一草稿的既有行和报价转单不会因主档调价漂移。
        Map<UUID, BigDecimal> masterPrices = loadMasterOrderPrices(needsMasterPrice);
        List<OrderItemDto> out = new ArrayList<>(lines.size());
        int auto = 1;
        for (int index = 0; index < lines.size(); index++) {
            OrderItemLine l = lines.get(index);
            BigDecimal authoritativePrice = authoritativePrices.get(index);
            if (authoritativePrice == null) {
                authoritativePrice = requireMasterOrderPrice(
                        l.getGoodsId(), masterPrices.get(l.getGoodsId()));
            }
            BigDecimal normalizedDiscount = normalizedDiscounts.get(index);
            requirePreviewPriceMatches(l, authoritativePrice);
            requireSafeCommercialLine(l, authoritativePrice);
            BigDecimal amountOriginal = authoritativeOrderAmount(
                    l.getQty(), authoritativePrice, normalizedDiscount);
            SalesOrderItem it = new SalesOrderItem();
            it.setOrderId(o.getId());
            it.setBillNo(o.getBillNo());
            it.setBillDate(o.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            it.setGoodsId(l.getGoodsId());
            applyGoodsSnapshot(
                    it,
                    SalesGoodsSnapshot.require(
                            goodsSnapshots, l.getGoodsId(), "销售订单明细"),
                    null);
            it.setColorId(l.getColorId());
            it.setUnitId(l.getUnitId());
            it.setUnitRate(l.getUnitRate());
            it.setQty(l.getQty());
            it.setPrice(authoritativePrice);
            // 客户端 price / amount* 只用于预览；持久化金额始终用权威单价和销售填写的
            // 规范化折扣重算，避免伪造金额或小数位漂移。
            it.setAmountOriginal(amountOriginal);
            // 销售订单不形成任何本币金额；SHIPPED 立账时再按财务汇率计算。
            it.setAmountLocal(null);
            it.setDiscount(normalizedDiscount);
            // A tax engine/price-condition ledger is not present yet. Do not
            // accept a client-authored tax amount as an accounting fact.
            it.setTaxAmount(BigDecimal.ZERO);
            it.setWeight(l.getWeight());
            it.setClientNo(l.getClientNo());
            it.setClientModel(l.getClientModel());
            it.setDeliverDate(l.getDeliverDate());
            it.setSourceDocNo(l.getSourceDocNo());
            it.setMachiningPrice(l.getMachiningPrice());
            it.setCircumference(l.getCircumference());
            // These are downstream-derived fields and must never be supplied
            // by an order-edit request.
            it.setInboundQty(BigDecimal.ZERO);
            it.setInNo(null);
            it.setOutNo(null);
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            out.add(toItemDto(it));
            auto++;
        }
        return out;
    }

    /**
     * 一次批量读取新行所需货品销售单价并加共享锁，避免保存事务内被并发调价撕裂。
     * 货品可见/启用/单位引用已由 {@link SalesMasterReferenceValidator} 先行校验；这里仅取得
     * NUMERIC(18,4) 的价格权威，不重复做逐行查询。
     */
    private Map<UUID, BigDecimal> loadMasterOrderPrices(List<OrderItemLine> lines) {
        if (lines == null || lines.isEmpty()) return Map.of();
        LinkedHashSet<UUID> ids = new LinkedHashSet<>();
        for (OrderItemLine line : lines) {
            if (line != null && line.getGoodsId() != null) ids.add(line.getGoodsId());
        }
        if (ids.isEmpty()) return Map.of();
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT goods.id, goods.price
                        FROM goods
                        WHERE goods.id IN (:ids)
                          AND COALESCE(goods.is_deleted, FALSE) = FALSE
                          AND goods.status = '使用'
                        FOR SHARE
                        """)
                .setParameter("ids", List.copyOf(ids))
                .getResultList();
        Map<UUID, BigDecimal> result = new HashMap<>();
        for (Object[] row : rows) {
            result.put((UUID) row[0], (BigDecimal) row[1]);
        }
        return result;
    }

    static BigDecimal requireMasterOrderPrice(UUID goodsId, BigDecimal price) {
        if (price == null) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "货品未维护销售单价，无法创建销售订货明细(" + goodsId + ")");
        }
        if (price.signum() < 0) {
            throw new ApiException(ErrorCode.CONFLICT, "货品销售单价为负数，禁止开单");
        }
        return price;
    }

    /**
     * 请求单价不是写入来源，但若旧/新客户端提交了页面预览值，就必须与服务端权威快照一致。
     * 这样既阻止改包篡价，也避免用户开单期间主档调价后静默保存成一个未核对的新价格；
     * 客户端省略 price 仍可兼容，由服务端独立取价。
     */
    static void requirePreviewPriceMatches(
            OrderItemLine line, BigDecimal authoritativePrice) {
        if (line.getPrice() != null
                && authoritativePrice != null
                && line.getPrice().compareTo(authoritativePrice) != 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "订单单价已变化或请求被修改，请刷新货品/来源单据后重新确认");
        }
    }

    /**
     * 新写折扣统一为四位倍率：1=原价、0.9=9折。null/0 是旧客户端的“不打折”表达，
     * 保存时归一为 1；已审核历史行仍由审核兼容公式把 null/0 解释为 1，不批量改写历史。
     */
    static BigDecimal normalizeOrderDiscountForWrite(BigDecimal discount) {
        if (discount == null || discount.signum() == 0) {
            return BigDecimal.ONE.setScale(4);
        }
        if (discount.signum() < 0 || discount.compareTo(BigDecimal.ONE) > 0) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "折扣须为大于 0 且不大于 1 的倍率(1=原价，0.9=9折)");
        }
        if (discount.stripTrailingZeros().scale() > 4) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "折扣最多四位小数(最小精度 0.0001，1=原价，0.9=9折)");
        }
        return discount.setScale(4);
    }

    /** 既有草稿行价格索引：UUID 精确命中优先；旧客户端无 UUID 时按商业身份队列匹配。 */
    static final class ExistingOrderPriceBook {
        private final Map<UUID, SalesOrderItem> byId = new HashMap<>();
        private final Map<OrderLinePriceIdentity, ArrayDeque<SalesOrderItem>> byIdentity =
                new HashMap<>();
        private final Set<UUID> consumed = new HashSet<>();

        ExistingOrderPriceBook(List<SalesOrderItem> items) {
            if (items == null) return;
            for (SalesOrderItem item : items) {
                byId.put(item.getId(), item);
                byIdentity.computeIfAbsent(
                        OrderLinePriceIdentity.from(item), ignored -> new ArrayDeque<>())
                        .addLast(item);
            }
        }

        BigDecimal take(OrderItemLine line) {
            if (line == null) return null;
            if (line.getId() != null) {
                SalesOrderItem exact = byId.get(line.getId());
                if (exact == null
                        || !OrderLinePriceIdentity.from(exact)
                                .equals(OrderLinePriceIdentity.from(line))
                        || !consumed.add(exact.getId())) {
                    return null;
                }
                return exact.getPrice();
            }
            ArrayDeque<SalesOrderItem> candidates =
                    byIdentity.get(OrderLinePriceIdentity.from(line));
            while (candidates != null && !candidates.isEmpty()) {
                SalesOrderItem candidate = candidates.removeFirst();
                if (consumed.add(candidate.getId())) return candidate.getPrice();
            }
            return null;
        }
    }

    /** 报价转单价格只按来源报价行号+商业身份匹配，绝不使用请求体里的 price。 */
    static final class TrustedQuotePriceBook {
        private final Map<QuoteLinePriceIdentity, ArrayDeque<BigDecimal>> prices = new HashMap<>();

        TrustedQuotePriceBook(List<SalesQuoteItem> items) {
            for (var item : items) {
                if (item.getPrice() == null || item.getPrice().signum() < 0) {
                    throw new ApiException(
                            ErrorCode.CONFLICT,
                            "来源报价存在空或负数单价，不能转换为销售订货单");
                }
                prices.computeIfAbsent(
                        QuoteLinePriceIdentity.from(item), ignored -> new ArrayDeque<>())
                        .addLast(item.getPrice());
            }
        }

        BigDecimal take(OrderItemLine line) {
            ArrayDeque<BigDecimal> candidates = prices.get(QuoteLinePriceIdentity.from(line));
            return candidates == null || candidates.isEmpty() ? null : candidates.removeFirst();
        }
    }

    private record OrderLinePriceIdentity(
            UUID goodsId, UUID colorId, UUID unitId, BigDecimal unitRate) {
        static OrderLinePriceIdentity from(SalesOrderItem item) {
            return new OrderLinePriceIdentity(
                    item.getGoodsId(), item.getColorId(), item.getUnitId(), decimalKey(item.getUnitRate()));
        }

        static OrderLinePriceIdentity from(OrderItemLine line) {
            return new OrderLinePriceIdentity(
                    line.getGoodsId(), line.getColorId(), line.getUnitId(), decimalKey(line.getUnitRate()));
        }
    }

    private record QuoteLinePriceIdentity(
            Integer lineNo, UUID goodsId, UUID colorId, UUID unitId, BigDecimal unitRate) {
        static QuoteLinePriceIdentity from(SalesQuoteItem item) {
            return new QuoteLinePriceIdentity(
                    item.getLineNo(), item.getGoodsId(), item.getColorId(), item.getUnitId(),
                    decimalKey(item.getUnitRate()));
        }

        static QuoteLinePriceIdentity from(OrderItemLine line) {
            return new QuoteLinePriceIdentity(
                    line.getLineNo(), line.getGoodsId(), line.getColorId(), line.getUnitId(),
                    decimalKey(line.getUnitRate()));
        }
    }

    private static BigDecimal decimalKey(BigDecimal value) {
        return value == null ? null : value.stripTrailingZeros();
    }

    private void captureGoodsSnapshots(
            List<SalesOrderItem> items, String source, OffsetDateTime lockedAt) {
        Map<UUID, SalesGoodsSnapshot> goodsSnapshots = SalesGoodsSnapshot.fromMaster(
                em,
                items.stream().map(SalesOrderItem::getGoodsId).toList(),
                source);
        for (SalesOrderItem item : items) {
            applyGoodsSnapshot(
                    item,
                    SalesGoodsSnapshot.require(
                            goodsSnapshots, item.getGoodsId(), "销售订单明细"),
                    lockedAt);
        }
    }

    private static void applyGoodsSnapshot(
            SalesOrderItem item, SalesGoodsSnapshot snapshot, OffsetDateTime lockedAt) {
        item.setGoodsCodeSnapshot(snapshot.code());
        item.setGoodsNameSnapshot(snapshot.name());
        item.setGoodsSnapshotSource(snapshot.source());
        item.setGoodsSnapshotLockedAt(lockedAt);
    }

    private static void requireSafeCommercialLine(
            OrderItemLine line, BigDecimal authoritativePrice) {
        if (line.getGoodsId() == null
                || line.getUnitId() == null
                || line.getUnitRate() == null
                || line.getUnitRate().signum() <= 0
                || line.getQty() == null || line.getQty().signum() <= 0
                || authoritativePrice == null || authoritativePrice.signum() < 0
                || isNegative(line.getTaxAmount())
                || isNegative(line.getWeight())
                || isNegative(line.getMachiningPrice())
                || isNegative(line.getCircumference())) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "订单货品、单位、正数数量和非负权威单价必须完整，金额由服务端计算");
        }
    }

    static BigDecimal authoritativeOrderAmount(
            BigDecimal quantity, BigDecimal unitPrice) {
        return authoritativeOrderAmount(quantity, unitPrice, null);
    }

    /**
     * 订单行权威金额 = 数量 × 单价 × 折扣倍率。折扣（货品主档 zk 倍率，1=原价、0.9=9折）为
     * null/0 视为不打折（倍率 1）——兼容历史订单行（discount 默认 0/未填，金额仍=数量×单价）
     * 与无折扣行，避免历史数据被重新解释为免费。
     */
    static BigDecimal authoritativeOrderAmount(
            BigDecimal quantity, BigDecimal unitPrice, BigDecimal discount) {
        if (quantity == null || quantity.signum() <= 0
                || unitPrice == null || unitPrice.signum() < 0
                || isNegative(discount)) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "订单数量必须大于 0，价格和折扣不得为负数");
        }
        BigDecimal multiplier = (discount == null || discount.signum() == 0)
                ? BigDecimal.ONE : discount;
        return quantity.multiply(unitPrice).multiply(multiplier)
                .setScale(4, RoundingMode.HALF_UP);
    }

    private static void requireSafeStoredCommercialOrder(
            SalesOrder order, List<SalesOrderItem> items) {
        if (isNegative(order.getTaxRate())
                || isNegative(order.getDeposit())) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "订单商业条款无效，禁止审核");
        }
        for (SalesOrderItem item : items) {
            BigDecimal expectedOriginal = item.getQty() == null
                    || item.getPrice() == null
                    ? null
                    : item.getQty().multiply(item.getPrice())
                            .multiply(item.getDiscount() == null
                                    || item.getDiscount().signum() == 0
                                            ? BigDecimal.ONE
                                            : item.getDiscount())
                            .setScale(4, RoundingMode.HALF_UP);
            if (item.getUnitId() == null
                    || item.getUnitRate() == null
                    || item.getUnitRate().signum() <= 0
                    || item.getQty() == null || item.getQty().signum() <= 0
                    || item.getPrice() == null || item.getPrice().signum() < 0
                    || isNegative(item.getDiscount())
                    || expectedOriginal == null
                    || item.getAmountOriginal() == null
                    || item.getAmountOriginal().compareTo(expectedOriginal) != 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "订单明细数量、价格或金额不一致，禁止审核；请重新保存草稿");
            }
        }
    }

    /** 清除旧草稿遗留的销售阶段汇率/本币影子，避免审核后继续被误认作会计事实。 */
    private static void clearSalesStageLocalFacts(
            SalesOrder order, List<SalesOrderItem> items) {
        order.setExchangeRate(null);
        order.setTotalLocal(null);
        order.setTotalOriginal(items.stream()
                .map(item -> item.getAmountOriginal() == null
                        ? BigDecimal.ZERO : item.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add));
        for (SalesOrderItem item : items) {
            item.setAmountLocal(null);
        }
    }

    private static boolean isNegative(BigDecimal value) {
        return value != null && value.signum() < 0;
    }

    private void applyTotals(SalesOrder o, List<OrderItemDto> items) {
        BigDecimal original = items.stream()
                .map(i -> i.getAmountOriginal() == null ? BigDecimal.ZERO : i.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        o.setTotalLocal(null);
        o.setTotalOriginal(original);
        orderRepo.save(o);
    }

    private OrderListItem toList(SalesOrder o, String sellerName, boolean writable) {
        // 延期预警：已审未结案 + 距交货日 ≤3 天（含逾期）；草稿/红冲/结案不预警
        boolean delayWarning = o.getDeliverDate() != null
                && o.getStatus() != null && o.getStatus() == STATUS_APPROVED
                && !o.isClosed() && !o.isStopped()
                && !o.getDeliverDate().isAfter(BusinessTime.today().plusDays(3));
        boolean mask = !priceMasker.canView(); // 价格脱敏（SOP §三8）：无权限置 null + priceMasked 标记
        return new OrderListItem(o.getId(), o.getBillNo(), o.getBillDate(), o.getClientId(),
                o.getCurrencyId(), mask ? null : o.getTotalOriginal(),
                null, o.getStatus(), o.isClosed(), o.isStopped(),
                o.getLegacyId(), o.getDeliverDate(), delayWarning, mask, writable, sellerName, o.getSellerId(),
                o.isFinanceConfirmed(), o.isFinanceRejected());
    }

    private OrderItemDto toItemDto(SalesOrderItem it) {
        return new OrderItemDto(it.getId(), it.getLineNo(), it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(),
                it.getGoodsSnapshotSource(), it.getGoodsSnapshotLockedAt(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getPrice(), it.getAmountOriginal(),
                null, it.getShippedQty(), it.getReturnedQty(), it.getFlagQty(),
                it.getDiscount(), it.getTaxAmount(), it.getWeight(), it.getClientNo(), it.getClientModel(),
                it.getDeliverDate(), it.getSourceDocNo(), it.getMachiningPrice(), it.getCircumference(),
                it.getInboundQty(), it.getInNo(), it.getOutNo(), it.getRemark(),
                it.getReservedQty(), it.getPlannedQty(), it.getProducedQty(), it.getChainStatus(), null,
                it.getPriority());
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
                o.getClientId(), o.getCurrencyId(), null, o.getTaxRate(), o.getPaymentStyleId(),
                o.getSettlementMethodId(),
                o.getSellerId(), o.getMakerId(), o.getApproverId(), o.getDeliverDate(), o.getContractNo(),
                o.getLinkPhone(), o.getSignAddr(), o.getShipAddr(),
                mask ? null : o.getDeposit(), o.getRemark(),
                mask ? null : o.getTotalOriginal(), null,
                o.getStatus(), o.isClosed(), o.isStopped(),
                o.getShipmentPolicy(), o.getPartialShipmentConfirmedAt(),
                o.getPartialShipmentConfirmedBy(),
                o.getPartialShipmentConfirmationReason(),
                o.getSourceDocNo(), null, mask, items, costItems,
                nameResolver.nameOf(o.getMakerId()), o.getCreatedAt(), writable,
                shipmentRefs(o.getId()),
                o.isFinanceConfirmed(), o.getFinanceConfirmedAt(),
                o.getFinanceConfirmedBy() == null ? null : nameResolver.nameOf(o.getFinanceConfirmedBy()),
                o.getFinanceConfirmRemark(),
                o.isFinanceRejected(), o.getFinanceRejectedReason(), o.getFinanceRejectedAt(),
                o.getFinanceRejectedBy() == null ? null : nameResolver.nameOf(o.getFinanceRejectedBy()));
    }

    /** 该订单全部出货单聚合（含物流单号与仓库作业状态；SOP §三.7 多单全展示）。 */
    private List<com.uten.imp.features.sales.order.dto.OrderShipmentRefDto> shipmentRefs(UUID orderId) {
        if (orderId == null) return List.of();
        List<Object[]> rows = com.uten.imp.common.util.NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT s.id, s.bill_no, s.bill_date, s.status, s.logistics_no,
                               s.parcel_count, s.warehouse_work_status, s.handed_over_at
                        FROM sales_shipments s
                        WHERE s.source_order_id = :orderId
                          AND COALESCE(s.is_deleted, FALSE) = FALSE
                        ORDER BY s.bill_date, s.bill_no
                        """).setParameter("orderId", orderId));
        return rows.stream()
                .map(r -> new com.uten.imp.features.sales.order.dto.OrderShipmentRefDto(
                        (UUID) r[0], (String) r[1],
                        toLocalDate(r[2]),
                        r[3] == null ? null : ((Number) r[3]).shortValue(),
                        com.uten.imp.features.sales.order.dto.OrderShipmentRefDto.statusLabel(
                                r[3] == null ? null : ((Number) r[3]).shortValue()),
                        (String) r[4],
                        r[5] == null ? null : ((Number) r[5]).intValue(),
                        (String) r[6],
                        toOffsetDateTime(r[7])))
                .toList();
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

    /**
     * 仓库草稿已经形成待备货分配。订单行锁与出货草稿创建使用同一锁顺序，
     * 所以让单、改量、取消或红冲不能越过已经下发仓库的作业。
     */
    private void assertNoActiveShipmentWork(List<UUID> orderItemIds, String action) {
        if (orderItemIds == null || orderItemIds.isEmpty()) return;
        @SuppressWarnings("unchecked")
        List<String> shipmentNos = em.createNativeQuery("""
                SELECT DISTINCT s.bill_no
                FROM sales_shipment_items si
                JOIN sales_shipments s ON s.id = si.shipment_id
                WHERE si.order_item_id IN (:ids)
                  AND COALESCE(si.is_deleted,false) = false
                  AND COALESCE(s.is_deleted,false) = false
                  AND s.status = 0
                  AND COALESCE(s.rejected,false) = false
                ORDER BY s.bill_no
                """, String.class)
                .setParameter("ids", orderItemIds)
                .getResultList();
        if (!shipmentNos.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT,
                    action + "前必须先撤销仓库待备货单：" + String.join("、", shipmentNos));
        }
    }

    private boolean isDeletedOrderItem(UUID orderItemId) {
        Object value = em.createNativeQuery(
                        "SELECT COALESCE(is_deleted,false) FROM sales_order_items WHERE id = :id")
                .setParameter("id", orderItemId)
                .getSingleResult();
        return Boolean.TRUE.equals(value);
    }

    private boolean hasObjectActionAuthority() {
        return accessPolicy.hasAuthority("sales_order:edit")
                || accessPolicy.hasAuthority("sales_order:delete")
                || accessPolicy.hasAuthority("sales_order:approve")
                || accessPolicy.hasAuthority("sales_order:reverse")
                || accessPolicy.hasAuthority("sales_order:stop")
                || accessPolicy.hasAuthority("sales_order:change_qty")
                || accessPolicy.hasAuthority("sales_order:cancel")
                || accessPolicy.hasAuthority("sales_order:confirm_partial_shipment")
                || accessPolicy.hasAuthority("sales_order:priority")
                || accessPolicy.hasAuthority("sales_order:reallocate");
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

    private SalesOrder requireWritableOrder(UUID id, String... operationAuthorities) {
        SalesOrder order = requireOrder(id);
        accessPolicy.requireWritable(
                order.getOwnerEmployeeId(),
                "只能操作本人负责的销售订货单",
                operationAuthorities);
        return order;
    }

    /**
     * 先做归属校验，再以数据库当前值重新加写锁并 refresh。
     * 避免普通 find 得到的受管实体在等待并发事务后仍携带旧 status/isStopped。
     */
    private SalesOrder requireWritableOrderForUpdate(
            UUID id, String... operationAuthorities) {
        return requireWritableOrderForUpdate(id, List.of(), operationAuthorities);
    }

    private SalesOrder requireWritableOrderForUpdate(UUID id,
            List<com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension> requested,
            String... operationAuthorities) {
        SalesOrder visible = requireWritableOrder(id, operationAuthorities);
        mutationFootprint.lockOrder(id, requested);
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
        accessPolicy.requireWritable(
                locked.getOwnerEmployeeId(),
                "只能操作本人负责的销售订货单",
                operationAuthorities);
        taskClaim.requireNoActiveClaim("SALES_ORDER_FINANCE_CONFIRM", id.toString());
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
