package com.uten.imp.features.master.client;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.client.dto.ClientDetail;
import com.uten.imp.features.master.client.dto.ClientListItem;
import com.uten.imp.features.master.client.dto.ClientSaveRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.UUID;

/**
 * 客户主档 API（基础资料-客户资料）。
 *
 * - GET  /api/master/clients?categoryId=&page=1&size=20 → 分页（子树汇总）
 * - GET  /api/master/clients/{id}                       → 详情
 * - POST /api/master/clients                            → 新建（client:edit）
 * - PUT  /api/master/clients/{id}                       → 编辑（client:edit）
 * - DEL  /api/master/clients/{id}                       → 删除（client:edit，软删）
 *
 * 权限点 client:view 由 V36 种子化（全部部门）；client:edit 授综合营销部（超管恒有）。
 */
@RestController
@RequestMapping("/api/master/clients")
@RequiredArgsConstructor
public class ClientController {

    private final ClientService service;

    @GetMapping
    @PreAuthorize("hasAuthority('client:view')")
    public PageResponse<ClientListItem> list(
            @RequestParam(required = false) UUID categoryId,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(categoryId, page, size);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('client:view')")
    public ClientDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('client:edit')")
    public ClientDetail create(@Valid @RequestBody ClientSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('client:edit')")
    public ClientDetail update(@PathVariable UUID id, @Valid @RequestBody ClientSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('client:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }
}
