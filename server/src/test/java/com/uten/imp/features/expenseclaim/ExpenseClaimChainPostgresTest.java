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
    "uten.reporting.materialized-view-refresh.enabled=false",
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
    @Autowired com.uten.imp.common.platformcolumns.PlatformColumnService platformColumns;
    @Autowired com.uten.imp.common.history.RetainedRecordReader retainedRecords;
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void submissionFreezesExtraColumnsAcrossRejectionAndRecreatedItemIds() throws Exception {
        Actor applicant=actor("extra-applicant"),reviewer=actor("extra-reviewer");login(applicant,"expense:apply");
        var column=platformColumns.create("expense_claim_item",new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CreateDefinition("项目说明","TEXT",false,null));
        var headColumn=platformColumns.create("expense_claim",new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CreateDefinition("申请归类","TEXT",false,null));
        var input=new ExpenseClaimItemInput("TRAVEL",new BigDecimal("100.00"),BusinessTime.today(),"住宿费用",
                new com.uten.imp.common.platformcolumns.PlatformColumnLineInput.Fields(null,0,List.of(new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CellInput(column.id(),"第一次说明"))));
        var draft=claims.create(new ExpenseClaimCreateRequest("扩展字段快照","原始备注",List.of(input),null));
        platformColumns.write("expense_claim",draft.id(),new com.uten.imp.common.platformcolumns.PlatformColumnContracts.Write(0,
                List.of(new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CellInput(headColumn.id(),"第一阶段"))));
        attachment(draft.id());var submitted=claims.submit(draft.id(),draft.version());
        var json=new com.fasterxml.jackson.databind.ObjectMapper();var first=json.readTree(submitted.submissionSnapshot());
        assertThat(first.path("schemaVersion").asInt()).isEqualTo(2);
        assertThat(first.path("platformFields").path("cells").get(0).path("value").asText()).isEqualTo("第一阶段");
        assertThat(first.path("items").get(0).path("platformFields").path("cells").get(0).path("value").asText()).isEqualTo("第一次说明");
        UUID originalItem=draft.items().getFirst().id();
        login(reviewer,"expense:approve");var rejected=claims.reject(draft.id(),"补充",submitted.version());
        login(applicant,"expense:apply");
        var changed=new ExpenseClaimItemInput("TRAVEL",new BigDecimal("100.00"),BusinessTime.today(),"住宿费用",
                new com.uten.imp.common.platformcolumns.PlatformColumnLineInput.Fields(originalItem,1,List.of(new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CellInput(column.id(),"第二次说明"))));
        var edited=claims.editVersioned(draft.id(),new ExpenseClaimCreateRequest("扩展字段快照","补充备注",List.of(changed),rejected.version()));
        assertThat(edited.items().getFirst().id()).isNotEqualTo(originalItem);
        platformColumns.write("expense_claim",draft.id(),new com.uten.imp.common.platformcolumns.PlatformColumnContracts.Write(1,
                List.of(new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CellInput(headColumn.id(),"第二阶段"))));
        var resubmitted=claims.submit(draft.id(),edited.version());
        assertThat(json.readTree(resubmitted.previousSubmissionSnapshot())).isEqualTo(first);
        assertThat(json.readTree(resubmitted.submissionSnapshot()).path("items").get(0).path("platformFields").path("cells").get(0).path("value").asText()).isEqualTo("第二次说明");
        assertThat(json.readTree(resubmitted.submissionSnapshot()).path("platformFields").path("cells").get(0).path("value").asText()).isEqualTo("第二阶段");
    }

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
        var firstSubmitted=claims.submit(claimId,invoice.version());
        long submittedVersion=firstSubmitted.version();
        assertThat(firstSubmitted.resubmission()).isFalse();
        assertThat(firstSubmitted.previousSubmissionSnapshot()).isNull();
        var snapshots=new com.fasterxml.jackson.databind.ObjectMapper();
        assertThat(snapshots.readTree(firstSubmitted.submissionSnapshot()).path("items").get(0).path("amount").asText())
            .isEqualTo("100.00");
        login(reviewer,"expense:approve","attachment:view","attachment:download");
        assertThatThrownBy(()->claims.approve(claimId,submittedVersion)).isInstanceOf(ApiException.class)
            .hasMessageContaining("逐张核对");
        var rejected=claims.reject(claimId,"补充业务说明",submittedVersion);
        login(applicant,"expense:apply");
        var edited=claims.editVersioned(claimId,request("出差拜访客户住宿",rejected.version()));
        var submitted=claims.submit(claimId,edited.version());
        assertThat(submitted.resubmission()).isTrue();
        assertThat(snapshots.readTree(submitted.previousSubmissionSnapshot()))
            .isEqualTo(snapshots.readTree(firstSubmitted.submissionSnapshot()));
        assertThat(snapshots.readTree(submitted.submissionSnapshot()).path("title").asText())
            .isEqualTo("出差拜访客户住宿");
        assertThat(snapshots.readTree(submitted.submissionSnapshot()).path("invoices").get(0).has("checkState"))
            .isFalse();
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

    @Test void withdrawnEditsCompareTheLastSubmissionAndMissingLegacyBaselinesStayMissing() throws Exception {
        var json=new com.fasterxml.jackson.databind.ObjectMapper();
        Actor applicant=actor("revisions"),reviewer=actor("revision-reviewer");
        login(applicant,"expense:apply");
        var draft=claims.create(request("首次提交",null));
        attachment(draft.id());
        var first=claims.submit(draft.id(),draft.version());
        var withdrawn=claims.withdraw(first.id(),first.version());
        assertThat(json.readTree(withdrawn.submissionSnapshot())).isEqualTo(json.readTree(first.submissionSnapshot()));
        var intermediate=claims.editVersioned(first.id(),request("中间修改",withdrawn.version()));
        var latest=claims.editVersioned(first.id(),new ExpenseClaimCreateRequest("最终修改","费用凭证说明",List.of(
            new ExpenseClaimItemInput("TRAVEL",new BigDecimal("80.00"),BusinessTime.today(),"住宿费用更正"),
            new ExpenseClaimItemInput("OFFICE",new BigDecimal("20.00"),BusinessTime.today(),"新增文具")),intermediate.version()));
        var resubmitted=claims.submit(first.id(),latest.version());
        assertThat(resubmitted.resubmission()).isTrue();
        assertThat(json.readTree(resubmitted.previousSubmissionSnapshot())).isEqualTo(json.readTree(first.submissionSnapshot()));
        assertThat(json.readTree(resubmitted.submissionSnapshot()).path("items")).hasSize(2);
        assertThat(json.readTree(resubmitted.submissionSnapshot()).path("items").get(0).path("amount").asText()).isEqualTo("80.00");

        // A still-submitted legacy document is frozen: withdrawal may preserve its
        // authentic current submission before any applicant edits are allowed.
        jdbc.update("UPDATE expense_claims SET submission_snapshot=NULL, previous_submission_snapshot=NULL WHERE id=?",first.id());
        var legacyWithdrawn=claims.withdraw(first.id(),resubmitted.version());
        var legacyEdited=claims.editVersioned(first.id(),request("撤回后的再次修改",legacyWithdrawn.version()));
        var third=claims.submit(first.id(),legacyEdited.version());
        assertThat(json.readTree(third.previousSubmissionSnapshot()).path("title").asText()).isEqualTo("最终修改");

        // Already-editable legacy documents may have been changed before rollout;
        // their unrecorded old rows must never be fabricated from current values.
        login(reviewer,"expense:approve");
        var rejected=claims.reject(first.id(),"补充说明",third.version());
        jdbc.update("UPDATE expense_claims SET submission_snapshot=NULL, previous_submission_snapshot=NULL WHERE id=?",first.id());
        login(applicant,"expense:apply");
        var legacyRework=claims.editVersioned(first.id(),request("历史缺少基线",rejected.version()));
        var legacyResubmission=claims.submit(first.id(),legacyRework.version());
        assertThat(legacyResubmission.resubmission()).isTrue();
        assertThat(legacyResubmission.previousSubmissionSnapshot()).isNull();
        assertThat(json.readTree(legacyResubmission.submissionSnapshot()).path("title").asText()).isEqualTo("历史缺少基线");
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

    @Test void deletionPreservesOriginalsAndHistoryIsReadOnlyAndCurrentlyScoped() {
        Actor applicant=actor("retained-owner"),foreign=actor("retained-other");login(applicant,"expense:apply");
        var draft=claims.create(request("删除前原文",null));
        UUID originalItem=draft.items().getFirst().id();
        var changed=claims.editVersioned(draft.id(),request("修订后原文",draft.version()));
        assertThat(jdbc.queryForObject("SELECT count(*) FROM business_record_history WHERE source_table='expense_claim_items' AND source_id=? AND payload->>'description'='客户拜访住宿一晚'",Integer.class,originalItem.toString())).isEqualTo(1);
        assertThat(changed.totalAmount()).isEqualByComparingTo("100.00");
        UUID retainedItem=changed.items().getFirst().id();
        claims.delete(changed.id(),changed.version());
        assertThat(jdbc.queryForObject("SELECT is_deleted FROM expense_claims WHERE id=?",Boolean.class,changed.id())).isTrue();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM expense_claim_items WHERE id=?",Integer.class,retainedItem)).isEqualTo(1);
        assertThatThrownBy(()->claims.detail(changed.id())).isInstanceOf(ApiException.class);
        assertThat(claims.listMine(null,null,null,null,null,1,20,null,null,changed.claimNo()).getItems()).isEmpty();
        var history=claims.detailHistory(changed.id());
        var retained=claims.historyRows(changed.id(),null,1);
        assertThat(retained).hasSize(1);
        assertThat(retained.getFirst().sourceId()).isEqualTo(originalItem.toString());
        assertThat(retained.getFirst().original().path("amount").decimalValue()).isEqualByComparingTo("100.00");
        assertThat(retained.getFirst().originalJson()).contains("客户拜访住宿一晚");
        assertThat(claims.historyRows(changed.id(),retained.getFirst().id(),1)).isEmpty();
        assertThat(history.title()).isEqualTo("修订后原文");
        assertThat(history.status()).isEqualTo("DRAFT");
        assertThat(history.items().getFirst().id()).isEqualTo(retainedItem);
        assertThat(history.history().isDeleted()).isTrue();
        assertThat(history.history().isHistoryReadOnly()).isTrue();
        assertThat(history.history().getDeletedAt()).isNotNull();
        assertThat(history.history().getDeletedByName()).isEqualTo(applicant.login());
        assertThat(claims.listMine(null,null,null,null,null,1,20,null,null,changed.claimNo(),false,true).getItems()).hasSize(1);
        assertThat(claims.facets("mine",false,true).claimNos()).anySatisfy(bucket->assertThat(bucket.value()).isEqualTo(changed.claimNo()));
        assertThatThrownBy(()->claims.submit(changed.id(),history.version())).isInstanceOf(ApiException.class);
        login(foreign,"expense:apply");
        assertThatThrownBy(()->claims.detailHistory(changed.id())).isInstanceOf(ApiException.class);
        assertThat(claims.listMine(null,null,null,null,null,1,20,null,null,changed.claimNo(),true,false).getItems()).isEmpty();
    }

    @Test void deletedDraftKeepsInvoiceOriginalButReleasesItsLiveDeduplicationSlot() {
        Actor applicant=actor("retained-invoice");login(applicant,"expense:apply");
        var old=claims.create(request("未提交的旧申请",null));
        String invoiceNo="HIST/"+UUID.randomUUID();
        var withInvoice=claims.addInvoiceVersioned(old.id(),new ExpenseClaimInvoiceInput("OTHER",null,invoiceNo,
                BusinessTime.today(),"测试出票单位",null,null,null,null,new BigDecimal("100.00"),null,"票据原文",old.version(),null));
        claims.delete(old.id(),withInvoice.version());
        assertThat(claims.detailHistory(old.id()).invoices()).hasSize(1);
        assertThat(claims.detailHistory(old.id()).invoices().getFirst().remark()).isEqualTo("票据原文");
        assertThat(claims.checkInvoiceDuplicate(invoiceNo,null,null,"OTHER","测试出票单位").duplicated()).isFalse();
        var replacement=claims.create(request("重建的有效申请",null));
        var saved=claims.addInvoiceVersioned(replacement.id(),new ExpenseClaimInvoiceInput("OTHER",null,invoiceNo,
                BusinessTime.today(),"测试出票单位",null,null,null,null,new BigDecimal("100.00"),null,null,replacement.version(),null));
        assertThat(claims.detail(saved.id()).invoices()).hasSize(1);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM expense_claim_invoices WHERE invoice_no=?",Integer.class,invoiceNo)).isEqualTo(2);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM expense_claim_invoices WHERE invoice_no=? AND NOT is_archived",Integer.class,invoiceNo)).isEqualTo(1);
    }

    @Test void retainedNestedRowsPreserveExactMoneyAcrossCursorPages() {
        jdbc.execute("CREATE TABLE history_reader_root(id uuid PRIMARY KEY)");
        jdbc.execute("CREATE TABLE history_reader_line(id uuid PRIMARY KEY,root_id uuid NOT NULL)");
        jdbc.execute("CREATE TABLE history_reader_cost(id uuid PRIMARY KEY,line_id uuid NOT NULL,amount numeric(38,18))");
        jdbc.execute("SELECT fn_register_record_retention('history_reader_line','history_reader_root','root_id')");
        jdbc.execute("SELECT fn_register_record_retention('history_reader_cost','history_reader_line','line_id')");
        UUID rootId=UUID.randomUUID(),lineId=UUID.randomUUID(),costId=UUID.randomUUID();
        BigDecimal exact=new BigDecimal("12345678901234567890.123456789012345678");
        jdbc.update("INSERT INTO history_reader_root VALUES(?)",rootId);
        jdbc.update("INSERT INTO history_reader_line VALUES(?,?)",lineId,rootId);
        jdbc.update("INSERT INTO history_reader_cost VALUES(?,?,?)",costId,lineId,exact);
        jdbc.update("DELETE FROM history_reader_cost WHERE id=?",costId);
        jdbc.update("DELETE FROM history_reader_line WHERE id=?",lineId);
        var first=retainedRecords.children("history_reader_root",rootId,null,1);
        assertThat(first).hasSize(1);assertThat(first.getFirst().sourceId()).isEqualTo(lineId.toString());
        var second=retainedRecords.children("history_reader_root",rootId,first.getFirst().id(),1);
        assertThat(second).hasSize(1);assertThat(second.getFirst().sourceId()).isEqualTo(costId.toString());
        assertThat(second.getFirst().original().path("amount").decimalValue()).isEqualByComparingTo(exact);
        assertThat(second.getFirst().originalJson()).contains(exact.toPlainString());
        assertThat(retainedRecords.children("history_reader_root",rootId,second.getFirst().id(),1)).isEmpty();
        assertThat(retainedRecords.children("history_reader_root",UUID.randomUUID(),null,100)).isEmpty();
        assertThat(retainedRecords.children("history_reader_root",rootId,null,100,Set.of())).isEmpty();
        assertThat(retainedRecords.children("history_reader_root",rootId,null,100,Set.of("history_reader_line")))
                .hasSize(1).allSatisfy(row->assertThat(row.sourceTable()).isEqualTo("history_reader_line"));
        assertThat(retainedRecords.children("history_reader_root",rootId,null,100,Set.of("history_reader_line","history_reader_cost")))
                .hasSize(2);
    }

    @Test void deletedClaimHistoryUsesTheHistoryAttachmentPolicyForBothEvidenceKinds() {
        Actor applicant=actor("retained-attachment"),foreign=actor("retained-attachment-other");
        login(applicant,"expense:apply","attachment:view");
        var draft=claims.create(request("保留有凭证的草稿",null));
        // Metadata fixture only; real file-byte verification lives in AttachmentRetainedHistoryPostgresTest.
        UUID evidence=attachment(draft.id()),proof=attachment(draft.id(),"EXPENSE_PAYMENT_PROOF");
        claims.delete(draft.id(),draft.version());
        var history=claims.detailHistory(draft.id());
        assertThat(history.attachments()).extracting(com.uten.imp.features.attachment.dto.AttachmentDto::id).containsExactly(evidence);
        assertThat(history.paymentProofs()).extracting(com.uten.imp.features.attachment.dto.AttachmentDto::id).containsExactly(proof);
        assertThat(history.attachments()).allSatisfy(row->assertThat(row.historyReadOnly()).isTrue());
        assertThat(history.paymentProofs()).allSatisfy(row->assertThat(row.historyReadOnly()).isTrue());
        login(foreign,"expense:apply","attachment:view");
        assertThatThrownBy(()->claims.detailHistory(draft.id())).isInstanceOf(ApiException.class);
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
