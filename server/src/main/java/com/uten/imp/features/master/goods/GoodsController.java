package com.uten.imp.features.master.goods;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.goods.dto.GoodsDetail;
import com.uten.imp.features.master.goods.dto.GoodsDictItem;
import com.uten.imp.features.master.goods.dto.GoodsFacets;
import com.uten.imp.features.master.goods.dto.GoodsListItem;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
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
 * 货品主档 API（基础资料-货品资料）。
 *
 * <p>列表与 facets 均按 {@code categoryId} 的<b>子树</b>范围（含子分类）查询，动态字段筛选。
 *
 * - GET  /api/master/goods?categoryId=&keyword=&nullFields=&series=...&page=1&size=20 → 分页
 * - GET  /api/master/goods/facets?categoryId=                                        → 各字段可选值 + 空值计数
 * - GET  /api/master/goods/{id}                                                       → 详情
 * - POST /api/master/goods                                                            → 新建（goods:edit）
 * - PUT  /api/master/goods/{id}                                                       → 编辑（goods:edit）
 * - DEL  /api/master/goods/{id}                                                       → 删除（goods:edit，软删）
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
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Set<String> nullFields,
            @RequestParam(required = false) String series,
            @RequestParam(required = false) String model,
            @RequestParam(required = false) String material,
            @RequestParam(required = false) String code,
            @RequestParam(required = false) String name,
            @RequestParam(required = false) String spec,
            @RequestParam(name = "cNumber", required = false) String cNumber,
            @RequestParam(required = false) String requireRemark,
            @RequestParam(required = false) Integer colorLegacyId,
            @RequestParam(required = false) Integer unitLegacyId,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(new GoodsQueryFilter(categoryId, keyword, nullFields,
                series, model, material, code, name, spec, cNumber, requireRemark,
                colorLegacyId, unitLegacyId), page, size);
    }

    @GetMapping("/facets")
    @PreAuthorize("hasAuthority('goods:view')")
    public GoodsFacets facets(@RequestParam UUID categoryId) {
        return service.facets(categoryId);
    }

    /** 按 id 批量解析货品名（采购单据明细展示用；goods:view 全员有）。 */
    @GetMapping("/lookup")
    @PreAuthorize("hasAuthority('goods:view')")
    public java.util.List<GoodsDictItem> lookup(@RequestParam("ids") Set<UUID> ids) {
        return service.lookup(ids);
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
