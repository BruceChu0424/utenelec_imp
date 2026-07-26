package com.uten.imp.features.sales.ret;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.sales.ret.dto.ReturnDetail;
import com.uten.imp.features.sales.ret.dto.ReturnListItem;
import com.uten.imp.features.sales.ret.dto.ReturnQueryFilter;
import com.uten.imp.features.sales.ret.dto.ReturnSaveRequest;
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
 * 销售退货单 API（销售管理）。
 *
 * - GET    /api/sales/returns               → 分页
 * - GET    /api/sales/returns/{id}          → 详情
 * - POST   /api/sales/returns               → 新建 sales_return:edit
 * - PUT    /api/sales/returns/{id}          → 编辑（仅草稿）
 * - DELETE /api/sales/returns/{id}          → 删除
 * - POST   /api/sales/returns/{id}/approve  → 审核（库存入库 + 双挂回写 + 立红字应收 + 结案）
 * - POST   /api/sales/returns/{id}/reverse  → 红冲（先校验收款核销 → 反向）
 */
@RestController
@RequestMapping("/api/sales/returns")
@RequiredArgsConstructor
public class SalesReturnController {

    private final SalesReturnService service;

    @GetMapping
    @PreAuthorize("hasAuthority('sales_return:view')")
    public PageResponse<ReturnListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) Boolean arPosted,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(new ReturnQueryFilter(keyword, clientId, warehouseId, status, arPosted, dateFrom, dateTo), page, size);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_return:view')")
    public ReturnDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('sales_return:edit')")
    public ReturnDetail create(@Valid @RequestBody ReturnSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_return:edit')")
    public ReturnDetail update(@PathVariable UUID id, @Valid @RequestBody ReturnSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('sales_return:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('sales_return:edit')")
    public ReturnDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('sales_return:edit')")
    public ReturnDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }
}
