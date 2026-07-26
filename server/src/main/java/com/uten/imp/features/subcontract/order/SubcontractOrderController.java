package com.uten.imp.features.subcontract.order;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.subcontract.order.dto.OrderCostItemDto;
import com.uten.imp.features.subcontract.order.dto.OrderDetail;
import com.uten.imp.features.subcontract.order.dto.OrderListItem;
import com.uten.imp.features.subcontract.order.dto.OrderQueryFilter;
import com.uten.imp.features.subcontract.order.dto.OrderSaveRequest;
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
import java.util.List;
import java.util.UUID;

/**
 * 委外订货单 API（委外管理）。
 *
 * - GET    /api/subcontract/orders?keyword=&supplierId=&warehouseId=&status=&dateFrom=&dateTo=&page=&size= → 分页
 * - GET    /api/subcontract/orders/{id}            → 详情（主+明细）
 * - GET    /api/subcontract/orders/{id}/cost-items → BOM 成本子表（只读；design doc 22 §五）
 * - POST   /api/subcontract/orders                 → 新建（草稿）subcontract_order:edit
 * - PUT    /api/subcontract/orders/{id}            → 编辑（仅草稿）
 * - DELETE /api/subcontract/orders/{id}            → 删除（草稿/红冲可删；已审核禁删）
 * - POST   /api/subcontract/orders/{id}/approve    → 审核（回写申请 ordered_qty；无库存/ArAp）
 * - POST   /api/subcontract/orders/{id}/reverse    → 红冲
 */
@RestController
@RequestMapping("/api/subcontract/orders")
@RequiredArgsConstructor
public class SubcontractOrderController {

    private final SubcontractOrderService service;

    @GetMapping
    @PreAuthorize("hasAuthority('subcontract_order:view')")
    public PageResponse<OrderListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(new OrderQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo), page, size);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_order:view')")
    public OrderDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    /** BOM 成本子表只读（design doc 22 §五：本期不展开，仅查迁老库的原样数据）。 */
    @GetMapping("/{id}/cost-items")
    @PreAuthorize("hasAuthority('subcontract_order:view')")
    public List<OrderCostItemDto> costItems(@PathVariable UUID id) {
        return service.listCostItems(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('subcontract_order:edit')")
    public OrderDetail create(@Valid @RequestBody OrderSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_order:edit')")
    public OrderDetail update(@PathVariable UUID id, @Valid @RequestBody OrderSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_order:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('subcontract_order:edit')")
    public OrderDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('subcontract_order:edit')")
    public OrderDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }
}
