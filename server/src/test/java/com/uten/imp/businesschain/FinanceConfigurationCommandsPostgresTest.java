package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.gl.GlReportLineBindingService;
import com.uten.imp.features.finance.gl.InventoryCostPostingService;
import com.uten.imp.features.finance.payables.ProcurementPayableRecognitionService;
import com.uten.imp.features.finance.FinanceOperationJournal.Cancellation;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.*;
import org.springframework.transaction.support.TransactionTemplate;
import java.time.LocalDate;
import java.util.*;
import java.util.concurrent.*;
import static org.assertj.core.api.Assertions.*;

/** Current migrated schema and actual service transactions, never company data. */
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
class FinanceConfigurationCommandsPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry r){FinanceScopedChainDatabase.register(r,FinanceConfigurationCommandsPostgresTest.class);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired TransactionTemplate transactions;
    @Autowired ProcurementPayableRecognitionService ap;
    @Autowired GlReportLineBindingService bindings;
    @Autowired InventoryCostPostingService inventory;
    @Autowired ObjectMapper json;
    @Autowired com.uten.imp.security.TxSessionVars variables;
    @Autowired com.uten.imp.features.sales.shipment.SalesShipmentService shipments;
    @Autowired com.uten.imp.features.stock.valuation.InventoryValueWorkService valueWorker;
    private FullChainEndToEndTest fixture;
    private FullChainEndToEndTest.World world;
    private UUID actorA,actorB;
    private static final Set<String> READ=Set.of("finance_report:view","ar_ap_ledger:view","finance:view:all","goods:cost:view");
    private static final Set<String> WRITE=Set.of("finance_report:view","ar_ap_ledger:view","finance:view:all","goods:cost:view","supplier_settlement:confirm","finance_post:execute","payment_style:edit");

    @BeforeEach void setup(){
        fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        world=fixture.seedWorld("finance-command-"+UUID.randomUUID().toString().substring(0,8));
        fixture.loginAs(world.superAdminUserId());fixture.seedChartOfAccounts();
        actorA=fixture.createUserWithPerms(world,"command-a-"+UUID.randomUUID().toString().substring(0,8),WRITE.toArray(String[]::new));
        actorB=fixture.createUserWithPerms(world,"command-b-"+UUID.randomUUID().toString().substring(0,8),WRITE.toArray(String[]::new));
        login(actorA,WRITE);
    }
    @AfterEach void cleanup(){SecurityContextHolder.clearContext();}

    @Test void lostApPolicyReplyReturnsItsOwnImmutableResultAfterAnotherActorChangesCurrentPolicy(){
        UUID id=UUID.randomUUID();var first=policy(id,revision(),"匿名第一份首次应付依据");
        var saved=ap.configureCommand(first);
        assertEnvelope(saved,id,actorA,"PROCUREMENT_AP_POLICY_SAVE","PUT","/finance/procurement-payable-recognitions/policy",first);
        long after=((Number)map(saved.get("result")).get("revision")).longValue();
        login(actorB,WRITE);ap.configureCommand(policy(UUID.randomUUID(),after,"匿名后续人员变更依据"));
        login(actorA,WRITE);same(ap.configureCommand(first),saved);same(ap.policyReceipt(id),saved);
        assertThat(ap.policy().get("sourceReference")).isEqualTo("匿名后续人员变更依据");
        assertThat(((Number)ap.policy().get("revision")).longValue()).isEqualTo(after+1);
        assertThat(receipts(id)).isEqualTo(1);
        assertThat(bindings.operationReceipt(id)).containsEntry("found",false);
        assertThat(inventory.operationReceipt(id)).containsEntry("found",false);
        assertThat(ap.policyReceipt(UUID.randomUUID())).containsEntry("found",false);
        login(actorB,WRITE);assertThat(ap.policyReceipt(id)).containsEntry("found",false);
    }

    @Test void missingIdentityChangedBodyAndAnotherActorCannotReuseARequestOrInferSuccessFromCurrentEquality(){
        long before=revision();UUID id=UUID.randomUUID();var command=policy(id,before,"匿名原始完整配置依据");
        ap.configureCommand(command);
        conflict(()->ap.configureCommand(policy(id,before,"匿名不同的请求正文")));
        // A fresh ID with an old version is rejected even if the current values equal
        // that body. Only a stored original receipt proves the earlier operation.
        conflict(()->ap.configureCommand(policy(UUID.randomUUID(),before,command.sourceReference())));
        deniedMissing(()->ap.configureCommand(policy(null,revision(),"匿名缺少原请求的依据")));
        login(actorB,WRITE);conflict(()->ap.configureCommand(command));
        assertThat(revision()).isEqualTo(before+1);assertThat(receipts(id)).isEqualTo(1);
    }

    @Test void losingWriteAuthorityStillAllowsReadingOwnResultButLosingReadAuthorityDoesNot(){
        UUID id=UUID.randomUUID();var command=policy(id,revision(),"匿名原权限内配置依据");var saved=ap.configureCommand(command);
        login(actorA,READ);same(ap.policyReceipt(id),saved);
        forbidden(()->ap.configureCommand(command));
        login(actorA,Set.of());forbidden(()->ap.policyReceipt(id));
        assertThat(receipts(id)).isEqualTo(1);
    }

    @Test void rollbackLeavesNeitherPolicyChangeNorReceiptAndTheOriginalRequestCanThenExecuteOnce(){
        UUID id=UUID.randomUUID();long before=revision();var command=policy(id,before,"匿名事务回滚核验依据");
        transactions.executeWithoutResult(status->{ap.configureCommand(command);status.setRollbackOnly();});
        assertThat(revision()).isEqualTo(before);assertThat(receipts(id)).isZero();
        var saved=ap.configureCommand(command);same(ap.configureCommand(command),saved);
        assertThat(revision()).isEqualTo(before+1);assertThat(receipts(id)).isEqualTo(1);
    }

    @Test void concurrentSameRequestCommitsOnlyOnePolicyVersionAndOneImmutableReceipt()throws Exception{
        long before=revision();UUID id=UUID.randomUUID();var command=policy(id,before,"匿名并发同一原请求依据");
        var gate=new CountDownLatch(1);ExecutorService pool=Executors.newFixedThreadPool(2);
        try{
            Callable<Map<String,Object>> call=()->{login(actorA,WRITE);try{if(!gate.await(20,TimeUnit.SECONDS))throw new AssertionError("request gate timeout");return ap.configureCommand(command);}finally{SecurityContextHolder.clearContext();}};
            var first=pool.submit(call);var second=pool.submit(call);gate.countDown();
            same(first.get(40,TimeUnit.SECONDS),second.get(40,TimeUnit.SECONDS));
        }finally{pool.shutdownNow();}
        login(actorA,WRITE);assertThat(revision()).isEqualTo(before+1);assertThat(receipts(id)).isEqualTo(1);
        assertThatThrownBy(()->transactions.executeWithoutResult(s->db.update("UPDATE finance_application_operations SET result='{}' WHERE request_id=?",id)))
                .hasMessageContaining("immutable");
    }

    @Test void missingReceiptWhileOriginalIsUncommittedDoesNotPermitADuplicateWrite()throws Exception{
        long before=revision();UUID id=UUID.randomUUID();var command=policy(id,before,"匿名在途事务原请求依据");
        var entered=new CountDownLatch(1);var release=new CountDownLatch(1);ExecutorService pool=Executors.newFixedThreadPool(2);
        try{
            var first=pool.submit(()->{login(actorA,WRITE);try{return transactions.execute(status->{
                var result=ap.configureCommand(command);entered.countDown();
                try{if(!release.await(20,TimeUnit.SECONDS))throw new AssertionError("commit gate timeout");}catch(InterruptedException error){Thread.currentThread().interrupt();throw new IllegalStateException(error);}
                return result;
            });}finally{SecurityContextHolder.clearContext();}});
            assertThat(entered.await(20,TimeUnit.SECONDS)).isTrue();
            assertThat(ap.policyReceipt(id)).containsEntry("found",false);
            var retry=pool.submit(()->{login(actorA,WRITE);try{return ap.configureCommand(command);}finally{SecurityContextHolder.clearContext();}});
            org.awaitility.Awaitility.await().atMost(java.time.Duration.ofSeconds(10)).until(()->
                    db.queryForObject("SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND NOT granted",Long.class)>0);
            assertThat(retry.isDone()).isFalse();release.countDown();
            same(first.get(30,TimeUnit.SECONDS),retry.get(30,TimeUnit.SECONDS));
        }finally{release.countDown();pool.shutdownNow();}
        login(actorA,WRITE);assertThat(revision()).isEqualTo(before+1);assertThat(receipts(id)).isEqualTo(1);
    }

    @Test void reportBindingUsesOriginalStateCasAndReturnsOriginalResultWithoutOverwritingLaterChanges(){
        var line=bindings.list().stream().filter(row->row.lineKey().equals("PL_23")).findFirst().orElseThrow();
        UUID id=UUID.randomUUID();var first=new GlReportLineBindingService.ReplaceCommand(id,List.of(),true,line.stateFingerprint());
        var saved=bindings.replaceCommand(line.lineKey(),first);
        assertEnvelope(saved,id,actorA,"GL_REPORT_BINDING_REPLACE","PUT","/finance/reports/gl/line-bindings/PL_23",first);
        var current=bindings.list().stream().filter(row->row.lineKey().equals(line.lineKey())).findFirst().orElseThrow();
        login(actorB,WRITE);bindings.replaceCommand(line.lineKey(),new GlReportLineBindingService.ReplaceCommand(UUID.randomUUID(),List.of(),false,current.stateFingerprint()));
        login(actorA,WRITE);same(bindings.replaceCommand(line.lineKey(),first),saved);same(bindings.operationReceipt(id),saved);
        assertThat(bindings.list().stream().filter(row->row.lineKey().equals(line.lineKey())).findFirst().orElseThrow().confirmedZero()).isFalse();
        conflict(()->bindings.replaceCommand(line.lineKey(),new GlReportLineBindingService.ReplaceCommand(UUID.randomUUID(),List.of(),true,current.stateFingerprint())));
        var defaults=new GlReportLineBindingService.DefaultsCommand(UUID.randomUUID());var seeded=bindings.seedDefaultsCommand(defaults);
        same(bindings.seedDefaultsCommand(defaults),seeded);same(bindings.operationReceipt(defaults.requestId()),seeded);
        login(actorA,READ);same(bindings.operationReceipt(id),saved);forbidden(()->bindings.replaceCommand(line.lineKey(),first));
    }

    @Test void inventoryPolicyPostAndCloseShareReceiptsAndRejectedSourceChoiceDoesNotCreateOne(){
        var old=inventory.policy();UUID id=UUID.randomUUID();
        var first=new InventoryCostPostingService.PolicyCommand(id,true,com.uten.imp.common.time.BusinessTime.today().withDayOfMonth(1),"匿名库存新旧来源对账依据",old.version());
        var saved=inventory.configureCommand(first);
        assertEnvelope(saved,id,actorA,"INVENTORY_COST_POLICY_SAVE","PUT","/finance/gl/inventory-cost/policy",first);
        login(actorB,WRITE);var latest=inventory.policy();
        inventory.configureCommand(new InventoryCostPostingService.PolicyCommand(UUID.randomUUID(),true,latest.effectiveFrom(),"匿名后续库存政策核对依据",latest.version()));
        login(actorA,WRITE);same(inventory.configureCommand(first),saved);same(inventory.operationReceipt(id),saved);
        assertThat(inventory.policy().reconciliationReference()).isEqualTo("匿名后续库存政策核对依据");
        String period="2091-01";var post=new InventoryCostPostingService.PostCommand(UUID.randomUUID());
        var posted=inventory.postCommand(period,post);same(inventory.postCommand(period,post),posted);
        assertThat(map(posted.get("result")).get("newVoucherCount")).isEqualTo(0);
        var close=new InventoryCostPostingService.CloseCommand(UUID.randomUUID(),0,"匿名完整空期间已核对");
        var closed=inventory.closeCommand(period,close);same(inventory.closeCommand(period,close),closed);
        assertThat(map(closed.get("result"))).containsEntry("status","CLOSED");
        same(inventory.operationReceipt(close.requestId()),closed);
        UUID rejected=UUID.randomUUID();
        assertThatThrownBy(()->inventory.choosePeriodCommand(UUID.randomUUID(),new InventoryCostPostingService.PeriodCommand(rejected,period,"匿名不存在来源核对"))).isInstanceOf(ApiException.class);
        assertThat(receipts(rejected)).isZero();
        login(actorA,READ);same(inventory.operationReceipt(id),saved);forbidden(()->inventory.configureCommand(first));
    }

    @Test void actualProducedShipmentsChoosePostAndCloseThroughOriginalReceiptsWithoutPostingLaterSourcesAgain(){
        var policy=inventory.policy();
        inventory.configureCommand(new InventoryCostPostingService.PolicyCommand(UUID.randomUUID(),true,
                com.uten.imp.common.time.BusinessTime.today().withDayOfMonth(1),"匿名实际生产成本源对账依据",policy.version()));
        fixture.loginAs(world.superAdminUserId());
        var made=fixture.produceFinishedFromOpeningInputs(world,world.goodsA(),"3","3");
        drainValues();UUID firstShipment=ship(made.orderItemId());drainValues();
        String target=java.time.YearMonth.from(com.uten.imp.common.time.BusinessTime.today()).plusMonths(1).toString();
        login(actorA,WRITE);
        var firstSources=readyForShipment(firstShipment);assertThat(firstSources).isNotEmpty();
        var choices=new LinkedHashMap<UUID,InventoryCostPostingService.PeriodCommand>();
        var choiceReceipts=new LinkedHashMap<UUID,Map<String,Object>>();
        for(UUID source:firstSources){
            var command=new InventoryCostPostingService.PeriodCommand(UUID.randomUUID(),target,"匿名真实价值来源明确核定期间");
            choices.put(source,command);var result=inventory.choosePeriodCommand(source,command);choiceReceipts.put(source,result);
            assertEnvelope(result,command.requestId(),actorA,"INVENTORY_COST_PERIOD_CHOICE","POST","/finance/gl/inventory-cost/postings/"+source+"/period",command);
        }
        var post=new InventoryCostPostingService.PostCommand(UUID.randomUUID());var posted=inventory.postCommand(target,post);
        assertThat(((Number)map(posted.get("result")).get("newVoucherCount")).intValue()).isEqualTo(firstSources.size());
        long links=db.queryForObject("SELECT count(*) FROM inventory_cost_gl_links",Long.class);
        for(var entry:choices.entrySet())same(inventory.choosePeriodCommand(entry.getKey(),entry.getValue()),choiceReceipts.get(entry.getKey()));
        same(inventory.postCommand(target,post),posted);
        assertThat(db.queryForObject("SELECT count(*) FROM inventory_cost_gl_links",Long.class)).isEqualTo(links);
        fixture.loginAs(world.superAdminUserId());UUID secondShipment=ship(made.orderItemId());drainValues();login(actorA,WRITE);
        var later=readyForShipment(secondShipment);assertThat(later).isNotEmpty();
        for(UUID source:later)inventory.choosePeriodCommand(source,new InventoryCostPostingService.PeriodCommand(UUID.randomUUID(),target,"匿名后续另一真实来源核定期间"));
        same(inventory.postCommand(target,post),posted);
        assertThat(db.queryForObject("SELECT count(*) FROM inventory_cost_gl_links",Long.class)).isEqualTo(links);
        assertThat(inventory.postCommand(target,new InventoryCostPostingService.PostCommand(UUID.randomUUID())).get("found")).isEqualTo(true);
        assertThat(db.queryForObject("SELECT count(*) FROM inventory_cost_gl_links",Long.class)).isEqualTo(links+later.size());
        long version=inventory.periods(target,target).getFirst().version();
        var close=new InventoryCostPostingService.CloseCommand(UUID.randomUUID(),version,"匿名两次实际价值均已完整入账");
        var closed=inventory.closeCommand(target,close);same(inventory.closeCommand(target,close),closed);
        same(inventory.operationReceipt(close.requestId()),closed);
        assertThat(inventory.periods(target,target).getFirst().status()).isEqualTo("CLOSED");
    }

    @Test void unwrittenCancellationSurvivesLostReplyRejectsChangedIdentityAndPreventsLateWritesAfterWriteAuthorityReturns(){
        UUID id=UUID.randomUUID();long before=revision();var command=policy(id,before,"匿名尚未落库的原配置依据");
        var cancel=cancellation(id,"PROCUREMENT_AP_POLICY_SAVE","PUT","/finance/procurement-payable-recognitions/policy",command);
        login(actorA,READ);var stopped=ap.cancelPolicyCommand(id,cancel);
        assertThat(stopped).containsEntry("outcome","CANCELLED_UNWRITTEN");same(ap.policyReceipt(id),stopped);same(ap.cancelPolicyCommand(id,cancel),stopped);
        assertThat(revision()).isEqualTo(before);assertThat(receipts(id)).isEqualTo(1);
        var wrongBody=policy(id,before,"匿名变更过的取消正文依据");
        conflict(()->ap.cancelPolicyCommand(id,cancellation(id,cancel.operation(),cancel.method(),cancel.path(),wrongBody)));
        deniedMissing(()->ap.cancelPolicyCommand(id,new Cancellation(id,actorA,cancel.operation(),"POST",cancel.path(),cancel.requestBody())));
        login(actorB,READ);forbidden(()->ap.cancelPolicyCommand(id,cancel));
        assertThat(ap.policyReceipt(id)).containsEntry("found",false);
        login(actorA,Set.of());forbidden(()->ap.cancelPolicyCommand(id,cancel));
        login(actorA,WRITE);same(ap.configureCommand(command),stopped);assertThat(revision()).isEqualTo(before);
        // A different ID is a new explicit operation, with a freshly read current version.
        ap.configureCommand(policy(UUID.randomUUID(),revision(),command.sourceReference()));assertThat(revision()).isEqualTo(before+1);
    }

    @Test void successfulOriginalWinsCancellationAndRollbackOfAnUnwrittenCancellationDoesNotSealARequest(){
        UUID id=UUID.randomUUID();var command=policy(id,revision(),"匿名已提交成功的原政策依据");var saved=ap.configureCommand(command);
        login(actorA,READ);same(ap.cancelPolicyCommand(id,cancellation(id,"PROCUREMENT_AP_POLICY_SAVE","PUT","/finance/procurement-payable-recognitions/policy",command)),saved);
        assertThat(saved).containsEntry("outcome","SUCCEEDED");
        UUID rollback=UUID.randomUUID();var pending=policy(rollback,revision(),"匿名取消自身回滚的原依据");
        transactions.executeWithoutResult(status->{ap.cancelPolicyCommand(rollback,cancellation(rollback,"PROCUREMENT_AP_POLICY_SAVE","PUT","/finance/procurement-payable-recognitions/policy",pending));status.setRollbackOnly();});
        assertThat(receipts(rollback)).isZero();login(actorA,WRITE);
        assertThat(ap.configureCommand(pending)).containsEntry("outcome","SUCCEEDED");
    }

    @Test void cancellationAndOriginalWriteSerializeToOneDurableOutcomeInBothCommitOrders()throws Exception{
        for(boolean cancelFirst:List.of(false,true)){
            UUID id=UUID.randomUUID();long before=revision();var command=policy(id,before,"匿名取消与原写并发的完整依据");
            var cancel=cancellation(id,"PROCUREMENT_AP_POLICY_SAVE","PUT","/finance/procurement-payable-recognitions/policy",command);
            var entered=new CountDownLatch(1);var release=new CountDownLatch(1);ExecutorService pool=Executors.newFixedThreadPool(2);
            try{
                var first=pool.submit(()->{login(actorA,cancelFirst?READ:WRITE);try{return transactions.execute(status->{
                    var result=cancelFirst?ap.cancelPolicyCommand(id,cancel):ap.configureCommand(command);entered.countDown();await(release);return result;
                });}finally{SecurityContextHolder.clearContext();}});
                assertThat(entered.await(20,TimeUnit.SECONDS)).isTrue();
                var second=pool.submit(()->{login(actorA,cancelFirst?WRITE:READ);try{return cancelFirst?ap.configureCommand(command):ap.cancelPolicyCommand(id,cancel);}finally{SecurityContextHolder.clearContext();}});
                org.awaitility.Awaitility.await().atMost(java.time.Duration.ofSeconds(10)).until(()->db.queryForObject("SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND NOT granted",Long.class)>0);
                assertThat(second.isDone()).isFalse();release.countDown();
                var result=first.get(30,TimeUnit.SECONDS);same(second.get(30,TimeUnit.SECONDS),result);
                assertThat(result).containsEntry("outcome",cancelFirst?"CANCELLED_UNWRITTEN":"SUCCEEDED");
            }finally{release.countDown();pool.shutdownNow();}
            login(actorA,WRITE);assertThat(receipts(id)).isEqualTo(1);assertThat(revision()).isEqualTo(before+(cancelFirst?0:1));
        }
    }

    @Test void cancelledUnknownBindingCannotExecuteLaterEvenWhenItsOriginalCasStateReturns(){
        String line="PL_23";var original=bindings.list().stream().filter(row->row.lineKey().equals(line)).findFirst().orElseThrow();
        UUID id=UUID.randomUUID();var command=new GlReportLineBindingService.ReplaceCommand(id,List.of(),!original.confirmedZero(),original.stateFingerprint());
        login(actorB,WRITE);bindings.replaceCommand(line,new GlReportLineBindingService.ReplaceCommand(UUID.randomUUID(),List.of(),!original.confirmedZero(),original.stateFingerprint()));
        login(actorA,WRITE);conflict(()->bindings.replaceCommand(line,command));assertThat(bindings.operationReceipt(id)).containsEntry("found",false);
        login(actorA,READ);var stopped=bindings.cancelCommand(id,cancellation(id,"GL_REPORT_BINDING_REPLACE","PUT","/finance/reports/gl/line-bindings/"+line,command));
        login(actorB,WRITE);var changed=bindings.list().stream().filter(row->row.lineKey().equals(line)).findFirst().orElseThrow();
        bindings.replaceCommand(line,new GlReportLineBindingService.ReplaceCommand(UUID.randomUUID(),original.targets().stream().map(GlReportLineBindingService.Target::id).toList(),original.confirmedZero(),changed.stateFingerprint()));
        login(actorA,WRITE);same(bindings.replaceCommand(line,command),stopped);
        assertThat(bindings.list().stream().filter(row->row.lineKey().equals(line)).findFirst().orElseThrow().stateFingerprint()).isEqualTo(original.stateFingerprint());
    }

    @Test void allInventoryAndDefaultCommandsCanBeSealedWithReadAuthorityWithoutExecutingBusinessWork(){
        long policyVersion=inventory.policy().version();long periods=db.queryForObject("SELECT count(*) FROM inventory_cost_gl_periods",Long.class);
        String base="/finance/gl/inventory-cost",period="2092-02";UUID posting=UUID.randomUUID();
        var policy=new InventoryCostPostingService.PolicyCommand(UUID.randomUUID(),false,null,"匿名只取消不改变策略",policyVersion);
        var choice=new InventoryCostPostingService.PeriodCommand(UUID.randomUUID(),period,"匿名只取消不选择来源");
        var post=new InventoryCostPostingService.PostCommand(UUID.randomUUID());
        var close=new InventoryCostPostingService.CloseCommand(UUID.randomUUID(),0,"匿名只取消不关闭期间");
        login(actorA,READ);
        var p=inventory.cancelCommand(policy.requestId(),cancellation(policy.requestId(),"INVENTORY_COST_POLICY_SAVE","PUT",base+"/policy",policy));
        var c=inventory.cancelCommand(choice.requestId(),cancellation(choice.requestId(),"INVENTORY_COST_PERIOD_CHOICE","POST",base+"/postings/"+posting+"/period",choice));
        var posted=inventory.cancelCommand(post.requestId(),cancellation(post.requestId(),"INVENTORY_COST_POST","POST",base+"/periods/"+period+"/post",post));
        var closed=inventory.cancelCommand(close.requestId(),cancellation(close.requestId(),"INVENTORY_COST_CLOSE","POST",base+"/periods/"+period+"/close",close));
        var defaults=new GlReportLineBindingService.DefaultsCommand(UUID.randomUUID());
        var seeded=bindings.cancelCommand(defaults.requestId(),cancellation(defaults.requestId(),"GL_REPORT_BINDINGS_SEED","POST","/finance/reports/gl/line-bindings/defaults",defaults));
        for(var result:List.of(p,c,posted,closed,seeded))assertThat(result).containsEntry("outcome","CANCELLED_UNWRITTEN");
        login(actorA,WRITE);same(inventory.configureCommand(policy),p);same(inventory.choosePeriodCommand(posting,choice),c);
        same(inventory.postCommand(period,post),posted);same(inventory.closeCommand(period,close),closed);same(bindings.seedDefaultsCommand(defaults),seeded);
        assertThat(inventory.policy().version()).isEqualTo(policyVersion);
        assertThat(db.queryForObject("SELECT count(*) FROM inventory_cost_gl_periods",Long.class)).isEqualTo(periods);
    }

    @Test void earlierSuccessfulCandidateReceiptGainsAnOutcomeOnlyInItsResponseWithoutChangingStoredBytes()throws Exception{
        UUID id=UUID.randomUUID();var command=policy(id,revision(),"匿名取消协议之前的成功政策依据");
        var committed=ap.configure(new ProcurementPayableRecognitionService.PolicyInput(command.expectedRevision(),command.enabled(),command.effectiveFrom(),command.sourceReference()));
        String operation="PROCUREMENT_AP_POLICY_SAVE",path="/finance/procurement-payable-recognitions/policy";
        var payload=new LinkedHashMap<String,Object>();payload.put("method","PUT");payload.put("path",path);payload.put("requestBody",command);
        var old=new LinkedHashMap<String,Object>();old.put("found",true);old.put("requestId",id);old.put("actorId",actorA);old.put("operation",operation);old.putAll(payload);old.put("result",committed);
        String hash=com.uten.imp.common.storage.ImmutableDocumentStore.digest(json.writeValueAsBytes(Arrays.asList(operation,null,payload)));
        String encoded=json.writeValueAsString(old);
        transactions.executeWithoutResult(status->{variables.bind();db.update("INSERT INTO finance_application_operations(request_id,application_id,actor_id,operation,payload_hash,result)VALUES(?,NULL,?,?,?,?::jsonb)",id,actorA,operation,hash,encoded);});
        String stored=db.queryForObject("SELECT result::text FROM finance_application_operations WHERE request_id=?",String.class,id);
        assertThat(stored).doesNotContain("outcome");
        var response=ap.policyReceipt(id);assertEnvelope(response,id,actorA,operation,"PUT",path,command);
        same(ap.configureCommand(command),response);same(ap.cancelPolicyCommand(id,cancellation(id,operation,"PUT",path,command)),response);
        assertThat(db.queryForObject("SELECT result::text FROM finance_application_operations WHERE request_id=?",String.class,id)).isEqualTo(stored);
        assertThat(revision()).isEqualTo(command.expectedRevision()+1);
    }

    private Cancellation cancellation(UUID id,String operation,String method,String path,Object body){return new Cancellation(id,actorA,operation,method,path,json.valueToTree(body));}
    private static void await(CountDownLatch gate){try{if(!gate.await(20,TimeUnit.SECONDS))throw new AssertionError("commit gate timeout");}catch(InterruptedException error){Thread.currentThread().interrupt();throw new IllegalStateException(error);}}
    private void drainValues(){InventoryValueWorkTestSupport.drain(valueWorker,db,List.of(world.goodsA(),world.goodsB(),world.goodsE()));}
    private UUID ship(UUID orderItem){
        var request=fixture.shipmentRequest(world,orderItem,world.goodsA(),"1");request.setBillDate(com.uten.imp.common.time.BusinessTime.today());
        UUID id=shipments.create(request).getId();fixture.shipThroughWarehouse(id);return id;
    }
    private List<UUID> readyForShipment(UUID shipment){return db.queryForList("SELECT posting_id FROM v_inventory_cost_gl_status WHERE shipment_id=? AND posting_status='READY' ORDER BY posting_id",UUID.class,shipment);}

    private ProcurementPayableRecognitionService.PolicyCommand policy(UUID id,long version,String reference){return new ProcurementPayableRecognitionService.PolicyCommand(id,version,false,null,reference);}
    private long revision(){return ((Number)ap.policy().get("revision")).longValue();}
    private int receipts(UUID id){return db.queryForObject("SELECT count(*) FROM finance_application_operations WHERE request_id=?",Integer.class,id);}
    private void login(UUID actor,Set<String> permissions){
        UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,actor);
        var user=new AuthUser(actor,employee,"anonymous-command-operator",permissions,false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,"",user.getAuthorities()));
    }
    private void assertEnvelope(Map<String,Object> result,UUID id,UUID actor,String operation,String method,String path,Object body){
        assertThat(result).containsEntry("found",true).containsEntry("requestId",id.toString()).containsEntry("actorId",actor.toString())
                .containsEntry("operation",operation).containsEntry("method",method).containsEntry("path",path).containsEntry("outcome","SUCCEEDED");
        same(result.get("requestBody"),body);
    }
    @SuppressWarnings("unchecked")private static Map<String,Object> map(Object value){return (Map<String,Object>)value;}
    private void same(Object actual,Object expected){try{assertThat(json.readTree(json.writeValueAsBytes(actual))).isEqualTo(json.readTree(json.writeValueAsBytes(expected)));}catch(java.io.IOException error){throw new AssertionError(error);}}
    private static void conflict(Runnable action){assertThatThrownBy(action::run).isInstanceOfSatisfying(ApiException.class,e->assertThat(e.getCode()).isEqualTo(ErrorCode.CONFLICT));}
    private static void forbidden(Runnable action){assertThatThrownBy(action::run).satisfies(error->{
        if(error instanceof ApiException api)assertThat(api.getCode()).isEqualTo(ErrorCode.FORBIDDEN);
        else assertThat(error).isInstanceOf(org.springframework.security.access.AccessDeniedException.class);
    });}
    private static void deniedMissing(Runnable action){assertThatThrownBy(action::run).isInstanceOfSatisfying(ApiException.class,e->assertThat(e.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));}
}
