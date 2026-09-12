package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryProductionCostPort;
import com.uten.imp.application.port.InventoryValuationPort;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.time.OffsetDateTime;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Real PostgreSQL claims, inventory locks and transactions; domain callbacks are controlled
 * durable effects here. Actual monetary/replay integration also runs in SubcontractLossValueEndToEndTest. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class InventoryValueWorkConcurrencyPostgresTest {
    private static final PostgreSQLContainer<?> PG=new PostgreSQLContainer<>("postgres:16-alpine")
            .withCommand("postgres","-c","statement_timeout=10s","-c","lock_timeout=5s");
    private static EntityManagerFactory factory;
    private static JpaTransactionManager manager;
    private static JdbcTemplate jdbc;
    private static NamedParameterJdbcTemplate db;
    private InventoryMutationLock mutex;
    private InventoryProductionCostPort production;
    private InventoryValueWorkService worker;
    private final AtomicReference<Refresh> business=new AtomicReference<>();
    private final AtomicReference<Recalculate> dirty=new AtomicReference<>();
    private static final OffsetDateTime TIME=OffsetDateTime.parse("2026-09-12T00:00:00Z");
    @FunctionalInterface interface Refresh { void run(UUID scope,UUID event,UUID actor); }
    @FunctionalInterface interface Recalculate { void run(InventoryValuationPort.EventContext event,UUID scope,long version); }

    @BeforeAll static void start() {
        PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        jdbc=new JdbcTemplate(source);db=new NamedParameterJdbcTemplate(source);
        var bean=new LocalContainerEntityManagerFactoryBean();bean.setDataSource(source);
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());bean.setPackagesToScan("com.uten.imp.features.common.taskclaim");
        bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none"));bean.afterPropertiesSet();factory=bean.getObject();
        manager=new JpaTransactionManager(factory);manager.setDataSource(source);
        jdbc.execute("CREATE TABLE stock_value_pools(id uuid PRIMARY KEY,goods_id uuid NOT NULL,color_id uuid)");
        jdbc.execute("CREATE TABLE stock_value_production_cost_objects(execution_segment_id uuid PRIMARY KEY,product_pool_id uuid,source_kind text,version bigint,state text,business_refresh_pending boolean,business_refresh_event_id uuid,business_refresh_actor_id uuid)");
        jdbc.execute("CREATE TABLE stock_value_nodes(id uuid PRIMARY KEY,pool_id uuid,owner_kind text,owner_id uuid,active boolean)");
        jdbc.execute("CREATE TABLE stock_value_production_cost_inputs(input_node_id uuid,execution_segment_id uuid)");
        jdbc.execute("CREATE TABLE stock_value_production_cost_outputs(source_node_id uuid,execution_segment_id uuid)");
        jdbc.execute("CREATE TABLE subcontract_receipt_material_consumptions(receipt_item_id uuid,issue_item_id uuid)");
        jdbc.execute("CREATE TABLE subcontract_material_issue_items(id uuid,order_item_id uuid,goods_id uuid,color_id uuid)");
        jdbc.execute("CREATE TABLE stock_value_production_cost_dirty(input_node_id uuid PRIMARY KEY,execution_segment_id uuid,source_event_id uuid,observed_revision bigint,cleared_revision bigint)");
        jdbc.execute("CREATE TABLE stock_value_events(id uuid PRIMARY KEY,actor_user_id uuid,occurred_at timestamptz)");
        jdbc.execute("CREATE TABLE stock_value_jobs(event_id uuid,status text)");
        jdbc.execute("CREATE TABLE stock_value_tasks(id uuid,status text)");
        jdbc.execute("CREATE TABLE stock_value_production_cost_tasks(id uuid,status text)");
        jdbc.execute("CREATE TABLE applied_refresh(scope uuid,event uuid,actor uuid,kind text,version bigint,PRIMARY KEY(scope,event,kind))");
    }
    @AfterAll static void stop() { if(factory!=null)factory.close();PG.stop(); }
    @BeforeEach void setup() {
        jdbc.execute("TRUNCATE stock_value_pools,stock_value_production_cost_objects,stock_value_nodes,stock_value_production_cost_inputs,stock_value_production_cost_outputs,subcontract_receipt_material_consumptions,subcontract_material_issue_items,stock_value_production_cost_dirty,stock_value_events,stock_value_jobs,stock_value_tasks,stock_value_production_cost_tasks,applied_refresh");
        mutex=spy(new InventoryMutationLock(SharedEntityManagerCreator.createSharedEntityManager(factory)));
        var values=mock(InventoryValuationPort.class);production=mock(InventoryProductionCostPort.class);
        when(values.pendingWork(anyInt())).thenReturn(List.of());when(production.pendingWork(anyInt())).thenReturn(List.of());
        when(production.pendingRecalculations(anyInt())).thenReturn(List.of());
        var material=mock(ProductionInventoryValueService.class);var subcontract=mock(SubcontractOwnMaterialCostService.class);
        var support=mock(InventoryBusinessValueSupport.class);
        when(support.context(anyString(),any(UUID.class),any(UUID.class),any(UUID.class),any(UUID.class),any(OffsetDateTime.class)))
                .thenAnswer(i->new InventoryValuationPort.EventContext(i.getArgument(1),i.getArgument(0),i.getArgument(2),i.getArgument(3),1,
                        i.getArgument(4),UUID.fromString("50000000-0000-4000-8000-000000000001"),"worker-test-"+i.getArgument(1),i.getArgument(5)));
        business.set((scope,event,actor)->applyBusiness(scope,event,actor));
        dirty.set((event,scope,version)->applyDirty(event,scope,version));
        doAnswer(i->{business.get().run(i.getArgument(0),i.getArgument(1),i.getArgument(2));return null;})
                .when(material).refresh(any(),any(),any());
        doAnswer(i->{business.get().run(i.getArgument(0),i.getArgument(1),i.getArgument(2));return null;})
                .when(subcontract).refresh(any(),any(),any());
        when(production.recalculate(any(),any(),anyLong())).thenAnswer(i->{
            dirty.get().run(i.getArgument(0),i.getArgument(1),i.getArgument(2));
            return new InventoryProductionCostPort.Revised(UUID.randomUUID(),i.getArgument(1),(long)i.getArgument(2)+1,0,
                    InventoryProductionCostPort.CostState.FINAL,false);
        });
        worker=new InventoryValueWorkService(values,production,mutex,manager);
        worker.configureSourceRecalculations(db,support,material,subcontract);
    }

    @ParameterizedTest @ValueSource(strings={"PRODUCTION_EXECUTION","SUBCONTRACT_RECEIPT_ITEM","SUBCONTRACT_ORDER_NORMAL_LOSS"})
    void competingBusinessWorkersDoNotReplayAStaleEventAndBusyIsNotGloballyEmpty(String kind) throws Exception {
        Seed seed=seed(kind,true);CountDownLatch entered=new CountDownLatch(1),release=new CountDownLatch(1);
        business.set((scope,event,actor)->{entered.countDown();await(release);applyBusiness(scope,event,actor);});
        var executor=Executors.newFixedThreadPool(2);
        try {
            Future<Integer> first=executor.submit(worker::runBatch);assertTrue(entered.await(5,TimeUnit.SECONDS));
            assertEquals(0,executor.submit(worker::runBatch).get(2,TimeUnit.SECONDS));
            assertTrue(worker.hasPendingWork(),"The first worker still owns uncommitted durable work");
            release.countDown();assertEquals(1,first.get(5,TimeUnit.SECONDS));
            assertEquals(1,count("SELECT count(*) FROM applied_refresh"));
            assertFalse(worker.hasPendingWork());assertEquals(1,version(seed));
        } finally { release.countDown();executor.shutdownNow();assertTrue(executor.awaitTermination(5,TimeUnit.SECONDS)); }
    }

    @Test void eventAndActorArrivingWhileInventoryIsHeldReplaceTheOldDiscovery() throws Exception {
        Seed seed=seed("PRODUCTION_EXECUTION",true);UUID nextEvent=UUID.randomUUID(),nextActor=UUID.randomUUID();
        var future=new AtomicReference<Future<Integer>>();var executor=Executors.newSingleThreadExecutor();
        CountDownLatch attempted=signalWorkerLock();
        try {
            new TransactionTemplate(manager).executeWithoutResult(status->{
                mutex.lock(seed.key());future.set(executor.submit(()->{Thread.currentThread().setName("blocked-value-worker");return worker.runBatch();}));
                await(attempted);
                jdbc.update("UPDATE stock_value_production_cost_objects SET business_refresh_event_id=?,business_refresh_actor_id=? WHERE execution_segment_id=?",nextEvent,nextActor,seed.scope());
            });
            assertEquals(1,future.get().get(5,TimeUnit.SECONDS));
            assertEquals(nextEvent,jdbc.queryForObject("SELECT event FROM applied_refresh",UUID.class));
            assertEquals(nextActor,jdbc.queryForObject("SELECT actor FROM applied_refresh",UUID.class));
            assertFalse(worker.hasPendingWork());
        } finally { executor.shutdownNow();assertTrue(executor.awaitTermination(5,TimeUnit.SECONDS)); }
    }

    @ParameterizedTest @ValueSource(strings={"PRODUCTION_EXECUTION","SUBCONTRACT_RECEIPT_ITEM","SUBCONTRACT_ORDER_NORMAL_LOSS"})
    void refreshFootprintIncludesRegisteredAndNotYetRegisteredActualSources(String kind) {
        Seed seed=seed(kind,true);
        InventoryKey registered=new InventoryKey(UUID.randomUUID(),null);
        InventoryKey waiting=new InventoryKey(UUID.randomUUID(),UUID.randomUUID());
        InventoryKey subcontractInput=new InventoryKey(UUID.randomUUID(),null);
        InventoryKey unrelated=new InventoryKey(UUID.randomUUID(),null);
        UUID registeredNode=node(seed.scope(),registered,"OTHER",true);
        jdbc.update("INSERT INTO stock_value_production_cost_inputs VALUES(?,?)",registeredNode,seed.scope());
        // Legal outputs keep product goods/color even when their physical pool
        // differs. This duplicates the global inventory key intentionally.
        UUID output=node(seed.scope(),seed.key(),"OTHER",true);
        jdbc.update("INSERT INTO stock_value_production_cost_outputs VALUES(?,?)",output,seed.scope());
        node(seed.scope(),waiting,"COST_WIP",true);
        node(seed.scope(),unrelated,"COST_WIP",false);
        UUID issue=UUID.randomUUID();
        jdbc.update("INSERT INTO subcontract_material_issue_items VALUES(?,?,?,?)",issue,
                kind.equals("SUBCONTRACT_ORDER_NORMAL_LOSS")?seed.scope():UUID.randomUUID(),subcontractInput.goodsId(),subcontractInput.colorId());
        if(kind.equals("SUBCONTRACT_RECEIPT_ITEM"))
            jdbc.update("INSERT INTO subcontract_receipt_material_consumptions VALUES(?,?)",seed.scope(),issue);
        business.set((scope,event,actor)->{
            mutex.requireHeld(registered);mutex.requireHeld(waiting);mutex.requireHeld(seed.key());
            if(kind.startsWith("SUBCONTRACT_"))mutex.requireHeld(subcontractInput);
            else assertThrows(IllegalStateException.class,()->mutex.requireHeld(subcontractInput));
            assertThrows(IllegalStateException.class,()->mutex.requireHeld(unrelated));
            applyBusiness(scope,event,actor);
        });
        assertEquals(1,worker.runBatch());assertFalse(worker.hasPendingWork());
    }

    @Test void aNewInputKeyRollsBackTheIncompleteFootprintAndRemainsPendingForRetry() throws Exception {
        Seed seed=seed("PRODUCTION_EXECUTION",true);
        InventoryKey input=new InventoryKey(UUID.fromString("00000001-0000-4000-8000-000000000001"),null);
        var future=new AtomicReference<Future<Integer>>();var executor=Executors.newSingleThreadExecutor();CountDownLatch attempted=signalWorkerLock();
        try {
            new TransactionTemplate(manager).executeWithoutResult(status->{
                mutex.lockAll(List.of(input,seed.key()));
                future.set(executor.submit(()->{Thread.currentThread().setName("blocked-value-worker");return worker.runBatch();}));await(attempted);
                UUID pool=UUID.randomUUID();jdbc.update("INSERT INTO stock_value_pools VALUES(?,?,NULL)",pool,input.goodsId());
                jdbc.update("INSERT INTO stock_value_nodes VALUES(?,?, 'COST_WIP',?,TRUE)",UUID.randomUUID(),pool,seed.scope());
            });
            assertEquals(0,future.get().get(5,TimeUnit.SECONDS));assertTrue(worker.hasPendingWork());assertEquals(0,count("SELECT count(*) FROM applied_refresh"));
            business.set((scope,event,actor)->{mutex.requireHeld(input);applyBusiness(scope,event,actor);});
            assertEquals(1,worker.runBatch());assertFalse(worker.hasPendingWork());
        } finally { executor.shutdownNow();assertTrue(executor.awaitTermination(5,TimeUnit.SECONDS)); }
    }

    @Test void failedRefreshRollsBackItsWritesAndReleasesTheWorkerClaim() {
        Seed seed=seed("PRODUCTION_EXECUTION",true);
        business.set((scope,event,actor)->{applyBusiness(scope,event,actor);throw new IllegalStateException("controlled callback failure");});
        assertThrows(IllegalStateException.class,worker::runBatch);assertEquals(0,version(seed));
        assertEquals(0,count("SELECT count(*) FROM applied_refresh"));assertTrue(worker.hasPendingWork());
        business.set(this::applyBusiness);assertEquals(1,worker.runBatch());assertFalse(worker.hasPendingWork());
    }

    @Test void staleDirtyProjectionIsRecheckedAfterInventoryAndNeverBypassesAnUnfinishedSourceJob() throws Exception {
        Seed seed=seed("PRODUCTION_EXECUTION",false);UUID input=UUID.randomUUID();
        jdbc.update("INSERT INTO stock_value_production_cost_dirty VALUES(?,?,?,1,0)",input,seed.scope(),seed.event());
        jdbc.update("INSERT INTO stock_value_events VALUES(?,?,?)",seed.event(),seed.actor(),TIME);
        when(production.pendingRecalculations(anyInt())).thenReturn(List.of(new InventoryProductionCostPort.Recalculation(seed.scope(),seed.event(),0)));
        UUID latest=UUID.randomUUID(),actor=UUID.randomUUID();
        var future=new AtomicReference<Future<Integer>>();var executor=Executors.newSingleThreadExecutor();CountDownLatch attempted=signalWorkerLock();
        try {
            new TransactionTemplate(manager).executeWithoutResult(status->{
                mutex.lock(seed.key());future.set(executor.submit(()->{Thread.currentThread().setName("blocked-value-worker");return worker.runBatch();}));await(attempted);
                jdbc.update("INSERT INTO stock_value_events VALUES(?,?,?)",latest,actor,TIME.plusDays(1));
                jdbc.update("INSERT INTO stock_value_jobs VALUES(?,'PENDING')",latest);
                jdbc.update("UPDATE stock_value_production_cost_objects SET version=5 WHERE execution_segment_id=?",seed.scope());
                jdbc.update("UPDATE stock_value_production_cost_dirty SET observed_revision=4,source_event_id=? WHERE input_node_id=?",latest,input);
            });
            assertEquals(0,future.get().get(5,TimeUnit.SECONDS));assertEquals(0,count("SELECT count(*) FROM applied_refresh"));assertTrue(worker.hasPendingWork());
            jdbc.update("UPDATE stock_value_jobs SET status='APPLIED' WHERE event_id=?",latest);
            assertEquals(1,worker.runBatch());
            assertEquals(latest,jdbc.queryForObject("SELECT event FROM applied_refresh",UUID.class));
            assertEquals(actor,jdbc.queryForObject("SELECT actor FROM applied_refresh",UUID.class));assertEquals(6,version(seed));
            assertEquals(0,worker.runBatch(),"An old dirty discovery must not recalculate a cleared scope");assertFalse(worker.hasPendingWork());
        } finally { executor.shutdownNow();assertTrue(executor.awaitTermination(5,TimeUnit.SECONDS)); }
    }

    @Test void concurrentDirtyWorkersOnlyCommitOneRevision() throws Exception {
        Seed seed=seed("PRODUCTION_EXECUTION",false);
        jdbc.update("INSERT INTO stock_value_production_cost_dirty VALUES(?,?,?,1,0)",UUID.randomUUID(),seed.scope(),seed.event());
        jdbc.update("INSERT INTO stock_value_events VALUES(?,?,?)",seed.event(),seed.actor(),TIME);
        when(production.pendingRecalculations(anyInt())).thenReturn(List.of(new InventoryProductionCostPort.Recalculation(seed.scope(),seed.event(),0)));
        CountDownLatch entered=new CountDownLatch(1),release=new CountDownLatch(1);
        dirty.set((event,scope,version)->{entered.countDown();await(release);applyDirty(event,scope,version);});
        var executor=Executors.newFixedThreadPool(2);
        try {
            Future<Integer> first=executor.submit(worker::runBatch);assertTrue(entered.await(5,TimeUnit.SECONDS));
            assertEquals(0,executor.submit(worker::runBatch).get(2,TimeUnit.SECONDS));assertTrue(worker.hasPendingWork());
            release.countDown();assertEquals(1,first.get(5,TimeUnit.SECONDS));assertEquals(1,version(seed));assertFalse(worker.hasPendingWork());
        } finally { release.countDown();executor.shutdownNow();assertTrue(executor.awaitTermination(5,TimeUnit.SECONDS)); }
    }

    private CountDownLatch signalWorkerLock() {
        CountDownLatch attempted=new CountDownLatch(1);AtomicBoolean first=new AtomicBoolean();
        doAnswer(i->{if(Thread.currentThread().getName().equals("blocked-value-worker")&&first.compareAndSet(false,true))attempted.countDown();return i.callRealMethod();})
                .when(mutex).lockAll(anyCollection());
        return attempted;
    }
    private record Seed(UUID scope,InventoryKey key,UUID event,UUID actor) {}
    private Seed seed(String kind,boolean pending) {
        UUID scope=UUID.randomUUID(),pool=UUID.randomUUID(),event=UUID.randomUUID(),actor=UUID.randomUUID();
        InventoryKey key=new InventoryKey(UUID.fromString("f0000000-0000-4000-8000-000000000001"),null);
        jdbc.update("INSERT INTO stock_value_pools VALUES(?,?,NULL)",pool,key.goodsId());
        jdbc.update("INSERT INTO stock_value_production_cost_objects VALUES(?,?,?,0,'PROVISIONAL',?,?,?)",scope,pool,kind,pending,event,actor);
        return new Seed(scope,key,event,actor);
    }
    private UUID node(UUID scope,InventoryKey key,String owner,boolean active) {
        UUID pool=UUID.randomUUID(),node=UUID.randomUUID();
        jdbc.update("INSERT INTO stock_value_pools VALUES(?,?,?)",pool,key.goodsId(),key.colorId());
        jdbc.update("INSERT INTO stock_value_nodes VALUES(?,?,?,?,?)",node,pool,owner,scope,active);
        return node;
    }
    private void applyBusiness(UUID scope,UUID event,UUID actor) {
        requireProduct(scope);
        jdbc.update("INSERT INTO applied_refresh SELECT execution_segment_id,?,?,'BUSINESS',version+1 FROM stock_value_production_cost_objects WHERE execution_segment_id=?",event,actor,scope);
        jdbc.update("UPDATE stock_value_production_cost_objects SET version=version+1,business_refresh_pending=FALSE WHERE execution_segment_id=?",scope);
    }
    private void applyDirty(InventoryValuationPort.EventContext event,UUID scope,long expectedVersion) {
        requireProduct(scope);assertEquals(expectedVersion,jdbc.queryForObject("SELECT version FROM stock_value_production_cost_objects WHERE execution_segment_id=?",Long.class,scope));
        jdbc.update("INSERT INTO applied_refresh VALUES(?,?,?,'DIRTY',?)",scope,event.sourceEventId(),event.actorUserId(),expectedVersion+1);
        jdbc.update("UPDATE stock_value_production_cost_objects SET version=version+1 WHERE execution_segment_id=?",scope);
        jdbc.update("UPDATE stock_value_production_cost_dirty SET cleared_revision=observed_revision WHERE execution_segment_id=?",scope);
    }
    private void requireProduct(UUID scope) { UUID goods=jdbc.queryForObject("SELECT p.goods_id FROM stock_value_production_cost_objects o JOIN stock_value_pools p ON p.id=o.product_pool_id WHERE o.execution_segment_id=?",UUID.class,scope);mutex.requireHeld(new InventoryKey(goods,null)); }
    private long version(Seed seed) { return jdbc.queryForObject("SELECT version FROM stock_value_production_cost_objects WHERE execution_segment_id=?",Long.class,seed.scope()); }
    private int count(String sql) { return jdbc.queryForObject(sql,Integer.class); }
    private static void await(CountDownLatch latch) { try{if(!latch.await(5,TimeUnit.SECONDS))throw new AssertionError("Coordination timeout");}catch(InterruptedException e){Thread.currentThread().interrupt();throw new AssertionError(e);} }
}
