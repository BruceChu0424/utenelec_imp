package com.uten.imp.features.finance.statement;

import com.uten.imp.support.MigratedProjectionSchema;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.time.LocalDate;
import java.util.UUID;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinanceAuxiliaryCompletenessPostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    static JdbcTemplate db;
    static final LocalDate FROM=LocalDate.of(2026,9,1),TO=LocalDate.of(2026,9,30);
    UUID style,currency;
    @BeforeAll static void start(){
        PG.start();db=new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()));
        MigratedProjectionSchema.createCurrentTables(db,"gl_entries","gl_vouchers","finance_chart_code_styles","finance_gl_entry_allocations","finance_chart_codes","finance_gl_auxiliary_opening_evidence");
        MigratedProjectionSchema.createCurrentFunctions(db,"fn_finance_gl_voucher_is_booked");
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void reset(){
        db.execute("TRUNCATE gl_entries,gl_vouchers,finance_chart_code_styles,finance_gl_entry_allocations,finance_chart_codes,finance_gl_auxiliary_opening_evidence");
        style=UUID.randomUUID();currency=UUID.randomUUID();
        db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by) VALUES('2202',?,gen_random_uuid())",style);
        db.update("INSERT INTO finance_chart_codes(code,name,currency_name,sort_order,source_row,source_import_id,updated_by) VALUES('2202','匿名应付科目','',1,1,gen_random_uuid(),gen_random_uuid())");
    }
    @Test void unallocatedNativePaymentCannotTurnOnePartyPartialLedgerIntoACompleteBalance(){
        UUID opening=entry("2026-08-31","100.0000001",1);allocate(opening,1,"100.0000001",currency);
        UUID payment=entry("2026-09-08","20.0000001",1);
        var missing=FinanceAuxiliaryCompleteness.read(db,"2202",currency,FROM,TO);
        assertThat(missing.openingComplete()).isTrue();assertThat(missing.movement()).isEqualTo(1);assertThat(missing.closingComplete()).isFalse();
        assertThat(reportRows()).allSatisfy(row->{assertThat(row.get("debit")).isNull();assertThat(row.get("closingBalance")).isNull();assertThat(row.get("__basis").toString()).contains("未完整分配");});
        allocate(payment,1,"10",currency);
        assertThat(FinanceAuxiliaryCompleteness.read(db,"2202",currency,FROM,TO).movement()).isEqualTo(1);
        allocate(payment,2,"10.0000001",currency);
        assertThat(FinanceAuxiliaryCompleteness.read(db,"2202",currency,FROM,TO).closingComplete()).isTrue();
        assertThat(reportRows()).allSatisfy(row->{assertThat(row.get("debit")).isNotNull();assertThat(row.get("closingBalance")).isNotNull();});
        assertThat(FinanceAuxiliaryCompleteness.read(db,"2202",UUID.randomUUID(),FROM,TO).closingComplete()).isFalse();
    }
    @Test void realNegativeReversalIsRequiredWhileDraftDeletedAndFutureSourcesDoNotCreateFalseGaps(){
        UUID original=entry("2026-08-31","7",-1);allocate(original,1,"7",currency);
        UUID reversal=entry("2026-09-06","-7",1);
        entry("2026-09-07","500",0);entry("2026-10-01","600",1);
        UUID deleted=entry("2026-09-09","700",1);db.update("UPDATE gl_entries SET is_deleted=true WHERE id=?",deleted);
        assertThat(FinanceAuxiliaryCompleteness.read(db,"2202",currency,FROM,TO).movement()).isEqualTo(1);
        allocate(reversal,1,"-7",currency);
        assertThat(FinanceAuxiliaryCompleteness.read(db,"2202",currency,FROM,TO).closingComplete()).isTrue();
    }
    UUID entry(String date,String amount,int status){
        UUID voucher=UUID.randomUUID();db.update("INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type,status) VALUES(?,?,?,?::date,'MANUAL','ANONYMOUS',?)",voucher,voucher.toString(),date.substring(0,7),date,status);
        return db.queryForObject("INSERT INTO gl_entries(voucher_id,style_id,direction,amount,entry_date,period) VALUES(?,?,1,?::numeric,?::date,?) RETURNING id",UUID.class,voucher,style,amount,date,date.substring(0,7));
    }
    void allocate(UUID entry,int number,String amount,UUID book){
        db.update("INSERT INTO finance_gl_entry_allocations(entry_id,allocation_no,account_code,source_account_code,auxiliary_id,currency_id,amount_local,auxiliary_role,party_id_snapshot,source_entry_id,source_row,source_snapshot,created_by,source_system,source_code,source_name,source_account_path_name) VALUES(?,?,'2202','2202',gen_random_uuid(),?,?::numeric,'SUPPLIER',gen_random_uuid(),?,1,'{}',gen_random_uuid(),'ANON','ANON','匿名往来','匿名科目路径')",entry,number,book,amount,entry.toString());
    }
    List<Map<String,Object>> reportRows(){
        var args=new HashMap<String,Object>();args.put("from",FROM);args.put("to",TO);args.put("prefix","2202");args.put("role","SUPPLIER");
        args.put("accountCode",null);args.put("auxiliaryId",null);args.put("auxiliaryIds",null);args.put("currencyId",currency);args.put("sourceSystem",null);
        args.put("scopeOpening",true);args.put("scopePeriod",true);args.put("scopeClosing",true);
        return new NamedParameterJdbcTemplate(db).queryForList(FinanceAuxiliaryReports.sql(false),args);
    }
}
