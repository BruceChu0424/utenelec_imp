package com.uten.imp.features.expenseclaim;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.expenseclaim.dto.*;
import com.uten.imp.features.finance.expense.FinanceExpenseService;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Actual service/transaction proof against an isolated fully migrated PostgreSQL. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
    "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
    "uten.reporting.materialized-view-refresh.enabled=false", "uten.policy-intelligence.enabled=false",
    "uten.features.goods-owner-scope-enabled=false", "uten.inventory.value-work-initial-delay-ms=3600000",
    "uten.jwt.secret=expense-test-only-jwt-key-0123456789-0123456789",
    "uten.crypto.pgp-master-key=expense-test-only-pgp-key-0123456789-0123456789",
    "uten.crypto.hmac-key=expense-test-only-hmac-key-0123456789",
    "uten.bootstrap.admin-login=expense-harness-admin",
    "uten.bootstrap.admin-password=ExpenseHarnessAdmin-1!"})
class ExpenseClaimChainPostgresTest {
    static final PostgreSQLContainer<?> PG=new PostgreSQLContainer<>("postgres:16-alpine")
        .withDatabaseName("expense_chain").withUsername("uten").withPassword("uten");
    @DynamicPropertySource static void database(DynamicPropertyRegistry r) {
        PG.start();r.add("spring.datasource.url",PG::getJdbcUrl);
        r.add("spring.datasource.username",PG::getUsername);r.add("spring.datasource.password",PG::getPassword);
    }
    @Autowired JdbcTemplate jdbc;
    @Autowired ExpenseClaimService claims;
    @Autowired ExpenseClaimSettingsService settings;
    @Autowired FinanceExpenseService expenses;
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void actualClaimRejectResubmitVerifyPayIsAtomicAndIdempotent() throws Exception {
        Actor applicant=actor("applicant"),reviewer=actor("reviewer"),cashier=actor("cashier");
        login(applicant,"expense:apply");
        var draft=claims.create(request("员工出差住宿",null));
        UUID claimId=draft.id();
        assertThatThrownBy(()->claims.submit(claimId,draft.version())).isInstanceOf(ApiException.class)
            .hasMessageContaining("原始凭证");
        UUID attachment=attachment(claimId);
        var invoice=claims.addInvoiceVersioned(claimId,new ExpenseClaimInvoiceInput(
            "DIGITAL",null,"26310000000000123456",BusinessTime.today(),"测试酒店","91310000123456789X","测试公司",
            new BigDecimal("94.34"),new BigDecimal("5.66"),new BigDecimal("100.00"),attachment,null,draft.version(),null));
        long submittedVersion=claims.submit(claimId,invoice.version()).version();
        login(reviewer,"expense:approve","attachment:view","attachment:download");
        assertThatThrownBy(()->claims.approve(claimId,submittedVersion)).isInstanceOf(ApiException.class)
            .hasMessageContaining("逐张核对");
        var rejected=claims.reject(claimId,"补充业务说明",submittedVersion);
        login(applicant,"expense:apply");
        var edited=claims.editVersioned(claimId,request("出差拜访客户住宿",rejected.version()));
        var submitted=claims.submit(claimId,edited.version());
        login(reviewer,"expense:approve","attachment:view","attachment:download");
        assertThatThrownBy(()->claims.approve(claimId,submittedVersion)).isInstanceOf(ApiException.class)
            .hasMessageContaining("已更新");
        UUID invoiceId=jdbc.queryForObject("SELECT id FROM expense_claim_invoices WHERE claim_id=?",UUID.class,claimId);
        var checked=claims.verifyInvoice(claimId,invoiceId,new ExpenseClaimInvoiceVerifyRequest(
            submitted.version(),"VERIFIED_MANUAL","测试票据原件与查验回执逐项核对一致"));
        var approved=claims.approve(claimId,checked.version());
        login(reviewer,"expense:pay");
        var account=account();UUID style=expenseStyle();
        var pay=new ExpenseClaimPaymentRequest(account,style,BusinessTime.today(),approved.version());
        assertThatThrownBy(()->claims.payVersioned(claimId,pay)).isInstanceOf(ApiException.class)
            .hasMessageContaining("审批人与打款人");
        login(cashier,"expense:pay","finance_expense:reverse","finance:view:all");
        assertThatThrownBy(()->claims.payVersioned(claimId,pay)).isInstanceOf(ApiException.class).hasMessageContaining("付款回单");
        attachment(claimId,"EXPENSE_PAYMENT_PROOF");
        UUID foreignAccount=account(false);
        assertThatThrownBy(()->claims.payVersioned(claimId,new ExpenseClaimPaymentRequest(
            foreignAccount,style,BusinessTime.today(),approved.version())))
            .isInstanceOf(ApiException.class).hasMessageContaining("本位币");
        assertThat(jdbc.queryForObject("SELECT balance_current FROM accounts WHERE id=?",BigDecimal.class,foreignAccount)).isEqualByComparingTo("1000");
        assertThat(jdbc.queryForObject("SELECT status FROM expense_claims WHERE id=?",String.class,claimId)).isEqualTo("APPROVED");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM finance_expenses WHERE remark=?",Long.class,"员工报销 "+claimId)).isZero();
        ExpenseClaimDto paid,retried;
        try(var executor=java.util.concurrent.Executors.newFixedThreadPool(2)) {
            java.util.concurrent.Callable<ExpenseClaimDto> payAction=()->{
                login(cashier,"expense:pay");
                try{return claims.payVersioned(claimId,pay);}finally{SecurityContextHolder.clearContext();}
            };
            var first=executor.submit(payAction);var second=executor.submit(payAction);
            paid=first.get(30,java.util.concurrent.TimeUnit.SECONDS);
            retried=second.get(30,java.util.concurrent.TimeUnit.SECONDS);
        }
        assertThat(retried.financeExpenseId()).isEqualTo(paid.financeExpenseId());
        assertThat(paid.status()).isEqualTo("PAID");
        assertThat(jdbc.queryForObject("SELECT balance_current FROM accounts WHERE id=?",BigDecimal.class,account))
            .isEqualByComparingTo("900.00");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM finance_reconciliations WHERE source_doc_id=?",Long.class,paid.financeExpenseId())).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT sum(direction*amount) FROM gl_entries WHERE source_doc_id=? AND NOT is_deleted",BigDecimal.class,paid.financeExpenseId())).isEqualByComparingTo("0");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM gl_entries WHERE source_doc_id=? AND NOT is_deleted",Long.class,paid.financeExpenseId())).isEqualTo(2);
        assertThatThrownBy(()->expenses.reverse(paid.financeExpenseId())).isInstanceOf(ApiException.class).hasMessageContaining("报销单");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM expense_claim_events WHERE claim_id=? AND event_type='PAID'",Long.class,claimId)).isEqualTo(1);
        assertThat(claims.listHistory(null,null,null,null,1,20).getItems()).extracting(ExpenseClaimDto::id).contains(claimId);
        assertThat(claims.facets("history").categories()).isNotEmpty();
        assertThat(claims.summary().monthPaidAmount()).isGreaterThanOrEqualTo(new BigDecimal("100"));
        login(reviewer,"expense:approve");
        assertThat(claims.listHistory(null,null,null,null,1,20).getItems()).extracting(ExpenseClaimDto::id).contains(claimId);
        login(actor("unrelated-reviewer"),"expense:approve");
        assertThat(claims.listHistory(null,null,null,null,1,20).getItems()).extracting(ExpenseClaimDto::id).doesNotContain(claimId);
        assertThatThrownBy(()->claims.detail(claimId)).isInstanceOf(ApiException.class);
    }

    @Test void duplicateInvoicePrecheckHandlesNullExclusionAndOtherClaimsAndSettingsAreScoped() {
        Actor applicant=actor("duplicate");login(applicant,"expense:apply");
        var one=claims.create(request("原始票据",null));var two=claims.create(request("另一份申请",null));
        var input=new ExpenseClaimInvoiceInput("OTHER",null,"RAIL/2026-ABC",BusinessTime.today(),"测试交通单位",null,null,
            null,null,new BigDecimal("100"),null,null,one.version(),null);
        claims.addInvoiceVersioned(one.id(),input);
        assertThat(claims.checkInvoiceDuplicate("RAIL/2026-ABC",null,null,"OTHER","测试交通单位").duplicated()).isTrue();
        assertThat(claims.checkInvoiceDuplicate("RAIL/2026-ABC",null,null,"OTHER","测试交通单位").heldByApplicantName()).isNull();
        assertThatThrownBy(()->claims.addInvoiceVersioned(two.id(),new ExpenseClaimInvoiceInput("OTHER",null,"RAIL/2026-ABC",
            BusinessTime.today(),"测试交通单位",null,null,null,null,new BigDecimal("100"),null,null,two.version(),null)))
            .isInstanceOf(ApiException.class).hasMessageContaining("不能重复报销");
        var configured=settings.get();
        assertThatThrownBy(()->settings.update(new ExpenseClaimSettingsDto("测试公司",null,null,false,configured.version())))
            .isInstanceOf(ApiException.class);
        login(applicant,"expense:settings");
        var updated=settings.update(new ExpenseClaimSettingsDto("测试公司",null,"请上传原件",false,configured.version()));
        assertThat(updated.version()).isEqualTo(configured.version()+1);
        assertThatThrownBy(()->settings.update(new ExpenseClaimSettingsDto("另一家公司",null,null,false,configured.version()))).isInstanceOf(ApiException.class).hasMessageContaining("已更新");
    }

    private ExpenseClaimCreateRequest request(String title,Long version) {
        return new ExpenseClaimCreateRequest(title,"客户拜访的真实住宿费",List.of(new ExpenseClaimItemInput(
            "TRAVEL",new BigDecimal("100.00"),BusinessTime.today(),"客户拜访住宿一晚")),version);
    }
    private UUID attachment(UUID claim) {return attachment(claim,"EXPENSE_CLAIM");}
    private UUID attachment(UUID claim,String ownerType) {
        UUID id=UUID.randomUUID();jdbc.update("""
            INSERT INTO attachments(id,owner_type,owner_id,storage_key,original_name,content_type,size_bytes,sha256,
                storage_provider,lifecycle_state,scan_engine,scanned_at,promoted_at)
            VALUES(?,?,?,?,'测试原件.pdf','application/pdf',100,?,'local','CLEAN','fixture',now(),now())
            """,id,ownerType,claim,id+".pdf","a".repeat(64));return id;
    }
    private UUID account() {return account(true);}
    private UUID account(boolean base) {
        var currencyIds=jdbc.queryForList("SELECT id FROM currencies WHERE is_base_currency=? AND status='使用' AND NOT is_deleted",UUID.class,base);
        if(currencyIds.isEmpty() && !base) jdbc.update("INSERT INTO currencies(id,code,name,exchange_rate,status) VALUES(?,?,'报销外币拒绝测试',7,'使用')",UUID.randomUUID(),"EXP-FX-"+UUID.randomUUID());
        UUID currency=jdbc.queryForObject("SELECT id FROM currencies WHERE is_base_currency=? AND status='使用' AND NOT is_deleted LIMIT 1",UUID.class,base);
        var bankStyles=jdbc.queryForList("SELECT id FROM payment_styles WHERE path='/102/' AND category='ACCOUNT' AND NOT is_deleted",UUID.class);
        if(bankStyles.isEmpty()) jdbc.update("INSERT INTO payment_styles(id,code,name,category,status) VALUES(?,'102','银行存款','ACCOUNT','使用')",UUID.randomUUID());
        UUID accountStyle=jdbc.queryForObject("SELECT id FROM payment_styles WHERE path='/102/' AND category='ACCOUNT' AND NOT is_deleted LIMIT 1",UUID.class);
        UUID id=UUID.randomUUID();jdbc.update("""
            INSERT INTO accounts(id,code,name,account_type,currency_id,init_balance,receipts_total,payments_total,balance_current,status,style_id)
            VALUES(?,?,'报销链测试账户','BANK',?,1000,0,0,1000,'使用',?)
            """,id,"EXP-"+id,currency,accountStyle);return id;
    }
    private UUID expenseStyle(){UUID id=UUID.randomUUID();jdbc.update("INSERT INTO payment_styles(id,code,name,category,status) VALUES(?,?,'报销测试费用','EXPENSE','使用')",id,"EXP-"+id);return id;}
    private Actor actor(String label) {
        UUID employee=UUID.randomUUID(),user=UUID.randomUUID();String login="expense-"+label+"-"+user;
        UUID department=jdbc.queryForObject("SELECT id FROM departments WHERE code='DEPT_FIN'",UUID.class);
        jdbc.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')",employee,"E-"+employee,label,department);
        jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status) VALUES(?,?,?,'test-not-used',false,false,'active')",user,employee,login);
        return new Actor(user,employee,login);
    }
    private void login(Actor actor,String... permissions){var user=new AuthUser(actor.user(),actor.employee(),actor.login(),Set.of(permissions),false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,"",user.getAuthorities()));}
    record Actor(UUID user,UUID employee,String login) {}
}
