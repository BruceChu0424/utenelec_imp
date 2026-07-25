package com.uten.imp.features.master.client;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.client.dto.ClientDetail;
import com.uten.imp.features.master.client.dto.ClientFacets;
import com.uten.imp.features.master.client.dto.ClientListItem;
import com.uten.imp.features.master.client.dto.ClientQueryFilter;
import com.uten.imp.features.master.client.dto.ClientSaveRequest;
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

import java.math.BigDecimal;
import java.util.Set;
import java.util.UUID;

/**
 * 客户主档 API（基础资料-客户资料）。
 *
 * <p>列表与 facets 均按 {@code categoryId} 的<b>子树</b>范围（含子分类）查询，动态字段筛选。
 *
 * - GET  /api/master/clients?categoryId=&keyword=&nullFields=&code=...&page=1&size=20 → 分页
 * - GET  /api/master/clients/facets?categoryId=                                       → 各字段可选值 + 空值计数
 * - GET  /api/master/clients/{id}                                                     → 详情
 * - POST /api/master/clients                                                          → 新建（client:edit）
 * - PUT  /api/master/clients/{id}                                                     → 编辑（client:edit）
 * - DEL  /api/master/clients/{id}                                                     → 删除（client:edit，软删）
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
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Set<String> nullFields,
            @RequestParam(required = false) String code,
            @RequestParam(required = false) String name,
            @RequestParam(name = "fullName", required = false) String fullName,
            @RequestParam(name = "clientXz", required = false) String clientXz,
            @RequestParam(required = false) Integer tday,
            @RequestParam(required = false) String region,
            @RequestParam(name = "placeId", required = false) String placeId,
            @RequestParam(name = "empId", required = false) String empId,
            @RequestParam(name = "legalPerson", required = false) String legalPerson,
            @RequestParam(required = false) String linkman,
            @RequestParam(required = false) String mobile,
            @RequestParam(required = false) String phone,
            @RequestParam(required = false) String phone2,
            @RequestParam(required = false) String fax,
            @RequestParam(required = false) String postcode,
            @RequestParam(required = false) String address,
            @RequestParam(required = false) String bank,
            @RequestParam(name = "bankAccount", required = false) String bankAccount,
            @RequestParam(name = "taxId", required = false) String taxId,
            @RequestParam(required = false) BigDecimal credit,
            @RequestParam(required = false) String website,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(new ClientQueryFilter(categoryId, keyword, nullFields,
                code, name, fullName, clientXz, tday, region, placeId, empId,
                legalPerson, linkman, mobile, phone, phone2, fax, postcode,
                address, bank, bankAccount, taxId, credit, website), page, size);
    }

    @GetMapping("/facets")
    @PreAuthorize("hasAuthority('client:view')")
    public ClientFacets facets(@RequestParam UUID categoryId) {
        return service.facets(categoryId);
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
