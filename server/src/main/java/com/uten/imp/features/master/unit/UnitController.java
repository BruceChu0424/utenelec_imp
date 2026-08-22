package com.uten.imp.features.master.unit;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.unit.dto.UnitDetail;
import com.uten.imp.features.master.unit.dto.UnitFacets;
import com.uten.imp.features.master.unit.dto.UnitListItem;
import com.uten.imp.features.master.unit.dto.UnitQueryFilter;
import com.uten.imp.features.master.unit.dto.UnitSaveRequest;
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
 * 基本单位主档 API（基础资料-基本单位）。
 *
 * <p>扁平主档，无 categoryId：列表与 facets 全量查询，动态字段筛选。
 *
 * - GET  /api/master/units?keyword=&nullFields=&code=&name=&status=&page=1&size=20 → 分页
 * - GET  /api/master/units/facets                                                → 各字段可选值 + 空值计数
 * - GET  /api/master/units/{id}                                                   → 详情
 * - POST /api/master/units                                                        → 新建（unit:edit）
 * - PUT  /api/master/units/{id}                                                   → 编辑（unit:edit）
 * - DEL  /api/master/units/{id}                                                   → 删除（unit:edit，软删）
 *
 * 权限点 unit:view 由种子化（已授予全部未软删部门）；unit:edit 授 DEPT_PMC + 超管恒有。
 */
@RestController
@RequestMapping("/api/master/units")
@RequiredArgsConstructor
public class UnitController {

    private final UnitService service;

    @GetMapping
    @PreAuthorize("hasAuthority('unit:view')")
    public PageResponse<UnitListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Set<String> nullFields,
            @RequestParam(required = false) String code,
            @RequestParam(required = false) String name,
            @RequestParam(required = false) String status,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(new UnitQueryFilter(keyword, nullFields, code, name, status), page, size);
    }

    @GetMapping("/facets")
    @PreAuthorize("hasAuthority('unit:view')")
    public UnitFacets facets() {
        return service.facets();
    }

    /** 全量字典（货品编辑表单选单位用；unit:view 全员有）。 */
    @GetMapping("/dict")
    @PreAuthorize("hasAuthority('unit:view')")
    public java.util.List<UnitListItem> dict() {
        return service.dict();
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('unit:view')")
    public UnitDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('unit:create')")
    public UnitDetail create(@Valid @RequestBody UnitSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAnyAuthority('unit:edit', 'unit:status')")
    public UnitDetail update(@PathVariable UUID id, @Valid @RequestBody UnitSaveRequest req) {
        return service.update(id, req);
    }

    @org.springframework.web.bind.annotation.PatchMapping("/{id}/status")
    @PreAuthorize("hasAuthority('unit:status')")
    public UnitDetail changeStatus(
            @PathVariable UUID id,
            @Valid @RequestBody com.uten.imp.features.master.dto.MasterStatusChangeRequest req) {
        return service.changeStatus(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('unit:delete')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }
}
