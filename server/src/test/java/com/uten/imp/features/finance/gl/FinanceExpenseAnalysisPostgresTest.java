package com.uten.imp.features.finance.gl;

import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.anyString;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinanceExpenseAnalysisPostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");static JdbcTemplate db;static NamedParameterJdbcTemplate named;
    @BeforeAll static void start(){PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());db=new JdbcTemplate(source);named=new NamedParameterJdbcTemplate(source);db.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto");
        MigratedProjectionSchema.createCurrentTables(db,"payment_styles","gl_vouchers","gl_entries","finance_report_line_bindings","finance_report_line_confirmations","finance_chart_codes","finance_chart_code_styles","finance_gl_voucher_evidence","finance_sales_expense_groups","finance_sales_expense_assignments","clients","finance_manufacturing_labor_splits","finance_accounting_period_coverage","finance_gl_period_versions","departments","payroll_batches","payroll_slips","payroll_items","finance_payroll_accruals","finance_payroll_accrual_lines","fixed_assets","deferred_expenses","finance_asset_books","finance_asset_categories","finance_deferral_schedule_versions","finance_deferral_schedule_lines","finance_asset_posting_runs","finance_asset_posting_lines","fa_depreciation_log","da_amortization_log","finance_expense_analysis_periods","finance_operating_report_notes","finance_expense_note_imports");
        MigratedProjectionSchema.createCurrentFunctions(db,"fn_financial_book_amount_is_exact","fn_finance_gl_voucher_is_booked","fn_finance_entry_is_pnl_closing","fn_finance_cost_expense_style_allowed","fn_finance_direction_occurrence","fn_finance_debit_occurrence","fn_finance_credit_occurrence","fn_finance_manufacturing_occurrence","fn_finance_expense_entry_fingerprint");
        MigratedProjectionSchema.createCurrentViews(db,"v_finance_sales_expense_pool","v_finance_sales_expense_period_coverage","v_finance_sales_expense_allocation_facts","v_finance_sales_expense_client_facts","v_finance_manufacturing_labor_pool","v_finance_asset_posting_facts","v_finance_payroll_cost_facts");
        MigratedProjectionSchema.createCurrentFunctions(db,"fn_guard_finance_sales_expense_assignment","fn_guard_finance_manufacturing_labor_split");
        db.execute("CREATE TRIGGER assignment_guard BEFORE INSERT OR UPDATE ON finance_sales_expense_assignments FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_sales_expense_assignment()");db.execute("CREATE TRIGGER labor_guard BEFORE INSERT OR UPDATE ON finance_manufacturing_labor_splits FOR EACH ROW EXECUTE FUNCTION fn_guard_finance_manufacturing_labor_split()");
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void reset(){db.execute("TRUNCATE finance_payroll_accrual_lines,finance_payroll_accruals,finance_manufacturing_labor_splits,finance_sales_expense_assignments,finance_sales_expense_groups,finance_gl_voucher_evidence,gl_entries,gl_vouchers,finance_chart_code_styles,finance_chart_codes,finance_report_line_bindings,finance_report_line_confirmations,payment_styles,clients,finance_accounting_period_coverage,finance_gl_period_versions,payroll_items,payroll_slips,payroll_batches,departments,fixed_assets,deferred_expenses,finance_asset_books,finance_asset_posting_runs,finance_asset_posting_lines,fa_depreciation_log,da_amortization_log,finance_expense_analysis_periods,finance_operating_report_notes,finance_expense_note_imports");}
    @Test void allocationGuardPreservesExactSignedAmountAndSourceChangesInvalidateExistingAttribution(){
        UUID fee=style("EXPENSE"),group=group(),entry=entry(fee,1,"123.4567");bind("SALES_FEE",fee);
        assign(entry,group,"123.4567");assertThat(db.queryForObject("SELECT pending FROM v_finance_sales_expense_period_coverage",Boolean.class)).isFalse();
        assertThatThrownBy(()->assign(entry,group,"123.4566")).hasMessageContaining("分配合计");
        db.update("UPDATE gl_entries SET amount=125 WHERE id=?",entry);assertThat(db.queryForObject("SELECT pending FROM v_finance_sales_expense_period_coverage",Boolean.class)).isTrue();
        assertThat(db.queryForObject("SELECT count(*) FROM v_finance_sales_expense_client_facts WHERE fee_key='FREIGHT' AND client_id IS NULL AND pending",Integer.class)).isEqualTo(1);
        db.update("UPDATE gl_entries SET is_deleted=true WHERE id=?",entry);
        assertThat(db.queryForObject("SELECT amount_local FROM v_finance_sales_expense_period_coverage",BigDecimal.class)).isNull();
        assertThat(db.queryForObject("SELECT count(*) FROM finance_sales_expense_assignments",Integer.class)).isEqualTo(1);
    }
    @Test void negativeCreditAndMixedSignsCannotBeOffsetWithinOneSource(){
        UUID fee=style("EXPENSE"),group=group();bind("SALES_FEE",fee);UUID entry=entry(fee,1,"-9.1234");assign(entry,group,"-9.1234");
        assertThat(db.queryForObject("SELECT amount_local FROM v_finance_sales_expense_allocation_facts",BigDecimal.class)).isEqualByComparingTo("-9.1234");
        assertThatThrownBy(()->assign(entry,group,"9.1234")).hasMessageContaining("方向");
    }
    @Test void originalThirtyDecimalBookFactAndGroupBaseSurviveAttributionWithoutRounding(){
        UUID fee=style("EXPENSE"),group=group();bind("SALES_FEE",fee);String exact="12345678901234567890.123456789012345678901234567890";UUID source=entry(fee,1,exact);assign(source,group,exact);
        assertThat(db.queryForObject("SELECT amount_local FROM v_finance_sales_expense_allocation_facts",BigDecimal.class)).isEqualByComparingTo(exact);
        db.update("UPDATE finance_sales_expense_groups SET sales_amount_local=?::numeric,sales_confirmed=true WHERE id=?",exact,group);
        assertThat(db.queryForObject("SELECT sales_amount_local FROM finance_sales_expense_groups",BigDecimal.class)).isEqualByComparingTo(exact);
    }
    @Test void laborDoublePoolsConserveEachDirectionAndExpiredSourceDoesNotSurviveAsZero(){
        UUID wage=style("ACCOUNT");code("410106",wage);bind("MFG_LABOR_CONTROL",wage);UUID positive=entry(wage,1,"100");entry(wage,1,"-100");
        var pool=db.queryForMap("SELECT * FROM v_finance_manufacturing_labor_pool");assertThat((BigDecimal)pool.get("positive_amount")).isEqualByComparingTo("100");assertThat((BigDecimal)pool.get("negative_amount")).isEqualByComparingTo("100");
        assertThatThrownBy(()->split(pool,"110","0","110","0")).hasMessageContaining("分别守恒");split(pool,"60","40","70","30");
        Map<String,BigDecimal[]> data=new HashMap<>();var binding=FinanceManufacturingLabor.apply(em(),2026,data,new GlReportLineSource.Bindings(Map.of()));assertThat(binding.bound("LABOR_DIRECT")).isTrue();assertThat(data.get("LABOR_DIRECT")[9]).isEqualByComparingTo("-10");
        db.update("UPDATE gl_entries SET amount=101 WHERE id=?",positive);FinanceManufacturingLabor.apply(em(),2026,data,binding);assertThat(data.get("LABOR_DIRECT")[9]).isNull();
        db.update("UPDATE gl_entries SET is_deleted=true");FinanceManufacturingLabor.apply(em(),2026,data,binding);assertThat(data.get("LABOR_INDIRECT")[9]).isNull();
    }
    @Test void manufacturingDebitOccurrenceExcludesApprovedClosingAndDoesNotUseZeroEndingBalance(){
        UUID wage=style("ACCOUNT");code("410106",wage);bind("MFG_SUBCONTRACT",wage);entry(wage,1,"100");entry(wage,1,"-10");UUID close=entry(wage,-1,"90");proof(close);
        var monthly=new GlReportLineSource(em()).styleMonthly(List.of("MFG_SUBCONTRACT"),"EXPENSE",java.time.LocalDate.of(2026,1,1),java.time.LocalDate.of(2026,12,31));
        assertThat(monthly.get("MFG_SUBCONTRACT")[9]).isEqualByComparingTo("90");
        bind("SALES_FEE",wage);assertThat(db.queryForObject("SELECT sum(amount_local) FROM v_finance_sales_expense_pool",BigDecimal.class)).isEqualByComparingTo("90");
    }
    @Test void removedCostClassificationCannotTurnPreviouslyBoundRealManufacturingAmountIntoZero(){
        UUID cost=style("ACCOUNT");code("410106",cost);bind("MFG_SUBCONTRACT",cost);entry(cost,1,"99");var reader=new GlReportLineSource(em());
        assertThat(reader.styleMonthly(List.of("MFG_SUBCONTRACT"),"EXPENSE",java.time.LocalDate.of(2026,1,1),java.time.LocalDate.of(2026,12,31)).get("MFG_SUBCONTRACT")[9]).isEqualByComparingTo("99");
        db.update("DELETE FROM finance_chart_code_styles WHERE style_id=?",cost);
        assertThat(reader.styleMonthly(List.of("MFG_SUBCONTRACT"),"EXPENSE",java.time.LocalDate.of(2026,1,1),java.time.LocalDate.of(2026,12,31)).get("MFG_SUBCONTRACT")[9]).isNull();
    }
    @Test void postedOriginalAndRealOppositeReversalRemainTogetherForOrdinaryAndManufacturingFacts(){
        UUID ordinary=style("EXPENSE");bind("ADM_OFFICE",ordinary);UUID original=entry(ordinary,1,"91.1234");reverseOccurrence(original,9);
        assertThat(new GlReportLineSource(em()).styleMonthly(List.of("ADM_OFFICE"),"EXPENSE",java.time.LocalDate.of(2026,1,1),java.time.LocalDate.of(2026,12,31)).get("ADM_OFFICE")[9]).isEqualByComparingTo("0");
        UUID cost=style("ACCOUNT");code("410106",cost);bind("MFG_SUBCONTRACT",cost);UUID debit=entry(cost,1,"100.1234");UUID reversed=reverseOccurrence(debit,10);
        var monthly=new GlReportLineSource(em()).styleMonthly(List.of("MFG_SUBCONTRACT"),"EXPENSE",java.time.LocalDate.of(2026,1,1),java.time.LocalDate.of(2026,12,31)).get("MFG_SUBCONTRACT");
        assertThat(monthly[9]).isEqualByComparingTo("100.1234");assertThat(monthly[10]).isEqualByComparingTo("-100.1234");
        db.update("UPDATE gl_entries SET amount=100 WHERE id=?",reversed);assertThat(new GlReportLineSource(em()).styleMonthly(List.of("MFG_SUBCONTRACT"),"EXPENSE",java.time.LocalDate.of(2026,1,1),java.time.LocalDate.of(2026,12,31)).get("MFG_SUBCONTRACT")[10]).isNull();
    }
    @Test void reversingCostTransferCreditDoesNotInventManufacturingExpenseAndSignedRedDebitsStaySigned(){
        UUID cost=style("ACCOUNT");code("410106",cost);bind("MFG_SUBCONTRACT",cost);UUID transfer=entry(cost,-1,"100");UUID reverse=reverseOccurrence(transfer,10);
        assertThat(db.queryForObject("SELECT fn_finance_manufacturing_occurrence(?)",BigDecimal.class,transfer)).isZero();assertThat(db.queryForObject("SELECT fn_finance_manufacturing_occurrence(?)",BigDecimal.class,reverse)).isZero();
        UUID red=entry(cost,1,"-7.1234");UUID undoRed=reverseOccurrence(red,10);assertThat(db.queryForObject("SELECT fn_finance_manufacturing_occurrence(?)",BigDecimal.class,red)).isEqualByComparingTo("-7.1234");assertThat(db.queryForObject("SELECT fn_finance_manufacturing_occurrence(?)",BigDecimal.class,undoRed)).isEqualByComparingTo("7.1234");
    }
    @Test void creditAndDebitWrappersShareProvedDirectionReversalAndPreserveSignedRedFacts(){
        UUID account=style("ACCOUNT"),credit=entry(account,-1,"123.456789012345678901234567890123"),reversal=reverseOccurrence(credit,10);
        assertThat(db.queryForObject("SELECT fn_finance_credit_occurrence(?)",BigDecimal.class,credit)).isEqualByComparingTo("123.456789012345678901234567890123");
        assertThat(db.queryForObject("SELECT fn_finance_credit_occurrence(?)",BigDecimal.class,reversal)).isEqualByComparingTo("-123.456789012345678901234567890123");
        for(UUID id:List.of(credit,reversal))assertThat(db.queryForObject("SELECT fn_finance_debit_occurrence(?)",BigDecimal.class,id)).isZero();
        UUID red=entry(account,-1,"-0.000000000000000000000000000001"),undo=reverseOccurrence(red,10);
        assertThat(db.queryForObject("SELECT fn_finance_credit_occurrence(?)",BigDecimal.class,red)).isEqualByComparingTo("-0.000000000000000000000000000001");
        assertThat(db.queryForObject("SELECT fn_finance_credit_occurrence(?)",BigDecimal.class,undo)).isEqualByComparingTo("0.000000000000000000000000000001");
        assertThat(db.queryForObject("SELECT fn_finance_direction_occurrence(?,0)",BigDecimal.class,credit)).isNull();
        db.update("UPDATE gl_entries SET amount=124 WHERE id=?",reversal);
        assertThat(db.queryForObject("SELECT fn_finance_credit_occurrence(?)",BigDecimal.class,reversal)).isNull();
        db.update("UPDATE gl_vouchers SET reversed_by_voucher_id=NULL WHERE id=(SELECT voucher_id FROM gl_entries WHERE id=?)",red);
        assertThat(db.queryForObject("SELECT fn_finance_credit_occurrence(?)",BigDecimal.class,undo)).isNull();
    }
    @Test void noPayrollFactIsUnknownAndUnverifiedOrChangedPeriodIsNotZero(){
        UUID department=UUID.randomUUID();db.update("INSERT INTO departments(id,code,name,path,level) VALUES(?,?,'原部门','/dept/',0)",department,"D"+department);db.update("INSERT INTO finance_report_line_bindings(line_key,binding_kind,department_id,created_by) VALUES('LABOR_DIRECT','DEPARTMENT',?,gen_random_uuid())",department);
        var values=new GlReportLineSource(em()).payrollMonthly(List.of("LABOR_DIRECT"),2026,null);assertThat(values.get("LABOR_DIRECT")[9]).isNull();
        assertThat(FinancialPeriodCoverage.months(em(),2026,9).get(9).complete()).isFalse();
        db.update("INSERT INTO finance_gl_period_versions(period,revision) VALUES('2026-09',3)");db.update("INSERT INTO finance_accounting_period_coverage(period,entries_revision,source_kind,source_sha256,verified_by) VALUES('2026-09',3,'REVIEWED',repeat('a',64),gen_random_uuid())");
        assertThat(FinancialPeriodCoverage.months(em(),2026,9).get(9).complete()).isTrue();db.update("UPDATE finance_gl_period_versions SET revision=4");assertThat(FinancialPeriodCoverage.months(em(),2026,9).get(9).complete()).isFalse();
    }
    @Test void fiftyThousandSourceFactsAggregateWithoutDuplicateAmplification(){
        UUID fee=style("EXPENSE");bind("SALES_FEE",fee);UUID voucher=UUID.randomUUID();db.update("INSERT INTO gl_vouchers(id,voucher_no,source,voucher_date,period,status,created_by,updated_by) VALUES(?,?,'AUTO','2026-09-30','2026-09',1,gen_random_uuid(),gen_random_uuid())",voucher,"V"+voucher);
        db.update("INSERT INTO gl_entries(voucher_id,style_id,direction,amount,entry_date,period) SELECT ?,?,1,0.0001,'2026-09-30','2026-09' FROM generate_series(1,50000)",voucher,fee);
        var row=db.queryForMap("SELECT * FROM v_finance_sales_expense_period_coverage");assertThat(row.get("source_count")).isEqualTo(50000L);assertThat((BigDecimal)row.get("amount_local")).isEqualByComparingTo("5");assertThat(row.get("pending")).isEqualTo(true);
    }
    @Test void approvedHistoricalDepreciationCanSupplyExpenseButPartialAssetProofCannotHideLedgerDifference(){
        UUID expense=style("EXPENSE");bind("ADM_DEPRECIATION",expense);UUID original=entry(expense,1,"10");proof(original,"OPERATING");
        var reader=new GlReportLineSource(em());assertThat(reader.depreciationMonthly(List.of("ADM_DEPRECIATION"),"2026-01","2026-12","FA").get("ADM_DEPRECIATION")[9]).isEqualByComparingTo("10");
        assetFact(original,expense,"5","NORMAL","ACTIVE");assertThat(reader.depreciationMonthly(List.of("ADM_DEPRECIATION"),"2026-01","2026-12","FA").get("ADM_DEPRECIATION")[9]).isNull();
        db.update("UPDATE fa_depreciation_log SET amount=10");db.update("UPDATE finance_asset_posting_lines SET amount=10");assertThat(reader.depreciationMonthly(List.of("ADM_DEPRECIATION"),"2026-01","2026-12","FA").get("ADM_DEPRECIATION")[9]).isEqualByComparingTo("10");
    }
    @Test void depreciationReversalRetainsOriginalPlusSignedReversalAndUnprovenLedgerIsUnknown(){
        UUID expense=style("EXPENSE");bind("ADM_DEPRECIATION",expense);UUID original=entry(expense,1,"10");var reader=new GlReportLineSource(em());
        assertThat(reader.depreciationMonthly(List.of("ADM_DEPRECIATION"),"2026-01","2026-12","FA").get("ADM_DEPRECIATION")[9]).isNull();
        assetFact(original,expense,"10","NORMAL","REVERSED");db.update("UPDATE gl_vouchers SET status=-1 WHERE id=(SELECT voucher_id FROM gl_entries WHERE id=?)",original);
        UUID reverse=entry(expense,1,"-10");assetFact(reverse,expense,"10","REVERSAL","ACTIVE");assertThat(reader.depreciationMonthly(List.of("ADM_DEPRECIATION"),"2026-01","2026-12","FA").get("ADM_DEPRECIATION")[9]).isEqualByComparingTo("0");
    }
    @Test void versionedServiceCommandsReplayOnceAndPreserveNotesAcrossConflictsAndPeriodLocks(){
        var user=mock(com.uten.imp.security.SecurityContextCurrentUser.class);when(user.requireId()).thenReturn(UUID.randomUUID());
        var access=mock(com.uten.imp.features.finance.FinanceDocumentAccessPolicy.class);when(access.scope()).thenReturn(new com.uten.imp.security.OwnerVisibility.OwnerScope(true,Set.of()));
        var service=new FinanceExpenseAnalysisService(db,em(),new com.fasterxml.jackson.databind.ObjectMapper(),mock(com.uten.imp.common.storage.ImmutableDocumentStore.class),user,access,mock(com.uten.imp.security.TxSessionVars.class));
        var auth=new org.springframework.security.authentication.UsernamePasswordAuthenticationToken("operator","",List.of(new org.springframework.security.core.authority.SimpleGrantedAuthority("finance_report:view"),new org.springframework.security.core.authority.SimpleGrantedAuthority("payment_style:edit")));
        org.springframework.security.core.context.SecurityContextHolder.getContext().setAuthentication(auth);
        var transaction=new org.springframework.transaction.support.TransactionTemplate(new org.springframework.jdbc.datasource.DataSourceTransactionManager(db.getDataSource()));
        try {
            UUID id=UUID.randomUUID(),expense=style("EXPENSE");bind("SALES_FEE",expense);UUID source=entry(expense,1,"12.3456");
            var group=new FinanceExpenseAnalysisContracts.GroupInput(id,"2026-09",-1,"原表本期分组",null,"DOMESTIC","0",true,true,"原文件/工作表/第3行",3);
            transaction.executeWithoutResult(status->{service.saveGroup(group);service.saveGroup(group);});assertThat(db.queryForObject("SELECT count(*) FROM finance_sales_expense_groups",Integer.class)).isEqualTo(1);
            String fingerprint=db.queryForObject("SELECT fn_finance_expense_entry_fingerprint(?)",String.class,source);
            var command=new FinanceExpenseAnalysisContracts.AssignmentInput(source,fingerprint,-1,List.of(new FinanceExpenseAnalysisContracts.Allocation(id,"FREIGHT",null,"12.3456")),"原凭证/逐笔核对");
            transaction.executeWithoutResult(status->{service.assign(command);service.assign(command);});assertThat(db.queryForObject("SELECT row_version FROM finance_sales_expense_assignments",Long.class)).isZero();assertThat(db.queryForObject("SELECT amount FROM gl_entries WHERE id=?",BigDecimal.class,source)).isEqualByComparingTo("12.3456");
            var note=new FinanceExpenseAnalysisContracts.NoteInput("2026-09","OP_RENT",-1,"原备注\n保留换行","差异原因");transaction.executeWithoutResult(status->{service.saveNote(note);service.saveNote(note);});
            assertThat(db.queryForObject("SELECT row_version FROM finance_operating_report_notes",Long.class)).isZero();
            assertThatThrownBy(()->transaction.executeWithoutResult(status->service.saveNote(new FinanceExpenseAnalysisContracts.NoteInput("2026-09","OP_RENT",-1,"旧版本不能覆盖","")))).hasMessageContaining("已变化");
            transaction.executeWithoutResult(status->service.savePolicy(new FinanceExpenseAnalysisContracts.PolicyInput("2026-09",-1,true,"已核对部门性质并排除资本化重复",true,"")));
            assertThatThrownBy(()->transaction.executeWithoutResult(status->service.saveNote(new FinanceExpenseAnalysisContracts.NoteInput("2026-09","OP_RENT",0,"锁定后不能写","")))).hasMessageContaining("锁定");
            assertThat(db.queryForObject("SELECT remark FROM finance_operating_report_notes",String.class)).isEqualTo("原备注\n保留换行");
        } finally {org.springframework.security.core.context.SecurityContextHolder.clearContext();}
    }
    static void assetFact(UUID entry,UUID expense,String amount,String kind,String status){
        UUID asset=UUID.randomUUID(),book=UUID.randomUUID(),run=UUID.randomUUID(),line=UUID.randomUUID();UUID voucher=db.queryForObject("SELECT voucher_id FROM gl_entries WHERE id=?",UUID.class,entry);
        db.update("INSERT INTO fixed_assets(id,code,name,original_value,capitalized_on,start_period,useful_months,lifecycle_status,expense_style_id,is_deleted) VALUES(?,?,'匿名资产',1000,'2026-01-01','2026-09',12,'ACTIVE',?,false)",asset,asset.toString(),expense);
        db.update("INSERT INTO finance_asset_books(id,asset_id,book_type,original_value,depreciable_amount,opening_accumulated_amount,useful_months,start_period,method,is_deleted) VALUES(?,?,'CORPORATE',1000,1000,0,12,'2026-09','STRAIGHT_LINE',false)",book,asset);
        db.update("INSERT INTO finance_asset_posting_runs(id,book_type,status,voucher_id,is_deleted) VALUES(?,'CORPORATE',?,?,false)",run,status.equals("REVERSED")?"REVERSED":"POSTED",voucher);
        db.update("INSERT INTO finance_asset_posting_lines(id,run_id,fixed_asset_id,asset_book_id,expense_style_id,line_kind,amount,voucher_id,is_deleted) VALUES(?,?,?,?,?,?,?::numeric,?,false)",line,run,asset,book,expense,kind,amount,voucher);
        db.update("INSERT INTO fa_depreciation_log(id,asset_id,period,amount,entry_kind,status,voucher_id,posting_run_id,posting_line_id,asset_book_id,is_deleted) VALUES(gen_random_uuid(),?,'2026-09',?::numeric,?,?,?,?,?,?,false)",asset,amount,kind,status,voucher,run,line,book);
    }
    static UUID style(String category){UUID id=UUID.randomUUID();db.update("INSERT INTO payment_styles(id,code,name,category,level) VALUES(?,?,'明确来源',?,0)",id,"S"+id,category);return id;}
    static void bind(String key,UUID style){db.update("INSERT INTO finance_report_line_bindings(line_key,binding_kind,style_id,created_by) VALUES(?,'STYLE',?,gen_random_uuid())",key,style);}
    static void code(String code,UUID style){db.update("INSERT INTO finance_chart_codes(code,name,currency_name,sort_order,source_row,source_import_id,updated_by) VALUES(?,'原财务科目','',1,1,gen_random_uuid(),gen_random_uuid())",code);db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by) VALUES(?,?,gen_random_uuid())",code,style);}
    static UUID group(){UUID id=UUID.randomUUID();db.update("INSERT INTO finance_sales_expense_groups(id,period,label_snapshot,reviewed,source_reference,request_fingerprint,updated_by) VALUES(?,'2026-09','原组',true,'原表核对','fp',gen_random_uuid())",id);return id;}
    static UUID entry(UUID style,int direction,String amount){UUID voucher=UUID.randomUUID();db.update("INSERT INTO gl_vouchers(id,voucher_no,source,voucher_date,period,status,created_by,updated_by) VALUES(?,?,'AUTO','2026-09-30','2026-09',1,gen_random_uuid(),gen_random_uuid())",voucher,"V"+voucher);UUID id=UUID.randomUUID();db.update("INSERT INTO gl_entries(id,voucher_id,style_id,direction,amount,entry_date,period) VALUES(?,?,?,?,?::numeric,'2026-09-30','2026-09')",id,voucher,style,direction,amount);return id;}
    static UUID reverseOccurrence(UUID original,int month){UUID voucher=UUID.randomUUID(),entry=UUID.randomUUID();String period="2026-%02d".formatted(month);db.update("UPDATE gl_entries SET line_no=1 WHERE id=?",original);UUID source=db.queryForObject("SELECT voucher_id FROM gl_entries WHERE id=?",UUID.class,original);
        db.update("INSERT INTO gl_vouchers(id,voucher_no,source,voucher_date,period,status,reversal_of_voucher_id,created_by,updated_by) VALUES(?,?,'AUTO',?::date,?,1,?,gen_random_uuid(),gen_random_uuid())",voucher,"R"+voucher,period+"-30",period,source);db.update("UPDATE gl_vouchers SET status=-1,reversed_by_voucher_id=? WHERE id=?",voucher,source);db.update("INSERT INTO gl_entries(id,voucher_id,line_no,style_id,direction,amount,entry_date,period) SELECT ?,?,1,style_id,-direction,amount,?::date,? FROM gl_entries WHERE id=?",entry,voucher,period+"-30",period,original);return entry;}
    static void assign(UUID entry,UUID group,String amount){String hash=db.queryForObject("SELECT fn_finance_expense_entry_fingerprint(?)",String.class,entry);String allocations="[{\"groupId\":\""+group+"\",\"feeKey\":\"FREIGHT\",\"clientId\":null,\"amountLocal\":\""+amount+"\"}]";db.update("INSERT INTO finance_sales_expense_assignments(entry_id,period,source_fingerprint,source_snapshot,allocations,source_reference,request_fingerprint,updated_by) VALUES(?,'2026-09',?,'{\"date\":\"2026-09-30\"}',?::jsonb,'原凭证核对','fp',gen_random_uuid()) ON CONFLICT(entry_id) DO UPDATE SET allocations=excluded.allocations,source_fingerprint=excluded.source_fingerprint",entry,hash,allocations);}
    static void split(Map<String,Object> pool,String dp,String ip,String dn,String in){db.update("INSERT INTO finance_manufacturing_labor_splits(period,source_fingerprint,source_snapshot,direct_positive,indirect_positive,direct_negative,indirect_negative,reviewed,source_reference,request_fingerprint,updated_by) VALUES('2026-09',?,'[]',?::numeric,?::numeric,?::numeric,?::numeric,true,'原工资分配核对','fp',gen_random_uuid())",pool.get("source_fingerprint"),dp,ip,dn,in);}
    static void proof(UUID entry){proof(entry,"PNL_CLOSE");}
    static void proof(UUID entry,String purpose){db.update("INSERT INTO finance_gl_voucher_evidence(voucher_id,purpose,source_system,source_ledger,source_year,source_period,source_voucher_type,source_voucher_no,source_sha256,source_snapshot,submitted_by,approved_by) SELECT voucher_id,?,'TEST','TEST',2026,9,'TEST',id::text,repeat('a',64),'{}',gen_random_uuid(),gen_random_uuid() FROM gl_entries WHERE id=?",purpose,entry);}
    static EntityManager em(){var em=mock(EntityManager.class);when(em.createNativeQuery(anyString())).thenAnswer(call->{String sql=call.getArgument(0);Map<String,Object> args=new HashMap<>();return mock(Query.class,q->{if(q.getMethod().getName().equals("setParameter")){args.put(q.getArgument(0),q.getArgument(1));return q.getMock();}if(q.getMethod().getName().equals("getResultList"))return named.query(sql,args,(rs,n)->{if(rs.getMetaData().getColumnCount()==1)return rs.getObject(1);Object[] row=new Object[rs.getMetaData().getColumnCount()];for(int i=0;i<row.length;i++)row[i]=rs.getObject(i+1);return row;});return org.mockito.Answers.RETURNS_DEFAULTS.answer(q);});});return em;}
}
