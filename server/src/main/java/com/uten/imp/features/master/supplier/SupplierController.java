package com.uten.imp.features.master.supplier;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.ExportPasswordRequest;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.DownloadContentDisposition;
import com.uten.imp.common.web.PageResponse;
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
 * - GET  /api/master/suppliers?categoryId=&keyword=&nullFields=&name=...&page=1&size=20 → 分页
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
    private final SecurityContextCurrentUser currentUser;

    @GetMapping
    @PreAuthorize("hasAuthority('supplier:view')")
    public PageResponse<SupplierListItem> list(
            @RequestParam(required = false) UUID categoryId,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Set<String> nullFields,
            @RequestParam(required = false) String name,
            @RequestParam(required = false) String description,
            @RequestParam(required = false) Integer tday,
            @RequestParam(required = false) String place,
            @RequestParam(name = "empId", required = false) String empId,
            @RequestParam(name = "legalPerson", required = false) String legalPerson,
            @RequestParam(required = false) String linkman,
            @RequestParam(required = false) String mobile,
            @RequestParam(required = false) String phone,
            @RequestParam(name = "phone2", required = false) String phone2,
            @RequestParam(required = false) String fax,
            @RequestParam(required = false) String postcode,
            @RequestParam(required = false) String address,
            @RequestParam(required = false) String bank,
            @RequestParam(name = "bankAccount", required = false) String bankAccount,
            @RequestParam(name = "taxId", required = false) String taxId,
            @RequestParam(required = false) String website,
            @RequestParam(name = "shipVia", required = false) String shipVia,
            @RequestParam(name = "shipAddress", required = false) String shipAddress,
            @RequestParam(defaultValue = "false") boolean selectableOnly,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new SupplierQueryFilter(categoryId, keyword, nullFields,
                name, description, tday, place, empId, legalPerson, linkman, mobile,
                phone, phone2, fax, postcode, address, bank, bankAccount, taxId,
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
        return service.detail(id);
    }

    // ---------- 加密 Excel 导出（POST，密码走 body；过滤/排序走 query，与 GET /list 一致） ----------

    @PostMapping("/export")
    @PreAuthorize("hasAuthority('supplier:export')")
    public ResponseEntity<byte[]> export(
            @RequestParam(required = false) UUID categoryId,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Set<String> nullFields,
            @RequestParam(required = false) String name,
            @RequestParam(required = false) String description,
            @RequestParam(required = false) Integer tday,
            @RequestParam(required = false) String place,
            @RequestParam(name = "empId", required = false) String empId,
            @RequestParam(name = "legalPerson", required = false) String legalPerson,
            @RequestParam(required = false) String linkman,
            @RequestParam(required = false) String mobile,
            @RequestParam(required = false) String phone,
            @RequestParam(name = "phone2", required = false) String phone2,
            @RequestParam(required = false) String fax,
            @RequestParam(required = false) String postcode,
            @RequestParam(required = false) String address,
            @RequestParam(required = false) String bank,
            @RequestParam(name = "bankAccount", required = false) String bankAccount,
            @RequestParam(name = "taxId", required = false) String taxId,
            @RequestParam(required = false) String website,
            @RequestParam(name = "shipVia", required = false) String shipVia,
            @RequestParam(name = "shipAddress", required = false) String shipAddress,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @Valid @RequestBody ExportPasswordRequest body) {
        ExportPayload payload = service.export(new SupplierQueryFilter(categoryId, keyword, nullFields,
                name, description, tday, place, empId, legalPerson, linkman, mobile,
                phone, phone2, fax, postcode, address, bank, bankAccount, taxId,
                website, shipVia, shipAddress), sort, order);
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
