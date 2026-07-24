package com.uten.imp.features.master.supplier;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.supplier.dto.SupplierDetail;
import com.uten.imp.features.master.supplier.dto.SupplierListItem;
import com.uten.imp.features.master.supplier.dto.SupplierSaveRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.UUID;

/**
 * 供应商主档 API（基础资料-供应商资料）。
 *
 * - GET  /api/master/suppliers?categoryId=&page=1&size=20 → 分页（子树汇总）
 * - GET  /api/master/suppliers/{id}                       → 详情
 * - POST /api/master/suppliers                            → 新建（supplier:edit）
 * - PUT  /api/master/suppliers/{id}                       → 编辑（supplier:edit）
 * - DEL  /api/master/suppliers/{id}                       → 删除（supplier:edit，软删）
 *
 * 权限点 supplier:view 由 V38 种子化（全部部门）；supplier:edit 授 PMC 运营部（超管恒有）。
 */
@RestController
@RequestMapping("/api/master/suppliers")
@RequiredArgsConstructor
public class SupplierController {

    private final SupplierService service;

    @GetMapping
    @PreAuthorize("hasAuthority('supplier:view')")
    public PageResponse<SupplierListItem> list(
            @RequestParam(required = false) UUID categoryId,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(categoryId, page, size);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('supplier:view')")
    public SupplierDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('supplier:edit')")
    public SupplierDetail create(@Valid @RequestBody SupplierSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('supplier:edit')")
    public SupplierDetail update(@PathVariable UUID id, @Valid @RequestBody SupplierSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('supplier:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }
}
