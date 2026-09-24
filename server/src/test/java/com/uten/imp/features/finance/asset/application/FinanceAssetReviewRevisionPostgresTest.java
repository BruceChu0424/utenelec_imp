package com.uten.imp.features.finance.asset.application;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.asset.api.AssetWorkbenchRequests;
import com.uten.imp.features.finance.asset.api.AssetWorkbenchResponses;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.YearMonth;
import java.util.Set;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK, properties={
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.inventory.value-work-initial-delay-ms=3600000",
        "uten.finance.asset.posted-workflows-enabled=true",
        "uten.jwt.secret=asset-review-only-jwt-key-0123456789-0123456789",
        "uten.crypto.pgp-master-key=asset-review-only-pgp-key-0123456789-0123456789",
        "uten.crypto.hmac-key=asset-review-only-hmac-key-0123456789",
        "uten.bootstrap.admin-login=asset-review-harness-admin",
        "uten.bootstrap.admin-password=AssetReviewHarnessAdmin-1!"})
class FinanceAssetReviewRevisionPostgresTest {
    private static final PostgreSQLContainer<?> PG = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("asset_review").withUsername("uten").withPassword("uten");
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        PG.start(); registry.add("spring.datasource.url", PG::getJdbcUrl);
        registry.add("spring.datasource.username", PG::getUsername); registry.add("spring.datasource.password", PG::getPassword);
    }
    @Autowired JdbcTemplate jdbc;
    @Autowired FinanceAssetWorkflowService workflow;
    @Autowired FinanceAssetQueryService queries;
    @Autowired ObjectMapper json;
    @AfterEach void logout() { SecurityContextHolder.clearContext(); }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void rejectionEditsAndResubmissionKeepTheOriginalCommercialFacts(boolean deferred) throws Exception {
        Actor maker = actor("maker"), reviewer = actor("reviewer");
        UUID category = category(deferred);
        String source = "SOURCE-" + UUID.randomUUID();
        login(maker);
        var created = create(deferred, category, maker, source, "原内容", "100.00", null);
        var first = workflow.submit(created.id(), created.version(), deferred);
        assertThatThrownBy(() -> workflow.reject(first.id(), first.version(), "自己不能驳回", deferred))
                .isInstanceOf(ApiException.class);
        var firstDiff = detail(first.id(), deferred).reviewRevisions().getFirst();
        assertThat(firstDiff.resubmission()).isFalse();
        assertThat(firstDiff.previousSnapshot()).isNull();
        login(reviewer);
        var rejected = workflow.reject(first.id(), first.version(), "请修正", deferred);
        login(maker);
        var edited = update(first.id(), deferred, category, maker, source, "中间内容", "80.00", rejected.version());
        var latest = update(first.id(), deferred, category, maker, source, "最新内容", "120.00", edited.version());
        assertThatThrownBy(() -> workflow.submit(first.id(), edited.version(), deferred)).isInstanceOf(ApiException.class);
        var submitted = workflow.submit(first.id(), latest.version(), deferred);
        var revision = detail(first.id(), deferred).reviewRevisions().getFirst();
        assertThat(revision.resubmission()).isTrue();
        assertThat(json.readTree(revision.previousSnapshot())).isEqualTo(json.readTree(firstDiff.submissionSnapshot()));
        assertThat(json.readTree(revision.previousSnapshot()).path("name").asText()).isEqualTo("原内容");
        assertThat(json.readTree(revision.submissionSnapshot()).path("name").asText()).isEqualTo("最新内容");
        assertThat(new BigDecimal(json.readTree(revision.submissionSnapshot())
                .path(deferred ? "totalAmount" : "originalValue").asText())).isEqualByComparingTo("120.00");
        assertThat(json.readTree(revision.submissionSnapshot()).has("rowVersion")).isFalse();
        assertThat(json.readTree(revision.submissionSnapshot()).has("netBookValue")).isFalse();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM finance_asset_events WHERE object_id=? AND event_type='SUBMITTED'",Long.class,first.id()))
                .isEqualTo(2);
        assertThatThrownBy(() -> jdbc.update("UPDATE finance_asset_events SET payload='{}'::jsonb WHERE object_id=?", first.id()))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThat(submitted.status()).isEqualTo("PENDING_APPROVAL");

        // A later business event from an older writer has no revision metadata.
        // Its absent snapshot must stay the latest unavailable submission, not
        // be sorted before older complete snapshots simply because metadata is missing.
        jdbc.update("""
                INSERT INTO finance_asset_events(object_type,object_id,event_type,title,payload,actor_user_id,occurred_at)
                VALUES(?,?,'SUBMITTED','Legacy writer submission','{}'::jsonb,?,clock_timestamp())
                """,deferred ? "DEFERRED_EXPENSE" : "FIXED_ASSET",first.id(),maker.user());
        var legacyLatest = detail(first.id(),deferred).reviewRevisions().getFirst();
        assertThat(legacyLatest.submissionSnapshot()).isNull();
        assertThat(json.readTree(legacyLatest.previousSnapshot())).isEqualTo(json.readTree(revision.submissionSnapshot()));
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void disposalAndTerminationResubmissionsStaySeparateFromRecognition(boolean deferred) throws Exception {
        Actor maker = actor("disposal-maker"), reviewer = actor("disposal-reviewer");
        UUID category = category(deferred);
        String source = "SOURCE-" + UUID.randomUUID();
        login(maker);
        var created = create(deferred, category, maker, source, "已确认卡片", "100.00", null);
        var submitted = workflow.submit(created.id(), created.version(), deferred);
        login(reviewer);
        var approved = workflow.approve(created.id(), submitted.version(), "核对", deferred);
        // Activation is an explicit fixture here: this test exercises repeated
        // request/return/read facts, not GL activation or depreciation acceptance.
        jdbc.update("UPDATE " + (deferred ? "deferred_expenses SET recognized_on" : "fixed_assets SET capitalized_on")
                + "=?, lifecycle_status='ACTIVE' WHERE id=?",BusinessTime.today(),created.id());
        login(maker);
        var first = deferred ? workflow.requestTermination(created.id(), new AssetWorkbenchRequests.TerminationCommand(
                approved.version(), "原原因",BusinessTime.today(),"凭证一"))
                : workflow.requestDisposal(created.id(), new AssetWorkbenchRequests.DisposalCommand(
                approved.version(),"原原因",BusinessTime.today(),new BigDecimal("12.30"),"凭证一"));
        login(reviewer);
        var rejected = deferred ? workflow.rejectTermination(created.id(),new AssetWorkbenchRequests.ReasonCommand(first.version(),"退回"))
                : workflow.rejectDisposal(created.id(),new AssetWorkbenchRequests.ReasonCommand(first.version(),"退回"));
        login(maker);
        if (deferred) workflow.requestTermination(created.id(),new AssetWorkbenchRequests.TerminationCommand(
                rejected.version(),"新原因",BusinessTime.today(),"凭证二"));
        else workflow.requestDisposal(created.id(),new AssetWorkbenchRequests.DisposalCommand(
                rejected.version(),"新原因",BusinessTime.today(),new BigDecimal("22.99"),"凭证二"));
        var revisions = detail(created.id(),deferred).reviewRevisions();
        assertThat(revisions).hasSize(2);
        var recognition = revisions.stream().filter(row -> row.workflowType().equals("RECOGNITION")).findFirst().orElseThrow();
        var request = revisions.stream().filter(row -> !row.workflowType().equals("RECOGNITION")).findFirst().orElseThrow();
        assertThat(recognition.resubmission()).isFalse();
        assertThat(request.workflowType()).isEqualTo(deferred ? "TERMINATION" : "DISPOSAL");
        assertThat(request.resubmission()).isTrue();
        assertThat(json.readTree(request.previousSnapshot()).path("reason").asText()).isEqualTo("原原因");
        assertThat(json.readTree(request.submissionSnapshot()).path("evidenceReference").asText()).isEqualTo("凭证二");
        if (!deferred) assertThat(json.readTree(request.submissionSnapshot()).path("proceedsAmount").asText()).isEqualTo("22.99");
    }

    private AssetWorkbenchResponses.Detail detail(UUID id,boolean deferred) {
        return deferred ? queries.deferredExpense(id) : queries.fixedAsset(id);
    }
    private AssetWorkbenchResponses.WorkflowResult create(boolean deferred,UUID category,Actor maker,String source,String name,String amount,Long version) {
        return deferred ? workflow.createDeferred(deferredDraft(category,maker,source,name,amount,version))
                : workflow.createFixed(fixedDraft(category,maker,source,name,amount,version));
    }
    private AssetWorkbenchResponses.WorkflowResult update(UUID id,boolean deferred,UUID category,Actor maker,String source,String name,String amount,Long version) {
        return deferred ? workflow.updateDeferred(id,deferredDraft(category,maker,source,name,amount,version))
                : workflow.updateFixed(id,fixedDraft(category,maker,source,name,amount,version));
    }
    private AssetWorkbenchRequests.FixedAssetDraft fixedDraft(UUID category,Actor maker,String source,String name,String amount,Long version) {
        var today = BusinessTime.today();
        return new AssetWorkbenchRequests.FixedAssetDraft(null,name,category,maker.department(),maker.employee(),"一楼", "序列",null,"部门成本",
                new BigDecimal(amount),new BigDecimal("0.05"),12,YearMonth.from(today).plusMonths(1).toString(),today,today,today,
                "MANUAL",null,source,"HEADER",today,"资产说明",version);
    }
    private AssetWorkbenchRequests.DeferredExpenseDraft deferredDraft(UUID category,Actor maker,String source,String name,String amount,Long version) {
        var today = BusinessTime.today();
        return new AssetWorkbenchRequests.DeferredExpenseDraft(null,name,category,maker.department(),maker.employee(),"一楼","部门成本",
                new BigDecimal(amount),12,YearMonth.from(today).toString(),today,today.plusMonths(11),"MANUAL",null,source,"HEADER",today,"待摊说明",version);
    }
    private UUID category(boolean deferred) {
        UUID cost=style("ACCOUNT"), accumulated=style("ACCOUNT"), expense=style("EXPENSE"), clearing=style("ACCOUNT"), id=UUID.randomUUID();
        jdbc.update("""
                INSERT INTO finance_asset_categories(id,object_type,code,name,cost_style_id,accumulated_style_id,expense_style_id,clearing_style_id,
                    default_method,default_months,default_salvage_rate,effective_from,status)
                VALUES(?,?,?,'提交对照类别',?,?,?,?,'STRAIGHT_LINE',12,0.05,CURRENT_DATE,'ACTIVE')
                """,id,deferred ? "DEFERRED_EXPENSE" : "FIXED_ASSET","REV-"+id,cost,deferred ? null : accumulated,expense,clearing);
        return id;
    }
    private UUID style(String type) {
        UUID id=UUID.randomUUID();
        jdbc.update("INSERT INTO payment_styles(id,code,name,category,status) VALUES(?,?,'提交对照科目',?,'使用')",id,"AR-"+id,type);
        return id;
    }
    private Actor actor(String label) {
        UUID employee=UUID.randomUUID(),user=UUID.randomUUID();
        UUID department=jdbc.queryForObject("SELECT id FROM departments WHERE code='DEPT_FIN'",UUID.class);
        jdbc.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')",employee,"ARE-"+employee,label,department);
        jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status) VALUES(?,?,?,'test-not-used',false,false,'active')",user,employee,"asset-revision-"+user);
        return new Actor(user,employee,department);
    }
    private void login(Actor actor) {
        var user=new AuthUser(actor.user(),actor.employee(),"asset-review",Set.of("finance_asset:view","finance_asset:edit","finance_asset:approve","finance_asset:dispose"),false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,"",user.getAuthorities()));
    }
    private record Actor(UUID user,UUID employee,UUID department) {}
}
