package com.uten.imp.support;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;
import org.springframework.jdbc.core.JdbcTemplate;

/** Frozen corporate facts for read SQL oracles; no service, approval or ledger is mocked. */
public final class FinanceAssetProjectionFacts {
    private FinanceAssetProjectionFacts() { }
    public static final UUID EXPENSE=UUID.fromString("ce7d2f54-5539-43ed-859c-c8d75b4b7001");

    public static void freeze(JdbcTemplate db,boolean deferred,UUID id,String nominal,LocalDate approvedOn) {
        String table=deferred?"deferred_expenses":"fixed_assets";
        db.update("UPDATE "+table+" SET expense_style_id=?,"+(deferred?"service_start_on=recognized_on":"acquired_on=capitalized_on")+" WHERE id=?",EXPENSE,id);
        db.update("INSERT INTO finance_asset_template_metadata(object_type,object_id,valid_from,confirmed,source_reference) VALUES(?,?,DATE '1900-01-01',true,'anonymous projection source')",deferred?"DEFERRED_EXPENSE":"FIXED_ASSET",id);
        if(deferred) db.update("""
                INSERT INTO finance_deferral_schedule_versions(id,deferred_id,version,total_amount,useful_months,
                    start_period,status,approved_at,method,nominal_monthly_amount,is_deleted)
                SELECT gen_random_uuid(),id,1,total_amount,useful_months,start_period,'APPROVED',?,'STRAIGHT_LINE',?,false
                FROM deferred_expenses WHERE id=?
                """,approvedOn,new BigDecimal(nominal),id);
        else db.update("""
                INSERT INTO finance_asset_books(id,asset_id,book_type,original_value,depreciable_amount,
                    opening_accumulated_amount,useful_months,start_period,method,regular_monthly_amount,is_deleted)
                SELECT gen_random_uuid(),id,'CORPORATE',original_value,original_value,
                    opening_accumulated_amount,useful_months,start_period,'STRAIGHT_LINE',?,false
                FROM fixed_assets WHERE id=?
                """,new BigDecimal(nominal),id);
    }

    public static void post(JdbcTemplate db,boolean deferred,UUID id,String period,String amount,
            String kind,String status,LocalDate voucherDate,boolean deleted) {
        UUID voucher=voucherDate==null?null:UUID.randomUUID(),run=UUID.randomUUID(),line=UUID.randomUUID();
        UUID book=deferred?null:db.queryForObject("SELECT id FROM finance_asset_books WHERE asset_id=? AND book_type='CORPORATE'",UUID.class,id);
        if(voucher!=null) db.update("""
                INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type,status,is_deleted)
                VALUES(?,?,?,?,'AUTO',?,?,?)
                """,voucher,"PROJECTION-"+voucher,period,voucherDate,deferred?"DA_AMT":"FA_DEP",status.equals("REVERSED")?-1:1,deleted);
        db.update("INSERT INTO finance_asset_posting_runs(id,book_type,status,voucher_id,is_deleted) VALUES(?,'CORPORATE',?,?,false)",run,status.equals("REVERSED")?"REVERSED":"POSTED",voucher);
        db.update("""
                INSERT INTO finance_asset_posting_lines(id,run_id,fixed_asset_id,deferred_expense_id,asset_book_id,
                    expense_style_id,line_kind,amount,voucher_id,is_deleted) VALUES(?,?,?,?,?,?,?,?,?,?)
                """,line,run,deferred?null:id,deferred?id:null,book,EXPENSE,kind,new BigDecimal(amount),voucher,deleted);
        String query="INSERT INTO "+(deferred?"da_amortization_log":"fa_depreciation_log")
                +"(id,"+(deferred?"deferred_id":"asset_id")+",period,amount,entry_kind,status,voucher_id,posting_run_id,posting_line_id"
                +(deferred?"":",asset_book_id")+",is_deleted) VALUES(?,?,?,?,?,?,?,?,?"+(deferred?"":",?")+",?)";
        if(deferred) db.update(query,UUID.randomUUID(),id,period,new BigDecimal(amount),kind,status,voucher,run,line,deleted);
        else db.update(query,UUID.randomUUID(),id,period,new BigDecimal(amount),kind,status,voucher,run,line,book,deleted);
    }
}
