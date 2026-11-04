package com.uten.imp.features.finance.gl;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.util.*;

/** Reads reviewed direction-preserving labor attribution in the report's own snapshot. */
final class FinanceManufacturingLabor {
    private FinanceManufacturingLabor() { }
    static GlReportLineSource.Bindings apply(EntityManager em,int year,Map<String,BigDecimal[]> data,GlReportLineSource.Bindings bindings) {
        Map<String,List<String>> names=new HashMap<>(bindings.namesByLine());
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT substring(COALESCE(p.period,s.period::text) FROM 6 FOR 2)::int,
                    s.reviewed AND NOT p.pending AND p.source_fingerprint=s.source_fingerprint
                    AND s.direct_positive+s.indirect_positive=p.positive_amount
                    AND s.direct_negative+s.indirect_negative=p.negative_amount AS valid,
                    s.direct_positive-s.direct_negative,s.indirect_positive-s.indirect_negative
                FROM v_finance_manufacturing_labor_pool p FULL JOIN finance_manufacturing_labor_splits s ON s.period::text=p.period
                WHERE COALESCE(p.period,s.period::text) BETWEEN :from AND :to
                """).setParameter("from","%04d-01".formatted(year)).setParameter("to","%04d-12".formatted(year)))) {
            int month=((Number)row[0]).intValue();boolean valid=Boolean.TRUE.equals(row[1]);
            for(int n=0;n<2;n++) {
                String key=n==0?"LABOR_DIRECT":"LABOR_INDIRECT";
                BigDecimal[] values=data.computeIfAbsent(key,k->new BigDecimal[13]);
                values[month]=valid?(BigDecimal)row[n+2]:null;
                names.put(key,List.of(valid?"已核对410106工资源池分配":"410106工资源池分配待核对"));
            }
        }
        return new GlReportLineSource.Bindings(Map.copyOf(names),bindings.confirmedZero());
    }
    static Set<Integer> uncoveredMonths(EntityManager em,int year) {
        Set<Integer> result=new HashSet<>();for(Object month:em.createNativeQuery("""
                SELECT DISTINCT EXTRACT(MONTH FROM e.entry_date)::int FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id
                WHERE NOT e.is_deleted AND public.fn_finance_gl_voucher_is_booked(v.id) AND e.amount<>0
                  AND (fn_finance_manufacturing_occurrence(e.id)<>0 OR fn_finance_manufacturing_occurrence(e.id) IS NULL)
                  AND e.entry_date BETWEEN :from AND :to AND NOT public.fn_finance_entry_is_pnl_closing(e.id)
                  AND EXISTS(SELECT 1 FROM finance_chart_code_styles m WHERE m.style_id=e.style_id AND m.code LIKE '4101%')
                  AND NOT EXISTS(SELECT 1 FROM finance_report_line_bindings b WHERE b.style_id=e.style_id AND b.binding_kind='STYLE'
                     AND b.line_key LIKE 'MFG\\_%')
                """).setParameter("from",java.time.LocalDate.of(year,1,1)).setParameter("to",java.time.LocalDate.of(year,12,31)).getResultList())result.add(((Number)month).intValue());
        return Set.copyOf(result);
    }
}
