package com.uten.imp.features.finance.statement;

import org.springframework.jdbc.core.JdbcTemplate;
import java.time.LocalDate;
import java.util.UUID;

/** A partial set of auxiliary allocations never proves a whole party balance. */
final class FinanceAuxiliaryCompleteness {
    private FinanceAuxiliaryCompleteness() { }
    record Missing(long opening,long movement) {
        boolean openingComplete(){return opening==0;}
        boolean movementComplete(){return movement==0;}
        boolean closingComplete(){return openingComplete()&&movementComplete();}
    }
    /** Expressions are owning-query aliases, never HTTP values. */
    static String coveredAmountSql(String entry,String code,String currency){
        return "(SELECT sum(covered.amount_local) FROM finance_gl_entry_allocations covered WHERE covered.entry_id="+entry+".id AND covered.account_code="+code+" AND covered.currency_id="+currency
                +" AND covered.auxiliary_id IS NOT NULL AND covered.party_id_snapshot IS NOT NULL AND covered.auxiliary_role IS NOT NULL)";
    }
    static Missing read(JdbcTemplate db,String code,UUID accountingCurrency,LocalDate from,LocalDate to){
        return db.queryForObject("""
                SELECT count(*) FILTER(WHERE entry.entry_date<?),count(*) FILTER(WHERE entry.entry_date>=?)
                FROM finance_chart_code_styles mapping JOIN gl_entries entry ON entry.style_id=mapping.style_id
                JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id
                LEFT JOIN LATERAL(SELECT %s AS covered) allocation ON true
                WHERE mapping.code=? AND entry.entry_date<=? AND NOT entry.is_deleted
                  AND fn_finance_gl_voucher_is_booked(voucher.id) AND COALESCE(allocation.covered,0)<>entry.amount
                """.formatted(coveredAmountSql("entry","mapping.code","?")),(row,index)->new Missing(row.getLong(1),row.getLong(2)),from,from,accountingCurrency,code,to);
    }
}
