package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryValuationPort.*;
import com.uten.imp.application.port.InventoryOpeningPort.*;
import com.uten.imp.application.port.InventoryLegacyResolutionEvidencePort;
import com.uten.imp.application.port.InventoryLegacyResolutionEvidencePort.ApprovedResolution;
import com.uten.imp.application.port.InventoryLegacyResolutionEvidencePort.ResolutionKind;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.OffsetDateTime;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Supplier;

import static org.assertj.core.api.Assertions.*;

/** Actual value-core migrations plus a minimal stand-in for StockService's sole physical write. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class InventoryValuationCorePostgresTest {
    private static final PostgreSQLContainer<?> DB=new PostgreSQLContainer<>("postgres:16-alpine");
    private static final UUID USER=UUID.randomUUID(),EMPLOYEE=UUID.randomUUID(),WAREHOUSE=UUID.randomUUID(),WAREHOUSE_2=UUID.randomUUID();
    private static final UUID LEGACY_GOODS=UUID.randomUUID();
    private static JdbcTemplate jdbc;
    private static CountingJdbc named;
    private static EntityManagerFactory emf;
    private static EntityManager em;
    private static TransactionTemplate tx;
    private static InventoryMutationLock mutex;
    private static InventoryValuationService service;
    private static InventoryOpeningService openings;

    @BeforeAll static void start() throws Exception {
        DB.start();
        var ds=new DriverManagerDataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword());
        jdbc=new JdbcTemplate(ds);named=new CountingJdbc(ds);
        for(String table:List.of("users","employees","warehouses","goods","colors"))jdbc.execute("CREATE TABLE "+table+"(id uuid PRIMARY KEY)");
        jdbc.update("INSERT INTO users VALUES (?)",USER);jdbc.update("INSERT INTO employees VALUES (?)",EMPLOYEE);
        jdbc.update("INSERT INTO warehouses VALUES (?),(?)",WAREHOUSE,WAREHOUSE_2);jdbc.update("INSERT INTO goods VALUES (?)",LEGACY_GOODS);
        jdbc.execute("""
                CREATE TABLE stock_balances(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),warehouse_id uuid NOT NULL,
                    goods_id uuid NOT NULL,color_id uuid,qty numeric(18,4) NOT NULL,amount_local numeric(18,4),
                    UNIQUE NULLS NOT DISTINCT(warehouse_id,goods_id,color_id))
                """);
        jdbc.execute("""
                CREATE TABLE stock_movements(id uuid PRIMARY KEY,transaction_date timestamptz,movement_type smallint,
                    source_doc_type text NOT NULL,source_doc_id uuid,source_item_id uuid,goods_id uuid NOT NULL,
                    color_id uuid,warehouse_id uuid NOT NULL,direction smallint NOT NULL,qty numeric(18,4) NOT NULL,
                    unit_id uuid,unit_rate numeric(18,6),amount_local numeric(18,4))
                """);
        jdbc.update("INSERT INTO stock_balances(warehouse_id,goods_id,qty,amount_local) VALUES (?,?,7,84)",WAREHOUSE,LEGACY_GOODS);
        String migration;
        try(var in=InventoryValuationCorePostgresTest.class.getResourceAsStream("/db/migration/V500__inventory_value_core.sql")){
            migration=new String(Objects.requireNonNull(in,"V500 migration resource").readAllBytes(),StandardCharsets.UTF_8);
        }
        jdbc.execute(migration);
        // Only the reset policy anchor is needed here; whole-platform reset is independently tested on full Flyway.
        jdbc.execute("CREATE FUNCTION business_data_reset() RETURNS TABLE(table_name text,policy text) LANGUAGE sql AS $$ VALUES ('stock_value_postings', 'CLEAR') $$");
        try(var in=InventoryValuationCorePostgresTest.class.getResourceAsStream("/db/migration/V506__inventory_value_openings_and_legacy_cases.sql")){
            migration=new String(Objects.requireNonNull(in,"V506 migration resource").readAllBytes(),StandardCharsets.UTF_8);
        }
        jdbc.execute(migration);
        var factory=new LocalContainerEntityManagerFactoryBean();factory.setDataSource(ds);
        factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());factory.setPackagesToScan("com.uten.imp.features.common.taskclaim");
        var props=new Properties();props.setProperty("hibernate.hbm2ddl.auto","none");factory.setJpaProperties(props);factory.afterPropertiesSet();
        emf=factory.getObject();em=SharedEntityManagerCreator.createSharedEntityManager(emf);
        tx=new TransactionTemplate(new JpaTransactionManager(emf));mutex=new InventoryMutationLock(em);
        service=new InventoryValuationService(named,mutex);
        openings=new InventoryOpeningService(named,mutex);
    }
    @AfterAll static void stop(){if(emf!=null)emf.close();DB.stop();}

    @Test void actualAverageMergeAndFullIssueLeaveNoResidualValue(){
        PoolKey key=key();receive(key,"10","100",true);receive(key,"10","100",true);
        MovementValue first=issue(key,"7");assertMoney(first.knownValueLocal(),"70");
        MovementValue last=issue(key,"13");assertMoney(last.knownValueLocal(),"130");
        assertBalance(key,"0","0");assertMoney(owned(key,"COGS"),"200");assertThat(service.pool(key).state()).isEqualTo(State.FINAL);
    }

    @Test void legacyFourPlaceParentFeedbackIsNotTheOriginalSourceShareAuthority(){
        // This fixture deliberately installs only frozen V500/V506. It documents
        // why its legacy monetary cache must not be the new exact-model authority.
        PoolKey key=key();MovementValue source=receive(key,"3","1.0001",true);
        MovementValue first=issue(key,"1"),second=issue(key,"1");
        assertMoney(first.knownValueLocal(),"0.3334");assertMoney(second.knownValueLocal(),"0.3334");
        assertBalance(key,"1","0.3333");assertMoney(owned(key,"COGS"),"0.6668");
        BigDecimal original=jdbc.queryForObject("SELECT initial_known_value FROM stock_value_nodes WHERE id=?",BigDecimal.class,source.valueNodeId());
        BigDecimal originalTwoThirdsProjection=jdbc.queryForObject("SELECT round(CAST(? AS numeric)*2/3,4)",BigDecimal.class,original);
        assertMoney(originalTwoThirdsProjection,"0.6667");
        assertThat(owned(key,"COGS")).isNotEqualByComparingTo(originalTwoThirdsProjection);
        // Both issue nodes still have exact 1/3 lineage: first 1/3, second (2/3)*(1/2).
        BigDecimal[] weights=jdbc.queryForObject("""
                SELECT (a.interval_to-a.interval_from) first_n,a.denominator first_d,
                    (b.interval_to-b.interval_from)*(c.interval_to-c.interval_from) second_n,
                    b.denominator*c.denominator second_d
                FROM stock_value_edges a,stock_value_edges b,stock_value_edges c
                WHERE a.parent_node_id=? AND a.child_node_id=? AND b.parent_node_id=?
                  AND b.child_node_id=? AND c.parent_node_id=? AND c.child_node_id=?
                """,(r,i)->new BigDecimal[]{r.getBigDecimal(1),r.getBigDecimal(2),r.getBigDecimal(3),r.getBigDecimal(4)},
                source.poolHeadId(),first.valueNodeId(),source.poolHeadId(),first.poolHeadId(),first.poolHeadId(),second.valueNodeId());
        assertThat(weights[0].multiply(weights[3])).isEqualByComparingTo(weights[2].multiply(weights[1]));
        issue(key,"1");assertBalance(key,"0","0");assertMoney(owned(key,"COGS"),"1.0001");
    }

    @Test void pendingOpeningPreservesOldEvidenceAndLateConfirmedCostFollowsAlreadySoldQuantity(){
        PoolKey key=legacy("7","999");long movements=count("stock_movements");
        OpeningValue opening=opening(key,"7","999",null,false);
        assertThat(opening.state()).isEqualTo(State.PENDING);assertThat(count("stock_movements")).isEqualTo(movements);
        assertBalance(key,"7","0");assertThat(service.pool(key).state()).isEqualTo(State.PENDING);
        assertMoney(jdbc.queryForObject("SELECT observed_recorded_value FROM stock_value_openings WHERE event_id=?",BigDecimal.class,opening.eventId()),"999");
        assertMoney(jdbc.queryForObject("SELECT (before_balance->>'amount_local')::numeric FROM stock_value_openings WHERE event_id=?",BigDecimal.class,opening.eventId()),"999");
        assertMoney(issue(key,"2").knownValueLocal(),"0");
        adjust(key,opening.sourceCostNodeId(),"70",true);drain();
        assertBalance(key,"5","50");assertMoney(owned(key,"COGS"),"20");
        assertThat(service.pool(key).state()).isEqualTo(State.FINAL);
        assertMoney(jdbc.queryForObject("SELECT observed_recorded_value FROM stock_value_openings WHERE event_id=?",BigDecimal.class,opening.eventId()),"999");
        assertThat(jdbc.queryForObject("SELECT opening_mode FROM stock_value_openings WHERE event_id=?",String.class,opening.eventId())).isEqualTo("PENDING_REVIEW");
    }

    @Test void zeroQuantityLegacyResidualIsIsolatedFromEveryFutureReceiptAndCannotBeRepricedIntoIt(){
        PoolKey key=legacy("0","-2000");long movements=count("stock_movements");
        EmptyCycle command=new EmptyCycle(context("INVENTORY_EMPTY_CYCLE"),key,bd("-2000"),"旧出库金额待财务核对；新周期空库存单独开始");
        EmptyCycleValue opening=locked(key,()->openings.startEmptyCycle(command));
        assertThat(count("stock_movements")).isEqualTo(movements);assertBalance(key,"0","0");
        assertThat(opening.legacyState()).isEqualTo(LegacyState.OPEN);
        assertMoney(openings.legacyCase(opening.legacyCaseId()).oldRecordedValueLocal(),"-2000");
        receive(key,"10","100",true);assertMoney(issue(key,"6").knownValueLocal(),"60");assertBalance(key,"4","40");
        assertThat(locked(key,()->openings.startEmptyCycle(command)).currentOpening().replayed()).isTrue();
        assertThatThrownBy(()->adjust(key,opening.currentOpening().sourceCostNodeId(),"2000",true)).isInstanceOf(ApiException.class);
        assertBalance(key,"4","40");assertMoney(owned(key,"COGS"),"60");
        assertMoney(jdbc.queryForObject("SELECT (original_balance->>'amount_local')::numeric FROM stock_value_legacy_balance_cases WHERE id=?",BigDecimal.class,opening.legacyCaseId()),"-2000");
        assertThat(openings.legacyCase(opening.legacyCaseId()).state()).isEqualTo(LegacyState.OPEN);
    }

    @Test void unknownEmptyBalanceCanStartNewStockButHistoryNeverBecomesAConfirmedZero(){
        PoolKey key=legacy("0",null);
        EmptyCycleValue opened=locked(key,()->openings.startEmptyCycle(new EmptyCycle(context("INVENTORY_EMPTY_CYCLE"),key,null,"原金额缺失，保留待核对事项")));
        assertThat(openings.legacyCase(opened.legacyCaseId()).oldRecordedValueLocal()).isNull();
        assertThat(openings.legacyCase(opened.legacyCaseId()).state()).isEqualTo(LegacyState.OPEN);
        receive(key,"1","10",true);assertBalance(key,"1","10");
        assertThat(service.pool(key).state()).isEqualTo(State.FINAL);
    }

    @Test void legacyCaseNotesAreAppendOnlyAndNoVoucherIdCanSubstituteForMissingFinanceApproval(){
        PoolKey key=legacy("0","999");EmptyCycleValue opened=locked(key,()->openings.startEmptyCycle(new EmptyCycle(context("INVENTORY_EMPTY_CYCLE"),key,bd("999"),"原残值需独立核对")));
        UUID caseId=opened.legacyCaseId();EventContext context=context("INVENTORY_LEGACY_RECONCILIATION");
        LegacyCaseAction note=tx.execute(status->openings.noteLegacyCase(context,caseId,"已找到原销售流水，尚待独立财务审批"));
        assertThat(tx.execute(status->openings.noteLegacyCase(context,caseId,"已找到原销售流水，尚待独立财务审批")).replayed()).isTrue();
        assertThatThrownBy(()->tx.execute(status->openings.noteLegacyCase(context,caseId,"改写同一条核对记录"))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->tx.execute(status->openings.closeLegacyCase(context("INVENTORY_LEGACY_RECONCILIATION"),caseId,UUID.randomUUID())))
                .isInstanceOf(ApiException.class).hasMessageContaining("审批证据尚未接入");
        assertThatThrownBy(()->replica(key,()->jdbc.update("UPDATE stock_value_legacy_balance_cases SET observed_recorded_value=0 WHERE id=?",caseId))).isInstanceOf(RuntimeException.class);
        assertThatThrownBy(()->replica(key,()->jdbc.update("DELETE FROM stock_value_legacy_balance_case_events WHERE id=?",note.eventId()))).isInstanceOf(RuntimeException.class);
        assertThat(openings.legacyCase(caseId).state()).isEqualTo(LegacyState.OPEN);assertBalance(key,"0","0");
    }

    @Test void caseClosureConsultsCaseSpecificApprovalPortAndOnlyRecordsTheAlreadyApprovedResult(){
        PoolKey key=legacy("0","999");EmptyCycleValue opened=locked(key,()->openings.startEmptyCycle(new EmptyCycle(context("INVENTORY_EMPTY_CYCLE"),key,bd("999"),"旧记录不代表真实损失")));
        UUID caseId=opened.legacyCaseId(),decision=UUID.randomUUID();AtomicInteger consulted=new AtomicInteger();
        // Port contract fixture only: real finance approval/forward GL is a separate, not-yet-delivered work package.
        InventoryLegacyResolutionEvidencePort authority=(requestedCase,requestedDecision)->{
            consulted.incrementAndGet();assertThat(requestedCase).isEqualTo(caseId);assertThat(requestedDecision).isEqualTo(decision);
            return Optional.of(new ApprovedResolution(caseId,decision,1,USER,EMPLOYEE,OffsetDateTime.parse("2026-09-07T00:00:00Z"),
                    ResolutionKind.NO_ADJUSTMENT_REQUIRED,bd("0"),null,"独立审批认定原台账显示差异不需要新增总账调整","a".repeat(64)));
        };
        var withAuthority=new InventoryOpeningService(named,mutex,Optional.of(authority));
        EventContext close=context("INVENTORY_LEGACY_RECONCILIATION");long movements=count("stock_movements");
        LegacyCaseAction result=tx.execute(status->withAuthority.closeLegacyCase(close,caseId,decision));
        assertThat(result.state()).isEqualTo(LegacyState.RESOLVED);
        assertThat(tx.execute(status->withAuthority.closeLegacyCase(close,caseId,decision)).replayed()).isTrue();assertThat(consulted).hasValue(1);
        assertThat(withAuthority.legacyCase(caseId).resolutionDecisionId()).isEqualTo(decision);
        assertMoney(withAuthority.legacyCase(caseId).oldRecordedValueLocal(),"999");assertBalance(key,"0","0");
        assertThat(count("stock_movements")).isEqualTo(movements);
    }

    @Test void approvedOpeningUsesExplicitActualValueEvenWhenOldRecordedAmountIsNull(){
        PoolKey key=legacy("7",null);long before=count("stock_movements");
        OpeningValue opening=opening(key,"7",null,"84",true);
        assertThat(opening.state()).isEqualTo(State.FINAL);assertBalance(key,"7","84");
        assertThat(count("stock_movements")).isEqualTo(before);
        assertThat(jdbc.queryForObject("SELECT observed_recorded_value FROM stock_value_openings WHERE event_id=?",BigDecimal.class,opening.eventId())).isNull();
        assertMoney(issue(key,"7").knownValueLocal(),"84");assertBalance(key,"0","0");
    }

    @Test void openingAndPhysicalIssueCanShareOneTransactionWithoutInventingAnOpeningMovement(){
        PoolKey key=legacy("7","84");long movements=count("stock_movements");
        locked(key,()->{
            openings.open(new Opening(context("INVENTORY_OPENING"),key,bd("7"),bd("84"),bd("70"),true,"依据批准盘点成本开账"));
            EventContext c=context("TEST_SHIPMENT");
            MovementValue issue=service.issue(new Issue(c,UUID.randomUUID(),key,bd("1"),bd("7"),Destination.COGS,c.sourceItemId()));
            physical(issue,c,key,bd("1"),-1);return null;
        });
        assertBalance(key,"6","60");assertMoney(owned(key,"COGS"),"10");
        assertThat(count("stock_movements")).isEqualTo(movements+1);
    }

    @Test void openingRejectsUnprovedFinalCostAndStaleOriginalEvidenceAndNeverReopensAnActivePool(){
        PoolKey key=legacy("7","84");long before=count("stock_value_openings");
        assertThatThrownBy(()->opening(key,"6","84","70",true)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->opening(key,"7","83","70",true)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->opening(key,"7","84",null,true)).isInstanceOf(ApiException.class);
        assertBalance(key,"7","84");assertThat(count("stock_value_openings")).isEqualTo(before);
        Opening command=new Opening(context("INVENTORY_OPENING"),key,bd("7"),bd("84"),bd("70"),true,"经批准的实际期初金额");
        OpeningValue first=locked(key,()->openings.open(command));
        OpeningValue replay=locked(key,()->openings.open(command));
        assertThat(replay.replayed()).isTrue();assertThat(replay.eventId()).isEqualTo(first.eventId());
        assertThatThrownBy(()->locked(key,()->openings.open(new Opening(command.context(),key,bd("7"),bd("84"),bd("71"),true,command.reason()))))
                .isInstanceOf(ApiException.class).hasMessageContaining("幂等键");
        assertThatThrownBy(()->opening(key,"7","70","70",true)).isInstanceOf(ApiException.class).hasMessageContaining("价值基准");
        assertThatThrownBy(()->tx.execute(status->openings.open(command))).isInstanceOf(IllegalStateException.class);
        assertBalance(key,"7","70");
    }

    @Test void replicaModeCannotRewriteOpeningFactsValueRevisionsOrTheManagedPhysicalPair(){
        PoolKey key=legacy("7","84");OpeningValue opening=opening(key,"7","84","70",true);
        assertThatThrownBy(()->replica(key,()->jdbc.update("UPDATE stock_value_openings SET observed_recorded_value=0 WHERE event_id=?",opening.eventId())))
                .isInstanceOf(RuntimeException.class);
        assertThatThrownBy(()->replica(key,()->jdbc.update("UPDATE stock_value_events SET known_value_local=0 WHERE id=?",opening.eventId())))
                .isInstanceOf(RuntimeException.class);
        assertThatThrownBy(()->replica(key,()->jdbc.update("UPDATE stock_value_nodes SET basis_value_local=80,revision=revision+1 WHERE id=?",opening.poolHeadId())))
                .isInstanceOf(RuntimeException.class);
        assertThatThrownBy(()->replica(key,()->jdbc.update("UPDATE stock_balances SET qty=8 WHERE warehouse_id=? AND goods_id=?",key.warehouseId(),key.goodsId())))
                .isInstanceOf(RuntimeException.class);
        assertThatThrownBy(()->replica(key,()->jdbc.update("UPDATE stock_balances SET amount_local=80 WHERE warehouse_id=? AND goods_id=?",key.warehouseId(),key.goodsId())))
                .isInstanceOf(RuntimeException.class);
        assertBalance(key,"7","70");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgname='trg_stock_balance_managed_value' AND tgenabled='A'",Integer.class)).isEqualTo(1);
    }

    @Test void concurrentOpeningHasOneWinnerAndCannotReplaceItsBasis()throws Exception{
        PoolKey key=legacy("7","84");CountDownLatch opened=new CountDownLatch(1),commit=new CountDownLatch(1);AtomicInteger waiter=new AtomicInteger();
        var executor=Executors.newFixedThreadPool(2);
        try{
            Future<?> winner=executor.submit(()->locked(key,()->{
                openings.open(new Opening(context("INVENTORY_OPENING"),key,bd("7"),bd("84"),bd("70"),true,"已核定开账"));
                opened.countDown();await(commit);return null;
            }));
            assertThat(opened.await(10,TimeUnit.SECONDS)).isTrue();
            Future<?> loser=executor.submit(()->lockedWithPid(key,waiter,()->openings.open(new Opening(context("INVENTORY_OPENING"),key,bd("7"),bd("84"),bd("140"),true,"竞争中的另一份金额"))));
            waitForDatabaseLock(waiter);commit.countDown();winner.get(10,TimeUnit.SECONDS);
            assertThatThrownBy(()->loser.get(10,TimeUnit.SECONDS)).hasCauseInstanceOf(ApiException.class);
        }finally{commit.countDown();executor.shutdownNow();}
        assertBalance(key,"7","70");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM stock_value_openings o JOIN stock_value_pools p ON p.id=o.pool_id WHERE p.goods_id=?",Integer.class,key.goodsId())).isEqualTo(1);
    }

    @Test void everyValueWriterRequiresTheActualGoodsColorLockInItsCurrentTransaction(){
        PoolKey key=key();MovementValue source=receive(key,"4","40",true);MovementValue out=issue(key,"1");
        AdjustmentValue change=adjust(key,source.valueNodeId(),"4",true);drain();
        UUID appliedTask=jdbc.queryForObject("SELECT id FROM stock_value_tasks WHERE event_id=? LIMIT 1",UUID.class,change.eventId());
        EventContext context=context("TEST_NO_LOCK");long before=count("stock_value_events");
        List<Runnable> writes=List.of(
                ()->service.receive(new Receive(context,UUID.randomUUID(),key,bd("1"),bd("3"),bd("10"),true)),
                ()->service.issue(new Issue(context,UUID.randomUUID(),key,bd("1"),bd("3"),Destination.COGS,context.sourceItemId())),
                ()->service.returnIssue(new ReturnIssue(context,UUID.randomUUID(),key,bd("1"),bd("3"),out.valueNodeId())),
                ()->service.adjustSource(new SourceAdjustment(context,source.valueNodeId(),bd("1"),true)),
                ()->service.reverseAdjustment(context,change.eventId()),
                ()->service.propagate(appliedTask));
        for(Runnable write:writes)assertThatThrownBy(()->tx.execute(status->{write.run();return null;}))
                .isInstanceOf(IllegalStateException.class).hasMessageContaining("mutex in the current transaction");
        PoolKey other=key();
        assertThatThrownBy(()->locked(other,()->service.issue(new Issue(context,UUID.randomUUID(),key,bd("1"),bd("3"),Destination.COGS,context.sourceItemId()))))
                .isInstanceOf(IllegalStateException.class);
        assertThat(count("stock_value_events")).isEqualTo(before);assertBalance(key,"3","33");
    }

    @Test void requiresNewCannotBorrowOuterMutexAndOuterOwnershipResumesAfterInnerRollback(){
        PoolKey key=key();EventContext context=context("TEST_RECEIPT");
        Receive command=new Receive(context,UUID.randomUUID(),key,bd("2"),bd("0"),bd("20"),true);
        var inner=new TransactionTemplate(Objects.requireNonNull(tx.getTransactionManager()));
        inner.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        locked(key,()->{
            int outerPid=((Number)em.createNativeQuery("SELECT pg_backend_pid()").getSingleResult()).intValue();
            assertThatThrownBy(()->inner.execute(status->{
                int innerPid=((Number)em.createNativeQuery("SELECT pg_backend_pid()").getSingleResult()).intValue();
                assertThat(innerPid).isNotEqualTo(outerPid);
                return service.receive(command);
            })).isInstanceOf(IllegalStateException.class).hasMessageContaining("mutex in the current transaction");
            mutex.requireHeld(new InventoryKey(key.goodsId(),key.colorId()));
            MovementValue value=service.receive(command);physical(value,context,key,bd("2"),1);return value;
        });
        assertBalance(key,"2","20");
        assertThatThrownBy(()->tx.execute(status->service.receive(command))).isInstanceOf(IllegalStateException.class);
    }

    @Test void unpricedReceiptAndLaterActualCostReachBothSoldAndRemainingStock(){
        PoolKey key=key();receive(key,"10","100",true);MovementValue pending=receive(key,"10",null,false);
        MovementValue sold=issue(key,"10");assertMoney(sold.knownValueLocal(),"50");assertThat(sold.state()).isEqualTo(State.PENDING);
        AdjustmentValue adjustment=adjust(key,pending.valueNodeId(),"100",true);
        assertThat(service.pool(key).propagationPending()).isTrue();drain();
        assertBalance(key,"10","100");assertMoney(owned(key,"COGS"),"100");
        assertThat(service.pool(key).state()).isEqualTo(State.FINAL);assertJobClosed(adjustment.eventId());
    }

    @Test void partialOriginalReturnThenResaleCarriesLateCostEntirelyToCogs(){
        PoolKey key=key();receive(key,"10","100",true);MovementValue source=receive(key,"10","100",true);
        MovementValue first=issue(key,"10");MovementValue returned=returned(key,first.valueNodeId(),"2");
        assertMoney(returned.knownValueLocal(),"20");
        adjust(key,source.valueNodeId(),"20",true);drain();
        assertBalance(key,"12","132");assertMoney(owned(key,"COGS"),"88");
        assertMoney(issue(key,"12").knownValueLocal(),"132");
        AdjustmentValue finalFee=adjust(key,source.valueNodeId(),"30",true);drain();
        assertBalance(key,"0","0");assertMoney(owned(key,"COGS"),"250");assertJobClosed(finalFee.eventId());
    }

    @Test void cumulativeOriginalReturnIntervalsDoNotReaverageRoundedRemainders(){
        PoolKey key=key();MovementValue source=receive(key,"3","0.0002",true);MovementValue out=issue(key,"3");
        assertMoney(returned(key,out.valueNodeId(),"1").knownValueLocal(),"0.0001");
        assertMoney(returned(key,out.valueNodeId(),"1").knownValueLocal(),"0.0000");
        assertMoney(returned(key,out.valueNodeId(),"1").knownValueLocal(),"0.0001");
        adjust(key,source.valueNodeId(),"0.0001",true);drain();
        assertBalance(key,"3","0.0003");assertMoney(owned(key,"COGS"),"0");
        assertThatThrownBy(()->returned(key,out.valueNodeId(),"0.0001")).isInstanceOf(ApiException.class);
    }

    @Test void cumulativeTargetsPreserveMicroFeesAndAConfirmedZeroIsNotUnknown(){
        PoolKey key=key();MovementValue source=receive(key,"3","0.0001",true);issue(key,"1");
        adjust(key,source.valueNodeId(),"0.0001",true);drain();
        assertBalance(key,"2","0.0001");assertMoney(owned(key,"COGS"),"0.0001");
        PoolKey free=key();MovementValue zero=receive(free,"2",null,false);assertThat(zero.state()).isEqualTo(State.PENDING);
        adjust(free,zero.valueNodeId(),"0",true);drain();assertBalance(free,"2","0");assertThat(service.pool(free).state()).isEqualTo(State.FINAL);
    }

    @Test void stableSourceAndTransportReplaysNeverDuplicateMoneyOrPhysicalMovement(){
        PoolKey key=key();EventContext context=context("TEST_RECEIPT");UUID candidate=UUID.randomUUID();
        Receive command=new Receive(context,candidate,key,bd("2"),bd("0"),bd("20"),true);
        MovementValue first=locked(key,()->{MovementValue r=service.receive(command);physical(r,context,key,bd("2"),1);return r;});
        long events=count("stock_value_events"),movements=count("stock_movements");
        MovementValue replay=locked(key,()->service.receive(new Receive(context,UUID.randomUUID(),key,bd("2"),bd("2"),bd("20"),true)));
        assertThat(replay.replayed()).isTrue();assertThat(replay.movementId()).isEqualTo(first.movementId());
        EventContext alias=new EventContext(context.sourceEventId(),context.sourceDocType(),context.sourceDocId(),context.sourceItemId(),
                context.sourceVersion(),context.actorUserId(),context.actorEmployeeId(),"different-retry-key",context.occurredAt());
        assertThat(locked(key,()->service.receive(new Receive(alias,UUID.randomUUID(),key,bd("2"),bd("2"),bd("20"),true))).replayed()).isTrue();
        assertThatThrownBy(()->locked(key,()->service.receive(new Receive(context,UUID.randomUUID(),key,bd("3"),bd("2"),bd("20"),true))))
                .isInstanceOf(ApiException.class).hasMessageContaining("幂等键");
        assertThat(count("stock_value_events")).isEqualTo(events);assertThat(count("stock_movements")).isEqualTo(movements);assertBalance(key,"2","20");
    }

    @Test void missingPhysicalWriteOrWrongSellingAmountRollsBackTheWholeValueStep(){
        PoolKey key=key();long events=count("stock_value_events");EventContext context=context("TEST_RECEIPT");
        assertThatThrownBy(()->locked(key,()->service.receive(new Receive(context,UUID.randomUUID(),key,bd("1"),bd("0"),bd("10"),true))))
                .isInstanceOf(RuntimeException.class);
        assertThat(count("stock_value_events")).isEqualTo(events);
        assertThatThrownBy(()->locked(key,()->{
            MovementValue value=service.receive(new Receive(context,UUID.randomUUID(),key,bd("1"),bd("0"),bd("10"),true));
            insertMovement(value.movementId(),context,key,bd("1"),1,null);
            changePhysicalBalance(key,bd("1"),bd("10"));return value;
        })).isInstanceOf(RuntimeException.class);
        assertThat(count("stock_value_events")).isEqualTo(events);
        receive(key,"1","10",true);EventContext out=context("TEST_SHIPMENT");
        assertThatThrownBy(()->locked(key,()->{
            MovementValue value=service.issue(new Issue(out,UUID.randomUUID(),key,bd("1"),bd("1"),Destination.COGS,out.sourceItemId()));
            // Stand-in deliberately attempts the old bug: selling amount=100, cost=10.
            insertMovement(value.movementId(),out,key,bd("1"),-1,bd("100"));
            changePhysicalBalance(key,bd("-1"),bd("-100"));return value;
        })).isInstanceOf(RuntimeException.class);
        assertBalance(key,"1","10");
    }

    @Test void nonemptyLegacyPoolIsUnverifiedAndCannotBecomeActualThroughOrdinaryReceive(){
        PoolKey key=new PoolKey(WAREHOUSE,LEGACY_GOODS,null);
        PoolValue result=service.pool(key);assertThat(result.state()).isEqualTo(State.LEGACY_UNVERIFIED);
        assertThat(result.knownValueLocal()).isNull();
        assertThatThrownBy(()->receive(key,"1","10",true)).isInstanceOf(ApiException.class).hasMessageContaining("历史期初");
        assertBalance(key,"7","84");assertThat(result.headNodeId()).isNull();
    }

    @Test void transferToAnotherWarehouseUsesOriginalValueAndTracksLateCosts(){
        PoolKey source=key();PoolKey target=new PoolKey(WAREHOUSE_2,source.goodsId(),null);
        MovementValue cost=receive(source,"4","100",true);
        EventContext c=context("TEST_TRANSFER_OUT");
        MovementValue out=locked(source,()->{MovementValue r=service.issue(new Issue(c,UUID.randomUUID(),source,bd("4"),qty(source),Destination.IN_TRANSIT,c.sourceItemId()));physical(r,c,source,bd("4"),-1);return r;});
        returned(target,out.valueNodeId(),"4");issue(target,"3");adjust(source,cost.valueNodeId(),"20",true);drain();
        assertBalance(source,"0","0");assertBalance(target,"1","30");assertMoney(owned(target,"COGS"),"90");
        assertMoney(owned(source,"IN_TRANSIT"),"0");
    }

    @Test void warehouseAndColorPoolsAreIndependentlyValued(){
        PoolKey plain=key();UUID color=UUID.randomUUID();jdbc.update("INSERT INTO colors VALUES (?)",color);
        PoolKey colored=new PoolKey(WAREHOUSE,plain.goodsId(),color);
        PoolKey otherWarehouse=new PoolKey(WAREHOUSE_2,plain.goodsId(),null);
        receive(plain,"10","100",true);receive(colored,"10","500",true);receive(otherWarehouse,"10","200",true);
        assertMoney(issue(plain,"5").knownValueLocal(),"50");
        assertMoney(issue(colored,"5").knownValueLocal(),"250");
        assertMoney(issue(otherWarehouse,"5").knownValueLocal(),"100");
        assertBalance(plain,"5","50");assertBalance(colored,"5","250");assertBalance(otherWarehouse,"5","100");
    }

    @Test void projectionTamperingCannotRepriceAHeadOrRepointItToAnotherPool(){
        PoolKey a=key(),b=key();receive(a,"2","20",true);receive(b,"2","20",true);
        PoolValue pa=service.pool(a),pb=service.pool(b);
        assertThatThrownBy(()->locked(a,()->jdbc.update("UPDATE stock_value_nodes SET basis_value_local=30,revision=revision+1 WHERE id=?",pa.headNodeId())))
                .isInstanceOf(RuntimeException.class);
        assertThatThrownBy(()->locked(a,()->jdbc.update("UPDATE stock_value_pools SET head_node_id=? WHERE id=?",pb.headNodeId(),pa.poolId())))
                .isInstanceOf(RuntimeException.class);
        assertThatThrownBy(()->locked(a,()->jdbc.update("UPDATE stock_value_nodes SET active=false WHERE id=?",pa.headNodeId())))
                .isInstanceOf(RuntimeException.class);
        assertThatThrownBy(()->locked(a,()->jdbc.update("UPDATE stock_value_pools SET head_node_id=NULL WHERE id=?",pa.poolId())))
                .isInstanceOf(RuntimeException.class);
        assertThatThrownBy(()->locked(a,()->jdbc.update("DELETE FROM stock_balances WHERE warehouse_id=? AND goods_id=?",a.warehouseId(),a.goodsId())))
                .isInstanceOf(RuntimeException.class);
        assertThatThrownBy(()->locked(a,()->jdbc.update("UPDATE stock_balances SET warehouse_id=? WHERE warehouse_id=? AND goods_id=?",WAREHOUSE_2,a.warehouseId(),a.goodsId())))
                .isInstanceOf(RuntimeException.class);
        assertBalance(a,"2","20");assertThat(service.pool(a).headNodeId()).isEqualTo(pa.headNodeId());
    }

    @Test void tasksAreIdempotentCanRejectOutOfOrderAndResumeAfterRollback(){
        PoolKey key=key();MovementValue source=receive(key,"10","100",true);issue(key,"4");
        AdjustmentValue first=adjust(key,source.valueNodeId(),"10",true);AdjustmentValue second=adjust(key,source.valueNodeId(),"20",true);
        List<PropagationWork> ready=service.pendingWork(100).stream().filter(w->w.lockKey().goodsId().equals(key.goodsId())).toList();
        PropagationWork a=ready.stream().filter(w->w.rootEventId().equals(first.eventId())).findFirst().orElseThrow();
        PropagationWork b=ready.stream().filter(w->w.rootEventId().equals(second.eventId())).findFirst().orElseThrow();
        assertThat(locked(key,()->service.propagate(b.taskId())).waitingForPriorRevision()).isTrue();
        BigDecimal before=value(key);
        assertThatThrownBy(()->locked(key,()->{service.propagate(a.taskId());throw new IllegalStateException("simulate worker failure before commit");}))
                .isInstanceOf(IllegalStateException.class);
        assertMoney(value(key),before.toPlainString());
        assertThat(locked(key,()->service.propagate(a.taskId())).applied()).isTrue();
        assertThat(locked(key,()->service.propagate(a.taskId())).replayed()).isTrue();
        drain();assertBalance(key,"6","78");assertMoney(owned(key,"COGS"),"52");assertJobClosed(first.eventId());assertJobClosed(second.eventId());
    }

    @Test void adjustmentReversalIsAppendOnlyAndStrictLifo(){
        PoolKey key=key();MovementValue source=receive(key,"10","100",true);issue(key,"5");
        AdjustmentValue first=adjust(key,source.valueNodeId(),"20",true);drain();
        AdjustmentValue second=adjust(key,source.valueNodeId(),"10",true);drain();
        assertThatThrownBy(()->locked(key,()->service.reverseAdjustment(context("TEST_COST_REVERSE"),first.eventId())))
                .isInstanceOf(ApiException.class).hasMessageContaining("后进先出");
        locked(key,()->service.reverseAdjustment(context("TEST_COST_REVERSE"),second.eventId()));drain();
        locked(key,()->service.reverseAdjustment(context("TEST_COST_REVERSE"),first.eventId()));drain();
        assertBalance(key,"5","50");assertMoney(owned(key,"COGS"),"50");
        assertThatThrownBy(()->jdbc.update("UPDATE stock_value_events SET source_version=99 WHERE id=?",first.eventId())).isInstanceOf(RuntimeException.class);
        assertThatThrownBy(()->jdbc.update("DELETE FROM stock_value_postings WHERE event_id=?",first.eventId())).isInstanceOf(RuntimeException.class);
    }

    @Test void issueEdgeCreatedBeforeAdjustmentIncludesTheLaterRevisionExactlyOnce() throws Exception {
        PoolKey key=key();MovementValue source=receive(key,"10","100",true);
        CountDownLatch edgeMade=new CountDownLatch(1),commitIssue=new CountDownLatch(1);
        AtomicInteger waiter=new AtomicInteger();
        var executor=Executors.newFixedThreadPool(2);
        try{
            Future<MovementValue> sale=executor.submit(()->locked(key,()->{
                EventContext c=context("TEST_SHIPMENT");MovementValue r=service.issue(new Issue(c,UUID.randomUUID(),key,bd("5"),qty(key),Destination.COGS,c.sourceItemId()));
                physical(r,c,key,bd("5"),-1);edgeMade.countDown();await(commitIssue);return r;
            }));
            assertThat(edgeMade.await(10,TimeUnit.SECONDS)).isTrue();
            Future<AdjustmentValue> adjustment=executor.submit(()->lockedWithPid(key,waiter,
                    ()->service.adjustSource(new SourceAdjustment(context("TEST_COST"),source.valueNodeId(),bd("100"),true))));
            waitForDatabaseLock(waiter);assertThat(adjustment.isDone()).isFalse();
            commitIssue.countDown();assertMoney(sale.get(10,TimeUnit.SECONDS).knownValueLocal(),"50");adjustment.get(10,TimeUnit.SECONDS);
        }finally{commitIssue.countDown();executor.shutdownNow();}
        drain();assertBalance(key,"5","100");assertMoney(owned(key,"COGS"),"100");
    }

    @Test void appliedAdjustmentBeforeNewEdgeIsIncludedInBaselineAndNeverReplayedIntoIt() throws Exception {
        PoolKey key=key();MovementValue source=receive(key,"10","100",true);adjust(key,source.valueNodeId(),"100",true);
        PropagationWork work=service.pendingWork(100).stream().filter(w->w.lockKey().goodsId().equals(key.goodsId())).findFirst().orElseThrow();
        CountDownLatch updated=new CountDownLatch(1),commitAdjustment=new CountDownLatch(1);
        AtomicInteger waiter=new AtomicInteger();
        var executor=Executors.newFixedThreadPool(2);
        try{
            Future<?> apply=executor.submit(()->locked(key,()->{service.propagate(work.taskId());updated.countDown();await(commitAdjustment);return null;}));
            assertThat(updated.await(10,TimeUnit.SECONDS)).isTrue();
            Future<MovementValue> sale=executor.submit(()->lockedWithPid(key,waiter,()->{
                EventContext c=context("TEST_SHIPMENT");MovementValue r=service.issue(new Issue(c,UUID.randomUUID(),key,bd("5"),qty(key),Destination.COGS,c.sourceItemId()));
                physical(r,c,key,bd("5"),-1);return r;
            }));
            waitForDatabaseLock(waiter);assertThat(sale.isDone()).isFalse();
            commitAdjustment.countDown();apply.get(10,TimeUnit.SECONDS);assertMoney(sale.get(10,TimeUnit.SECONDS).knownValueLocal(),"100");
        }finally{commitAdjustment.countDown();executor.shutdownNow();}
        assertThat(locked(key,()->service.propagate(work.taskId())).replayed()).isTrue();drain();
        assertBalance(key,"5","100");assertMoney(owned(key,"COGS"),"100");
    }

    @Test void ordinaryStatementCountDoesNotGrowWithPoolHistory(){
        PoolKey shortHistory=key();receive(shortHistory,"300","3000",true);named.calls.set(0);issue(shortHistory,"1");int small=named.calls.get();
        PoolKey longHistory=key();receive(longHistory,"300","3000",true);
        for(int i=0;i<120;i++)issue(longHistory,"1");
        named.calls.set(0);issue(longHistory,"1");int large=named.calls.get();
        assertThat(large).isEqualTo(small);assertThat(large).isLessThan(30);
        assertThat(service.pendingWork(10000)).hasSizeLessThanOrEqualTo(100);
    }

    private static PoolKey key(){UUID goods=UUID.randomUUID();jdbc.update("INSERT INTO goods VALUES (?)",goods);return new PoolKey(WAREHOUSE,goods,null);}
    private static PoolKey legacy(String qty,String oldValue){PoolKey key=key();jdbc.update("INSERT INTO stock_balances(warehouse_id,goods_id,qty,amount_local) VALUES (?,?,?,?)",key.warehouseId(),key.goodsId(),bd(qty),oldValue==null?null:bd(oldValue));return key;}
    private static OpeningValue opening(PoolKey key,String qty,String oldValue,String actualValue,boolean finalValue){return locked(key,()->openings.open(new Opening(context("INVENTORY_OPENING"),key,bd(qty),oldValue==null?null:bd(oldValue),actualValue==null?null:bd(actualValue),finalValue,"独立期初核对依据；原旧值保留供历史对账")));}
    private static <T>T replica(PoolKey key,Supplier<T> action){return locked(key,()->{jdbc.execute("SET LOCAL session_replication_role='replica'");return action.get();});}
    private static EventContext context(String type){UUID source=UUID.randomUUID();return new EventContext(source,type,UUID.randomUUID(),UUID.randomUUID(),1,USER,EMPLOYEE,
            source.toString(),OffsetDateTime.parse("2026-09-07T00:00:00Z"));}
    private static <T>T locked(PoolKey key,Supplier<T> action){return tx.execute(status->{mutex.lock(new InventoryKey(key.goodsId(),key.colorId()));return action.get();});}
    private static <T>T lockedWithPid(PoolKey key,AtomicInteger pid,Supplier<T> action){return tx.execute(status->{
        pid.set(((Number)em.createNativeQuery("SELECT pg_backend_pid()").getSingleResult()).intValue());
        mutex.lock(new InventoryKey(key.goodsId(),key.colorId()));return action.get();
    });}
    private static void waitForDatabaseLock(AtomicInteger pid)throws Exception{
        long deadline=System.nanoTime()+Duration.ofSeconds(10).toNanos();
        while(System.nanoTime()<deadline){
            if(pid.get()>0&&Boolean.TRUE.equals(jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE pid=? AND wait_event_type='Lock')",Boolean.class,pid.get())))return;
            Thread.sleep(20);
        }
        fail("The competing transaction did not reach a real PostgreSQL lock wait");
    }
    private static MovementValue receive(PoolKey key,String qty,String amount,boolean finalValue){
        return locked(key,()->{EventContext c=context("TEST_RECEIPT");BigDecimal q=bd(qty);
            MovementValue r=service.receive(new Receive(c,UUID.randomUUID(),key,q,qty(key),amount==null?null:bd(amount),finalValue));physical(r,c,key,q,1);return r;});
    }
    private static MovementValue issue(PoolKey key,String qty){return locked(key,()->{EventContext c=context("TEST_SHIPMENT");BigDecimal q=bd(qty);
        MovementValue r=service.issue(new Issue(c,UUID.randomUUID(),key,q,qty(key),Destination.COGS,c.sourceItemId()));physical(r,c,key,q,-1);return r;});}
    private static MovementValue returned(PoolKey key,UUID original,String qty){return locked(key,()->{EventContext c=context("TEST_RETURN");BigDecimal q=bd(qty);
        MovementValue r=service.returnIssue(new ReturnIssue(c,UUID.randomUUID(),key,q,qty(key),original));physical(r,c,key,q,1);return r;});}
    private static AdjustmentValue adjust(PoolKey key,UUID source,String amount,boolean finalValue){return locked(key,()->service.adjustSource(new SourceAdjustment(context("TEST_COST"),source,bd(amount),finalValue)));}
    private static void physical(MovementValue r,EventContext c,PoolKey key,BigDecimal qty,int direction){
        if(r.replayed())return;insertMovement(r.movementId(),c,key,qty,direction,r.knownValueLocal());
        changePhysicalBalance(key,qty.multiply(BigDecimal.valueOf(direction)),r.knownValueLocal().multiply(BigDecimal.valueOf(direction)));
    }
    private static void insertMovement(UUID id,EventContext c,PoolKey k,BigDecimal qty,int direction,BigDecimal value){
        jdbc.update("""
                INSERT INTO stock_movements(id,transaction_date,movement_type,source_doc_type,source_doc_id,source_item_id,
                    goods_id,color_id,warehouse_id,direction,qty,unit_rate,amount_local) VALUES (?,?,1,?,?,?,?,?,?,?, ?,1,?)
                """,id,c.occurredAt(),c.sourceDocType(),c.sourceDocId(),c.sourceItemId(),k.goodsId(),k.colorId(),k.warehouseId(),direction,qty,value);
    }
    private static void changePhysicalBalance(PoolKey k,BigDecimal qty,BigDecimal value){
        jdbc.update("""
                INSERT INTO stock_balances(warehouse_id,goods_id,color_id,qty,amount_local) VALUES (?,?,?,?,?)
                ON CONFLICT(warehouse_id,goods_id,color_id) DO UPDATE SET qty=stock_balances.qty+excluded.qty,
                    amount_local=stock_balances.amount_local+excluded.amount_local
                """,k.warehouseId(),k.goodsId(),k.colorId(),qty,value);
    }
    private static BigDecimal qty(PoolKey k){List<BigDecimal> rows=jdbc.query("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NOT DISTINCT FROM ?",(r,i)->r.getBigDecimal(1),k.warehouseId(),k.goodsId(),k.colorId());return rows.isEmpty()?bd("0"):rows.getFirst();}
    private static BigDecimal value(PoolKey k){return jdbc.queryForObject("SELECT amount_local FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NOT DISTINCT FROM ?",BigDecimal.class,k.warehouseId(),k.goodsId(),k.colorId());}
    private static BigDecimal owned(PoolKey k,String owner){return jdbc.queryForObject("SELECT coalesce(sum(n.owned_value_local),0) FROM stock_value_nodes n JOIN stock_value_pools p ON p.id=n.pool_id WHERE p.goods_id=? AND p.color_id IS NOT DISTINCT FROM ? AND n.owner_kind=? AND n.active",BigDecimal.class,k.goodsId(),k.colorId(),owner);}
    private static void assertBalance(PoolKey k,String qty,String value){assertMoney(qty(k),qty);assertMoney(value(k),value);}
    private static BigDecimal bd(String value){return new BigDecimal(value).setScale(4);}
    private static void assertMoney(BigDecimal value,String expected){assertThat(value).isEqualByComparingTo(expected);}
    private static long count(String table){return jdbc.queryForObject("SELECT count(*) FROM "+table,Long.class);}
    private static void assertJobClosed(UUID event){assertThat(jdbc.queryForObject("SELECT status FROM stock_value_jobs WHERE event_id=?",String.class,event)).isEqualTo("APPLIED");assertMoney(jdbc.queryForObject("SELECT clearing_remaining_local FROM stock_value_jobs WHERE event_id=?",BigDecimal.class,event),"0");}
    private static void drain(){for(int round=0;round<1000;round++){List<PropagationWork> work=service.pendingWork(100);if(work.isEmpty())return;boolean progress=false;for(PropagationWork item:work)progress|=locked(item.lockKey(),()->service.propagate(item.taskId())).applied();if(!progress)fail("Propagation made no progress");}fail("Propagation did not finish within bounded test rounds");}
    private static void await(CountDownLatch latch){try{if(!latch.await(15,TimeUnit.SECONDS))throw new IllegalStateException("barrier timed out");}catch(InterruptedException e){Thread.currentThread().interrupt();throw new IllegalStateException(e);}}

    private static class CountingJdbc extends NamedParameterJdbcTemplate {
        final AtomicInteger calls=new AtomicInteger();
        CountingJdbc(javax.sql.DataSource source){super(source);}
        @Override public int update(String sql,Map<String,?> params){calls.incrementAndGet();return super.update(sql,params);}
        @Override public <T>List<T> query(String sql,Map<String,?> params,RowMapper<T> mapper){calls.incrementAndGet();return super.query(sql,params,mapper);}
        @Override public List<Map<String,Object>> queryForList(String sql,Map<String,?> params){calls.incrementAndGet();return super.queryForList(sql,params);}
        @Override public <T>T queryForObject(String sql,Map<String,?> params,Class<T> type){calls.incrementAndGet();return super.queryForObject(sql,params,type);}
    }
}
