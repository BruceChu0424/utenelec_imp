package com.uten.imp.features.finance.report;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.ExportPasswordRequest;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.DownloadContentDisposition;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.format.annotation.DateTimeFormat.ISO;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

/**
 * 钱流报表 API（钱流管理 / 钱流报表，finance_report:view）。镜像销售/采购 {@code /{group}/{view}} 范式。
 *
 * <p>5 组 22 张报表（服务端 JOIN 出名称 + 分页 + 列 facet 筛选）：
 * <ul>
 *   <li><b>应收应付</b>：GET /ar-ap/overview（Z 树形）、/ar-ap/detail（A·C direction=AR/AP）、/ar-ap/summary（B·D）</li>
 *   <li><b>收付款</b>：GET /receipt/{detail,summary}（E·F）、/payment/{detail,summary}（G·H）</li>
 *   <li><b>费用收入</b>：GET /expense/{detail,summary}（M·N）、/income/{detail,summary}（O·P）、/fee-offset/detail（V）</li>
 *   <li><b>往来对帐</b>：GET /statement/{flow,detail,annual}?partyId&side=AR|AP（I·J·K·L·X）</li>
 *   <li><b>账户流水</b>：GET /account/statement?accountId（S）、/bank/{detail,summary}（Q·R 空表）</li>
 * </ul>
 *
 * <p>通用参数：billNo / clientId / supplierId / accountId / departmentId / status / dateFrom / dateTo /
 * keyword / direction / side / partyId / displayMode / categoryType / categoryId / year / page / size。
 * 列筛选以 {@code f.<colKey>=<value>} 传（值 {@code __null__} 表空值档）。
 * 五类单据型报表在服务层继续按 maker 本人/委托范围过滤；AR/AP、对账、账户流水等
 * 无法安全切片的公司级报表还要求超级管理员或 {@code finance:view:all}，否则返回 403。
 */
@RestController
@RequestMapping("/api/finance/reports")
@RequiredArgsConstructor
public class FinanceReportController {

    private final FinanceReportService service;
    private final XlsxExportService xlsxExport;
    private final WorkbookDownloadService workbookDownload;
    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;

    // ======================== ① 应收应付 Z / A·C / B·D ========================

    /** Z 应收应付总览（前端左分类树+右表）。displayMode: ALL/ANY/AR_ONLY/AP_ONLY。 */
    @GetMapping("/ar-ap/overview")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse overview(
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String displayMode,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) String categoryType,
            @RequestParam(required = false) UUID categoryId,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.arApOverview(dateFrom, dateTo, displayMode, keyword, categoryType, categoryId, page, size);
    }

    /** A/C 应收/应付明细。 */
    @GetMapping("/ar-ap/detail")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse arApDetail(
            @RequestParam String direction,
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID partyId,
            @RequestParam(required = false) Boolean settled,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.arApDetail(direction, billNo, partyId, settled, dateFrom, dateTo, keyword,
                facetsOf(allParams), page, size, sort, order);
    }

    /** 已审核销售订单待收计划（经营视图，不形成会计应收）。 */
    @GetMapping("/ar-ap/order-plan")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse salesOrderReceivablePlan(
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.salesOrderReceivablePlan(
                billNo, clientId, dateFrom, dateTo, keyword, page, size, sort, order);
    }

    /** B/D 应收/应付汇总（按往来单位）。 */
    @GetMapping("/ar-ap/summary")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse arApSummary(
            @RequestParam String direction,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.arApSummary(direction, dateFrom, dateTo, keyword, facetsOf(allParams), page, size, sort, order);
    }

    // ======================== ② 收付款 E·F / G·H ========================

    /** E 销售收款明细。 */
    @GetMapping("/receipt/detail")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse receiptDetail(
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) UUID accountId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.receiptDetail(billNo, clientId, accountId, status, dateFrom, dateTo, keyword,
                facetsOf(allParams), page, size, sort, order);
    }

    /** F 销售收款汇总。 */
    @GetMapping("/receipt/summary")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse receiptSummary(
            @RequestParam(required = false) String billNo,
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
        return service.receiptSummary(billNo, clientId, status, dateFrom, dateTo, keyword,
                facetsOf(allParams), page, size, sort, order);
    }

    /** G 采购付款明细。 */
    @GetMapping("/payment/detail")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse paymentDetail(
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID accountId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.paymentDetail(billNo, supplierId, accountId, status, dateFrom, dateTo, keyword,
                facetsOf(allParams), page, size, sort, order);
    }

    /** H 采购付款汇总。 */
    @GetMapping("/payment/summary")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse paymentSummary(
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
        return service.paymentSummary(billNo, supplierId, status, dateFrom, dateTo, keyword,
                facetsOf(allParams), page, size, sort, order);
    }

    // ======================== ③ 费用/收入 M·N / O·P + V ========================

    /** M 一般费用明细。 */
    @GetMapping("/expense/detail")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse expenseDetail(
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID accountId,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.expenseDetail(billNo, accountId, departmentId, status, dateFrom, dateTo, keyword,
                facetsOf(allParams), page, size, sort, order);
    }

    /** N 一般费用汇总。 */
    @GetMapping("/expense/summary")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse expenseSummary(
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.expenseSummary(billNo, departmentId, status, dateFrom, dateTo, keyword,
                facetsOf(allParams), page, size, sort, order);
    }

    /** O 其它收入明细。 */
    @GetMapping("/income/detail")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse incomeDetail(
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID accountId,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.incomeDetail(billNo, accountId, departmentId, status, dateFrom, dateTo, keyword,
                facetsOf(allParams), page, size, sort, order);
    }

    /** P 其它收入汇总。 */
    @GetMapping("/income/summary")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse incomeSummary(
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.incomeSummary(billNo, departmentId, status, dateFrom, dateTo, keyword,
                facetsOf(allParams), page, size, sort, order);
    }

    /** V 费用冲销明细（收款侧 + AR 核销 + 其它费用）。 */
    @GetMapping("/fee-offset/detail")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse feeOffsetDetail(
            @RequestParam(required = false) String billNo,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) UUID accountId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        return service.feeOffsetDetail(billNo, clientId, accountId, status, dateFrom, dateTo, keyword,
                facetsOf(allParams), page, size, sort, order);
    }

    // ======================== ④ 往来对帐 I·J·K·L / X ========================

    /** I/K 单客户/供应商流水对帐（滚动余额）。side=AR 走客户 / AP 走供应商。 */
    @GetMapping("/statement/flow")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse statementFlow(
            @RequestParam(required = false) UUID partyId,
            @RequestParam(required = false) String side,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.partyStatementFlow(partyId, side, dateFrom, dateTo, page, size);
    }

    /** J/L 单客户/供应商明细对帐。 */
    @GetMapping("/statement/detail")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse statementDetail(
            @RequestParam(required = false) UUID partyId,
            @RequestParam(required = false) String side,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.partyStatementDetail(partyId, side, dateFrom, dateTo, page, size);
    }

    /** X 客户/供应商年度对帐单（按月）。 */
    @GetMapping("/statement/annual")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse statementAnnual(
            @RequestParam(required = false) UUID partyId,
            @RequestParam(required = false) String side,
            @RequestParam(required = false, defaultValue = "0") int year,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.partyAnnualStatement(partyId, side, year, page, size);
    }

    // ======================== ⑤ 账户流水 S / 银行存取 Q·R ========================

    /** S 帐户进出流水帐（滚动余额，必填 accountId）。 */
    @GetMapping("/account/statement")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse accountStatement(
            @RequestParam(required = false) UUID accountId,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.accountStatement(accountId, dateFrom, dateTo, keyword, page, size);
    }

    /** Q 银行存取明细 / R 汇总（M_Bank 0 行，空结构）。 */
    @GetMapping("/bank/{view}")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse bank(@PathVariable String view) {
        return service.bankReport(view);
    }

    // ---------- 加密导出（POST，密码走 body；过滤/排序走 query，与 GET 一致） ----------

    @PostMapping("/export")
    @PreAuthorize("hasAuthority('finance_report:export')")
    public ResponseEntity<byte[]> export(
            @RequestParam String report,
            @RequestParam(required = false) Map<String, String> allParams,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order,
            @Valid @RequestBody ExportPasswordRequest body) {
        ExportPayload payload = service.export(report, allParams, sort, order);
        byte[] xlsx = xlsxExport.build(payload.columns(), payload.rows());
        byte[] downloadBytes = workbookDownload.protect(xlsx, body.password());
        // 审计：记录 谁 下载了 什么报表/多少行（工作台-系统管理 可查）。
        currentUser.get().ifPresent(u -> audit.logExplicit(u.getId(), u.getLoginAccount(),
                "export_finance_report", "finance_reports",
                report + "/" + payload.total() + "rows", "success"));
        String filename = "finance_" + report.replace('/', '_') + ".xlsx";
        return ResponseEntity.ok()
                .header("Content-Disposition", DownloadContentDisposition.attachment(filename))
                .header("Content-Type",
                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
                .body(downloadBytes);
    }

    // ======================== 辅助 ========================

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
}
