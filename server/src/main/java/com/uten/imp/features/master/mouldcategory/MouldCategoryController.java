package com.uten.imp.features.master.mouldcategory;

import com.uten.imp.common.mastercode.CategoryPrefixPreview;
import com.uten.imp.features.master.mouldcategory.dto.*;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.UUID;

/**
 * 模具分类 API（基础资料-模具资料）。端点与 {@code MaterialCategoryController} 同构。
 *
 * - GET  /api/master/mould-categories/tree          → 全树
 * - GET  /api/master/mould-categories/{id}/subtree  → 子树
 * - GET  /api/master/mould-categories/{id}          → 详情
 * - GET  /api/master/mould-categories/{id}/delete-preview → 删除预览（子树规模，问题 #7）
 * - POST /api/master/mould-categories                → 新建（mould_category:edit）
 * - PUT  /api/master/mould-categories/{id}           → 改名/移动（mould_category:edit）
 * - DEL  /api/master/mould-categories/{id}           → 级联删除（含子树+子树下模具，mould_category:edit）
 *
 * 权限点 mould_category:view/edit 由种子化（view 已授予全部未软删部门，edit 授生产部）。
 */
@RestController
@RequestMapping("/api/master/mould-categories")
@RequiredArgsConstructor
public class MouldCategoryController {

    private final MouldCategoryService service;

    @GetMapping("/tree")
    @PreAuthorize("hasAuthority('mould_category:view')")
    public List<MouldCategoryNode> tree() {
        return service.tree();
    }

    @GetMapping("/{id}/subtree")
    @PreAuthorize("hasAuthority('mould_category:view')")
    public List<MouldCategoryNode> subtree(@PathVariable UUID id) {
        return service.subtree(id);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('mould_category:view')")
    public MouldCategoryDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @GetMapping("/{id}/prefix-preview")
    @PreAuthorize("hasAuthority('mould_category:view')")
    public CategoryPrefixPreview prefixPreview(@PathVariable UUID id,
                                               @RequestParam(required = false) String prefix,
                                               @RequestParam(required = false) UUID parentId) {
        return service.prefixPreview(id, prefix == null ? "" : prefix, parentId);
    }

    @GetMapping("/{id}/delete-preview")
    @PreAuthorize("hasAuthority('mould_category:view')")
    public MouldCategoryDeletePreview deletePreview(@PathVariable UUID id) {
        return service.deletePreview(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('mould_category:create')")
    public MouldCategoryDetail create(@Valid @RequestBody MouldCategorySaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAnyAuthority('mould_category:edit', 'mould_category:move', 'mould_category:reorder')")
    public MouldCategoryDetail update(@PathVariable UUID id, @Valid @RequestBody MouldCategoryUpdateRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('mould_category:delete')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }
}
