package com.uten.imp.features.master.suppliercategory;

import com.uten.imp.features.master.suppliercategory.dto.*;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.UUID;

@RestController
@RequestMapping("/api/master/supplier-categories")
@RequiredArgsConstructor
public class SupplierCategoryController {

    private final SupplierCategoryService service;

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
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('supplier_category:edit')")
    public SupplierCategoryDetail create(@Valid @RequestBody SupplierCategorySaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('supplier_category:edit')")
    public SupplierCategoryDetail update(@PathVariable UUID id, @Valid @RequestBody SupplierCategoryUpdateRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('supplier_category:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }
}
