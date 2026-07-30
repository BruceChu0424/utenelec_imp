package com.uten.imp.features.subcontract.report;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.EncryptedWorkbookService;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.ExportPasswordRequest;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.DownloadContentDisposition;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.format.annotation.DateTimeFormat.ISO;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 委外报表 API（委外管理，subcontract_report:view）。
 *
 * <p>9 张报表（前端每张一个卡片入口）：
 * <ul>
 *   <li>{@code GET /api/subcontract/reports/{doc}/{view}} —— 进仓/退货/材料出/材料退 各明细+汇总
 *      （doc ∈ receipt|return|material-issue|material-return；view ∈ detail|summary）。
 *       返回 {@link ReportTableResponse}（columns/rows/facets/page）。</li>
 *   <li>{@code GET /api/subcontract/reports/in-out-status} —— 委外出入状况表（综合，含期初/期末）。</li>
 *   <li>{@code GET /api/subcontract/reports/monthly} —— 月度汇总（MV 兜底，前端不再暴露入口）。</li>
 * </ul>
 *
 * <p>询价/申请/订货/损耗 无报表（用户要求删）。docType 取值见 {@link SubcontractReportService#monthly}。
 */
@RestController
@RequestMapping("/api/subcontract/reports")
@RequiredArgsConstructor
public class SubcontractReportController {

    private final SubcontractReportService service;
    private final XlsxExportService xlsxExport;
    private final EncryptedWorkbookService encryptedWorkbook;
    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;

    /** 8 张明细/汇总报表：doc/view 路由分发。 */
    @GetMapping("/{doc}/{view}")
    @PreAuthorize("hasAuthority('subcontract_report:view')")
    public ReportTableResponse table(
            @PathVariable String doc,
            @PathVariable String view,
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> f,   // f.<colKey>=<value> 表头 facet
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        // 只保留 f. 前缀的列筛选（其余 @RequestParam 已绑定）
        Map<String, String> facets = f == null ? Map.of()
                : f.entrySet().stream()
                    .filter(e -> e.getKey().startsWith("f."))
                    .collect(java.util.stream.Collectors.toMap(e -> e.getKey().substring(2), Map.Entry::getValue));
        String key = doc + "/" + view;
        return switch (key) {
            case "RECEIPT/detail"        -> service.receiptDetail(billNo, supplierId, warehouseId, status, dateFrom, dateTo, keyword, facets, page, size, sort, order);
            case "RECEIPT/summary"       -> service.receiptSummary(billNo, supplierId, warehouseId, status, dateFrom, dateTo, keyword, facets, page, size, sort, order);
            case "RETURN/detail"         -> service.returnDetail(billNo, supplierId, warehouseId, status, dateFrom, dateTo, keyword, facets, page, size, sort, order);
            case "RETURN/summary"        -> service.returnSummary(billNo, supplierId, warehouseId, status, dateFrom, dateTo, keyword, facets, page, size, sort, order);
            case "MATERIAL_ISSUE/detail" -> service.materialIssueDetail(billNo, supplierId, warehouseId, status, dateFrom, dateTo, keyword, facets, page, size, sort, order);
            case "MATERIAL_ISSUE/summary"-> service.materialIssueSummary(billNo, supplierId, warehouseId, status, dateFrom, dateTo, keyword, facets, page, size, sort, order);
            case "MATERIAL_RETURN/detail"-> service.materialReturnDetail(billNo, supplierId, warehouseId, status, dateFrom, dateTo, keyword, facets, page, size, sort, order);
            case "MATERIAL_RETURN/summary"-> service.materialReturnSummary(billNo, supplierId, warehouseId, status, dateFrom, dateTo, keyword, facets, page, size, sort, order);
            default -> throw new IllegalArgumentException("未知报表类型：" + key);
        };
    }

    /** 委外出入状况表（综合 O）。 */
    @GetMapping("/in-out-status")
    @PreAuthorize("hasAuthority('subcontract_report:view')")
    public ReportTableResponse inOutStatus(
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.inOutStatus(supplierId, dateFrom, dateTo, keyword, page, size);
    }

    // ---------- 加密导出（POST，密码走 body；过滤/排序走 query，与 GET 一致） ----------

    @PostMapping("/export")
    @PreAuthorize("hasAuthority('subcontract_report:export')")
    public ResponseEntity<byte[]> export(
            @RequestParam String report,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @Valid @RequestBody ExportPasswordRequest body) {
        ExportPayload payload = service.export(report, allParams, sort, order);
        byte[] xlsx = xlsxExport.build(payload.columns(), payload.rows());
        byte[] encrypted = encryptedWorkbook.encrypt(xlsx, body.password());
        // 审计：记录 谁 下载了 什么报表/多少行（工作台-系统管理 可查）。
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "export_subcontract_report", "subcontract_reports",
                report + "/" + payload.total() + "rows", "success"));
        String filename = "subcontract_" + report.replace('/', '_') + ".xlsx";
        return ResponseEntity.ok()
                .header("Content-Disposition", DownloadContentDisposition.attachment(filename))
                .header("Content-Type",
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
                .body(encrypted);
    }

    /** 月度汇总（MV，兜底；前端不再暴露入口）。 */
    @GetMapping("/monthly")
    @PreAuthorize("hasAuthority('subcontract_report:view')")
    public List<SubcontractMonthlyRow> monthly(
            @RequestParam(required = false) String docType,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "200") int limit) {
        return service.monthly(docType, dateFrom, dateTo, limit);
    }
}
