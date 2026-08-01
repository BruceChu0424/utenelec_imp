package com.uten.imp.features.production.report;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.EncryptedWorkbookService;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.ExportPasswordRequest;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.DownloadContentDisposition;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Valid;
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

import java.time.LocalDate;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 生产报表 API（生产管理，production_report:view）。
 *
 * <p>生产计划 2 张报表（服务端 JOIN 出名称 + 分页 + 列 facet 筛选，范式同采购/销售报表）：
 * <ul>
 *   <li>GET /api/production/reports/plan/detail?billNo=&goodsId=&status=&dateFrom=&dateTo=&keyword=&page=&size=
 *       — 生产计划明细（一行=单里一样货品，货品/类别/颜色名称服务端 JOIN）</li>
 *   <li>GET /api/production/reports/plan/summary?billNo=&status=&dateFrom=&dateTo=&keyword=&page=&size=
 *       — 生产计划汇总（一行=一整张单，制单员/审核员名 COALESCE(employees, 冻结名)）</li>
 * </ul>
 *
 * <p>通用参数：billNo / goodsId(仅明细) / status / dateFrom / dateTo / keyword / page / size。
 * 列筛选以 {@code f.<colKey>=<value>} 传（值 {@code __null__} 表空值档）。
 *
 * <p>保留：/daily/detail、/daily/summary（生产日报 <b>本期 0 行</b>，结构留位；前端未挂入口）。
 */
@RestController
@RequestMapping("/api/production/reports")
@RequiredArgsConstructor
public class ProductionReportController {

    private final ProductionReportService service;
    private final ProductionWhereUsedQueryService whereUsedQuery;
    private final XlsxExportService xlsxExport;
    private final EncryptedWorkbookService encryptedWorkbook;
    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;

    // ===== 生产计划（PLAN） =====

    @GetMapping("/plan/detail")
    @PreAuthorize("hasAuthority('production_report:view')")
    public ReportTableResponse planDetail(
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID goodsId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.planDetail(billNo, goodsId, status, dateFrom, dateTo, keyword, facetsOf(allParams), page, size, sort, order);
    }

    @GetMapping("/plan/summary")
    @PreAuthorize("hasAuthority('production_report:view')")
    public ReportTableResponse planSummary(
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
        return service.planSummary(billNo, status, dateFrom, dateTo, keyword, facetsOf(allParams), page, size, sort, order);
    }

    // ===== 物料反查产成品（BOM where-used） =====

    /**
     * 查一个原材料（materialGoodsId）被用在了哪些产成品上（按产成品汇总）。
     * GET /api/production/reports/where-used?materialGoodsId=&source=&dateFrom=&dateTo=&page=&size=&sort=&order=
     */
    @GetMapping("/where-used")
    @PreAuthorize("hasAuthority('production_where_used:view')")
    public ReportTableResponse whereUsed(
            @RequestParam UUID materialGoodsId,
            @RequestParam(defaultValue = "all") String source,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return whereUsedQuery.whereUsed(materialGoodsId, source, dateFrom, dateTo, page, size, sort, order);
    }

    /**
     * 物料反查专用货品搜索。它与报表共用权限，不要求 {@code goods:view}，
     * 因此工程/生产用户不会在“选材料”阶段被货品主档权限意外拦住。
     */
    @GetMapping("/where-used/materials")
    @PreAuthorize("hasAuthority('production_where_used:view')")
    public PageResponse<WhereUsedMaterialOption> whereUsedMaterials(
            @RequestParam(required = false) String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "30") int size) {
        return whereUsedQuery.searchWhereUsedMaterials(keyword, page, size);
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
    @PreAuthorize("hasAuthority('production_report:export')")
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
                "export_production_report", "production_reports",
                report + "/" + payload.total() + "rows", "success"));
        String filename = "production_" + report.replace('/', '_') + ".xlsx";
        return ResponseEntity.ok()
                .header("Content-Disposition", DownloadContentDisposition.attachment(filename))
                .header("Content-Type",
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
                .body(encrypted);
    }

    // ===== 生产日报（DAILY · 本期 0 行，结构留位；前端未挂入口） =====

    @GetMapping("/daily/detail")
    @PreAuthorize("hasAuthority('production_report:view')")
    public List<DailyDetailRow> dailyDetail(
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) UUID goodsId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) String billNo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.dailyDetail(dateFrom, dateTo, goodsId, status, billNo, page, size);
    }

    @GetMapping("/daily/summary")
    @PreAuthorize("hasAuthority('production_report:view')")
    public List<MonthlySummaryRow> dailySummary(
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "200") int limit) {
        return service.monthly("DAILY", dateFrom, dateTo, limit);
    }
}
