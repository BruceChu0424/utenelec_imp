package com.uten.imp.features.master.materialcategory;

import com.uten.imp.features.master.materialcategory.dto.*;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.UUID;

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
