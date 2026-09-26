package com.uten.imp.features.master.unit;

import com.uten.imp.application.port.ExportLimitPort;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.ExportPasswordRequest;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.DownloadContentDisposition;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.unit.dto.UnitDetail;
import com.uten.imp.features.master.unit.dto.UnitFacets;
import com.uten.imp.features.master.unit.dto.UnitListItem;
import com.uten.imp.features.master.unit.dto.UnitQueryFilter;
import com.uten.imp.features.master.unit.dto.UnitSaveRequest;
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

import java.util.Set;
import java.util.UUID;

/**
 * 基本单位主档 API（基础资料-基本单位）。
 *
 * <p>扁平主档，无 categoryId：列表与 facets 全量查询，动态字段筛选。
 *
 * - GET  /api/master/units?keyword=&nullFields=&code=&name=&status=&page=1&size=20 → 分页
 * - GET  /api/master/units/facets                                                → 各字段可选值 + 空值计数
 * - GET  /api/master/units/{id}                                                   → 详情
 * - POST /api/master/units                                                        → 新建（unit:edit）
 * - PUT  /api/master/units/{id}                                                   → 编辑（unit:edit）
 * - DEL  /api/master/units/{id}                                                   → 删除（unit:edit，软删）
 *
 * 权限点 unit:view 由种子化（已授予全部未软删部门）；unit:edit 授 DEPT_PMC + 超管恒有。
 */
@RestController
@RequestMapping("/api/master/units")
@RequiredArgsConstructor
public class UnitController {

    private final UnitService service;
    private final AuditDetailViewRecorder detailViewAudit;
    private final XlsxExportService xlsxExport;
    private final WorkbookDownloadService workbookDownload;
    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;
    private final ExportLimitPort exportLimits;

    @GetMapping
    @PreAuthorize("hasAuthority('unit:view')")
    public PageResponse<UnitListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Set<String> nullFields,
            @RequestParam(required = false) String code,
            @RequestParam(required = false) String name,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) String dimension,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(new UnitQueryFilter(keyword, nullFields, code, name, status, dimension), page, size);
    }

    // ---------- 加密 Excel 导出（POST，密码走 body；过滤参数与 GET /list 一致；V717） ----------

    @PostMapping("/export")
    @PreAuthorize("hasAuthority('unit:export')")
    public ResponseEntity<byte[]> export(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Set<String> nullFields,
            @RequestParam(required = false) String code,
            @RequestParam(required = false) String name,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) String dimension,
            @Valid @RequestBody ExportPasswordRequest body) {
        ExportPayload payload = service.export(
                new UnitQueryFilter(keyword, nullFields, code, name, status, dimension),
                exportLimits.exportMaxRows());
        byte[] xlsx = xlsxExport.build(payload.columns(), payload.rows());
        byte[] downloadBytes = workbookDownload.protect(xlsx, body.password());
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "export_unit", "master_data", String.valueOf(payload.total()), "success"));
        return ResponseEntity.ok()
                .header("Content-Disposition", DownloadContentDisposition.attachment("units.xlsx"))
                .header("Content-Type",
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
                .body(downloadBytes);
    }

    @GetMapping("/facets")
    @PreAuthorize("hasAuthority('unit:view')")
    public UnitFacets facets() {
        return service.facets();
    }

    /** 全量字典（货品编辑表单选单位用；unit:view 全员有）。 */
    @GetMapping("/dict")
    @PreAuthorize("hasAuthority('unit:view')")
    public java.util.List<UnitListItem> dict() {
        return service.dict();
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('unit:view')")
    public UnitDetail detail(@PathVariable UUID id) {
        UnitDetail result = service.detail(id);
        String displayName = result.getCode();
        if (displayName == null || displayName.isBlank()) {
            displayName = result.getName();
        }
        detailViewAudit.record(
                "view_unit_detail", "units", id, displayName,
                result.getLegacyId(), "计量单位");
        return result;
    }

    @PostMapping
    @PreAuthorize("hasAuthority('unit:create')")
    public UnitDetail create(@Valid @RequestBody UnitSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAnyAuthority('unit:edit', 'unit:status')")
    public UnitDetail update(@PathVariable UUID id, @Valid @RequestBody UnitSaveRequest req) {
        return service.update(id, req);
    }

    @org.springframework.web.bind.annotation.PatchMapping("/{id}/status")
    @PreAuthorize("hasAuthority('unit:status')")
    public UnitDetail changeStatus(
            @PathVariable UUID id,
            @Valid @RequestBody com.uten.imp.features.master.dto.MasterStatusChangeRequest req) {
        return service.changeStatus(id, req);
    }

}
