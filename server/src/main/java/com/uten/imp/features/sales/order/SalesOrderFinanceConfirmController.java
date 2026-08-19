package com.uten.imp.features.sales.order;

import com.uten.imp.common.web.PageResponse;

import com.uten.imp.features.sales.order.dto.SalesOrderFinancePendingDto;
import com.uten.imp.features.sales.order.dto.SalesOrderFinanceReviewDto;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;
import java.util.UUID;

/**
 * 销售订货单「财务确认」API（V294 业务链闸门，V300 补审核详情与驳回）。
 *
 * <ul>
 *   <li>GET  /api/sales/orders/finance-confirmation/pending?rejected= → 待确认任务列表
 *       （rejected 缺省=仅未驳回待办；true=已驳回；all=全部）</li>
 *   <li>GET  /api/sales/orders/finance-confirmation/count → 待确认计数（工作台徽标，不含已驳回）</li>
 *   <li>GET  /api/sales/orders/{id}/finance-confirmation/review → 财务审核详情
 *       （订单全量信息 + 客户财务快照：应收余额/信用额度/超信用）</li>
 *   <li>POST /api/sales/orders/{id}/finance-confirmation → 财务确认（确认后放行计划部）</li>
 *   <li>POST /api/sales/orders/{id}/finance-confirmation/reject → 财务驳回（必填原因，
 *       不改订单状态/预留，通知归属销售修正）</li>
 * </ul>
 *
 * <p>确认人资格（财务部门树在职 + sales_order_finance:confirm）在服务层复核；
 * 权限可在权限设置中按部门/角色/个人配置。
 */
@RestController
@RequestMapping("/api/sales/orders")
@RequiredArgsConstructor
public class SalesOrderFinanceConfirmController {

    private final SalesOrderFinanceConfirmService service;

    @GetMapping("/finance-confirmation/pending")
    @PreAuthorize("hasAuthority('sales_order_finance:view')")
    public PageResponse<SalesOrderFinancePendingDto> pending(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String rejected) {
        // 缺省=仅未驳回（可办待办，与徽标同口径）；rejected=all 全部；true=仅已驳回。
        Boolean filter = rejected == null || rejected.isBlank()
                ? Boolean.FALSE
                : "all".equalsIgnoreCase(rejected) ? null : Boolean.valueOf(rejected);
        return service.pending(page, size, filter);
    }

    @GetMapping("/finance-confirmation/count")
    @PreAuthorize("hasAuthority('sales_order_finance:view')")
    public Map<String, Long> pendingCount() {
        return service.pendingCount();
    }

    @GetMapping("/{id}/finance-confirmation/review")
    @PreAuthorize("hasAuthority('sales_order_finance:view')")
    public SalesOrderFinanceReviewDto review(@PathVariable UUID id) {
        return service.review(id);
    }

    @PostMapping("/{id}/finance-confirmation")
    @PreAuthorize("hasAuthority('sales_order_finance:view')"
            + " and hasAuthority('sales_order_finance:confirm')")
    public void confirm(@PathVariable UUID id,
                        @Valid @RequestBody(required = false)
                        SalesOrderFinanceConfirmService.FinanceConfirmRequest request) {
        service.confirm(id, request);
    }

    @PostMapping("/{id}/finance-confirmation/reject")
    @PreAuthorize("hasAuthority('sales_order_finance:view')"
            + " and hasAuthority('sales_order_finance:confirm')")
    public void reject(@PathVariable UUID id,
                       @Valid @RequestBody
                       SalesOrderFinanceConfirmService.FinanceRejectRequest request) {
        service.reject(id, request);
    }
}
