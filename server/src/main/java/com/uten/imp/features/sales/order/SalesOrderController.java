package com.uten.imp.features.sales.order;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.sales.order.dto.OrderDetail;
import com.uten.imp.features.sales.order.dto.OrderListItem;
import com.uten.imp.features.sales.order.dto.OrderQueryFilter;
import com.uten.imp.features.sales.order.dto.OrderSaveRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.UUID;

/**
 * 销售订货单 API（销售管理）。CRUD + 审核 + 红冲（订货不入库、不立应收）+ 中止位切换。
 */
@RestController
@RequestMapping("/api/sales/orders")
@RequiredArgsConstructor
public class SalesOrderController {

    private final SalesOrderService service;

    @GetMapping
    @PreAuthorize("hasAuthority('sales_order:view')")
    public PageResponse<OrderListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) Boolean closed,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new OrderQueryFilter(keyword, clientId, status, closed, dateFrom, dateTo), page, size, sort, order);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_order:view')")
    public OrderDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('sales_order:edit')")
    public OrderDetail create(@Valid @RequestBody OrderSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_order:edit')")
    public OrderDetail update(@PathVariable UUID id, @Valid @RequestBody OrderSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_order:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('sales_order:edit')")
    public OrderDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('sales_order:edit')")
    public OrderDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }

    /** 中止位切换（独立业务位）。 */
    @PostMapping("/{id}/stopped")
    @PreAuthorize("hasAuthority('sales_order:edit')")
    public OrderDetail setStopped(@PathVariable UUID id, @RequestParam boolean stopped) {
        return service.toggleStopped(id, stopped);
    }
}
