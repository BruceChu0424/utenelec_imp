package com.uten.imp.features.subcontract.application;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.subcontract.application.dto.ApplicationDetail;
import com.uten.imp.features.subcontract.application.dto.ApplicationListItem;
import com.uten.imp.features.subcontract.application.dto.ApplicationQueryFilter;
import com.uten.imp.features.subcontract.application.dto.ApplicationSaveRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
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

import java.time.LocalDate;
import java.util.UUID;

/**
 * 委外申请单 API（委外管理）。
 *
 * - GET    /api/subcontract/applications?keyword=&supplierId=&warehouseId=&status=&dateFrom=&dateTo=&page=&size= → 分页
 * - GET    /api/subcontract/applications/{id}            → 详情（主+明细，含 ordered_qty 已订量）
 * - POST   /api/subcontract/applications                 → 新建（草稿）subcontract_application:edit
 * - PUT    /api/subcontract/applications/{id}            → 编辑（仅草稿）
 * - DELETE /api/subcontract/applications/{id}            → 删除（草稿/红冲可删；已审核禁删）
 * - POST   /api/subcontract/applications/{id}/approve    → 审核（仅状态变更；申请无库存/ArAp 联动）
 * - POST   /api/subcontract/applications/{id}/reverse    → 红冲
 */
@RestController
@RequestMapping("/api/subcontract/applications")
@RequiredArgsConstructor
public class SubcontractApplicationController {

    private final SubcontractApplicationService service;

    @GetMapping
    @PreAuthorize("hasAuthority('subcontract_application:view')")
    public PageResponse<ApplicationListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new ApplicationQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo), page, size, sort, order);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_application:view')")
    public ApplicationDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('subcontract_application:edit')")
    public ApplicationDetail create(@Valid @RequestBody ApplicationSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_application:edit')")
    public ApplicationDetail update(@PathVariable UUID id, @Valid @RequestBody ApplicationSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_application:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('subcontract_application:edit')")
    public ApplicationDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('subcontract_application:edit')")
    public ApplicationDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }
}
