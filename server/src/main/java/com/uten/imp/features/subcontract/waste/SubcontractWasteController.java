package com.uten.imp.features.subcontract.waste;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.subcontract.waste.dto.WasteDetail;
import com.uten.imp.features.subcontract.waste.dto.WasteListItem;
import com.uten.imp.features.subcontract.waste.dto.WasteQueryFilter;
import com.uten.imp.features.subcontract.waste.dto.WasteSaveRequest;
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
 * 委外材料损耗单 API（委外管理）。
 *
 * - GET    /api/subcontract/wastes?keyword=&supplierId=&warehouseId=&status=&dateFrom=&dateTo=&page=&size= → 分页
 * - GET    /api/subcontract/wastes/{id}            → 详情（主+明细）
 * - POST   /api/subcontract/wastes                 → 新建（草稿）subcontract_waste:edit
 * - PUT    /api/subcontract/wastes/{id}            → 编辑（仅草稿）
 * - DELETE /api/subcontract/wastes/{id}            → 删除（草稿/红冲可删；已审核禁删）
 * - POST   /api/subcontract/wastes/{id}/approve    → 审核（出库 + ★回写 wasted_qty 新库补全；不立应付）
 * - POST   /api/subcontract/wastes/{id}/reverse    → 红冲（反向入库 + 回减 wasted_qty）
 */
@RestController
@RequestMapping("/api/subcontract/wastes")
@RequiredArgsConstructor
public class SubcontractWasteController {

    private final SubcontractWasteService service;

    @GetMapping
    @PreAuthorize("hasAuthority('subcontract_waste:view')")
    public PageResponse<WasteListItem> list(
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
        return service.list(new WasteQueryFilter(keyword, supplierId, warehouseId, status, dateFrom, dateTo), page, size, sort, order);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_waste:view')")
    public WasteDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('subcontract_waste:edit')")
    public WasteDetail create(@Valid @RequestBody WasteSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_waste:edit')")
    public WasteDetail update(@PathVariable UUID id, @Valid @RequestBody WasteSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_waste:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('subcontract_waste:edit')")
    public WasteDetail approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('subcontract_waste:edit')")
    public WasteDetail reverse(@PathVariable UUID id) {
        return service.reverse(id);
    }
}
