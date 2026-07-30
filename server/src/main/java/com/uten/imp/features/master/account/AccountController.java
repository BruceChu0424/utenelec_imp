package com.uten.imp.features.master.account;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.EncryptedWorkbookService;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.ExportPasswordRequest;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.DownloadContentDisposition;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.account.dto.AccountDetail;
import com.uten.imp.features.master.account.dto.AccountFacets;
import com.uten.imp.features.master.account.dto.AccountListItem;
import com.uten.imp.features.master.account.dto.AccountQueryFilter;
import com.uten.imp.features.master.account.dto.AccountSaveRequest;
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

import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * 账户主档 API（基础资料-账户资料）。
 *
 * - GET  /api/master/accounts?keyword=&nullFields=&code=&name=&accountType=&currencyId=&status=&page=1&size=20 → 分页
 * - GET  /api/master/accounts/facets                                                  → 各字段可选值 + 空值计数
 * - GET  /api/master/accounts/dict                                                     → 全量字典（钱流单据选账户）
 * - GET  /api/master/accounts/{id}                                                     → 详情
 * - POST /api/master/accounts                                                          → 新建（account:edit）
 * - PUT  /api/master/accounts/{id}                                                     → 编辑（account:edit）
 * - DEL  /api/master/accounts/{id}                                                     → 删除（account:edit，软删）
 *
 * 权限点 account:view / account:edit 由 V50 种子化（view 全员、edit 授 DEPT_FIN；超管恒有）。
 */
@RestController
@RequestMapping("/api/master/accounts")
@RequiredArgsConstructor
public class AccountController {

    private final AccountService service;
    private final XlsxExportService xlsxExport;
    private final EncryptedWorkbookService encryptedWorkbook;
    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;

    @GetMapping
    @PreAuthorize("hasAuthority('account:view')")
    public PageResponse<AccountListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Set<String> nullFields,
            @RequestParam(required = false) String code,
            @RequestParam(required = false) String name,
            @RequestParam(required = false) String accountType,
            @RequestParam(required = false) UUID currencyId,
            @RequestParam(required = false) String status,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(
                new AccountQueryFilter(keyword, nullFields, code, name, accountType, currencyId, status),
                page, size, sort, order);
    }

    @GetMapping("/facets")
    @PreAuthorize("hasAuthority('account:view')")
    public AccountFacets facets() {
        return service.facets();
    }

    /** 全量字典（钱流单据选账户用；account:view 全员有）。 */
    @GetMapping("/dict")
    @PreAuthorize("hasAuthority('account:view')")
    public List<AccountListItem> dict() {
        return service.dict();
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('account:view')")
    public AccountDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    // ---------- 加密 Excel 导出（POST，密码走 body；过滤/排序走 query，与 GET /list 一致） ----------

    @PostMapping("/export")
    @PreAuthorize("hasAuthority('account:export')")
    public ResponseEntity<byte[]> export(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Set<String> nullFields,
            @RequestParam(required = false) String code,
            @RequestParam(required = false) String name,
            @RequestParam(required = false) String accountType,
            @RequestParam(required = false) UUID currencyId,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @Valid @RequestBody ExportPasswordRequest body) {
        ExportPayload payload = service.export(
                new AccountQueryFilter(keyword, nullFields, code, name, accountType, currencyId, status),
                sort, order);
        byte[] xlsx = xlsxExport.build(payload.columns(), payload.rows());
        byte[] encrypted = encryptedWorkbook.encrypt(xlsx, body.password());
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "export_account", "master_data", String.valueOf(payload.total()), "success"));
        String filename = "accounts.xlsx";
        return ResponseEntity.ok()
                .header("Content-Disposition", DownloadContentDisposition.attachment(filename))
                .header("Content-Type",
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
                .body(encrypted);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('account:edit')")
    public AccountDetail create(@Valid @RequestBody AccountSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('account:edit')")
    public AccountDetail update(@PathVariable UUID id, @Valid @RequestBody AccountSaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('account:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }
}
