package com.uten.imp.features.sales.order;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.features.sales.order.dto.SalesOrderFinancePendingDto;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.validation.constraints.Size;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 销售订货单「财务确认」（V294 业务链闸门）。
 *
 * <p>流程：销售审核（库存检查+软预留照旧）→ <b>财务确认</b> → 计划部接收
 * （物料分析/待排产/MRP/计划关联全部以 {@code finance_confirmed = TRUE} 为准入）。
 * 确认人资格镜像 ADR-027 审核组模型：财务部门（DEPT_FIN）子树在职员工、账号启用，
 * 且持有 {@code sales_order_finance:confirm}（含个人加授）；权限可在权限设置中调整。
 *
 * <p>确认只放行计划可见性，不动库存、不立账；确认后订单红冲/取消规则不变。
 */
@Service
@RequiredArgsConstructor
public class SalesOrderFinanceConfirmService {

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

    /** 待确认任务：已审（status=1）且未财务确认、未结案/中止/删除的订单，按交货日升序。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_order_finance:view')")
    public PageResponse<SalesOrderFinancePendingDto> pending(int page, int size) {
        int p = Math.max(1, page);
        int sz = Math.min(Math.max(1, size), 100);
        long total = ((Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM sales_orders o
                WHERE o.status = 1 AND o.is_deleted = FALSE
                  AND o.is_closed = FALSE AND o.is_stopped = FALSE
                  AND o.finance_confirmed = FALSE
                """).getSingleResult()).longValue();
        int totalPages = total == 0 ? 0 : (int) ((total + sz - 1) / sz);
        if (totalPages > 0 && p > totalPages) p = totalPages;
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT o.id, o.bill_no, o.bill_date,
                       COALESCE(c.name, ''), COALESCE(e.full_name, ''),
                       o.deliver_date,
                       (SELECT COUNT(*) FROM sales_order_items i
                        WHERE i.order_id = o.id AND i.is_deleted = FALSE),
                       o.total_original, COALESCE(cur.code, '')
                FROM sales_orders o
                LEFT JOIN clients c ON c.id = o.client_id
                LEFT JOIN employees e ON e.id = o.seller_id
                LEFT JOIN currencies cur ON cur.id = o.currency_id
                WHERE o.status = 1 AND o.is_deleted = FALSE
                  AND o.is_closed = FALSE AND o.is_stopped = FALSE
                  AND o.finance_confirmed = FALSE
                ORDER BY o.deliver_date NULLS LAST, o.bill_date, o.bill_no
                LIMIT :lim OFFSET :off
                """)
                .setParameter("lim", sz)
                .setParameter("off", (p - 1) * sz)
                .getResultList();
        List<SalesOrderFinancePendingDto> out = rows.stream()
                .map(r -> new SalesOrderFinancePendingDto(
                        (UUID) r[0], (String) r[1],
                        com.uten.imp.common.util.NativeValueConverters.toLocalDate(r[2]),
                        (String) r[3], (String) r[4],
                        com.uten.imp.common.util.NativeValueConverters.toLocalDate(r[5]),
                        ((Number) r[6]).longValue(),
                        r[7] == null ? BigDecimal.ZERO : (BigDecimal) r[7],
                        (String) r[8]))
                .toList();
        return new PageResponse<>(out, p, sz, total, totalPages);
    }

    /** 待确认计数（财务工作台徽标）。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_order_finance:view')")
    public Map<String, Long> pendingCount() {
        Number n = (Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM sales_orders o
                WHERE o.status = 1 AND o.is_deleted = FALSE
                  AND o.is_closed = FALSE AND o.is_stopped = FALSE
                  AND o.finance_confirmed = FALSE
                """).getSingleResult();
        return Map.of("count", n.longValue());
    }

    /**
     * 财务确认：status=1 且未确认才受理（重复确认静默幂等返回）。确认后订单对计划部可见，
     * 并旁路通知计划员接手物料分析（同事务 outbox，提交后才发送）。
     */
    @Transactional
    @PreAuthorize("hasAuthority('sales_order_finance:view')"
            + " and hasAuthority('sales_order_finance:confirm')")
    public void confirm(UUID orderId, FinanceConfirmRequest request) {
        tx.bind();
        requireEligibleConfirmer();
        SalesOrder order = orderRepo.findById(orderId)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "销售订货单不存在"));
        if (order.isDeleted() || order.getStatus() == null || order.getStatus() != 1) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核的销售订货单可做财务确认");
        }
        if (order.isClosed() || order.isStopped()) {
            throw new ApiException(ErrorCode.BUSINESS, "已结案或已中止的订单无需财务确认");
        }
        if (order.isFinanceConfirmed()) {
            return; // 幂等：已确认静默成功
        }
        UUID actor = currentUser.requireEmployeeId();
        order.setFinanceConfirmed(true);
        order.setFinanceConfirmedAt(OffsetDateTime.now());
        order.setFinanceConfirmedBy(actor);
        String remark = request == null ? null : request.remark();
        order.setFinanceConfirmRemark(remark == null || remark.isBlank() ? null : remark.trim());
        orderRepo.save(order);
        chainNotice.notifyOrderFinanceConfirmed(orderId);
    }

    /** 确认人资格：财务部门树在职 + 账号启用 + 持有 sales_order_finance:confirm（ADR-027 同型）。 */
    private void requireEligibleConfirmer() {
        if (!confirmerEligibility.isEligible(currentUser.requireId())) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "仅财务部门在职且持有 sales_order_finance:confirm 的人员可确认");
        }
    }
}
