package com.uten.imp.features.master.warehouse;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.warehouse.dto.WarehouseDetail;
import com.uten.imp.features.master.warehouse.dto.WarehouseFacets;
import com.uten.imp.features.master.warehouse.dto.WarehouseListItem;
import com.uten.imp.features.master.warehouse.dto.WarehouseQueryFilter;
import com.uten.imp.features.master.warehouse.dto.WarehouseSaveRequest;
import com.uten.imp.features.master.warehouse.dto.WarehouseWorkshopOption;
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

import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * 仓库主档 API（基础资料-仓库资料）。
 *
 * - GET  /api/master/warehouses?keyword=&nullFields=&code=&name=&status=&location=&page=1&size=20
 * - GET  /api/master/warehouses/facets
 * - GET  /api/master/warehouses/dict            （采购单据/库存选仓库用）
 * - GET  /api/master/warehouses/{id}
 * - POST /api/master/warehouses                 （warehouse:edit）
 * - PUT  /api/master/warehouses/{id}            （warehouse:edit）
 * - DEL  /api/master/warehouses/{id}            （warehouse:edit，软删）
 */
@RestController
@RequestMapping("/api/master/warehouses")
@RequiredArgsConstructor
public class WarehouseController {

    private final WarehouseService service;
    private final AuditDetailViewRecorder detailViewAudit;

    @GetMapping
    @PreAuthorize("hasAuthority('warehouse:view')")
    public PageResponse<WarehouseListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Set<String> nullFields,
            @RequestParam(required = false) String code,
            @RequestParam(required = false) String name,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) String location,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(new WarehouseQueryFilter(keyword, nullFields, code, name, status, location), page, size);
    }

    @GetMapping("/facets")
    @PreAuthorize("hasAuthority('warehouse:view')")
    public WarehouseFacets facets() {
        return service.facets();
    }

    @GetMapping("/dict")
    @PreAuthorize("hasAuthority('warehouse:view')")
    public List<WarehouseListItem> dict() {
        return service.dict();
    }

    @GetMapping("/workshops")
    @PreAuthorize("hasAuthority('warehouse:view')")
    public List<WarehouseWorkshopOption> workshops() {
        return service.workshopOptions();
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('warehouse:view')")
    public WarehouseDetail detail(@PathVariable UUID id) {
        WarehouseDetail result = service.detail(id);
        String displayName = result.getCode();
        if (displayName == null || displayName.isBlank()) {
            displayName = result.getName();
        }
        detailViewAudit.record(
                "view_warehouse_detail", "warehouses", id, displayName,
                result.getLegacyId(), "仓库");
        return result;
    }

    @PostMapping
    @PreAuthorize("hasAuthority('warehouse:create')")
    public WarehouseDetail create(@Valid @RequestBody WarehouseSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAnyAuthority('warehouse:edit', 'warehouse:status')")
    public WarehouseDetail update(@PathVariable UUID id, @Valid @RequestBody WarehouseSaveRequest req) {
        return service.update(id, req);
    }

    @org.springframework.web.bind.annotation.PatchMapping("/{id}/status")
    @PreAuthorize("hasAuthority('warehouse:status')")
    public WarehouseDetail changeStatus(
            @PathVariable UUID id,
            @Valid @RequestBody com.uten.imp.features.master.dto.MasterStatusChangeRequest req) {
        return service.changeStatus(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('warehouse:delete')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }
}
