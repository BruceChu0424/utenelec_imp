package com.uten.imp.features.finance.asset.application;

import com.uten.imp.testsupport.FixtureDatabaseProperties;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.asset.api.AssetWorkbenchRequests;
import com.uten.imp.features.finance.asset.api.AssetWorkbenchResponses;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
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
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.YearMonth;
import java.util.Set;
import java.util.Map;
import java.util.List;
import java.util.LinkedHashMap;
import java.util.function.Function;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK, properties={
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.features.goods-owner-scope-enabled=false",
        "uten.finance.asset.posted-workflows-enabled=true",
        "uten.jwt.secret=asset-review-only-jwt-key-0123456789-0123456789",
        "uten.crypto.pgp-master-key=asset-review-only-pgp-key-0123456789-0123456789",
        "uten.crypto.hmac-key=asset-review-only-hmac-key-0123456789",
        "uten.bootstrap.admin-login=asset-review-harness-admin",
        "uten.bootstrap.admin-password=AssetReviewHarnessAdmin-1!"})
class FinanceAssetReviewRevisionPostgresTest {
    private static final PostgreSQLContainer PG = new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("asset_review").withUsername("fixture_admin").withPassword("uten");
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        PG.start(); FixtureDatabaseProperties.bindSameRole(registry, PG::getJdbcUrl,
                PG::getUsername, PG::getPassword);
    }
    @Autowired JdbcTemplate jdbc;
    @Autowired FinanceAssetWorkflowService workflow;
    @Autowired FinanceAssetPostingService posting;
    @Autowired FinanceAssetQueryService queries;
    @Autowired FinanceAssetRecognitionReversalService recognitionReversals;
    @Autowired com.uten.imp.features.finance.gl.GlReportService financialReports;
    @Autowired com.uten.imp.features.finance.gl.GlReportLineBindingService reportBindings;
    @Autowired com.uten.imp.features.finance.asset.FixedAssetService assetReports;
    @Autowired ObjectMapper json;
    @Autowired com.uten.imp.features.purchase.report.PurchaseReportService purchaseReports;
    @Autowired com.uten.imp.features.subcontract.report.SubcontractReportService subcontractReports;
    @AfterEach void logout() { SecurityContextHolder.clearContext(); }

    /** Reuse this fully migrated application fixture to validate each real SQL projection. */
    @Test
    void everyProcurementReportHeaderExpressionExecutesAgainstTheCurrentPostgresSchema() {
        Actor reader = actor("report-header");
        login(reader, Set.of("purchase_report:price:view", "subcontract_report:price:view",
                "purchase_order:view", "subcontract_order:view", "finance_asset:view"));
        var from = java.time.LocalDate.of(2026, 1, 1);
        var to = java.time.LocalDate.of(2026, 12, 31);
        List<Function<Map<String,String>,com.uten.imp.features.purchase.report.ReportTableResponse>> purchase = List.of(
                f -> purchaseReports.expediting(null,null,from,to,null,f,1,1,null,null),
                f -> purchaseReports.requestDetail(null,null,from,to,null,f,1,1,null,null),
                f -> purchaseReports.requestSummary(null,null,from,to,null,f,1,1,null,null),
                f -> purchaseReports.orderDetail(null,null,null,from,to,null,f,1,1,null,null),
                f -> purchaseReports.orderSummary(null,null,null,from,to,null,f,1,1,null,null),
                f -> purchaseReports.receiptDetail(null,null,null,null,from,to,null,f,1,1,null,null),
                f -> purchaseReports.receiptSummary(null,null,null,null,from,to,null,f,1,1,null,null),
                f -> purchaseReports.returnDetail(null,null,null,null,from,to,null,f,1,1,null,null),
                f -> purchaseReports.returnSummary(null,null,null,null,from,to,null,f,1,1,null,null));
        for (var read : purchase) {
            var schema = read.apply(Map.of());
            Map<String,String> filter = new LinkedHashMap<>();
            for (var column : schema.columns()) {
                if (!schema.columnSearchKeys().contains(column.key())) continue;
                filter.put("search." + column.key(), Set.of("number","money").contains(column.type())
                        ? ">=0" : column.type().equals("date") ? "2026-10-01..2026-10-31" : "HEADER-NO-MATCH-" + UUID.randomUUID());
            }
            assertThat(read.apply(filter).rows()).isEmpty();
            assertThat(schema.columnSearchKeys()).doesNotContain("finishedProductName", "__srcId");
        }
        List<Function<Map<String,String>,com.uten.imp.features.subcontract.report.ReportTableResponse>> subcontract = List.of(
                f -> subcontractReports.orderDetail(null,null,null,from,to,null,f,1,1,null,null),
                f -> subcontractReports.receiptDetail(null,null,null,null,from,to,null,f,1,1,null,null),
                f -> subcontractReports.receiptSummary(null,null,null,null,from,to,null,f,1,1,null,null),
                f -> subcontractReports.returnDetail(null,null,null,null,from,to,null,f,1,1,null,null),
                f -> subcontractReports.returnSummary(null,null,null,null,from,to,null,f,1,1,null,null),
                f -> subcontractReports.materialIssueDetail(null,null,null,null,from,to,null,f,1,1,null,null),
                f -> subcontractReports.materialIssueSummary(null,null,null,null,from,to,null,f,1,1,null,null),
                f -> subcontractReports.materialReturnDetail(null,null,null,null,from,to,null,f,1,1,null,null),
                f -> subcontractReports.materialReturnSummary(null,null,null,null,from,to,null,f,1,1,null,null),
                f -> subcontractReports.inOutStatus(null,from,to,null,1,1,f,"closingQty","desc"));
        for (var read : subcontract) {
            var schema = read.apply(Map.of());
            Map<String,String> filter = new LinkedHashMap<>();
            for (var column : schema.columns()) {
                if (!schema.columnSearchKeys().contains(column.key())) continue;
                filter.put("search." + column.key(), Set.of("number","money").contains(column.type())
                        ? ">=0" : column.type().equals("date") ? "2026-10-01..2026-10-31" : "HEADER-NO-MATCH-" + UUID.randomUUID());
            }
            assertThat(read.apply(filter).rows()).isEmpty();
            assertThat(schema.columnSearchKeys()).doesNotContain("docSeq", "step", "__srcId");
        }
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void headerQueriesFilterAndSortTheWholeLedgerWithTheSameDisplayedBalance(boolean deferred) {
        Actor maker = actor("header-query");
        UUID category = category(deferred);
        login(maker);
        String token = "HEADER-" + UUID.randomUUID();
        create(deferred, category, maker, token + "-100", token + " 低值", "100.00", null);
        var middle = create(deferred, category, maker, token + "-200", token + " 中值", "200.00", null);
        var high = create(deferred, category, maker, token + "-300", token + " 高值", "300.00", null);
        Map<String, String> filters = Map.of(
                "search.name", token,
                "search.grossAmount", "150..350",
                "search.balance", ">=200",
                "sort", "grossAmount", "order", "asc");
        var first = deferred
                ? queries.listDeferredExpenses(null, "DRAFT", category, maker.department(), 1, 1, filters)
                : queries.listFixedAssets(null, "DRAFT", category, maker.department(), 1, 1, filters);
        var second = deferred
                ? queries.listDeferredExpenses(null, "DRAFT", category, maker.department(), 2, 1, filters)
                : queries.listFixedAssets(null, "DRAFT", category, maker.department(), 2, 1, filters);
        assertThat(first.getTotal()).isEqualTo(2);
        assertThat(first.getItems()).extracting(AssetWorkbenchResponses.Summary::id).containsExactly(middle.id());
        assertThat(second.getItems()).extracting(AssetWorkbenchResponses.Summary::id).containsExactly(high.id());
        var row = first.getItems().getFirst();
        assertThat(deferred ? row.remainingAmount() : row.netBookValue()).isEqualByComparingTo("200.00");
        Map<String, String> nameOnly = Map.of("search.name", token + "-200");
        var sourceIsNotName = deferred
                ? queries.listDeferredExpenses(null, null, category, null, 1, 20, nameOnly)
                : queries.listFixedAssets(null, null, category, null, 1, 20, nameOnly);
        assertThat(sourceIsNotName.getItems()).isEmpty();
    }

    @Test
    void postingAndReversalPermissionsStayIndependentThroughApprovedRunExecution() {
        Actor maker = actor("posting-maker"), reviewer = actor("posting-reviewer"), poster = actor("posting-poster");
        Actor reversalMaker = actor("reversal-maker"), reversalPoster = actor("reversal-poster");
        String period = YearMonth.from(BusinessTime.today()).toString();
        UUID original = UUID.randomUUID();
        // A valid zero-item posted batch isolates authorization and workflow transitions.
        // Asset value and GL compensation arithmetic are covered by their existing ledger tests.
        jdbc.update("""
                INSERT INTO finance_asset_posting_runs(id,run_type,book_type,period,run_kind,status,
                    input_fingerprint,algorithm_version,idempotency_key,submitted_at,submitted_by,
                    approved_at,approved_by,posted_at,posted_by)
                VALUES(?,'DEPRECIATION','CORPORATE',?,'NORMAL','POSTED',?,'TEST',?,now(),?,now(),?,now(),?)
                """, original, period, "a".repeat(64), "permission-run-" + original,
                maker.user(), reviewer.user(), poster.user());
        login(poster, Set.of(FinanceAssetAuthorization.VIEW, FinanceAssetAuthorization.POST));
        var originalRun = posting.get(original);
        assertThat(originalRun.allowedActions()).doesNotContain("REVERSE");
        assertThatThrownBy(() -> posting.reverse(original,
                new AssetWorkbenchRequests.PostingReasonCommand(originalRun.version(), "无撤销权限")))
                .isInstanceOf(org.springframework.security.access.AccessDeniedException.class);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM finance_asset_posting_runs WHERE reversal_of_run_id=?",Long.class,original)).isZero();

        login(reversalMaker, Set.of(FinanceAssetAuthorization.VIEW, FinanceAssetAuthorization.REVERSE));
        assertThatThrownBy(() -> posting.post(original,
                new AssetWorkbenchRequests.PostingActionCommand(originalRun.version(), null)))
                .isInstanceOfSatisfying(ApiException.class,error -> assertThat(error.getCode()).isEqualTo(com.uten.imp.common.web.ErrorCode.FORBIDDEN));
        assertThat(posting.get(original).allowedActions()).containsExactly("REVERSE");
        var reversal = posting.reverse(original,
                new AssetWorkbenchRequests.PostingReasonCommand(originalRun.version(), "撤销本期计提入账"));
        assertThat(reversal.status()).isEqualTo("SUBMITTED");
        login(reversalMaker, Set.of(FinanceAssetAuthorization.VIEW, FinanceAssetAuthorization.REVERSE, FinanceAssetAuthorization.APPROVE));
        assertThatThrownBy(() -> posting.approve(reversal.id(),
                new AssetWorkbenchRequests.ApprovalCommand(reversal.version(), "自己不能审"))).isInstanceOf(ApiException.class);
        login(reviewer, Set.of(FinanceAssetAuthorization.VIEW, FinanceAssetAuthorization.APPROVE));
        var approved = posting.approve(reversal.id(), new AssetWorkbenchRequests.ApprovalCommand(reversal.version(), "核对后批准"));

        login(poster, Set.of(FinanceAssetAuthorization.VIEW, FinanceAssetAuthorization.POST));
        assertThat(posting.get(reversal.id()).allowedActions()).doesNotContain("POST");
        assertThatThrownBy(() -> posting.post(reversal.id(),
                new AssetWorkbenchRequests.PostingActionCommand(approved.version(), null)))
                .isInstanceOfSatisfying(ApiException.class,error -> assertThat(error.getCode()).isEqualTo(com.uten.imp.common.web.ErrorCode.FORBIDDEN));
        assertThat(jdbc.queryForObject("SELECT status FROM finance_asset_posting_runs WHERE id=?",String.class,reversal.id())).isEqualTo("APPROVED");
        login(reversalMaker, Set.of(FinanceAssetAuthorization.VIEW, FinanceAssetAuthorization.REVERSE));
        assertThat(posting.get(reversal.id()).allowedActions()).doesNotContain("POST");
        assertThatThrownBy(() -> posting.post(reversal.id(), new AssetWorkbenchRequests.PostingActionCommand(approved.version(), null)))
                .isInstanceOf(ApiException.class);
        login(reversalPoster, Set.of(FinanceAssetAuthorization.VIEW, FinanceAssetAuthorization.REVERSE));
        assertThat(posting.get(reversal.id()).allowedActions()).containsExactly("POST");
        var completed = posting.post(reversal.id(), new AssetWorkbenchRequests.PostingActionCommand(approved.version(), null));
        assertThat(completed.status()).isEqualTo("POSTED");
        assertThat(posting.get(original).status()).isEqualTo("REVERSED");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM finance_asset_posting_runs WHERE reversal_of_run_id=?",Long.class,original)).isEqualTo(1L);
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void deletingDraftsRequiresSeparatePermissionAndStillChecksVersionAndState(boolean deferred) {
        Actor maker = actor("delete-permission");
        login(maker);
        var created = create(deferred, category(deferred), maker, "DELETE-" + UUID.randomUUID(), "删除权限草稿", "100.00", null);
        assertThat(detail(created.id(), deferred).allowedActions()).doesNotContain("DELETE");
        assertThatThrownBy(() -> workflow.deleteDraft(created.id(), deferred, created.version()))
                .isInstanceOf(org.springframework.security.access.AccessDeniedException.class);

        login(maker, Set.of(FinanceAssetAuthorization.VIEW, FinanceAssetAuthorization.DELETE));
        assertThat(detail(created.id(), deferred).allowedActions()).containsExactly("DELETE");
        assertThatThrownBy(() -> workflow.deleteDraft(created.id(), deferred, created.version() + 1))
                .isInstanceOf(ApiException.class);
        login(maker, Set.of(FinanceAssetAuthorization.VIEW));
        assertThatThrownBy(() -> workflow.deleteDraft(created.id(), deferred, created.version()))
                .isInstanceOf(org.springframework.security.access.AccessDeniedException.class);
        login(maker, Set.of(FinanceAssetAuthorization.VIEW, FinanceAssetAuthorization.DELETE));
        workflow.deleteDraft(created.id(), deferred, created.version());
        assertThat(jdbc.queryForObject("SELECT is_deleted FROM " + (deferred ? "deferred_expenses" : "fixed_assets")
                + " WHERE id = ?", Boolean.class, created.id())).isTrue();

        login(maker);
        var second = create(deferred, category(deferred), maker, "SUBMITTED-" + UUID.randomUUID(), "待审不能删除", "100.00", null);
        var submitted = workflow.submit(second.id(), second.version(), deferred);
        login(maker, Set.of(FinanceAssetAuthorization.VIEW, FinanceAssetAuthorization.DELETE));
        assertThatThrownBy(() -> workflow.deleteDraft(second.id(), deferred, submitted.version())).isInstanceOf(ApiException.class);
    }

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

    @Test
    void openingDepreciationReversalAndBothStatementsReconcileWithRealAmounts() {
        Actor maker=actor("opening-maker"),reviewer=actor("opening-reviewer"),poster=actor("opening-poster"),
                reverseMaker=actor("opening-reverse-maker"),reversePoster=actor("opening-reverse-poster");
        UUID category=category(false);
        var asOf=YearMonth.from(BusinessTime.today()).minusMonths(1).atEndOfMonth();
        String period=YearMonth.from(asOf).plusMonths(1).toString();
        var end=YearMonth.parse(period).atEndOfMonth();
        var start=asOf.minusMonths(10);
        login(maker,financialPermissions());
        var draft=workflow.createFixed(new AssetWorkbenchRequests.FixedAssetDraft(null,"接续资产",category,
                maker.department(),maker.employee(),"一楼",null,null,null,new BigDecimal("1200"),new BigDecimal("0.05"),
                12,period,start,start,start,"MANUAL",null,"OPENING-"+UUID.randomUUID(),"HEADER",start,null,null,
                new AssetWorkbenchRequests.OpeningBalance(asOf,new BigDecimal("540"),6,null)));
        var submitted=workflow.submit(draft.id(),draft.version(),false);
        login(reviewer,financialPermissions());var approved=workflow.approve(draft.id(),submitted.version(),"核对期初",false);
        login(poster,financialPermissions());var active=workflow.activate(draft.id(),approved.version(),false);
        assertThat(active.status()).isEqualTo("ACTIVE");
        assertThat(queries.fixedAsset(draft.id()).books().getFirst().monthlyAmount()).isEqualByComparingTo("100");
        assertThat(queries.fixedAsset(draft.id()).schedule().getFirst().openingBalance()).isEqualByComparingTo("660");
        // Explicitly configure unused lines instead of manufacturing zeroes from missing mappings.
        for(var line:reportBindings.list())if(line.sheet()!=null)reportBindings.replace(line.lineKey(),List.of(),true);
        var styles=jdbc.queryForMap("SELECT cost_style_id,accumulated_style_id,expense_style_id,clearing_style_id FROM finance_asset_categories WHERE id=?",category);
        reportBindings.replace("BS_18",List.of((UUID)styles.get("cost_style_id")));
        reportBindings.replace("BS_19",List.of((UUID)styles.get("accumulated_style_id")));
        reportBindings.replace("BS_1",List.of((UUID)styles.get("clearing_style_id")));
        reportBindings.replace("PL_14",List.of((UUID)styles.get("expense_style_id")));
        var posted=postNormalMonth(period,maker,reviewer,poster);
        assertThat(posted.totalAmount()).isEqualByComparingTo("100");
        assertStatement(financialReports.balanceSheet(end),20,"periodEnd","560");
        assertStatement(financialReports.balanceSheet(end),19,"periodEnd","640");
        assertStatement(financialReports.balanceSheet(end),30,"periodEnd","-100");
        assertStatement(financialReports.balanceSheet(end),53,"periodEnd","-100");
        assertStatement(financialReports.profitMonthly(end.getYear(),end.getMonthValue()),32,"monthAmount","-100");
        try {
            var directory=java.nio.file.Path.of("target","finance-statement-fixtures");java.nio.file.Files.createDirectories(directory);
            json.writeValue(directory.resolve("balance.json").toFile(),com.uten.imp.features.finance.gl.FinancialStatementPresentation.apply("BALANCE","template",financialReports.balanceSheet(end)));
            json.writeValue(directory.resolve("profit.json").toFile(),com.uten.imp.features.finance.gl.FinancialStatementPresentation.apply("PROFIT","template",financialReports.profitMonthly(end.getYear(),end.getMonthValue())));
        } catch(java.io.IOException failure){throw new AssertionError(failure);}
        var historical=assetReports.depreciationSchedule(1,50,com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE,asOf);
        assertThat(historical.rows().stream().filter(r->"接续资产".equals(r.get("name"))).findFirst().orElseThrow().get("netValue"))
                .isEqualTo(new BigDecimal("660.00"));
        assertThatThrownBy(()->posting.post(posted.id(),new AssetWorkbenchRequests.PostingActionCommand(posted.version(),null)))
                .isInstanceOf(ApiException.class);
        login(reverseMaker,Set.of(FinanceAssetAuthorization.VIEW,FinanceAssetAuthorization.REVERSE));
        assertThatThrownBy(()->recognitionReversals.request(draft.id(),false,
                new AssetWorkbenchRequests.ReasonCommand(active.version(),"尚有计提"))).isInstanceOf(ApiException.class);
        reverseMonth(posted,reviewer,reverseMaker,reversePoster);
        login(poster,financialPermissions());
        assertStatement(financialReports.balanceSheet(end),20,"periodEnd","660");
        assertStatement(financialReports.profitMonthly(end.getYear(),end.getMonthValue()),32,"monthAmount","0");
        var reposted=postNormalMonth(period,maker,reviewer,poster);
        assertThat(reposted.totalAmount()).isEqualByComparingTo("100");
        reverseMonth(reposted,reviewer,reverseMaker,reversePoster);
        login(reverseMaker,Set.of(FinanceAssetAuthorization.VIEW,FinanceAssetAuthorization.REVERSE));
        long version=queries.fixedAsset(draft.id()).summary().version();
        var reversal=recognitionReversals.request(draft.id(),false,new AssetWorkbenchRequests.ReasonCommand(version,"撤销接续测试"));
        assertThat(queries.fixedAsset(draft.id()).allowedActions()).doesNotContain("APPROVE_RECOGNITION_REVERSAL");
        login(reviewer,financialPermissions());
        var checked=recognitionReversals.approve(draft.id(),false,new AssetWorkbenchRequests.VersionCommand(reversal.version()));
        login(reversePoster,Set.of(FinanceAssetAuthorization.VIEW,FinanceAssetAuthorization.REVERSE));
        var done=recognitionReversals.post(draft.id(),false,new AssetWorkbenchRequests.VersionCommand(checked.version()));
        assertThat(done.status()).isEqualTo("REVERSED");
        login(poster,financialPermissions());
        assertStatement(financialReports.balanceSheet(end),18,"periodEnd","0");
        assertStatement(financialReports.balanceSheet(asOf),18,"periodEnd","1200");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM gl_vouchers WHERE source_type='FA_CAP_REV' AND source_ref LIKE 'RECOGNITION_REVERSAL:%'",Integer.class)).isPositive();
    }

    @Test
    void linkedOpeningVoucherIsNotRepostedAndIsProtectedUntilRegistrationReversal() {
        Actor maker=actor("linked-maker"),reviewer=actor("linked-reviewer"),poster=actor("linked-poster");
        UUID category=category(false),voucher=UUID.randomUUID();
        var asOf=YearMonth.from(BusinessTime.today()).minusMonths(1).atEndOfMonth();
        var styles=jdbc.queryForMap("SELECT cost_style_id,accumulated_style_id,clearing_style_id FROM finance_asset_categories WHERE id=?",category);
        jdbc.update("INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type,status) VALUES(?,?,?,?,'MANUAL','MANUAL',1)",
                voucher,"OPENING-"+voucher,YearMonth.from(asOf).toString(),asOf);
        String[] keys={"cost_style_id","accumulated_style_id","clearing_style_id"};
        String[] amounts={"1000","450","550"};
        for(int i=0;i<3;i++)jdbc.update("INSERT INTO gl_entries(voucher_id,line_no,style_id,direction,amount,entry_date,period) VALUES(?,?,?,?,?,?,?)",
                voucher,i+1,styles.get(keys[i]),i==0?1:-1,new BigDecimal(amounts[i]),asOf,YearMonth.from(asOf).toString());
        login(maker,financialPermissions());
        String source="LINKED-"+UUID.randomUUID();
        var input=new AssetWorkbenchRequests.FixedAssetDraft(null,"关联旧资产",category,maker.department(),maker.employee(),"一楼",null,null,null,
                new BigDecimal("1000"),new BigDecimal("0.05"),12,YearMonth.from(asOf).plusMonths(1).toString(),
                asOf,asOf,asOf,"MANUAL",null,source,"HEADER",asOf,null,null,
                new AssetWorkbenchRequests.OpeningBalance(asOf,new BigDecimal("450"),5,voucher));
        var created=workflow.createFixed(input);
        jdbc.update("UPDATE gl_entries SET amount=449 WHERE voucher_id=? AND style_id=?",voucher,styles.get("accumulated_style_id"));
        assertThatThrownBy(()->workflow.submit(created.id(),created.version(),false)).isInstanceOf(ApiException.class);
        assertThat(queries.fixedAsset(created.id()).summary().status()).isEqualTo("DRAFT");
        jdbc.update("UPDATE gl_entries SET amount=450 WHERE voucher_id=? AND style_id=?",voucher,styles.get("accumulated_style_id"));
        var submitted=workflow.submit(created.id(),created.version(),false);
        assertThatThrownBy(()->jdbc.update("UPDATE gl_entries SET amount=449 WHERE voucher_id=? AND style_id=?",voucher,styles.get("accumulated_style_id")))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
        login(reviewer,financialPermissions());var approved=workflow.approve(created.id(),submitted.version(),"核对已入账凭证",false);
        login(poster,financialPermissions());var active=workflow.activate(created.id(),approved.version(),false);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM gl_entries WHERE style_id=?",Integer.class,styles.get("cost_style_id"))).isEqualTo(1);
        assertThat(queries.fixedAsset(created.id()).summary().openingBalance().existingVoucherId()).isEqualTo(voucher);
        var duplicate=new AssetWorkbenchRequests.FixedAssetDraft(null,"重复关联",category,maker.department(),maker.employee(),"一楼",null,null,null,
                new BigDecimal("1000"),new BigDecimal("0.05"),12,YearMonth.from(asOf).plusMonths(1).toString(),
                asOf,asOf,asOf,"MANUAL",null,source+"-DUPLICATE","HEADER",asOf,null,null,input.openingBalance());
        assertThatThrownBy(()->workflow.createFixed(duplicate)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->jdbc.update("UPDATE gl_entries SET amount=amount+1 WHERE voucher_id=?",voucher))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
        UUID other=UUID.randomUUID();
        jdbc.update("INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type,status) VALUES(?,?,?,?,'MANUAL','MANUAL',1)",
                other,"OTHER-"+other,YearMonth.from(asOf).toString(),asOf);
        jdbc.update("INSERT INTO gl_entries(voucher_id,line_no,style_id,direction,amount,entry_date,period) VALUES(?,1,?,1,1,?,?)",
                other,styles.get("cost_style_id"),asOf,YearMonth.from(asOf).toString());
        assertThatThrownBy(()->jdbc.update("UPDATE gl_entries SET voucher_id=? WHERE voucher_id=?",voucher,other))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
        jdbc.update("DELETE FROM gl_entries WHERE voucher_id=?",other);jdbc.update("DELETE FROM gl_vouchers WHERE id=?",other);
        login(maker,financialPermissions());
        var request=recognitionReversals.request(created.id(),false,new AssetWorkbenchRequests.ReasonCommand(active.version(),"撤销台账接续"));
        login(reviewer,financialPermissions());
        var checked=recognitionReversals.approve(created.id(),false,new AssetWorkbenchRequests.VersionCommand(request.version()));
        login(poster,Set.of(FinanceAssetAuthorization.VIEW,FinanceAssetAuthorization.REVERSE));
        recognitionReversals.post(created.id(),false,new AssetWorkbenchRequests.VersionCommand(checked.version()));
        assertThat(jdbc.queryForObject("SELECT status FROM gl_vouchers WHERE id=?",Integer.class,voucher)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM gl_entries WHERE voucher_id=?",Integer.class,voucher)).isEqualTo(3);
        login(maker,financialPermissions());
        var retry=workflow.createFixed(input);
        assertThat(retry.id()).isNotEqualTo(created.id());
        login(maker,Set.of(FinanceAssetAuthorization.DELETE));workflow.deleteDraft(retry.id(),false,retry.version());
        // Only this synthetic manual voucher's entries are cleaned after the preservation assertions;
        // another company-wide report test must not inherit this test's opening balance.
        jdbc.update("DELETE FROM gl_entries WHERE voucher_id=?",voucher);
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void recognitionReversalCanBeRejectedThenCompletedWithoutErasingHistory(boolean deferred) {
        Actor maker=actor("recognition-maker"),reviewer=actor("recognition-reviewer"),poster=actor("recognition-poster");
        UUID category=category(deferred);
        login(maker,financialPermissions());
        var created=create(deferred,category,maker,"RECOGNITION-"+UUID.randomUUID(),"初始确认闭环","100.00",null);
        var submitted=workflow.submit(created.id(),created.version(),deferred);
        login(reviewer,financialPermissions());var approved=workflow.approve(created.id(),submitted.version(),"复核",deferred);
        login(poster,financialPermissions());var active=workflow.activate(created.id(),approved.version(),deferred);
        login(maker,financialPermissions());
        var request=recognitionReversals.request(created.id(),deferred,new AssetWorkbenchRequests.ReasonCommand(active.version(),"首次申请"));
        assertThatThrownBy(()->recognitionReversals.approve(created.id(),deferred,new AssetWorkbenchRequests.VersionCommand(request.version())))
                .isInstanceOf(ApiException.class);
        login(reviewer,financialPermissions());
        var rejected=recognitionReversals.reject(created.id(),deferred,new AssetWorkbenchRequests.ReasonCommand(request.version(),"暂不撤销"));
        assertThat(rejected.status()).isEqualTo("ACTIVE");
        login(maker,financialPermissions());
        var again=recognitionReversals.request(created.id(),deferred,new AssetWorkbenchRequests.ReasonCommand(rejected.version(),"核对后重新申请"));
        login(reviewer,financialPermissions());
        var checked=recognitionReversals.approve(created.id(),deferred,new AssetWorkbenchRequests.VersionCommand(again.version()));
        login(poster,Set.of(FinanceAssetAuthorization.VIEW,FinanceAssetAuthorization.REVERSE));
        var reversed=recognitionReversals.post(created.id(),deferred,new AssetWorkbenchRequests.VersionCommand(checked.version()));
        assertThat(reversed.status()).isEqualTo("REVERSED");
        assertThat(detail(created.id(),deferred).schedule()).allSatisfy(line->assertThat(line.status()).isEqualTo("CANCELLED"));
        assertThat(jdbc.queryForObject("SELECT count(*) FROM finance_asset_recognition_reversals WHERE object_id=?",Integer.class,created.id())).isEqualTo(2);
        assertThatThrownBy(()->jdbc.update("DELETE FROM finance_asset_recognition_reversals WHERE object_id=?",created.id()))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
    }

    @Test
    void anOlderDraftContractCannotSilentlyEraseOpeningBalances() {
        Actor maker=actor("opening-compatibility");UUID category=category(false);
        var asOf=YearMonth.from(BusinessTime.today()).minusMonths(1).atEndOfMonth();
        String period=YearMonth.from(asOf).plusMonths(1).toString(),source="COMPAT-"+UUID.randomUUID();
        login(maker,financialPermissions());
        var draft=workflow.createFixed(new AssetWorkbenchRequests.FixedAssetDraft(null,"旧资产",category,maker.department(),maker.employee(),"一楼",null,null,null,
                new BigDecimal("1000"),new BigDecimal("0.05"),12,period,asOf,asOf,asOf,"MANUAL",null,source,"HEADER",asOf,null,null,
                new AssetWorkbenchRequests.OpeningBalance(asOf,new BigDecimal("450.1234"),5,null)));
        var updated=workflow.updateFixed(draft.id(),new AssetWorkbenchRequests.FixedAssetDraft(null,"仅改名称",category,maker.department(),maker.employee(),"一楼",null,null,null,
                new BigDecimal("1000"),new BigDecimal("0.05"),12,period,asOf,asOf,asOf,"MANUAL",null,source,"HEADER",asOf,null,draft.version()));
        assertThat(queries.fixedAsset(draft.id()).summary().openingBalance().accumulatedAmount()).isEqualByComparingTo("450.1234");
        var corrected=workflow.updateFixed(draft.id(),new AssetWorkbenchRequests.FixedAssetDraft(null,"同时更正原值与累计折旧",category,maker.department(),maker.employee(),"一楼",null,null,null,
                new BigDecimal("200"),new BigDecimal("0.05"),12,period,asOf,asOf,asOf,"MANUAL",null,source,"HEADER",asOf,null,updated.version(),
                new AssetWorkbenchRequests.OpeningBalance(asOf,new BigDecimal("100"),1,null)));
        assertThat(queries.fixedAsset(corrected.id()).summary().originalValue()).isEqualByComparingTo("200");
        var cleared=workflow.updateFixed(draft.id(),new AssetWorkbenchRequests.FixedAssetDraft(null,"改为新资产",category,maker.department(),maker.employee(),"一楼",null,null,null,
                new BigDecimal("50"),new BigDecimal("0.05"),12,period,asOf,asOf,asOf,"MANUAL",null,source,"HEADER",asOf,null,corrected.version(),null,true));
        assertThat(queries.fixedAsset(cleared.id()).summary().openingBalance()).isNull();
    }

    private AssetWorkbenchResponses.PostingRun postNormalMonth(String period,Actor maker,Actor reviewer,Actor poster) {
        login(maker,financialPermissions());
        var preview=posting.preview(new AssetWorkbenchRequests.PostingPreviewCommand("DEPRECIATION","CORPORATE",period));
        assertThat(preview.exceptions()).noneMatch(e->"BLOCKING".equals(e.severity()));
        var submitted=posting.submit(preview.id(),new AssetWorkbenchRequests.PostingActionCommand(preview.version(),preview.token()));
        login(reviewer,financialPermissions());
        var approved=posting.approve(submitted.id(),new AssetWorkbenchRequests.ApprovalCommand(submitted.version(),"金额核对"));
        login(poster,financialPermissions());
        return posting.post(approved.id(),new AssetWorkbenchRequests.PostingActionCommand(approved.version(),null));
    }
    private void reverseMonth(AssetWorkbenchResponses.PostingRun posted,Actor reviewer,Actor maker,Actor poster) {
        login(maker,Set.of(FinanceAssetAuthorization.VIEW,FinanceAssetAuthorization.REVERSE));
        var requested=posting.reverse(posted.id(),new AssetWorkbenchRequests.PostingReasonCommand(posted.version(),"重新核对"));
        login(reviewer,financialPermissions());
        var approved=posting.approve(requested.id(),new AssetWorkbenchRequests.ApprovalCommand(requested.version(),"批准红冲"));
        login(poster,Set.of(FinanceAssetAuthorization.VIEW,FinanceAssetAuthorization.REVERSE));
        assertThat(posting.post(approved.id(),new AssetWorkbenchRequests.PostingActionCommand(approved.version(),null)).status()).isEqualTo("POSTED");
    }
    private static Set<String> financialPermissions(){return Set.of("finance_asset:view","finance_asset:edit","finance_asset:approve",
            "finance_asset:post","finance_asset:reverse","finance_asset_period:manage","finance_report:view","finance:view:all","payment_style:edit");}
    private static void assertStatement(com.uten.imp.features.finance.report.ReportTableResponse report,int line,String column,String expected) {
        var row=report.rows().stream().filter(r->Integer.valueOf(line).equals(r.get("lineNo"))).findFirst().orElseThrow();
        assertThat(row.get(column)).as("%s %s (%s)",line,column,row.get("basis")).isNotNull();
        assertThat((BigDecimal)row.get(column)).isEqualByComparingTo(expected);
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
                VALUES(?,?,?,?,?,?,?,?,'STRAIGHT_LINE',12,0.05,CURRENT_DATE,'ACTIVE')
                """,id,deferred ? "DEFERRED_EXPENSE" : "FIXED_ASSET","REV-"+id,
                "提交对照类别-"+id,cost,deferred ? null : accumulated,expense,clearing);
        return id;
    }
    private UUID style(String type) {
        UUID id=UUID.randomUUID();
        jdbc.update("INSERT INTO payment_styles(id,code,name,category,status) VALUES(?,?,?,?,'使用')",
                id,"AR-"+id,"提交对照科目-"+id,type);
        return id;
    }
    private Actor actor(String label) {
        UUID employee=UUID.randomUUID(),user=UUID.randomUUID();
        UUID department=jdbc.queryForObject("SELECT id FROM departments WHERE code='DEPT_FIN'",UUID.class);
        jdbc.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')",employee,"ARE-"+employee,com.uten.imp.support.SyntheticEmployeeIdentity.name(label,employee),department);
        jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status) VALUES(?,?,?,'test-not-used',false,false,'active')",user,employee,"asset-revision-"+user);
        return new Actor(user,employee,department);
    }
    private void login(Actor actor) {
        login(actor, Set.of("finance_asset:view","finance_asset:edit","finance_asset:approve","finance_asset:dispose"));
    }
    private void login(Actor actor, Set<String> permissions) {
        var user=new AuthUser(actor.user(),actor.employee(),"asset-review",permissions,false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,"",user.getAuthorities()));
    }
    private record Actor(UUID user,UUID employee,UUID department) {}
}
