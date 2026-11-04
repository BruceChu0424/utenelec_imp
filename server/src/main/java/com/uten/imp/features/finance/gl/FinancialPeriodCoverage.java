package com.uten.imp.features.finance.gl;

import jakarta.persistence.EntityManager;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.*;
import java.util.*;

/** An empty month is not a verified zero. One bounded query reads the selected year's source coverage. */
public final class FinancialPeriodCoverage {
    private FinancialPeriodCoverage() { }
    public record Value(boolean complete,String basis) { }
    public static Value asOf(EntityManager em,java.time.LocalDate date) {
        boolean complete=Boolean.TRUE.equals(em.createNativeQuery("SELECT fn_finance_balance_asof_complete(:date)").setParameter("date",date).getSingleResult());
        return new Value(complete,complete?"已核对期初及截至报表日的完整发生额":"缺少已核对期初或其后完整发生额，余额待核对");
    }
    public static Value range(EntityManager em,java.time.LocalDate from,java.time.LocalDate to) {
        boolean complete=Boolean.TRUE.equals(em.createNativeQuery("""
                SELECT NOT EXISTS(SELECT 1 FROM generate_series(CAST(:first AS date),CAST(:last AS date),interval '1 month') month
                    LEFT JOIN finance_gl_period_versions v ON v.period=to_char(month,'YYYY-MM')
                    LEFT JOIN finance_accounting_period_coverage c ON c.period=v.period
                    WHERE c.period IS NULL OR c.entries_revision<>v.revision)
                """).setParameter("first",from.withDayOfMonth(1)).setParameter("last",to.withDayOfMonth(1)).getSingleResult());
        return new Value(complete,complete?"所选期间完整发生额已核对":"所选期间发生额尚未完整核对");
    }
    public static Map<Integer,Value> months(EntityManager em,int year,int throughMonth) {
        if(year<1||year>9999||throughMonth<1||throughMonth>12)throw new ApiException(ErrorCode.VALIDATION_FAILED,"会计年/月不正确");
        Map<Integer,Value> result=new LinkedHashMap<>();
        for(int month=1;month<=throughMonth;month++)result.put(month,new Value(false,"该月来源尚未完整核对，未发生不能直接认作零"));
        for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT substring(c.period,6,2)::int,c.entries_revision=v.revision,c.source_kind
                FROM finance_accounting_period_coverage c JOIN finance_gl_period_versions v ON v.period=c.period
                WHERE c.period>=:first AND c.period<=:last ORDER BY c.period
                """).setParameter("first","%04d-01".formatted(year)).setParameter("last","%04d-%02d".formatted(year,throughMonth)))) {
            boolean complete=Boolean.TRUE.equals(row[1]);result.put(((Number)row[0]).intValue(),new Value(complete,
                    complete?"该月来源已核对："+row[2]:"该月来源在核对后已变化，请重新核对"));
        }
        return Collections.unmodifiableMap(result);
    }
}
