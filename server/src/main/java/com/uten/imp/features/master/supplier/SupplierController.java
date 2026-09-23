package com.uten.imp.features.master.supplier;

import com.uten.imp.application.port.ExportLimitPort;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.DownloadContentDisposition;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.dto.ContactExportRequest;
import com.uten.imp.features.master.dto.ContactSensitiveFilter;
import com.uten.imp.features.master.supplier.dto.SupplierDetail;
import com.uten.imp.features.master.supplier.dto.SupplierDictItem;
import com.uten.imp.features.master.supplier.dto.SupplierFacets;
import com.uten.imp.features.master.supplier.dto.SupplierListItem;
import com.uten.imp.features.master.supplier.dto.SupplierQueryFilter;
import com.uten.imp.features.master.supplier.dto.SupplierSaveRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
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
 * 供应商主档 API（基础资料-供应商资料）。
 *
 * <p>列表与 facets 均按 {@code categoryId} 的<b>子树</b>范围（含子分类）查询，动态字段筛选。
 *
 * - GET  /api/master/suppliers?categoryId=&nullFields=&name=...&page=1&size=20 → 分页
 * - GET  /api/master/suppliers/facets?categoryId=                                       → 各字段可选值 + 空值计数
 * - GET  /api/master/suppliers/{id}                                                     → 详情
 * - POST /api/master/suppliers                                                          → 新建（supplier:edit）
 * - PUT  /api/master/suppliers/{id}                                                     → 编辑（supplier:edit）
 * - DEL  /api/master/suppliers/{id}                                                     → 删除（supplier:edit，软删）
 *
 * 权限点 supplier:view 由种子化（全部部门）；supplier:edit 授 PMC 运营部（超管恒有）。
 */
@RestController
@RequestMapping("/api/master/suppliers")
@RequiredArgsConstructor
public class SupplierController {

    private final SupplierService service;
    private final XlsxExportService xlsxExport;
    private final WorkbookDownloadService workbookDownload;
    private final AuditService audit;
    private final AuditDetailViewRecorder viewAudit;
    private final SecurityContextCurrentUser currentUser;
    private final ExportLimitPort exportLimits;

    @GetMapping
    @PreAuthorize("hasAuthority('supplier:view')")
    public PageResponse<SupplierListItem> list(
            @RequestParam(required = false) UUID categoryId,
            @RequestParam(required = false) Set<String> nullFields,
            @RequestParam(required = false) String name,
            @RequestParam(required = false) String description,
            @RequestParam(required = false) Integer tday,
            @RequestParam(required = false) String place,
            @RequestParam(name = "empId", required = false) String empId,
            @RequestParam(name = "ownerEmployeeId", required = false) UUID ownerEmployeeId,
            @RequestParam(name = "legalPerson", required = false) String legalPerson,
            @RequestParam(required = false) String linkman,
            @RequestParam(required = false) String fax,
            @RequestParam(required = false) String postcode,
            @RequestParam(required = false) String address,
            @RequestParam(required = false) String bank,
            @RequestParam(name = "taxId", required = false) String taxId,
            @RequestParam(required = false) String website,
            @RequestParam(name = "shipVia", required = false) String shipVia,
            @RequestParam(name = "shipAddress", required = false) String shipAddress,
            @RequestParam(defaultValue = "false") boolean selectableOnly,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        // 关键字 (会匹配手机号) 与手机/电话/银行账号筛选只接受 POST /search 请求体 (security-19)。
        return service.list(new SupplierQueryFilter(categoryId, null, nullFields,
                name, description, tday, place, empId, ownerEmployeeId, legalPerson, linkman,
                null, null, null, fax, postcode, address, bank, null, taxId,
                website, shipVia, shipAddress, selectableOnly), page, size, sort, order);
    }

    /**
     * 列表 (带关键字或手机/电话/银行账号筛选时用): 关键字会匹配手机号, 与敏感筛选值一样只走请求体,
     * 不进 URL 与访问日志 (security-19); 其余筛选、分页与排序和 GET 列表完全一致。只读查询。
     */
    @PostMapping("/search")
    @PreAuthorize("hasAuthority('supplier:view')")
    public PageResponse<SupplierListItem> search(
            @RequestParam(required = false) UUID categoryId,
            @RequestParam(required = false) Set<String> nullFields,
            @RequestParam(required = false) String name,
            @RequestParam(required = false) String description,
            @RequestParam(required = false) Integer tday,
            @RequestParam(required = false) String place,
            @RequestParam(name = "empId", required = false) String empId,
            @RequestParam(name = "ownerEmployeeId", required = false) UUID ownerEmployeeId,
            @RequestParam(name = "legalPerson", required = false) String legalPerson,
            @RequestParam(required = false) String linkman,
            @RequestParam(required = false) String fax,
            @RequestParam(required = false) String postcode,
            @RequestParam(required = false) String address,
            @RequestParam(required = false) String bank,
            @RequestParam(name = "taxId", required = false) String taxId,
            @RequestParam(required = false) String website,
            @RequestParam(name = "shipVia", required = false) String shipVia,
            @RequestParam(name = "shipAddress", required = false) String shipAddress,
            @RequestParam(defaultValue = "false") boolean selectableOnly,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @Valid @RequestBody(required = false) ContactSensitiveFilter body) {
        ContactSensitiveFilter sensitive = ContactSensitiveFilter.orNone(body);
        return service.list(new SupplierQueryFilter(categoryId, sensitive.keyword(), nullFields,
                name, description, tday, place, empId, ownerEmployeeId, legalPerson, linkman,
                sensitive.mobile(), sensitive.phone(), sensitive.phone2(), fax, postcode, address, bank,
                sensitive.bankAccount(), taxId,
                website, shipVia, shipAddress, selectableOnly), page, size, sort, order);
    }

    @GetMapping("/facets")
    @PreAuthorize("hasAuthority('supplier:view')")
    public SupplierFacets facets(@RequestParam UUID categoryId) {
        return service.facets(categoryId);
    }

    /** 全量字典（采购单据页选/解析供应商用；supplier:view 全员有）。 */
    @GetMapping("/dict")
    @PreAuthorize("hasAuthority('supplier:view')")
    public java.util.List<SupplierDictItem> dict() {
        return service.dict();
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('supplier:view')")
    public SupplierDetail detail(@PathVariable UUID id) {
        SupplierDetail detail = service.detail(id);
        viewAudit.record(
                "view_supplier_detail", "suppliers", id,
                detail.getCode(), detail.getLegacyId(), "供应商档案");
        return detail;
    }

    // ---------- 加密 Excel 导出 (POST: 密码、关键字与手机/电话/银行账号筛选走 body; 其余过滤/排序走 query, 与 GET /list 一致) ----------

    @PostMapping("/export")
    @PreAuthorize("hasAuthority('supplier:export')")
    public ResponseEntity<byte[]> export(
            @RequestParam(required = false) UUID categoryId,
            @RequestParam(required = false) Set<String> nullFields,
            @RequestParam(required = false) String name,
            @RequestParam(required = false) String description,
            @RequestParam(required = false) Integer tday,
            @RequestParam(required = false) String place,
            @RequestParam(name = "empId", required = false) String empId,
            @RequestParam(name = "ownerEmployeeId", required = false) UUID ownerEmployeeId,
            @RequestParam(name = "legalPerson", required = false) String legalPerson,
            @RequestParam(required = false) String linkman,
            @RequestParam(required = false) String fax,
            @RequestParam(required = false) String postcode,
            @RequestParam(required = false) String address,
            @RequestParam(required = false) String bank,
            @RequestParam(name = "taxId", required = false) String taxId,
            @RequestParam(required = false) String website,
            @RequestParam(name = "shipVia", required = false) String shipVia,
            @RequestParam(name = "shipAddress", required = false) String shipAddress,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @Valid @RequestBody ContactExportRequest body) {
        ExportPayload payload = service.export(new SupplierQueryFilter(categoryId, body.sensitive().keyword(), nullFields,
                name, description, tday, place, empId, ownerEmployeeId, legalPerson, linkman,
                body.sensitive().mobile(), body.sensitive().phone(), body.sensitive().phone2(),
                fax, postcode, address, bank, body.sensitive().bankAccount(), taxId,
                website, shipVia, shipAddress), sort, order,
                exportLimits.exportMaxRows());
        byte[] xlsx = xlsxExport.build(payload.columns(), payload.rows());
        byte[] downloadBytes = workbookDownload.protect(xlsx, body.password());
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "export_supplier", "master_data", String.valueOf(payload.total()), "success"));
        String filename = "suppliers.xlsx";
        return ResponseEntity.ok()
                .header("Content-Disposition", DownloadContentDisposition.attachment(filename))
                .header("Content-Type",
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
                .body(downloadBytes);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('supplier:create')")
    public SupplierDetail create(@Valid @RequestBody SupplierSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAnyAuthority('supplier:edit', 'supplier:status')")
    public SupplierDetail update(@PathVariable UUID id, @Valid @RequestBody SupplierSaveRequest req) {
        return service.update(id, req);
    }

    @org.springframework.web.bind.annotation.PatchMapping("/{id}/status")
    @PreAuthorize("hasAuthority('supplier:status')")
    public SupplierDetail changeStatus(
            @PathVariable UUID id,
            @Valid @RequestBody com.uten.imp.features.master.dto.MasterStatusChangeRequest req) {
        return service.changeStatus(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('supplier:delete')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }
}
