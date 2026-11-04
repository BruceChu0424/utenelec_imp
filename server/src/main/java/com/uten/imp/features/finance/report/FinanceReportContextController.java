package com.uten.imp.features.finance.report;

import com.uten.imp.features.finance.FinanceCompanyReportAccess;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;
import java.time.LocalDate;
import java.util.*;

/** Minimal source identities for the same company-wide financial report. */
@RestController @RequiredArgsConstructor
@RequestMapping("/api/finance/reports/context")
@PreAuthorize("hasAuthority('finance_report:view')")
@Transactional(readOnly=true)
public class FinanceReportContextController {
    private final EntityManager em;
    private final FinanceDocumentAccessPolicy access;
    @GetMapping("/plastic-bins")
    public Map<String,Object> plasticBins(
            @RequestParam @DateTimeFormat(iso=DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam @DateTimeFormat(iso=DateTimeFormat.ISO.DATE) LocalDate dateTo){
        FinanceCompanyReportAccess.require(access);
        if(dateFrom==null||dateTo==null||dateFrom.isAfter(dateTo))throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,"请选择先后正确的期间");
        @SuppressWarnings("unchecked") List<Object[]> values=em.createNativeQuery("""
                SELECT DISTINCT bin.id,bin.code,bin.name
                FROM v_workshop_material_period_report report JOIN warehouses bin ON bin.id=report.bin_warehouse_id
                WHERE report.close_id IS NOT NULL AND report.end_date BETWEEN :from AND :to
                ORDER BY bin.code,bin.name,bin.id LIMIT 1001
                """).setParameter("from",dateFrom).setParameter("to",dateTo).getResultList();
        if(values.size()>1000)throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,"本期料仓超过1000个，请缩小期间后选择");
        var rows=new ArrayList<Map<String,Object>>();for(var row:values){var item=new LinkedHashMap<String,Object>();item.put("id",row[0].toString());item.put("code",row[1]);item.put("name",row[2]);rows.add(item);}
        return Map.of("items",rows);
    }
}
