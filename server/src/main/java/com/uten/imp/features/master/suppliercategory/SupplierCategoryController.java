package com.uten.imp.features.master.suppliercategory;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.mastercode.CategoryPrefixPreview;
import com.uten.imp.features.master.suppliercategory.dto.*;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.UUID;

/** 供应商分类树接口（/api/master/supplier-categories）：树查询/详情/编码前缀预览 + CRUD。 */
@RestController
@RequestMapping("/api/master/supplier-categories")
@RequiredArgsConstructor
public class SupplierCategoryController {

    private final SupplierCategoryService service;
    private final AuditDetailViewRecorder detailViewAudit;

    @GetMapping("/tree")
    @PreAuthorize("hasAuthority('supplier_category:view')")
    public List<SupplierCategoryNode> tree() {
        return service.tree();
    }

    @GetMapping("/{id}/subtree")
    @PreAuthorize("hasAuthority('supplier_category:view')")
    public List<SupplierCategoryNode> subtree(@PathVariable UUID id) {
        return service.subtree(id);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('supplier_category:view')")
    public SupplierCategoryDetail detail(@PathVariable UUID id) {
        SupplierCategoryDetail result = service.detail(id);
        String displayName = result.getCode();
        if (displayName == null || displayName.isBlank()) {
            displayName = result.getName();
        }
        detailViewAudit.record(
                "view_supplier_category_detail", "supplier_categories", id, displayName,
                result.getLegacyId(), "供应商分类");
        return result;
    }

    @GetMapping("/{id}/prefix-preview")
    @PreAuthorize("hasAuthority('supplier_category:view')")
    public CategoryPrefixPreview prefixPreview(@PathVariable UUID id,
                                               @RequestParam(required = false) String prefix,
                                               @RequestParam(required = false) UUID parentId) {
        return service.prefixPreview(id, prefix == null ? "" : prefix, parentId);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('supplier_category:create')")
    public SupplierCategoryDetail create(@Valid @RequestBody SupplierCategorySaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAnyAuthority('supplier_category:edit', 'supplier_category:move', 'supplier_category:reorder')")
    public SupplierCategoryDetail update(@PathVariable UUID id, @Valid @RequestBody SupplierCategoryUpdateRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('supplier_category:delete')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }
}
