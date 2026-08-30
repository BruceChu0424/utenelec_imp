package com.uten.imp.features.master.client;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.ExportPasswordRequest;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.DownloadContentDisposition;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.client.dto.ClientDetail;
import com.uten.imp.features.master.client.dto.ClientDictItem;
import com.uten.imp.features.master.client.dto.ClientFacets;
import com.uten.imp.features.master.client.dto.ClientListItem;
import com.uten.imp.features.master.client.dto.ClientQueryFilter;
import com.uten.imp.features.master.client.dto.ClientSaveRequest;
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
 * 权限点 client:view 由种子化（全部部门）；client:edit 授综合营销部（超管恒有）。
 */
@RestController
@RequestMapping("/api/master/clients")
@RequiredArgsConstructor
public class ClientController {

    private final ClientService service;
    private final XlsxExportService xlsxExport;
    private final WorkbookDownloadService workbookDownload;
    private final AuditService audit;
    private final AuditDetailViewRecorder viewAudit;
    private final SecurityContextCurrentUser currentUser;

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
            @RequestParam(defaultValue = "true") boolean excludeLegacyFinanceStub,
            @RequestParam(defaultValue = "false") boolean selectableOnly,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new ClientQueryFilter(categoryId, keyword, nullFields,
                code, name, fullName, clientXz, tday, region, placeId, empId,
                legalPerson, linkman, mobile, phone, phone2, fax, postcode,
                address, bank, bankAccount, taxId, credit, website,
                excludeLegacyFinanceStub, selectableOnly), page, size, sort, order);
    }

    @GetMapping("/facets")
    @PreAuthorize("hasAuthority('client:view')")
    public ClientFacets facets(
            @RequestParam UUID categoryId,
            @RequestParam(defaultValue = "true") boolean excludeLegacyFinanceStub) {
        return service.facets(categoryId, excludeLegacyFinanceStub);
    }

    /** 全量字典（单据客户名解析用；client:view 全员有）。 */
    @GetMapping("/dict")
    @PreAuthorize("hasAuthority('client:view')")
    public java.util.List<ClientDictItem> dict(
            @RequestParam(defaultValue = "true") boolean excludeLegacyFinanceStub) {
        return service.dict(excludeLegacyFinanceStub);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('client:view')")
    public ClientDetail detail(@PathVariable UUID id) {
        ClientDetail detail = service.detail(id);
        viewAudit.record(
                "view_client_detail", "clients", id,
                detail.getCode(), detail.getLegacyId(), "客户档案");
        return detail;
    }

    // ---------- 加密 Excel 导出（POST，密码走 body；过滤/排序走 query，与 GET /list 一致） ----------

    @PostMapping("/export")
    @PreAuthorize("hasAuthority('client:export')")
    public ResponseEntity<byte[]> export(
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
            @RequestParam(defaultValue = "true") boolean excludeLegacyFinanceStub,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @Valid @RequestBody ExportPasswordRequest body) {
        ExportPayload payload = service.export(new ClientQueryFilter(categoryId, keyword, nullFields,
                code, name, fullName, clientXz, tday, region, placeId, empId,
                legalPerson, linkman, mobile, phone, phone2, fax, postcode,
                address, bank, bankAccount, taxId, credit, website,
                excludeLegacyFinanceStub, false), sort, order);
        byte[] xlsx = xlsxExport.build(payload.columns(), payload.rows());
        byte[] downloadBytes = workbookDownload.protect(xlsx, body.password());
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "export_client", "master_data", String.valueOf(payload.total()), "success"));
        String filename = "clients.xlsx";
        return ResponseEntity.ok()
                .header("Content-Disposition", DownloadContentDisposition.attachment(filename))
                .header("Content-Type",
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
                .body(downloadBytes);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('client:create')")
    public ClientDetail create(@Valid @RequestBody ClientSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAnyAuthority('client:edit', 'client:status')")
    public ClientDetail update(@PathVariable UUID id, @Valid @RequestBody ClientSaveRequest req) {
        return service.update(id, req);
    }

    @org.springframework.web.bind.annotation.PatchMapping("/{id}/status")
    @PreAuthorize("hasAuthority('client:status')")
    public ClientDetail changeStatus(
            @PathVariable UUID id,
            @Valid @RequestBody com.uten.imp.features.master.dto.MasterStatusChangeRequest req) {
        return service.changeStatus(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('client:delete')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }
}
