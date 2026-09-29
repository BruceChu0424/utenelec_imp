package com.uten.imp.features.sales.order;

import com.uten.imp.application.port.PartyOpenBalancePort;
import com.uten.imp.common.finance.PartyOpenBalances;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.NativeFacets;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.features.sales.order.dto.SalesOrderFinancePendingDto;
import com.uten.imp.features.sales.order.dto.SalesOrderFinanceReviewDto;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;

/**
 * 销售订货单「财务确认」（V294 业务链闸门，V300 补驳回与审核详情）。
 *
 * <p>流程：销售审核（库存检查+软预留照旧）→ <b>财务确认</b> → 计划部接收
 * （物料分析/待排产/MRP/计划关联全部以 {@code finance_confirmed = TRUE} 为准入）。
 * 确认人资格镜像 ADR-027 审核组模型：财务部门（DEPT_FIN）子树在职员工、账号启用，
 * 且持有 {@code sales_order_finance:confirm}（含个人加授）；权限可在权限设置中调整。
 *
 * <p>确认只放行计划可见性，不动库存、不立账；确认后订单红冲/取消规则不变。
 *
 * <p>V300 驳回：财务可驳回（必填原因），驳回先记录事实并通知归属销售；
 * 销售须走受控修订释放预留、回到草稿并重新审核，财务不能直接越过驳回确认。
 */
@Service
@RequiredArgsConstructor
public class SalesOrderFinanceConfirmService {

    private static final int MAX_BATCH_CONFIRM_ORDERS = 100;

    private final EntityManager em;
    private final SalesOrderRepository orderRepo;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    // 旁路通知与 SalesOrderService 同约定：sales→notice 不 import（ADR-017 依赖图
    // 按 import 扫描），全限定名内联引用。
    private final com.uten.imp.features.notice.ChainNoticeService chainNotice;
    private final SalesOrderFinanceConfirmerEligibility confirmerEligibility;
    private final com.uten.imp.application.port.TaskClaimMutationGuardPort taskClaim;
    private final SalesOrderRevisionService revisions;
    // ADR-128: 客户应收只经 finance 的共用余额查询取, 本服务不再自写 ar_ap_ledger 汇总。
    private final PartyOpenBalancePort partyBalances;

    /** 客户信用额度: 迁入客户的旧额度不可信, 按未设置处理(列表与审核页同一表达式)。 */
    private static final String CLIENT_CREDIT_SQL =
            "CASE WHEN c.legacy_id IS NULL THEN c.credit ELSE NULL END";

    /** 确认请求体（remark 可选；确认即放行计划部可见性，幂等由服务层状态前置保证）。 */
    public record FinanceConfirmRequest(
            @Size(max = 500, message = "确认备注不能超过 500 个字符") String remark,
            Long expectedRevision,UUID expectedClaimId) {
        public FinanceConfirmRequest(String remark) { this(remark, null); }
        public FinanceConfirmRequest(String remark,Long expectedRevision) { this(remark,expectedRevision,null); }
    }

    /** 驳回请求体（reason 必填：驳回要告诉销售"改什么"，空原因驳回 fail-closed）。 */
    public record FinanceRejectRequest(
            @NotBlank(message = "驳回原因不能为空")
            @Size(max = 500, message = "驳回原因不能超过 500 个字符") String reason,
            Long expectedRevision,UUID expectedClaimId) {
        public FinanceRejectRequest(String reason) { this(reason, null); }
        public FinanceRejectRequest(String reason,Long expectedRevision) { this(reason,expectedRevision,null); }
    }

    /** 原子批量确认：一次最多 100 个订单；重复 UUID 由服务层去重。 */
    public record FinanceBatchConfirmRequest(
            @NotEmpty(message = "请选择至少一笔销售订货单")
            @Size(max = MAX_BATCH_CONFIRM_ORDERS, message = "一次最多确认 100 笔销售订货单")
            List<@NotNull(message = "销售订货单 ID 不能为空") UUID> orderIds,
            @Size(max = 500, message = "确认备注不能超过 500 个字符") String remark,
            Map<UUID, Long> expectedRevisions,
            @Size(max=MAX_BATCH_CONFIRM_ORDERS) Map<UUID,UUID> expectedClaimIds) {
        public FinanceBatchConfirmRequest(List<UUID> orderIds, String remark) {
            this(orderIds, remark, Map.of());
        }
        public FinanceBatchConfirmRequest(List<UUID> orderIds,String remark,Map<UUID,Long> expectedRevisions) {
            this(orderIds,remark,expectedRevisions,Map.of());
        }
    }

    /** 批量确认结果；orderIds 为去重、排序后的完整受理集合。 */
    public record FinanceBatchConfirmResult(
            int requestedCount,
            int newlyConfirmedCount,
            int alreadyConfirmedCount,
            List<UUID> orderIds) {
    }

    /**
     * 待确认任务：已审（status=1）且未财务确认、未结案/中止/删除的订单，按交货日升序。
     *
     * @param rejected null=全部；false=仅未驳回（默认待办视图）；true=仅已驳回。
     */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_order_finance:view')")
    public PageResponse<SalesOrderFinancePendingDto> pending(
            int page, int size, Boolean rejected, String keyword) {
        return pending(page, size, rejected, keyword, null);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_order_finance:view')")
    public PageResponse<SalesOrderFinancePendingDto> pending(
            int page, int size, Boolean rejected, String keyword, Boolean changesOnly) {
        return pending(page, size, rejected, keyword, changesOnly, null, null, null);
    }

    /** 同上；2026-09-25 单号列统一：sort/order 表头排序（白名单，未知回落默认
     *  驳回沉底+交货日序）、billNo 销售单号表头值筛选（等值精确匹配，仅条件出现
     *  才绑定命名参数）。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_order_finance:view')")
    public PageResponse<SalesOrderFinancePendingDto> pending(
            int page, int size, Boolean rejected, String keyword, Boolean changesOnly,
            String sort, String order, String billNo) {
        int p = Math.max(1, page);
        int sz = Math.min(Math.max(1, size), 100);
        String rejectedFilter = rejected == null ? ""
                : rejected ? " AND o.finance_rejected = TRUE" : " AND o.finance_rejected = FALSE";
        String changesFilter = changesOnly == null ? ""
                : " AND " + (changesOnly ? "" : "NOT ") + "(" + pendingChangesExpression() + ")";
        String normalizedKeyword = keyword == null
                ? "" : keyword.trim().toLowerCase(Locale.ROOT);
        String keywordFilter = normalizedKeyword.isEmpty() ? "" : """
                  AND (
                    POSITION(:keyword IN LOWER(COALESCE(o.bill_no, ''))) > 0
                    OR POSITION(:keyword IN LOWER(COALESCE(c.name, ''))) > 0
                    OR POSITION(:keyword IN LOWER(COALESCE(e.full_name, ''))) > 0
                  )
                """;
        // 单号列值筛选（2026-09-25 单号列统一）：等值精确匹配；列表/计数同口径。
        String trimmedBillNo = billNo == null ? "" : billNo.trim();
        String billNoFilter = trimmedBillNo.isEmpty()
                ? "" : " AND COALESCE(o.bill_no, '') = :bill_no\n";
        var countQuery = em.createNativeQuery("""
                SELECT COUNT(*)
                FROM sales_orders o
                LEFT JOIN clients c ON c.id = o.client_id
                LEFT JOIN employees e ON e.id = o.seller_id
                WHERE o.status = 1 AND o.is_deleted = FALSE
                  AND (o.is_closed = FALSE OR o.finance_review_revision > 0) AND o.is_stopped = FALSE
                  AND o.finance_confirmed = FALSE
                """ + rejectedFilter + changesFilter + keywordFilter + billNoFilter);
        if (!normalizedKeyword.isEmpty()) {
            countQuery.setParameter("keyword", normalizedKeyword);
        }
        if (!trimmedBillNo.isEmpty()) {
            countQuery.setParameter("bill_no", trimmedBillNo);
        }
        long total = ((Number) countQuery.getSingleResult()).longValue();
        int totalPages = total == 0 ? 0 : (int) ((total + sz - 1) / sz);
        if (totalPages > 0 && p > totalPages) p = totalPages;
        var pendingQuery = em.createNativeQuery("""
                SELECT o.id, o.bill_no, o.bill_date,
                       COALESCE(c.name, ''), COALESCE(e.full_name, ''),
                       o.deliver_date,
                       (SELECT COUNT(*) FROM sales_order_items i
                        WHERE i.order_id = o.id AND i.is_deleted = FALSE),
                       o.total_original, COALESCE(cur.code, ''), COALESCE(cur.name, ''),
                       COALESCE(o.shipment_policy, ''),
                       o.client_id,
                       o.finance_rejected, o.finance_rejected_reason, o.finance_rejected_at,
                       (SELECT COUNT(*) FROM sales_order_qty_change_logs ch
                         WHERE ch.order_id = o.id
                           AND ch.changed_at > COALESCE(o.finance_confirmed_at,
                                                       to_timestamp(0))
                           AND NOT EXISTS (
                               SELECT 1 FROM sales_order_revision_logs snapshot
                               WHERE snapshot.order_id = ch.order_id
                                 AND snapshot.changed_at >= ch.changed_at
                                 AND (snapshot.before_snapshot -> '产品明细' -> ch.order_item_id::text
                                      ->> '数量')::numeric = ch.old_qty
                                 AND (snapshot.after_snapshot -> '产品明细' -> ch.order_item_id::text
                                      ->> '数量')::numeric = ch.new_qty))
                       + (SELECT COUNT(*) FROM sales_order_revision_logs revision
                          WHERE revision.order_id = o.id
                            AND revision.changed_at > COALESCE(o.finance_confirmed_at, to_timestamp(0))),
                       o.finance_review_revision,
                       """ + CLIENT_CREDIT_SQL + """
                       , o.currency_id
                       , source_quote.id, source_quote.bill_no,
                       COALESCE(quote_confirmer.full_name, ''), source_quote.finance_confirmed_at
                FROM sales_orders o
                LEFT JOIN sales_quotes source_quote ON source_quote.id = o.source_quote_id
                     AND source_quote.is_deleted = FALSE
                     AND source_quote.finance_confirmed_at IS NOT NULL
                LEFT JOIN employees quote_confirmer ON quote_confirmer.id = source_quote.finance_confirmed_by
                LEFT JOIN clients c ON c.id = o.client_id
                LEFT JOIN employees e ON e.id = o.seller_id
                LEFT JOIN currencies cur ON cur.id = o.currency_id
                WHERE o.status = 1 AND o.is_deleted = FALSE
                  AND (o.is_closed = FALSE OR o.finance_review_revision > 0) AND o.is_stopped = FALSE
                  AND o.finance_confirmed = FALSE
                """ + String.join("\n", rejectedFilter, changesFilter,
                        keywordFilter, billNoFilter, pendingOrderBy(sort, order),
                        "LIMIT :lim OFFSET :off"));
        if (!normalizedKeyword.isEmpty()) {
            pendingQuery.setParameter("keyword", normalizedKeyword);
        }
        if (!trimmedBillNo.isEmpty()) {
            pendingQuery.setParameter("bill_no", trimmedBillNo);
        }
        pendingQuery.setParameter("lim", sz);
        pendingQuery.setParameter("off", (p - 1) * sz);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = pendingQuery.getResultList();
        // 本页用到的客户一次取余额(不 N+1), 每行按自己订单的币种派生「客户应收」。
        PartyOpenBalances balances = rows.isEmpty() ? PartyOpenBalances.empty()
                : partyBalances.clients(rows.stream().map(r -> (UUID) r[11]).toList());
        Map<UUID, UUID> quoteByOrder = new java.util.LinkedHashMap<>();
        for (Object[] r : rows) {
            if (r[19] != null) quoteByOrder.put((UUID) r[0], (UUID) r[19]);
        }
        Map<UUID, Boolean> allLinesMatch = allLinesMatchByOrder(quoteByOrder);
        List<SalesOrderFinancePendingDto> out = rows.stream()
                .map(r -> new SalesOrderFinancePendingDto(
                        (UUID) r[0], (String) r[1],
                        com.uten.imp.common.util.NativeValueConverters.toLocalDate(r[2]),
                        (String) r[3], (String) r[4],
                        com.uten.imp.common.util.NativeValueConverters.toLocalDate(r[5]),
                        ((Number) r[6]).longValue(),
                        r[7] == null ? BigDecimal.ZERO : (BigDecimal) r[7],
                        (String) r[8],
                        (String) r[9],
                        (String) r[10],
                        balances.forDocument((UUID) r[11], (UUID) r[18],
                                configuredCreditLimit((BigDecimal) r[17])),
                        Boolean.TRUE.equals(r[12]),
                        (String) r[13],
                        com.uten.imp.common.util.NativeValueConverters.toOffsetDateTime(r[14]),
                        ((Number) r[15]).longValue(),
                        ((Number) r[16]).longValue(),
                        r[19] == null ? null : new SalesOrderFinanceReviewDto.SourceQuote(
                                (UUID) r[19], (String) r[20],
                                ((String) r[21]).isBlank() ? null : (String) r[21],
                                com.uten.imp.common.util.NativeValueConverters.toOffsetDateTime(r[22]),
                                Boolean.TRUE.equals(allLinesMatch.get((UUID) r[0]))),
                        r[19] == null ? null : Boolean.TRUE.equals(allLinesMatch.get((UUID) r[0]))))
                .toList();
        return new PageResponse<>(out, p, sz, total, totalPages);
    }

    /** 信用额度为空或不大于 0 = 未设置, 不判超信用(沿用 V300 口径)。 */
    private static BigDecimal configuredCreditLimit(BigDecimal credit) {
        return credit != null && credit.signum() > 0 ? credit : null;
    }

    static String pendingChangesExpression() {
        return """
                EXISTS(SELECT 1 FROM sales_order_revision_logs revision
                    WHERE revision.order_id = o.id
                      AND revision.changed_at > COALESCE(o.finance_confirmed_at, to_timestamp(0)))
                OR EXISTS(SELECT 1 FROM sales_order_qty_change_logs change_log
                    WHERE change_log.order_id = o.id
                      AND change_log.changed_at > COALESCE(o.finance_confirmed_at, to_timestamp(0)))
                """;
    }

    /** 排序 ORDER BY（2026-09-25 单号列统一）：白名单映射前端列 key→SQL 表达式；
     *  未知/空→默认（驳回沉底, 交货日升序, 单据日期/单号稳定序）。 */
    private static String pendingOrderBy(String sort, String order) {
        String dir = "desc".equalsIgnoreCase(order) ? "DESC" : "ASC";
        return switch (sort == null ? "" : sort) {
            case "billNo" -> "ORDER BY o.bill_no " + dir + " NULLS LAST,\n"
                    + "         o.finance_rejected ASC,\n"
                    + "         o.deliver_date NULLS LAST, o.bill_date\n";
            default -> """
                    ORDER BY o.finance_rejected ASC,
                             o.deliver_date NULLS LAST, o.bill_date, o.bill_no
                    """;
        };
    }

    /** 销售单号 facets（2026-09-25 单号列统一）：{billNo:[各销售单号]}——与列表/计数
     *  同一过滤基座（不含单号列自身值筛选），按销售单号分组计数、单号升序，上限 500 桶。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_order_finance:view')")
    public java.util.Map<String, java.util.List<java.util.Map<String, Object>>> pendingFacets(
            Boolean rejected, String keyword, Boolean changesOnly) {
        String rejectedFilter = rejected == null ? ""
                : rejected ? " AND o.finance_rejected = TRUE" : " AND o.finance_rejected = FALSE";
        String changesFilter = changesOnly == null ? ""
                : " AND " + (changesOnly ? "" : "NOT ") + "(" + pendingChangesExpression() + ")";
        String normalizedKeyword = keyword == null
                ? "" : keyword.trim().toLowerCase(Locale.ROOT);
        String keywordFilter = normalizedKeyword.isEmpty() ? "" : """
                  AND (
                    POSITION(:keyword IN LOWER(COALESCE(o.bill_no, ''))) > 0
                    OR POSITION(:keyword IN LOWER(COALESCE(c.name, ''))) > 0
                    OR POSITION(:keyword IN LOWER(COALESCE(e.full_name, ''))) > 0
                  )
                """;
        var query = em.createNativeQuery("""
                        SELECT COALESCE(o.bill_no, ''), COUNT(*)
                        FROM sales_orders o
                        LEFT JOIN clients c ON c.id = o.client_id
                        LEFT JOIN employees e ON e.id = o.seller_id
                        WHERE o.status = 1 AND o.is_deleted = FALSE
                          AND (o.is_closed = FALSE OR o.finance_review_revision > 0) AND o.is_stopped = FALSE
                          AND o.finance_confirmed = FALSE
                        """ + rejectedFilter + changesFilter + keywordFilter
                        + " GROUP BY 1 ORDER BY 1")
                .setMaxResults(500);
        if (!normalizedKeyword.isEmpty()) {
            query.setParameter("keyword", normalizedKeyword);
        }
        return java.util.Map.of("billNo", NativeFacets.rowsOf(query));
    }

    /** 待确认计数（财务工作台徽标）：只数未驳回的可办件，已驳回等销售修正不占徽标。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_order_finance:view')")
    public Map<String, Long> pendingCount() {
        return pendingCount(null);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_order_finance:view')")
    public Map<String, Long> pendingCount(Boolean changesOnly) {
        String changesFilter = changesOnly == null ? ""
                : " AND " + (changesOnly ? "" : "NOT ") + "(" + pendingChangesExpression() + ")";
        Number n = (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM sales_orders o
                WHERE o.status = 1 AND o.is_deleted = FALSE
                  AND (o.is_closed = FALSE OR o.finance_review_revision > 0) AND o.is_stopped = FALSE
                  AND o.finance_confirmed = FALSE AND o.finance_rejected = FALSE
                """ + changesFilter).getSingleResult();
        return Map.of("count", n.longValue());
    }

    /**
     * 财务审核详情（V300 专用审核页）：订单主表 + 明细 + 客户财务快照
     * （应收余额/信用额度/铺底额/超信用）。仅已审未结案订单可进入审核视图。
     */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_order_finance:view')")
    public SalesOrderFinanceReviewDto review(UUID orderId) {
        SalesOrder order = orderRepo.findById(orderId)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "销售订货单不存在"));
        if (order.isDeleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "销售订货单不存在或已删除");
        }
        Object[] h = (Object[]) em.createNativeQuery("""
                SELECT COALESCE(c.name, ''), COALESCE(c.code, ''),
                       COALESCE(e.full_name, ''), COALESCE(m.full_name, ''),
                       COALESCE(cur.code, ''), COALESCE(cur.name, ''),
                       COALESCE(sm.name, ''),
                       """ + CLIENT_CREDIT_SQL + """
                       , c.credit_floor,
                       COALESCE(fc.full_name, ''), COALESCE(fr.full_name, '')
                FROM sales_orders o
                LEFT JOIN clients c ON c.id = o.client_id
                LEFT JOIN employees e ON e.id = o.seller_id
                LEFT JOIN employees m ON m.id = o.maker_id
                LEFT JOIN currencies cur ON cur.id = o.currency_id
                LEFT JOIN settlement_methods sm ON sm.id = o.settlement_method_id
                LEFT JOIN employees fc ON fc.id = o.finance_confirmed_by
                LEFT JOIN employees fr ON fr.id = o.finance_rejected_by
                WHERE o.id = :id
                """)
                .setParameter("id", orderId)
                .getSingleResult();
        @SuppressWarnings("unchecked")
        List<Object[]> itemRows = em.createNativeQuery("""
                SELECT i.id, i.line_no,
                       COALESCE(i.goods_code_snapshot, g.code, ''),
                       COALESCE(i.goods_name_snapshot, g.name, ''),
                       COALESCE(col.name, ''), i.unit_id, COALESCE(u.name, ''),
                       COALESCE(i.client_model, ''),
                       i.qty, i.weight, i.price, i.discount, i.amount_original,
                       COALESCE(i.remark, ''),
                       i.client_goods_name, i.client_price,
                       i.goods_id, i.color_id, i.unit_rate
                FROM sales_order_items i
                LEFT JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors col ON col.id = i.color_id
                LEFT JOIN units u ON u.id = i.unit_id
                WHERE i.order_id = :id AND i.is_deleted = FALSE
                ORDER BY i.line_no NULLS LAST, i.id
                """)
                .setParameter("id", orderId)
                .getResultList();
        List<SalesOrderFinanceReviewDto.Line> lines = new ArrayList<>(itemRows.size());
        QuoteTrace quoteTrace = quoteTrace(order, itemRows);
        for (int rowIndex = 0; rowIndex < itemRows.size(); rowIndex++) {
            Object[] r = itemRows.get(rowIndex);
            SalesOrderService.TrustedQuotePriceBook.Terms quoted = quoteTrace == null ? null
                    : quoteTrace.match().terms().get(rowIndex);
            Boolean matchesQuote = quoteTrace == null ? null : quoteTrace.match().matches().get(rowIndex);
            lines.add(new SalesOrderFinanceReviewDto.Line(
                    (UUID) r[0],
                    r[1] == null ? null : ((Number) r[1]).intValue(),
                    (String) r[2], (String) r[3], (String) r[4],
                    (UUID) r[5], (String) r[6],
                    (String) r[7],
                    r[8] == null ? null : (BigDecimal) r[8],
                    r[9] == null ? null : (BigDecimal) r[9],
                    r[10] == null ? null : (BigDecimal) r[10],
                    r[11] == null ? null : (BigDecimal) r[11],
                    r[12] == null ? null : (BigDecimal) r[12],
                    (String) r[13],
                    (String) r[14],
                    r[15] == null ? null : (BigDecimal) r[15],
                    quoted == null ? null : quoted.price(),
                    quoted == null ? null : quoted.discount(),
                    matchesQuote));
        }
        @SuppressWarnings("unchecked")
        List<Object[]> changeRows = em.createNativeQuery("""
                SELECT ch.order_item_id,
                       COALESCE(i.goods_code_snapshot, g.code, ''),
                       COALESCE(i.goods_name_snapshot, g.name, ''),
                       COALESCE(col.name, ''), COALESCE(u.name, ''),
                       ch.old_qty, ch.new_qty,
                       COALESCE(emp.full_name, ''), ch.changed_at
                FROM sales_order_qty_change_logs ch
                JOIN sales_order_items i ON i.id = ch.order_item_id
                LEFT JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors col ON col.id = i.color_id
                LEFT JOIN units u ON u.id = i.unit_id
                LEFT JOIN employees emp ON emp.id = ch.changed_by_employee_id
                WHERE ch.order_id = :id
                  AND ch.changed_at > COALESCE(
                        (SELECT o2.finance_confirmed_at
                         FROM sales_orders o2 WHERE o2.id = :id),
                        to_timestamp(0))
                ORDER BY ch.changed_at DESC, ch.id
                """)
                .setParameter("id", orderId)
                .getResultList();
        List<SalesOrderFinanceReviewDto.QtyChange> qtyChanges = new ArrayList<>(changeRows.size());
        for (Object[] r : changeRows) {
            qtyChanges.add(new SalesOrderFinanceReviewDto.QtyChange(
                    (UUID) r[0],
                    (String) r[1], (String) r[2], (String) r[3], (String) r[4],
                    (BigDecimal) r[5], (BigDecimal) r[6],
                    (String) r[7],
                    com.uten.imp.common.util.NativeValueConverters.toOffsetDateTime(r[8])));
        }
        BigDecimal credit = (BigDecimal) h[7];
        BigDecimal creditFloor = (BigDecimal) h[8];
        // ADR-128: 客户应收按本单币种显示; 超信用 = 全币种正式应收账面本币毛额(不扣预收) > 信用额度,
        // 与出货财审同一口径, 由共用余额视图算一次。
        var clientBalance = partyBalances.clients(java.util.Collections.singletonList(order.getClientId()))
                .forDocument(order.getClientId(), order.getCurrencyId(), configuredCreditLimit(credit));
        return new SalesOrderFinanceReviewDto(
                order.getId(),
                order.getBillNo(),
                order.getBillDate(),
                order.getClientId(),
                (String) h[0], (String) h[1],
                (String) h[2], (String) h[3],
                order.getCreatedAt(),
                order.getDeliverDate(),
                (String) h[4],
                (String) h[5],
                order.getShipmentPolicy(),
                shipmentPolicyName(order.getShipmentPolicy()),
                (String) h[6],
                order.getContractNo(),
                order.getDeposit(),
                order.getRemark(),
                lines.size(),
                order.getTotalOriginal(),
                clientBalance,
                creditFloor,
                order.isFinanceConfirmed(),
                order.getFinanceConfirmedAt(),
                (String) h[9],
                order.getFinanceConfirmRemark(),
                order.isFinanceRejected(),
                order.getFinanceRejectedReason(),
                (String) h[10],
                order.getFinanceRejectedAt(),
                lines,
                qtyChanges,
                revisions.pendingChanges(orderId),
                order.getFinanceReviewRevision(),
                revisions.pendingDiff(orderId),
                quoteTrace == null ? null : new SalesOrderFinanceReviewDto.SourceQuote(
                        quoteTrace.quoteId(), quoteTrace.billNo(), quoteTrace.confirmedByName(),
                        quoteTrace.confirmedAt(), quoteTrace.match().allLinesMatch()),
                order.getClientFileCurrency(),
                quoteTrace == null ? null : quoteTrace.match().allLinesMatch());
    }

    /**
     * 报价转入订单的核价对照(ADR-134): 按订单保存时的同一配对规则把订单行对上来源报价行,
     * 财务可见每行报价核定的单价/折扣与是否一致; 价格已在报价上核定, 订单确认只需再核信用与条款。
     * 只有财务核价确认过的来源报价才有对照(旧流程直接审核的报价没有「报价核定」可比, 返回 null)。
     */
    private QuoteTrace quoteTrace(SalesOrder order, List<Object[]> itemRows) {
        if (order.getSourceQuoteId() == null) return null;
        @SuppressWarnings("unchecked")
        List<Object[]> header = em.createNativeQuery("""
                        SELECT q.bill_no, COALESCE(e.full_name, ''), q.finance_confirmed_at
                        FROM sales_quotes q
                        LEFT JOIN employees e ON e.id = q.finance_confirmed_by
                        WHERE q.id = :id AND q.is_deleted = FALSE AND q.finance_confirmed_at IS NOT NULL
                        """)
                .setParameter("id", order.getSourceQuoteId())
                .getResultList();
        if (header.isEmpty()) return null;
        Object[] h = header.getFirst();
        List<QuoteMatchLine> lines = itemRows.stream()
                .map(r -> new QuoteMatchLine(
                        r[1] == null ? null : ((Number) r[1]).intValue(),
                        (UUID) r[16], (UUID) r[17], (UUID) r[5],
                        r[18] == null ? null : (BigDecimal) r[18],
                        r[10] == null ? null : (BigDecimal) r[10],
                        r[11] == null ? null : (BigDecimal) r[11]))
                .toList();
        List<com.uten.imp.features.sales.quote.SalesQuoteItem> quoteItems =
                quoteItemsByQuote(List.of(order.getSourceQuoteId()))
                        .getOrDefault(order.getSourceQuoteId(), List.of());
        return new QuoteTrace(order.getSourceQuoteId(), (String) h[0],
                ((String) h[1]).isBlank() ? null : (String) h[1],
                com.uten.imp.common.util.NativeValueConverters.toOffsetDateTime(h[2]),
                matchQuote(quoteItems, (String) h[0], lines));
    }

    /**
     * 待确认列表一页里报价转入的订单: 每张订单的「每行单价与折扣都与报价核定一致」。与审核页同一规则
     * ({@link #matchQuote}), 一页只查两次(订单明细 + 来源报价明细)。
     */
    private Map<UUID, Boolean> allLinesMatchByOrder(Map<UUID, UUID> quoteByOrder) {
        if (quoteByOrder.isEmpty()) return Map.of();
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT i.order_id, i.line_no, i.goods_id, i.color_id, i.unit_id, i.unit_rate,
                               i.price, i.discount
                        FROM sales_order_items i
                        WHERE i.order_id IN (:ids) AND i.is_deleted = FALSE
                        ORDER BY i.order_id, i.line_no NULLS LAST, i.id
                        """)
                .setParameter("ids", List.copyOf(quoteByOrder.keySet()))
                .getResultList();
        Map<UUID, List<QuoteMatchLine>> linesByOrder = new HashMap<>();
        for (Object[] r : rows) {
            linesByOrder.computeIfAbsent((UUID) r[0], ignored -> new ArrayList<>()).add(new QuoteMatchLine(
                    r[1] == null ? null : ((Number) r[1]).intValue(),
                    (UUID) r[2], (UUID) r[3], (UUID) r[4],
                    (BigDecimal) r[5], (BigDecimal) r[6], (BigDecimal) r[7]));
        }
        Map<UUID, List<com.uten.imp.features.sales.quote.SalesQuoteItem>> quoteItems =
                quoteItemsByQuote(quoteByOrder.values());
        Map<UUID, Boolean> result = new HashMap<>();
        quoteByOrder.forEach((orderId, quoteId) -> result.put(orderId, matchQuote(
                quoteItems.getOrDefault(quoteId, List.of()), null,
                linesByOrder.getOrDefault(orderId, List.of())).allLinesMatch()));
        return result;
    }

    /** 来源报价明细(按报价分组, 行号 + id 稳定排序; 审核页与列表共用, 保证配对顺序一致)。 */
    private Map<UUID, List<com.uten.imp.features.sales.quote.SalesQuoteItem>> quoteItemsByQuote(
            java.util.Collection<UUID> quoteIds) {
        Map<UUID, List<com.uten.imp.features.sales.quote.SalesQuoteItem>> out = new HashMap<>();
        if (quoteIds.isEmpty()) return out;
        em.createQuery("""
                        SELECT i FROM SalesQuoteItem i
                        WHERE i.quoteId IN :ids
                        ORDER BY i.quoteId, i.lineNo, i.id
                        """, com.uten.imp.features.sales.quote.SalesQuoteItem.class)
                .setParameter("ids", java.util.Set.copyOf(quoteIds))
                .getResultList()
                .forEach(item -> out.computeIfAbsent(item.getQuoteId(), ignored -> new ArrayList<>()).add(item));
        return out;
    }

    /** 一行订单明细的配对键与单价/折扣(对照来源报价用)。 */
    record QuoteMatchLine(Integer lineNo, UUID goodsId, UUID colorId, UUID unitId, BigDecimal unitRate,
                          BigDecimal price, BigDecimal discount) {
    }

    /** 对照结果: 逐行配上的报价条款(没配上为 null)、逐行是否一致、是否全部一致。 */
    record QuoteMatch(List<SalesOrderService.TrustedQuotePriceBook.Terms> terms, List<Boolean> matches,
                      boolean allLinesMatch) {
    }

    /**
     * 订单行对照来源报价(审核页与待确认列表同一规则): 按订单保存时的配对规则(先行号 + 商业身份精确配, 再按商业
     * 身份兜底; 商业身份含换算率; 每条报价行只配一次)配上报价行, 单价和折扣都相同才算一致; 报价外多出来的行不一致。
     */
    static QuoteMatch matchQuote(List<com.uten.imp.features.sales.quote.SalesQuoteItem> quoteItems,
                                 String quoteBillNo, List<QuoteMatchLine> lines) {
        SalesOrderService.TrustedQuotePriceBook book =
                new SalesOrderService.TrustedQuotePriceBook(quoteItems, quoteBillNo, false);
        List<SalesOrderService.TrustedQuotePriceBook.Terms> terms = book.assignKeys(lines.stream()
                .map(line -> new SalesOrderService.TrustedQuotePriceBook.LineKey(
                        line.lineNo(), line.goodsId(), line.colorId(), line.unitId(), line.unitRate()))
                .toList(), false);
        List<Boolean> matches = new ArrayList<>(lines.size());
        for (int index = 0; index < lines.size(); index++) {
            SalesOrderService.TrustedQuotePriceBook.Terms quoted = terms.get(index);
            QuoteMatchLine line = lines.get(index);
            BigDecimal discount = comparableDiscount(line.discount());
            matches.add(quoted != null && line.price() != null && discount != null
                    && quoted.price().compareTo(line.price()) == 0
                    && quoted.discount().compareTo(discount) == 0);
        }
        return new QuoteMatch(terms, matches, matches.stream().allMatch(Boolean::booleanValue));
    }

    /** 订单行折扣按保存口径归一(空/0 = 1); 历史脏值(超出 0~1 或多于 4 位)算不一致, 不让列表报错。 */
    private static BigDecimal comparableDiscount(BigDecimal discount) {
        try {
            return SalesOrderService.normalizeOrderDiscountForWrite(discount);
        } catch (ApiException invalid) {
            return null;
        }
    }

    private record QuoteTrace(UUID quoteId, String billNo, String confirmedByName,
                              OffsetDateTime confirmedAt, QuoteMatch match) {
    }

    /**
     * 财务确认：status=1 且未确认才受理（重复确认静默幂等返回）。确认后订单对计划部可见，
     * 并旁路通知计划员接手物料分析（同事务 outbox，提交后才发送）。
     * 当前驳回标志由销售修订后的重新审核清除；最后一次驳回事实保留供时间线展示。
     */
    @Transactional
    @PreAuthorize("hasAuthority('sales_order_finance:view')"
            + " and hasAuthority('sales_order_finance:confirm')")
    public void confirm(UUID orderId, FinanceConfirmRequest request) {
        tx.bind();
        requireEligibleConfirmer();
        SalesOrder order = requireDecisionOrderForUpdate(orderId);
        requireReviewRevision(order, request == null ? null : request.expectedRevision());
        requireConfirmable(order);
        if (order.isFinanceConfirmed()) {
            return; // 幂等：已确认静默成功
        }
        taskClaim.requireActiveClaimByMe("SALES_ORDER_FINANCE_CONFIRM",orderId.toString(),request==null ? null : request.expectedClaimId());
        UUID actor = currentUser.requireEmployeeId();
        String remark = normalizeConfirmRemark(request == null ? null : request.remark());
        applyConfirmation(order, actor, OffsetDateTime.now(), remark);
        orderRepo.save(order);
        chainNotice.notifyOrderFinanceConfirmed(orderId);
        // V459 办结撤回：确认完成，全部接收人的待审弹卡与收件台计数清零。
        chainNotice.resolveReviewNotices("SALES_ORDER", orderId, "FINANCE_CONFIRMED");
        taskClaim.release("SALES_ORDER_FINANCE_CONFIRM", orderId.toString());
    }

    /**
     * 原子批量财务确认：按 UUID 固定顺序锁住全部订单，先校验完整集合，再统一写入。
     * 任一订单不可确认时整个事务失败；已确认且仍处于合法已审在途态的订单幂等跳过。
     */
    @Transactional
    @PreAuthorize("hasAuthority('sales_order_finance:view')"
            + " and hasAuthority('sales_order_finance:confirm')")
    public FinanceBatchConfirmResult confirmBatch(FinanceBatchConfirmRequest request) {
        tx.bind();
        requireEligibleConfirmer();
        NormalizedBatchConfirm normalized = normalizeBatchConfirm(request);

        List<SalesOrder> lockedOrders = new ArrayList<>(normalized.orderIds().size());
        for (UUID orderId : normalized.orderIds()) {
            lockedOrders.add(requireDecisionOrderForUpdate(orderId));
        }
        for (SalesOrder order : lockedOrders) {
            requireReviewRevision(order, request.expectedRevisions() == null
                    ? null : request.expectedRevisions().get(order.getId()));
            requireConfirmable(order);
        }
        taskClaim.requireActiveClaimsByMe("SALES_ORDER_FINANCE_CONFIRM",lockedOrders.stream()
                .filter(order -> !order.isFinanceConfirmed())
                .map(order -> new com.uten.imp.application.port.TaskClaimMutationGuardPort.ClaimExpectation(order.getId().toString(),
                        request.expectedClaimIds()==null ? null : request.expectedClaimIds().get(order.getId()))).toList());

        UUID actor = currentUser.requireEmployeeId();
        OffsetDateTime confirmedAt = OffsetDateTime.now();
        int alreadyConfirmed = 0;
        int newlyConfirmed = 0;
        for (SalesOrder order : lockedOrders) {
            if (order.isFinanceConfirmed()) {
                alreadyConfirmed++;
                continue;
            }
            applyConfirmation(order, actor, confirmedAt, normalized.remark());
            orderRepo.save(order);
            chainNotice.notifyOrderFinanceConfirmed(order.getId());
            chainNotice.resolveReviewNotices(
                    "SALES_ORDER", order.getId(), "FINANCE_CONFIRMED");
            taskClaim.release("SALES_ORDER_FINANCE_CONFIRM", order.getId().toString());
            newlyConfirmed++;
        }
        return new FinanceBatchConfirmResult(
                normalized.orderIds().size(),
                newlyConfirmed,
                alreadyConfirmed,
                normalized.orderIds());
    }

    /**
     * 财务驳回（V300）：订单仍保持已审状态与库存预留，仅记录驳回事实+原因，
     * 并通知归属销售修正；相同驳回请求幂等，异原因的陈旧重放拒绝覆盖。
     */
    @Transactional
    @PreAuthorize("hasAuthority('sales_order_finance:view')"
            + " and hasAuthority('sales_order_finance:confirm')")
    public void reject(UUID orderId, FinanceRejectRequest request) {
        tx.bind();
        requireEligibleConfirmer();
        SalesOrder order = requireDecisionOrderForUpdate(orderId);
        requireReviewRevision(order, request == null ? null : request.expectedRevision());
        if (order.getStatus() == null || order.getStatus() != 1) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核的销售订货单可做财务驳回");
        }
        if ((order.isClosed() && order.getFinanceReviewRevision() == 0) || order.isStopped()) {
            throw new ApiException(ErrorCode.BUSINESS, "已结案或已中止的订单无需财务驳回");
        }
        if (order.isFinanceConfirmed()) {
            throw new ApiException(ErrorCode.BUSINESS, "该订单已财务确认，不能驳回");
        }
        String reason = request == null || request.reason() == null
                ? "" : request.reason().trim();
        if (reason.isEmpty() || reason.length() > 500) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "驳回原因不能为空且不能超过 500 个字符");
        }
        if (order.isFinanceRejected()) {
            if (reason.equals(order.getFinanceRejectedReason())) {
                return; // 同一决策重放幂等，不刷新人员/时间，也不重复投递通知。
            }
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "该订单已被驳回，不能用陈旧页面覆盖驳回原因，请刷新后重试");
        }
        taskClaim.requireActiveClaimByMe("SALES_ORDER_FINANCE_CONFIRM",orderId.toString(),request.expectedClaimId());
        if (order.getFinanceConfirmedAt() == null) {
            requireNoShipmentWorkForRejection(orderId);
        }
        order.setFinanceRejected(true);
        order.setFinanceRejectedReason(reason);
        order.setFinanceRejectedBy(currentUser.requireEmployeeId());
        order.setFinanceRejectedAt(OffsetDateTime.now());
        orderRepo.save(order);
        chainNotice.notifyOrderFinanceRejected(orderId, reason);
        // V459 办结撤回：驳回同样是办结（销售收到的下一条通知是驳回修正指引）。
        chainNotice.resolveReviewNotices("SALES_ORDER", orderId, "FINANCE_REJECTED");
        taskClaim.release("SALES_ORDER_FINANCE_CONFIRM", orderId.toString());
    }

    private SalesOrder requireDecisionOrderForUpdate(UUID orderId) {
        SalesOrder order = orderRepo.findActiveByIdForUpdate(orderId)
                .orElseThrow(() -> new ApiException(
                        ErrorCode.NOT_FOUND, "销售订货单不存在"));
        return order;
    }

    private void requireConfirmable(SalesOrder order) {
        if (order.getStatus() == null || order.getStatus() != 1) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核的销售订货单可做财务确认");
        }
        if ((order.isClosed() && order.getFinanceReviewRevision() == 0) || order.isStopped()) {
            throw new ApiException(ErrorCode.BUSINESS, "已结案或已中止的订单无需财务确认");
        }
        if (order.isFinanceRejected()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "订单已被财务驳回，须由销售修订并重新审核后再确认");
        }
    }

    private static void requireReviewRevision(SalesOrder order, Long expectedRevision) {
        // Revision zero accepts historical clients. Once commercial content changes,
        // every decision must identify the exact version actually shown to finance.
        if ((expectedRevision == null && order.getFinanceReviewRevision() != 0)
                || (expectedRevision != null && expectedRevision != order.getFinanceReviewRevision())) {
            throw new ApiException(ErrorCode.CONFLICT, "销售订单内容已修改，请刷新并核对修改清单后重新审核");
        }
    }

    private static void applyConfirmation(
            SalesOrder order, UUID actor, OffsetDateTime confirmedAt, String remark) {
        order.setFinanceConfirmed(true);
        order.setFinanceConfirmedAt(confirmedAt);
        order.setFinanceConfirmedBy(actor);
        order.setFinanceConfirmRemark(remark);
        // 当前态已在销售重新审核时清除。历史原因/人员/时间保留给业务时间线。
        order.setFinanceRejected(false);
    }

    private static NormalizedBatchConfirm normalizeBatchConfirm(
            FinanceBatchConfirmRequest request) {
        if (request == null || request.orderIds() == null
                || request.orderIds().isEmpty()) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED, "请选择至少一笔销售订货单");
        }
        if (request.orderIds().size() > MAX_BATCH_CONFIRM_ORDERS) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED, "一次最多确认 100 笔销售订货单");
        }
        if (request.orderIds().stream().anyMatch(java.util.Objects::isNull)) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED, "销售订货单 ID 不能为空");
        }
        List<UUID> orderIds = request.orderIds().stream()
                .distinct()
                // Match PostgreSQL UUID order and TaskClaimService's commercial-header order;
                // UUID.compareTo uses signed longs and puts ffffffff before 00000000.
                .sorted(java.util.Comparator.comparing(UUID::toString))
                .toList();
        return new NormalizedBatchConfirm(
                orderIds, normalizeConfirmRemark(request.remark()));
    }

    private static String normalizeConfirmRemark(String remark) {
        if (remark == null || remark.isBlank()) {
            return null;
        }
        if (remark.length() > 500) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED, "确认备注不能超过 500 个字符");
        }
        return remark.trim();
    }

    private record NormalizedBatchConfirm(List<UUID> orderIds, String remark) {
    }

    /**
     * 财务驳回必须发生在仓库接手前。订单头写锁与出货建单的头/行锁共同关闭
     * “一边驳回、一边创建待拣货单”的竞态窗口。
     */
    private void requireNoShipmentWorkForRejection(UUID orderId) {
        long count = ((Number) em.createNativeQuery("""
                SELECT COUNT(*)
                FROM sales_shipment_items shipment_item
                JOIN sales_shipments shipment
                  ON shipment.id = shipment_item.shipment_id
                JOIN sales_order_items order_item
                  ON order_item.id = shipment_item.order_item_id
                WHERE order_item.order_id = :orderId
                  AND COALESCE(order_item.is_deleted, FALSE) = FALSE
                  AND COALESCE(shipment_item.is_deleted, FALSE) = FALSE
                  AND COALESCE(shipment.is_deleted, FALSE) = FALSE
                """)
                .setParameter("orderId", orderId)
                .getSingleResult()).longValue();
        if (count > 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "订单已有出货作业，须先撤销相关出货单后才能财务驳回");
        }
    }

    /** 确认人资格：财务部门树在职 + 账号启用 + 持有 sales_order_finance:confirm（ADR-027 同型）。 */
    private void requireEligibleConfirmer() {
        if (!confirmerEligibility.isEligible(currentUser.requireId())) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "仅财务部门在职且持有 sales_order_finance:confirm 的人员可确认");
        }
    }

    /** 发运策略显示名（审核详情用；与 Flutter salesShipmentPolicyLabel 同文案，服务端自持避免前端跨模块依赖）。 */
    private static String shipmentPolicyName(String policy) {
        if (policy == null || policy.isBlank()) return "未选";
        return switch (policy) {
            case SalesOrder.SHIPMENT_POLICY_ALLOW_PARTIAL -> "允许分批发货";
            case SalesOrder.SHIPMENT_POLICY_REQUIRE_COMPLETE -> "整单齐套后发货";
            case SalesOrder.SHIPMENT_POLICY_CUSTOMER_CONFIRM -> "客户确认后分批";
            case SalesOrder.SHIPMENT_POLICY_LEGACY -> "历史订单(未指定)";
            default -> "未知策略(" + policy + ")";
        };
    }
}
