package com.uten.imp.features.master.color;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.color.dto.ColorDetail;
import com.uten.imp.features.master.color.dto.ColorFacets;
import com.uten.imp.features.master.color.dto.ColorListItem;
import com.uten.imp.features.master.color.dto.ColorQueryFilter;
import com.uten.imp.features.master.color.dto.ColorSaveRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
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

import java.util.Set;
import java.util.UUID;

/**
 * 颜色主档 API（基础资料-颜色资料）。
 *
 * <p>扁平主档，无 categoryId：列表与 facets 全量查询，动态字段筛选。
 *
 * - GET  /api/master/colors?keyword=&nullFields=&code=&name=&status=&page=1&size=20 → 分页
 * - GET  /api/master/colors/facets                                                 → 各字段可选值 + 空值计数
 * - GET  /api/master/colors/{id}                                                    → 详情
 * - POST /api/master/colors                                                         → 新建（color:edit）
 * - PUT  /api/master/colors/{id}                                                    → 编辑（color:edit）
 * - DEL  /api/master/colors/{id}                                                    → 删除（color:edit，软删）
 *
 * 权限点 color:view 由种子化（已授予全部未软删部门）；color:edit 授 DEPT_PMC + 超管恒有。
 */
@RestController
@RequestMapping("/api/master/colors")
@RequiredArgsConstructor
public class ColorController {

    private final ColorService service;

    @GetMapping
    @PreAuthorize("hasAuthority('color:view')")
    public PageResponse<ColorListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Set<String> nullFields,
            @RequestParam(required = false) String code,
            @RequestParam(required = false) String name,
            @RequestParam(required = false) String status,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(new ColorQueryFilter(keyword, nullFields, code, name, status), page, size);
    }

    @GetMapping("/facets")
    @PreAuthorize("hasAuthority('color:view')")
    public ColorFacets facets() {
        return service.facets();
    }

    /** 全量字典（货品编辑表单选颜色用；color:view 全员有）。 */
    @GetMapping("/dict")
    @PreAuthorize("hasAuthority('color:view')")
    public java.util.List<ColorListItem> dict() {
        return service.dict();
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('color:view')")
    public ColorDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('color:create')")
    public ColorDetail create(@Valid @RequestBody ColorSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAnyAuthority('color:edit', 'color:status')")
    public ColorDetail update(@PathVariable UUID id, @Valid @RequestBody ColorSaveRequest req) {
        return service.update(id, req);
    }

    @org.springframework.web.bind.annotation.PatchMapping("/{id}/status")
    @PreAuthorize("hasAuthority('color:status')")
    public ColorDetail changeStatus(
            @PathVariable UUID id,
            @Valid @RequestBody com.uten.imp.features.master.dto.MasterStatusChangeRequest req) {
        return service.changeStatus(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('color:delete')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }
}
