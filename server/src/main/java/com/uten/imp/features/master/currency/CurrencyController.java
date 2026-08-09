package com.uten.imp.features.master.currency;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.ExportPasswordRequest;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.DownloadContentDisposition;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.currency.dto.CurrencyDetail;
import com.uten.imp.features.master.currency.dto.CurrencyFacets;
import com.uten.imp.features.master.currency.dto.CurrencyListItem;
import com.uten.imp.features.master.currency.dto.CurrencyQueryFilter;
import com.uten.imp.features.master.currency.dto.CurrencySaveRequest;
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
 * 币种主档 API（基础资料-币种资料）。
 *
 * <p>扁平主档，无 categoryId：列表与 facets 全量查询，动态字段筛选。
 *
 * - GET  /api/master/currencies?keyword=&nullFields=&code=&name=&status=&page=1&size=20 → 分页
 * - GET  /api/master/currencies/facets                                                 → 各字段可选值 + 空值计数
 * - GET  /api/master/currencies/dict                                                   → 全量字典（采购单据选币种）
 * - GET  /api/master/currencies/{id}                                                    → 详情
 * - POST /api/master/currencies                                                         → 新建（currency:edit）
 * - PUT  /api/master/currencies/{id}                                                    → 编辑（currency:edit）
 * - DEL  /api/master/currencies/{id}                                                    → 删除（currency:edit，软删）
 *
 * 权限点 currency:view 由 V42 种子化（已授予全部未软删部门）；currency:edit 授 DEPT_PMC + 超管恒有。
 */
@RestController
@RequestMapping("/api/master/currencies")
@RequiredArgsConstructor
public class CurrencyController {

    private final CurrencyService service;
    private final XlsxExportService xlsxExport;
    private final WorkbookDownloadService workbookDownload;
    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;

    @GetMapping
    @PreAuthorize("hasAuthority('currency:view')")
    public PageResponse<CurrencyListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Set<String> nullFields,
            @RequestParam(required = false) String code,
            @RequestParam(required = false) String name,
            @RequestParam(required = false) String status,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.list(new CurrencyQueryFilter(keyword, nullFields, code, name, status), page, size, sort, order);
    }

    @GetMapping("/facets")
    @PreAuthorize("hasAuthority('currency:view')")
    public CurrencyFacets facets() {
        return service.facets();
    }

    /** 全量字典（采购单据选币种用；currency:view 全员有）。 */
    @GetMapping("/dict")
    @PreAuthorize("hasAuthority('currency:view')")
    public List<CurrencyListItem> dict() {
        return service.dict();
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('currency:view')")
    public CurrencyDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    // ---------- 加密 Excel 导出（POST，密码走 body；过滤/排序走 query，与 GET /list 一致） ----------

    @PostMapping("/export")
    @PreAuthorize("hasAuthority('currency:export')")
    public ResponseEntity<byte[]> export(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Set<String> nullFields,
            @RequestParam(required = false) String code,
            @RequestParam(required = false) String name,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @Valid @RequestBody ExportPasswordRequest body) {
        ExportPayload payload = service.export(
                new CurrencyQueryFilter(keyword, nullFields, code, name, status), sort, order);
        byte[] xlsx = xlsxExport.build(payload.columns(), payload.rows());
        byte[] downloadBytes = workbookDownload.protect(xlsx, body.password());
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "export_currency", "master_data", String.valueOf(payload.total()), "success"));
        String filename = "currencies.xlsx";
        return ResponseEntity.ok()
                .header("Content-Disposition", DownloadContentDisposition.attachment(filename))
                .header("Content-Type",
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
                .body(downloadBytes);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('currency:edit')")
    public CurrencyDetail create(@Valid @RequestBody CurrencySaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('currency:edit')")
    public CurrencyDetail update(@PathVariable UUID id, @Valid @RequestBody CurrencySaveRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('currency:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }
}
