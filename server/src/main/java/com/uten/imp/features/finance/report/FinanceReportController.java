package com.uten.imp.features.finance.report;

import com.uten.imp.features.finance.report.dto.AccountStatementRow;
import com.uten.imp.features.finance.report.dto.ArApDetailReportRow;
import com.uten.imp.features.finance.report.dto.ArApSummaryRow;
import com.uten.imp.features.finance.report.dto.FinanceDocReportRow;
import com.uten.imp.features.finance.report.dto.FinanceDocSummaryRow;
import com.uten.imp.features.finance.report.dto.PartyAnnualStatementRow;
import com.uten.imp.features.finance.report.dto.PartyStatementRow;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.format.annotation.DateTimeFormat.ISO;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/**
 * 钱流报表 API（钱流报表 · {@code finance_report:view}）。
 *
 * <p>4 大类 22+ 报表端点（按 design doc 26 §六）：
 *
 * <h3>A. 应收应付类（10）</h3>
 * <ul>
 *   <li>GET /api/finance/reports/ar-ap/summary   — Z 总览 / B 应收汇总 / D 应付汇总（MV 上卷，direction 区分）</li>
 *   <li>GET /api/finance/reports/ar-ap/detail    — A 应收明细 / C 应付明细</li>
 *   <li>GET /api/finance/reports/parties/statement — I/J 单客户对账 / K/L 单供应商对账（side=AR/AP）</li>
 *   <li>GET /api/finance/reports/parties/annual-statement — X 客户/供应商年度对账单</li>
 * </ul>
 *
 * <h3>B. 收付款单据类（4）</h3>
 * <ul>
 *   <li>GET /api/finance/reports/receipts/detail + /summary — E/F 销售收款</li>
 *   <li>GET /api/finance/reports/payments/detail + /summary — G/H 采购付款</li>
 * </ul>
 *
 * <h3>C. 费用收入类（5）</h3>
 * <ul>
 *   <li>GET /api/finance/reports/expenses/detail + /summary — M/N 一般费用（费用冲销明细同 M）</li>
 *   <li>GET /api/finance/reports/incomes/detail + /summary — O/P 其它收入</li>
 * </ul>
 *
 * <h3>D. 账户流水类（3）</h3>
 * <ul>
 *   <li>GET /api/finance/reports/accounts/statement — S 帐户进出流水帐</li>
 *   <li>Q/R 银行存取款（空表，复用 /api/finance/bank-transfers 列表查询）</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/finance/reports")
@RequiredArgsConstructor
public class FinanceReportController {

    private final FinanceReportService service;

    // ============= A. 应收应付类 =============

    @GetMapping("/ar-ap/summary")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public List<ArApSummaryRow> arApSummary(
            @RequestParam(required = false) String direction,
            @RequestParam(required = false) String sourceDocType,
            @RequestParam(required = false) UUID partyId,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "500") int limit) {
        return service.arApSummary(direction, sourceDocType, partyId, dateFrom, dateTo, limit);
    }

    @GetMapping("/ar-ap/detail")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public List<ArApDetailReportRow> arApDetail(
            @RequestParam(required = false) String direction,
            @RequestParam(required = false) String sourceDocType,
            @RequestParam(required = false) UUID partyId,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) Boolean settled,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "500") int limit) {
        return service.arApDetail(direction, sourceDocType, partyId, clientId, supplierId, settled, dateFrom, dateTo, limit);
    }

    @GetMapping("/parties/statement")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public List<PartyStatementRow> partyStatement(
            @RequestParam UUID partyId,
            @RequestParam(defaultValue = "AR") String side,            // AR=客户 / AP=供应商
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1000") int limit) {
        return service.partyStatement(partyId, side, dateFrom, dateTo, limit);
    }

    @GetMapping("/parties/annual-statement")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public PartyAnnualStatementRow partyAnnualStatement(
            @RequestParam UUID partyId,
            @RequestParam(defaultValue = "AR") String side,
            @RequestParam(defaultValue = "2026") int year) {
        return service.partyAnnualStatement(partyId, side, year);
    }

    // ============= B. 收付款单据类 =============

    @GetMapping("/receipts/detail")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public List<FinanceDocReportRow> receiptsDetail(
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) UUID accountId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "500") int limit) {
        return service.receiptsDetail(clientId, accountId, status, dateFrom, dateTo, limit);
    }

    @GetMapping("/receipts/summary")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public List<FinanceDocSummaryRow> receiptsSummary(
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "500") int limit) {
        return service.receiptsSummary(clientId, dateFrom, dateTo, limit);
    }

    @GetMapping("/payments/detail")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public List<FinanceDocReportRow> paymentsDetail(
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID accountId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "500") int limit) {
        return service.paymentsDetail(supplierId, accountId, status, dateFrom, dateTo, limit);
    }

    @GetMapping("/payments/summary")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public List<FinanceDocSummaryRow> paymentsSummary(
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "500") int limit) {
        return service.paymentsSummary(supplierId, dateFrom, dateTo, limit);
    }

    // ============= C. 费用收入类 =============

    @GetMapping("/expenses/detail")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public List<FinanceDocReportRow> expensesDetail(
            @RequestParam(required = false) UUID accountId,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "500") int limit) {
        return service.expensesDetail(accountId, departmentId, status, dateFrom, dateTo, limit);
    }

    @GetMapping("/expenses/summary")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public List<FinanceDocSummaryRow> expensesSummary(
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(required = false) UUID expenseStyleId,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "500") int limit) {
        return service.expensesSummary(departmentId, expenseStyleId, dateFrom, dateTo, limit);
    }

    @GetMapping("/incomes/detail")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public List<FinanceDocReportRow> incomesDetail(
            @RequestParam(required = false) UUID accountId,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "500") int limit) {
        return service.incomesDetail(accountId, departmentId, status, dateFrom, dateTo, limit);
    }

    @GetMapping("/incomes/summary")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public List<FinanceDocSummaryRow> incomesSummary(
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(required = false) UUID incomeStyleId,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "500") int limit) {
        return service.incomesSummary(departmentId, incomeStyleId, dateFrom, dateTo, limit);
    }

    // ============= D. 账户流水类 =============

    @GetMapping("/accounts/statement")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public List<AccountStatementRow> accountStatement(
            @RequestParam UUID accountId,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE_TIME) OffsetDateTime dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = ISO.DATE_TIME) OffsetDateTime dateTo,
            @RequestParam(defaultValue = "1000") int limit) {
        return service.accountStatement(accountId, dateFrom, dateTo, limit);
    }
}
