package com.uten.imp.features.finance.statement;

import com.uten.imp.features.finance.report.ReportTableResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.math.BigDecimal;
import java.time.LocalDate;

import static org.springframework.format.annotation.DateTimeFormat.ISO;

/**
 * 月结对账单 API（C2 · 财务 5 张手工对账单自动生成；模板列结构照抄附件 Excel）。
 *
 * <ul>
 *   <li>GET /api/finance/reports/statements/subcontract —— 附件 1 委外加工对账单（兼「采购外放加工对账单」）；
 *       参数 lossRate 默认 0.03（允许生产损耗 3%，铜材/特殊件传 0.05）。</li>
 *   <li>GET /api/finance/reports/statements/supplier —— 附件 2 供应商对账单（收货+退货负数行）。</li>
 *   <li>GET /api/finance/reports/statements/other-receivable —— 附件 4 其他应收款对账单（铜材加工按重量，损耗 0.5%）。</li>
 *   <li>GET /api/finance/reports/statements/client —— 附件 5 应收账款客户对账单（出货+退货负数行）。</li>
 * </ul>
 *
 * <p>通用参数：keyword（往来单位名称/编号）/ dateFrom / dateTo / page / size。权限 {@code finance_report:view}。
 * 路径挂在 /finance/reports/ 下，前端导出按钮（/finance/reports/export，report=statements/xxx）直接可用。</p>
 */
@RestController
@RequestMapping("/api/finance/reports/statements")
@RequiredArgsConstructor
public class FinanceStatementController {

    private final FinanceStatementService service;

    /** 附件 1 · 委外加工对账单（前端两个 chip 共用：委外加工 / 采购外放加工）。 */
    @GetMapping("/subcontract")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse subcontract(
            @RequestParam(required = false) String keyword,
            @RequestParam @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) BigDecimal lossRate,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.subcontractStatement(keyword, dateFrom, dateTo, lossRate, page, size);
    }

    /** 附件 2 · 供应商对账单。 */
    @GetMapping("/supplier")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse supplier(
            @RequestParam(required = false) String keyword,
            @RequestParam @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.supplierStatement(keyword, dateFrom, dateTo, page, size);
    }

    /** 附件 4 · 其他应收款对账单（铜材加工）。 */
    @GetMapping("/other-receivable")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse otherReceivable(
            @RequestParam(required = false) String keyword,
            @RequestParam @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.otherReceivableStatement(keyword, dateFrom, dateTo, page, size);
    }

    /** 附件 5 · 应收账款客户对账单。 */
    @GetMapping("/client")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse client(
            @RequestParam(required = false) String keyword,
            @RequestParam @DateTimeFormat(iso = ISO.DATE) LocalDate dateFrom,
            @RequestParam @DateTimeFormat(iso = ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return service.clientStatement(keyword, dateFrom, dateTo, page, size);
    }
}
