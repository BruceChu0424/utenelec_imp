package com.uten.imp.features.finance.statement;

import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.report.*;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.time.LocalDate;
import java.util.UUID;
import static org.springframework.format.annotation.DateTimeFormat.ISO;

@RestController
@RequiredArgsConstructor
@RequestMapping("/api/finance/reports/auxiliary")
@PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all')")
@org.springframework.transaction.annotation.Transactional(readOnly=true)
public class FinanceAuxiliaryReportController {
    private final EntityManager em;
    private final FinanceDocumentAccessPolicy access;
    @GetMapping("/{side}") public ReportTableResponse balances(@PathVariable String side,
            @RequestParam @DateTimeFormat(iso=ISO.DATE)LocalDate dateFrom,@RequestParam @DateTimeFormat(iso=ISO.DATE)LocalDate dateTo,
            @RequestParam(required=false)String accountCode,@RequestParam(required=false)UUID auxiliaryId,
            @RequestParam(required=false) UUID currencyId,@RequestParam(required=false)String sourceSystem,
            @RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size) {
        if(!side.equals("receivable")&&!side.equals("payable"))throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,"辅助报表类别无效");
        return FinanceAuxiliaryReports.balances(em,access,side.equals("receivable"),dateFrom,dateTo,accountCode,auxiliaryId,currencyId,sourceSystem,page,size,FinanceReportColumnOptions.current());
    }
}
