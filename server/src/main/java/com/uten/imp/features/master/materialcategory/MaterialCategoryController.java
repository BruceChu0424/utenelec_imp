package com.uten.imp.features.master.materialcategory;

import com.uten.imp.common.mastercode.CategoryPrefixPreview;
import com.uten.imp.features.master.materialcategory.dto.*;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.UUID;

/** 物料分类树接口（/api/master/material-categories）：树查询/详情/删除影响预览/编码前缀预览 + CRUD。 */
@RestController
@RequestMapping("/api/master/material-categories")
@RequiredArgsConstructor
public class MaterialCategoryController {

    private final MaterialCategoryService service;

    @GetMapping("/tree")
    @PreAuthorize("hasAuthority('material_category:view')")
    public List<MaterialCategoryNode> tree() {
        return service.tree();
    }

    @GetMapping("/{id}/subtree")
    @PreAuthorize("hasAuthority('material_category:view')")
    public List<MaterialCategoryNode> subtree(@PathVariable UUID id) {
        return service.subtree(id);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('material_category:view')")
    public MaterialCategoryDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @GetMapping("/{id}/delete-preview")
    @PreAuthorize("hasAuthority('material_category:view')")
    public MaterialCategoryDeletePreview deletePreview(@PathVariable UUID id) {
        return service.deletePreview(id);
    }

    @GetMapping("/{id}/prefix-preview")
    @PreAuthorize("hasAuthority('material_category:view')")
    public CategoryPrefixPreview prefixPreview(@PathVariable UUID id,
                                               @RequestParam(required = false) String prefix,
                                               @RequestParam(required = false) UUID parentId) {
        return service.prefixPreview(id, prefix == null ? "" : prefix, parentId);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('material_category:edit')")
    public MaterialCategoryDetail create(@Valid @RequestBody MaterialCategorySaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('material_category:edit')")
    public MaterialCategoryDetail update(@PathVariable UUID id, @Valid @RequestBody MaterialCategoryUpdateRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('material_category:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }
}
