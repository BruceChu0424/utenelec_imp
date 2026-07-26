package com.uten.imp.features.subcontract.material_return;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.subcontract.material_return.dto.MaterialReturnDetail;
import com.uten.imp.features.subcontract.material_return.dto.MaterialReturnListItem;
import com.uten.imp.features.subcontract.material_return.dto.MaterialReturnQueryFilter;
import com.uten.imp.features.subcontract.material_return.dto.MaterialReturnSaveRequest;
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
 * 委外材料退货单 API（委外管理）。
 *
 * - GET    /api/subcontract/material-returns?keyword=&supplierId=&warehouseId=&status=&dateFrom=&dateTo=&page=&size= → 分页
 * - GET    /api/subcontract/material-returns/{id}            → 详情（主+明细）
 * - POST   /api/subcontract/material-returns                 → 新建（草稿）subcontract_material_return:edit
 * - PUT    /api/subcontract/material-returns/{id}            → 编辑（仅草稿）
 * - DELETE /api/subcontract/material-returns/{id}            → 删除（草稿/红冲可删；已审核禁删）
 * - POST   /api/subcontract/material-returns/{id}/approve    → 审核（入库 + 双回写；不立应付）
 * - POST   /api/subcontract/material-returns/{id}/reverse    → 红冲（反向出库）
 */
@RestController
@RequestMapping("/api/subcontract/material-returns")
@RequiredArgsConstructor
public class SubcontractMaterialReturnController {

    private final SubcontractMaterialReturnService service;

    @GetMapping
    @PreAuthorize("hasAuthority('subcontract_material_return:view')")
    public PageResponse<MaterialReturnListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(new MaterialReturnQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo), page, size);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_material_return:view')")
    public MaterialReturnDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('subcontract_material_return:edit')")
    public MaterialReturnDetail create(@Valid @RequestBody MaterialReturnSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_material_return:edit')")
    public MaterialReturnDetail update(@PathVariable UUID id, @Valid @RequestBody MaterialReturnSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_material_return:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('subcontract_material_return:edit')")
    public MaterialReturnDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('subcontract_material_return:edit')")
    public MaterialReturnDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }
}
