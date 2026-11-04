package com.uten.imp.features.finance.gl;

import com.uten.imp.application.port.FinanceGlSettlementCapacityPort.*;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.*;
import com.uten.imp.testsupport.FixtureDatabaseProperties;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.*;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicReference;
import static org.assertj.core.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.jwt.secret=pool-regression-jwt-0123456789-0123456789","uten.crypto.pgp-master-key=pool-regression-pgp-0123456789-0123456789",
        "uten.crypto.hmac-key=pool-regression-hmac-0123456789","uten.bootstrap.admin-login=pool-regression-admin","uten.bootstrap.admin-password=PoolFixtureAdmin-1!"})
class FinanceGlSettlementCapacityPostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("settlement_capacity");
    @DynamicPropertySource static void database(DynamicPropertyRegistry r){PG.start();FixtureDatabaseProperties.bindSameRole(r,PG::getJdbcUrl,PG::getUsername,PG::getPassword);}
    @Autowired JdbcTemplate db;
    @Autowired FinanceGlSettlementCapacityService pool;
    @Autowired FinanceControlledJournalService journals;
    @Autowired PlatformTransactionManager transactions;
    @Autowired TxSessionVars tx;
    Actor actor;UUID base,cash;
    @BeforeEach void setup(){actor=actor();login();base=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND status='使用' AND NOT is_deleted",UUID.class);cash=style("ACCOUNT");}
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void actualClearingIsNotDeductedTwiceAndOnlySymmetricReversalRestoresCapacity(){
        var f=fixture(base);var old=BusinessTime.today().minusDays(5);var source=journal(f,1,"1000.123456789012345678901234","1000.123456789012345678901234",old);
        var scope=scope(f,base,old);var ref=new SourceRef(source.entry(),1);
        var preview=pool.preview(scope,Mode.EXPLICIT_GL_SOURCE,List.of(ref));assertThat(preview.ready()).isTrue();
        BigDecimal amount=new BigDecimal("125.000000000000000001");Owner owner=owner(UUID.randomUUID());
        var request=new Reservation(UUID.randomUUID(),owner,scope,Mode.EXPLICIT_GL_SOURCE,preview.fingerprint(),amount,amount,List.of(new SourceAmount(ref,amount,amount)),"匿名已审核原借款份额");
        var reserved=pool.reserve(request);assertThat(pool.reserve(request)).isEqualTo(reserved);
        AtomicReference<Journal> paid=new AtomicReference<>();
        var committed=new TransactionTemplate(transactions).execute(status->{var actual=journalInside(f,-1,amount.toPlainString(),amount.toPlainString(),old);paid.set(actual);
            return pool.commit(new Commit(UUID.randomUUID(),owner,reserved.reservationId(),List.of(new Clearing(actual.entry(),1,ref))));});
        assertThat(committed.status()).isEqualTo("COMMITTED");
        var after=pool.preview(scope,Mode.EXPLICIT_GL_SOURCE,List.of(ref));
        assertThat(after.availableLocal()).isEqualByComparingTo(new BigDecimal("1000.123456789012345678901234").subtract(amount));
        assertThat(after.sources().getFirst().amountLocal()).isEqualByComparingTo(after.availableLocal());
        assertThatThrownBy(()->pool.cancel(new Cancel(UUID.randomUUID(),owner,reserved.reservationId(),"已有真实清偿不能直接取消"))).isInstanceOf(ApiException.class);
        var released=new TransactionTemplate(transactions).execute(status->{
            var reversed=journals.reverse(paid.get().voucher(),"POOL-REV-"+UUID.randomUUID(),BusinessTime.today(),"POOL_TEST_REV",UUID.randomUUID(),"POOL_TEST","匿名原事实对称红冲",actor.user());
            UUID reverseEntry=reversed.entryIds().stream().filter(id->f.style().equals(db.queryForObject("SELECT style_id FROM gl_entries WHERE id=?",UUID.class,id))).findFirst().orElseThrow();
            return pool.release(new Release(UUID.randomUUID(),owner,reserved.reservationId(),List.of(new Reversal(reverseEntry,1,paid.get().entry(),1)),"核对真实反向凭证"));});
        assertThat(released.status()).isEqualTo("RELEASED");
        // A reversal today restores today's capacity, not a historical date before that reversal.
        assertThat(pool.preview(scope,Mode.EXPLICIT_GL_SOURCE,List.of(ref)).availableLocal()).isEqualByComparingTo(after.availableLocal());
        var current=pool.preview(scope(f,base,BusinessTime.today()),Mode.EXPLICIT_GL_SOURCE,List.of(ref));
        assertThat(current.availableLocal()).isEqualByComparingTo("1000.123456789012345678901234");
        assertThat(current.sources().getFirst().amountLocal()).isEqualByComparingTo(current.availableLocal());
        assertThat(pool.receipt(reserved.reservationId(),owner).status()).isEqualTo("RELEASED");
    }

    @Test void concurrentReservationsCannotSpendTheSameEmployeeBalanceAndUnknownRetryReturnsOriginalReceipt()throws Exception {
        var f=fixture(base);var scope=scope(f,base,BusinessTime.today());journal(f,1,"1000","1000",scope.asOf());
        var before=pool.preview(scope,Mode.AUXILIARY_BALANCE_POOL,List.of());var gate=new CountDownLatch(1);
        var result=new AtomicReference<Reservation>();var receipt=new AtomicReference<Receipt>();
        try(var executor=Executors.newFixedThreadPool(2)){
            List<Future<Boolean>> futures=new ArrayList<>();
            for(int n=0;n<2;n++)futures.add(executor.submit(()->{login();gate.await();var command=new Reservation(UUID.randomUUID(),owner(UUID.randomUUID()),scope,Mode.AUXILIARY_BALANCE_POOL,before.fingerprint(),new BigDecimal("750"),new BigDecimal("750"),List.of(),"匿名同员工余额池支付");
                try{var saved=pool.reserve(command);result.set(command);receipt.set(saved);return true;}catch(ApiException conflict){return false;}finally{SecurityContextHolder.clearContext();}}));
            gate.countDown();int winners=0;for(var future:futures)if(future.get(45,TimeUnit.SECONDS))winners++;assertThat(winners).isEqualTo(1);
        }
        assertThat(pool.reserve(result.get())).isEqualTo(receipt.get());
        assertThat(pool.preview(scope,Mode.AUXILIARY_BALANCE_POOL,List.of()).availableLocal()).isEqualByComparingTo("250");
        pool.cancel(new Cancel(UUID.randomUUID(),result.get().owner(),receipt.get().reservationId(),"撤回本次未过账支付"));
        assertThat(pool.preview(scope,Mode.AUXILIARY_BALANCE_POOL,List.of()).availableLocal()).isEqualByComparingTo("1000");
        assertThatThrownBy(()->pool.reserve(new Reservation(result.get().requestId(),result.get().owner(),scope,Mode.AUXILIARY_BALANCE_POOL,before.fingerprint(),new BigDecimal("1"),BigDecimal.ONE,List.of(),"不得改请求重放"))).isInstanceOf(ApiException.class);
    }

    @Test void accountingCurrencyAndActualOriginalUnitStaySeparateAndUnknownEmployeeNeverBecomesZero(){
        UUID foreign=UUID.randomUUID();db.update("INSERT INTO currencies(id,code,name,status,is_base_currency) VALUES(?,?,?,'使用',false)",foreign,"F-"+foreign,"匿名外币");
        var f=fixture(foreign);journal(f,1,"700.000001","100.000001",BusinessTime.today());
        var scope=scope(f,foreign,BusinessTime.today());var preview=pool.preview(scope,Mode.AUXILIARY_BALANCE_POOL,List.of());
        assertThat(preview.ready()).isTrue();assertThat(preview.availableLocal()).isEqualByComparingTo("700.000001");assertThat(preview.availableOriginal()).isEqualByComparingTo("100.000001");
        // Same account attribute but another original amount unit is another pool.
        assertThat(pool.preview(scope(f,base,BusinessTime.today()),Mode.AUXILIARY_BALANCE_POOL,List.of()).availableOriginal()).isZero();
        new TransactionTemplate(transactions).executeWithoutResult(status->{tx.bind();var unknown=journalInside(f,-1,"1","1",BusinessTime.today());
            db.update("DELETE FROM finance_gl_entry_allocations WHERE entry_id=?",unknown.entry());});
        var pending=pool.preview(scope,Mode.AUXILIARY_BALANCE_POOL,List.of());assertThat(pending.ready()).isFalse();assertThat(pending.availableLocal()).isNull();
    }

    @Test void historicalCutoffCannotSpendAnAmountAlreadyClearedByLaterActualGl(){
        var f=fixture(base);var old=BusinessTime.today().minusDays(5);var original=journal(f,1,"1000","1000",old);
        journal(f,-1,"1000","1000",BusinessTime.today());
        var preview=pool.preview(scope(f,base,old),Mode.EXPLICIT_GL_SOURCE,List.of(new SourceRef(original.entry(),1)));
        assertThat(preview.ready()).isTrue();assertThat(preview.availableLocal()).isZero();assertThat(preview.sources().getFirst().amountLocal()).isZero();
        assertThatThrownBy(()->pool.reserve(new Reservation(UUID.randomUUID(),owner(UUID.randomUUID()),scope(f,base,old),Mode.EXPLICIT_GL_SOURCE,preview.fingerprint(),BigDecimal.ONE,BigDecimal.ONE,List.of(new SourceAmount(new SourceRef(original.entry(),1),BigDecimal.ONE,BigDecimal.ONE)),"不得用旧日余额再次清偿"))).isInstanceOf(ApiException.class);
    }

    @Test void otherGlProducersCannotConsumeReservedCapacityAndImmediateChecksAreInvalidatedByLaterWrites(){
        var f=fixture(base);var scope=scope(f,base,BusinessTime.today());journal(f,1,"1000","1000",scope.asOf());
        var preview=pool.preview(scope,Mode.AUXILIARY_BALANCE_POOL,List.of());Owner owner=owner(UUID.randomUUID());
        var reservation=pool.reserve(new Reservation(UUID.randomUUID(),owner,scope,Mode.AUXILIARY_BALANCE_POOL,preview.fingerprint(),new BigDecimal("500"),new BigDecimal("500"),List.of(),"已批准未执行的匿名清偿"));
        assertThatThrownBy(()->journal(f,-1,"600","600",scope.asOf())).isInstanceOf(RuntimeException.class);
        assertThat(pool.preview(scope,Mode.AUXILIARY_BALANCE_POOL,List.of()).availableLocal()).isEqualByComparingTo("500");
        journal(f,-1,"100","100",scope.asOf());
        assertThatThrownBy(()->new TransactionTemplate(transactions).executeWithoutResult(status->{
            db.execute("SET CONSTRAINTS ALL IMMEDIATE");journalInside(f,-1,"450","450",scope.asOf());
        })).isInstanceOf(RuntimeException.class);
        assertThat(pool.preview(scope,Mode.AUXILIARY_BALANCE_POOL,List.of()).availableLocal()).isEqualByComparingTo("400");
        pool.cancel(new Cancel(UUID.randomUUID(),owner,reservation.reservationId(),"撤回尚未执行的清偿"));
        assertThat(pool.preview(scope,Mode.AUXILIARY_BALANCE_POOL,List.of()).availableLocal()).isEqualByComparingTo("900");
    }

    @Test void registeredFinancialAuditMetadataAlsoFiltersInsertAndDeleteWithoutExposingSourceBodies(){
        db.execute("CREATE TABLE finance_audit_projection_fixture(id uuid PRIMARY KEY,status text,amount numeric,source_snapshot jsonb,source_name text)");
        try{
            db.execute("SELECT fn_audit_track_table('finance_audit_projection_fixture','COLUMN_SCOPED','data_change',false,ARRAY['id','status'],true,NULL)");
            UUID id=UUID.randomUUID();db.update("INSERT INTO finance_audit_projection_fixture VALUES(?,'NEW',12345.67,'{\"salary\":\"PRIVATE_SALARY_FIXTURE\"}','PRIVATE_EMPLOYEE_FIXTURE')",id);
            db.update("DELETE FROM finance_audit_projection_fixture WHERE id=?",id);
            var records=db.queryForList("SELECT before::text,\"after\"::text FROM audit_log WHERE target_type='finance_audit_projection_fixture' ORDER BY created_at");
            assertThat(records).hasSize(2);assertThat(records.toString()).doesNotContain("PRIVATE_SALARY_FIXTURE","PRIVATE_EMPLOYEE_FIXTURE","12345.67","source_snapshot","source_name");
            assertThat(records.toString()).contains(id.toString(),"status");
        }finally{db.execute("DROP TABLE finance_audit_projection_fixture");}
    }

    @Test void explicitlyConfirmedAggregateWageLiabilityDoesNotInventAnEmployeeAuxiliary(){
        UUID wage=style("LIABILITY");String suffix="00000000000000000000"+Long.toUnsignedString(UUID.randomUUID().getLeastSignificantBits());String code="2211"+suffix.substring(suffix.length()-20);
        db.update("INSERT INTO finance_chart_codes(code,name,currency_name,currency_id,sort_order,source_row,source_kind,source_reference,classification,updated_by) VALUES(?,'匿名聚合工资负债','人民币',?,1,1,'MANUAL','明确受审原凭证','LIABILITY',?)",code,base,actor.user());
        db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by) VALUES(?,?,?)",code,wage,actor.user());
        var f=new Fixture(wage,code,null,base);var source=journal(f,-1,"1000","1000",BusinessTime.today());
        var scope=new Scope(wage,code,null,base,base,-1,BusinessTime.today());var ref=new SourceRef(source.entry(),1);
        assertThat(pool.preview(scope,Mode.AUXILIARY_BALANCE_POOL,List.of()).ready()).isFalse();
        var preview=pool.preview(scope,Mode.CONFIRMED_AGGREGATE_LIABILITY,List.of(ref));assertThat(preview.ready()).isTrue();
        var owner=new Owner("PAYROLL_LIABILITY",UUID.randomUUID(),actor.user());var amount=new BigDecimal("800");
        var reserved=pool.reserve(new Reservation(UUID.randomUUID(),owner,scope,Mode.CONFIRMED_AGGREGATE_LIABILITY,preview.fingerprint(),amount,amount,List.of(new SourceAmount(ref,amount,amount)),"人工明确原工资批次与该原GL范围，不按摘要猜配"));
        new TransactionTemplate(transactions).executeWithoutResult(status->{var actual=journalInside(f,1,"800","800",scope.asOf());pool.commit(new Commit(UUID.randomUUID(),owner,reserved.reservationId(),List.of(new Clearing(actual.entry(),1,ref))));});
        var remaining=pool.preview(scope,Mode.CONFIRMED_AGGREGATE_LIABILITY,List.of(ref));assertThat(remaining.availableLocal()).isEqualByComparingTo("200");
        assertThat(db.queryForObject("SELECT count(*) FROM finance_gl_settlement_scopes WHERE style_id=? AND auxiliary_id IS NULL AND party_id_snapshot IS NULL",Integer.class,wage)).isEqualTo(1);
    }

    /** GL ownership protocol fixture, not a claim that a supplier workflow was run here. */
    @Test void nativeManagedGlCannotBeReclaimedAndItsIndependentCreditCannotConsumeTheGeneralReservation(){
        var f=fixture(base);var scope=scope(f,base,BusinessTime.today());
        journal(f,1,"1000","1000",scope.asOf());
        var nativeSource=new TransactionTemplate(transactions).execute(status->journalInside(f,1,"2000","2000",scope.asOf(),"NATIVE_SUPPLIER_OFFSET"));
        var poolPreview=pool.preview(scope,Mode.AUXILIARY_BALANCE_POOL,List.of());
        assertThat(poolPreview.ready()).isTrue();assertThat(poolPreview.availableLocal()).isEqualByComparingTo("1000");
        var reclaimed=pool.preview(scope,Mode.EXPLICIT_GL_SOURCE,List.of(new SourceRef(nativeSource.entry(),1)));
        assertThat(reclaimed.ready()).isFalse();assertThat(reclaimed.availableLocal()).isNull();
        assertThat(reclaimed.issues()).anySatisfy(issue->assertThat(issue.message()).contains("原业务清偿"));
        var owner=owner(UUID.randomUUID());var reservation=pool.reserve(new Reservation(UUID.randomUUID(),owner,scope,
            Mode.AUXILIARY_BALANCE_POOL,poolPreview.fingerprint(),new BigDecimal("750"),new BigDecimal("750"),List.of(),"通用独立原来源预留"));
        new TransactionTemplate(transactions).executeWithoutResult(status->journalInside(f,-1,"2500","2500",scope.asOf(),"NATIVE_SUPPLIER_OFFSET_REV"));
        // The full ledger is still 500, while the distinct general source is 1000.
        assertThat(db.queryForObject("SELECT sum(entry.direction*allocation.amount_local) FROM finance_gl_entry_allocations allocation JOIN gl_entries entry ON entry.id=allocation.entry_id WHERE allocation.account_code=?",BigDecimal.class,f.code())).isEqualByComparingTo("500");
        assertThat(pool.preview(scope,Mode.AUXILIARY_BALANCE_POOL,List.of()).availableLocal()).isEqualByComparingTo("250");
        pool.cancel(new Cancel(UUID.randomUUID(),owner,reservation.reservationId(),"只取消尚未执行的通用预留"));
    }

    private record Actor(UUID user,UUID employee,UUID department) { }
    private record Fixture(UUID style,String code,UUID auxiliary,UUID originalCurrency) { }
    private record Journal(UUID voucher,UUID entry) { }
    private Actor actor(){UUID employee=UUID.randomUUID(),user=UUID.randomUUID();UUID department=db.queryForObject("SELECT id FROM departments WHERE code='DEPT_FIN'",UUID.class);
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,CURRENT_DATE,'active','regular')",employee,"POOL-"+employee,com.uten.imp.support.SyntheticEmployeeIdentity.name("pool",employee),department);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status) VALUES(?,?,?,'unused',false,false,'active')",user,employee,"pool-"+user);return new Actor(user,employee,department);}
    private UUID style(String category){UUID id=UUID.randomUUID();db.update("INSERT INTO payment_styles(id,code,name,category,status) VALUES(?,?,?,?,'使用')",id,"POOL-"+id,"匿名清偿科目-"+id,category);return id;}
    private Fixture fixture(UUID original){UUID style=style("ACCOUNT"),aux=UUID.randomUUID();String suffix="00000000000000000000"+Long.toUnsignedString(UUID.randomUUID().getLeastSignificantBits());String code="1221"+suffix.substring(suffix.length()-20);
        db.update("INSERT INTO finance_chart_codes(code,name,currency_name,currency_id,sort_order,source_row,source_kind,source_reference,classification,updated_by) VALUES(?,'匿名员工往来','人民币',?,1,1,'MANUAL','匿名受审来源','ASSET',?)",code,base,actor.user());
        db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by) VALUES(?,?,?)",code,style,actor.user());
        db.update("INSERT INTO finance_auxiliary_items(id,source_system,source_code,source_name,role,party_id,employee_id,source_reference,created_by,updated_by) VALUES(?,'POOL-TEST',?,'匿名员工','EMPLOYEE',?,?,?, ?,?)",aux,aux.toString(),actor.employee(),actor.employee(),"匿名财务辅助核对",actor.user(),actor.user());
        return new Fixture(style,code,aux,original);}
    private Scope scope(Fixture f,UUID original,LocalDate asOf){return new Scope(f.style(),f.code(),f.auxiliary(),base,original,1,asOf);}
    private Owner owner(UUID id){return new Owner("POOL_TEST",id,actor.user());}
    private Journal journal(Fixture f,int direction,String local,String original,LocalDate date){return new TransactionTemplate(transactions).execute(status->journalInside(f,direction,local,original,date));}
    private Journal journalInside(Fixture f,int direction,String local,String original,LocalDate date){return journalInside(f,direction,local,original,date,"POOL_TEST");}
    private Journal journalInside(Fixture f,int direction,String local,String original,LocalDate date,String protocol){tx.bind();UUID voucher=UUID.randomUUID(),entry=UUID.randomUUID();String period=date.toString().substring(0,7);
        db.update("INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type,status,created_by,updated_by) VALUES(?,?,?,?,'AUTO',?,0,?,?)",voucher,"POOL-"+voucher,period,date,protocol,actor.user(),actor.user());
        db.update("INSERT INTO gl_entries(id,voucher_id,line_no,style_id,direction,amount,entry_date,period,created_by,updated_by) VALUES(?,?,1,?,?,?,?,?,?,?)",entry,voucher,f.style(),direction,new BigDecimal(local),date,period,actor.user(),actor.user());
        db.update("INSERT INTO gl_entries(voucher_id,line_no,style_id,direction,amount,entry_date,period,created_by,updated_by) VALUES(?,2,?,?,?,?,?,?,?)",voucher,cash,-direction,new BigDecimal(local),date,period,actor.user(),actor.user());
        db.update("INSERT INTO finance_gl_entry_allocations(entry_id,allocation_no,account_code,source_account_code,auxiliary_id,currency_id,original_currency_id,amount_local,amount_original,auxiliary_role,party_id_snapshot,source_system,source_code,source_name,source_entry_id,source_row,source_snapshot,created_by) VALUES(?,1,?,?,?,?,?,?,?,?,?,'POOL-TEST',?,?,?,1,'{}',?)",
                entry,f.code(),f.code(),f.auxiliary(),base,f.originalCurrency(),new BigDecimal(local),new BigDecimal(original),f.auxiliary()==null?null:"EMPLOYEE",f.auxiliary()==null?null:actor.employee(),f.auxiliary()==null?null:f.auxiliary().toString(),f.auxiliary()==null?"匿名聚合工资负债":"匿名员工",entry.toString(),actor.user());
        db.update("UPDATE gl_vouchers SET status=1 WHERE id=?",voucher);return new Journal(voucher,entry);}
    private void login(){var user=new AuthUser(actor.user(),actor.employee(),"pool-fixture",Set.of("finance_report:view","finance:view:all","payment_style:edit","finance_post:execute","finance_application:execute"),false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,"",user.getAuthorities()));}
}
