package com.uten.imp.features.finance.application;

import com.uten.imp.testsupport.FixtureDatabaseProperties;
import com.uten.imp.testsupport.HistoricalJdbcNativeSql;
import com.uten.imp.features.expenseclaim.HistoricalExpenseSourceJdbc;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.*;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static com.uten.imp.features.finance.application.FinanceApplicationContracts.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
    "spring.profiles.active=dev","uten.inventory.value-work.enabled=false","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
    "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
    "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
    "uten.jwt.secret=application-test-only-jwt-key-0123456789-0123456789",
    "uten.crypto.pgp-master-key=application-test-only-pgp-key-0123456789-0123456789",
    "uten.crypto.hmac-key=application-test-only-hmac-key-0123456789",
    "uten.bootstrap.admin-login=application-harness-admin","uten.bootstrap.admin-password=ApplicationHarnessAdmin-1!"})
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class FinanceApplicationsPostgresTest {
    private static final String MIGRATIONS=snapshotMigrations();
    private final Map<String,Prepared> prepared=new LinkedHashMap<>();
    private static Map<String,Prepared> historicalPrepared=Map.of();
    private boolean historicalJdbc;
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("application_chain").withUsername("fixture_admin").withPassword("uten");
    @DynamicPropertySource static void database(DynamicPropertyRegistry r)throws Exception {
        PG.start();
        var source=new org.springframework.jdbc.datasource.DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        com.uten.imp.testsupport.TestFlyway.configure().dataSource(source).locations(MIGRATIONS).target("1039").load().migrate();
        var fixture=new FinanceApplicationsPostgresTest();fixture.db=new JdbcTemplate(source);fixture.data=source;fixture.historicalJdbc=true;
        fixture.transactions=new org.springframework.jdbc.datasource.DataSourceTransactionManager(source);
        var json=com.uten.imp.config.Jackson2ObjectMapperAutoConfiguration.domainObjectMapper();
        fixture.numbers=new com.uten.imp.common.docnumber.DocNumberService(HistoricalJdbcNativeSql.statements(fixture.db));
        fixture.legacy=new FinanceApplicationLegacyPolicy(fixture.db);
        fixture.applications=new FinanceApplicationService(fixture.db,json,null,new com.uten.imp.security.SecurityContextCurrentUser(),null,
                fixture.numbers,HistoricalExpenseSourceJdbc.readOnlyPort(fixture.db,json),null,null,null,null,null,null,fixture.legacy);
        UUID department=fixture.db.queryForObject("SELECT id FROM departments WHERE code='DEPT_FIN'",UUID.class);
        UUID administrator=UUID.randomUUID(),employee=UUID.randomUUID();
        fixture.db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,'旧数据播种管理员','其他',?,CURRENT_DATE,'active','regular')",
                employee,"OLD-FQ-"+employee,department);
        fixture.db.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status) VALUES(?,?,?,'not-used',false,true,'active')",
                administrator,employee,"old-applications-admin-"+administrator);
        fixture.seedActualPre1040OriginalRounds();
        com.uten.imp.testsupport.TestFlyway.configure().dataSource(source).locations(MIGRATIONS).load().migrate();
        historicalPrepared=Collections.unmodifiableMap(new LinkedHashMap<>(fixture.prepared));
        FixtureDatabaseProperties.bindSameRole(r,PG::getJdbcUrl,PG::getUsername,PG::getPassword);
        r.add("spring.flyway.locations",()->MIGRATIONS);
    }
    @Autowired JdbcTemplate db;@Autowired FinanceApplicationService applications;@Autowired FinanceApplicationRoles roles;@Autowired TaskClaimService claims;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactions;
    @Autowired com.uten.imp.features.expenseclaim.ExpenseClaimService expenseClaims;
    @Autowired com.uten.imp.features.finance.statement.FinanceAuxiliaryService auxiliaries;
    @Autowired com.uten.imp.application.port.FinancePayrollPaymentPort payroll;
    @Autowired javax.sql.DataSource data;
    @Autowired com.uten.imp.common.docnumber.DocNumberService numbers;
    @Autowired FinanceApplicationLegacyPolicy legacy;
    @Autowired com.uten.imp.security.TxSessionVars tx;
    @AfterEach void logout(){SecurityContextHolder.clearContext();}
    @Test void originalTravelPathHasThreeDistinctStepsNoCashAndFrozenSignaturesAndDurableReplay(){
        Prepared original=prepared.get("travel");World w=original.world();login(w.owner);UUID id=original.input().id();DraftInput command=original.input();
        assertThat(applications.save(command).get("id").toString()).isEqualTo(id.toString());
        assertThat(db.queryForObject("SELECT count(*) FROM finance_applications WHERE id=?",Integer.class,id)).isEqualTo(1);
        var submitted=applications.submit(id,original.submit());assertThat(submitted.get("status")).isEqualTo("SUBMITTED");
        login(w.finance2);assertThatThrownBy(()->claims.claim("FINANCE_APPLICATION_REVIEW",id.toString())).hasMessageContaining("明确参与范围");
        login(w.department);claims.claim("FINANCE_APPLICATION_REVIEW",id.toString());login(w.finance2);
        assertThat(claims.activeClaimViewsByTargetKey("FINANCE_APPLICATION_REVIEW")).doesNotContainKey(id.toString());assertThat(claims.activeClaimView("FINANCE_APPLICATION_REVIEW",id.toString())).isEmpty();
        login(w.department);var first=decide(id,true,null);assertThat(first.get("current_step")).isEqualTo(2);
        db.update("UPDATE employees SET full_name='人员已改名' WHERE id=?",w.department.employee);login(w.management);var second=decide(id,true,null);assertThat(second.get("current_step")).isEqualTo(3);
        login(w.finance1);var archived=decide(id,true,null);assertThat(archived.get("status")).isEqualTo("ARCHIVED");
        assertThat(db.queryForObject("SELECT decided_name_snapshot FROM finance_application_nodes WHERE application_id=? AND step_no=1",String.class,id)).isEqualTo(w.department.name);
        assertThat(db.queryForObject("SELECT count(*) FROM finance_application_executions WHERE application_id=?",Integer.class,id)).isZero();
        assertThatThrownBy(()->db.update("UPDATE finance_applications SET source_id=gen_random_uuid() WHERE id=?",id)).hasMessageContaining("原始内容已冻结");
        login(w.owner);assertThat(applications.list("mine",null,1,20).get("total")).isEqualTo(1L);
    }
    @Test void withdrawalPreservesOldRoundAndRejectionDoesNotRewriteItsDecisionOrCreateMoney(){
        Prepared original=prepared.get("withdraw");World w=original.world();login(w.owner);UUID id=original.input().id();var submitted=applications.detail(id);
        var withdrawn=applications.withdraw(id,action(submitted));assertThat(withdrawn.get("status")).isEqualTo("DRAFT");
        assertThatThrownBy(()->applications.submit(id,action(withdrawn))).isInstanceOfSatisfying(com.uten.imp.common.web.ApiException.class,
            error->assertThat(error.getCode()).isEqualTo(com.uten.imp.common.web.ErrorCode.CONFLICT));
        assertThat(legacy.allowed(id)).isFalse();
        assertThat(db.queryForObject("SELECT count(*) FROM finance_application_nodes WHERE application_id=? AND submission_round=1 AND status='WITHDRAWN'",Integer.class,id)).isEqualTo(3);
        assertThat(db.queryForObject("SELECT count(*) FROM finance_application_nodes WHERE application_id=? AND submission_round>1",Integer.class,id)).isZero();
        UUID rejected=prepared.get("reject").input().id();login(w.department);var returned=decide(rejected,false,"行程依据需要补齐");assertThat(returned.get("status")).isEqualTo("REJECTED");
        assertThatThrownBy(()->db.update("UPDATE finance_application_nodes SET status='APPROVED' WHERE application_id=? AND submission_round=1 AND step_no=1",rejected)).hasMessageContaining("不能覆盖");
        assertThat(db.queryForObject("SELECT count(*) FROM finance_application_executions WHERE application_id IN (?,?)",Integer.class,id,rejected)).isZero();
    }
    @Test void nonzeroExpensePostsOnlyAfterPaymentAndConcurrentReplayCannotDuplicateCashOrGl() throws Exception {
        Prepared original=prepared.get("expense");World w=original.world();Actor payer=payer();UUID account=account(),style=original.style();UUID id=original.input().id();
        approvePayment(w,id);
        assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",java.math.BigDecimal.class,account)).isEqualByComparingTo("1000");
        assertThat(db.queryForObject("SELECT count(*) FROM finance_application_executions WHERE application_id=?",Integer.class,id)).isZero();
        login(payer);var approved=applications.detail(id);Execute execute=execute(approved,account,style,"100.1234");
        assertThatThrownBy(()->applications.execute(id,execute)).hasMessageContaining("付款回单");
        proof(id,"FINANCE_APPLICATION_PAYMENT_PROOF");
        try(var threads=java.util.concurrent.Executors.newFixedThreadPool(4)){
            var start=new java.util.concurrent.CountDownLatch(1);List<java.util.concurrent.Future<Map<String,Object>>> requests=new ArrayList<>();
            for(int i=0;i<4;i++)requests.add(threads.submit(()->{login(payer);try{start.await();return applications.execute(id,execute);}finally{SecurityContextHolder.clearContext();}}));
            start.countDown();for(var request:requests)assertThat(request.get(40,java.util.concurrent.TimeUnit.SECONDS).get("status")).isEqualTo("EXECUTED");
        }
        login(payer);var posted=applications.detail(id);UUID doc=(UUID)posted.get("native_doc_id");
        assertThat(db.queryForObject("SELECT count(*) FROM finance_application_executions WHERE application_id=?",Integer.class,id)).isEqualTo(1);
        assertThat(db.queryForObject("SELECT count(*) FROM finance_reconciliations WHERE source_doc_id=?",Integer.class,doc)).isEqualTo(1);
        assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",java.math.BigDecimal.class,account)).isEqualByComparingTo("899.8766");
        assertBalanced(doc);assertThat(db.queryForObject("SELECT approver_id FROM finance_expenses WHERE id=?",UUID.class,doc)).isEqualTo(w.management.employee);
        assertThat(((Map<?,?>)applications.receipt(id,execute.requestId()).get("result")).get("status")).isEqualTo("EXECUTED");
        var confirmed=applications.confirm(id,action(posted));assertThat(confirmed.get("status")).isEqualTo("CONFIRMED");
        assertThatThrownBy(()->applications.reverse(id,reason(confirmed,"真实付款需要按原顺序撤回"))).hasMessageContaining("撤销财务确认");
        var unconfirmed=applications.unconfirm(id,reason(confirmed,"原回单核对后撤销本次确认"));
        var reversed=applications.reverse(id,reason(unconfirmed,"按原付款资金及GL对称撤销"));assertThat(reversed.get("status")).isEqualTo("REVERSED");
        assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",java.math.BigDecimal.class,account)).isEqualByComparingTo("1000");assertBalanced(doc);
        assertThat(db.queryForObject("SELECT count(*) FROM finance_application_events WHERE application_id=? AND event_type='PAYMENT_POSTED'",Integer.class,id)).isEqualTo(1);
        assertThatThrownBy(()->applications.execute(id,new Execute(execute.requestId(),execute.expectedVersion(),execute.sourceFingerprint(),account,execute.paymentDate(),execute.bankBookedAt(),"不同实际流水",execute.bankAmount(),"0",null,style,"1","ORDINARY_EXPENSE"))).hasMessageContaining("不同内容");
    }
    @org.junit.jupiter.params.ParameterizedTest
    @org.junit.jupiter.params.provider.ValueSource(strings={"REIMBURSEMENT","TRAVEL_REIMBURSEMENT"})
    void realReimbursementKeepsNativeInvoiceAndPaymentAuthorityAndCanReverse(String kind){
        Prepared original=prepared.get(kind);World w=original.world();Actor payer=payer();UUID nativeClaim=original.claim();UUID id=original.input().id();
        login(w.department);decide(id,true,null);login(w.finance1);
        var shown=applications.detail(id);UUID invoiceId=db.queryForObject("SELECT id FROM expense_claim_invoices WHERE claim_id=?",UUID.class,nativeClaim);var lease=claims.claim("FINANCE_APPLICATION_REVIEW",id.toString());
        applications.verifyExpenseInvoice(id,new InvoiceVerification(UUID.randomUUID(),((Number)shown.get("row_version")).longValue(),shown.get("source_fingerprint").toString(),lease.claimId(),invoiceId,expenseClaims.detail(nativeClaim).version(),"VERIFIED_MANUAL","原票原件及真实查验回执逐项核对一致"));
        decide(id,true,null);login(w.finance2);decide(id,true,null);login(w.management);decide(id,true,null);
        assertThat(db.queryForObject("SELECT status FROM expense_claims WHERE id=?",String.class,nativeClaim)).isEqualTo("APPROVED");
        login(payer);UUID account=account(),style=expenseStyle();proof(id,"FINANCE_APPLICATION_PAYMENT_PROOF");var approved=applications.detail(id);var paid=applications.execute(id,execute(approved,account,style,"100"));UUID doc=(UUID)paid.get("native_doc_id");
        assertThat(db.queryForObject("SELECT finance_expense_id FROM expense_claims WHERE id=?",UUID.class,nativeClaim)).isEqualTo(doc);assertBalanced(doc);
        assertThat(db.queryForObject("SELECT count(*) FROM expense_claim_events WHERE claim_id=? AND event_type='PAID'",Integer.class,nativeClaim)).isEqualTo(1);
        Object frozenSource=paid.get("source_snapshot");Object frozenFingerprint=paid.get("source_fingerprint");
        assertThat(((Map<?,?>)frozenSource).get("id")).isEqualTo(nativeClaim.toString());
        assertThat(frozenFingerprint.toString()).matches("[0-9a-f]{64}");
        String originalEvents=db.queryForObject("SELECT jsonb_agg(to_jsonb(event) ORDER BY id)::text FROM expense_claim_events event WHERE claim_id=?",String.class,nativeClaim);
        var reverse=reason(paid,"按真实报销原付款对称撤回");
        var reversed=applications.reverse(id,reverse);assertThat(reversed.get("status")).isEqualTo("REVERSED");
        assertThat(reversed).containsEntry("source_snapshot",frozenSource).containsEntry("source_fingerprint",frozenFingerprint)
                .containsEntry("expenseClaimUnavailable",true).doesNotContainKeys("currentDraftSource","currentDraftSourceFingerprint","currentDraftAmountOriginal");
        assertThat(((Map<?,?>)reversed.get("actions")).get("edit")).isEqualTo(false);
        assertThat(applications.detail(id)).containsEntry("source_snapshot",frozenSource).containsEntry("source_fingerprint",frozenFingerprint)
                .doesNotContainKey("currentDraftSource");
        assertThat(applications.receipt(id,reverse.requestId())).containsEntry("found",true);
        assertThat(expenseClaims.findReadableDetail(nativeClaim)).isEmpty();
        assertNotFound(()->expenseClaims.detail(nativeClaim));
        assertNotFound(()->expenseClaims.applicationBusinessSnapshot(nativeClaim));
        assertNotFound(()->applications.receipt(prepared.get("reject").input().id(),reverse.requestId()));
        assertThat(db.queryForObject("SELECT status FROM expense_claims WHERE id=?",String.class,nativeClaim)).isEqualTo("REJECTED");
        assertThat(db.queryForObject("SELECT count(*) FROM expense_claim_events WHERE claim_id=? AND event_type='PAYMENT_REVERSED'",Integer.class,nativeClaim)).isEqualTo(1);
        assertThat(db.queryForObject("SELECT jsonb_agg(to_jsonb(event) ORDER BY id)::text FROM expense_claim_events event WHERE claim_id=? AND event_type<>'PAYMENT_REVERSED'",String.class,nativeClaim)).isEqualTo(originalEvents);
        assertThatThrownBy(()->db.update("INSERT INTO expense_claim_events(claim_id,event_type,actor_employee_id,actor_name_snapshot) VALUES(?,'UNKNOWN_EVENT_KIND',?,'拒绝无效事件')",nativeClaim,payer.employee()))
                .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class).hasMessageContaining("expense_claim_events_type_chk");
        assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",java.math.BigDecimal.class,account)).isEqualByComparingTo("1000");
        assertThat(db.queryForObject("SELECT count(*) FROM expense_claim_invoices WHERE claim_id=? AND id=?",Integer.class,nativeClaim,invoiceId)).isEqualTo(1);
        login(w.owner());
        var editable=applications.detail(id);
        assertThat(((Map<?,?>)editable.get("actions")).get("edit")).isEqualTo(true);
        assertThat(((Map<?,?>)editable.get("currentDraftSource")).get("id")).isEqualTo(nativeClaim);
        Actor outsider=actor("无关只读",Set.of("finance_application:view"));login(outsider);
        assertNotFound(()->applications.detail(id));assertNotFound(()->applications.receipt(id,reverse.requestId()));
        new org.springframework.transaction.support.TransactionTemplate(transactions).executeWithoutResult(status->{
            UUID administrator=db.queryForObject("SELECT id FROM users WHERE is_super_admin AND NOT is_deleted ORDER BY created_at LIMIT 1",UUID.class);
            db.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,administrator.toString());
            db.update("UPDATE user_permission_overrides grant_row SET effect='revoke' FROM permissions permission WHERE permission.id=grant_row.permission_id AND grant_row.user_id=? AND permission.code='finance_application:view'",payer.user());
        });
        var revoked=new HashSet<>(payer.permissions());revoked.remove("finance_application:view");
        login(new Actor(payer.user(),payer.employee(),payer.name(),Set.copyOf(revoked)));
        assertNotFound(()->applications.detail(id));assertNotFound(()->applications.receipt(id,reverse.requestId()));
    }
    @Test void approvedSupplierPrepaymentUsesOneActualPaymentAssetAndNoFabricatedPayable(){
        Prepared original=prepared.get("prepayment");World w=original.world();Actor payer=payer();UUID id=original.input().id();approvePayment(w,id);
        login(payer);UUID account=account();proof(id,"FINANCE_APPLICATION_PAYMENT_PROOF");var approved=applications.detail(id);Execute command=execute(approved,account,null,"100");var paid=applications.execute(id,command);UUID doc=(UUID)paid.get("native_doc_id");
        assertThat(applications.execute(id,command).get("native_doc_id").toString()).isEqualTo(doc.toString());
        assertThat(db.queryForObject("SELECT count(*) FROM ar_ap_ledger WHERE source_doc_id=?",Integer.class,doc)).isZero();
        assertThat(db.queryForObject("SELECT amount_original FROM finance_supplier_advances WHERE payment_id=?",java.math.BigDecimal.class,doc)).isEqualByComparingTo("100");
        assertThat(db.queryForObject("SELECT count(*) FROM finance_gl_entry_allocations a JOIN gl_entries e ON e.id=a.entry_id WHERE e.source_doc_id=? AND a.account_code='1123'",Integer.class,doc)).isEqualTo(1);
        assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",java.math.BigDecimal.class,account)).isEqualByComparingTo("900");assertBalanced(doc);
        applications.reverse(id,reason(applications.detail(id),"按原预付真实资金对称撤销"));
        assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",java.math.BigDecimal.class,account)).isEqualByComparingTo("1000");
        assertThat(db.queryForObject("SELECT status FROM finance_supplier_advances WHERE payment_id=?",String.class,doc)).isEqualTo("REVERSED");assertBalanced(doc);
    }
    @Test void guessingAnOriginalPayableUuidDoesNotBypassItsExistingReadPermission(){
        Prepared original=prepared.get("payableScope");login(original.world().owner());var input=original.input();
        // The retired SAVE gate is now earlier; the original payload permission boundary still rejects a guessed UUID.
        assertThatThrownBy(()->applications.payload(input,FinanceApplicationCatalog.Kind.PAYMENT_APPLICATION)).hasMessageContaining("ar_ap_ledger:view");
        assertThatThrownBy(()->applications.save(input)).hasMessageContaining("当前申请流程");
        assertThat(db.queryForObject("SELECT count(*) FROM finance_applications WHERE id=?",Integer.class,input.id())).isZero();
    }
    @Test void originalPayrollHrFinanceManagementPathPaysOnceConfirmsAndReversesOnlyActualPayment(){
        World w=world(true);Actor payer=payer();login(w.owner);UUID batch=UUID.randomUUID(),slip=UUID.randomUUID(),item=UUID.randomUUID();var today=BusinessTime.today();UUID department=db.queryForObject("SELECT department_id FROM employees WHERE id=?",UUID.class,w.owner.employee);
        db.update("INSERT INTO payroll_batches(id,payroll_year,payroll_month,department_id,status,headcount,gross_income,total_deduction,net_income,generated_by) VALUES(?,?,?,?,'APPROVED',1,100,10,90,?)",batch,today.getYear(),today.getMonthValue(),department,w.owner.employee);
        db.update("INSERT INTO payroll_slips(id,batch_id,employee_id,employee_code_snapshot,employee_name_snapshot,department_id_snapshot,department_name_snapshot,payroll_year,payroll_month,gross_income,total_deduction,net_income) VALUES(?,?,?,'FQ-SALARY','原工资员工',?,'原工资部门',?,?,100,10,90)",slip,batch,w.owner.employee,department,today.getYear(),today.getMonthValue());
        db.update("INSERT INTO payroll_items(slip_id,line_no,item_code,name,item_type,amount,source_type) VALUES(?,1,'BASE','原工资','EARNING',100,'COMPENSATION_SNAPSHOT')",slip);
        db.update("INSERT INTO payroll_items(id,slip_id,line_no,item_code,name,item_type,amount,source_type,description) VALUES(?,?,2,'OTHER_DEDUCTION','原扣款','DEDUCTION',10,'VARIABLE_INPUT','已审原项明确归为应付扣款')",item,slip);
        var draft=applications.save(new DraftInput(UUID.randomUUID(),UUID.randomUUID(),-1,"PAYROLL_PAYMENT","原工资付款申请","原人事工资批次",today.toString(),batch,null,null,null,null,null,null,null,null,null));UUID id=(UUID)draft.get("id");applications.submit(id,action(draft));
        assertThat(db.queryForList("SELECT role_key FROM finance_application_nodes WHERE application_id=? ORDER BY step_no",String.class,id)).containsExactly("FINANCE_REVIEW_2","MANAGEMENT_PAYMENT");
        UUID wage=payrollStyle("LIABILITY","2211","LIABILITY",w.owner.user),cost=payrollStyle("ACCOUNT","410106","COST",w.owner.user),tax=payrollStyle("LIABILITY","2221","LIABILITY",w.owner.user),evidence=proof(id,"FINANCE_APPLICATION");
        login(w.finance2);var shown=applications.detail(id);var lease=claims.claim("FINANCE_APPLICATION_REVIEW",id.toString());
        var instruction=new com.uten.imp.application.port.FinancePayrollPaymentPort.Instruction(com.uten.imp.application.port.FinancePayrollPaymentPort.AccrualMode.NATIVE_APPROVED_PAYROLL,wage,Map.of(department,cost),Map.of(),null,"逐原工资项目明确会计准备依据",null,List.of(),List.of(),List.of(evidence),today,Map.of(item,List.of(new com.uten.imp.application.port.FinancePayrollPaymentPort.DeductionAllocation(UUID.randomUUID(),com.uten.imp.application.port.FinancePayrollPaymentPort.DeductionPurpose.STANDARD_LIABILITY,tax,"10",null,null,"本原项明确应付扣款依据"))));
        var prepared=applications.preparePayroll(id,new PayrollPreparation(UUID.randomUUID(),((Number)shown.get("row_version")).longValue(),shown.get("source_fingerprint").toString(),lease.claimId(),instruction));
        assertThat(((com.uten.imp.application.port.FinancePayrollPaymentPort.Prepared)prepared.get("preparation")).issues()).isEmpty();decide(id,true,null);login(w.management);decide(id,true,null);
        login(payer);UUID account=account(payrollStyle("ACCOUNT","1002","ASSET",w.owner.user));proof(id,"FINANCE_APPLICATION_PAYMENT_PROOF");var approved=applications.detail(id);Execute command=execute(approved,account,null,"90");var posted=applications.execute(id,command);UUID payment=(UUID)posted.get("native_doc_id");assertThat(applications.execute(id,command).get("native_doc_id").toString()).isEqualTo(payment.toString());
        var receipt=payroll.result(id).orElseThrow();assertThat(receipt.paymentId()).isEqualTo(payment);assertThat(receipt.receiptKind()).isEqualTo(com.uten.imp.application.port.FinancePayrollPaymentPort.ReceiptKind.BANK_PAYMENT);
        assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",java.math.BigDecimal.class,account)).isEqualByComparingTo("910");
        assertThat(db.queryForObject("SELECT count(*) FROM finance_payroll_accruals WHERE batch_id=?",Integer.class,batch)).isEqualTo(1);assertThat(db.queryForObject("SELECT count(*) FROM finance_payroll_payment_attempts WHERE application_id=?",Integer.class,id)).isEqualTo(1);
        var confirmed=applications.confirm(id,action(posted));assertThat(confirmed.get("status")).isEqualTo("CONFIRMED");applications.reverse(id,reason(confirmed,"对称撤销原工资实际付款，原计提保留"));
        assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",java.math.BigDecimal.class,account)).isEqualByComparingTo("1000");
        assertThat(db.queryForObject("SELECT status FROM gl_vouchers WHERE id=?",Integer.class,receipt.accrualVoucherId())).isEqualTo(1);
        assertThat(db.queryForObject("SELECT sum(amount*direction) FROM gl_entries WHERE style_id=? AND NOT is_deleted",java.math.BigDecimal.class,cost)).isEqualByComparingTo("100");
        assertThat(db.queryForObject("SELECT count(*) FROM finance_expenses WHERE remark LIKE ?",Integer.class,"%"+batch+"%")).isZero();
    }
    /** Historical compatibility fixtures only: original1039 fields/nodes, followed by real1040 capture.
     * This does not claim that the now-retired SAVE/SUBMIT API remains available. */
    @BeforeAll void captureActualPre1040OriginalRounds() {
        prepared.putAll(historicalPrepared);
        for(var fixture:prepared.entrySet())if(!fixture.getKey().equals("payableScope"))assertThat(legacy.allowed(fixture.getValue().input().id())).as(fixture.getKey()).isTrue();
        logout();
    }

    private void seedActualPre1040OriginalRounds() throws Exception {
        assertThat(db.queryForObject("SELECT to_regclass('finance_application_legacy_sources') IS NULL",Boolean.class)).isTrue();
        World travelWorld=world();prepare("travel",travelWorld,travel(UUID.randomUUID()),null,null,false);
        World withdrawal=world();prepare("withdraw",withdrawal,travel(UUID.randomUUID()),null,null,false);prepare("reject",withdrawal,travel(UUID.randomUUID()),null,null,false);
        World expense=world();UUID style=expenseStyle();prepare("expense",expense,payment(UUID.randomUUID(),"PAYMENT_APPLICATION","GENERAL_EXPENSE",null,null,style,"100.1234"),null,style,false);
        for(String kind:List.of("REIMBURSEMENT","TRAVEL_REIMBURSEMENT")){
            World w=world();UUID trip=null;
            if(kind.equals("TRAVEL_REIMBURSEMENT")){trip=UUID.randomUUID();seedOriginal(w,travel(trip),null,true);}
            login(w.owner());UUID claim=seedOriginalClaim(w,kind);
            var input=new DraftInput(UUID.randomUUID(),UUID.randomUUID(),-1,kind,"原差旅报销申请","附原票据",BusinessTime.today().toString(),claim,trip,null,null,null,null,null,null,null,null);
            prepare(kind,w,input,claim,null,false);
        }
        World prepayment=world();login(prepayment.owner());UUID supplier=preparePrepaymentSource();
        prepare("prepayment",prepayment,payment(UUID.randomUUID(),"PREPAYMENT_APPLICATION","SUPPLIER_PREPAYMENT",supplier,null,null,"100"),null,null,false);
        World scoped=world();login(scoped.owner());UUID inaccessible=UUID.randomUUID();db.update("INSERT INTO suppliers(id,code,name,status,code_sequence) VALUES(?,?,'匿名权限范围供应商','使用',(SELECT COALESCE(MAX(code_sequence),0)+1 FROM suppliers))",inaccessible,"FQ-S-"+inaccessible);
        prepared.put("payableScope",new Prepared(scoped,payment(UUID.randomUUID(),"PAYMENT_APPLICATION","SUPPLIER_AP",inaccessible,UUID.randomUUID(),null,"100"),null,null,null));
        com.uten.imp.testsupport.TestFlyway.configure().dataSource(data).locations(MIGRATIONS).target("1040").load().migrate();
        for(var fixture:prepared.entrySet())if(!fixture.getKey().equals("payableScope"))assertThat(legacy.allowed(fixture.getValue().input().id())).as(fixture.getKey()).isTrue();
        logout();
    }
    private record Prepared(World world,DraftInput input,Action submit,UUID claim,UUID style) { }
    private void prepare(String key,World w,DraftInput input,UUID claim,UUID style,boolean archived){prepared.put(key,new Prepared(w,input,seedOriginal(w,input,claim,archived),claim,style));}
    private Action seedOriginal(World w,DraftInput input,UUID claim,boolean archived){
        login(w.owner());return new org.springframework.transaction.support.TransactionTemplate(transactions).execute(status->{
            if(historicalJdbc)bindHistoricalActor(w.owner());else tx.bind();
            return seedOriginalInTransaction(w,input,claim,archived);
        });
    }
    private Action seedOriginalInTransaction(World w,DraftInput input,UUID claim,boolean archived){
        var kind=FinanceApplicationCatalog.Kind.valueOf(input.kind());var payload=applications.payload(input,kind);
        UUID department=db.queryForObject("SELECT department_id FROM employees WHERE id=?",UUID.class,w.owner().employee());
        db.update("""
            INSERT INTO finance_applications(id,application_no,kind,source_kind,source_id,applicant_id,applicant_name_snapshot,department_id,department_name_snapshot,title,remark,travel_application_id,requested_date,requested_payload,request_fingerprint,created_by,updated_by)
            VALUES(?,?,?,?,?,?,?,?,'原申请部门',?,?,?,?::date,?::jsonb,?,?,?)
            """,input.id(),numbers.nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.FIN_APPLICATION),input.kind(),claim==null?(kind==FinanceApplicationCatalog.Kind.TRAVEL_APPLICATION?"TRAVEL_PLAN":"PAYMENT_INTENT"):"EXPENSE_CLAIM",claim,w.owner().employee(),w.owner().name(),department,input.title(),Objects.toString(input.remark(),""),input.travelApplicationId(),input.requestedDate(),applications.encode(payload),applications.digest(payload),w.owner().user(),w.owner().user());
        if(claim!=null)db.update("INSERT INTO finance_expense_application_links(claim_id,kind,travel_application_id,application_id,created_by) VALUES(?,?,?,?,?)",claim,input.kind(),input.travelApplicationId(),input.id(),w.owner().user());
        var facts=applications.source(applications.row(input.id(),false));
        Action submit=new Action(UUID.randomUUID(),0,null,null,null);
        db.update("UPDATE finance_applications SET source_snapshot=?::jsonb,source_fingerprint=?,amount_original=?,currency_id=?,status='SUBMITTED',submission_round=1,current_step=1,submitted_at=now(),row_version=1 WHERE id=?",applications.encode(facts.facts()),facts.fingerprint(),facts.amount(),facts.currency(),input.id());
        for(var step:FinanceApplicationCatalog.steps(kind)){
            var assigned=historicalJdbc?historicalAssignments(step.role(),department,w.owner().employee()):roles.resolve(step.role(),department,w.owner().employee(),Set.of());assertThat(assigned).isNotEmpty();
            Actor decided=step.role()==FinanceApplicationCatalog.Role.DEPARTMENT_REVIEW?w.department():step.role()==FinanceApplicationCatalog.Role.TRAVEL_APPROVAL?w.management():w.finance1();
            db.update("""
                INSERT INTO finance_application_nodes(application_id,submission_round,step_no,role_key,label_snapshot,action,assignees,status,decided_by,decided_name_snapshot,decided_at)
                VALUES(?,1,?,?,?,?,?::jsonb,?,?,?,CASE WHEN ? THEN now() ELSE NULL END)
                """,input.id(),step.ordinal(),step.role().name(),step.label(),step.action(),applications.encode(assigned),archived?(step.action().equals("ARCHIVE")?"ARCHIVED":"APPROVED"):"PENDING",archived?decided.employee():null,archived?decided.name():null,archived);
        }
        if(archived)db.update("UPDATE finance_applications SET status='ARCHIVED',approved_at=now(),approved_by=?,approved_name_snapshot=? WHERE id=?",w.finance1().employee(),w.finance1().name(),input.id());
        Map<String,Object> draft=new LinkedHashMap<>();draft.put("id",input.id());draft.put("status","DRAFT");draft.put("row_version",0);
        db.update("INSERT INTO finance_application_operations(request_id,application_id,actor_id,operation,payload_hash,result) VALUES(?,?,?,'SAVE',?,?::jsonb)",input.requestId(),input.id(),w.owner().user(),applications.digest(List.of("SAVE",input.id(),input)),applications.encode(draft));
        Map<String,Object> submitted=new LinkedHashMap<>();submitted.put("id",input.id());submitted.put("status","SUBMITTED");submitted.put("row_version",1);submitted.put("source_fingerprint",facts.fingerprint());submitted.put("submission_round",1);
        db.update("INSERT INTO finance_application_operations(request_id,application_id,actor_id,operation,payload_hash,result) VALUES(?,?,?,'SUBMIT',?,?::jsonb)",submit.requestId(),input.id(),w.owner().user(),applications.digest(List.of("SUBMIT",input.id(),submit)),applications.encode(submitted));
        return submit;
    }
    private UUID seedOriginalClaim(World w,String kind){
        UUID claim=UUID.randomUUID();
        db.update("INSERT INTO expense_claims(id,claim_no,applicant_id,applicant_name_snapshot,applicant_department_id,title,total_amount,status,approval_stage,approval_round,submitted_at,expense_kind,remark) VALUES(?,?,?,? ,(SELECT department_id FROM employees WHERE id=?),'原差旅住宿费',100,'SUBMITTED',NULL,1,now(),?,'原凭据只读保全')",claim,numbers.nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.EXPENSE_CLAIM),w.owner().employee(),w.owner().name(),w.owner().employee(),kind.equals("TRAVEL_REIMBURSEMENT")?"TRAVEL":"GENERAL");
        db.update("INSERT INTO expense_claim_items(id,claim_id,line_no,category,amount,expense_date,description) VALUES(?,?,1,'TRAVEL',100,CURRENT_DATE,'真实原差旅事项')",UUID.randomUUID(),claim);
        UUID original=proof(claim,"EXPENSE_CLAIM");
        db.update("INSERT INTO expense_claim_invoices(id,claim_id,line_no,invoice_type,invoice_no,issue_date,seller_name,amount_excl_tax,tax_amount,total_amount,attachment_id) VALUES(?,?,1,'DIGITAL',?,CURRENT_DATE,'原票供应方',94.34,5.66,100,?)",UUID.randomUUID(),claim,new java.math.BigInteger(UUID.randomUUID().toString().replace("-",""),16).toString().substring(0,20),original);
        db.update("UPDATE expense_claims SET submission_snapshot=?::jsonb WHERE id=?",historicalJdbc?HistoricalExpenseSourceJdbc.snapshot(db,claim):expenseClaims.applicationBusinessSnapshot(claim),claim);
        return claim;
    }
    private UUID preparePrepaymentSource(){
Actor accountant=actor("预付科目核对",Set.of("finance_report:view","finance:view:all","payment_style:edit"));login(accountant);
        UUID supplier=UUID.randomUUID(),base=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class),asset=UUID.randomUUID();
        db.update("INSERT INTO suppliers(id,code,name,status,code_sequence) VALUES(?,?,'匿名预付供应商','使用',(SELECT COALESCE(MAX(code_sequence),0)+1 FROM suppliers))",supplier,"FQ-S-"+supplier);
        db.update("INSERT INTO payment_styles(id,code,name,category,status) VALUES(?,?,'匿名明确预付资产','ACCOUNT','使用')",asset,"FQ-A-"+asset);
        db.update("INSERT INTO finance_chart_codes(code,name,currency_name,currency_id,classification,source_kind,source_reference,sort_order,source_row,updated_by) VALUES('1123','原预付账款','',?,'ASSET','MANUAL','匿名测试明确预付资产来源',1,1,?) ON CONFLICT(code) DO UPDATE SET currency_id=excluded.currency_id",base,accountant.user);
        db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by) VALUES('1123',?,?)",asset,accountant.user);
        if(historicalJdbc)new org.springframework.transaction.support.TransactionTemplate(transactions).executeWithoutResult(status->{
            bindHistoricalActor(accountant);UUID auxiliary=UUID.randomUUID();
            db.update("""
                INSERT INTO finance_auxiliary_items(id,source_system,source_code,source_name,role,party_id,supplier_id,source_reference,created_by,updated_by)
                VALUES(?,'匿名原账套',?,'匿名原供应商','SUPPLIER',?,?,'与真实供应商UUID明确对应',?,?)
                """,auxiliary,"SUP-"+supplier,supplier,supplier,accountant.user(),accountant.user());
            db.update("INSERT INTO finance_account_auxiliary_bindings(account_code,auxiliary_id,created_by) VALUES('1123',?,?)",auxiliary,accountant.user());
        });
        else auxiliaries.save(new com.uten.imp.features.finance.statement.FinanceAuxiliaryContracts.Save(null,null,"匿名原账套","SUP-"+supplier,"匿名原供应商","SUPPLIER",supplier,"与真实供应商UUID明确对应","1123"));
        db.update("UPDATE system_posting_style_roles SET style_id=? WHERE role_key='SUPPLIER_PREPAYMENT_ASSET'",asset);
        for(String role:List.of("FX_GAIN_LOSS","BANK_FEE_EXPENSE")){if(db.queryForObject("SELECT system_posting_style_id(?) IS NULL",Boolean.class,role)){db.update("UPDATE system_posting_style_roles SET style_id=? WHERE role_key=?",expenseStyle(),role);}}
        return supplier;
    }
    private static String snapshotMigrations(){
        try{
            var root=java.nio.file.Path.of(Objects.requireNonNull(FinanceApplicationsPostgresTest.class.getClassLoader().getResource("db/migration")).toURI());
            var snapshot=java.nio.file.Files.createTempDirectory("uten-original-finance-round-migrations-");
            try(var paths=java.nio.file.Files.list(root)){for(var p:paths.filter(f->f.getFileName().toString().endsWith(".sql")).toList()){byte[] bytes=java.nio.file.Files.readAllBytes(p);java.nio.file.Files.write(snapshot.resolve(p.getFileName()),bytes);if(!Arrays.equals(bytes,java.nio.file.Files.readAllBytes(p)))throw new IllegalStateException("Migration source changed while taking snapshot");}}
            return "filesystem:"+snapshot.toAbsolutePath().toString().replace('\\','/');
        }catch(Exception e){throw new IllegalStateException("Cannot freeze the actual migration source",e);}
    }
    private UUID payrollStyle(String category,String prefix,String classification,UUID actor){UUID id=UUID.randomUUID(),base=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class);String code=prefix+new java.math.BigInteger(id.toString().replace("-",""),16).toString().substring(0,18);db.update("INSERT INTO payment_styles(id,code,name,category,status) VALUES(?,?,?,?,'使用')",id,"FQ-P-"+id,"原工资科目-"+id,category);db.update("INSERT INTO finance_chart_codes(code,name,currency_name,currency_id,classification,source_kind,source_reference,sort_order,source_row,updated_by) VALUES(?,?,'',?,?,'MANUAL','匿名原工资明确科目依据',1,1,?)",code,"原财务工资科目-"+id,base,classification,actor);db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by) VALUES(?,?,?)",code,id,actor);return id;}
    private void approvePayment(World w,UUID id){for(Actor reviewer:List.of(w.department,w.finance1,w.finance2,w.management)){login(reviewer);decide(id,true,null);}}
    private DraftInput payment(UUID id,String kind,String nature,UUID supplier,UUID payable,UUID style,String amount){UUID currency=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class);return new DraftInput(UUID.randomUUID(),id,-1,kind,"原实际付款申请","原单据与款项依据",BusinessTime.today().toString(),null,null,nature,supplier,currency,List.of(new RequestLine(UUID.randomUUID(),"原款项",amount,payable,style)),null,null,null,null);}
    private Execute execute(Map<String,Object> app,UUID account,UUID style,String amount){return new Execute(UUID.randomUUID(),((Number)app.get("row_version")).longValue(),app.get("source_fingerprint").toString(),account,BusinessTime.today().toString(),java.time.OffsetDateTime.now().toString(),"真实回单-"+UUID.randomUUID(),amount,"0",null,style,"1","ORDINARY_EXPENSE");}
    private Action reason(Map<String,Object> app,String reason){var action=action(app);return new Action(action.requestId(),action.expectedVersion(),action.sourceFingerprint(),null,reason);}
    private void assertBalanced(UUID doc){assertThat(db.queryForObject("SELECT COALESCE(sum(direction*amount),0) FROM gl_entries WHERE source_doc_id=? AND NOT is_deleted",java.math.BigDecimal.class,doc)).isZero();}
    private void assertNotFound(Runnable action){assertThatThrownBy(action::run).isInstanceOfSatisfying(com.uten.imp.common.web.ApiException.class,
            failure->assertThat(failure.getCode()).isEqualTo(com.uten.imp.common.web.ErrorCode.NOT_FOUND));}
    private UUID proof(UUID owner,String type){UUID id=UUID.randomUUID();db.update("INSERT INTO attachments(id,owner_type,owner_id,storage_key,original_name,content_type,size_bytes,sha256,storage_provider,lifecycle_state,scan_engine,scanned_at,promoted_at) VALUES(?,?,?,?,'匿名原回单.pdf','application/pdf',100,?,'local','CLEAN','fixture',now(),now())",id,type,owner,id+".pdf","a".repeat(64));return id;}
    private UUID account(){return account(null);}
    private UUID account(UUID suppliedStyle){UUID currency=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class);UUID bank=suppliedStyle==null?UUID.randomUUID():suppliedStyle;if(suppliedStyle==null){db.update("INSERT INTO payment_styles(id,code,name,category,status) VALUES(?,?,?,'ACCOUNT','使用')",bank,"FQ-B-"+bank,"匿名银行科目-"+bank);}UUID id=UUID.randomUUID();db.update("INSERT INTO accounts(id,code,name,account_type,currency_id,init_balance,receipts_total,payments_total,balance_current,status,style_id) VALUES(?,?,'匿名实际银行','BANK',?,1000,0,0,1000,'使用',?)",id,"FQ-B-"+id,currency,bank);return id;}
    private UUID expenseStyle(){UUID id=UUID.randomUUID();db.update("INSERT INTO payment_styles(id,code,name,category,status) VALUES(?,?,?,'EXPENSE','使用')",id,"FQ-E-"+id,"匿名原费用科目-"+id);return id;}
    private Actor payer(){return actor("实际支付财务",Set.of("finance_application:view","finance_application:execute","finance_application:confirm","finance_application:reverse","finance_expense:view","finance_expense:create","finance_expense:approve","finance_expense:reverse","finance_expense:gl_confirm","finance_payment:view","finance_payment:create","finance_payment:approve","finance_payment:reverse","finance:view:all","expense:pay","attachment:view","attachment:download"));}
    private Map<String,Object> decide(UUID id,boolean approve,String reason){var shown=applications.detail(id);var lease=claims.claim("FINANCE_APPLICATION_REVIEW",id.toString());return applications.review(id,new Action(UUID.randomUUID(),((Number)shown.get("row_version")).longValue(),shown.get("source_fingerprint").toString(),lease.claimId(),reason),approve);}
    private DraftInput travel(UUID id){return new DraftInput(UUID.randomUUID(),id,-1,"TRAVEL_APPLICATION","原行程申请","原始行程依据",BusinessTime.today().toString(),null,null,null,null,null,null,"客户所在地",BusinessTime.today().toString(),BusinessTime.today().plusDays(1).toString(),"客户现场业务办理");}
    private Action action(Map<String,Object> app){return new Action(UUID.randomUUID(),((Number)app.get("row_version")).longValue(),Objects.toString(app.get("source_fingerprint"),null),null,null);}
    private World world(){return world(false);}
    private World world(boolean salary){Actor admin=actor("设置",Set.of("expense:settings","finance_application:view")),owner=actor("申请人",salary?Set.of("finance_application:view","finance_application:apply","expense:apply","payroll:generate"):Set.of("finance_application:view","finance_application:apply","expense:apply")),department=reviewer("部门"),finance1=reviewer("财务一"),finance2=reviewer("财务二"),management=reviewer("总经办");login(admin);
        UUID dept=db.queryForObject("SELECT department_id FROM employees WHERE id=?",UUID.class,owner.employee);
        if(historicalJdbc) {
            new org.springframework.transaction.support.TransactionTemplate(transactions).executeWithoutResult(status->{
                bindHistoricalActor(admin);
                for(var binding:Map.of("DEPARTMENT_REVIEW",department,"TRAVEL_APPROVAL",management,"FINANCE_CUSTODY",finance1,"FINANCE_REVIEW_1",finance1,"FINANCE_REVIEW_2",finance2,"MANAGEMENT_PAYMENT",management).entrySet()) {
                    db.update("""
                        INSERT INTO finance_application_role_bindings(id,role_key,department_id,employee_id,source_reference,updated_by)
                        VALUES(?,?,?,?,'原图岗位明确指派测试依据',?)
                        """,UUID.randomUUID(),binding.getKey(),binding.getKey().equals("DEPARTMENT_REVIEW")?dept:null,binding.getValue().employee(),admin.user());
                }
                var settings=db.queryForMap("SELECT enabled,source_reference FROM finance_application_settings WHERE id=1 FOR UPDATE");
                String reference="按财务原图启用新申请流程测试依据";
                if(!Boolean.TRUE.equals(settings.get("enabled")))db.update("INSERT INTO finance_application_enable_periods(enabled_at,actor_id,source_reference) VALUES(now(),?,?)",admin.user(),reference);
                if(!Boolean.TRUE.equals(settings.get("enabled"))||!reference.equals(settings.get("source_reference"))) {
                    db.update("UPDATE finance_application_settings SET enabled=true,enabled_at=COALESCE(enabled_at,now()),source_reference=?,row_version=row_version+1,updated_at=now(),updated_by=? WHERE id=1",reference,admin.user());
                }
            });
            return new World(owner,department,finance1,finance2,management);
        }
        for(var binding:Map.of("DEPARTMENT_REVIEW",department,"TRAVEL_APPROVAL",management,"FINANCE_CUSTODY",finance1,"FINANCE_REVIEW_1",finance1,"FINANCE_REVIEW_2",finance2,"MANAGEMENT_PAYMENT",management).entrySet())roles.saveRole(new RoleInput(UUID.randomUUID(),-1,binding.getKey(),binding.getKey().equals("DEPARTMENT_REVIEW")?dept:null,binding.getValue().employee,"原图岗位明确指派测试依据"));
        var settings=roles.settings();roles.saveSettings(new SettingsInput(((Number)settings.get("version")).longValue(),true,"按财务原图启用新申请流程测试依据"));return new World(owner,department,finance1,finance2,management);
    }

    private void bindHistoricalActor(Actor actor) {
        var row=db.queryForMap("SELECT employee_id,login_account FROM users WHERE id=? AND NOT is_deleted AND status='active'",actor.user());
        assertThat(row.get("employee_id")).isEqualTo(actor.employee());
        db.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,actor.user().toString());
        db.queryForObject("SELECT set_config('app.actor_account',?,true)",String.class,row.get("login_account").toString());
    }

    /** These fixture assignees explicitly grant all four required codes.
     * Read actual enabled identities and active grants before freezing them. */
    private List<Assignment> historicalAssignments(FinanceApplicationCatalog.Role role,UUID department,UUID applicant) {
        var ids=db.queryForList("SELECT employee_id FROM finance_application_role_bindings WHERE role_key=? AND department_id IS NOT DISTINCT FROM ?::uuid ORDER BY id",UUID.class,
                role.name(),role==FinanceApplicationCatalog.Role.DEPARTMENT_REVIEW?department:null);
        List<Assignment> result=new ArrayList<>();
        for(UUID id:ids) {
            var accounts=db.queryForList("""
                    SELECT e.id,u.id AS user_id,e.full_name FROM employees e JOIN users u ON u.employee_id=e.id
                    WHERE e.id=fn_canonical_employee_identity(?) AND NOT e.is_deleted AND e.status<>'resigned'
                      AND NOT u.is_deleted AND u.status='active' ORDER BY u.id
                    """,id);
            for(var account:accounts) {
                UUID user=(UUID)account.get("user_id"),person=(UUID)account.get("id");
                int grants=db.queryForObject("""
                    SELECT count(DISTINCT permission.code) FROM user_permission_overrides grant_row
                    JOIN permissions permission ON permission.id=grant_row.permission_id
                    WHERE grant_row.user_id=? AND grant_row.effect='grant' AND grant_row.active
                      AND permission.code IN('finance_application:view','finance_application:review','attachment:view','attachment:download')
                    """,Integer.class,user);
                assertThat(grants).isEqualTo(4);
                if((role==FinanceApplicationCatalog.Role.FINANCE_CUSTODY||!person.equals(applicant))
                        &&result.stream().noneMatch(value->value.employeeId().equals(person))) {
                    result.add(new Assignment(person,user,account.get("full_name").toString()));break;
                }
            }
        }
        return List.copyOf(result);
    }
    private Actor reviewer(String name){return actor(name,Set.of("finance_application:view","finance_application:review","attachment:view","attachment:download","notice:read"));}
    private Actor actor(String label,Set<String> permissions){UUID employee=UUID.randomUUID(),user=UUID.randomUUID();String name=label+employee.toString().substring(0,8);UUID department=db.queryForObject("SELECT id FROM departments WHERE code='DEPT_FIN'",UUID.class);
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')",employee,"A-"+employee,name,department);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status) VALUES(?,?,?,'not-used',false,false,'active')",user,employee,"application-"+user);
        new org.springframework.transaction.support.TransactionTemplate(transactions).executeWithoutResult(status->{UUID administrator=db.queryForObject("SELECT id FROM users WHERE is_super_admin AND NOT is_deleted ORDER BY created_at LIMIT 1",UUID.class);db.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,administrator.toString());for(var code:permissions)db.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'grant' FROM permissions WHERE code=?",user,code);});return new Actor(user,employee,name,permissions);
    }
    private void login(Actor actor){var user=new AuthUser(actor.user,actor.employee,"application-"+actor.user,actor.permissions,false,true,false);SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,"",user.getAuthorities()));}
    record Actor(UUID user,UUID employee,String name,Set<String> permissions){}
    record World(Actor owner,Actor department,Actor finance1,Actor finance2,Actor management){}
}
