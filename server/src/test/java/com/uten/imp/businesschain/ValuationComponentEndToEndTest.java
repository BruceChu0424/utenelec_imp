package com.uten.imp.businesschain;

import com.uten.imp.application.port.InventoryValuationPort;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.finance.BusinessPrecisionRequiredException;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.gl.InventoryCostPostingService;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocDetail;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.MigratedSchemaBaseline;
import com.uten.imp.testsupport.FixtureDatabaseProperties;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.*;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.time.YearMonth;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.Supplier;

import static org.assertj.core.api.Assertions.*;

/** Real documents, physical movements and GL. Historical fixture edits metadata only; all business guards stay on. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=false","uten.policy-intelligence.enabled=false","uten.inventory.value-work.enabled=false",
        "uten.workshop-material.auto-close.enabled=false",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only", // gitleaks:allow synthetic test key.
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", // gitleaks:allow synthetic test key.
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_EACH_TEST_METHOD)
@TestExecutionListeners(listeners=ValuationComponentEndToEndTest.Cleanup.class,mergeMode=TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class ValuationComponentEndToEndTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static final List<MigratedSchemaBaseline.ScopedDatabase> databases=new ArrayList<>();
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry)throws Exception{
        database=MigratedSchemaBaseline.openDatabase("valuation_components");
        databases.add(database);
        FixtureDatabaseProperties.bindSameRole(registry,database::getJdbcUrl,database::getUsername,database::getPassword);
        String storage=java.nio.file.Files.createTempDirectory("uten-value-components-").toString();
        registry.add("uten.storage.local-dir",()->storage);
    }
    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder(){return new DirtiesContextTestExecutionListener().getOrder()-1;}
        @Override public void afterTestClass(TestContext ignored)throws Exception{for(var lease:databases)lease.close();databases.clear();}
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired StockDocService stock;
    @Autowired SalesShipmentService shipments;
    @Autowired InventoryValuationPort values;
    @Autowired InventoryCostPostingService posting;
    @Autowired InventoryMutationLock mutex;
    @Autowired PlatformTransactionManager transactions;
    @Autowired TxSessionVars vars;
    @Autowired com.uten.imp.features.stock.valuation.InventoryValueWorkService valueWorker;
    @Autowired com.uten.imp.application.port.InventoryProductionCostPort production;
    private FullChainEndToEndTest fixture;

    @BeforeEach void prepare(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @ParameterizedTest(name="historical source base={0}, new delta={1}")
    @CsvSource({"0,1","0,0.000000000000000000000001","0.9999,1"})
    void newLateCostRequiresItsOwnChoiceAndReversesOnlyItsRecordedOrigin(String baseText,String deltaText)throws Exception{
        Case c=soldOneFromHistoricalSource(baseText);
        Map<String,String> oldGl=glFacts(c.goods());
        BigDecimal oldCogs=amount("SELECT coalesce(sum(amount_delta_local),0) FROM stock_value_postings WHERE owner_kind='COGS' AND owner_id=?",c.shipmentItem());
        BigDecimal oldSourceInitial=amount("SELECT initial_known_value FROM stock_value_nodes WHERE id=?",c.source());
        Map<String,Long> before=writeCounts(c.goods());
        CostChange command=costChange(c,deltaText,"late-cost",new BigDecimal(baseText).signum()==0);

        Throwable refusal=catchThrowable(()->adjust(c,command,Map.of()));
        assertThat(refusal).as("A new 1/3 delta must request explicit precision before any source/job/task/GL write").isNotNull();
        var required=BusinessPrecisionRequiredException.from(refusal);
        assertThat(required).as("A temporary legacy guard or a worker failure is not precision negotiation; actual=%s",refusal.getClass().getName()).isPresent();
        assertThat(required.orElseThrow().details()).containsEntry("notWritten",true);
        String purpose=required.orElseThrow().details().get("calculationKey").toString();
        assertThat(writeCounts(c.goods())).isEqualTo(before);
        assertThat(amount("SELECT source_amount_exact FROM stock_value_nodes WHERE id=?",c.source())).isEqualByComparingTo(baseText);
        assertThat(amount("SELECT initial_known_value FROM stock_value_nodes WHERE id=?",c.source())).isEqualByComparingTo(oldSourceInitial);

        Map<String,BusinessPrecisionContext.Choice> explicit=Map.of(purpose,new BusinessPrecisionContext.Choice(24,"DOWN"));
        InventoryValuationPort.AdjustmentValue applied=adjust(c,command,explicit);
        assertThat(applied.replayed()).isFalse();
        assertThat(values.pool(c.pool()).state()).as("Committed ancestor work must not publish an old known zero as final").isEqualTo(InventoryValuationPort.State.PENDING);
        assertThat(values.pool(c.pool()).propagationPending()).isTrue();
        Map<String,Long> committed=writeCounts(c.goods());
        // Lost response: replay the exact original body/key and original explicit header.
        assertThat(adjust(c,command,explicit).replayed()).isTrue();
        assertThat(writeCounts(c.goods())).isEqualTo(committed);
        drain(c);
        BigDecimal delta=new BigDecimal(deltaText),third=delta.divide(new BigDecimal("3"),24,java.math.RoundingMode.DOWN);
        assertThat(amount("SELECT owned_value_local FROM stock_value_nodes WHERE id=?",c.issue())).isEqualByComparingTo(oldCogs.add(third));
        assertThat(balance(c)).isEqualByComparingTo(new BigDecimal(baseText).subtract(oldCogs).add(delta.subtract(third)));
        assertThat(values.pool(c.pool()).state()).isEqualTo(InventoryValuationPort.State.FINAL);
        postReadyCurrentPeriod();
        assertThat(glCogs(c.goods())).isEqualByComparingTo(oldCogs.add(third));
        assertThat(glFacts(c.goods())).containsAllEntriesOf(oldGl);
        assertThat(amount("SELECT initial_known_value FROM stock_value_nodes WHERE id=?",c.source())).isEqualByComparingTo(oldSourceInitial);

        var reverse=context(c,"reverse-origin");
        inPrecision(Map.of(purpose,new BusinessPrecisionContext.Choice(0,"HALF_UP")),()->locked(c,()->values.reverseAdjustment(reverse,applied.eventId())));
        drain(c);
        assertThat(amount("SELECT owned_value_local FROM stock_value_nodes WHERE id=?",c.issue())).isEqualByComparingTo(oldCogs);
        assertThat(balance(c)).isEqualByComparingTo(new BigDecimal(baseText).subtract(oldCogs));
        assertThat(amount("SELECT source_amount_exact FROM stock_value_nodes WHERE id=?",c.source())).isEqualByComparingTo(baseText);
        assertThat(glFacts(c.goods())).containsAllEntriesOf(oldGl);
        assertThat(amount("SELECT coalesce(sum(amount_delta_local),0) FROM stock_value_postings WHERE owner_kind='COGS' AND owner_id=?",c.shipmentItem())).isEqualByComparingTo(oldCogs);
        if(new BigDecimal(baseText).signum()==0){
            assertThat(values.pool(c.pool()).state()).as("Inverse restores original unknown cost, never confirmed free stock").isEqualTo(InventoryValuationPort.State.PENDING);
        }
        if(new BigDecimal(baseText).signum()!=0||third.signum()!=0)postReadyCurrentPeriod();
        else assertThatThrownBy(this::postReadyCurrentPeriod).isInstanceOf(ApiException.class);
        assertThat(glCogs(c.goods())).isEqualByComparingTo(oldCogs);
        assertThat(glFacts(c.goods())).containsAllEntriesOf(oldGl);
        Map<String,Long> reversed=writeCounts(c.goods());
        assertThat(inPrecision(Map.of(purpose,new BusinessPrecisionContext.Choice(0,"HALF_UP")),()->locked(c,()->values.reverseAdjustment(reverse,applied.eventId()))).replayed()).isTrue();
        assertThat(writeCounts(c.goods())).isEqualTo(reversed);
        assertAllGuardsRestored(c);
    }

    @Test void committedLateCostBlocksANewPhysicalSuccessorUntilRestartedWorkerDrainsAndRetainsFiniteTwentySixPlaces()throws Exception{
        Case c=soldOneFromHistoricalSource("0");
        var outgoing=create(c.world(),"OTHER_OUT","0.5",null);
        var command=costChange(c,"1","concurrent-source-total",true);
        String purpose=requiredPurpose(c,command);
        var explicit=Map.of(purpose,new BusinessPrecisionContext.Choice(24,"DOWN"));
        CountDownLatch sourceWritten=new CountDownLatch(1),commitAllowed=new CountDownLatch(1),successorStarted=new CountDownLatch(1);
        ExecutorService workers=Executors.newFixedThreadPool(2);
        try{
            Future<InventoryValuationPort.AdjustmentValue> source=workers.submit(()->{
                fixture.loginAs(c.world().superAdminUserId());
                try{return inPrecision(explicit,()->new TransactionTemplate(transactions).execute(status->{
                    vars.bind();mutex.lock(new InventoryKey(c.goods(),null));
                    var result=executeCostChange(command);sourceWritten.countDown();await(commitAllowed);return result;
                }));}finally{SecurityContextHolder.clearContext();}
            });
            assertThat(sourceWritten.await(20,TimeUnit.SECONDS)).isTrue();
            Future<Throwable> successor=workers.submit(()->{
                fixture.loginAs(c.world().superAdminUserId());successorStarted.countDown();
                try{return catchThrowable(()->stock.approve(outgoing.getId()));}finally{SecurityContextHolder.clearContext();}
            });
            assertThat(successorStarted.await(10,TimeUnit.SECONDS)).isTrue();
            commitAllowed.countDown();
            InventoryValuationPort.AdjustmentValue original=source.get(30,TimeUnit.SECONDS);
            assertThat(successor.get(30,TimeUnit.SECONDS)).as("New dependent edge must be proved unwritten while ancestor work is durable")
                    .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
            assertThat(stock.detail(outgoing.getId()).getStatus()).isZero();
            assertThat(amount("SELECT count(*) FROM stock_movements WHERE source_doc_id=?",outgoing.getId())).isZero();
            assertThat(amount("SELECT qty FROM stock_document_items WHERE doc_id=?",outgoing.getId())).isEqualByComparingTo("0.5");
            assertThat(balance(c)).isZero();
            assertThat(values.pool(c.pool()).state()).isEqualTo(InventoryValuationPort.State.PENDING);
            // No process-local preview state is reused: a subsequent transaction resumes the original durable tasks.
            drain(c);
            fixture.loginAs(c.world().superAdminUserId());stock.approve(outgoing.getId());
            BigDecimal actual=amount("SELECT known_value_local FROM stock_value_events WHERE source_doc_id=? AND operation='ISSUE'",outgoing.getId());
            assertThat(actual).isEqualByComparingTo("0.16666666666666666666666675");
            assertThat(actual.stripTrailingZeros().scale()).isEqualTo(26);
            inPrecision(Map.of(purpose,new BusinessPrecisionContext.Choice(0,"HALF_UP")),()->locked(c,()->values.reverseAdjustment(context(c,"after-new-slice"),original.eventId())));
            drain(c);
            assertThat(balance(c)).isZero();
            assertThat(amount("SELECT coalesce(sum(amount_delta_local),0) FROM stock_value_postings posting JOIN stock_value_nodes node ON node.id=posting.node_id JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=? AND posting.owner_kind IN('COGS','EXTERNAL')",c.goods())).isZero();
            assertAllGuardsRestored(c);
        }finally{commitAllowed.countDown();workers.shutdownNow();assertThat(workers.awaitTermination(10,TimeUnit.SECONDS)).isTrue();}
    }

    @Test void oneKnownFeeDoesNotConfirmAnOtherwiseUnknownSourceOrItsShipmentCost(){
        Case c=soldOneFromHistoricalSource("0");
        CostChange fee=costChange(c,"1","known-fee-unknown-base",false);
        String purpose=requiredPurpose(c,fee);
        var applied=adjust(c,fee,Map.of(purpose,new BusinessPrecisionContext.Choice(24,"DOWN")));drain(c);
        assertThat(amount("SELECT source_amount_exact FROM stock_value_nodes WHERE id=?",c.source())).isEqualByComparingTo("1");
        assertThat(db.queryForObject("SELECT source_final FROM stock_value_nodes WHERE id=?",Boolean.class,c.source())).isFalse();
        assertThat(values.pool(c.pool()).state()).isEqualTo(InventoryValuationPort.State.PENDING);
        assertThat(db.queryForObject("SELECT pending FROM v_stock_actual_sales_cost_coverage WHERE shipment_item_id=?",Boolean.class,c.shipmentItem())).isTrue();
        assertThatThrownBy(this::postReadyCurrentPeriod).isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
        assertThat(glCogs(c.goods())).isZero();
        inPrecision(Map.of(purpose,new BusinessPrecisionContext.Choice(0,"HALF_UP")),()->locked(c,()->values.reverseAdjustment(context(c,"fee-unknown-base-reverse"),applied.eventId())));drain(c);
        assertThat(balance(c)).isZero();assertThat(values.pool(c.pool()).state()).isEqualTo(InventoryValuationPort.State.PENDING);
        assertAllGuardsRestored(c);
    }

    private String requiredPurpose(Case c,CostChange command){
        Throwable refusal=catchThrowable(()->adjust(c,command,Map.of()));
        var precision=BusinessPrecisionRequiredException.from(refusal);
        assertThat(precision).as("The real source rehearsal must return the missing precision before writing; actual=%s",refusal==null?"NONE":refusal.getClass().getName()).isPresent();
        return precision.orElseThrow().details().get("calculationKey").toString();
    }

    @Test void lateMaterialDeltaRehearsesThroughTheRealProductionShareAndCrossGoodsShipmentBeforeWriting(){
        var w=fixture.seedWorld("component-production-"+UUID.randomUUID());fixture.loginAs(w.superAdminUserId());fixture.seedChartOfAccounts();
        var policy=posting.policy();posting.configure(new InventoryCostPostingService.PolicyChange(true,BusinessTime.today().withDayOfMonth(1),"匿名实际生产原投入与成品成本对账",policy.version()));
        var made=fixture.produceFinishedFromOpeningInputs(w,w.goodsA(),"3","3");
        InventoryValueWorkTestSupport.drain(valueWorker,db,List.of(w.goodsA(),w.goodsB(),w.goodsE()));
        var request=fixture.shipmentRequest(w,made.orderItemId(),w.goodsA(),"1");request.setBillDate(BusinessTime.today());
        UUID shipment=shipments.create(request).getId();fixture.shipThroughWarehouse(shipment);
        InventoryValueWorkTestSupport.drain(valueWorker,db,List.of(w.goodsA(),w.goodsB(),w.goodsE()));
        postReadyCurrentPeriod();assertThat(glCogs(w.goodsA())).isEqualByComparingTo("30");
        var originalGl=glFacts(w.goodsA());
        UUID materialSource=db.queryForObject("SELECT node.id FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=? AND node.kind='SOURCE'",UUID.class,w.goodsE());
        UUID incoming=db.queryForObject("SELECT event.source_doc_id FROM stock_value_nodes node JOIN stock_value_events event ON event.id=node.creation_event_id WHERE node.id=?",UUID.class,materialSource);
        UUID productSource=db.queryForObject("SELECT source_node_id FROM stock_value_production_cost_outputs output JOIN stock_value_nodes node ON node.id=output.source_node_id JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=?",UUID.class,w.goodsA());
        UUID shipmentItem=db.queryForObject("SELECT id FROM sales_shipment_items WHERE shipment_id=? AND NOT is_deleted",UUID.class,shipment);
        Case material=new Case(w,incoming,materialSource,null,shipmentItem,new InventoryValuationPort.PoolKey(w.warehouseId(),w.goodsE(),null));
        Case product=new Case(w,made.finishedInId(),productSource,null,shipmentItem,new InventoryValuationPort.PoolKey(w.warehouseId(),w.goodsA(),null));
        markExistingValueFactsAsHistoricalV1(material);markExistingValueFactsAsHistoricalV1(product);
        Map<String,Long> before=writeCounts(w.goodsE());
        var command=costChange(material,"1","production-late-delta",false);
        String purpose=requiredPurpose(material,command);
        assertThat(writeCounts(w.goodsE())).isEqualTo(before);
        assertThat(amount("SELECT source_amount_exact FROM stock_value_nodes WHERE id=?",materialSource)).isEqualByComparingTo("30");
        var applied=adjust(material,command,Map.of(purpose,new BusinessPrecisionContext.Choice(24,"DOWN")));
        drain(material);
        UUID scope=db.queryForObject("SELECT DISTINCT input.execution_segment_id FROM stock_value_production_cost_inputs input JOIN stock_value_nodes node ON node.id=input.input_node_id JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=?",UUID.class,w.goodsE());
        // Execute the existing worker's real source refresh phase, including its original claim/lock/recheck order.
        Boolean refreshed=org.springframework.test.util.ReflectionTestUtils.invokeMethod(valueWorker,"withRefreshLocks",scope,
                (Supplier<Boolean>)()->org.springframework.test.util.ReflectionTestUtils.invokeMethod(valueWorker,"recalculatePendingSource",scope));
        assertThat(refreshed).isTrue();
        var work=production.pendingWork(100).stream().filter(task->task.inputPool().goodsId().equals(w.goodsE())).findFirst().orElseThrow();
        // Honour the same root FIFO used by a real worker. An unchanged other
        // input may precede E; apply that actual metadata task, keeping E's
        // monetary task as the transaction interrupted below.
        for(var preceding:production.pendingWork(100)){
            if(preceding.taskId().equals(work.taskId()))break;
            new TransactionTemplate(transactions).executeWithoutResult(status->{
                vars.bind();mutex.lockAll(List.of(new InventoryKey(preceding.inputPool().goodsId(),preceding.inputPool().colorId()),new InventoryKey(preceding.outputPool().goodsId(),preceding.outputPool().colorId())));
                assertThat(production.apply(preceding.taskId()).applied()).isTrue();
            });
        }
        Map<String,Long> beforeInterruptedTask=writeCounts(w.goodsE());
        String originalShare=db.queryForObject("SELECT to_jsonb(share)::text FROM stock_value_production_cost_shares share WHERE input_node_id=(SELECT input_node_id FROM stock_value_production_cost_tasks WHERE id=?) AND output_source_node_id=?",String.class,work.taskId(),productSource);
        assertThatThrownBy(()->new TransactionTemplate(transactions).executeWithoutResult(status->{
            vars.bind();mutex.lockAll(List.of(new InventoryKey(work.inputPool().goodsId(),work.inputPool().colorId()),new InventoryKey(work.outputPool().goodsId(),work.outputPool().colorId())));
            assertThat(production.apply(work.taskId()).applied()).isTrue();
            throw new TaskInterruptedBeforeCommit();
        })).isInstanceOf(TaskInterruptedBeforeCommit.class);
        assertThat(writeCounts(w.goodsE())).isEqualTo(beforeInterruptedTask);
        assertThat(db.queryForObject("SELECT status FROM stock_value_production_cost_tasks WHERE id=?",String.class,work.taskId())).isEqualTo("PENDING");
        assertThat(db.queryForObject("SELECT to_jsonb(share)::text FROM stock_value_production_cost_shares share WHERE input_node_id=(SELECT input_node_id FROM stock_value_production_cost_tasks WHERE id=?) AND output_source_node_id=?",String.class,work.taskId(),productSource)).isEqualTo(originalShare);
        // A newly constructed real runner resumes the same durable task; no preview or JVM-local result is reused.
        org.springframework.test.util.ReflectionTestUtils.invokeMethod(fixture,"drainCostsWithFreshRunnerWithoutSession",w);
        assertThat(amount("SELECT basis_value_local FROM stock_value_nodes WHERE id=?",productSource)).isEqualByComparingTo("91");
        assertThat(amount("SELECT initial_known_value FROM stock_value_nodes WHERE id=?",productSource)).isZero();
        assertThat(amount("SELECT coalesce(sum(owned_value_local),0) FROM stock_value_nodes WHERE owner_kind='COGS' AND owner_id=?",shipmentItem)).isEqualByComparingTo("30.333333333333333333333333");
        postReadyCurrentPeriod();assertThat(glCogs(w.goodsA())).isEqualByComparingTo("30.333333333333333333333333");
        assertThat(glFacts(w.goodsA())).containsAllEntriesOf(originalGl);
        inPrecision(Map.of(purpose,new BusinessPrecisionContext.Choice(0,"HALF_UP")),()->locked(material,()->values.reverseAdjustment(context(material,"production-origin-reverse"),applied.eventId())));
        // The source's stock phase really precedes production recomputation.
        // Keep its negative held adjustment visible and pending, never a final
        // old output snapshot or a fabricated zero while successors wait.
        drain(material);
        assertThat(amount("SELECT node.owned_value_local FROM stock_value_production_cost_inputs input JOIN stock_value_nodes node ON node.id=input.input_node_id WHERE input.execution_segment_id=? AND node.pool_id IN(SELECT id FROM stock_value_pools WHERE goods_id=?)",scope,w.goodsE())).isEqualByComparingTo("-1");
        assertThat(values.pool(product.pool()).state()).isEqualTo(InventoryValuationPort.State.PENDING);
        Throwable prematureGl=catchThrowable(this::postReadyCurrentPeriod);
        InventoryValueWorkTestSupport.drain(valueWorker,db,List.of(w.goodsA(),w.goodsB(),w.goodsE()));
        postReadyCurrentPeriod();assertThat(glCogs(w.goodsA())).isEqualByComparingTo("30");
        assertThat(amount("SELECT basis_value_local FROM stock_value_nodes WHERE id=?",productSource)).isEqualByComparingTo("90");
        assertThat(glFacts(w.goodsA())).containsAllEntriesOf(originalGl);assertAllGuardsRestored(material);
        assertThat(prematureGl).as("An old known output snapshot cannot make the period ready before production dirty work drains").isInstanceOf(ApiException.class);
    }

    @Test void twoProducedSourcesMergeThroughEveryRealPrefixBeforeFiniteFinalCostCanCommit(){
        var w=fixture.seedWorld("two-produced-sources-"+UUID.randomUUID());fixture.loginAs(w.superAdminUserId());fixture.seedChartOfAccounts();
        var policy=posting.policy();posting.configure(new InventoryCostPostingService.PolicyChange(true,BusinessTime.today().withDayOfMonth(1),"实际双产出来源与累计成本前缀",policy.version()));
        org.springframework.test.util.ReflectionTestUtils.invokeMethod(fixture,"receiveOpeningInputsForA",w,"3");
        UUID plan=org.springframework.test.util.ReflectionTestUtils.invokeMethod(fixture,"approvedPlan",w,w.goodsA(),"3","3");
        org.springframework.test.util.ReflectionTestUtils.invokeMethod(fixture,"issueReadyPlanAndMaterials",w,plan);
        UUID planItem=org.springframework.test.util.ReflectionTestUtils.invokeMethod(fixture,"planItemIdFor",plan,w.goodsA());
        UUID orderItem=org.springframework.test.util.ReflectionTestUtils.invokeMethod(fixture,"orderItemIdOfPlan",plan);
        for(String qty:List.of("1","2")){
            // The first partial report really divides the individual 10/20
            // inputs by target 3. Its original user choice is a real fact, not
            // an implicit legacy rounding rule.
            inPrecision(Map.of("stock.value.interval",new BusinessPrecisionContext.Choice(24,"DOWN")),()->{
                UUID report=org.springframework.test.util.ReflectionTestUtils.invokeMethod(fixture,"reportAndApprove",w,planItem,orderItem,w.goodsA(),qty);
                InventoryValueWorkTestSupport.drain(valueWorker,db,List.of(w.goodsA(),w.goodsB(),w.goodsE()));
                UUID incoming=org.springframework.test.util.ReflectionTestUtils.invokeMethod(fixture,"finishedInDocForReport",report);
                org.springframework.test.util.ReflectionTestUtils.invokeMethod(fixture,"confirmFinishedInboundFully",incoming);return null;
            });
            InventoryValueWorkTestSupport.drain(valueWorker,db,List.of(w.goodsA(),w.goodsB(),w.goodsE()));
        }
        assertThat(amount("SELECT count(*) FROM stock_value_production_cost_outputs output JOIN stock_value_nodes node ON node.id=output.source_node_id JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=?",w.goodsA())).isEqualByComparingTo("2");
        var request=fixture.shipmentRequest(w,orderItem,w.goodsA(),"1");request.setBillDate(BusinessTime.today());
        UUID shipment=shipments.create(request).getId();fixture.shipThroughWarehouse(shipment);
        InventoryValueWorkTestSupport.drain(valueWorker,db,List.of(w.goodsA(),w.goodsB(),w.goodsE()));
        postReadyCurrentPeriod();var originalGl=glFacts(w.goodsA());
        UUID shipmentItem=db.queryForObject("SELECT id FROM sales_shipment_items WHERE shipment_id=? AND NOT is_deleted",UUID.class,shipment);
        UUID source=db.queryForObject("SELECT node.id FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=? AND node.kind='SOURCE'",UUID.class,w.goodsE());
        UUID incoming=db.queryForObject("SELECT event.source_doc_id FROM stock_value_nodes node JOIN stock_value_events event ON event.id=node.creation_event_id WHERE node.id=?",UUID.class,source);
        Case material=new Case(w,incoming,source,null,shipmentItem,new InventoryValuationPort.PoolKey(w.warehouseId(),w.goodsE(),null));
        var command=costChange(material,"3","finite-final-needs-prefix-choice",false);
        Map<String,Long> before=writeCounts(w.goodsE());
        String purpose=requiredPurpose(material,command);
        assertThat(writeCounts(w.goodsE())).isEqualTo(before);
        // 93/3 is finite 31. A real intermediate merged pool still divides by 3.
        var applied=adjust(material,command,Map.of(purpose,new BusinessPrecisionContext.Choice(24,"DOWN")));
        org.springframework.test.util.ReflectionTestUtils.invokeMethod(fixture,"drainCostsWithFreshRunnerWithoutSession",w);
        assertThat(amount("SELECT sum(node.owned_value_local) FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=? AND node.owner_kind='COGS'",w.goodsA())).isEqualByComparingTo("31");
        assertThat(amount("SELECT amount_local FROM stock_balances WHERE goods_id=?",w.goodsA())).isEqualByComparingTo("62");
        postReadyCurrentPeriod();assertThat(glCogs(w.goodsA())).isEqualByComparingTo("31");assertThat(glFacts(w.goodsA())).containsAllEntriesOf(originalGl);
        inPrecision(Map.of(purpose,new BusinessPrecisionContext.Choice(0,"HALF_UP")),()->locked(material,()->values.reverseAdjustment(context(material,"two-source-original-inverse"),applied.eventId())));
        org.springframework.test.util.ReflectionTestUtils.invokeMethod(fixture,"drainCostsWithFreshRunnerWithoutSession",w);
        postReadyCurrentPeriod();assertThat(glCogs(w.goodsA())).isEqualByComparingTo("30");
        assertThat(amount("SELECT amount_local FROM stock_balances WHERE goods_id=?",w.goodsA())).isEqualByComparingTo("60");
        assertThat(glFacts(w.goodsA())).containsAllEntriesOf(originalGl);
    }

    @Test void actualWorkshopCloseAndReopenReverseBothMaterialCogsSlicesWithoutPretendingTheProductCostKnown(){
        var bench=WorkshopMaterialClosePostgresTest.CloseBench.create(beans,"actual-plan-gl");
        bench.fixture.seedChartOfAccounts();
        bench.confirmInboundAndDrain();
        // This bench reports half of its approved target. Confirm the remaining
        // real direct-material use before asking GL to publish a complete cost;
        // leaving unsettled or declared legal WIP is correctly a source blocker.
        var consume=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest();
        consume.setIdempotencyKey("actual-plan-direct-use:"+UUID.randomUUID());consume.setReason("实际确认整批直接料耗用，期间主料仍待结算");
        var consumeLines=new ArrayList<com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest.Line>();
        for(var row:db.queryForList("SELECT demand.id,clearance.uncleared_qty FROM production_material_demands demand JOIN v_production_material_clearance clearance ON clearance.demand_id=demand.id WHERE demand.plan_id=? AND clearance.uncleared_qty>0",bench.plan)){
            var line=new com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest.Line();line.setDemandId((UUID)row.get("id"));line.setSettlementType("CONSUMED");line.setQtyBase((BigDecimal)row.get("uncleared_qty"));consumeLines.add(line);
        }
        assertThat(consumeLines).isNotEmpty();consume.setLines(consumeLines);beans.getBean(com.uten.imp.features.stock.allocation.ProductionMaterialSettlementService.class).post(bench.plan,consume,bench.admin);
        InventoryValueWorkTestSupport.drain(valueWorker,db,List.of(bench.world.goodsA(),bench.world.goodsB(),bench.world.goodsE()));
        UUID firstMaterial=bench.granule("实际成本主料一","OWN"),secondMaterial=bench.granule("实际成本主料二","OWN");
        bench.edge(bench.world.goodsA(),firstMaterial,"0.2");bench.edge(bench.world.goodsA(),secondMaterial,"0.1");
        bench.stockIn(firstMaterial,"10","10");bench.stockIn(secondMaterial,"10","20");
        var goods=new ArrayList<UUID>(List.of(bench.world.goodsA(),bench.world.goodsB(),bench.world.goodsE(),firstMaterial,secondMaterial));
        InventoryValueWorkTestSupport.drain(valueWorker,db,goods);
        bench.enable(List.of());
        assertThat(amount("SELECT count(*) FROM production_execution_periodic_materials WHERE execution_segment_id=?",bench.segment)).isEqualByComparingTo("2");
        assertThat(db.queryForObject("SELECT business_refresh_pending FROM stock_value_production_cost_objects WHERE execution_segment_id=fn_production_execution_cost_scope(?)",Boolean.class,bench.segment)).isTrue();
        assertThat(values.pool(new InventoryValuationPort.PoolKey(bench.world.warehouseId(),bench.world.goodsA(),null)).state()).isEqualTo(InventoryValuationPort.State.PENDING);
        InventoryValueWorkTestSupport.drain(valueWorker,db,goods);
        bench.issue(firstMaterial,"3",null);bench.issue(secondMaterial,"2",null);
        InventoryValueWorkTestSupport.drain(valueWorker,db,goods);
        var policy=posting.policy();posting.configure(new InventoryCostPostingService.PolicyChange(true,BusinessTime.today().withDayOfMonth(1),"真实内料仓结算与原来源GL反向",policy.version()));
        var request=fixture.shipmentRequest(bench.world,bench.orderItem,bench.world.goodsA(),"1");request.setBillDate(BusinessTime.today());
        UUID shipment=shipments.create(request).getId();fixture.shipThroughWarehouse(shipment);
        InventoryValueWorkTestSupport.drain(valueWorker,db,goods);
        assertThat(catchThrowable(this::postReadyCurrentPeriod)).as("unclosed periodic scope must block GL; facts=%s",db.queryForMap("SELECT (SELECT count(*) FROM production_execution_periodic_materials WHERE execution_segment_id=?) bound,(SELECT scope_complete FROM stock_value_production_cost_revisions WHERE id=object.current_revision_id) complete,object.state,object.business_refresh_pending FROM stock_value_production_cost_objects object WHERE object.execution_segment_id=fn_production_execution_cost_scope(?)",bench.segment,bench.segment)).isInstanceOf(ApiException.class);
        UUID count=bench.startCount(bench.firstPeriod,BusinessTime.today().minusDays(1));
        bench.weighed(count,"actual-one",firstMaterial,"1.8");bench.weighed(count,"actual-two",secondMaterial,"1.4");bench.submit(count);
        var closes=beans.getBean(com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseService.class);
        assertThat(closes.attempt(bench.firstPeriod,com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseService.TriggerKind.AFTER_COUNT,bench.admin))
            .isEqualTo(com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseService.Result.CLOSED);
        InventoryValueWorkTestSupport.drain(valueWorker,db,goods);postReadyCurrentPeriod();
        BigDecimal closedCost=amount("SELECT sum(node.owned_value_local) FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=? AND node.owner_kind='COGS'",bench.world.goodsA());
        assertThat(closedCost).isEqualByComparingTo("32.4");assertThat(glCogs(bench.world.goodsA())).isEqualByComparingTo(closedCost);
        // Reuse the actual approved plan through its existing source-refresh
        // port. This creates real zero-share knowledge tasks after the last
        // monetary posting, so UUID ordering cannot hide the pending-state tail.
        UUID costScope=db.queryForObject("SELECT fn_production_execution_cost_scope(?)",UUID.class,bench.segment);
        UUID causalEvent=db.queryForObject("SELECT task.value_event_id FROM stock_value_production_cost_tasks task WHERE task.execution_segment_id=? AND task.status='APPLIED' AND task.desired_value_local>task.before_share_local ORDER BY task.task_sequence DESC LIMIT 1",UUID.class,costScope);
        long beforeKnowledgeVersion=production.position(costScope).version();
        new TransactionTemplate(transactions).executeWithoutResult(status->{
            vars.bind();mutex.lockAll(goods.stream().map(goodsId->new InventoryKey(goodsId,null)).toList());
            production.recalculate(new InventoryValuationPort.EventContext(causalEvent,"PRODUCTION_SOURCE_RECALCULATE",costScope,costScope,beforeKnowledgeVersion+1,
                bench.admin,bench.world.employeeId(),"actual-wm-knowledge-tail:"+UUID.randomUUID(),java.time.OffsetDateTime.now()),costScope,beforeKnowledgeVersion);
        });
        InventoryValueWorkTestSupport.drain(valueWorker,db,goods);
        assertThat(glCogs(bench.world.goodsA())).isEqualByComparingTo(closedCost);
        assertThat(amount("SELECT count(*) FROM stock_value_production_cost_tasks task JOIN stock_value_production_cost_revisions revision ON revision.id=task.revision_id WHERE revision.execution_segment_id=? AND revision.version>? AND task.before_share_local=task.desired_value_local",costScope,beforeKnowledgeVersion)).isGreaterThan(BigDecimal.ZERO);
        var originalGl=glFacts(bench.world.goodsA());
        bench.login();
        inPrecision(Map.of("stock.value.interval",new BusinessPrecisionContext.Choice(0,"HALF_UP")),()->closes.reopen(bench.firstPeriod,
            new com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseDtos.ReopenRequest(bench.periodVersion(bench.firstPeriod),"按原真实主料来源撤结算","actual-plan-reopen:"+UUID.randomUUID())));
        InventoryValueWorkTestSupport.drain(valueWorker,db,goods);
        assertThat(amount("SELECT sum(node.owned_value_local) FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=? AND node.owner_kind='COGS'",bench.world.goodsA())).isEqualByComparingTo("30");
        assertThat(values.pool(new InventoryValuationPort.PoolKey(bench.world.warehouseId(),bench.world.goodsA(),null)).state()).isEqualTo(InventoryValuationPort.State.PENDING);
        postReadyCurrentPeriod();
        if(glCogs(bench.world.goodsA()).compareTo(new BigDecimal("30"))!=0)System.out.println("WM_WITHDRAWAL_PROOFS "+db.queryForList("""
            SELECT cost.posting_id,cost.amount_local,cost.posting_status,event.valuation_root_id,revision.revision,node.revision current_head,
              fn_inventory_cost_storno_head_proven(node.id,revision.revision,event.id,revision.after_projection) head_proven,
              (SELECT count(*) FROM fn_inventory_cost_exact_storno_candidates(NULL,cost.posting_id)) candidate,
              fn_inventory_value_producer_withdrawal_proof(producer.id) producer_proof,
              inverse.before_pending_contribution inverse_edge_before_pending,inverse.target_pending inverse_edge_after_pending,
              original.before_pending_contribution original_edge_before_pending,original.target_pending original_edge_after_pending,
              revision.before_pending inverse_node_before_pending,revision.after_pending inverse_node_after_pending,
              original_revision.before_pending original_node_before_pending,original_revision.after_pending original_node_after_pending,
              fn_inventory_value_restore_knowledge_bridge_proven(original.id,inverse.id) knowledge_bridge
            FROM v_inventory_cost_gl_status cost JOIN stock_value_nodes node ON node.id=cost.node_id
            JOIN stock_value_pools pool ON pool.id=node.pool_id JOIN stock_value_events event ON event.id=cost.event_id
            JOIN stock_value_node_revisions revision ON revision.node_id=node.id AND revision.event_id=event.id
            LEFT JOIN stock_value_production_cost_tasks producer ON producer.value_event_id=event.id
            JOIN stock_value_tasks inverse ON inverse.id=revision.task_id
            LEFT JOIN stock_value_tasks original ON original.id=inverse.restores_task_id
            LEFT JOIN stock_value_node_revisions original_revision ON original_revision.node_id=node.id AND original_revision.task_id=original.id
            WHERE pool.goods_id=? AND cost.amount_local<0 ORDER BY revision.revision
            """,bench.world.goodsA()));
        assertThat(glCogs(bench.world.goodsA())).isEqualByComparingTo("30");
        System.out.println("WM_METADATA_KNOWLEDGE_BRIDGED "+amount("""
            SELECT count(*) FROM stock_value_postings posting JOIN stock_value_nodes node ON node.id=posting.node_id
            JOIN stock_value_pools pool ON pool.id=node.pool_id JOIN inventory_cost_gl_links linked ON linked.posting_id=posting.id
            JOIN stock_value_tasks inverse ON inverse.id=posting.task_id JOIN stock_value_tasks original ON original.id=inverse.restores_task_id
            JOIN stock_value_node_revisions inverse_revision ON inverse_revision.node_id=node.id AND inverse_revision.task_id=inverse.id
            JOIN stock_value_node_revisions original_revision ON original_revision.node_id=node.id AND original_revision.task_id=original.id
            WHERE pool.goods_id=? AND posting.amount_delta_local<0
             AND (inverse.before_pending_contribution IS DISTINCT FROM original.target_pending OR inverse_revision.before_pending IS DISTINCT FROM original_revision.after_pending)
             AND fn_inventory_value_restore_knowledge_bridge_proven(original.id,inverse.id)
            """,bench.world.goodsA()));
        assertThat(glFacts(bench.world.goodsA())).containsAllEntriesOf(originalGl);
    }

    @Test void theHundredAndFirstRealPeriodicInputResumesWithTheOriginalPolicyAfterAllJavaRequestStateIsGone(){
        var bench=new WorkshopMaterialClosePostgresTest.CloseBench();beans.autowireBean(bench);
        bench.fixture=new FullChainEndToEndTest();beans.autowireBean(bench.fixture);
        bench.world=bench.fixture.seedWorld("real-periodic-101-"+UUID.randomUUID());bench.admin=bench.world.superAdminUserId();bench.login();
        org.springframework.test.util.ReflectionTestUtils.invokeMethod(bench.fixture,"receiveOpeningInputsForA",bench.world,"3");
        bench.plan=org.springframework.test.util.ReflectionTestUtils.invokeMethod(bench.fixture,"approvedPlan",bench.world,bench.world.goodsA(),"3","3");
        org.springframework.test.util.ReflectionTestUtils.invokeMethod(bench.fixture,"issueReadyPlanAndMaterials",bench.world,bench.plan);
        bench.planItem=org.springframework.test.util.ReflectionTestUtils.invokeMethod(bench.fixture,"planItemIdFor",bench.plan,bench.world.goodsA());
        bench.orderItem=org.springframework.test.util.ReflectionTestUtils.invokeMethod(bench.fixture,"orderItemIdOfPlan",bench.plan);
        bench.segment=db.queryForObject("SELECT id FROM production_execution_segments WHERE source_plan_item_id=? AND NOT is_deleted ORDER BY created_at LIMIT 1",UUID.class,bench.planItem);
        var assigned=db.queryForMap("SELECT workshop_department_id,responsible_employee_id FROM production_execution_segments WHERE id=?",bench.segment);
        bench.workshop=(UUID)assigned.get("workshop_department_id");bench.receiver=(UUID)assigned.get("responsible_employee_id");
        bench.kg=org.springframework.test.util.ReflectionTestUtils.invokeMethod(bench,"massUnit");
        org.springframework.test.util.ReflectionTestUtils.invokeMethod(bench.fixture,"startedSegmentFor",bench.world,bench.plan,bench.planItem,bench.orderItem,null);
        var incoming=new StockDocSaveRequest();incoming.setDocType("OTHER_IN");incoming.setBillDate(BusinessTime.today());incoming.setWarehouseId(bench.world.warehouseId());
        var incomingLines=new ArrayList<StockDocItemLine>();
        for(int i=0;i<101;i++){
            UUID material=bench.granule("实际101来源主料-"+i,"OWN");bench.edge(bench.world.goodsA(),material,"0.333333333333333333333333");
            var line=new StockDocItemLine();line.setGoodsId(material);line.setUnitId(bench.kg);line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal("2"));line.setPrice(BigDecimal.ONE);
            line.setAmountOriginal(new BigDecimal("2"));line.setAmountLocal(new BigDecimal("2"));incomingLines.add(line);
        }
        incoming.setItems(incomingLines);stock.approve(stock.create(incoming).getId());
        var goods=new ArrayList<UUID>(List.of(bench.world.goodsA(),bench.world.goodsB(),bench.world.goodsE()));goods.addAll(bench.granules);
        InventoryValueWorkTestSupport.drain(valueWorker,db,goods);bench.enable(List.of());
        // Bind the actual periodic inputs while this segment is still open.
        // A completed segment is deliberately not retrofitted by enablement.
        assertThat(amount("SELECT count(*) FROM production_execution_periodic_materials WHERE execution_segment_id=?",bench.segment)).isEqualByComparingTo("101");
        bench.report=org.springframework.test.util.ReflectionTestUtils.invokeMethod(bench.fixture,"reportAndApprove",bench.world,bench.planItem,bench.orderItem,bench.world.goodsA(),"3");
        bench.confirmInboundAndDrain();
        var issueLines=bench.granules.stream().map(material->new com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.DirectIssueLine(material,null,null,new BigDecimal("2"),bench.world.warehouseId())).toList();
        bench.requisitions.directIssue(new com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.DirectIssueRequest(bench.workshop,bench.receiver,issueLines,null,"actual-101-issue:"+UUID.randomUUID()));
        InventoryValueWorkTestSupport.drain(valueWorker,db,goods);
        var policy=Map.of("stock.value.interval",new BusinessPrecisionContext.Choice(24,"DOWN"),"workshop.material.waste-rate",new BusinessPrecisionContext.Choice(24,"DOWN"),"goods.bom.actual-usage",new BusinessPrecisionContext.Choice(24,"DOWN"));
        UUID count=bench.startCount(bench.firstPeriod,BusinessTime.today().minusDays(1));
        for(int i=0;i<bench.granules.size();i++)bench.weighed(count,"actual-101-"+i,bench.granules.get(i),"1");inPrecision(policy,()->bench.submit(count));
        var closes=beans.getBean(com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseService.class);
        assertThat(closes.attempt(bench.firstPeriod,com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseService.TriggerKind.AFTER_COUNT,bench.admin))
            .isEqualTo(com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseService.Result.FAILED);
        assertThat(closes.status(bench.firstPeriod).precisionRequirement()).isNotNull();
        inPrecision(policy,()->closes.retry(bench.firstPeriod,new com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseDtos.RetryRequest("actual-101-close-choice:"+UUID.randomUUID())));
        long closedDeadline=System.nanoTime()+java.time.Duration.ofSeconds(60).toNanos();
        while(!"CLOSED".equals(db.queryForObject("SELECT status FROM workshop_material_periods WHERE id=?",String.class,bench.firstPeriod))&&System.nanoTime()<closedDeadline){
            if("FAILED".equals(db.queryForObject("SELECT close_state FROM workshop_material_periods WHERE id=?",String.class,bench.firstPeriod)))break;
            try{Thread.sleep(50);}catch(InterruptedException interrupted){Thread.currentThread().interrupt();throw new AssertionError(interrupted);}
        }
        assertThat(db.queryForObject("SELECT status FROM workshop_material_periods WHERE id=?",String.class,bench.firstPeriod))
            .as("Actual retry must close with its durable policy; result=%s",closes.status(bench.firstPeriod)).isEqualTo("CLOSED");
        UUID scope=db.queryForObject("SELECT fn_production_execution_cost_scope(?)",UUID.class,bench.segment);
        assertThat(amount("SELECT count(*) FROM stock_value_production_cost_inputs WHERE execution_segment_id=? AND input_kind='PERIODIC_MATERIAL'",scope)).isEqualByComparingTo("100");
        assertThat(db.queryForObject("SELECT business_refresh_pending FROM stock_value_production_cost_objects WHERE execution_segment_id=?",Boolean.class,scope)).isTrue();
        assertThat(BusinessPrecisionContext.choices()).isEmpty();
        long resumedAt=System.nanoTime();
        try{org.springframework.test.util.ReflectionTestUtils.invokeMethod(bench.fixture,"drainCostsWithFreshRunnerWithoutSession",bench.world,java.time.Duration.ofSeconds(120));}
        catch(AssertionError failure){System.out.println("BATCH101_PENDING "+db.queryForList("SELECT object.state,object.business_refresh_pending,cardinality(object.precision_input_ancestor_nodes) input_ancestors,(SELECT count(*) FROM stock_value_production_cost_inputs input WHERE input.execution_segment_id=object.execution_segment_id) registered,(SELECT count(*) FROM stock_value_production_cost_tasks task WHERE task.execution_segment_id=object.execution_segment_id AND task.status='PENDING') producers,(SELECT count(*) FROM stock_value_tasks WHERE status='PENDING') stock,(SELECT count(*) FROM stock_value_production_cost_dirty WHERE observed_revision>cleared_revision) dirty FROM stock_value_production_cost_objects object WHERE object.execution_segment_id=?",scope));throw failure;}
        System.out.println("BATCH101_FRESH_WORKER_MILLIS "+java.time.Duration.ofNanos(System.nanoTime()-resumedAt).toMillis());
        assertThat(valueWorker.hasPendingWork()).isFalse();
        assertThat(amount("SELECT count(*) FROM stock_value_production_cost_inputs WHERE execution_segment_id=? AND input_kind='PERIODIC_MATERIAL'",scope)).isEqualByComparingTo("101");
        assertThat(db.queryForObject("SELECT business_refresh_pending FROM stock_value_production_cost_objects WHERE execution_segment_id=?",Boolean.class,scope)).isFalse();
        assertThat(amount("SELECT max(jsonb_array_length(input_snapshot)) FROM stock_value_production_cost_revisions WHERE execution_segment_id=?",scope)).isEqualByComparingTo("103");
        assertThat(db.queryForObject("SELECT bool_and((request_precision_policy->'choices'->'stock.value.interval'->>'scale')::int=24) FROM stock_value_production_cost_revisions WHERE execution_segment_id=? AND jsonb_array_length(input_snapshot)>=102",Boolean.class,scope)).isTrue();
        assertThat(amount("SELECT sum(source.basis_value_local) FROM stock_value_production_cost_outputs output JOIN stock_value_nodes source ON source.id=output.source_node_id WHERE output.execution_segment_id=?",scope)).isEqualByComparingTo("191");
        assertThat(BusinessPrecisionContext.choices()).isEmpty();
    }

    private Case soldOneFromHistoricalSource(String baseText){
        var w=fixture.seedWorld("component-"+UUID.randomUUID());fixture.loginAs(w.superAdminUserId());fixture.seedChartOfAccounts();
        var policy=posting.policy();
        if(!policy.enabled())posting.configure(new InventoryCostPostingService.PolicyChange(true,BusinessTime.today().withDayOfMonth(1),"匿名实际库存来源新旧成本对账",policy.version()));
        var incoming=create(w,"OTHER_IN","3",new BigDecimal(baseText).signum()==0?null:baseText);stock.approve(incoming.getId());
        UUID order=fixture.createApprovedOrder(w,w.goodsD(),"1","100");fixture.loginAs(w.superAdminUserId());
        UUID orderItem=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,order);
        var request=fixture.shipmentRequest(w,orderItem,w.goodsD(),"1");request.setBillDate(BusinessTime.today());
        UUID shipment=shipments.create(request).getId();fixture.shipThroughWarehouse(shipment);
        UUID item=db.queryForObject("SELECT id FROM sales_shipment_items WHERE shipment_id=? AND NOT is_deleted",UUID.class,shipment);
        UUID source=db.queryForObject("SELECT result_node_id FROM stock_value_events WHERE source_doc_id=? AND operation='RECEIVE'",UUID.class,incoming.getId());
        UUID issue=db.queryForObject("SELECT event.result_node_id FROM stock_value_events event JOIN stock_movements movement ON movement.id=event.movement_id WHERE movement.source_doc_id=? AND movement.direction=-1",UUID.class,shipment);
        Case c=new Case(w,incoming.getId(),source,issue,item,new InventoryValuationPort.PoolKey(w.warehouseId(),w.goodsD(),null));
        if(new BigDecimal(baseText).signum()>0){postReadyCurrentPeriod();assertThat(glCogs(c.goods())).isEqualByComparingTo("0.3333");}
        markExistingValueFactsAsHistoricalV1(c);
        return c;
    }

    /** Produce anonymous historical v1 facts without altering any stored value, quantity, document, source or GL fact. */
    private void markExistingValueFactsAsHistoricalV1(Case c){
        Map<String,String> before=historicalBusinessFacts(c);
        new TransactionTemplate(transactions).executeWithoutResult(status->{
            List<Map<String,Object>> triggers=db.queryForList("""
                    SELECT class.relname table_name,trigger.tgname,trigger.tgenabled::text enabled
                    FROM pg_trigger trigger JOIN pg_class class ON class.oid=trigger.tgrelid
                    JOIN pg_namespace ns ON ns.oid=class.relnamespace JOIN pg_proc fn ON fn.oid=trigger.tgfoid
                    WHERE ns.nspname='public' AND NOT trigger.tgisinternal
                      AND class.relname IN('stock_value_nodes','stock_value_edges','stock_value_events','stock_value_node_revisions')
                      AND (trigger.tgname='trg_00_inventory_value_precision'
                        OR fn.proname IN('fn_guard_stock_value_projection_identity','fn_stock_value_append_only','fn_guard_stock_value_exact_revision_metadata'))
                    ORDER BY class.relname,trigger.tgname
                    """);
            assertThat(triggers).isNotEmpty();
            try{
                for(var trigger:triggers)db.execute("ALTER TABLE "+identifier(trigger.get("table_name"))+" DISABLE TRIGGER "+identifier(trigger.get("tgname")));
                db.update("UPDATE stock_value_nodes SET value_precision_version=1,business_precision_policy=NULL WHERE pool_id IN(SELECT id FROM stock_value_pools WHERE goods_id=?)",c.goods());
                db.update("UPDATE stock_value_edges SET value_precision_version=1,business_precision_policy=NULL WHERE parent_node_id IN(SELECT node.id FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=?)",c.goods());
                db.update("UPDATE stock_value_events SET value_precision_version=1,business_precision_policy=NULL WHERE pool_id IN(SELECT id FROM stock_value_pools WHERE goods_id=?)",c.goods());
                db.update("UPDATE stock_value_node_revisions SET value_precision_version=1,business_precision_policy=NULL WHERE node_id IN(SELECT node.id FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=?)",c.goods());
                // Deferred physical/source guards stay enabled and validate the unchanged facts before trigger mode DDL.
                db.execute("SET CONSTRAINTS ALL IMMEDIATE");
            }finally{
                for(var trigger:triggers){String enabled=trigger.get("enabled").toString();String mode=switch(enabled){case "O"->"ENABLE";case "A"->"ENABLE ALWAYS";case "R"->"ENABLE REPLICA";case "D"->"DISABLE";default->throw new AssertionError("Unknown trigger mode");};db.execute("ALTER TABLE "+identifier(trigger.get("table_name"))+" "+mode+" TRIGGER "+identifier(trigger.get("tgname")));}
            }
        });
        Map<String,String> after=historicalBusinessFacts(c);
        assertThat(after.keySet()).isEqualTo(before.keySet());
        for(var fact:before.entrySet())assertThat(db.queryForObject("SELECT CAST(? AS jsonb)=CAST(? AS jsonb)",Boolean.class,
                fact.getValue(),after.get(fact.getKey()))).as("Historical business facts remain identical: %s",fact.getKey()).isTrue();
        assertThat(amount("SELECT count(*) FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=? AND (node.value_precision_version<>1 OR node.business_precision_policy IS NOT NULL)",c.goods())).isZero();
        assertAllGuardsRestored(c);
    }

    private Map<String,String> historicalBusinessFacts(Case c){
        var facts=new TreeMap<String,String>();
        for(String table:List.of("stock_value_nodes","stock_value_edges","stock_value_events","stock_value_node_revisions")){
            String filter=switch(table){case "stock_value_edges"->"t.parent_node_id IN(SELECT node.id FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=?)";case "stock_value_node_revisions"->"t.node_id IN(SELECT node.id FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=?)";default->"t.pool_id IN(SELECT id FROM stock_value_pools WHERE goods_id=?)";};
            facts.put(table,db.queryForObject("SELECT coalesce(jsonb_agg(to_jsonb(t)-'value_precision_version'-'business_precision_policy' ORDER BY to_jsonb(t)::text),'[]'::jsonb)::text FROM "+table+" t WHERE "+filter,String.class,c.goods()));
        }
        facts.putAll(glFacts(c.goods()));return facts;
    }
    private void assertAllGuardsRestored(Case ignored){
        assertThat(amount("SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid WHERE NOT t.tgisinternal AND c.relname IN('stock_value_nodes','stock_value_edges','stock_value_events','stock_value_node_revisions') AND t.tgenabled='D'")).isZero();
    }
    private StockDocDetail create(FullChainEndToEndTest.World w,String type,String qty,String total){
        var request=new StockDocSaveRequest();request.setDocType(type);request.setBillDate(BusinessTime.today());request.setWarehouseId(w.warehouseId());
        var line=new StockDocItemLine();line.setGoodsId(w.goodsD());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));
        if(total!=null){line.setAmountLocal(new BigDecimal(total));line.setAmountOriginal(new BigDecimal(total));line.setPrice(new BigDecimal(total).divide(new BigDecimal(qty)));}
        request.setItems(List.of(line));return stock.create(request);
    }
    private InventoryValuationPort.EventContext context(Case c,String prefix){UUID event=UUID.randomUUID();UUID item=db.queryForObject("SELECT id FROM stock_document_items WHERE doc_id=? AND goods_id=? AND NOT is_deleted",UUID.class,c.incoming(),c.goods());return new InventoryValuationPort.EventContext(event,"COMPONENT_COST_PROOF",c.incoming(),item,1,c.world().superAdminUserId(),c.world().employeeId(),prefix+":"+event,OffsetDateTime.now());}
    private CostChange costChange(Case c,String amount,String prefix,boolean confirmTotal){return new CostChange(context(c,prefix),c.source(),new BigDecimal(amount),confirmTotal);}
    private InventoryValuationPort.AdjustmentValue executeCostChange(CostChange command){return command.confirmTotal()
            ?values.confirmSourceTotal(new InventoryValuationPort.SourceTotalConfirmation(command.context(),command.source(),command.amount()))
            :values.adjustSource(new InventoryValuationPort.SourceAdjustment(command.context(),command.source(),command.amount(),false));}
    private InventoryValuationPort.AdjustmentValue adjust(Case c,CostChange command,Map<String,BusinessPrecisionContext.Choice> choices){return inPrecision(choices,()->locked(c,()->executeCostChange(command)));}
    private <T>T locked(Case c,Supplier<T> body){return new TransactionTemplate(transactions).execute(status->{vars.bind();mutex.lock(new InventoryKey(c.goods(),null));return body.get();});}
    private <T>T inPrecision(Map<String,BusinessPrecisionContext.Choice> choices,Supplier<T> body){try(var scope=BusinessPrecisionContext.use(choices)){return body.get();}catch(RuntimeException|Error failure){throw failure;}catch(Exception failure){throw new IllegalStateException(failure);}}
    private void drain(Case c){
        for(int round=0;round<200;round++){
            var work=values.pendingWork(100).stream().filter(task->task.lockKey().goodsId().equals(c.goods())).toList();
            if(work.isEmpty()){assertThat(amount("SELECT count(*) FROM stock_value_jobs job JOIN stock_value_nodes node ON node.id=job.source_node_id JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=? AND job.status<>'APPLIED'",c.goods())).isZero();return;}
            for(var task:work)new TransactionTemplate(transactions).executeWithoutResult(status->{vars.bind();mutex.lock(new InventoryKey(task.lockKey().goodsId(),task.lockKey().colorId()));var applied=values.propagate(task.taskId());assertThat(applied.applied()||applied.replayed()||applied.waitingForPriorRevision()).isTrue();});
        }
        fail("Original durable value work did not drain within the bounded fixture");
    }
    private void postReadyCurrentPeriod(){posting.post(YearMonth.from(BusinessTime.today()).toString());}
    private BigDecimal balance(Case c){return amount("SELECT coalesce(sum(amount_local),0) FROM stock_balances WHERE goods_id=?",c.goods());}
    private BigDecimal glCogs(UUID goods){return amount("SELECT coalesce(sum(link.amount_local),0) FROM inventory_cost_gl_links link JOIN stock_value_nodes node ON node.id=link.source_node_id JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=?",goods);}
    private Map<String,String> glFacts(UUID goods){var result=new TreeMap<String,String>();db.query("SELECT link.posting_id::text id,(to_jsonb(link)||jsonb_build_object('voucher',to_jsonb(voucher),'entries',(SELECT jsonb_agg(to_jsonb(entry) ORDER BY line_no) FROM gl_entries entry WHERE entry.voucher_id=voucher.id)))::text fact FROM inventory_cost_gl_links link JOIN gl_vouchers voucher ON voucher.id=link.voucher_id JOIN stock_value_nodes node ON node.id=link.source_node_id JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=?",row->{result.put(row.getString("id"),row.getString("fact"));},goods);return result;}
    private Map<String,Long> writeCounts(UUID goods){var counts=new TreeMap<String,Long>();for(String table:List.of("stock_value_nodes","stock_value_edges","stock_value_events","stock_value_jobs","stock_value_tasks","stock_value_node_revisions","stock_value_postings","stock_value_production_cost_revisions","stock_value_production_cost_tasks","stock_value_production_cost_shares","stock_value_production_cost_dirty","stock_movements","gl_vouchers","gl_entries","inventory_cost_gl_links"))counts.put(table,db.queryForObject("SELECT count(*) FROM "+table,Long.class));return counts;}
    private BigDecimal amount(String sql,Object...args){return db.queryForObject(sql,BigDecimal.class,args);}
    private static String identifier(Object value){String text=value.toString();if(!text.matches("[a-z_][a-z0-9_]*"))throw new AssertionError("Unexpected fixture identifier");return '"'+text+'"';}
    private static void await(CountDownLatch latch){try{if(!latch.await(20,TimeUnit.SECONDS))throw new AssertionError("Concurrent fixture timed out");}catch(InterruptedException failure){Thread.currentThread().interrupt();throw new AssertionError(failure);}}
    private record CostChange(InventoryValuationPort.EventContext context,UUID source,BigDecimal amount,boolean confirmTotal){}
    private static final class TaskInterruptedBeforeCommit extends RuntimeException{}
    private record Case(FullChainEndToEndTest.World world,UUID incoming,UUID source,UUID issue,UUID shipmentItem,InventoryValuationPort.PoolKey pool){UUID goods(){return pool.goodsId();}}
}
