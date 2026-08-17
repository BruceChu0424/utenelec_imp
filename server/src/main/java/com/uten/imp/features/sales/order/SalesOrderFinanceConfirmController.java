package com.uten.imp.features.sales.order;

import com.uten.imp.common.web.PageResponse;

import com.uten.imp.features.sales.order.dto.SalesOrderFinancePendingDto;
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
 * 销售订货单「财务确认」API（V294 业务链闸门）。
 *
 * <ul>
 *   <li>GET  /api/sales/orders/finance-confirmation/pending → 待确认任务列表（已审未确认）</li>
 *   <li>GET  /api/sales/orders/finance-confirmation/count → 待确认计数（工作台徽标）</li>
 *   <li>POST /api/sales/orders/{id}/finance-confirmation → 财务确认（确认后放行计划部）</li>
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
            @RequestParam(defaultValue = "20") int size) {
        return service.pending(page, size);
    }

    @GetMapping("/finance-confirmation/count")
    @PreAuthorize("hasAuthority('sales_order_finance:view')")
    public Map<String, Long> pendingCount() {
        return service.pendingCount();
    }

    @PostMapping("/{id}/finance-confirmation")
    @PreAuthorize("hasAuthority('sales_order_finance:view')"
            + " and hasAuthority('sales_order_finance:confirm')")
    public void confirm(@PathVariable UUID id,
                        @Valid @RequestBody(required = false)
                        SalesOrderFinanceConfirmService.FinanceConfirmRequest request) {
        service.confirm(id, request);
    }
}
