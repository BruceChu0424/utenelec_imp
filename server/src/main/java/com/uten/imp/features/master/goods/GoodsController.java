package com.uten.imp.features.master.goods;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.goods.dto.GoodsDetail;
import com.uten.imp.features.master.goods.dto.GoodsListItem;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.UUID;

/**
 * 货品主档 API（基础资料-货品资料）。
 *
 * - GET  /api/master/goods?categoryId=&page=1&size=20 → 分页（PageResponse）
 * - GET  /api/master/goods/{id}                       → 详情
 * - POST /api/master/goods                            → 新建（goods:edit）
 * - PUT  /api/master/goods/{id}                       → 编辑（goods:edit）
 * - DEL  /api/master/goods/{id}                       → 删除（goods:edit，软删）
 *
 * 权限点 goods:view 由 V32 种子化（已授予全部未软删部门）；goods:edit 仅超管恒有（未授部门）。
 */
@RestController
@RequestMapping("/api/master/goods")
@RequiredArgsConstructor
public class GoodsController {

    private final GoodsService service;

    @GetMapping
    @PreAuthorize("hasAuthority('goods:view')")
    public PageResponse<GoodsListItem> list(
            @RequestParam(required = false) UUID categoryId,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(categoryId, page, size);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('goods:view')")
    public GoodsDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('goods:edit')")
    public GoodsDetail create(@Valid @RequestBody GoodsSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('goods:edit')")
    public GoodsDetail update(@PathVariable UUID id, @Valid @RequestBody GoodsSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('goods:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }
}
