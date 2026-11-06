package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.finance.FinancialJsonResults;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.*;
import com.uten.imp.features.finance.receipt.*;
import com.uten.imp.features.finance.receipt.dto.*;
import com.uten.imp.features.finance.payment.*;
import com.uten.imp.features.finance.payment.dto.*;
import com.uten.imp.features.finance.expense.*;
import com.uten.imp.features.finance.expense.dto.*;
import com.uten.imp.features.finance.other_income.*;
import com.uten.imp.features.finance.other_income.dto.*;
import com.uten.imp.features.finance.bank_transfer.*;
import com.uten.imp.features.finance.bank_transfer.dto.*;
import com.uten.imp.features.documents.DocumentUnapprovalService;
import com.uten.imp.application.port.FinancialDocumentUnapprovalCommandPort.Command;
import com.uten.imp.common.platformcolumns.*;
import com.uten.imp.security.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.*;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.transaction.support.TransactionTemplate;
import java.math.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Real current-schema documents, original lock order and actual cash/GL/AP
 * transitions. A class-owned clone avoids policy/opening contamination. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
 "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
 "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
 "uten.inventory.value-work.enabled=false","uten.workshop-material.auto-close.enabled=false",
 "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
 "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
 "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
 "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
 "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@FinanceScopedChain
class FinanceDocumentReviewCommandsPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FinanceScopedChainDatabase.register(registry,FinanceDocumentReviewCommandsPostgresTest.class);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper json;
    @Autowired TransactionTemplate transaction;
    @Autowired jakarta.persistence.EntityManagerFactory entityManagers;
    @MockitoSpyBean(name="dataSource") javax.sql.DataSource dataSource;
    @Autowired TxSessionVars variables;
    @Autowired FinanceDocumentActions actions;
    @Autowired FinanceReceiptService receipts;
    @MockitoSpyBean FinanceReceiptUnapprovalAdapter receiptAdapter;
    @Autowired FinancePaymentService payments;
    @MockitoSpyBean FinanceExpenseService expenses;
    @Autowired FinanceOtherIncomeService incomes;
    @Autowired FinanceBankTransferService transfers;
    @MockitoSpyBean FinanceOperationJournal journal;
    @Autowired DocumentUnapprovalService unapproval;
    @Autowired PlatformColumnService fields;
    @Autowired com.uten.imp.features.attachment.AttachmentService attachments;
    @Autowired com.uten.imp.features.finance.gl.NativeFinancialPostingAccountService nativeAccounts;
    @Autowired com.uten.imp.features.finance.statement.FinanceAuxiliaryService auxiliaries;
    @Autowired com.uten.imp.features.stock.valuation.InventoryValueWorkService inventoryWork;
    @Autowired com.uten.imp.features.sales.order.SalesOrderService salesOrders;
    @Autowired com.uten.imp.features.sales.SalesManagerReviewService salesManagers;
    @Autowired com.uten.imp.features.common.taskclaim.TaskClaimService claims;
    @MockitoSpyBean com.uten.imp.features.notice.NoticeService notices;
    private FullChainEndToEndTest harness;
    private FinanceUnapprovalEligibilityEndToEndTest factory;
    private FinanceUnapprovalEligibilityEndToEndTest.Fixture f;
    private record Draft(String family,UUID id,Object request) { }
    private static final Map<String,String> TABLES=Map.of("financeReceipt","finance_receipts","financePayment","finance_payments","financeExpense","finance_expenses","financeOtherIncome","finance_other_incomes","financeBankTransfer","finance_bank_transfers");
    private static final Map<String,String> SEGMENTS=Map.of("financeReceipt","receipts","financePayment","payments","financeExpense","expenses","financeOtherIncome","incomes","financeBankTransfer","bank-transfers");

    @BeforeEach void setup(){
        factory=new FinanceUnapprovalEligibilityEndToEndTest();beans.autowireBean(factory);factory.prepare();
        f=factory.fixture("rv-"+UUID.randomUUID().toString().substring(0,8));
        // Reuse the actual world-owning fixture, including its established
        // planner identity, rather than an unseeded second harness instance.
        harness=(FullChainEndToEndTest)org.springframework.test.util.ReflectionTestUtils.getField(factory,"harness");
        assertThat(harness).isNotNull();
    }
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void anActualPendingFinanceNoticeRetainsItsHeaderLockAndTheSameOwnerCanClaimAfterDeliveryCommits()throws Exception{
        harness.loginAs(f.world().superAdminUserId());
        UUID finance=harness.createUserWithPerms(f.world(),"notice-claim-owner-"+UUID.randomUUID(),
                "notice:read","sales_order_finance:view","sales_order_finance:confirm");
        var preview=transaction.execute(status->beans.getBean(com.uten.imp.features.sales.SalesPriceAuthority.class)
                .loadMasterPrices(List.of(f.world().goodsD())).get(f.world().goodsD()));
        assertThat(preview).isNotNull();
        var input=harness.orderRequest(f.world(),f.world().goodsD(),"1",preview.toPlainString());input.setBillDate(BusinessTime.today());
        UUID order=salesOrders.create(input).getId();
        var entered=new CountDownLatch(1);var release=new CountDownLatch(1);var once=new AtomicBoolean();
        com.uten.imp.features.notice.NoticeService noticeTarget=org.springframework.test.util.AopTestUtils.getUltimateTargetObject(notices);
        doAnswer(call->{
            if(Thread.currentThread().getName().equals("business-outbox-dispatch")&&once.compareAndSet(false,true)){
                entered.countDown();
                if(!release.await(20,TimeUnit.SECONDS))throw new AssertionError("The original notice lock must be released by this test");
            }
            return call.callRealMethod();
        }).when(noticeTarget).publishForUser(eq(finance),anyString(),anyString(),anyString(),anyString(),anyString(),
                eq("SALES_ORDER_PENDING_FINANCE_CONFIRM"),nullable(String.class),eq(order));
        try{
            salesOrders.approve(order);
            com.uten.imp.support.SalesManagerReviewFixtures.approveOrderForFinance(db,claims,salesManagers,order,0L);
            assertThat(entered.await(10,TimeUnit.SECONDS)).isTrue();
            UUID event=db.queryForObject("SELECT id FROM business_outbox WHERE event_type='SALES_ORDER_PENDING_FINANCE_CONFIRM' AND aggregate_type='SALES_ORDER' AND aggregate_id=? AND created_by=?",UUID.class,order,f.world().superAdminUserId());
            assertThat(db.queryForObject("SELECT status=0 AND processed_at IS NULL FROM business_outbox WHERE id=?",Boolean.class,event)).isTrue();
            String original=db.queryForObject("SELECT to_jsonb(o)::text FROM sales_orders o WHERE id=?",String.class,order);
            harness.loginAs(finance);
            assertThatThrownBy(()->claims.claim("SALES_ORDER_FINANCE_CONFIRM",order.toString())).satisfies(error->{
                var cause=org.springframework.core.NestedExceptionUtils.getMostSpecificCause(error);
                assertThat(cause).isInstanceOf(java.sql.SQLException.class);
                assertThat(((java.sql.SQLException)cause).getSQLState()).isEqualTo("55P03");
            });
            assertThat(db.queryForObject("SELECT count(*) FROM task_claims WHERE target_type='SALES_ORDER_FINANCE_CONFIRM' AND target_key=?",Integer.class,order.toString())).isZero();
            assertThat(db.queryForObject("SELECT to_jsonb(o)::text FROM sales_orders o WHERE id=?",String.class,order)).isEqualTo(original);
            release.countDown();
            assertThat(com.uten.imp.support.SalesPrepaymentOrderFixture.awaitPendingFinanceNotice(db,order,f.world().superAdminUserId())).isEqualTo(event);
            var acquired=claims.claim("SALES_ORDER_FINANCE_CONFIRM",order.toString());
            assertThat(claims.claim("SALES_ORDER_FINANCE_CONFIRM",order.toString()).claimId()).isEqualTo(acquired.claimId());
            assertThat(db.queryForObject("SELECT count(*) FROM task_claims WHERE target_type='SALES_ORDER_FINANCE_CONFIRM' AND target_key=? AND released_at IS NULL",Integer.class,order.toString())).isEqualTo(1);
            assertThat(db.queryForObject("SELECT to_jsonb(o)::text FROM sales_orders o WHERE id=?",String.class,order)).isEqualTo(original);
            assertThat(db.queryForObject("SELECT finance_confirmed FROM sales_orders WHERE id=?",Boolean.class,order)).isFalse();
        }finally{
            release.countDown();
            doCallRealMethod().when(noticeTarget).publishForUser(eq(finance),anyString(),anyString(),anyString(),anyString(),anyString(),
                    eq("SALES_ORDER_PENDING_FINANCE_CONFIRM"),nullable(String.class),eq(order));
        }
    }

    @ParameterizedTest @ValueSource(strings={"financeReceipt","financePayment","financeExpense","financeOtherIncome","financeBankTransfer"})
    void changedAndAbaDraftsCannotBeApprovedWithTheEarlierDisplayedSnapshot(String family){
        Draft d=create(family,"10");FinanceReviewMetadata shown=review(d);
        if(family.equals("financeReceipt")||family.equals("financePayment"))assertThat(shown.getApprovalVersion()).isNotNull();else assertThat(shown.getApprovalVersion()).isNull();
        var command=command(shown);mutate(d,"20");harness.loginAs(f.reviewer());String before=moneyFacts(d);
        conflict(()->actions.approve(family,d.id(),command));assertThat(moneyFacts(d)).isEqualTo(before);assertThat(receiptCount(command.requestId())).isZero();
        mutate(d,"10");harness.loginAs(f.reviewer());before=moneyFacts(d);
        conflict(()->actions.approve(family,d.id(),command));assertThat(moneyFacts(d)).isEqualTo(before);
        assertThat(review(d).getApprovalSnapshot()).isNotEqualTo(shown.getApprovalSnapshot());
    }

    @ParameterizedTest @ValueSource(strings={"financeReceipt","financePayment","financeExpense","financeOtherIncome","financeBankTransfer"})
    void ownApprovedAndUnapprovedReceiptsSurviveLostRepliesAndNeverRepeatMoneyOrCreateAnotherSuccessor(String family){
      for(boolean generic:new boolean[]{false,true}){
        Draft d=create(family,"10");var original=command(review(d));var approved=approveHttp(d,original);
        assertThat(approved).containsEntry("outcome","SUCCEEDED");String posted=moneyFacts(d);
        assertThat(businessAudits(d,"approve")).isEqualTo(1);
        same(approveHttp(d,original),approved);same(actions.receipt(family,d.id(),original.requestId()),approved);
        assertThat(moneyFacts(d)).isEqualTo(posted);assertThat(receiptCount(original.requestId())).isEqualTo(1);
        assertThat(businessAudits(d,"approve")).isEqualTo(1);
        var capability=unapproval.capabilityHttp(family,d.id());assertThat(capability.eligible()).as(capability.reasons().toString()).isTrue();
        UUID reverseId=UUID.randomUUID();var reverse=new Command(reverseId,reverseId.toString(),"匿名本人明确核对后反审原代次",capability.factsSnapshot());
        var reversed=reverseHttp(d,reverse,generic);assertThat(reversed).containsEntry("outcome","SUCCEEDED");
        String reversePath=generic?unapprovePath(d):"/finance/"+SEGMENTS.get(family)+"/"+d.id()+"/reverse";
        assertThat(reversed).containsEntry("path",reversePath);assertThat(businessAudits(d,"reverse")).isEqualTo(1);
        UUID successor=UUID.fromString(map(reversed.get("result")).get("id").toString());
        assertThat(map(reversed.get("result")).get("unapprovalOriginalId").toString()).isEqualTo(d.id().toString());
        String undone=moneyFacts(d);same(reverseHttp(d,reverse,generic),reversed);same(actions.receipt(family,d.id(),reverseId),reversed);
        same(actions.cancel(family,d.id(),reverseId,cancellation(reverseId,"FINANCE_DOCUMENT_UNAPPROVE",reversePath,reverse)),reversed);
        assertThat(businessAudits(d,"reverse")).isEqualTo(1);assertThat(businessAudits(d,"approve")).isEqualTo(1);
        assertThat(db.queryForList("SELECT DISTINCT actor_id FROM v_audit_log_all WHERE action IN (?,?) AND target_type=? AND target_id=?",UUID.class,permission(d)+"_approve",permission(d)+"_reverse",permission(d),d.id().toString())).containsExactly(f.reviewer());
        assertThat(moneyFacts(d)).isEqualTo(undone);
        assertThat(db.queryForObject("SELECT count(*) FROM document_unapprovals WHERE family=? AND original_id=?",Integer.class,family,d.id())).isEqualTo(1);
        assertThat(db.queryForObject("SELECT status FROM "+TABLES.get(family)+" WHERE id=?",Integer.class,successor)).isZero();
      }
    }

    @Test void xminRejectsAbaEvenWhenEveryOrdinaryHeaderAndLineValueAndTimestampIsRestored(){
        Draft d=create("financeExpense","10");var shown=review(d);var request=command(shown);
        String head=header(d),lines=db.queryForObject("SELECT jsonb_agg(to_jsonb(l) ORDER BY id)::text FROM finance_expense_items l WHERE expense_id=?",String.class,d.id());
        var dates=db.queryForMap("SELECT h.updated_at header_time,l.updated_at line_time,h.amount_original header_original,h.amount_local header_local,l.amount_original line_original,l.amount_local line_local FROM finance_expenses h JOIN finance_expense_items l ON l.expense_id=h.id WHERE h.id=?",d.id());
        harness.loginAs(f.world().superAdminUserId());
        for(String amount:List.of("20","10"))transaction.executeWithoutResult(status->{variables.bind();
            boolean restore=amount.equals("10");
            db.update("UPDATE finance_expense_items SET amount_original=?,amount_local=?,updated_at=? WHERE expense_id=?",restore?dates.get("line_original"):n(amount),restore?dates.get("line_local"):n(amount),dates.get("line_time"),d.id());
            db.update("UPDATE finance_expenses SET amount_original=?,amount_local=?,updated_at=? WHERE id=?",restore?dates.get("header_original"):n(amount),restore?dates.get("header_local"):n(amount),dates.get("header_time"),d.id());
        });
        assertThat(header(d)).isEqualTo(head);assertThat(db.queryForObject("SELECT jsonb_agg(to_jsonb(l) ORDER BY id)::text FROM finance_expense_items l WHERE expense_id=?",String.class,d.id())).isEqualTo(lines);
        harness.loginAs(f.reviewer());String before=moneyFacts(d);conflict(()->actions.approve(d.family(),d.id(),request));assertThat(moneyFacts(d)).isEqualTo(before);
    }

    @Test void detailAndApprovalProofShareOneRepeatableReadViewWhenAnotherActorEditsBetweenThem()throws Exception{
        Draft d=create("financeExpense","10");var earlier=review(d);var entered=new CountDownLatch(1);var release=new CountDownLatch(1);var once=new AtomicBoolean();
        FinanceExpenseService expenseTarget=org.springframework.test.util.AopTestUtils.getUltimateTargetObject(expenses);
        doAnswer(invocation->{Object result=invocation.callRealMethod();if(Thread.currentThread().getName().equals("review-reader")&&once.compareAndSet(false,true)){entered.countDown();await(release);}return result;}).when(expenseTarget).detail(d.id());
        ExecutorService worker=Executors.newSingleThreadExecutor(r->new Thread(r,"review-reader"));
        try{
            var reading=worker.submit(()->{harness.loginAs(f.reviewer());try{return actions.<FinanceExpenseDetail>reviewedDetail(d.family(),d.id(),false);}finally{SecurityContextHolder.clearContext();}});
            assertThat(entered.await(20,TimeUnit.SECONDS)).isTrue();mutate(d,"20");release.countDown();var shown=reading.get(30,TimeUnit.SECONDS);
            assertThat(shown.getAmountOriginal()).isEqualByComparingTo("10");assertThat(shown.getApprovalSnapshot()).isEqualTo(earlier.getApprovalSnapshot());
            harness.loginAs(f.reviewer());conflict(()->actions.approve(d.family(),d.id(),command(shown)));
        }finally{release.countDown();worker.shutdownNow();doCallRealMethod().when(expenseTarget).detail(d.id());}
    }

    @Test void platformValueAbaAndARealNewAttachmentInvalidateTheEarlierProofWithoutMoneyChanges(){
        Draft d=create("financeExpense","10");harness.loginAs(f.world().superAdminUserId());
        UUID line=db.queryForObject("SELECT id FROM finance_expense_items WHERE expense_id=?",UUID.class,d.id());
        var definition=fields.create("finance_expense_item",new PlatformColumnContracts.CreateDefinition("匿名审核依据","TEXT",false,null));
        fields.write("finance_expense_item",line,new PlatformColumnContracts.Write(0,List.of(new PlatformColumnContracts.CellInput(definition.id(),"A"))));
        var shown=review(d);var original=command(shown);String head=header(d);
        harness.loginAs(f.world().superAdminUserId());
        fields.write("finance_expense_item",line,new PlatformColumnContracts.Write(1,List.of(new PlatformColumnContracts.CellInput(definition.id(),"B"))));
        fields.write("finance_expense_item",line,new PlatformColumnContracts.Write(2,List.of(new PlatformColumnContracts.CellInput(definition.id(),"A"))));
        assertThat(header(d)).isEqualTo(head);harness.loginAs(f.reviewer());String before=moneyFacts(d);conflict(()->actions.approve(d.family(),d.id(),original));assertThat(moneyFacts(d)).isEqualTo(before);
        var platformShown=actions.<FinanceExpenseDetail>reviewedDetail(d.family(),d.id(),false);
        assertThat(platformShown.getApprovalPlatformFields().get("finance_expense_item").getFirst().cells().getFirst().value()).isEqualTo("A");
        harness.loginAs(f.world().superAdminUserId());
        byte[] bytes=Base64.getDecoder().decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=");
        var upload=attachments.presign(new com.uten.imp.features.attachment.dto.AttachmentPresignRequest("FINANCE_EXPENSE",d.id(),"anonymous-review.png","image/png",(long)bytes.length));
        attachments.storeRaw(upload.storageKey(),upload.confirmToken(),new java.io.ByteArrayInputStream(bytes),bytes.length,"image/png");
        attachments.confirm(new com.uten.imp.features.attachment.dto.AttachmentConfirmRequest(upload.storageKey(),upload.confirmToken(),"FINANCE_EXPENSE",d.id(),"anonymous-review.png","image/png",(long)bytes.length,null,null));
        harness.loginAs(f.reviewer());before=moneyFacts(d);conflict(()->actions.approve(d.family(),d.id(),command(platformShown)));assertThat(moneyFacts(d)).isEqualTo(before);
    }

    @Test void receiptInsertFailureRollsBackActualApprovalAndTheSameOriginalRequestCanThenCommitOnce(){
        Draft d=create("financeExpense","10");var original=command(review(d));String before=moneyFacts(d);
        com.uten.imp.support.PostgresFixtureDdl.execute(db,"CREATE FUNCTION fixture_reject_review_receipt() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.request_id=%L::uuid THEN RAISE EXCEPTION 'anonymous review receipt failure';END IF;RETURN NEW;END;$$;CREATE TRIGGER fixture_reject_review_receipt BEFORE INSERT ON finance_application_operations FOR EACH ROW EXECUTE FUNCTION fixture_reject_review_receipt()",original.requestId());
        try{assertThatThrownBy(()->approveHttp(d,original)).hasMessageContaining("review receipt failure");assertThat(moneyFacts(d)).isEqualTo(before);assertThat(receiptCount(original.requestId())).isZero();assertThat(businessAudits(d,"approve")).isZero();}
        finally{db.execute("DROP TRIGGER fixture_reject_review_receipt ON finance_application_operations;DROP FUNCTION fixture_reject_review_receipt()");}
        var saved=approveHttp(d,original);same(approveHttp(d,original),saved);same(actions.receipt(d.family(),d.id(),original.requestId()),saved);assertThat(businessAudits(d,"approve")).isEqualTo(1);
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void unapprovalReceiptFailureRollsBackItsActualBusinessAuditWithMoneyAndSuccessor(boolean generic){
        Draft d=create("financeExpense","10");var approval=command(review(d));approveHttp(d,approval);
        var capability=unapproval.capabilityHttp(d.family(),d.id());UUID id=UUID.randomUUID();
        var original=new Command(id,id.toString(),"匿名核对反审事务审计",capability.factsSnapshot());String before=moneyFacts(d);
        com.uten.imp.support.PostgresFixtureDdl.execute(db,"CREATE FUNCTION fixture_reject_reverse_receipt() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.request_id=%L::uuid THEN RAISE EXCEPTION 'anonymous reverse receipt failure';END IF;RETURN NEW;END;$$;CREATE TRIGGER fixture_reject_reverse_receipt BEFORE INSERT ON finance_application_operations FOR EACH ROW EXECUTE FUNCTION fixture_reject_reverse_receipt()",id);
        try{
            assertThatThrownBy(()->reverseHttp(d,original,generic)).hasMessageContaining("reverse receipt failure");
            assertThat(moneyFacts(d)).isEqualTo(before);assertThat(receiptCount(id)).isZero();assertThat(businessAudits(d,"reverse")).isZero();assertThat(businessAudits(d,"approve")).isEqualTo(1);
            assertThat(db.queryForObject("SELECT count(*) FROM document_unapprovals WHERE family=? AND original_id=?",Integer.class,d.family(),d.id())).isZero();
        }finally{db.execute("DROP TRIGGER fixture_reject_reverse_receipt ON finance_application_operations;DROP FUNCTION fixture_reject_reverse_receipt()");}
        var saved=reverseHttp(d,original,generic);String after=moneyFacts(d);same(reverseHttp(d,original,generic),saved);same(actions.receipt(d.family(),d.id(),id),saved);
        assertThat(moneyFacts(d)).isEqualTo(after);assertThat(receiptCount(id)).isEqualTo(1);assertThat(businessAudits(d,"reverse")).isEqualTo(1);
    }

    @Test void glConfirmationKeepsItsOriginalPrecisionReceiptAfterLostReplyAndLaterReferenceChangesAndAuditsOnlyOnce()throws Exception{
        harness.loginAs(f.world().superAdminUserId());var input=factory.expense(f,"10.123456789012345678901234");input.getItems().getFirst().setDepartmentId(f.world().departmentId());
        Draft d=new Draft("financeExpense",expenses.create(input).getId(),input);actions.approve(d.family(),d.id(),command(review(d)));
        UUID actor=confirmationActor();harness.loginAs(actor);var original=command(actions.reviewedDetail(d.family(),d.id(),false));assertThat(original.expectedVersion()).isNull();String facts=confirmationMoney(d);
        var down=Map.of("anonymous.gl.confirm.intent",new BusinessPrecisionContext.Choice(24,"DOWN"));var up=Map.of("anonymous.gl.confirm.intent",new BusinessPrecisionContext.Choice(24,"HALF_UP"));Map<String,Object> saved;
        try(var precision=BusinessPrecisionContext.use(down)){saved=actions.glConfirm(d.id(),original);}
        assertThat(saved).containsEntry("outcome","SUCCEEDED").containsEntry("operation","FINANCE_DOCUMENT_GL_CONFIRM");assertThat(map(saved.get("result"))).containsEntry("status",1).containsEntry("glStatus",2);
        same(map(saved.get("precisionContext")).get("choices"),down);assertThat(map(map(saved.get("precisionContext")).get("usedChoices"))).isEmpty();
        assertThat(confirmationMoney(d)).isEqualTo(facts);assertThat(confirmationAudits(d)).isEqualTo(1);assertThat(receiptCount(original.requestId())).isEqualTo(1);
        harness.loginAs(f.world().superAdminUserId());db.update("UPDATE departments SET name=? WHERE id=?","匿名后续名称-"+UUID.randomUUID(),f.world().departmentId());
        assertThat(actions.receipt(d.family(),d.id(),original.requestId())).containsEntry("found",false);
        loginConfirmationReader(actor);same(actions.receipt(d.family(),d.id(),original.requestId()),saved);same(actions.cancel(d.family(),d.id(),original.requestId(),confirmationCancellation(d,actor,original,down)),saved);forbidden(()->actions.glConfirm(d.id(),original));
        harness.loginAs(actor);try(var precision=BusinessPrecisionContext.use(up)){conflict(()->actions.glConfirm(d.id(),original));}
        try(var precision=BusinessPrecisionContext.use(down)){same(actions.glConfirm(d.id(),original),saved);}
        assertThat(confirmationAudits(d)).isEqualTo(1);assertThat(confirmationMoney(d)).isEqualTo(facts);
        harness.loginAs(f.reviewer());assertThatThrownBy(()->expenses.reverse(d.id())).isInstanceOf(ApiException.class).hasMessageContaining("不提供撤销确认或红冲入口");
        assertThat(db.queryForObject("SELECT gl_status FROM finance_expenses WHERE id=?",Integer.class,d.id())).isEqualTo(2);
    }

    @Test void glConfirmationRejectsTheEarlierLockedGenerationAndReceiptFailureRollsBackConfirmationAndAuditTogether(){
        Draft d=create("financeExpense","10");actions.approve(d.family(),d.id(),command(review(d)));UUID actor=confirmationActor();harness.loginAs(actor);
        var stale=command(actions.reviewedDetail(d.family(),d.id(),false));String facts=confirmationMoney(d);
        transaction.executeWithoutResult(status->{variables.bind();db.update("UPDATE finance_expenses SET updated_at=updated_at WHERE id=?",d.id());});
        conflict(()->actions.glConfirm(d.id(),stale));assertThat(receiptCount(stale.requestId())).isZero();assertThat(confirmationAudits(d)).isZero();assertThat(confirmationMoney(d)).isEqualTo(facts);
        var current=command(actions.reviewedDetail(d.family(),d.id(),false));
        com.uten.imp.support.PostgresFixtureDdl.execute(db,"CREATE FUNCTION fixture_reject_gl_confirm_receipt() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.request_id=%L::uuid THEN RAISE EXCEPTION 'anonymous GL confirmation receipt failure';END IF;RETURN NEW;END;$$;CREATE TRIGGER fixture_reject_gl_confirm_receipt BEFORE INSERT ON finance_application_operations FOR EACH ROW EXECUTE FUNCTION fixture_reject_gl_confirm_receipt()",current.requestId());
        try{assertThatThrownBy(()->actions.glConfirm(d.id(),current)).hasMessageContaining("GL confirmation receipt failure");assertThat(receiptCount(current.requestId())).isZero();assertThat(confirmationAudits(d)).isZero();assertThat(db.queryForObject("SELECT gl_status FROM finance_expenses WHERE id=?",Integer.class,d.id())).isEqualTo(1);}
        finally{db.execute("DROP TRIGGER fixture_reject_gl_confirm_receipt ON finance_application_operations;DROP FUNCTION fixture_reject_gl_confirm_receipt()");}
        var saved=actions.glConfirm(d.id(),current);same(actions.receipt(d.family(),d.id(),current.requestId()),saved);assertThat(confirmationAudits(d)).isEqualTo(1);assertThat(confirmationMoney(d)).isEqualTo(facts);
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void glConfirmationAndUnwrittenCancellationSerializeInBothOrdersWithoutRepeatedMoneyOrAudit(boolean cancelFirst)throws Exception{
        Draft d=create("financeExpense","10");actions.approve(d.family(),d.id(),command(review(d)));UUID actor=confirmationActor();harness.loginAs(actor);var original=command(actions.reviewedDetail(d.family(),d.id(),false));var cancel=confirmationCancellation(d,actor,original,Map.of());String facts=confirmationMoney(d);
        var entered=new CountDownLatch(1);var release=new CountDownLatch(1);var once=new AtomicBoolean();var pool=Executors.newFixedThreadPool(2);
        doAnswer(invocation->{Object result=invocation.callRealMethod();if(once.compareAndSet(false,true)){entered.countDown();await(release);}return result;}).when(journal).execute(isNull(),eq(original.requestId()),eq("FINANCE_DOCUMENT_GL_CONFIRM"),any(),any(),any());
        try{
            var first=pool.submit(()->{harness.loginAs(actor);try{return cancelFirst?actions.cancel(d.family(),d.id(),original.requestId(),cancel):actions.glConfirm(d.id(),original);}finally{SecurityContextHolder.clearContext();}});
            assertThat(entered.await(20,TimeUnit.SECONDS)).isTrue();assertThat(actions.receipt(d.family(),d.id(),original.requestId())).containsEntry("found",false);
            var second=pool.submit(()->{harness.loginAs(actor);try{return cancelFirst?actions.glConfirm(d.id(),original):actions.cancel(d.family(),d.id(),original.requestId(),cancel);}finally{SecurityContextHolder.clearContext();}});
            org.awaitility.Awaitility.await().atMost(java.time.Duration.ofSeconds(10)).until(()->db.queryForObject("SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND NOT granted",Long.class)>0);assertThat(second.isDone()).isFalse();release.countDown();
            var saved=first.get(30,TimeUnit.SECONDS);same(second.get(30,TimeUnit.SECONDS),saved);assertThat(saved).containsEntry("outcome",cancelFirst?"CANCELLED_UNWRITTEN":"SUCCEEDED");assertThat(receiptCount(original.requestId())).isEqualTo(1);
            assertThat(db.queryForObject("SELECT gl_status FROM finance_expenses WHERE id=?",Integer.class,d.id())).isEqualTo(cancelFirst?1:2);assertThat(confirmationAudits(d)).isEqualTo(cancelFirst?0:1);assertThat(confirmationMoney(d)).isEqualTo(facts);
        }finally{release.countDown();pool.shutdownNow();doCallRealMethod().when(journal).execute(isNull(),eq(original.requestId()),eq("FINANCE_DOCUMENT_GL_CONFIRM"),any(),any(),any());}
    }

    @Test void glConfirmationCancellationNeedsOriginalOwnerBodyAndReadScopeAndCanRetireAfterWritePermissionLoss(){
        Draft d=create("financeExpense","10");actions.approve(d.family(),d.id(),command(review(d)));UUID actor=confirmationActor();harness.loginAs(actor);var original=command(actions.reviewedDetail(d.family(),d.id(),false));var cancel=confirmationCancellation(d,actor,original,Map.of());
        var wrong=new FinanceDocumentActions.ApprovalCommand(original.requestId(),null,"a".repeat(64));
        var stopped=actions.cancel(d.family(),d.id(),original.requestId(),cancel);assertThat(stopped).containsEntry("outcome","CANCELLED_UNWRITTEN");
        conflict(()->actions.cancel(d.family(),d.id(),original.requestId(),confirmationCancellation(d,actor,wrong,Map.of())));
        loginConfirmationReader(actor);same(actions.receipt(d.family(),d.id(),original.requestId()),stopped);same(actions.cancel(d.family(),d.id(),original.requestId(),cancel),stopped);forbidden(()->actions.glConfirm(d.id(),original));
        harness.loginAs(actor);same(actions.glConfirm(d.id(),original),stopped);assertThat(confirmationAudits(d)).isZero();assertThat(db.queryForObject("SELECT gl_status FROM finance_expenses WHERE id=?",Integer.class,d.id())).isEqualTo(1);
        harness.loginAs(f.world().superAdminUserId());assertThat(actions.receipt(d.family(),d.id(),original.requestId())).containsEntry("found",false);forbidden(()->actions.cancel(d.family(),d.id(),original.requestId(),cancel));
        UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,actor);var noRead=new AuthUser(actor,employee,"anonymous-confirm-no-read",Set.of(),false,true,false);SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(noRead,"",noRead.getAuthorities()));forbidden(()->actions.receipt(d.family(),d.id(),original.requestId()));forbidden(()->actions.cancel(d.family(),d.id(),original.requestId(),cancel));
    }
    @Test void nativeClosedFlagDoesNotHideARequiredPendingGlConfirmationSnapshot(){
        Draft d=create("financeExpense","10");actions.approve(d.family(),d.id(),command(review(d)));
        harness.loginAs(f.world().superAdminUserId());transaction.executeWithoutResult(status->{variables.bind();db.update("UPDATE finance_expenses SET is_closed=true WHERE id=?",d.id());});
        UUID actor=confirmationActor();harness.loginAs(actor);FinanceExpenseDetail shown=actions.reviewedDetail(d.family(),d.id(),false);
        assertThat(shown.isClosed()).isTrue();assertThat(shown.isLegacyImported()).isFalse();assertThat(shown.isHistoryReadOnly()).isFalse();assertThat(shown.getApprovalSnapshot()).matches("[a-f0-9]{64}");
        var original=command(shown);String facts=confirmationMoney(d);assertThat(actions.glConfirm(d.id(),original)).containsEntry("outcome","SUCCEEDED");
        assertThat(db.queryForObject("SELECT gl_status FROM finance_expenses WHERE id=?",Integer.class,d.id())).isEqualTo(2);assertThat(confirmationMoney(d)).isEqualTo(facts);assertThat(confirmationAudits(d)).isEqualTo(1);
    }

    @ParameterizedTest @ValueSource(strings={"financeReceipt","financePayment","financeExpense","financeOtherIncome","financeBankTransfer"})
    void draftDeletionRejectsChangedAndAbaViewsAndItsOriginalSuccessStaysReadableAfterDeletion(String family){
        Draft d=create(family,"10");var original=command(makerReview(d));mutate(d,"20");String facts=moneyFacts(d);
        conflict(()->actions.delete(family,d.id(),original));assertThat(moneyFacts(d)).isEqualTo(facts);assertThat(receiptCount(original.requestId())).isZero();
        mutate(d,"10");conflict(()->actions.delete(family,d.id(),original));
        var fresh=command(makerReview(d));String money=deletionMoney(d);var saved=actions.delete(family,d.id(),fresh);
        assertThat(saved).containsEntry("outcome","SUCCEEDED");assertThat(map(saved.get("result"))).containsEntry("id",d.id().toString()).containsEntry("status",0).containsEntry("deleted",true);
        same(actions.delete(family,d.id(),fresh),saved);same(actions.receipt(family,d.id(),fresh.requestId()),saved);assertThat(deletionMoney(d)).isEqualTo(money);assertThat(deletionAudits(d)).isEqualTo(1);assertThat(receiptCount(fresh.requestId())).isEqualTo(1);
    }
    @ParameterizedTest @ValueSource(strings={"financeReceipt","financePayment","financeExpense","financeOtherIncome","financeBankTransfer"})
    void aReadOnlyOwnerCanRetireAnUnknownDeletionAndEveryLateOriginalLeavesTheDraftIntact(String family){
        Draft d=create(family,"10");var original=command(makerReview(d));var cancel=deletionCancellation(d,original,Map.of());String money=deletionMoney(d);
        loginDeletionReader(d);var stopped=actions.cancel(family,d.id(),original.requestId(),cancel);assertThat(stopped).containsEntry("outcome","CANCELLED_UNWRITTEN");same(actions.receipt(family,d.id(),original.requestId()),stopped);forbidden(()->actions.delete(family,d.id(),original));
        harness.loginAs(f.world().superAdminUserId());same(actions.delete(family,d.id(),original),stopped);assertThat(db.queryForObject("SELECT is_deleted FROM "+TABLES.get(family)+" WHERE id=?",Boolean.class,d.id())).isFalse();assertThat(deletionMoney(d)).isEqualTo(money);assertThat(deletionAudits(d)).isZero();
    }
    @ParameterizedTest @ValueSource(booleans={false,true})
    void deletionAndUnwrittenCancellationSerializeInBothOrdersWithOneAtomicBusinessAudit(boolean cancelFirst)throws Exception{
        Draft d=create("financeExpense","10");var original=command(makerReview(d));var cancel=deletionCancellation(d,original,Map.of());String money=deletionMoney(d);
        var entered=new CountDownLatch(1);var release=new CountDownLatch(1);var once=new AtomicBoolean();var pool=Executors.newFixedThreadPool(2);
        doAnswer(invocation->{Object result=invocation.callRealMethod();if(once.compareAndSet(false,true)){entered.countDown();await(release);}return result;}).when(journal).execute(isNull(),eq(original.requestId()),eq("FINANCE_DOCUMENT_DELETE"),any(),any(),any());
        try{
            var first=pool.submit(()->{harness.loginAs(f.world().superAdminUserId());try{return cancelFirst?actions.cancel(d.family(),d.id(),original.requestId(),cancel):actions.delete(d.family(),d.id(),original);}finally{SecurityContextHolder.clearContext();}});
            assertThat(entered.await(20,TimeUnit.SECONDS)).isTrue();assertThat(actions.receipt(d.family(),d.id(),original.requestId())).containsEntry("found",false);
            var second=pool.submit(()->{harness.loginAs(f.world().superAdminUserId());try{return cancelFirst?actions.delete(d.family(),d.id(),original):actions.cancel(d.family(),d.id(),original.requestId(),cancel);}finally{SecurityContextHolder.clearContext();}});
            org.awaitility.Awaitility.await().atMost(java.time.Duration.ofSeconds(10)).until(()->db.queryForObject("SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND NOT granted",Long.class)>0);assertThat(second.isDone()).isFalse();release.countDown();var saved=first.get(30,TimeUnit.SECONDS);same(second.get(30,TimeUnit.SECONDS),saved);
            assertThat(saved).containsEntry("outcome",cancelFirst?"CANCELLED_UNWRITTEN":"SUCCEEDED");assertThat(db.queryForObject("SELECT is_deleted FROM finance_expenses WHERE id=?",Boolean.class,d.id())).isEqualTo(!cancelFirst);assertThat(deletionAudits(d)).isEqualTo(cancelFirst?0:1);assertThat(deletionMoney(d)).isEqualTo(money);
        }finally{release.countDown();pool.shutdownNow();doCallRealMethod().when(journal).execute(isNull(),eq(original.requestId()),eq("FINANCE_DOCUMENT_DELETE"),any(),any(),any());}
    }
    @Test void deletionReceiptFailureRollsBackTheDraftAndItsAuditAndPrecisionCannotChangeAfterSuccess()throws Exception{
        Draft d=create("financeExpense","10");var original=command(makerReview(d));String money=moneyFacts(d);
        var down=Map.of("anonymous.delete.intent",new BusinessPrecisionContext.Choice(24,"DOWN"));var up=Map.of("anonymous.delete.intent",new BusinessPrecisionContext.Choice(24,"HALF_UP"));
        com.uten.imp.support.PostgresFixtureDdl.execute(db,"CREATE FUNCTION fixture_reject_deletion_receipt() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.request_id=%L::uuid THEN RAISE EXCEPTION 'anonymous deletion receipt failure';END IF;RETURN NEW;END;$$;CREATE TRIGGER fixture_reject_deletion_receipt BEFORE INSERT ON finance_application_operations FOR EACH ROW EXECUTE FUNCTION fixture_reject_deletion_receipt()",original.requestId());
        try(var precision=BusinessPrecisionContext.use(down)){assertThatThrownBy(()->actions.delete(d.family(),d.id(),original)).hasMessageContaining("deletion receipt failure");assertThat(moneyFacts(d)).isEqualTo(money);assertThat(deletionAudits(d)).isZero();assertThat(receiptCount(original.requestId())).isZero();}
        finally{db.execute("DROP TRIGGER fixture_reject_deletion_receipt ON finance_application_operations;DROP FUNCTION fixture_reject_deletion_receipt()");}
        Map<String,Object> saved;try(var precision=BusinessPrecisionContext.use(down)){saved=actions.delete(d.family(),d.id(),original);}assertThat(deletionAudits(d)).isEqualTo(1);same(actions.receipt(d.family(),d.id(),original.requestId()),saved);
        try(var precision=BusinessPrecisionContext.use(up)){conflict(()->actions.delete(d.family(),d.id(),original));same(actions.cancel(d.family(),d.id(),original.requestId(),deletionCancellation(d,original,down)),saved);conflict(()->actions.cancel(d.family(),d.id(),original.requestId(),deletionCancellation(d,original,up)));}
        assertThat(deletionAudits(d)).isEqualTo(1);
    }

    @Test void originalApprovalAndUnapprovalCanBeSealedWithReadRightsAndLateRequestsNeverTouchMoney(){
        Draft d=create("financeExpense","10");var original=command(review(d));var cancel=cancellation(original.requestId(),"FINANCE_DOCUMENT_APPROVE",approvePath(d),original);
        loginReadOnly();String before=moneyFacts(d);var stopped=actions.cancel(d.family(),d.id(),original.requestId(),cancel);
        assertThat(stopped).containsEntry("outcome","CANCELLED_UNWRITTEN");same(actions.receipt(d.family(),d.id(),original.requestId()),stopped);
        forbidden(()->actions.approve(d.family(),d.id(),original));harness.loginAs(f.reviewer());same(actions.approve(d.family(),d.id(),original),stopped);assertThat(moneyFacts(d)).isEqualTo(before);
        var fresh=command(review(d));actions.approve(d.family(),d.id(),fresh);var capability=unapproval.capabilityHttp(d.family(),d.id());UUID reverseId=UUID.randomUUID();
        var reverse=new Command(reverseId,reverseId.toString(),"匿名只封口原反审不另逆账",capability.factsSnapshot());
        var reverseCancel=cancellation(reverseId,"FINANCE_DOCUMENT_UNAPPROVE",unapprovePath(d),reverse);
        loginReadOnly();before=moneyFacts(d);var reverseStopped=actions.cancel(d.family(),d.id(),reverseId,reverseCancel);
        harness.loginAs(f.reviewer());same(actions.execute(d.family(),d.id(),reverse),reverseStopped);assertThat(moneyFacts(d)).isEqualTo(before);
        assertThat(db.queryForObject("SELECT count(*) FROM document_unapprovals WHERE original_id=?",Integer.class,d.id())).isZero();
    }

    @Test void preciseWholeDetailResultsSurviveSuccessReplayGetAndSuccessfulCancellationVerification()throws Exception{
        Draft d=create("financeExpense","10");harness.loginAs(f.reviewer());UUID id=UUID.randomUUID();
        var command=new FinanceDocumentActions.ApprovalCommand(id,null,"a".repeat(64));
        BigDecimal big=n("1234567890123456789012345678901234567890.123456789012345678901234"),tiny=n("0.000000000000000000000001");
        BigInteger integer=new BigInteger("12345678901234567890123456789012345678901234567890");
        Map<String,Object> saved=transaction.execute(status->{variables.bind();return journal.command(id,"FINANCE_DOCUMENT_APPROVE","POST",approvePath(d),command,()->Map.of("amountOriginal",big,"amountLocal",tiny,"longInteger",integer,"nested",Map.of("amount",big)));});
        var repeated=transaction.execute(status->{variables.bind();return journal.command(id,"FINANCE_DOCUMENT_APPROVE","POST",approvePath(d),command,()->{throw new AssertionError("Original result must not run twice");});});
        for(var result:List.of(saved,repeated,actions.receipt(d.family(),d.id(),id),actions.cancel(d.family(),d.id(),id,cancellation(id,"FINANCE_DOCUMENT_APPROVE",approvePath(d),command)))){
            var values=map(result.get("result"));assertThat(values.get("amountOriginal")).isInstanceOf(BigDecimal.class);assertThat((BigDecimal)values.get("amountOriginal")).isEqualByComparingTo(big);
            assertThat((BigDecimal)values.get("amountLocal")).isEqualByComparingTo(tiny);assertThat(values.get("longInteger")).isEqualTo(integer);
            assertThat((BigDecimal)map(values.get("nested")).get("amount")).isEqualByComparingTo(big);
            assertThat(FinancialJsonResults.tree(json,json.writeValueAsString(result)).path("result").path("amountOriginal").decimalValue()).isEqualByComparingTo(big);
        }
    }

    @ParameterizedTest @ValueSource(strings={"financeReceipt","financePayment","financeExpense","financeOtherIncome","financeBankTransfer"})
    void editsRequireTheActuallyDisplayedGenerationAndRetainOriginalBodyThroughCancelAndReplay(String family)throws Exception{
        Draft d=create(family,"10");var shown=makerReview(d);var original=updateCommand(d,"15",shown);mutate(d,"20");
        harness.loginAs(f.world().superAdminUserId());String before=moneyFacts(d);
        conflict(()->actions.update(family,d.id(),original));assertThat(moneyFacts(d)).isEqualTo(before);assertThat(receiptCount(original.requestId())).isZero();
        var stopped=actions.cancel(family,d.id(),original.requestId(),editCancellation(d,original));
        assertThat(stopped).containsEntry("outcome","CANCELLED_UNWRITTEN");same(actions.update(family,d.id(),original),stopped);assertThat(moneyFacts(d)).isEqualTo(before);
        var reviewedNow=makerReview(d);var fresh=updateCommand(d,"15",reviewedNow);assertThat(fresh.requestId()).isNotEqualTo(original.requestId());
        var saved=actions.update(family,d.id(),fresh);assertThat(saved).containsEntry("outcome","SUCCEEDED");
        same(map(saved.get("requestBody")).get("document"),fresh.document());
        mutate(d,"30");harness.loginAs(f.world().superAdminUserId());before=moneyFacts(d);
        same(actions.update(family,d.id(),fresh),saved);same(actions.receipt(family,d.id(),fresh.requestId()),saved);
        same(actions.cancel(family,d.id(),fresh.requestId(),editCancellation(d,fresh)),saved);assertThat(moneyFacts(d)).isEqualTo(before);
    }

    @Test void rawEditWireKeepsTwentyFourPlacesAndMissingVersusNullThroughActualWriteAndEveryReceipt()throws Exception{
        Draft d=create("financeExpense","10");var shown=makerReview(d);var original=updateCommand(d,"10.123456789012345678901234",shown);
        ((ObjectNode)original.document()).remove("remark");
        var parsed=FinancialJsonResults.value(json,json.writeValueAsString(original),FinanceDocumentActions.UpdateCommand.class);
        assertThat(parsed.document().path("items").get(0).path("amountOriginal").decimalValue()).isEqualByComparingTo("10.123456789012345678901234");
        var saved=actions.update(d.family(),d.id(),parsed);assertThat(db.queryForObject("SELECT amount_original FROM finance_expenses WHERE id=?",BigDecimal.class,d.id())).isEqualByComparingTo("10.123456789012345678901234");
        same(map(saved.get("requestBody")).get("document"),original.document());
        var cancelWire=FinancialJsonResults.value(json,json.writeValueAsString(editCancellation(d,original)),FinanceOperationJournal.Cancellation.class);
        same(actions.cancel(d.family(),d.id(),original.requestId(),cancelWire),saved);
        var changed=(ObjectNode)original.document().deepCopy();changed.putNull("remark");
        conflict(()->actions.update(d.family(),d.id(),new FinanceDocumentActions.UpdateCommand(original.requestId(),original.expectedVersion(),original.expectedSnapshot(),changed)));
        assertThatThrownBy(()->actions.cancel(d.family(),d.id(),original.requestId(),editCancellation(d,new FinanceDocumentActions.UpdateCommand(original.requestId(),original.expectedVersion(),original.expectedSnapshot(),changed)))).isInstanceOf(ApiException.class);
    }

    @Test void precisionIntentCannotChangeAfterSuccessAndCancelUsesFrozenChoicesRatherThanItsOwnHeader()throws Exception{
        Draft d=create("financeExpense","10");var command=command(review(d));String purpose="anonymous.review.divide";
        var down=Map.of(purpose,new BusinessPrecisionContext.Choice(2,"DOWN"));var up=Map.of(purpose,new BusinessPrecisionContext.Choice(2,"HALF_UP"));
        Map<String,Object> saved;
        try(var scope=BusinessPrecisionContext.use(down)){
            saved=transaction.execute(status->{variables.bind();return journal.command(command.requestId(),"FINANCE_DOCUMENT_APPROVE","POST",approvePath(d),command,()->Map.of("amount",BusinessPrecisionContext.divide(n("10"),n("3"),purpose,"匿名测试分配",24)));});
        }
        assertThat(map(saved.get("precisionContext"))).containsEntry("available",true);same(map(saved.get("precisionContext")).get("usedChoices"),down);
        try(var scope=BusinessPrecisionContext.use(up)){
            conflict(()->actions.approve(d.family(),d.id(),command));
            var proof=new FinanceOperationJournal.Cancellation(command.requestId(),f.reviewer(),"FINANCE_DOCUMENT_APPROVE","POST",approvePath(d),json.valueToTree(command),down);
            same(actions.cancel(d.family(),d.id(),command.requestId(),proof),saved);
            conflict(()->actions.cancel(d.family(),d.id(),command.requestId(),new FinanceOperationJournal.Cancellation(command.requestId(),f.reviewer(),"FINANCE_DOCUMENT_APPROVE","POST",approvePath(d),json.valueToTree(command),up)));
        }
        try(var scope=BusinessPrecisionContext.use(down)){same(actions.approve(d.family(),d.id(),command),saved);}
        same(actions.receipt(d.family(),d.id(),command.requestId()),saved);
        UUID missing=UUID.randomUUID();var negotiation=new FinanceDocumentActions.ApprovalCommand(missing,null,"a".repeat(64));
        assertThatThrownBy(()->transaction.execute(status->{variables.bind();return journal.command(missing,"FINANCE_DOCUMENT_APPROVE","POST",approvePath(d),negotiation,()->BusinessPrecisionContext.divide(n("10"),n("3"),purpose,"匿名显式选择",24));})).isInstanceOf(com.uten.imp.common.finance.BusinessPrecisionRequiredException.class);
        assertThat(receiptCount(missing)).isZero();
        try(var scope=BusinessPrecisionContext.use(down)){
            var resolved=transaction.execute(status->{variables.bind();return journal.command(missing,"FINANCE_DOCUMENT_APPROVE","POST",approvePath(d),negotiation,()->BusinessPrecisionContext.divide(n("10"),n("3"),purpose,"匿名显式选择",24));});
            same(map(resolved.get("precisionContext")).get("choices"),down);
        }
        var stoppedCommand=command(review(d));var frozen=new FinanceOperationJournal.Cancellation(stoppedCommand.requestId(),f.reviewer(),"FINANCE_DOCUMENT_APPROVE","POST",approvePath(d),json.valueToTree(stoppedCommand),down);
        try(var scope=BusinessPrecisionContext.use(up)){assertThat(actions.cancel(d.family(),d.id(),stoppedCommand.requestId(),frozen)).containsEntry("outcome","CANCELLED_UNWRITTEN");}
        try(var scope=BusinessPrecisionContext.use(down)){
            assertThat(actions.approve(d.family(),d.id(),stoppedCommand)).containsEntry("outcome","CANCELLED_UNWRITTEN");
            var fresh=command(review(d));assertThat(fresh.requestId()).isNotEqualTo(stoppedCommand.requestId());
            same(map(actions.approve(d.family(),d.id(),fresh).get("precisionContext")).get("choices"),down);
        }
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void actualApprovalAndUnwrittenCancellationSerializeInBothCommitOrders(boolean cancelFirst)throws Exception{
        Draft d=create("financeExpense","10");var original=command(review(d));var cancel=cancellation(original.requestId(),"FINANCE_DOCUMENT_APPROVE",approvePath(d),original);
        var entered=new CountDownLatch(1);var release=new CountDownLatch(1);var once=new AtomicBoolean();var pool=Executors.newFixedThreadPool(2);
        doAnswer(invocation->{Object result=invocation.callRealMethod();if(original.requestId().equals(invocation.getArgument(1))&&once.compareAndSet(false,true)){entered.countDown();await(release);}return result;})
            .when(journal).execute(isNull(),eq(original.requestId()),eq("FINANCE_DOCUMENT_APPROVE"),any(),any(),any());
        try{
            var first=pool.submit(()->{harness.loginAs(f.reviewer());try{return cancelFirst?actions.cancel(d.family(),d.id(),original.requestId(),cancel):actions.approve(d.family(),d.id(),original);}finally{SecurityContextHolder.clearContext();}});
            assertThat(entered.await(20,TimeUnit.SECONDS)).isTrue();harness.loginAs(f.reviewer());assertThat(actions.receipt(d.family(),d.id(),original.requestId())).containsEntry("found",false);
            var second=pool.submit(()->{harness.loginAs(f.reviewer());try{return cancelFirst?actions.approve(d.family(),d.id(),original):actions.cancel(d.family(),d.id(),original.requestId(),cancel);}finally{SecurityContextHolder.clearContext();}});
            org.awaitility.Awaitility.await().atMost(java.time.Duration.ofSeconds(10)).until(()->db.queryForObject("SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND NOT granted",Long.class)>0);
            assertThat(second.isDone()).isFalse();release.countDown();var result=first.get(30,TimeUnit.SECONDS);same(second.get(30,TimeUnit.SECONDS),result);
            assertThat(result).containsEntry("outcome",cancelFirst?"CANCELLED_UNWRITTEN":"SUCCEEDED");assertThat(receiptCount(original.requestId())).isEqualTo(1);
            assertThat(db.queryForObject("SELECT status FROM finance_expenses WHERE id=?",Integer.class,d.id())).isEqualTo(cancelFirst?0:1);
            assertThat(db.queryForObject("SELECT count(*) FROM finance_reconciliations WHERE source_doc_id=?",Integer.class,d.id())).isEqualTo(cancelFirst?0:1);
        }finally{release.countDown();pool.shutdownNow();doCallRealMethod().when(journal).execute(isNull(),eq(original.requestId()),eq("FINANCE_DOCUMENT_APPROVE"),any(),any(),any());}
    }

    @Test void receiptsAndCancellationKeepOwnerReadScopeAndRejectImpersonatedCancellationWithoutLeakingBodies(){
        Draft d=create("financeExpense","10");var original=command(review(d));var cancel=cancellation(original.requestId(),"FINANCE_DOCUMENT_APPROVE",approvePath(d),original);var saved=actions.approve(d.family(),d.id(),original);
        harness.loginAs(f.world().superAdminUserId());assertThat(actions.receipt(d.family(),d.id(),original.requestId())).containsEntry("found",false);forbidden(()->actions.cancel(d.family(),d.id(),original.requestId(),cancel));
        UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,f.reviewer());
        loginReadOnly();same(actions.receipt(d.family(),d.id(),original.requestId()),saved);same(actions.cancel(d.family(),d.id(),original.requestId(),cancel),saved);forbidden(()->actions.approve(d.family(),d.id(),original));
        var noRead=new AuthUser(f.reviewer(),employee,"anonymous-no-read",Set.of(),false,true,false);SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(noRead,"",noRead.getAuthorities()));
        forbidden(()->actions.receipt(d.family(),d.id(),original.requestId()));forbidden(()->actions.cancel(d.family(),d.id(),original.requestId(),cancel));
        harness.loginAs(f.reviewer());var originalUser=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        var impersonated=new AuthUser(f.reviewer(),employee,"anonymous-impersonated",originalUser.getPermissions(),false,true,false,false,f.world().superAdminUserId());
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(impersonated,"",impersonated.getAuthorities()));
        same(actions.receipt(d.family(),d.id(),original.requestId()),saved);forbidden(()->actions.cancel(d.family(),d.id(),original.requestId(),cancel));
    }

    @Test void paymentSuccessorAssemblesItsCurrentLegalIdentityAfterLinesWhileOriginalReversalKeepsFrozenAccounts(){
        Draft d=create("financePayment","10");actions.approve(d.family(),d.id(),command(review(d)));
        String sourceLines=financialSourceLines("finance_payment_lines","payment_id",d.id());
        String originalAmounts=db.queryForObject("SELECT jsonb_build_object('bank',account_amount,'local',account_amount_local,'original',amount_original,'book',amount_local,'gl',gl_ap_style_id,'lines',(SELECT jsonb_agg(jsonb_build_object('cash',l.amount_original,'book',l.amount_local,'applied',l.applied_amount_local,'diff',l.exchange_diff) ORDER BY line_no) FROM finance_payment_lines l WHERE l.payment_id=p.id AND NOT l.is_deleted))::text FROM finance_payments p WHERE p.id=?",String.class,d.id());
        String frozen=db.queryForObject("SELECT jsonb_agg(to_jsonb(p) ORDER BY line_no)::text FROM finance_native_cash_debt_parts p WHERE kind='PAYMENT' AND cash_id=?",String.class,d.id());
        UUID previous=db.queryForObject("SELECT system_posting_style_id('AP_CONTROL')",UUID.class),replacement=UUID.randomUUID();
        String category=db.queryForObject("SELECT required_category FROM system_posting_style_roles WHERE role_key='AP_CONTROL'",String.class);
        db.update("INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,?,'匿名后来新应付用途',?,0,'使用')",replacement,"REVIEW-AP-"+replacement,category);
        try{
            db.update("UPDATE system_posting_style_roles SET style_id=? WHERE role_key='AP_CONTROL'",replacement);
            var capability=unapproval.capabilityHttp(d.family(),d.id());assertThat(capability.eligible()).as(capability.reasons().toString()).isTrue();UUID key=UUID.randomUUID();
            var result=map(actions.execute(d.family(),d.id(),new Command(key,key.toString(),"匿名核对后来用途已变化仍按原冻结事实逆账",capability.factsSnapshot())));
            UUID draft=UUID.fromString(map(result.get("result")).get("id").toString());
            assertThat(db.queryForObject("SELECT amount_authority_version FROM finance_payments WHERE id=?",Integer.class,draft)).isEqualTo(2);
            assertThat(db.queryForObject("SELECT gl_ap_style_id=fn_finance_native_cash_counter_style('PAYMENT',id,'AP_CONTROL',currency_id,'SUPPLIER',supplier_id,bill_date) FROM finance_payments WHERE id=?",Boolean.class,draft)).isTrue();
            assertThat(db.queryForObject("SELECT gl_ap_style_id FROM finance_payments WHERE id=?",UUID.class,draft)).isNotEqualTo(replacement);
            assertThat(db.queryForObject("SELECT jsonb_agg(to_jsonb(p) ORDER BY line_no)::text FROM finance_native_cash_debt_parts p WHERE kind='PAYMENT' AND cash_id=?",String.class,d.id())).isEqualTo(frozen);
            assertThat(financialSourceLines("finance_payment_lines","payment_id",d.id())).isEqualTo(sourceLines);
            String after=db.queryForObject("SELECT jsonb_build_object('bank',account_amount,'local',account_amount_local,'original',amount_original,'book',amount_local,'gl',gl_ap_style_id,'lines',(SELECT jsonb_agg(jsonb_build_object('cash',l.amount_original,'book',l.amount_local,'applied',l.applied_amount_local,'diff',l.exchange_diff) ORDER BY line_no) FROM finance_payment_lines l WHERE l.payment_id=p.id AND NOT l.is_deleted))::text FROM finance_payments p WHERE p.id=?",String.class,d.id());
            assertThat(after).isEqualTo(originalAmounts);
        }finally{db.update("UPDATE system_posting_style_roles SET style_id=? WHERE role_key='AP_CONTROL'",previous);}
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void receiptSuccessorRequiresOriginalFrozenIdentityAfterRowsAndNeverRelabelsOriginalCashFacts(boolean prepayment){
        String role=prepayment?"CUSTOMER_ADVANCE":"AR_CONTROL";harness.loginAs(f.world().superAdminUserId());
        UUID configReviewer=harness.createUserWithPerms(f.world(),"anonymous-cash-map-reviewer-"+UUID.randomUUID(),"finance_report:view","finance:view:all","payment_style:edit","finance_post:execute");
        UUID firstStyle=configureReceiptAccount(role,prepayment?"22030951":"11220951",configReviewer);
        Draft d;
        if(prepayment)d=create("financeReceipt","10");
        else{
            harness.loginAs(f.world().superAdminUserId());var produced=harness.produceFinishedFromOpeningInputs(f.world(),f.world().goodsA(),"1","1");
            var goods=List.of(f.world().goodsA(),f.world().goodsB(),f.world().goodsC(),f.world().goodsD(),f.world().goodsE());
            InventoryValueWorkTestSupport.drain(inventoryWork,db,goods);
            UUID shipment=harness.createShipment(f.world(),produced.orderItemId(),f.world().goodsA(),"1");harness.shipThroughWarehouse(shipment);InventoryValueWorkTestSupport.drain(inventoryWork,db,goods);
            UUID ledger=db.queryForObject("SELECT id FROM ar_ap_ledger WHERE source_doc_type='SALES_SHIPMENT' AND source_doc_id=?",UUID.class,shipment);
            var input=harness.receiptRequest(f.world(),ledger,f.bank(),null,"10","10","0","0",BigDecimal.ONE,BusinessTime.today());
            d=new Draft("financeReceipt",receipts.create(input).getId(),input);
        }
        var approval=command(review(d));var approved=actions.approve(d.family(),d.id(),approval);
        assertThat(db.queryForObject("SELECT gl_counter_style_id FROM finance_receipts WHERE id=?",UUID.class,d.id())).isEqualTo(firstStyle);
        String originalMoney=receiptMoney(d.id()),frozen=receiptCashFacts(d.id());
        String sourceLines=financialSourceLines("finance_receipt_lines","receipt_id",d.id());
        String originalReceipt=db.queryForObject("SELECT to_jsonb(operation)::text FROM finance_application_operations operation WHERE request_id=?",String.class,approval.requestId());
        UUID laterStyle=configureReceiptAccount(role,prepayment?"22030952":"11220952",configReviewer);assertThat(laterStyle).isNotEqualTo(firstStyle);
        harness.loginAs(f.reviewer());var capability=unapproval.capabilityHttp(d.family(),d.id());assertThat(capability.eligible()).as(capability.reasons().toString()).isTrue();UUID key=UUID.randomUUID();
        var original=new Command(key,key.toString(),"匿名按原冻结来源逆账并显式核对新草稿当前科目",capability.factsSnapshot());
        // Exact pre-fix header assembly against the real current constraints:
        // restoring the old empty generated-header map must fail and roll back
        // the preceding real reversal, without consuming this original key.
        doReturn(Map.of()).when(receiptAdapter).generatedHeaderInputs();
        try{
            assertThatThrownBy(()->actions.execute(d.family(),d.id(),original)).satisfies(error->{
                var sql=org.springframework.core.NestedExceptionUtils.getMostSpecificCause(error);
                assertThat(sql).isInstanceOf(java.sql.SQLException.class);assertThat(((java.sql.SQLException)sql).getSQLState()).isEqualTo("23514");
            });
            assertThat(receiptMoney(d.id())).isEqualTo(originalMoney);assertThat(receiptCashFacts(d.id())).isEqualTo(frozen);assertThat(receiptCount(key)).isZero();
            assertThat(db.queryForObject("SELECT status FROM finance_receipts WHERE id=?",Integer.class,d.id())).isEqualTo(1);
        }finally{doCallRealMethod().when(receiptAdapter).generatedHeaderInputs();}
        if(prepayment){
            // Main V1069 requires a faithful original header at completion.
            // A header-only advance has no copied debt source proving that the
            // old account is still this draft's legal identity. A later approved
            // default cannot silently relabel it or consume the original command.
            String posted=moneyFacts(d);
            int headers=db.queryForObject("SELECT count(*) FROM finance_receipts",Integer.class);
            int vouchers=db.queryForObject("SELECT count(*) FROM gl_vouchers",Integer.class);
            assertThatThrownBy(()->actions.execute(d.family(),d.id(),original)).satisfies(error->{
                var sql=org.springframework.core.NestedExceptionUtils.getMostSpecificCause(error);
                assertThat(sql).isInstanceOf(java.sql.SQLException.class);
                assertThat(((java.sql.SQLException)sql).getSQLState()).isEqualTo("23514");
            });
            assertThat(moneyFacts(d)).isEqualTo(posted);
            assertThat(receiptMoney(d.id())).isEqualTo(originalMoney);
            assertThat(receiptCashFacts(d.id())).isEqualTo(frozen);
            assertThat(financialSourceLines("finance_receipt_lines","receipt_id",d.id())).isEqualTo(sourceLines);
            assertThat(receiptCount(key)).isZero();
            assertThat(db.queryForObject("SELECT count(*) FROM document_unapprovals WHERE family=? AND original_id=?",Integer.class,d.family(),d.id())).isZero();
            assertThat(db.queryForObject("SELECT count(*) FROM finance_receipts",Integer.class)).isEqualTo(headers);
            assertThat(db.queryForObject("SELECT count(*) FROM gl_vouchers",Integer.class)).isEqualTo(vouchers);
            assertThat(db.queryForObject("SELECT status FROM finance_receipts WHERE id=?",Integer.class,d.id())).isEqualTo(1);
            assertThat(db.queryForObject("SELECT gl_counter_style_id FROM finance_receipts WHERE id=?",UUID.class,d.id())).isEqualTo(firstStyle);
            same(actions.receipt(d.family(),d.id(),approval.requestId()),approved);
            assertThat(db.queryForObject("SELECT to_jsonb(operation)::text FROM finance_application_operations operation WHERE request_id=?",String.class,approval.requestId())).isEqualTo(originalReceipt);
            return;
        }
        var result=map(actions.execute(d.family(),d.id(),original));UUID draft=UUID.fromString(map(result.get("result")).get("id").toString());
        assertThat(receiptMoney(d.id())).isEqualTo(originalMoney);assertThat(receiptMoney(draft)).isEqualTo(originalMoney);assertThat(receiptCashFacts(d.id())).isEqualTo(frozen);
        assertThat(db.queryForObject("SELECT settlement_authority_version FROM finance_receipts WHERE id=?",Integer.class,draft)).isEqualTo(2);
        assertThat(db.queryForObject("SELECT gl_counter_style_id=fn_finance_native_cash_counter_style('RECEIPT',id,?,currency_id,'CUSTOMER',client_id,bill_date) FROM finance_receipts WHERE id=?",Boolean.class,role,draft)).isTrue();
        assertThat(db.queryForObject("SELECT gl_counter_style_id FROM finance_receipts WHERE id=?",UUID.class,draft)).isEqualTo(firstStyle);
        assertThat(financialSourceLines("finance_receipt_lines","receipt_id",d.id())).isEqualTo(sourceLines);
        same(actions.receipt(d.family(),d.id(),approval.requestId()),approved);
        assertThat(db.queryForObject("SELECT to_jsonb(operation)::text FROM finance_application_operations operation WHERE request_id=?",String.class,approval.requestId())).isEqualTo(originalReceipt);
        same(actions.execute(d.family(),d.id(),original),result);assertThat(receiptCashFacts(d.id())).isEqualTo(frozen);
        var shown=actions.<FinanceReviewMetadata>reviewedDetail("financeReceipt",draft,false);
        assertThat(actions.approve("financeReceipt",draft,command(shown))).containsEntry("outcome","SUCCEEDED");
        assertThat(receiptCashFacts(d.id())).isEqualTo(frozen);assertThat(db.queryForObject("SELECT balance_current FROM accounts WHERE id=?",BigDecimal.class,f.bank())).isEqualByComparingTo("510");
    }

    @ParameterizedTest @ValueSource(ints={201,401})
    void platformProjectionPreservesEveryRealRowAcrossTwoAndThreeBatchesAndAnOldSnapshotCannotApprove(int count)throws Exception{
        harness.loginAs(f.world().superAdminUserId());var input=factory.expense(f,"0.01");var rows=new ArrayList<FinanceExpenseItemInput>();
        for(int i=0;i<count;i++){var row=new FinanceExpenseItemInput();row.setExpenseStyleId(f.expenseStyle());row.setAmountOriginal(n("0.01"));row.setRemark("anonymous-row-"+i);rows.add(row);}input.setItems(rows);
        UUID id=expenses.create(input).getId();Draft d=new Draft("financeExpense",id,input);
        var nativeDetail=expenses.detail(id);assertThat(nativeDetail.getItems()).hasSize(count);
        var definition=fields.create("finance_expense_item",new PlatformColumnContracts.CreateDefinition("匿名跨批核对-"+id,"TEXT",false,null));
        var selected=new LinkedHashSet<>(List.of(0,200,count-1));
        for(int index:selected)fields.write("finance_expense_item",nativeDetail.getItems().get(index).getId(),new PlatformColumnContracts.Write(0,List.of(new PlatformColumnContracts.CellInput(definition.id(),"row-"+index))));
        var statistics=entityManagers.unwrap(org.hibernate.SessionFactory.class).getStatistics();boolean previous=statistics.isStatisticsEnabled();statistics.setStatisticsEnabled(true);statistics.clear();
        clearInvocations(expenses);harness.loginAs(f.reviewer());statistics.clear();
        var observer=new com.uten.imp.support.ObservedSqlDataSource();
        doAnswer(call->observer.observeConnection((java.sql.Connection)call.callRealMethod())).when(dataSource).getConnection();
        long started=System.nanoTime();FinanceExpenseDetail shown;
        try{shown=actions.reviewedDetail(d.family(),id,false);}finally{statistics.setStatisticsEnabled(previous);doCallRealMethod().when(dataSource).getConnection();}
        long elapsed=TimeUnit.NANOSECONDS.toMillis(System.nanoTime()-started),prepared=statistics.getPrepareStatementCount();
        long reloads=mockingDetails(expenses).getInvocations().stream().filter(call->call.getMethod().getName().equals("detail")&&id.equals(call.getArgument(0))).count();
        System.out.println("FINANCE_REVIEW_ROWS="+count+";elapsedMs="+elapsed+";jdbcExecutions="+observer.statements.get()+";hibernatePreparedStatements="+prepared+";domainDetailReloads="+reloads);
        assertThat(observer.statements.get()).isGreaterThanOrEqualTo((int)prepared);
        assertThat(reloads).isEqualTo(3);assertThat(shown.getItems()).hasSize(count);
        var projection=shown.getApprovalPlatformFields().get("finance_expense_item");assertThat(projection).hasSize(count);
        assertThat(projection.stream().map(PlatformColumnContracts.Row::recordId).toList()).containsExactlyElementsOf(shown.getItems().stream().map(FinanceExpenseItemDto::getId).toList());
        for(int index:selected){var row=projection.get(index);assertThat(row.cells()).hasSize(1);assertThat(row.cells().getFirst().value()).isEqualTo("row-"+index);}
        assertThat(projection.get(1).cells()).isEmpty();var original=command(shown);String before=moneyFacts(d);
        harness.loginAs(f.world().superAdminUserId());UUID last=shown.getItems().getLast().getId();fields.write("finance_expense_item",last,new PlatformColumnContracts.Write(1,List.of(new PlatformColumnContracts.CellInput(definition.id(),"new-view"))));
        harness.loginAs(f.reviewer());conflict(()->actions.approve(d.family(),id,original));assertThat(receiptCount(original.requestId())).isZero();assertThat(moneyFacts(d)).isEqualTo(before);
    }

    @Test void aRealReadonlyProjectionScopeCannotReuseTheCompanyReadersHeaderForAnotherEmployeesActor(){
        Draft d=create("financeExpense","10");UUID item=db.queryForObject("SELECT id FROM finance_expense_items WHERE expense_id=?",UUID.class,d.id());
        UUID outsider=harness.createUserWithPerms(f.world(),"anonymous-cache-outsider-"+UUID.randomUUID(),"finance_expense:view");
        var read=new TransactionTemplate(transaction.getTransactionManager());read.setReadOnly(true);read.setIsolationLevel(org.springframework.transaction.TransactionDefinition.ISOLATION_REPEATABLE_READ);
        read.executeWithoutResult(status->{
            try(var scope=DocumentPlatformReadContext.open()){
                harness.loginAs(f.reviewer());assertThat(fields.read("finance_expense_item",new PlatformColumnContracts.BatchRead(List.of(item),null))).hasSize(1);
                harness.loginAs(outsider);assertThat(((AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal()).getPermissions()).doesNotContain("finance:view:all");
                assertThatThrownBy(()->fields.read("finance_expense_item",new PlatformColumnContracts.BatchRead(List.of(item),null))).isInstanceOf(ApiException.class);
                harness.loginAs(f.reviewer());assertThat(fields.read("finance_expense_item",new PlatformColumnContracts.BatchRead(List.of(item),null))).hasSize(1);
            }finally{status.setRollbackOnly();}
        });
    }

    private UUID configureReceiptAccount(String role,String code,UUID configReviewer){
        harness.loginAs(f.world().superAdminUserId());UUID style=UUID.randomUUID();String category=db.queryForObject("SELECT required_category FROM system_posting_style_roles WHERE role_key=?",String.class,role);
        db.update("INSERT INTO payment_styles(id,code,name,category,level,status)VALUES(?,?,?,?,0,'使用')",style,"REVIEW-"+style,"匿名明确收款科目-"+style,category);
        db.update("INSERT INTO finance_chart_codes(code,name,currency_name,currency_id,classification,source_kind,source_reference,sort_order,source_row,updated_by)VALUES(?,'匿名真实财务收款对应','',?,?,'MANUAL','匿名逐科目明确对应',1,1,?)",code,f.currency(),role.equals("AR_CONTROL")?"ASSET":"LIABILITY",f.world().superAdminUserId());
        db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by)VALUES(?,?,?)",code,style,f.world().superAdminUserId());
        var rule=auxiliaries.readRule(code);auxiliaries.saveRule(code,new com.uten.imp.features.finance.statement.FinanceAuxiliaryContracts.RuleInput(rule.version(),true,List.of("CUSTOMER"),"匿名明确客户原UUID"));
        auxiliaries.save(new com.uten.imp.features.finance.statement.FinanceAuxiliaryContracts.Save(null,null,"匿名审核账套","CUSTOMER-"+f.world().clientId(),"匿名源客户","CUSTOMER",f.world().clientId(),"匿名真实客户与当前科目逐项对应",code));
        var configuration=new com.uten.imp.features.finance.gl.NativeFinancialPostingAccountService.Configuration(UUID.randomUUID(),role,role.equals("AR_CONTROL")?f.world().currencyId():f.currency(),new com.uten.imp.application.port.NativeFinancialPostingAccountPort.Party("CUSTOMER",f.world().clientId()),BusinessTime.today(),true,style,code,f.currency(),null,"匿名明确此次原生科目用途并由另一财务审核");
        UUID id=(UUID)nativeAccounts.submit(configuration).get("id");harness.loginAs(configReviewer);nativeAccounts.approve(id);harness.loginAs(f.world().superAdminUserId());return style;
    }
    private String receiptMoney(UUID id){return db.queryForObject("SELECT jsonb_build_object('original',amount_original,'local',amount_local,'account',account_amount,'accountLocal',account_amount_local,'rate',exchange_rate,'accountRate',account_exchange_rate,'bankFee',bank_fee,'otherFee',other_fee,'bankBookedAt',bank_booked_at,'bankReference',bank_reference)::text FROM finance_receipts WHERE id=?",String.class,id);}
    private String receiptCashFacts(UUID id){return db.queryForObject("SELECT jsonb_build_object('account',(SELECT jsonb_agg(to_jsonb(c)) FROM finance_native_cash_accounts c WHERE kind='RECEIPT' AND cash_id=?),'parts',(SELECT jsonb_agg(to_jsonb(p)ORDER BY line_no) FROM finance_native_cash_debt_parts p WHERE kind='RECEIPT' AND cash_id=?))::text",String.class,id,id);}
    private String financialSourceLines(String table,String parent,UUID id){return db.queryForObject("SELECT jsonb_agg(to_jsonb(line) ORDER BY line_no,id)::text FROM "+table+" line WHERE "+parent+"=? AND NOT is_deleted",String.class,id);}

    private FinanceReviewMetadata makerReview(Draft d){harness.loginAs(f.world().superAdminUserId());return actions.reviewedDetail(d.family(),d.id(),false);}
    private FinanceDocumentActions.UpdateCommand updateCommand(Draft d,String amount,FinanceReviewMetadata shown)throws Exception{
        ObjectNode body=(ObjectNode)FinancialJsonResults.tree(json,json.writeValueAsString(d.request()));
        if(d.family().equals("financeReceipt")||d.family().equals("financePayment")){
            body.put("expectedVersion",shown.getApprovalVersion());body.put("amountOriginal",n(amount));body.put("accountAmount",n(amount));
        }
        if(!d.family().equals("financeReceipt"))((ObjectNode)body.path("items").get(0)).put("amountOriginal",n(amount));
        return new FinanceDocumentActions.UpdateCommand(UUID.randomUUID(),shown.getApprovalVersion(),shown.getApprovalSnapshot(),body);
    }
    private FinanceOperationJournal.Cancellation editCancellation(Draft d,FinanceDocumentActions.UpdateCommand body){return new FinanceOperationJournal.Cancellation(body.requestId(),f.world().superAdminUserId(),"FINANCE_DOCUMENT_UPDATE","PUT","/finance/"+SEGMENTS.get(d.family())+"/"+d.id(),json.valueToTree(body),Map.of());}

    private Draft create(String family,String value){
        harness.loginAs(f.world().superAdminUserId());Object request=switch(family){case "financeReceipt"->factory.receipt(f,value);case "financePayment"->factory.payment(f,value);case "financeExpense"->factory.expense(f,value);case "financeOtherIncome"->factory.income(f,value);default->factory.transfer(f,value);};
        UUID id=switch(family){case "financeReceipt"->receipts.create((FinanceReceiptSaveRequest)request).getId();case "financePayment"->payments.create((FinancePaymentSaveRequest)request).getId();case "financeExpense"->expenses.create((FinanceExpenseSaveRequest)request).getId();case "financeOtherIncome"->incomes.create((FinanceOtherIncomeSaveRequest)request).getId();default->transfers.create((FinanceBankTransferSaveRequest)request).getId();};
        return new Draft(family,id,request);
    }
    private void mutate(Draft d,String value){
        harness.loginAs(f.world().superAdminUserId());
        try{switch(d.family()){
            case "financeReceipt"->{var request=FinancialJsonResults.value(json,json.writeValueAsString(d.request()),FinanceReceiptSaveRequest.class);request.setExpectedVersion(receipts.detail(d.id()).getVersion());request.setAmountOriginal(n(value));request.setAccountAmount(n(value));receipts.update(d.id(),request);}
            case "financePayment"->{var request=FinancialJsonResults.value(json,json.writeValueAsString(d.request()),FinancePaymentSaveRequest.class);request.setExpectedVersion(payments.detail(d.id()).getVersion());request.setAmountOriginal(n(value));request.setAccountAmount(n(value));request.getItems().getFirst().setAmountOriginal(n(value));payments.update(d.id(),request);}
            case "financeExpense"->{var request=FinancialJsonResults.value(json,json.writeValueAsString(d.request()),FinanceExpenseSaveRequest.class);request.getItems().getFirst().setAmountOriginal(n(value));expenses.update(d.id(),request);}
            case "financeOtherIncome"->{var request=FinancialJsonResults.value(json,json.writeValueAsString(d.request()),FinanceOtherIncomeSaveRequest.class);request.getItems().getFirst().setAmountOriginal(n(value));incomes.update(d.id(),request);}
            default->{var request=FinancialJsonResults.value(json,json.writeValueAsString(d.request()),FinanceBankTransferSaveRequest.class);request.getItems().getFirst().setAmountOriginal(n(value));transfers.update(d.id(),request);}
        }}catch(java.io.IOException error){throw new AssertionError(error);}
    }
    private FinanceReviewMetadata review(Draft d){harness.loginAs(f.reviewer());return actions.reviewedDetail(d.family(),d.id(),false);}
    private static FinanceDocumentActions.ApprovalCommand command(FinanceReviewMetadata shown){return new FinanceDocumentActions.ApprovalCommand(UUID.randomUUID(),shown.getApprovalVersion(),shown.getApprovalSnapshot());}
    private FinanceOperationJournal.Cancellation cancellation(UUID id,String operation,String path,Object body){return new FinanceOperationJournal.Cancellation(id,f.reviewer(),operation,"POST",path,json.valueToTree(body),Map.of());}
    private void loginReadOnly(){UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,f.reviewer());var user=new AuthUser(f.reviewer(),employee,"anonymous-review-reader",Set.of("finance_expense:view","finance:view:all"),false,true,false);SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,"",user.getAuthorities()));}
    private String moneyFacts(Draft d){return header(d)+db.queryForObject("SELECT jsonb_build_object('bank',(SELECT balance_current FROM accounts WHERE id=?),'other',(SELECT balance_current FROM accounts WHERE id=?),'flows',(SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.id),'[]'::jsonb) FROM finance_reconciliations x WHERE source_doc_id=?),'gl',(SELECT COALESCE(jsonb_agg(to_jsonb(v) ORDER BY v.id),'[]'::jsonb) FROM gl_vouchers v WHERE source_doc_id=?),'ledger',(SELECT COALESCE(jsonb_agg(to_jsonb(l) ORDER BY l.id),'[]'::jsonb) FROM ar_ap_ledger l WHERE source_doc_id=?))::text",String.class,f.bank(),f.otherBank(),d.id(),d.id(),d.id());}
    private String header(Draft d){return db.queryForObject("SELECT to_jsonb(h)::text FROM "+TABLES.get(d.family())+" h WHERE id=?",String.class,d.id());}
    private int receiptCount(UUID id){return db.queryForObject("SELECT count(*) FROM finance_application_operations WHERE request_id=?",Integer.class,id);}
    private UUID confirmationActor(){harness.loginAs(f.world().superAdminUserId());return harness.createUserWithPerms(f.world(),"anonymous-gl-confirm-"+UUID.randomUUID(),"finance_expense:view","finance_expense:gl_confirm","finance:view:all");}
    private void loginConfirmationReader(UUID actor){UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,actor);var user=new AuthUser(actor,employee,"anonymous-gl-confirm-reader",Set.of("finance_expense:view","finance:view:all"),false,true,false);SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,"",user.getAuthorities()));}
    private FinanceOperationJournal.Cancellation confirmationCancellation(Draft d,UUID actor,FinanceDocumentActions.ApprovalCommand body,Map<String,BusinessPrecisionContext.Choice> choices){return new FinanceOperationJournal.Cancellation(body.requestId(),actor,"FINANCE_DOCUMENT_GL_CONFIRM","POST","/finance/expenses/"+d.id()+"/gl-confirm",json.valueToTree(body),choices);}
    private int confirmationAudits(Draft d){return db.queryForObject("SELECT count(*) FROM v_audit_log_all WHERE action='finance_expense_gl_confirm' AND target_type='finance_expense' AND target_id=?",Integer.class,d.id().toString());}
    private String confirmationMoney(Draft d){return db.queryForObject("SELECT jsonb_build_object('header',(SELECT to_jsonb(e)-ARRAY['gl_status','updated_at','updated_by'] FROM finance_expenses e WHERE id=?),'items',(SELECT jsonb_agg(to_jsonb(i) ORDER BY i.id) FROM finance_expense_items i WHERE expense_id=?),'bank',(SELECT balance_current FROM accounts WHERE id=?),'flows',(SELECT jsonb_agg(to_jsonb(x) ORDER BY x.id) FROM finance_reconciliations x WHERE source_doc_id=?),'vouchers',(SELECT jsonb_agg(to_jsonb(v) ORDER BY v.id) FROM gl_vouchers v WHERE source_doc_id=?),'entries',(SELECT jsonb_agg(to_jsonb(g) ORDER BY g.id) FROM gl_entries g JOIN gl_vouchers v ON v.id=g.voucher_id WHERE v.source_doc_id=?))::text",String.class,d.id(),d.id(),f.bank(),d.id(),d.id(),d.id());}
    private Map<String,Object> approveHttp(Draft d,FinanceDocumentActions.ApprovalCommand command){return switch(d.family()){
        case "financeReceipt"->beans.getBean(FinanceReceiptController.class).approve(d.id(),command);
        case "financePayment"->beans.getBean(FinancePaymentController.class).approve(d.id(),command);
        case "financeExpense"->beans.getBean(FinanceExpenseController.class).approve(d.id(),command);
        case "financeOtherIncome"->beans.getBean(FinanceOtherIncomeController.class).approve(d.id(),command);
        default->beans.getBean(FinanceBankTransferController.class).approve(d.id(),command);
    };}
    private Map<String,Object> reverseHttp(Draft d,Command command,boolean generic){
        if(generic)return map(beans.getBean(com.uten.imp.features.documents.DocumentUnapprovalController.class).unapprove(d.family(),d.id(),new DocumentUnapprovalService.UnapproveRequest(command.idempotencyKey(),command.reason(),command.expectedSnapshot(),command.requestId())));
        return switch(d.family()){
            case "financeReceipt"->beans.getBean(FinanceReceiptController.class).reverse(d.id(),command);
            case "financePayment"->beans.getBean(FinancePaymentController.class).reverse(d.id(),command);
            case "financeExpense"->beans.getBean(FinanceExpenseController.class).reverse(d.id(),command);
            case "financeOtherIncome"->beans.getBean(FinanceOtherIncomeController.class).reverse(d.id(),command);
            default->beans.getBean(FinanceBankTransferController.class).reverse(d.id(),command);
        };
    }
    private int businessAudits(Draft d,String action){return db.queryForObject("SELECT count(*) FROM v_audit_log_all WHERE action=? AND target_type=? AND target_id=? AND result='success'",Integer.class,permission(d)+"_"+action,permission(d),d.id().toString());}
    private String permission(Draft d){String table=TABLES.get(d.family());return table.substring(0,table.length()-1);}
    private int deletionAudits(Draft d){return db.queryForObject("SELECT count(*) FROM v_audit_log_all WHERE action=? AND target_type=? AND target_id=?",Integer.class,permission(d)+"_delete",permission(d),d.id().toString());}
    private void loginDeletionReader(Draft d){UUID actor=f.world().superAdminUserId(),employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,actor);var user=new AuthUser(actor,employee,"anonymous-deletion-reader",Set.of(permission(d)+":view","finance:view:all","customer_prepayment:view"),false,true,false);SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,"",user.getAuthorities()));}
    private FinanceOperationJournal.Cancellation deletionCancellation(Draft d,FinanceDocumentActions.ApprovalCommand body,Map<String,BusinessPrecisionContext.Choice> choices){return new FinanceOperationJournal.Cancellation(body.requestId(),f.world().superAdminUserId(),"FINANCE_DOCUMENT_DELETE","DELETE","/finance/"+SEGMENTS.get(d.family())+"/"+d.id(),json.valueToTree(body),choices);}
    private String deletionMoney(Draft d){String child=switch(d.family()){case "financeReceipt"->"finance_receipt_lines";case "financePayment"->"finance_payment_lines";case "financeExpense"->"finance_expense_items";case "financeOtherIncome"->"finance_other_income_items";default->"finance_bank_transfer_lines";};String parent=switch(d.family()){case "financeReceipt"->"receipt_id";case "financePayment"->"payment_id";case "financeExpense"->"expense_id";case "financeOtherIncome"->"income_id";default->"transfer_id";};return db.queryForObject("SELECT jsonb_build_object('header',(SELECT to_jsonb(h)-ARRAY['is_deleted','deleted_at','deleted_by','deleted_reason','updated_at','updated_by','version','row_version'] FROM "+TABLES.get(d.family())+" h WHERE id=?),'items',(SELECT jsonb_agg(to_jsonb(i) ORDER BY i.id) FROM "+child+" i WHERE "+parent+"=?),'bank',(SELECT balance_current FROM accounts WHERE id=?),'flows',(SELECT jsonb_agg(to_jsonb(x) ORDER BY x.id) FROM finance_reconciliations x WHERE source_doc_id=?),'vouchers',(SELECT jsonb_agg(to_jsonb(v) ORDER BY v.id) FROM gl_vouchers v WHERE source_doc_id=?),'ledger',(SELECT jsonb_agg(to_jsonb(l) ORDER BY l.id) FROM ar_ap_ledger l WHERE source_doc_id=?))::text",String.class,d.id(),d.id(),f.bank(),d.id(),d.id(),d.id());}
    private static String approvePath(Draft d){return "/finance/"+SEGMENTS.get(d.family())+"/"+d.id()+"/approve";}
    private static String unapprovePath(Draft d){return "/documents/"+d.family()+"/"+d.id()+"/unapprove";}
    @SuppressWarnings("unchecked")private static Map<String,Object> map(Object value){return (Map<String,Object>)value;}
    private void same(Object actual,Object expected){try{assertThat(FinancialJsonResults.tree(json,json.writeValueAsString(actual))).isEqualTo(FinancialJsonResults.tree(json,json.writeValueAsString(expected)));}catch(java.io.IOException error){throw new AssertionError(error);}}
    private static BigDecimal n(String value){return new BigDecimal(value);}
    private static void await(CountDownLatch gate){try{if(!gate.await(20,TimeUnit.SECONDS))throw new AssertionError("review gate timeout");}catch(InterruptedException error){Thread.currentThread().interrupt();throw new IllegalStateException(error);}}
    private static void conflict(Runnable action){assertThatThrownBy(action::run).isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));}
    private static void forbidden(Runnable action){assertThatThrownBy(action::run).satisfies(error->{if(error instanceof ApiException api)assertThat(api.getCode()).isEqualTo(ErrorCode.FORBIDDEN);else assertThat(error).isInstanceOf(org.springframework.security.access.AccessDeniedException.class);});}
}
