package com.uten.imp.features.finance.gl;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;
import java.util.*;

/** Reads the caller's same repeatable-read snapshot; annotation/configuration never posts a ledger. */
final class FinanceExpenseAnalysisReader {
    private FinanceExpenseAnalysisReader() { }
    static Set<Integer> confirmedPolicies(EntityManager em,int year) {
        Set<Integer> months=new HashSet<>();
        for(Object value:em.createNativeQuery("SELECT substring(period FROM 6 FOR 2)::int FROM finance_expense_analysis_periods WHERE period BETWEEN :from AND :to AND policy_confirmed")
                .setParameter("from","%04d-01".formatted(year)).setParameter("to","%04d-12".formatted(year)).getResultList())months.add(((Number)value).intValue());
        return Set.copyOf(months);
    }
    static Map<String,Map<String,Object>> notes(EntityManager em,String period) {
        Map<String,Map<String,Object>> result=new LinkedHashMap<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("SELECT line_key,remark,variance_reason,row_version FROM finance_operating_report_notes WHERE period=:period")
                .setParameter("period",period)))result.put(row[0].toString(),Map.of("remark",row[1],"varianceReason",row[2],"version",row[3]));
        return result;
    }
}
