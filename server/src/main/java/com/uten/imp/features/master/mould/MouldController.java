package com.uten.imp.features.master.mould;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.mould.dto.MouldDetail;
import com.uten.imp.features.master.mould.dto.MouldFacets;
import com.uten.imp.features.master.mould.dto.MouldListItem;
import com.uten.imp.features.master.mould.dto.MouldQueryFilter;
import com.uten.imp.features.master.mould.dto.MouldSaveRequest;
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
 * 模具主档 API（基础资料-模具资料）。
 *
 * <p>列表与 facets 均按 {@code categoryId} 的<b>子树</b>范围（含子分类）查询，动态字段筛选。
 *
 * - GET  /api/master/moulds?categoryId=&keyword=&nullFields=&code=...&page=1&size=20 → 分页
 * - GET  /api/master/moulds/facets?categoryId=                                       → 各字段可选值 + 空值计数
 * - GET  /api/master/moulds/{id}                                                     → 详情
 * - POST /api/master/moulds                                                          → 新建（mould:edit）
 * - PUT  /api/master/moulds/{id}                                                     → 编辑（mould:edit）
 * - DEL  /api/master/moulds/{id}                                                     → 删除（mould:edit，软删）
 *
 * 权限点 mould:view 由种子化（已授予全部未软删部门）；mould:edit 授生产部（超管恒有）。
 */
@RestController
@RequestMapping("/api/master/moulds")
@RequiredArgsConstructor
public class MouldController {

    private final MouldService service;

    @GetMapping
    @PreAuthorize("hasAuthority('mould:view')")
    public PageResponse<MouldListItem> list(
            @RequestParam(required = false) UUID categoryId,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Set<String> nullFields,
            @RequestParam(required = false) String code,
            @RequestParam(required = false) String name,
            @RequestParam(required = false) String place,
            @RequestParam(required = false) String mstatus,
            @RequestParam(required = false) String remark,
            @RequestParam(required = false) String status,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(new MouldQueryFilter(categoryId, keyword, nullFields,
                code, name, place, mstatus, remark, status), page, size);
    }

    @GetMapping("/facets")
    @PreAuthorize("hasAuthority('mould:view')")
    public MouldFacets facets(@RequestParam UUID categoryId) {
        return service.facets(categoryId);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('mould:view')")
    public MouldDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('mould:create')")
    public MouldDetail create(@Valid @RequestBody MouldSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAnyAuthority('mould:edit', 'mould:status')")
    public MouldDetail update(@PathVariable UUID id, @Valid @RequestBody MouldSaveRequest req) {
        return service.update(id, req);
    }

    @org.springframework.web.bind.annotation.PatchMapping("/{id}/status")
    @PreAuthorize("hasAuthority('mould:status')")
    public MouldDetail changeStatus(
            @PathVariable UUID id,
            @Valid @RequestBody com.uten.imp.features.master.dto.MasterStatusChangeRequest req) {
        return service.changeStatus(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('mould:delete')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }
}
