package com.uten.imp.features.stock.report;

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
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

/**
 * 仓库报表 API（仓库管理 / 仓库报表，stock_report:view）。
 *
 * <p>14 张报表（服务端 JOIN 出名称 + 分页 + 列 facet 筛选），7 单据类型 × 明细/汇总：
 * <ul>
 *   <li>GET /{docType}/detail  /{docType}/summary   调拨/其它入库/领料/退料/产成品进仓/出仓/盘点 各明细/汇总</li>
 * </ul>
 * docType ∈ { TRANSFER, OTHER_IN, DRAW, WDRAW, FINISHED_IN, FINISHED_OUT, CHECK }（无 OTHER_OUT/WASTE，用户指定删除）。
 *
 * <p>通用参数：billNo / warehouseId / clientId / status / dateFrom / dateTo / keyword / page / size。
 * 列筛选以 {@code f.<colKey>=<value>} 传（值 {@code __null__} 表空值档）。
 *
 * <p>明细表：一行=单里一样货品（同单号重复）；汇总表：一行=一整张单（单号唯一）。
 */
@RestController
@RequestMapping("/api/stock/reports")
@RequiredArgsConstructor
public class StockReportController {

    private final StockReportService service;
    private final XlsxExportService xlsxExport;
    private final EncryptedWorkbookService encryptedWorkbook;
    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;

    /** 明细报表（7 单据类型参数化；docType 决定列集 + 标签）。 */
    @GetMapping("/{docType}/detail")
    @PreAuthorize("hasAuthority('stock_report:view')")
    public ReportTableResponse detail(
            @PathVariable String docType,
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.detail(docType, billNo, warehouseId, clientId, status, dateFrom, dateTo, keyword,
                facetsOf(allParams), page, size, sort, order);
    }

    /** 汇总报表（7 单据类型参数化；一行一单号）。 */
    @GetMapping("/{docType}/summary")
    @PreAuthorize("hasAuthority('stock_report:view')")
    public ReportTableResponse summary(
            @PathVariable String docType,
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID warehouseId,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.summary(docType, billNo, warehouseId, clientId, status, dateFrom, dateTo, keyword,
                facetsOf(allParams), page, size, sort, order);
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
    @PreAuthorize("hasAuthority('stock_report:export')")
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
                "export_stock_report", "stock_reports",
                report + "/" + payload.total() + "rows", "success"));
        String filename = "stock_" + report.replace('/', '_') + ".xlsx";
        String encoded = URLEncoder.encode(filename, StandardCharsets.UTF_8).replace("+", "%20");
        return ResponseEntity.ok()
                .header("Content-Disposition", "attachment; filename*=UTF-8''" + encoded)
                .header("Content-Type",
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
                .body(encrypted);
    }
}
