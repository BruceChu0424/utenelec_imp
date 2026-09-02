package com.uten.imp.features.sales.order;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
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

    /** 确认请求体（remark 可选；确认即放行计划部可见性，幂等由服务层状态前置保证）。 */
    public record FinanceConfirmRequest(
            @Size(max = 500, message = "确认备注不能超过 500 个字符") String remark) {
    }

    /** 驳回请求体（reason 必填：驳回要告诉销售"改什么"，空原因驳回 fail-closed）。 */
    public record FinanceRejectRequest(
            @NotBlank(message = "驳回原因不能为空")
            @Size(max = 500, message = "驳回原因不能超过 500 个字符") String reason) {
    }

    /** 原子批量确认：一次最多 100 个订单；重复 UUID 由服务层去重。 */
    public record FinanceBatchConfirmRequest(
            @NotEmpty(message = "请选择至少一笔销售订货单")
            @Size(max = MAX_BATCH_CONFIRM_ORDERS, message = "一次最多确认 100 笔销售订货单")
            List<@NotNull(message = "销售订货单 ID 不能为空") UUID> orderIds,
            @Size(max = 500, message = "确认备注不能超过 500 个字符") String remark) {
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
        int p = Math.max(1, page);
        int sz = Math.min(Math.max(1, size), 100);
        String rejectedFilter = rejected == null ? ""
                : rejected ? " AND o.finance_rejected = TRUE" : " AND o.finance_rejected = FALSE";
        String normalizedKeyword = keyword == null
                ? "" : keyword.trim().toLowerCase(Locale.ROOT);
        String keywordFilter = normalizedKeyword.isEmpty() ? "" : """
                  AND (
                    POSITION(:keyword IN LOWER(COALESCE(o.bill_no, ''))) > 0
                    OR POSITION(:keyword IN LOWER(COALESCE(c.name, ''))) > 0
                    OR POSITION(:keyword IN LOWER(COALESCE(e.full_name, ''))) > 0
                  )
                """;
        var countQuery = em.createNativeQuery("""
                SELECT COUNT(*)
                FROM sales_orders o
                LEFT JOIN clients c ON c.id = o.client_id
                LEFT JOIN employees e ON e.id = o.seller_id
                WHERE o.status = 1 AND o.is_deleted = FALSE
                  AND o.is_closed = FALSE AND o.is_stopped = FALSE
                  AND o.finance_confirmed = FALSE
                """ + rejectedFilter + keywordFilter);
        if (!normalizedKeyword.isEmpty()) {
            countQuery.setParameter("keyword", normalizedKeyword);
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
                       COALESCE(ar.bal, 0),
                       o.finance_rejected, o.finance_rejected_reason, o.finance_rejected_at
                FROM sales_orders o
                LEFT JOIN clients c ON c.id = o.client_id
                LEFT JOIN employees e ON e.id = o.seller_id
                LEFT JOIN currencies cur ON cur.id = o.currency_id
                LEFT JOIN (SELECT client_id, SUM(amount_balance) AS bal
                           FROM ar_ap_ledger
                           WHERE direction = 'AR' AND is_deleted = FALSE AND status = 1
                           GROUP BY client_id) ar ON ar.client_id = o.client_id
                WHERE o.status = 1 AND o.is_deleted = FALSE
                  AND o.is_closed = FALSE AND o.is_stopped = FALSE
                  AND o.finance_confirmed = FALSE
                """ + rejectedFilter + keywordFilter + """

                ORDER BY o.finance_rejected ASC,
                         o.deliver_date NULLS LAST, o.bill_date, o.bill_no
                LIMIT :lim OFFSET :off
                """);
        if (!normalizedKeyword.isEmpty()) {
            pendingQuery.setParameter("keyword", normalizedKeyword);
        }
        pendingQuery.setParameter("lim", sz);
        pendingQuery.setParameter("off", (p - 1) * sz);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = pendingQuery.getResultList();
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
                        r[11] == null ? BigDecimal.ZERO : (BigDecimal) r[11],
                        Boolean.TRUE.equals(r[12]),
                        (String) r[13],
                        com.uten.imp.common.util.NativeValueConverters.toOffsetDateTime(r[14])))
                .toList();
        return new PageResponse<>(out, p, sz, total, totalPages);
    }

    /** 待确认计数（财务工作台徽标）：只数未驳回的可办件，已驳回等销售修正不占徽标。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_order_finance:view')")
    public Map<String, Long> pendingCount() {
        Number n = (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM sales_orders o
                WHERE o.status = 1 AND o.is_deleted = FALSE
                  AND o.is_closed = FALSE AND o.is_stopped = FALSE
                  AND o.finance_confirmed = FALSE AND o.finance_rejected = FALSE
                """).getSingleResult();
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
                       COALESCE(ar.bal, 0),
                       CASE WHEN c.legacy_id IS NULL THEN c.credit ELSE NULL END,
                       c.credit_floor,
                       COALESCE(fc.full_name, ''), COALESCE(fr.full_name, '')
                FROM sales_orders o
                LEFT JOIN clients c ON c.id = o.client_id
                LEFT JOIN employees e ON e.id = o.seller_id
                LEFT JOIN employees m ON m.id = o.maker_id
                LEFT JOIN currencies cur ON cur.id = o.currency_id
                LEFT JOIN settlement_methods sm ON sm.id = o.settlement_method_id
                LEFT JOIN (SELECT client_id, SUM(amount_balance) AS bal
                           FROM ar_ap_ledger
                           WHERE direction = 'AR' AND is_deleted = FALSE AND status = 1
                           GROUP BY client_id) ar ON ar.client_id = o.client_id
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
                       COALESCE(col.name, ''), COALESCE(u.name, ''),
                       COALESCE(i.client_model, ''),
                       i.qty, i.weight, i.price, i.discount, i.amount_original,
                       COALESCE(i.remark, '')
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
        for (Object[] r : itemRows) {
            lines.add(new SalesOrderFinanceReviewDto.Line(
                    (UUID) r[0],
                    r[1] == null ? null : ((Number) r[1]).intValue(),
                    (String) r[2], (String) r[3], (String) r[4], (String) r[5],
                    (String) r[6],
                    r[7] == null ? null : (BigDecimal) r[7],
                    r[8] == null ? null : (BigDecimal) r[8],
                    r[9] == null ? null : (BigDecimal) r[9],
                    r[10] == null ? null : (BigDecimal) r[10],
                    r[11] == null ? null : (BigDecimal) r[11],
                    (String) r[12]));
        }
        BigDecimal outstanding = h[7] == null ? BigDecimal.ZERO : (BigDecimal) h[7];
        BigDecimal credit = (BigDecimal) h[8];
        BigDecimal creditFloor = (BigDecimal) h[9];
        boolean overCredit = credit != null && credit.signum() > 0
                && outstanding.compareTo(credit) > 0;
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
                outstanding,
                credit,
                creditFloor,
                overCredit,
                order.isFinanceConfirmed(),
                order.getFinanceConfirmedAt(),
                (String) h[10],
                order.getFinanceConfirmRemark(),
                order.isFinanceRejected(),
                order.getFinanceRejectedReason(),
                (String) h[11],
                order.getFinanceRejectedAt(),
                lines);
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
        requireConfirmable(order);
        if (order.isFinanceConfirmed()) {
            return; // 幂等：已确认静默成功
        }
        UUID actor = currentUser.requireEmployeeId();
        String remark = normalizeConfirmRemark(request == null ? null : request.remark());
        applyConfirmation(order, actor, OffsetDateTime.now(), remark);
        orderRepo.save(order);
        chainNotice.notifyOrderFinanceConfirmed(orderId);
        // V459 办结撤回：确认完成，全部接收人的待审弹卡与收件台计数清零。
        chainNotice.resolveReviewNotices("SALES_ORDER", orderId, "FINANCE_CONFIRMED");
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
            requireConfirmable(order);
        }

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
        if (order.getStatus() == null || order.getStatus() != 1) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核的销售订货单可做财务驳回");
        }
        if (order.isClosed() || order.isStopped()) {
            throw new ApiException(ErrorCode.BUSINESS, "已结案或已中止的订单无需财务驳回");
        }
        if (order.isFinanceConfirmed()) {
            throw new ApiException(ErrorCode.BUSINESS, "该订单已财务确认，不能驳回");
        }
        String reason = request == null || request.reason() == null
                ? "" : request.reason().trim();
        if (reason.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "驳回原因不能为空");
        }
        if (order.isFinanceRejected()) {
            if (reason.equals(order.getFinanceRejectedReason())) {
                return; // 同一决策重放幂等，不刷新人员/时间，也不重复投递通知。
            }
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "该订单已被驳回，不能用陈旧页面覆盖驳回原因，请刷新后重试");
        }
        requireNoShipmentWorkForRejection(orderId);
        order.setFinanceRejected(true);
        order.setFinanceRejectedReason(reason);
        order.setFinanceRejectedBy(currentUser.requireEmployeeId());
        order.setFinanceRejectedAt(OffsetDateTime.now());
        orderRepo.save(order);
        chainNotice.notifyOrderFinanceRejected(orderId, reason);
        // V459 办结撤回：驳回同样是办结（销售收到的下一条通知是驳回修正指引）。
        chainNotice.resolveReviewNotices("SALES_ORDER", orderId, "FINANCE_REJECTED");
    }

    private SalesOrder requireDecisionOrderForUpdate(UUID orderId) {
        return orderRepo.findActiveByIdForUpdate(orderId)
                .orElseThrow(() -> new ApiException(
                        ErrorCode.NOT_FOUND, "销售订货单不存在"));
    }

    private void requireConfirmable(SalesOrder order) {
        if (order.getStatus() == null || order.getStatus() != 1) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核的销售订货单可做财务确认");
        }
        if (order.isClosed() || order.isStopped()) {
            throw new ApiException(ErrorCode.BUSINESS, "已结案或已中止的订单无需财务确认");
        }
        if (order.isFinanceRejected()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "订单已被财务驳回，须由销售修订并重新审核后再确认");
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
                .sorted()
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
