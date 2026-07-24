package com.uten.imp.features.master.mould;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.mould.dto.MouldDetail;
import com.uten.imp.features.master.mould.dto.MouldListItem;
import com.uten.imp.features.master.mould.dto.MouldSaveRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.UUID;

/**
 * 模具主档 API（基础资料-模具资料）。
 *
 * - GET  /api/master/moulds?categoryId=&page=1&size=20 → 分页（PageResponse）
 * - GET  /api/master/moulds/{id}                       → 详情
 * - POST /api/master/moulds                            → 新建（mould:edit）
 * - PUT  /api/master/moulds/{id}                       → 编辑（mould:edit）
 * - DEL  /api/master/moulds/{id}                       → 删除（mould:edit，软删）
 *
 * 权限点 mould:view 由 V34 种子化（已授予全部未软删部门）；mould:edit 授生产部（超管恒有）。
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
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(categoryId, page, size);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('mould:view')")
    public MouldDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('mould:edit')")
    public MouldDetail create(@Valid @RequestBody MouldSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('mould:edit')")
    public MouldDetail update(@PathVariable UUID id, @Valid @RequestBody MouldSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('mould:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }
}
