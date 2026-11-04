package com.uten.imp.features.finance.gl;

import jakarta.persistence.EntityManager;
import com.uten.imp.common.util.NativeValueConverters;
import java.time.*;
import java.util.*;

/** Report amounts describe posted ledger facts. Source certification is a separate, stricter write/evidence policy. */
public final class FinancialLedgerReadScope {
    private FinancialLedgerReadScope() { }
    public record Value(boolean complete,String basis) { }
    private static LocalDate start(EntityManager em) {
        Object date=em.createNativeQuery("""
                SELECT min(b.effective_from) FROM finance_gl_opening_baselines b
                JOIN finance_accounting_import_batches batch ON batch.id=b.import_batch_id
                WHERE batch.status='POSTED' AND batch.reversed_at IS NULL
                """).getSingleResult();
        return date==null?null:NativeValueConverters.toLocalDate(date);
    }
    public static Value asOf(EntityManager em,LocalDate date) {
        LocalDate start=start(em);boolean known=start==null||!date.isBefore(start.minusDays(1));
        return new Value(known,known?"本系统已记账总账余额，不含未记账单据":"该日期早于原账套接续起点，历史余额尚未提供");
    }
    public static Value range(EntityManager em,LocalDate from,LocalDate to) {
        LocalDate start=start(em);boolean known=start==null||!from.isBefore(start);
        return new Value(known,known?"所选期间本系统已记账发生额，不含未记账单据":"所选期间包含接续起点前未提供的历史发生额");
    }
    public static Map<Integer,Value> months(EntityManager em,int year,int throughMonth) {
        if(throughMonth<1||throughMonth>12)throw new IllegalArgumentException("throughMonth");
        LocalDate start=start(em);Map<Integer,Value> values=new LinkedHashMap<>();
        for(int month=1;month<=throughMonth;month++) {
            boolean known=start==null||!LocalDate.of(year,month,1).isBefore(start);
            values.put(month,new Value(known,known?"本系统已记账发生额，不含未记账单据":"接续起点前的历史发生额尚未提供"));
        }
        return Collections.unmodifiableMap(values);
    }
}
