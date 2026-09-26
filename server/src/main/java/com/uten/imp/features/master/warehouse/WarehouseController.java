package com.uten.imp.features.master.warehouse;

import com.uten.imp.application.port.ExportLimitPort;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.ExportPasswordRequest;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.DownloadContentDisposition;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.warehouse.dto.MyWarehouseScope;
import com.uten.imp.features.master.warehouse.dto.WarehouseDetail;
import com.uten.imp.features.master.warehouse.dto.WarehouseFacets;
import com.uten.imp.features.master.warehouse.dto.WarehouseKeeper;
import com.uten.imp.features.master.warehouse.dto.WarehouseKeeperAssignment;
import com.uten.imp.features.master.warehouse.dto.WarehouseKeeperSaveRequest;
import com.uten.imp.features.master.warehouse.dto.WarehouseListItem;
import com.uten.imp.features.master.warehouse.dto.WarehouseQueryFilter;
import com.uten.imp.features.master.warehouse.dto.WarehouseSaveRequest;
import com.uten.imp.features.master.warehouse.dto.WarehouseWorkshopOption;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
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
 * - GET  /api/master/warehouses/keepers          （全部负责关系，列表「负责人」列）
 * - GET  /api/master/warehouses/keeper-candidates（warehouse:edit，负责人候选员工）
 * - GET  /api/master/warehouses/my-scope         （登录即可：当前账号的「我的仓库」）
 * - GET  /api/master/warehouses/{id}/keepers     （某仓库的负责人）
 * - PUT  /api/master/warehouses/{id}/keepers     （warehouse:edit，整组替换负责人，ADR-115）
 */
@RestController
@RequestMapping("/api/master/warehouses")
@RequiredArgsConstructor
public class WarehouseController {

    private final WarehouseService service;
    private final WarehouseKeeperService keeperService;
    private final AuditDetailViewRecorder detailViewAudit;
    private final XlsxExportService xlsxExport;
    private final WorkbookDownloadService workbookDownload;
    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;
    private final ExportLimitPort exportLimits;

    @GetMapping
    @PreAuthorize("hasAuthority('warehouse:view')")
    public PageResponse<WarehouseListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Set<String> nullFields,
            @RequestParam(required = false) String code,
            @RequestParam(required = false) String name,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) String location,
            @RequestParam(required = false) UUID parentId,
            @RequestParam(required = false) Boolean accountable,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(new WarehouseQueryFilter(
                keyword, nullFields, code, name, status, location, parentId, accountable), page, size);
    }

    // ---------- 加密 Excel 导出（POST，密码走 body；过滤参数与 GET /list 一致；V717） ----------

    @PostMapping("/export")
    @PreAuthorize("hasAuthority('warehouse:export')")
    public ResponseEntity<byte[]> export(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Set<String> nullFields,
            @RequestParam(required = false) String code,
            @RequestParam(required = false) String name,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) String location,
            @RequestParam(required = false) UUID parentId,
            @RequestParam(required = false) Boolean accountable,
            @Valid @RequestBody ExportPasswordRequest body) {
        ExportPayload payload = service.export(new WarehouseQueryFilter(
                        keyword, nullFields, code, name, status, location, parentId, accountable),
                exportLimits.exportMaxRows());
        byte[] xlsx = xlsxExport.build(payload.columns(), payload.rows());
        byte[] downloadBytes = workbookDownload.protect(xlsx, body.password());
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "export_warehouse", "master_data", String.valueOf(payload.total()), "success"));
        return ResponseEntity.ok()
                .header("Content-Disposition", DownloadContentDisposition.attachment("warehouses.xlsx"))
                .header("Content-Type",
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
                .body(downloadBytes);
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

    /** 全部负责关系(ADR-115)：仓库资料列表「负责人」列。 */
    @GetMapping("/keepers")
    @PreAuthorize("hasAuthority('warehouse:view')")
    public List<WarehouseKeeperAssignment> keeperAssignments() {
        return keeperService.assignments();
    }

    /** 负责人候选：在职员工，仓库部门的人排前面，标出有无账号/是否仓库部门。 */
    @GetMapping("/keeper-candidates")
    @PreAuthorize("hasAuthority('warehouse:edit')")
    public List<WarehouseKeeper> keeperCandidates(@RequestParam(required = false) String keyword) {
        return keeperService.candidates(keyword);
    }

    /**
     * 当前账号的「我的仓库」：仓库任务中心的仓库范围选择器用。只回本人负责的仓与范围 id，
     * 不含任何他人信息，登录即可读(任务中心各列表自己再按各自权限校验)。
     */
    @GetMapping("/my-scope")
    @PreAuthorize("isAuthenticated()")
    public MyWarehouseScope myScope() {
        return keeperService.myScope();
    }

    @GetMapping("/{id}/keepers")
    @PreAuthorize("hasAuthority('warehouse:view')")
    public List<WarehouseKeeper> keepers(@PathVariable UUID id) {
        return keeperService.keepers(id);
    }

    /** 整组替换负责人(ADR-115)：空列表 = 清空，该仓的仓库类通知回到整个仓库部门。 */
    @PutMapping("/{id}/keepers")
    @PreAuthorize("hasAuthority('warehouse:edit')")
    public List<WarehouseKeeper> replaceKeepers(
            @PathVariable UUID id, @Valid @RequestBody WarehouseKeeperSaveRequest req) {
        return keeperService.replaceKeepers(id, req);
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

}
