package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.BatchDecisionItem;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.finance.procurement.ProcurementOrderClosureBatchService;
import com.uten.imp.features.finance.procurement.ProcurementOrderClosureBatchService.PreviewRequest;
import com.uten.imp.features.finance.procurement.ProcurementOrderClosureBatchService.SubmissionItem;
import com.uten.imp.features.finance.procurement.ProcurementOrderClosureBatchService.SubmissionRequest;
import com.uten.imp.features.finance.procurement.ProcurementOrderClosureBatchService.Target;
import com.uten.imp.features.finance.procurement.ProcurementOrderClosureService;
import com.uten.imp.features.finance.procurement.ProcurementOrderClosureService.ClosureRequest;
import com.uten.imp.features.notice.outbox.BusinessOutboxProcessor;
import com.uten.imp.features.notice.outbox.BusinessOutboxScheduler;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.Callable;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Batch submission, actual finance claims, warehouse races and durable departmental action cards. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@SpringBootTest(properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
        "uten.inventory.value-work.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=false",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only", // gitleaks:allow shared synthetic fixture.
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", // gitleaks:allow shared synthetic fixture.
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProcurementOrderClosureCoordinationEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) { FullChainEndToEndTest.registerDataSource(registry); }
    @MockitoBean BusinessOutboxScheduler scheduler;
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PurchaseOrderService orders;
    @Autowired PurchaseRequestService requests;
    @Autowired PurchaseReceiptService receipts;
    @Autowired ProcurementOrderClosureService closure;
    @Autowired ProcurementOrderClosureBatchService batches;
    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired TaskClaimService claims;
    @Autowired BusinessOutboxProcessor outbox;
    @Autowired PlatformTransactionManager transactions;
    @Autowired com.uten.imp.application.port.BusinessEventPublisher events;
    private FullChainEndToEndTest harness;
    private record Fixture(FullChainEndToEndTest.World world,UUID reviewer,UUID keeper,UUID request,UUID source,UUID order,UUID item) {}
    private record Outcome(boolean succeeded,Throwable failure,Object value) {}

    @BeforeEach void setup() { harness=new FullChainEndToEndTest();beans.autowireBean(harness); }
    @AfterEach void logout() { SecurityContextHolder.clearContext(); }

    @Test void duplicatePhysicalSelectionsDirectlyCloseOneCasePerOrderAndRetryDoesNotDuplicateWork() {
        var first=fixture("batch-one");var second=fixture("batch-two");owner(first);
        var preview=batches.preview(new PreviewRequest(List.of(target(first),target(first),target(second))));
        assertThat(preview.items()).hasSize(2);assertThat(preview.canSubmit()).isTrue();
        var items=preview.items().stream().map(p->new SubmissionItem(p.orderType(),p.orderId(),p.fingerprint())).toList();
        List<SubmissionItem> repeated=new ArrayList<>(items);repeated.add(items.getFirst());
        var submitted=batches.submit(new SubmissionRequest("CLOSE_AND_REORDER","两家供应商停止履约",repeated));
        assertThat(submitted.submittedCount()).isEqualTo(2);
        for(var f:List.of(first,second)) {
            assertThat(caseCount(f,"APPROVED")).isEqualTo(1);assertClosed(f);
            assertThat(number("SELECT ordered_qty FROM purchase_request_items WHERE id=?",f.source())).isZero();
            assertThat(count("SELECT COUNT(*) FROM procurement_order_termination_sources WHERE order_id=?",f.order())).isEqualTo(1);
        }
        assertThatThrownBy(()->batches.submit(new SubmissionRequest("CLOSE_AND_REORDER","响应丢失后的重复点击",items)))
                .isInstanceOf(ApiException.class);
        var replay=batches.submit(new SubmissionRequest("CLOSE_AND_REORDER","两家供应商停止履约",items));
        assertThat(replay.approvals()).extracting(FinanceApproval::caseId)
                .containsExactlyElementsOf(submitted.approvals().stream().map(FinanceApproval::caseId).toList());
        assertThat(caseCount(first,"APPROVED")).isEqualTo(1);assertThat(caseCount(second,"APPROVED")).isEqualTo(1);
    }

    @Test void aBlockedOrChangedRowRejectsTheWholeSubmissionWithoutPartialFinanceWork() {
        var first=fixture("batch-valid");var second=fixture("batch-stale");owner(first);
        var preview=batches.preview(new PreviewRequest(List.of(target(first),target(second))));
        draft(second);
        String before=facts(first)+facts(second);
        assertThatThrownBy(()->batches.submit(new SubmissionRequest("CLOSE","逐单核对后整批送审",preview.items().stream()
                .map(p->new SubmissionItem(p.orderType(),p.orderId(),p.fingerprint())).toList())))
                .isInstanceOf(ApiException.class);
        assertThat(facts(first)+facts(second)).isEqualTo(before);
        var blocked=batches.preview(new PreviewRequest(List.of(target(first),target(second))));
        assertThat(blocked.canSubmit()).isFalse();
        assertThat(blocked.items().stream().filter(p->p.orderId().equals(second.order())).findFirst().orElseThrow().blocker().kind())
                .isEqualTo("WAREHOUSE_RECEIPT");
    }

    @Test void batchPreviewDoesNotDiscloseAnotherOwnersCommercialSnapshot() {
        var f=fixture("private-preview");owner(f);
        UUID viewer=harness.createUserWithPerms(f.world(),"closure-readonly-"+UUID.randomUUID(),"purchase_order:view");
        harness.loginAs(viewer);
        var result=batches.preview(new PreviewRequest(List.of(target(f))));
        assertThat(result.canSubmit()).isFalse();assertThat(result.items()).hasSize(1);
        var unavailable=result.items().getFirst();
        assertThat(unavailable.items()).isEmpty();assertThat(unavailable.billNo()).isEmpty();
        assertThat(unavailable.fingerprint()).isEmpty();assertThat(unavailable.blockReason()).isNotBlank();
        assertThat(unavailable.blocker()).isNull();
    }

    @Test void aLaterStaleBatchRowCannotLeaveAnEarlierClosureOrReplacementDraftCommitted() {
        var a=fixture("atomic-a");var b=fixture("atomic-b");
        var sorted=List.of(a,b).stream().sorted(Comparator.comparing(f->f.order().toString())).toList();
        var first=sorted.getFirst();var second=sorted.getLast();
        owner(first);var preview=batches.preview(new PreviewRequest(List.of(target(first),target(second))));
        draft(second);
        String before=facts(first)+facts(second);
        assertThatThrownBy(()->batches.submit(new SubmissionRequest("CLOSE_AND_REORDER","不能只取消半批",preview.items().stream()
                .map(p->new SubmissionItem(p.orderType(),p.orderId(),p.fingerprint())).toList())))
                .isInstanceOf(ApiException.class);
        assertThat(facts(first)+facts(second)).isEqualTo(before);
        assertThat(caseCount(first,"APPROVED")).isZero();assertThat(caseCount(second,"APPROVED")).isZero();
        assertOpen(first);assertOpen(second);
    }

    @Test void repeatedAndConcurrentDirectSubmissionsGenerateExactlyOneReplacementAndOneRelease() throws Exception {
        var f=fixture("double-decision");owner(f);var preview=closure.preview("PURCHASE",f.order());
        var request=new ClosureRequest("CLOSE_AND_REORDER","并发相同结束命令",preview.fingerprint());
        var outcomes=race(()->actor(f.world().superAdminUserId(),()->closure.submit("PURCHASE",f.order(),request)),
                ()->actor(f.world().superAdminUserId(),()->closure.submit("PURCHASE",f.order(),request)));
        assertThat(outcomes.stream().filter(Outcome::succeeded).count()).isEqualTo(2);
        var pending=(FinanceApproval)outcomes.getFirst().value();
        assertThat(((FinanceApproval)outcomes.getLast().value()).caseId()).isEqualTo(pending.caseId());
        assertThat(caseCount(f,"APPROVED")).isEqualTo(1);
        assertThat(count("SELECT COUNT(*) FROM procurement_order_approval_events WHERE case_id=? AND event_type='CLOSED'",pending.caseId())).isEqualTo(1);
        assertThat(count("SELECT COUNT(*) FROM procurement_order_termination_sources WHERE order_id=?",f.order())).isEqualTo(1);
        UUID replacement=db.queryForObject("SELECT replacement_order_id FROM procurement_order_approval_cases WHERE id=?",UUID.class,pending.caseId());
        assertThat(replacement).isNotNull();
        assertThat(number("SELECT qty FROM purchase_order_items WHERE order_id=?",replacement)).isEqualByComparingTo("10");
        owner(f);String before=facts(f);
        assertThat(closure.submit("PURCHASE",f.order(),request).caseId()).isEqualTo(pending.caseId());
        assertThat(facts(f)).isEqualTo(before);
    }

    @Test void directClosureAndWarehouseArrivalCannotBothCommitAgainstTheSameRemainingCapacity() throws Exception {
        var f=fixture("arrival-race");owner(f);var preview=closure.preview("PURCHASE",f.order());
        var outcomes=race(()->actor(f.world().superAdminUserId(),()->closure.submit("PURCHASE",f.order(),new ClosureRequest("CLOSE","到货与结束竞争",preview.fingerprint()))),
                ()->actor(f.world().superAdminUserId(),()->new TransactionTemplate(transactions).execute(status->{
                    UUID receipt=receipts.create(receiptRequest(f)).getId();receipts.approve(receipt);return receipt;
                })));
        assertThat(outcomes.stream().filter(Outcome::succeeded).count()).isEqualTo(1);
        boolean closed=Boolean.TRUE.equals(db.queryForObject("SELECT termination_case_id IS NOT NULL FROM purchase_orders WHERE id=?",Boolean.class,f.order()));
        assertThat(number("SELECT received_qty FROM purchase_order_items WHERE id=?",f.item()))
                .isEqualByComparingTo(closed?"0":"1");
        assertThat(caseCount(f,"APPROVED")).isEqualTo(closed?1:0);
        assertThat(count("SELECT COUNT(*) FROM purchase_receipts WHERE supplier_id=? AND status=1",f.world().supplierId()))
                .isEqualTo(closed?0:1);
    }

    @Test void differentConcurrentClosureCommandsHaveOneDurableOutcome() throws Exception {
        var f=fixture("decision-race");owner(f);var preview=closure.preview("PURCHASE",f.order());
        var outcomes=race(()->actor(f.world().superAdminUserId(),()->closure.submit("PURCHASE",f.order(),new ClosureRequest("CLOSE_AND_REORDER","换供应商",preview.fingerprint()))),
                ()->actor(f.world().superAdminUserId(),()->closure.submit("PURCHASE",f.order(),new ClosureRequest("CLOSE","取消无需重建",preview.fingerprint()))));
        assertThat(outcomes.stream().filter(Outcome::succeeded).count()).isEqualTo(1);
        assertThat(caseCount(f,"APPROVED")).isEqualTo(1);
        assertThat(count("SELECT COUNT(*) FROM procurement_order_termination_sources WHERE order_id=?",f.order())).isEqualTo(1);
        assertThat(number("SELECT ordered_qty FROM purchase_request_items WHERE id=?",f.source())).isZero();
    }

    @Test void originalOrderReversalCannotUndoADirectlyCompletedClosure() {
        var f=fixture("reverse-pending");var pending=submit(f,"CLOSE");
        owner(f);String before=facts(f);
        assertThatThrownBy(()->orders.reverse(f.order())).isInstanceOf(ApiException.class);
        assertThat(facts(f)).isEqualTo(before);
        assertThat(db.queryForObject("SELECT status FROM procurement_order_approval_cases WHERE id=?",String.class,pending.caseId())).isEqualTo("APPROVED");
        assertThat(db.queryForObject("SELECT status FROM inbound_expectations WHERE order_type='PURCHASE' AND order_id=?",String.class,f.order())).isEqualTo("CLOSED");
        assertThat(number("SELECT ordered_qty FROM purchase_request_items WHERE id=?",f.source())).isZero();
        harness.loginAs(f.reviewer());
        assertThatThrownBy(()->finance.approveBatch(List.of(new BatchDecisionItem(pending.caseId(),pending.version())),null)).isInstanceOf(RuntimeException.class);
    }

    @Test void directClosureCreatesNoFinanceApprovalQueueCountFacetOrCurrentTaskRow() {
        var f=fixture("queue-state");harness.loginAs(f.reviewer());
        long before=finance.countTasksByType("CLOSURE_PENDING").getOrDefault("PURCHASE",0L);
        submit(f,"CLOSE");harness.loginAs(f.reviewer());
        assertThat(finance.countTasksByType("CLOSURE_PENDING").getOrDefault("PURCHASE",0L)).isEqualTo(before);
        String bill=db.queryForObject("SELECT bill_no FROM purchase_orders WHERE id=?",String.class,f.order());
        var page=finance.tasks(1,50,"PURCHASE",bill,null,null,null,"CLOSURE_PENDING");
        assertThat(page.getItems()).isEmpty();
        assertThat(finance.taskFacets("PURCHASE",bill,"CLOSURE_PENDING").get("billNo")).isEmpty();
        assertThat(finance.countTasksByType("CLOSURE_PENDING").getOrDefault("PURCHASE",0L)).isEqualTo(before);
        assertThat(finance.tasks(1,50,"PURCHASE",bill,null,null,null,"CLOSURE_PENDING").getItems()).isEmpty();
        owner(f);assertClosed(f);
    }

    @Test void warehouseAndFinanceNoticesResolveWithoutResurrectingLateDeliveryEvents() {
        var f=fixture("notice-close");owner(f);drain();
        assertThat(count("SELECT COUNT(*) FROM notices WHERE aggregate_kind='PROCUREMENT_ORDER' AND aggregate_id=? AND resolved_at IS NULL",f.order())).isPositive();
        var pending=submit(f,"CLOSE");owner(f);drain();
        assertThat(count("SELECT COUNT(*) FROM notices WHERE aggregate_kind='PROCUREMENT_APPROVAL_CASE' AND aggregate_id=? AND resolved_at IS NULL",pending.caseId())).isZero();
        assertThat(count("SELECT COUNT(*) FROM notices WHERE aggregate_kind IN ('PROCUREMENT_ORDER','PROCUREMENT_APPROVAL_CASE') AND aggregate_id IN (?,?) AND resolved_at IS NULL",f.order(),pending.caseId())).isZero();
        assertThat(count("SELECT COUNT(*) FROM notices WHERE audience_user_id=? AND title LIKE '%已结束%' AND action_route=?",f.world().superAdminUserId(),"/purchase/orders/"+f.order())).isEqualTo(1);
        assertThat(count("SELECT COUNT(*) FROM business_outbox WHERE aggregate_id IN (?,?) AND status<>1",f.order(),pending.caseId())).isZero();
    }

    @Test void lateLegacySubmissionEventCannotResurrectFinanceApprovalAfterDirectCompletion() {
        var f=fixture("late-legacy-notice");owner(f);drain();
        var legacy=LegacyProcurementClosureFixture.pending(db,closure.preview("PURCHASE",f.order()),f.world(),"CLOSE");
        new TransactionTemplate(transactions).executeWithoutResult(ignored->events.publishOnce(
                ProcurementFinanceApprovalService.EVENT_SUBMITTED,"PROCUREMENT_APPROVAL_CASE",legacy.caseId(),
                java.util.Map.of("orderType","PURCHASE","status","PENDING","version",1),"legacy-late-"+legacy.caseId()));
        var completed=submit(f,"CLOSE");drain();
        assertThat(db.queryForObject("SELECT status FROM procurement_order_approval_cases WHERE id=?",String.class,legacy.caseId())).isEqualTo("CANCELED");
        assertThat(count("SELECT COUNT(*) FROM notices WHERE aggregate_kind='PROCUREMENT_APPROVAL_CASE' AND aggregate_id=? AND resolved_at IS NULL",legacy.caseId())).isZero();
        assertThat(count("SELECT COUNT(*) FROM notices WHERE aggregate_id=? AND audience_user_id=? AND resolved_at IS NULL",completed.caseId(),f.reviewer())).isZero();
        assertClosed(f);
    }

    private Fixture fixture(String label) {
        var w=harness.seedWorld(label+"-"+UUID.randomUUID());harness.loginAs(w.superAdminUserId());
        UUID reviewer=harness.createUserWithPerms(w,"closure-fin-"+UUID.randomUUID(),"notice:read","finance_order_approval:view","finance_order_approval:approve","finance_order_approval:reject");
        UUID keeper=harness.createUserWithPerms(w,"closure-wh-"+UUID.randomUUID(),"notice:read","warehouse_inbound:view","warehouse_inbound:stock_in");
        var request=new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();request.setBillDate(BusinessTime.today());request.setWarehouseId(w.warehouseId());
        var source=new com.uten.imp.features.purchase.request.dto.RequestItemLine();source.setGoodsId(w.goodsD());source.setUnitId(w.unitId());source.setUnitRate(BigDecimal.ONE);source.setQty(BigDecimal.TEN);source.setGiftQty(BigDecimal.ZERO);request.setItems(List.of(source));
        var requested=requests.create(request);requests.approve(requested.getId());
        var order=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();order.setBillDate(BusinessTime.today());order.setSupplierId(w.supplierId());order.setWarehouseId(w.warehouseId());
        order.setCurrencyId(db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class));order.setExchangeRate(BigDecimal.ONE);order.setTaxRate(BigDecimal.ZERO);
        order.setSettlementMethodId(db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1",UUID.class));
        var line=new com.uten.imp.features.purchase.order.dto.OrderItemLine();line.setGoodsId(w.goodsD());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(BigDecimal.TEN);line.setGiftQty(BigDecimal.ZERO);line.setPrice(BigDecimal.TEN);line.setRequestItemId(requested.getItems().getFirst().getId());order.setItems(List.of(line));
        var created=orders.create(order);var initial=finance.submit("PURCHASE",created.getId());
        var f=new Fixture(w,reviewer,keeper,requested.getId(),requested.getItems().getFirst().getId(),created.getId(),created.getItems().getFirst().getId());
        harness.loginAs(reviewer);finance.approveBatch(List.of(decision(initial)),null);owner(f);return f;
    }
    private Target target(Fixture f) {return new Target("PURCHASE",f.order());}
    private FinanceApproval submit(Fixture f,String mode) {owner(f);var p=closure.preview("PURCHASE",f.order());assertThat(p.canSubmit()).isTrue();return closure.submit("PURCHASE",f.order(),new ClosureRequest(mode,"供应商终止供货",p.fingerprint()));}
    private BatchDecisionItem decision(FinanceApproval p) {var claim=claims.claim("PROCUREMENT_FINANCE_APPROVE",p.caseId().toString());return new BatchDecisionItem(p.caseId(),p.version(),claim.claimId());}
    private UUID draft(Fixture f) {owner(f);return receipts.create(receiptRequest(f)).getId();}
    private com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest receiptRequest(Fixture f) {
        var request=new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(f.world().supplierId());request.setWarehouseId(f.world().warehouseId());
        var line=new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();line.setGoodsId(f.world().goodsD());line.setUnitId(f.world().unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(BigDecimal.ONE);line.setGiftQty(BigDecimal.ZERO);line.setOrderItemId(f.item());request.setItems(List.of(line));return request;
    }
    private void owner(Fixture f) {harness.loginAs(f.world().superAdminUserId());}
    private long caseCount(Fixture f,String state) {return count("SELECT COUNT(*) FROM procurement_order_approval_cases WHERE order_id=? AND request_type<>'ORDER' AND status=?",f.order(),state);}
    private long count(String sql,Object...args) {return db.queryForObject(sql,Long.class,args);}
    private BigDecimal number(String sql,Object...args) {return db.queryForObject(sql,BigDecimal.class,args);}
    private void assertOpen(Fixture f) {assertThat(db.queryForObject("SELECT termination_case_id IS NULL AND NOT is_closed FROM purchase_orders WHERE id=?",Boolean.class,f.order())).isTrue();assertThat(db.queryForObject("SELECT status FROM inbound_expectations WHERE order_type='PURCHASE' AND order_id=?",String.class,f.order())).isEqualTo("OPEN");}
    private void assertClosed(Fixture f) {assertThat(db.queryForObject("SELECT termination_case_id IS NOT NULL AND is_closed FROM purchase_orders WHERE id=?",Boolean.class,f.order())).isTrue();assertThat(db.queryForObject("SELECT status FROM inbound_expectations WHERE order_type='PURCHASE' AND order_id=?",String.class,f.order())).isEqualTo("CLOSED");}
    private String facts(Fixture f) {return table("purchase_orders","id",f.order())+table("purchase_order_items","order_id",f.order())+table("purchase_request_items","id",f.source())+table("procurement_order_approval_cases","order_id",f.order())+table("procurement_order_termination_sources","order_id",f.order())+table("inbound_expectations","order_id",f.order())+table("business_outbox","aggregate_id",f.order());}
    private String table(String table,String column,UUID id) {return db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(fact) ORDER BY fact.id),'[]'::jsonb)::text FROM "+table+" fact WHERE fact."+column+"=?",String.class,id);}
    private void drain() {int processed=0;while(outbox.processNext()){if(++processed>1000)throw new AssertionError("Outbox did not quiesce");}}
    private <T> T actor(UUID user,Callable<T> action) throws Exception {harness.loginAs(user);try{return action.call();}finally{SecurityContextHolder.clearContext();}}
    private List<Outcome> race(Callable<?> first,Callable<?> second) throws Exception {
        var ready=new CountDownLatch(2);var start=new CountDownLatch(1);var pool=Executors.newFixedThreadPool(2);
        try {
            List<java.util.concurrent.Future<Outcome>> results=new ArrayList<>();
            for(var action:List.of(first,second))results.add(pool.submit(()->{ready.countDown();if(!start.await(20,TimeUnit.SECONDS))throw new AssertionError("Concurrent start timed out");try{return new Outcome(true,null,action.call());}catch(RuntimeException failure){return new Outcome(false,failure,null);}}));
            assertThat(ready.await(20,TimeUnit.SECONDS)).isTrue();start.countDown();
            return List.of(results.get(0).get(45,TimeUnit.SECONDS),results.get(1).get(45,TimeUnit.SECONDS));
        } finally {start.countDown();pool.shutdownNow();assertThat(pool.awaitTermination(10,TimeUnit.SECONDS)).isTrue();}
    }
}
