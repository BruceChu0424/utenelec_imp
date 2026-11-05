package com.uten.imp.businesschain;

import com.uten.imp.testsupport.FixtureDatabaseProperties;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.math.BigDecimal;
import java.util.Map;
import java.util.List;
import java.util.UUID;
import com.uten.imp.testsupport.TestFlyway;
import com.uten.imp.testsupport.HistoricalJdbcNativeSql;
import com.uten.imp.features.expenseclaim.HistoricalExpenseSourceJdbc;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.boot.webmvc.test.autoconfigure.MockMvcPrint;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.*;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.*;
import static com.uten.imp.testsupport.BusinessHttpRequests.authenticated;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.transaction.PlatformTransactionManager;

/** Real pre-upgrade originals continue through current native HTTP APIs. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
@TestExecutionListeners(listeners=FinanceApplicationContinuationEndToEndTest.Cleanup.class,mergeMode=TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
@SpringBootTest(properties={"spring.profiles.active=dev",
        "uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.inventory.value-work.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only", // gitleaks:allow synthetic fixture.
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", // gitleaks:allow synthetic fixture.
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class FinanceApplicationContinuationEndToEndTest {
    private static final String MIGRATIONS=snapshotMigrations();
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    private static Originals original;
    private record Originals(FullChainEndToEndTest.World world,List<Actor> reviewers,UUID active,UUID draft,UUID activeReview,
            UUID knownZero,UUID missingCurrencyZero,UUID claim,UUID expenseApp,UUID oldClaim,UUID oldExpenseApp,
            UUID attachment,String originalItems,String originalInvoices,String oldHeader) { }
    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder(){return new DirtiesContextTestExecutionListener().getOrder()-1;}
        @Override public void afterTestClass(TestContext ignored){PG.stop();}
    }
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry)throws Exception {
        PG.start();
        var source=new org.springframework.jdbc.datasource.DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        TestFlyway.configure().dataSource(source).locations(MIGRATIONS).target("1039").load().migrate();
        var fixture=new FinanceApplicationContinuationEndToEndTest();fixture.db=new JdbcTemplate(source);
        fixture.json=com.uten.imp.config.Jackson2ObjectMapperAutoConfiguration.domainObjectMapper();
        fixture.transactions=new org.springframework.jdbc.datasource.DataSourceTransactionManager(source);
        fixture.numbers=new com.uten.imp.common.docnumber.DocNumberService(HistoricalJdbcNativeSql.statements(fixture.db));
        var worldFixture=new FullChainEndToEndTest();ReflectionTestUtils.setField(worldFixture,"jdbc",fixture.db);
        var world=worldFixture.seedWorld("application-continuation");
        UUID owner=fixture.db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,world.superAdminUserId());
        fixture.reviewers=fixture.seedReviewers(world.departmentId(),world.superAdminUserId());
        fixture.db.update("UPDATE departments SET manager_id=? WHERE id=?",fixture.reviewers.getFirst().employee(),world.departmentId());
        UUID active=fixture.seedTravel(owner,world.superAdminUserId(),true),draft=fixture.seedTravel(owner,world.superAdminUserId(),false);
        UUID activeReview=fixture.seedTravel(owner,world.superAdminUserId(),true);
        UUID knownZero=fixture.seedTravel(owner,world.superAdminUserId(),false),missingCurrencyZero=fixture.seedTravel(owner,world.superAdminUserId(),false);
        fixture.db.update("UPDATE finance_applications SET amount_original=0,currency_id=? WHERE id=?",world.currencyId(),knownZero);
        fixture.db.update("UPDATE finance_applications SET amount_original=0,currency_id=NULL WHERE id=?",missingCurrencyZero);
        UUID claim=fixture.seedExpense(owner,world.departmentId());
        UUID expenseApp=fixture.seedExpenseApplication(claim,owner,world.superAdminUserId(),world.departmentId());
        UUID oldClaim=fixture.seedExpense(owner,world.departmentId());
        UUID oldExpenseApp=fixture.seedActiveExpenseApplication(oldClaim,owner,world.superAdminUserId(),world.departmentId());
        String originalItems=fixture.db.queryForObject("SELECT jsonb_agg(to_jsonb(item) ORDER BY id)::text FROM expense_claim_items item WHERE claim_id=?",String.class,claim);
        String originalInvoices=fixture.db.queryForObject("SELECT jsonb_agg(to_jsonb(invoice) ORDER BY id)::text FROM expense_claim_invoices invoice WHERE claim_id=?",String.class,claim);
        UUID attachment=fixture.proof(draft,"FINANCE_APPLICATION");
        String oldHeader=fixture.db.queryForObject("SELECT to_jsonb(app)::text FROM finance_applications app WHERE id=?",String.class,draft);
        TestFlyway.configure().dataSource(source).locations(MIGRATIONS).target("1040").load().migrate();
        assertThat(fixture.db.queryForObject("SELECT to_jsonb(app)::text FROM finance_applications app WHERE id=?",String.class,draft)).isEqualTo(oldHeader);
        TestFlyway.configure().dataSource(source).locations(MIGRATIONS).load().migrate();
        original=new Originals(world,fixture.reviewers,active,draft,activeReview,knownZero,missingCurrencyZero,claim,expenseApp,oldClaim,
                oldExpenseApp,attachment,originalItems,originalInvoices,oldHeader);
        FixtureDatabaseProperties.bindSameRole(registry,PG::getJdbcUrl,PG::getUsername,PG::getPassword);
        registry.add("spring.flyway.locations",()->MIGRATIONS);
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MockMvc http;
    @Autowired ObjectMapper json;
    @Autowired PlatformTransactionManager transactions;
    @Autowired com.uten.imp.common.docnumber.DocNumberService numbers;
    @Autowired com.uten.imp.features.finance.application.FinanceApplicationService originals;
    @Autowired com.uten.imp.features.finance.application.FinanceApplicationLegacyPolicy legacy;
    @Autowired com.uten.imp.features.finance.application.FinanceApplicationOriginalEvidence originalEvidence;
    @Autowired com.uten.imp.features.expenseclaim.ExpenseClaimService claims;
    @Autowired com.uten.imp.application.port.AttachmentEvidencePort evidence;
    @Autowired com.uten.imp.application.port.NativeApplicationOriginPort origins;
    @Autowired com.uten.imp.features.common.taskclaim.TaskClaimService tasks;
    private List<Actor> reviewers=List.of();
    @AfterEach void logout(){SecurityContextHolder.clearContext();}
    @Test void actualUpgradeFencesNewOldWorkflowAndReviewsOriginalsWithoutCashOrGl()throws Exception {
        var harness=new FullChainEndToEndTest();beans.autowireBean(harness);var world=original.world();harness.loginAs(world.superAdminUserId());
        reviewers=original.reviewers();
        UUID active=original.active(),draft=original.draft(),activeReview=original.activeReview();
        UUID knownZero=original.knownZero(),missingCurrencyZero=original.missingCurrencyZero();
        UUID claim=original.claim(),expenseApp=original.expenseApp(),oldClaim=original.oldClaim(),oldExpenseApp=original.oldExpenseApp();
        UUID attachment=original.attachment();String originalItems=original.originalItems(),originalInvoices=original.originalInvoices(),oldHeader=original.oldHeader();
        assertThat(legacy.allowed(active)).isTrue();assertThat(legacy.allowed(draft)).isFalse();
        var auth=SecurityContextHolder.getContext().getAuthentication();
        // A newly arrived old SAVE cannot allocate a second approval tree.
        UUID local=UUID.randomUUID(),oldRequest=UUID.randomUUID();
        var localBody=new java.util.LinkedHashMap<String,Object>();localBody.put("id",local);localBody.put("requestId",oldRequest);localBody.put("expectedVersion",-1);localBody.put("kind","TRAVEL_APPLICATION");localBody.put("title","本机原出差稿");localBody.put("requestedDate",com.uten.imp.common.time.BusinessTime.today().toString());localBody.put("destination","匿名原地点");localBody.put("travelStart","2026-11-01");localBody.put("travelEnd","2026-11-02");localBody.put("travelPurpose","保留完整原出差目的");
        String raw=json.writeValueAsString(localBody);
        var blocked=postJson("/api/finance/applications",localBody,auth);assertThat(blocked.status).isEqualTo(409);
        assertThat(db.queryForObject("SELECT count(*) FROM finance_applications WHERE id=?",Integer.class,local)).isZero();
        // Existing approved round may withdraw, but never gains another old round.
        harness.loginAs(world.superAdminUserId());
        var shown=originals.detail(active);var withdrawn=originals.withdraw(active,new com.uten.imp.features.finance.application.FinanceApplicationContracts.Action(UUID.randomUUID(),0,shown.get("source_fingerprint").toString(),null,null));
        assertThat(withdrawn.get("status")).isEqualTo("DRAFT");assertThat(legacy.allowed(active)).isFalse();
        assertThatThrownBy(()->originals.submit(active,new com.uten.imp.features.finance.application.FinanceApplicationContracts.Action(UUID.randomUUID(),1,shown.get("source_fingerprint").toString(),null,null))).isInstanceOfSatisfying(com.uten.imp.common.web.ApiException.class,error->assertThat(error.getCode()).isEqualTo(com.uten.imp.common.web.ErrorCode.CONFLICT));
        assertThatThrownBy(()->db.update("INSERT INTO finance_application_nodes(application_id,submission_round,step_no,role_key,label_snapshot,action,assignees) VALUES(?,2,1,'DEPARTMENT_REVIEW','非法新旧轮','APPROVE','[]')",active)).hasMessageContaining("当前流程");
        // Read and confirm the captured source, reusing source bytes/owner/hash.
        var reviewed=postJson("/api/finance/applications/continuation/review",Map.of("originId",draft,"expectedVersion",0,"fields",Map.of()),auth);
        assertThat(reviewed.status).as(reviewed.body.toString()).isEqualTo(200);
        var confirm=Map.of("requestId",UUID.randomUUID(),"reviewId",reviewed.body.get("reviewId"),"reviewedFingerprint",reviewed.body.get("reviewedFingerprint"));
        var continued=postJson("/api/finance/applications/continuation/confirm",confirm,auth);assertThat(continued.status).as(continued.body.toString()).isEqualTo(200);
        UUID nativeId=UUID.fromString(continued.body.get("id").toString());
        assertThat(db.queryForObject("SELECT amount IS NULL FROM business_applications WHERE id=?",Boolean.class,nativeId)).isTrue();
        assertThat(db.queryForObject("SELECT kind||':'||status FROM business_applications WHERE id=?",String.class,nativeId)).isEqualTo("TRAVEL:DRAFT");
        assertThat(db.queryForObject("SELECT to_jsonb(app)::text FROM finance_applications app WHERE id=?",String.class,draft)).isEqualTo(oldHeader);
        assertThat(originalEvidence.linkedEvidence("BUSINESS_APPLICATION",nativeId)).hasSize(1);
        assertThat(originalEvidence.linkedEvidence("BUSINESS_APPLICATION",nativeId).getFirst().id()).isEqualTo(attachment);
        assertThat(evidence.frozenEvidenceReady(originalEvidence.linkedEvidence("BUSINESS_APPLICATION",nativeId))).isTrue();
        assertThat(originalEvidence.readableOriginal(attachment,(com.uten.imp.security.AuthUser)auth.getPrincipal())).isPresent();
        assertThat(originalEvidence.immutableOriginal(attachment)).isTrue();
        var sourceView=getJson("/api/business-applications/"+nativeId+"/original-source",auth);
        assertThat(sourceView.status).isEqualTo(200);assertThat(sourceView.body.get("readOnly")).isEqualTo(true);
        assertThat(sourceView.body.get("originalEvidenceState")).isEqualTo("AVAILABLE");
        assertThat(((Map<?,?>)sourceView.body.get("original")).get("title")).isEqualTo("匿名原出差申请");
        var linkedView=getJson("/api/attachments/linked?ownerType=BUSINESS_APPLICATION&ownerId="+nativeId,auth);
        assertThat(linkedView.status).isEqualTo(200);
        assertThat(linkedView.body.get("data")).asInstanceOf(org.assertj.core.api.InstanceOfAssertFactories.list(Map.class)).hasSize(1);
        var linkedFile=(Map<?,?>)((List<?>)linkedView.body.get("data")).getFirst();
        assertThat(linkedFile.get("id")).isEqualTo(attachment.toString());
        assertThat(linkedFile.get("ownerId")).isEqualTo(draft.toString());
        assertThat(linkedFile.get("historyReadOnly")).isEqualTo(true);
        var again=postJson("/api/finance/applications/continuation/confirm",confirm,auth);assertThat(again.status).isEqualTo(200);assertThat(again.body.get("id")).isEqualTo(nativeId.toString());
        assertThat(db.queryForObject("SELECT count(*) FROM business_applications WHERE id=?",Integer.class,nativeId)).isEqualTo(1);
        assertThatThrownBy(()->db.update("UPDATE finance_applications SET title='不能覆盖原稿' WHERE id=?",draft)).hasMessageContaining("只读");
        assertThatThrownBy(()->db.update("UPDATE business_applications SET amount=0 WHERE id=?",nativeId)).hasMessageContaining("未知金额");
        // Deleting or changing any one frozen reference prevents a later submit.
        assertThatThrownBy(()->db.update("UPDATE attachments SET sha256=? WHERE id=?","b".repeat(64),attachment)).hasMessageContaining("immutable");
        db.update("UPDATE attachments SET lifecycle_state='DELETE_FAILED',delete_requested_at=now() WHERE id=?",attachment);
        assertThatThrownBy(()->origins.requireReady("BUSINESS_APPLICATION",nativeId)).hasMessageContaining("凭证已变化");
        assertThat(getJson("/api/business-applications/"+nativeId+"/original-source",auth).body.get("originalEvidenceState")).isEqualTo("UNAVAILABLE");
        // An unsent local body has an explicit reviewed route, retaining its exact JSON.
        var localReview=postJson("/api/finance/applications/continuation/review",Map.of("originId",local,"originalRequestId",oldRequest,"originalCommand",raw,"expectedVersion",-1,"fields",Map.of()),auth);
        assertThat(localReview.status).as(localReview.body.toString()).isEqualTo(200);
        var localContinue=postJson("/api/finance/applications/continuation/confirm",Map.of("requestId",UUID.randomUUID(),"reviewId",localReview.body.get("reviewId"),"reviewedFingerprint",localReview.body.get("reviewedFingerprint")),auth);
        assertThat(localContinue.status).as(localContinue.body.toString()).isEqualTo(200);
        assertThat(db.queryForObject("SELECT original_command FROM finance_application_continuation_reviews WHERE id=?",String.class,UUID.fromString(localReview.body.get("reviewId").toString()))).isEqualTo(raw);
        assertThat(db.queryForObject("SELECT count(*) FROM finance_applications WHERE id=?",Integer.class,local)).isZero();
        // Ordinary current travel preserves unknown and explicit zero separately.
        var nativeFields=Map.of("reason","匿名当前事由","destination","匿名地点","startDate","2026-11-01","endDate","2026-11-02");
        var blankInput=new java.util.LinkedHashMap<String,Object>();blankInput.put("id",UUID.randomUUID());blankInput.put("kind","TRAVEL");blankInput.put("title","匿名无金额出差");blankInput.put("fields",nativeFields);
        var blank=postJson("/api/business-applications",blankInput,auth);assertThat(blank.status).as(blank.body.toString()).isEqualTo(200);assertThat(blank.body.get("amount")).isNull();
        blankInput.put("id",UUID.randomUUID());blankInput.put("amount","0");var zero=postJson("/api/business-applications",blankInput,auth);assertThat(zero.status).as(zero.body.toString()).isEqualTo(200);assertThat(zero.body.get("amount")).isEqualTo("0");
        assertThat(db.queryForObject("SELECT count(*) FROM finance_application_executions",Integer.class)).isZero();
        // A real old claim continues as the same native claim, never a second claim.
        harness.loginAs(world.superAdminUserId());
        assertThatThrownBy(()->claims.submit(claim)).hasMessageContaining("审阅");
        var claimReview=postJson("/api/finance/applications/continuation/review",Map.of("originId",expenseApp,"expectedVersion",0,"fields",Map.of()),auth);
        assertThat(claimReview.status).as(claimReview.body.toString()).isEqualTo(200);
        var claimContinued=postJson("/api/finance/applications/continuation/confirm",Map.of("requestId",UUID.randomUUID(),"reviewId",claimReview.body.get("reviewId"),"reviewedFingerprint",claimReview.body.get("reviewedFingerprint")),auth);
        assertThat(claimContinued.status).as(claimContinued.body.toString()).isEqualTo(200);assertThat(claimContinued.body.get("id")).isEqualTo(claim.toString());
        assertThat(db.queryForObject("SELECT jsonb_agg(to_jsonb(item) ORDER BY id)::text FROM expense_claim_items item WHERE claim_id=?",String.class,claim)).isEqualTo(originalItems);
        assertThat(db.queryForObject("SELECT jsonb_agg(to_jsonb(invoice) ORDER BY id)::text FROM expense_claim_invoices invoice WHERE claim_id=?",String.class,claim)).isEqualTo(originalInvoices);
        assertThat(db.queryForObject("SELECT application_kind FROM expense_claim_source_links WHERE claim_id=?",String.class,claim)).isEqualTo("REIMBURSEMENT");
        var claimSource=getJson("/api/expense-claims/"+claim+"/original-source",auth);
        assertThat(claimSource.status).isEqualTo(200);assertThat(claimSource.body.get("readOnly")).isEqualTo(true);
        assertThat(((Map<?,?>)claimSource.body.get("original")).get("amountOriginal"))
            .isEqualTo(db.queryForObject("SELECT total_amount FROM expense_claims WHERE id=?",BigDecimal.class,claim).toPlainString());
        harness.loginAs(world.superAdminUserId());
        var submittedClaim=claims.submit(claim);
        assertThat(submittedClaim.approvalStage()).isEqualTo("DEPARTMENT");assertThat(submittedClaim.applicationKind()).isEqualTo("REIMBURSEMENT");
        assertThat(db.queryForObject("SELECT count(*) FROM finance_application_nodes WHERE application_id=?",Integer.class,expenseApp)).isZero();
        assertThat(db.queryForObject("SELECT finance_expense_id IS NULL FROM expense_claims WHERE id=?",Boolean.class,claim)).isTrue();
        // The real already captured old round still progresses under its original nodes.
        for(int step=0;step<3;step++){
            harness.loginAs(reviewers.get(step).user());
            var pending=originals.detail(activeReview);var lease=tasks.claim("FINANCE_APPLICATION_REVIEW",activeReview.toString());
            var done=originals.review(activeReview,new com.uten.imp.features.finance.application.FinanceApplicationContracts.Action(UUID.randomUUID(),((Number)pending.get("row_version")).longValue(),pending.get("source_fingerprint").toString(),lease.claimId(),null),true);
            assertThat(done.get("status")).isEqualTo(step==2?"ARCHIVED":"REVIEWING");
        }
        // A real frozen old reimbursement uses its original finance invoice gate,
        // although its native stage was correctly absent in the old contract.
        for(int step=0;step<4;step++){
            var actor=reviewers.get(step);harness.loginAs(actor.user());
            var pending=originals.detail(oldExpenseApp);var lease=tasks.claim("FINANCE_APPLICATION_REVIEW",oldExpenseApp.toString());
            if(step==1){
                UUID invoice=db.queryForObject("SELECT id FROM expense_claim_invoices WHERE claim_id=?",UUID.class,oldClaim);
                originals.verifyExpenseInvoice(oldExpenseApp,new com.uten.imp.features.finance.application.FinanceApplicationContracts.InvoiceVerification(UUID.randomUUID(),((Number)pending.get("row_version")).longValue(),pending.get("source_fingerprint").toString(),lease.claimId(),invoice,claims.detail(oldClaim).version(),"VERIFIED_MANUAL","匿名原票据渠道、日期与查验依据完整核对"));
            }
            var done=originals.review(oldExpenseApp,new com.uten.imp.features.finance.application.FinanceApplicationContracts.Action(UUID.randomUUID(),((Number)pending.get("row_version")).longValue(),pending.get("source_fingerprint").toString(),lease.claimId(),null),true);
            assertThat(done.get("status")).isEqualTo(step==3?"APPROVED":"REVIEWING");
        }
        assertThat(db.queryForObject("SELECT status FROM expense_claims WHERE id=?",String.class,oldClaim)).isEqualTo("APPROVED");
        for(int index=0;index<4;index++){
            harness.loginAs(reviewers.get(index).user());var approved=originals.detail(oldExpenseApp);
            var command=new com.uten.imp.features.finance.application.FinanceApplicationContracts.Execute(UUID.randomUUID(),((Number)approved.get("row_version")).longValue(),approved.get("source_fingerprint").toString(),null,null,null,null,null,null,null,null,null,null);
            assertThatThrownBy(()->originals.execute(oldExpenseApp,command)).isInstanceOfSatisfying(com.uten.imp.common.web.ApiException.class,error->assertThat(error.getCode()).isEqualTo(com.uten.imp.common.web.ErrorCode.FORBIDDEN));
        }
        harness.loginAs(reviewers.get(4).user());
        var approved=originals.detail(oldExpenseApp);var unfilled=new com.uten.imp.features.finance.application.FinanceApplicationContracts.Execute(UUID.randomUUID(),((Number)approved.get("row_version")).longValue(),approved.get("source_fingerprint").toString(),null,null,null,null,null,null,null,null,null,null);
        assertThatThrownBy(()->originals.execute(oldExpenseApp,unfilled)).hasMessageContaining("实际付款账户");
        assertThat(db.queryForObject("SELECT count(*) FROM finance_application_executions",Integer.class)).isZero();
        // Stored zero stays zero; a missing currency is completed explicitly,
        // recorded separately, and never written back into the original header.
        var incomplete=postJson("/api/finance/applications/continuation/review",Map.of("originId",missingCurrencyZero,"expectedVersion",0,"fields",Map.of()),auth);
        assertThat(incomplete.status).isEqualTo(409);
        for(UUID zeroOrigin:List.of(knownZero,missingCurrencyZero)){
            var input=new java.util.LinkedHashMap<String,Object>();input.put("originId",zeroOrigin);input.put("expectedVersion",0);input.put("fields",Map.of());
            if(zeroOrigin.equals(missingCurrencyZero))input.put("reviewedCurrencyId",world.currencyId());
            var zeroReview=postJson("/api/finance/applications/continuation/review",input,auth);assertThat(zeroReview.status).as(zeroReview.body.toString()).isEqualTo(200);
            var zeroDone=postJson("/api/finance/applications/continuation/confirm",Map.of("requestId",UUID.randomUUID(),"reviewId",zeroReview.body.get("reviewId"),"reviewedFingerprint",zeroReview.body.get("reviewedFingerprint")),auth);
            assertThat(zeroDone.status).as(zeroDone.body.toString()).isEqualTo(200);
            assertThat(db.queryForObject("SELECT amount FROM business_applications WHERE id=?",BigDecimal.class,UUID.fromString(zeroDone.body.get("id").toString()))).isZero();
        }
        assertThat(db.queryForObject("SELECT currency_id IS NULL AND amount_original=0 FROM finance_applications WHERE id=?",Boolean.class,missingCurrencyZero)).isTrue();
        assertThat(db.queryForObject("SELECT review.original_snapshot->>'currencyEvidence' FROM finance_application_native_mappings mapping JOIN finance_application_continuation_reviews review ON review.id=mapping.review_id WHERE mapping.origin_id=?",String.class,missingCurrencyZero)).isEqualTo("REVIEW_COMPLETION");
        assertThat(db.queryForObject("SELECT count(*) FROM finance_application_native_mappings",Integer.class)).isEqualTo(5);
    }
    private UUID seedTravel(UUID owner,UUID user,boolean active)throws Exception {
        UUID id=UUID.randomUUID(),department=db.queryForObject("SELECT department_id FROM employees WHERE id=?",UUID.class,owner);
        var payload=new java.util.LinkedHashMap<String,Object>();payload.put("title","匿名原出差申请");payload.put("remark","原始说明");payload.put("requestedDate",com.uten.imp.common.time.BusinessTime.today().toString());payload.put("destination","匿名原地点");payload.put("travelStart","2026-11-01");payload.put("travelEnd","2026-11-02");payload.put("travelPurpose","完整原出差事由");
        db.update("INSERT INTO finance_applications(id,application_no,kind,source_kind,applicant_id,applicant_name_snapshot,department_id,title,requested_date,requested_payload,request_fingerprint,created_by,updated_by) VALUES(?,?,'TRAVEL_APPLICATION','TRAVEL_PLAN',?,'匿名原申请人',?,'匿名原出差申请',CURRENT_DATE,?::jsonb,?,?,?)",id,numbers.nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.FIN_APPLICATION),owner,department,json.writeValueAsString(payload),"c".repeat(64),user,user);
        if(active){
            String source=db.queryForObject("SELECT requested_payload::text FROM finance_applications WHERE id=?",String.class,id);
            String fingerprint=com.uten.imp.common.storage.ImmutableDocumentStore.digest(json.writeValueAsBytes(json.readValue(source,new com.fasterxml.jackson.core.type.TypeReference<java.util.LinkedHashMap<String,Object>>(){})));
            db.update("UPDATE finance_applications SET status='SUBMITTED',submission_round=1,current_step=1,source_snapshot=requested_payload,source_fingerprint=? WHERE id=?",fingerprint,id);
            int step=0;for(var role:List.of("DEPARTMENT_REVIEW","TRAVEL_APPROVAL","FINANCE_CUSTODY"))db.update("INSERT INTO finance_application_nodes(application_id,submission_round,step_no,role_key,label_snapshot,action,assignees) VALUES(?,1,?,?,?,?,?::jsonb)",id,++step,role,"匿名原节点",role.equals("FINANCE_CUSTODY")?"ARCHIVE":"APPROVE",json.writeValueAsString(List.of(Map.of("employeeId",reviewers.get(step-1).employee(),"userId",reviewers.get(step-1).user(),"name","匿名节点指派"))));
        }return id;
    }
    private record Actor(UUID user,UUID employee) { }
    private List<Actor> seedReviewers(UUID department,UUID administrator){
        var result=new java.util.ArrayList<Actor>();
        var permissions=List.of("finance_application:view","finance_application:review","finance_application:execute","expense:approve:department","expense:approve:finance_initial","expense:approve:finance_review","expense:approve:executive","expense:pay","attachment:view","attachment:download","attachment:upload");
        for(int index=0;index<5;index++){
            UUID employee=UUID.randomUUID(),user=UUID.randomUUID();
            db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,CURRENT_DATE,'active','regular')",employee,"CONT-"+employee.toString().toUpperCase(java.util.Locale.ROOT),"匿名接续审阅人员"+index,department);
            db.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status) VALUES(?,?,?,'not-used',false,false,'active')",user,employee,"cont-"+user);
            new TransactionTemplate(transactions).executeWithoutResult(status->{db.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,administrator.toString());for(var code:permissions)db.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'grant' FROM permissions WHERE code=?",user,code);});
            result.add(new Actor(user,employee));
        }return List.copyOf(result);
    }
    private UUID seedExpense(UUID owner,UUID department){
        UUID id=UUID.randomUUID();String full="100.123456789012345678901234";
        db.update("INSERT INTO expense_claims(id,claim_no,applicant_id,applicant_name_snapshot,applicant_department_id,title,total_amount,status,remark) VALUES(?,?,?,'匿名原报销人',?,'匿名原报销草稿',?,'DRAFT','按原票据申请，不改原金额')",id,numbers.nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.EXPENSE_CLAIM),owner,department,new BigDecimal(full));
        db.update("INSERT INTO expense_claim_items(id,claim_id,line_no,category,amount,expense_date,description) VALUES(?,?,1,'TRAVEL',?,DATE '2026-11-01','匿名原住宿费')",UUID.randomUUID(),id,new BigDecimal(full));
        UUID attachment=proof(id,"EXPENSE_CLAIM");
        db.update("INSERT INTO expense_claim_invoices(id,claim_id,line_no,invoice_type,invoice_no,issue_date,seller_name,amount_excl_tax,tax_amount,total_amount,attachment_id) VALUES(?,?,1,'DIGITAL',?,DATE '2026-11-01','匿名原供应方',?,0,?,?)",UUID.randomUUID(),id,"9"+new java.math.BigInteger(id.toString().replace("-",""),16).toString().substring(0,19),new BigDecimal(full),new BigDecimal(full),attachment);
        return id;
    }
    private UUID seedActiveExpenseApplication(UUID claim,UUID owner,UUID user,UUID department){
        db.update("UPDATE expense_claims SET status='SUBMITTED',approval_stage=NULL WHERE id=?",claim);
        var source=HistoricalExpenseSourceJdbc.source(db,json,claim);
        UUID app=seedExpenseApplication(claim,owner,user,department);
        db.update("UPDATE finance_applications SET status='SUBMITTED',submission_round=1,current_step=1,source_snapshot=?::jsonb,source_fingerprint=?,amount_original=?,currency_id=? WHERE id=?",encode(source.facts()),source.fingerprint(),source.amount(),source.currencyId(),app);
        int step=0;for(String role:List.of("DEPARTMENT_REVIEW","FINANCE_REVIEW_1","FINANCE_REVIEW_2","MANAGEMENT_PAYMENT")){
            var actor=reviewers.get(step++);
            db.update("INSERT INTO finance_application_nodes(application_id,submission_round,step_no,role_key,label_snapshot,action,assignees) VALUES(?,1,?,?,?,'APPROVE',?::jsonb)",app,step,role,"匿名原审批节点",encode(List.of(Map.of("employeeId",actor.employee(),"userId",actor.user(),"name","匿名原审核人"))));
        }return app;
    }
    private String encode(Object value){try{return json.writeValueAsString(value);}catch(Exception error){throw new IllegalStateException(error);}}
    private UUID seedExpenseApplication(UUID source,UUID owner,UUID user,UUID department){
        UUID id=UUID.randomUUID();
        db.update("INSERT INTO finance_applications(id,application_no,kind,source_kind,source_id,applicant_id,applicant_name_snapshot,department_id,title,requested_date,requested_payload,request_fingerprint,created_by,updated_by) VALUES(?,?,'REIMBURSEMENT','EXPENSE_CLAIM',?,?,'匿名原申请人',?,'匿名原报销申请',CURRENT_DATE,'{}'::jsonb,?,?,?)",id,numbers.nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.FIN_APPLICATION),source,owner,department,"d".repeat(64),user,user);
        db.update("INSERT INTO finance_expense_application_links(claim_id,kind,application_id,created_by) VALUES(?,'REIMBURSEMENT',?,?)",source,id,user);
        proof(id,"FINANCE_APPLICATION");return id;
    }
    private UUID proof(UUID owner,String type){UUID id=UUID.randomUUID();db.update("INSERT INTO attachments(id,owner_type,owner_id,storage_key,original_name,content_type,size_bytes,sha256,storage_provider,lifecycle_state,scan_engine,scanned_at,promoted_at) VALUES(?,?,?,?,'匿名原凭证.pdf','application/pdf',100,?,'local','CLEAN','fixture',now(),now())",id,type,owner,id+".pdf","a".repeat(64));return id;}
    private record Response(int status,Map<String,Object> body) { }
    @SuppressWarnings("unchecked")
    private Response postJson(String path,Object body,org.springframework.security.core.Authentication auth)throws Exception {
        var response=http.perform(post(path).with(authenticated(auth)).contentType("application/json").content(json.writeValueAsBytes(body))).andReturn().getResponse();
        Object decoded=json.readValue(response.getContentAsString(java.nio.charset.StandardCharsets.UTF_8),Object.class);
        Map<String,Object> result=decoded instanceof Map<?,?> value?new java.util.LinkedHashMap<>((Map<String,Object>)value):new java.util.LinkedHashMap<>(Map.of("data",decoded));
        if(result.get("data") instanceof Map<?,?> data)result=new java.util.LinkedHashMap<>((Map<String,Object>)data);
        return new Response(response.getStatus(),result);
    }
    @SuppressWarnings("unchecked")
    private Response getJson(String path,org.springframework.security.core.Authentication auth)throws Exception {
        var response=http.perform(get(path).with(authenticated(auth))).andReturn().getResponse();
        Object decoded=json.readValue(response.getContentAsString(java.nio.charset.StandardCharsets.UTF_8),Object.class);
        Map<String,Object> result=decoded instanceof Map<?,?> value?new java.util.LinkedHashMap<>((Map<String,Object>)value):new java.util.LinkedHashMap<>(Map.of("data",decoded));
        if(result.get("data") instanceof Map<?,?> data)result=new java.util.LinkedHashMap<>((Map<String,Object>)data);
        return new Response(response.getStatus(),result);
    }
    private static String snapshotMigrations() {
        try {
            var source=java.nio.file.Path.of(java.util.Objects.requireNonNull(FinanceApplicationContinuationEndToEndTest.class.getClassLoader().getResource("db/migration")).toURI());
            var target=java.nio.file.Files.createTempDirectory("uten-application-continuation-migrations-").toAbsolutePath().normalize();
            try(var paths=java.nio.file.Files.list(source)) {
                for(var file:paths.filter(path->path.getFileName().toString().endsWith(".sql")).sorted().toList()) {
                    byte[] bytes=java.nio.file.Files.readAllBytes(file);
                    java.nio.file.Files.write(target.resolve(file.getFileName()),bytes);
                    if(!java.util.Arrays.equals(bytes,java.nio.file.Files.readAllBytes(file))) throw new IllegalStateException("Migration source changed while taking the isolated test snapshot");
                }
            }
            return "filesystem:"+target.toString().replace('\\','/');
        } catch(Exception failure) { throw new IllegalStateException("Cannot snapshot the actual live migration source",failure); }
    }

}
