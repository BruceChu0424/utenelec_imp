package com.uten.imp.features.purchase.report;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.EncryptedWorkbookService;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.ExportPasswordRequest;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.format.annotation.DateTimeFormat.ISO;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 采购报表 API（采购管理 / 采购报表，purchase_report:view）。
 *
 * <p>9 张报表（服务端 JOIN 出名称 + 分页 + 列 facet 筛选）：
 * <ul>
 *   <li>GET /expediting                    采购催料单（订货明细未收 + 库存/安全库存）</li>
 *   <li>GET /request/detail  /request/summary   采购申请 明细 / 汇总</li>
 *   <li>GET /order/detail    /order/summary     采购订货 明细 / 汇总</li>
 *   <li>GET /receipt/detail  /receipt/summary   采购收货 明细 / 汇总</li>
 *   <li>GET /return/detail   /return/summary    采购退货 明细 / 汇总</li>
 * </ul>
 *
 * <p>通用参数：billNo / supplierId / warehouseId / status / dateFrom / dateTo / keyword / page / size。
 * 列筛选以 {@code f.<colKey>=<value>} 传（值 {@code __null__} 表空值档）。
 *
 * <p>保留：/monthly（MV 上卷）、/pending（待交货视图）。
 */
@RestController
@RequestMapping("/api/purchase/reports")
@RequiredArgsConstructor
public class PurchaseReportController {

    private final PurchaseReportService service;
    private final XlsxExportService xlsxExport;
    private final EncryptedWorkbookService encryptedWorkbook;
    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;

    // ---------- 9 张报表 ----------

    @GetMapping("/expediting")
    @PreAuthorize("hasAuthority('purchase_report:view')")
    public ReportTableResponse expediting(
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.expediting(billNo, supplierId, dateFrom, dateTo, keyword, facetsOf(allParams), page, size, sort, order);
    }

    @GetMapping("/request/detail")
    @PreAuthorize("hasAuthority('purchase_report:view')")
    public ReportTableResponse requestDetail(
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.requestDetail(billNo, status, dateFrom, dateTo, keyword, facetsOf(allParams), page, size, sort, order);
    }

    @GetMapping("/request/summary")
    @PreAuthorize("hasAuthority('purchase_report:view')")
    public ReportTableResponse requestSummary(
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.requestSummary(billNo, status, dateFrom, dateTo, keyword, facetsOf(allParams), page, size, sort, order);
    }

    @GetMapping("/order/detail")
    @PreAuthorize("hasAuthority('purchase_report:view')")
    public ReportTableResponse orderDetail(
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.orderDetail(billNo, supplierId, status, dateFrom, dateTo, keyword, facetsOf(allParams), page, size, sort, order);
    }

    @GetMapping("/order/summary")
    @PreAuthorize("hasAuthority('purchase_report:view')")
    public ReportTableResponse orderSummary(
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.orderSummary(billNo, supplierId, status, dateFrom, dateTo, keyword, facetsOf(allParams), page, size, sort, order);
    }

    @GetMapping("/receipt/detail")
    @PreAuthorize("hasAuthority('purchase_report:view')")
    public ReportTableResponse receiptDetail(
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.receiptDetail(billNo, supplierId, warehouseId, status, dateFrom, dateTo, keyword, facetsOf(allParams), page, size, sort, order);
    }

    @GetMapping("/receipt/summary")
    @PreAuthorize("hasAuthority('purchase_report:view')")
    public ReportTableResponse receiptSummary(
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.receiptSummary(billNo, supplierId, warehouseId, status, dateFrom, dateTo, keyword, facetsOf(allParams), page, size, sort, order);
    }

    @GetMapping("/return/detail")
    @PreAuthorize("hasAuthority('purchase_report:view')")
    public ReportTableResponse returnDetail(
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.returnDetail(billNo, supplierId, warehouseId, status, dateFrom, dateTo, keyword, facetsOf(allParams), page, size, sort, order);
    }

    @GetMapping("/return/summary")
    @PreAuthorize("hasAuthority('purchase_report:view')")
    public ReportTableResponse returnSummary(
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.returnSummary(billNo, supplierId, warehouseId, status, dateFrom, dateTo, keyword, facetsOf(allParams), page, size, sort, order);
    }

    /** 从全部查询参数里抽出列筛选（键以 "f." 前缀）。 */
    private static Map<String, String> facetsOf(Map<String, String> allParams) {
        Map<String, String> facets = new HashMap<>();
        if (allParams == null) return facets;
        for (Map.Entry<String, String> e : allParams.entrySet()) {
            if (e.getKey().startsWith("f.") && e.getValue() != null && !e.getValue().isBlank()) {
                facets.put(e.getKey().substring(2), e.getValue());
            }
        }
        return facets;
    }

    // ---------- 加密导出（POST，密码走 body；过滤/排序走 query，与 GET 一致） ----------

    @PostMapping("/export")
    @PreAuthorize("hasAuthority('purchase_report:export')")
    public ResponseEntity<byte[]> export(
            @RequestParam String report,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @RequestBody ExportPasswordRequest body) {
        if (body == null || body.password() == null || body.password().length() < 4) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "导出密码至少 4 位");
        }
        ExportPayload payload = service.export(report, allParams, sort, order);
        byte[] xlsx = xlsxExport.build(payload.columns(), payload.rows());
        byte[] encrypted = encryptedWorkbook.encrypt(xlsx, body.password());
        // 审计：记录 谁 下载了 什么报表/多少行（工作台-系统管理 可查）。
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "export_purchase_report", "purchase_reports",
                report + "/" + payload.total() + "rows", "success"));
        String filename = "purchase_" + report.replace('/', '_') + ".xlsx";
        String encoded = URLEncoder.encode(filename, StandardCharsets.UTF_8).replace("+", "%20");
        return ResponseEntity.ok()
                .header("Content-Disposition", "attachment; filename*=UTF-8''" + encoded)
                .header("Content-Type",
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
                .body(encrypted);
    }

    // ---------- 保留 ----------

    @GetMapping("/monthly")
    @PreAuthorize("hasAuthority('purchase_report:view')")
    public List<MonthlySummaryRow> monthly(
            @RequestParam(required = false) String docType,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "200") int limit) {
        return service.monthly(docType, dateFrom, dateTo, limit);
    }

    @GetMapping("/pending")
    @PreAuthorize("hasAuthority('purchase_report:view')")
    public List<PendingRow> pending(@RequestParam(defaultValue = "200") int limit) {
        return service.pending(limit);
    }
}
