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
    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.common.readsnapshot.VersionedSummaryPages summaryPages;

    /** Equivalent membership of the original period report: at least one
     * period line and an active close. Do not evaluate monetary projections or
     * join close-material multiplicity merely to select a bin identity. */
    private static final String BIN_SCOPE="""
        FROM workshop_material_periods period JOIN warehouses bin ON bin.id=period.bin_warehouse_id
        WHERE period.end_date BETWEEN :from AND :to
          AND EXISTS(SELECT 1 FROM workshop_material_period_lines line WHERE line.period_id=period.id)
          AND EXISTS(SELECT 1 FROM workshop_material_period_closes closed WHERE closed.period_id=period.id AND closed.status='ACTIVE')
        """;

    @GetMapping("/plastic-bins/summaries")
    public com.uten.imp.common.readsnapshot.VersionedSummaryPages.Page<Map<String,Object>> plasticBinSummaries(
            @RequestParam @DateTimeFormat(iso=DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam @DateTimeFormat(iso=DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="1000") int size,
            @RequestParam(required=false) String readSnapshotRevision){
        validatePeriod(dateFrom,dateTo);
        var request=new com.uten.imp.common.readsnapshot.VersionedSummaryPages.Request(
            "finance-plastic-bin-contexts","finance",Arrays.asList("plastic-bin-context-v1",dateFrom,dateTo),"all",page,size,1000,readSnapshotRevision);
        return summaryPages.page(request,()->{FinanceCompanyReportAccess.require(access);validatePeriod(dateFrom,dateTo);},
            ()->((Number)em.createNativeQuery("SELECT count(*) FROM (SELECT DISTINCT bin.id "+BIN_SCOPE+") scoped")
                .setParameter("from",dateFrom).setParameter("to",dateTo).getSingleResult()).longValue(),
            (batch,batchSize)->{
                @SuppressWarnings("unchecked") List<Object[]> values=em.createNativeQuery(
                    "SELECT DISTINCT bin.id,bin.code,bin.name "+BIN_SCOPE+" ORDER BY bin.code,bin.name,bin.id LIMIT :batchSize OFFSET :offset")
                    .setParameter("from",dateFrom).setParameter("to",dateTo).setParameter("batchSize",batchSize)
                    .setParameter("offset",Math.multiplyExact((long)batch-1,batchSize)).getResultList();
                var rows=new ArrayList<Map<String,Object>>();
                for(var value:values){var row=new LinkedHashMap<String,Object>();row.put("id",value[0].toString());row.put("code",value[1]);row.put("name",value[2]);rows.add(row);}
                return rows;
            });
    }
    private static void validatePeriod(LocalDate from,LocalDate to){
        if(from==null||to==null||from.isAfter(to))throw new com.uten.imp.common.web.ApiException(
            com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,"请选择先后正确的期间");
    }

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
