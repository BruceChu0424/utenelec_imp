package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryCostSourceEvidencePort;
import com.uten.imp.application.port.InventoryCostSourceEvidencePort.Evidence;
import com.uten.imp.application.port.InventoryPositionPort.*;
import com.uten.imp.application.port.InventoryValuationPort.*;
import com.uten.imp.application.port.InventoryProductionCostPort;
import com.uten.imp.application.port.InventoryProcurementValuePort.FailureReference;
import com.uten.imp.application.port.InventoryValueAuthorityPort.ValueReference;
import com.uten.imp.application.port.ProcurementReceiptConsiderationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.OffsetDateTime;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Supplier;
import static org.assertj.core.api.Assertions.*;

/** Exact value-engine contract tests. Approval evidence and physical writes are explicit test adapters. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class InventoryPositionPostgresTest {
    private static final PostgreSQLContainer<?> DB=new PostgreSQLContainer<>("postgres:16-alpine");
    private static final UUID USER=UUID.randomUUID(),EMPLOYEE=UUID.randomUUID(),WAREHOUSE=UUID.randomUUID();
    private static JdbcTemplate db;
    private static EntityManagerFactory emf;
    private static EntityManager em;
    private static TransactionTemplate tx;
    private static InventoryMutationLock mutex;
    private static InventoryValuationService values;
    private static InventoryPositionService positions;
    private static InventoryProductionCostService productionCosts;
    private static InventoryValueAuthorityService authorityValues;
    private static final Map<UUID,Evidence> proofs=new ConcurrentHashMap<>();

    @BeforeAll static void start() throws Exception {
        DB.start();var ds=new DriverManagerDataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword());db=new JdbcTemplate(ds);
        for(String table:List.of("users","employees","warehouses","goods","colors"))db.execute("CREATE TABLE "+table+"(id uuid PRIMARY KEY)");
        db.update("INSERT INTO users VALUES (?)",USER);db.update("INSERT INTO employees VALUES (?)",EMPLOYEE);db.update("INSERT INTO warehouses VALUES (?)",WAREHOUSE);
        db.execute("""
                CREATE TABLE stock_balances(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),warehouse_id uuid NOT NULL,
                    goods_id uuid NOT NULL,color_id uuid,qty numeric(18,4) NOT NULL,amount_local numeric(18,4),
                    UNIQUE NULLS NOT DISTINCT(warehouse_id,goods_id,color_id));
                CREATE TABLE stock_movements(id uuid PRIMARY KEY,transaction_date timestamptz,movement_type smallint,
                    source_doc_type text NOT NULL,source_doc_id uuid,source_item_id uuid,goods_id uuid NOT NULL,
                    color_id uuid,warehouse_id uuid NOT NULL,direction smallint NOT NULL,qty numeric(18,4) NOT NULL,
                    unit_id uuid,unit_rate numeric(18,6),amount_local numeric(18,4));
                CREATE FUNCTION business_data_reset() RETURNS TABLE(table_name text,policy text) LANGUAGE sql
                    AS $$ VALUES ('stock_value_postings', 'CLEAR') $$;
                """);
        for(String migration:List.of("V500__inventory_value_core.sql","V506__inventory_value_openings_and_legacy_cases.sql"))
            try(var in=InventoryPositionPostgresTest.class.getResourceAsStream("/db/migration/"+migration)){
                db.execute(new String(Objects.requireNonNull(in).readAllBytes(),StandardCharsets.UTF_8));}
        // Candidate remains outside Flyway's formal directory until this package passes.
        db.execute(Files.readString(Path.of("../.codex-tmp/valuation-positions/V517__inventory_value_custody_positions.sql")));
        // This fixture exercises the value core. FullChainEndToEndTest applies the complete V524,
        // including its actual production completion authorization and business event checks.
        String consumptionReturns=Files.readString(Path.of("../.codex-tmp/valuation-positions/V524__inventory_consumption_returns.sql"));
        db.execute(consumptionReturns.substring(0,consumptionReturns.indexOf("-- Correcting an explicit material settlement")));
        var factory=new LocalContainerEntityManagerFactoryBean();factory.setDataSource(ds);factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setPackagesToScan("com.uten.imp.features.common.taskclaim");var props=new Properties();props.setProperty("hibernate.hbm2ddl.auto","none");
        factory.setJpaProperties(props);factory.afterPropertiesSet();emf=factory.getObject();em=SharedEntityManagerCreator.createSharedEntityManager(emf);
        tx=new TransactionTemplate(new JpaTransactionManager(emf));mutex=new InventoryMutationLock(em);var named=new NamedParameterJdbcTemplate(ds);
        values=new InventoryValuationService(named,mutex);
        positions=new InventoryPositionService(named,mutex,Optional.of((id,version)->Optional.ofNullable(proofs.get(id)).filter(p->p.version()==version)));
        productionCosts=new InventoryProductionCostService(named,mutex,values);
        authorityValues=new InventoryValueAuthorityService(named);
    }
    @AfterAll static void stop(){if(emf!=null)emf.close();DB.stop();}

    @Test void multiPartSingleMovementKeepsExactInputsAndLaterCostsReachSoldAndWarehouseParts(){
        PoolKey k=key();PositionValue first=acquire(k,"10","100","0",true,List.of());
        PositionValue second=acquire(k,"10","200","0",true,List.of());
        PositionValue good1=move(k,first.positionRootId(),"10",Owner.QUALITY_PASSED);
        PositionValue good2=move(k,second.positionRootId(),"10",Owner.QUALITY_PASSED);
        MovementValue stock=store(k,List.of(slice(good1.positionRootId(),"10"),slice(good2.positionRootId(),"10")));
        money(stock.knownValueLocal(),"300");assertThat(db.queryForObject("SELECT count(*) FROM stock_value_position_transfers WHERE event_id=?",Integer.class,stock.eventId())).isEqualTo(2);
        issue(k,"15");adjust(k,first.fundingSourceNodeId(),"100");drain();
        balance(k,"5","100");money(owned(k,"COGS"),"300");money(owned(k,"QUALITY_PENDING"),"0");money(owned(k,"QUALITY_PASSED"),"0");
        assertThat(db.queryForObject("SELECT count(*) FROM stock_movements WHERE id=?",Integer.class,stock.movementId())).isEqualTo(1);
    }

    @Test void zeroChargeReplacementCarriesOriginalFailedValueWithoutAddingASecondSource(){
        PoolKey k=key();PositionValue original=acquire(k,"20","1000","0",true,List.of());
        PositionValue good=move(k,original.positionRootId(),"12",Owner.QUALITY_PASSED);store(k,List.of(slice(good.positionRootId(),"12")));
        PositionValue failed=move(k,original.positionRootId(),"8",Owner.REJECTED_HOLD);
        PositionValue atSupplier=move(k,failed.positionRootId(),"8",Owner.SUPPLIER_CUSTODY);
        PositionValue replacement=acquire(k,"8","0","8",true,List.of(slice(atSupplier.positionRootId(),"8")));
        money(replacement.knownValueLocal(),"400");
        PositionValue passed=move(k,replacement.positionRootId(),"8",Owner.QUALITY_PASSED);store(k,List.of(slice(passed.positionRootId(),"8")));
        balance(k,"20","1000");money(sum("SELECT coalesce(sum(a.initial_known_value),0) FROM stock_value_acquisition_sources a JOIN stock_value_nodes n ON n.id=a.source_node_id JOIN stock_value_pools p ON p.id=n.pool_id WHERE p.goods_id=?",k.goodsId()),"1000");
        adjust(k,original.fundingSourceNodeId(),"100");drain();balance(k,"20","1100");money(owned(k,"SUPPLIER_CUSTODY"),"0");
    }

    @Test void salesReturnMovesOriginalCogsThroughInspectionToGoodAndLossThenLateCostFollowsBoth(){
        PoolKey k=key();PositionValue acquired=acquire(k,"10","100","0",true,List.of());
        PositionValue good=move(k,acquired.positionRootId(),"10",Owner.QUALITY_PASSED);store(k,List.of(slice(good.positionRootId(),"10")));
        MovementValue sale=issue(k,"10");PositionValue returned=move(k,sale.valueNodeId(),"4",Owner.RETURN_INSPECTION);
        balance(k,"0","0");money(owned(k,"COGS"),"60");money(owned(k,"RETURN_INSPECTION"),"40");
        PositionValue back=move(k,returned.positionRootId(),"3",Owner.QUALITY_PASSED);
        move(k,returned.positionRootId(),"1",Owner.LOSS);store(k,List.of(slice(back.positionRootId(),"3")));issue(k,"3");
        adjust(k,acquired.fundingSourceNodeId(),"100");drain();balance(k,"0","0");money(owned(k,"COGS"),"180");money(owned(k,"LOSS"),"20");
        money(owned(k,"RETURN_INSPECTION"),"0");
    }

    @Test void cumulativeTinyValueSplitsKeepTheOriginalBasisRatherThanReaveragingRemainders(){
        PoolKey k=key();PositionValue p=acquire(k,"3","0.0002","0",true,List.of());
        PositionValue a=move(k,p.positionRootId(),"1",Owner.QUALITY_PASSED);
        PositionValue b=move(k,p.positionRootId(),"1",Owner.REJECTED_HOLD);
        PositionValue c=move(k,p.positionRootId(),"1",Owner.QUALITY_PASSED);
        money(a.knownValueLocal(),"0.0001");money(b.knownValueLocal(),"0");money(c.knownValueLocal(),"0.0001");
        store(k,List.of(slice(a.positionRootId(),"1"),slice(c.positionRootId(),"1")));balance(k,"2","0.0002");
        money(positions.position(p.positionRootId()).remainingQtyBase(),"0");
    }

    @Test void unknownAcquisitionRemainsPendingAndUnqualifiedOrWrongSourceCannotEnterWarehouse(){
        PoolKey k=key();PositionValue p=acquire(k,"10",null,"0",false,List.of());
        assertThat(p.state()).isEqualTo(State.PENDING);
        assertThatThrownBy(()->store(k,List.of(slice(p.positionRootId(),"2")))).isInstanceOf(ApiException.class).hasMessageContaining("业务处置");
        assertThatThrownBy(()->acquire(k,"10","0","8",true,List.of(slice(p.positionRootId(),"7"))))
                .isInstanceOf(ApiException.class).hasMessageContaining("承接数量");
        PositionValue good=move(k,p.positionRootId(),"10",Owner.QUALITY_PASSED);store(k,List.of(slice(good.positionRootId(),"10")));
        assertThat(values.pool(k).state()).isEqualTo(State.PENDING);
        adjust(k,p.fundingSourceNodeId(),"100");drain();balance(k,"10","100");assertThat(values.pool(k).state()).isEqualTo(State.FINAL);
    }

    @Test void replayUsesCanonicalMovementAndRejectsAlteredBodyAndReplicaFactTampering(){
        PoolKey k=key();PositionValue p=acquire(k,"5","50","0",true,List.of());
        EventContext c=context();Move command=new Move(c,k,Owner.QUALITY_PASSED,UUID.randomUUID(),List.of(slice(p.positionRootId(),"5")));
        PositionValue good=locked(k,()->positions.move(command));assertThat(locked(k,()->positions.move(command)).replayed()).isTrue();
        assertThatThrownBy(()->locked(k,()->positions.move(new Move(c,k,Owner.LOSS,command.ownerId(),command.sources())))).isInstanceOf(ApiException.class);
        EventContext stockContext=context();Store store=new Store(stockContext,UUID.randomUUID(),k,bd("0"),List.of(slice(good.positionRootId(),"5")));
        MovementValue first=locked(k,()->{MovementValue r=positions.store(store);physical(r,stockContext,k,bd("5"),1);return r;});
        MovementValue replay=locked(k,()->positions.store(new Store(stockContext,UUID.randomUUID(),k,bd("99"),store.sources())));
        assertThat(replay.replayed()).isTrue();assertThat(replay.movementId()).isEqualTo(first.movementId());balance(k,"5","50");
        assertThatThrownBy(()->locked(k,()->{db.execute("SET LOCAL session_replication_role='replica'");
            db.update("UPDATE stock_value_position_transfers SET qty_base=1 WHERE event_id=?",first.eventId());return null;})).isInstanceOf(RuntimeException.class);
        assertThatThrownBy(()->locked(k,()->{db.execute("SET LOCAL session_replication_role='replica'");
            db.update("UPDATE stock_value_acquisition_sources SET initial_known_value=0 WHERE source_node_id=?",p.fundingSourceNodeId());return null;})).isInstanceOf(RuntimeException.class);
    }

    @Test void twoConnectionsCannotBothSpendTheSamePositionAndDirectUnlockedCallsFail() throws Exception {
        PoolKey k=key();PositionValue p=acquire(k,"5","50","0",true,List.of());
        Move a=new Move(context(),k,Owner.QUALITY_PASSED,UUID.randomUUID(),List.of(slice(p.positionRootId(),"4")));
        Move b=new Move(context(),k,Owner.REJECTED_HOLD,UUID.randomUUID(),List.of(slice(p.positionRootId(),"4")));
        assertThatThrownBy(()->tx.execute(s->positions.move(a))).isInstanceOf(IllegalStateException.class).hasMessageContaining("mutex");
        CountDownLatch firstHeld=new CountDownLatch(1),commit=new CountDownLatch(1);AtomicInteger pid=new AtomicInteger();var threads=Executors.newFixedThreadPool(2);
        try{
            Future<PositionValue> first=threads.submit(()->locked(k,()->{PositionValue r=positions.move(a);firstHeld.countDown();await(commit);return r;}));
            assertThat(firstHeld.await(10,TimeUnit.SECONDS)).isTrue();
            Future<PositionValue> second=threads.submit(()->tx.execute(s->{pid.set(((Number)em.createNativeQuery("SELECT pg_backend_pid()").getSingleResult()).intValue());
                mutex.lock(new InventoryKey(k.goodsId(),k.colorId()));return positions.move(b);}));
            long deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(10);boolean waited=false;
            while(System.nanoTime()<deadline){if(pid.get()>0&&Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE pid=? AND wait_event_type='Lock')",Boolean.class,pid.get()))){waited=true;break;}Thread.sleep(20);}
            assertThat(waited).isTrue();commit.countDown();first.get(10,TimeUnit.SECONDS);
            assertThatThrownBy(()->second.get(10,TimeUnit.SECONDS)).isInstanceOf(ExecutionException.class).hasCauseInstanceOf(ApiException.class);
        }finally{commit.countDown();threads.shutdownNow();}
        money(positions.position(p.positionRootId()).remainingQtyBase(),"1");money(owned(k,"QUALITY_PASSED"),"40");money(owned(k,"QUALITY_PENDING"),"10");
    }

    @Test void productionSixHundredAllocatesFiveOfTwentyThenNewTargetAndLateCostFollowActualSales(){
        Production p=production();productionRevision(p,0,"20",true);drainProduction();
        balance(p.product(),"5","150");costPosition(p,"600","150","450","0","0");
        productionRevision(p,1,"10",false);drainProduction();
        balance(p.product(),"5","300");costPosition(p,"600","300","300","0","0");
        issue(p.product(),"3");balance(p.product(),"2","120");money(owned(p.product(),"COGS"),"180");
        adjust(p.b(),p.bSource(),"100");drain();
        costPosition(p,"700","300","400","0","0");
        assertThat(productionCosts.pendingRecalculations(100)).extracting(InventoryProductionCostPort.Recalculation::executionSegmentId).contains(p.segment());
        lockedAll(List.of(p.product()),()->productionCosts.recalculate(context(),p.segment(),2));drainProduction();
        balance(p.product(),"2","140");money(owned(p.product(),"COGS"),"210");costPosition(p,"700","350","350","0","0");
    }

    @Test void negativeLateCostHasAnExplicitSignedPendingDifferenceAndRetryDoesNotDoubleRedistribute(){
        Production p=production();productionRevision(p,0,"5",true);drainProduction();
        balance(p.product(),"5","600");costPosition(p,"600","600","0","0","0");
        adjust(p.b(),p.bSource(),"-200");drain();
        // Breakpoint: upstream job is complete; no production redistribution ran.
        balance(p.product(),"5","600");costPosition(p,"400","600","0","-200","0");
        assertThat(productionCosts.position(p.segment()).pending()).isTrue();
        money(positions.position(p.bInput()).knownValueLocal(),"0");money(positions.position(p.bInput()).pendingReallocationLocal(),"-200");
        lockedAll(List.of(p.product()),()->productionCosts.recalculate(context(),p.segment(),1));
        InventoryProductionCostPort.Work work=productionCosts.pendingWork(100).stream().filter(w->w.executionSegmentId().equals(p.segment())).findFirst().orElseThrow();
        assertThatThrownBy(()->lockedAll(List.of(work.inputPool(),work.outputPool()),()->{productionCosts.apply(work.taskId());throw new IllegalStateException("caller rolls back");}))
                .isInstanceOf(IllegalStateException.class).hasMessageContaining("rolls back");
        costPosition(p,"400","600","0","-200","0");
        lockedAll(List.of(work.inputPool(),work.outputPool()),()->productionCosts.apply(work.taskId()));
        assertThat(lockedAll(List.of(work.inputPool(),work.outputPool()),()->productionCosts.apply(work.taskId())).replayed()).isTrue();
        drainProduction();balance(p.product(),"5","400");costPosition(p,"400","400","0","0","0");
        assertThatThrownBy(()->adjust(p.b(),p.bSource(),"-201")).isInstanceOf(ApiException.class);
    }

    @Test void zeroTargetReleasesAssignmentsToUnclassifiedCostWithoutSendingItToTheNextStockCycle(){
        Production p=production();productionRevision(p,0,"20",true);drainProduction();
        productionRevision(p,1,"0",false);drainProduction();balance(p.product(),"5","0");
        costPosition(p,"600","0","0","0","600");
        assertThat(productionCosts.position(p.segment()).state()).isEqualTo(InventoryProductionCostPort.CostState.PENDING_CLASSIFICATION);
        locked(p.product(),()->{EventContext c=context();MovementValue fresh=values.receive(new Receive(c,UUID.randomUUID(),p.product(),bd("2"),qty(p.product()),bd("40"),true));physical(fresh,c,p.product(),bd("2"),1);return fresh;});
        adjust(p.b(),p.bSource(),"100");drain();lockedAll(List.of(p.product()),()->productionCosts.recalculate(context(),p.segment(),2));drainProduction();
        balance(p.product(),"7","40");costPosition(p,"700","0","0","0","700");
    }

    @Test void procurementFailureResolverUsesTheWholeFundingQualityIdentityAndNeverGuessesByAp(){
        PoolKey k=key();PositionValue acquired=acquire(k,"2","1","0",true,List.of());
        UUID partId=db.queryForObject("SELECT evidence_id FROM stock_value_acquisition_sources WHERE source_node_id=?",UUID.class,acquired.fundingSourceNodeId());
        UUID caseId=UUID.randomUUID(),funding=UUID.randomUUID(),ap=UUID.randomUUID(),qualityId=UUID.randomUUID(),receipt=UUID.randomUUID(),receiptItem=UUID.randomUUID();
        PositionValue failed=locked(k,()->positions.move(new Move(context(),k,Owner.REJECTED_HOLD,caseId,
                List.of(new Slice(acquired.positionRootId(),bd("1"),qualityId)))));
        var part=new ProcurementReceiptConsiderationPort.Part(partId,"PURCHASE",receipt,receiptItem,
                ProcurementReceiptConsiderationPort.BillingMode.STANDARD,null,caseId,funding,funding,caseId,null,null,receiptItem,
                ap,ap,bd("1"),new BigDecimal("0.00005"),bd("0.5"),new BigDecimal("0.00005"),bd("0.5"));
        var quality=new ProcurementReceiptConsiderationPort.QualityPart(qualityId,partId,UUID.randomUUID(),UUID.randomUUID(),"FAIL",bd("1"));
        ProcurementReceiptConsiderationPort quotes=new ProcurementReceiptConsiderationPort(){
            public List<Part> receipt(String type,UUID id){return List.of(part);}
            public List<Part> failure(UUID id){return caseId.equals(id)?List.of(part):List.of();}
            public Optional<QualityPart> failureQuality(UUID id,UUID slice){return caseId.equals(id)&&funding.equals(slice)?Optional.of(quality):Optional.empty();}
            public List<QualityPart> quality(UUID event){return List.of(quality);}
            public List<StockPart> stock(UUID stock){return List.of();}
        };
        var resolver=new InventoryProcurementValueService(new NamedParameterJdbcTemplate(Objects.requireNonNull(db.getDataSource())),Optional.of(quotes),positions);
        FailureReference ref=new FailureReference(caseId,qualityId,funding,ap);
        var result=locked(k,()->resolver.resolveFailure(ref));assertThat(result.failedPositionId()).isEqualTo(failed.positionRootId());
        assertThat(result.costSourceId()).isEqualTo(acquired.fundingSourceNodeId());money(result.remainingQtyBase(),"1");money(result.knownFeeLocal(),"0.5");
        assertThatThrownBy(()->locked(k,()->resolver.resolveFailure(new FailureReference(caseId,qualityId,funding,UUID.randomUUID())))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->locked(k,()->resolver.resolveFailure(new FailureReference(caseId,UUID.randomUUID(),funding,ap)))).isInstanceOf(ApiException.class);
        move(k,failed.positionRootId(),"1",Owner.EXTERNAL);
        money(locked(k,()->resolver.resolveFailure(ref)).remainingQtyBase(),"0");money(owned(k,"QUALITY_PENDING"),"0.5");
    }

    @Test void sourcePrecisionAndExactShareBoundsSurviveFiniteProjectionFeedbackAndTinyLateCosts(){
        PoolKey k=key();BigDecimal actual=new BigDecimal("1.00010001");EventContext c=context();
        MovementValue acquired=locked(k,()->{MovementValue r=values.receive(new Receive(c,UUID.randomUUID(),k,bd("3"),bd("0"),actual,true));physical(r,c,k,bd("3"),1);return r;});
        assertThat(db.queryForObject("SELECT source_initial_amount_exact FROM stock_value_nodes WHERE id=?",BigDecimal.class,acquired.valueNodeId())).isEqualByComparingTo(actual);
        MovementValue one=issue(k,"1"),two=issue(k,"1");
        var first=authorityValues.authority(new ValueReference(one.valueNodeId(),1));
        var second=authorityValues.authority(new ValueReference(two.valueNodeId(),1));
        assertThat(first.lowerKnownValue().multiply(bd("3"))).isLessThanOrEqualTo(actual);
        assertThat(first.upperKnownValue().multiply(bd("3"))).isGreaterThanOrEqualTo(actual);
        assertThat(second.lowerKnownValue().multiply(bd("3"))).isLessThanOrEqualTo(actual);
        assertThat(second.upperKnownValue().multiply(bd("3"))).isGreaterThanOrEqualTo(actual);
        BigDecimal sumLower=first.lowerKnownValue().add(second.lowerKnownValue());
        BigDecimal sumUpper=first.upperKnownValue().add(second.upperKnownValue());
        assertThat(sumLower.setScale(4,java.math.RoundingMode.HALF_UP)).isEqualByComparingTo("0.6667");
        assertThat(sumUpper.setScale(4,java.math.RoundingMode.HALF_UP)).isEqualByComparingTo("0.6667");
        // The compatibility projection is deliberately NOT the next expression's authority.
        money(owned(k,"COGS"),"0.6668");
        EventContext late=context();var command=new SourceAdjustment(late,acquired.valueNodeId(),new BigDecimal("0.00000001"),true);
        var adjusted=locked(k,()->values.adjustSource(command));drain();
        assertThat(db.queryForObject("SELECT source_amount_exact FROM stock_value_nodes WHERE id=?",BigDecimal.class,acquired.valueNodeId())).isEqualByComparingTo("1.00010002");
        assertThat(db.queryForObject("SELECT source_delta_exact FROM stock_value_events WHERE id=?",BigDecimal.class,adjusted.eventId())).isEqualByComparingTo("0.00000001");
        assertThat(locked(k,()->values.adjustSource(command)).replayed()).isTrue();
        assertThatThrownBy(()->locked(k,()->values.adjustSource(new SourceAdjustment(late,acquired.valueNodeId(),new BigDecimal("0.00000002"),true)))).isInstanceOf(ApiException.class);
        long revision=db.queryForObject("SELECT revision FROM stock_value_nodes WHERE id=?",Long.class,two.valueNodeId());
        var after=authorityValues.authority(new ValueReference(two.valueNodeId(),revision));
        assertThat(after.lowerKnownValue().multiply(bd("3"))).isLessThanOrEqualTo(new BigDecimal("1.00010002"));
        assertThat(after.upperKnownValue().multiply(bd("3"))).isGreaterThanOrEqualTo(new BigDecimal("1.00010002"));
    }

    @Test void fullUnregisteredConsumptionCanReturnToItsExactIssueButRegisteredCostCannotBeMovedAgain(){
        PoolKey k=key();var acquired=acquire(k,"10","100","0",true,List.of());
        UUID issue=UUID.randomUUID();
        var consumed=locked(k,()->positions.move(new Move(context(),k,Owner.COST_WIP,UUID.randomUUID(),List.of(slice(acquired.positionRootId(),"10")))));
        var restored=locked(k,()->positions.restoreUnallocatedConsumed(new RestoreConsumed(context(),k,consumed.positionRootId(),issue,UUID.randomUUID())));
        money(restored.knownValueLocal(),"100");money(owned(k,"COST_WIP"),"0");money(owned(k,"WIP"),"100");
        assertThat(positions.position(restored.positionRootId()).ownerId()).isEqualTo(issue);
        Production p=production();productionRevision(p,0,"20",true);
        assertThatThrownBy(()->locked(p.b(),()->positions.restoreUnallocatedConsumed(
                new RestoreConsumed(context(),p.b(),p.bInput(),UUID.randomUUID(),UUID.randomUUID())))).isInstanceOf(ApiException.class);
    }

    @Test void partialAllocatedConsumptionReturnAndTinyLateCostKeepTheOriginalExactSource(){
        PoolKey input=key(),product=key();UUID segment=UUID.randomUUID(),issueOwner=UUID.randomUUID();
        PositionValue acquired=acquire(input,"3","1.00010001","0",true,List.of());
        var passed=move(input,acquired.positionRootId(),"3",Owner.QUALITY_PASSED);store(input,List.of(slice(passed.positionRootId(),"3")));
        UUID consumed=locked(input,()->{
            EventContext c=context();var issued=values.issue(new Issue(c,UUID.randomUUID(),input,bd("3"),qty(input),Destination.WIP,issueOwner));
            physical(issued,c,input,bd("3"),-1);
            return positions.move(new Move(context(),input,Owner.COST_WIP,segment,List.of(slice(issued.valueNodeId(),"3")))).positionRootId();
        });
        var output=locked(product,()->{
            EventContext c=context();var value=values.receive(new Receive(c,UUID.randomUUID(),product,bd("3"),qty(product),null,false));
            physical(value,c,product,bd("3"),1);productionCosts.registerOutput(segment,product,new InventoryProductionCostPort.Output(value.valueNodeId(),value.movementId()));return value;
        });
        UUID approval=UUID.randomUUID();
        lockedAll(List.of(input,product),()->productionCosts.revise(new InventoryProductionCostPort.Revision(context(),segment,product,0,bd("3"),true,
                approval,"a".repeat(64),List.of(new InventoryProductionCostPort.Input(consumed,UUID.randomUUID(),InventoryProductionCostPort.InputKind.CONSUMED)),List.of())));
        drainProduction();var sale=issue(product,"3");
        var returned=locked(input,()->positions.returnConsumed(new ReturnConsumed(context(),input,consumed,bd("1"),Owner.WIP,issueOwner)));
        money(owned(input,"COST_WIP"),"-0.3334");
        lockedAll(List.of(input,product),()->productionCosts.revise(new InventoryProductionCostPort.Revision(context(),segment,product,1,bd("3"),false,
                approval,"a".repeat(64),List.of(),List.of())));
        drainProduction();money(owned(input,"COST_WIP"),"0");money(owned(product,"COGS"),"0.6667");
        assertExactReturnedAndSoldTotal(returned.positionRootId(),sale.valueNodeId(),"1.00010001");
        adjust(input,acquired.fundingSourceNodeId(),"0.00000001");drain();
        lockedAll(List.of(input,product),()->productionCosts.recalculate(context(),segment,2));drainProduction();
        assertExactReturnedAndSoldTotal(returned.positionRootId(),sale.valueNodeId(),"1.00010002");
        assertThat(db.queryForObject("SELECT source_amount_exact FROM stock_value_nodes WHERE id=?",BigDecimal.class,acquired.fundingSourceNodeId())).isEqualByComparingTo("1.00010002");
        assertThat(db.queryForObject("SELECT count(*) FROM stock_value_nodes n JOIN stock_value_pools p ON p.id=n.pool_id WHERE p.goods_id IN (?,?) AND n.owner_kind='LOSS'",Integer.class,input.goodsId(),product.goodsId())).isZero();
    }

    private static void assertExactReturnedAndSoldTotal(UUID returned,UUID sold,String expected){
        var a=authorityValues.authority(new ValueReference(returned,db.queryForObject("SELECT revision FROM stock_value_nodes WHERE id=?",Long.class,returned)));
        var b=authorityValues.authority(new ValueReference(sold,db.queryForObject("SELECT revision FROM stock_value_nodes WHERE id=?",Long.class,sold)));
        assertThat(a.lowerKnownValue().add(b.lowerKnownValue())).isLessThanOrEqualTo(new BigDecimal(expected));
        assertThat(a.upperKnownValue().add(b.upperKnownValue())).isGreaterThanOrEqualTo(new BigDecimal(expected));
        assertThat(a.upperKnownValue().add(b.upperKnownValue()).subtract(a.lowerKnownValue()).subtract(b.lowerKnownValue())).isLessThan(new BigDecimal("1e-20"));
    }

    private record Production(UUID segment,PoolKey product,PoolKey b,PoolKey e,UUID bSource,UUID bInput,UUID eInput,MovementValue fg){}
    private static Production production(){
        UUID segment=UUID.randomUUID();PoolKey product=key(),b=key(),e=key();PositionValue bCost=acquire(b,"20","400","0",true,List.of()),eCost=acquire(e,"20","200","0",true,List.of());
        PositionValue bg=move(b,bCost.positionRootId(),"20",Owner.QUALITY_PASSED),eg=move(e,eCost.positionRootId(),"20",Owner.QUALITY_PASSED);
        store(b,List.of(slice(bg.positionRootId(),"20")));store(e,List.of(slice(eg.positionRootId(),"20")));
        UUID bi=consume(b,segment),ei=consume(e,segment);
        MovementValue fg=locked(product,()->{EventContext c=context();MovementValue r=values.receive(new Receive(c,UUID.randomUUID(),product,bd("5"),bd("0"),null,false));
            physical(r,c,product,bd("5"),1);productionCosts.registerOutput(segment,product,new InventoryProductionCostPort.Output(r.valueNodeId(),r.movementId()));return r;});
        return new Production(segment,product,b,e,bCost.fundingSourceNodeId(),bi,ei,fg);
    }
    private static UUID consume(PoolKey k,UUID segment){return locked(k,()->{EventContext c=context();MovementValue issued=values.issue(new Issue(c,UUID.randomUUID(),k,bd("20"),qty(k),Destination.WIP,segment));
        physical(issued,c,k,bd("20"),-1);return positions.move(new Move(context(),k,Owner.COST_WIP,segment,List.of(slice(issued.valueNodeId(),"20")))).positionRootId();});}
    private static InventoryProductionCostPort.Revised productionRevision(Production p,long prior,String target,boolean first){
        var inputs=first?List.of(new InventoryProductionCostPort.Input(p.bInput(),UUID.randomUUID(),InventoryProductionCostPort.InputKind.CONSUMED),new InventoryProductionCostPort.Input(p.eInput(),UUID.randomUUID(),InventoryProductionCostPort.InputKind.CONSUMED)):List.<InventoryProductionCostPort.Input>of();
        var outputs=first?List.of(new InventoryProductionCostPort.Output(p.fg().valueNodeId(),p.fg().movementId())):List.<InventoryProductionCostPort.Output>of();
        return lockedAll(List.of(p.product(),p.b(),p.e()),()->productionCosts.revise(new InventoryProductionCostPort.Revision(context(),p.segment(),p.product(),prior,bd(target),false,UUID.randomUUID(),"b".repeat(64),inputs,outputs)));
    }
    private static void costPosition(Production p,String actual,String allocated,String wip,String adjustment,String unclassified){var v=productionCosts.position(p.segment());
        money(v.actualKnownCostLocal(),actual);money(v.allocatedToOutputsLocal(),allocated);money(v.heldWipLocal(),wip);money(v.pendingReallocationLocal(),adjustment);money(v.unclassifiedLocal(),unclassified);
        money(v.allocatedToOutputsLocal().add(v.heldWipLocal()).add(v.pendingReallocationLocal()).add(v.unclassifiedLocal()),actual);}
    private static <T>T lockedAll(List<PoolKey> keys,Supplier<T> action){return tx.execute(s->{mutex.lockAll(keys.stream().map(k->new InventoryKey(k.goodsId(),k.colorId())).toList());return action.get();});}
    private static void drainProduction(){for(int i=0;i<500;i++){var tasks=productionCosts.pendingWork(100);if(tasks.isEmpty()){drain();return;}
        for(var work:tasks)lockedAll(List.of(work.inputPool(),work.outputPool()),()->productionCosts.apply(work.taskId()));}fail("Production allocation did not finish");}

    private static PoolKey key(){UUID id=UUID.randomUUID();db.update("INSERT INTO goods VALUES (?)",id);return new PoolKey(WAREHOUSE,id,null);}
    private static EventContext context(){UUID id=UUID.randomUUID();return new EventContext(id,"TEST_POSITION",UUID.randomUUID(),UUID.randomUUID(),1,USER,EMPLOYEE,id.toString(),OffsetDateTime.parse("2026-09-07T00:00:00Z"));}
    private static Slice slice(UUID root,String qty){return new Slice(root,bd(qty),UUID.randomUUID());}
    private static PositionValue acquire(PoolKey key,String qty,String cost,String carry,boolean complete,List<Slice> slices){
        UUID id=UUID.randomUUID();proofs.put(id,new Evidence(id,1,key,bd(qty),bd(carry),cost==null?null:new BigDecimal(cost),complete,"TEST_APPROVED_COST",UUID.randomUUID(),1,"a".repeat(64)));
        return locked(key,()->positions.acquire(new Acquire(context(),key,id,1,Owner.QUALITY_PENDING,UUID.randomUUID(),slices)));}
    private static PositionValue move(PoolKey k,UUID root,String qty,Owner owner){return locked(k,()->positions.move(new Move(context(),k,owner,UUID.randomUUID(),List.of(slice(root,qty)))));}
    private static MovementValue store(PoolKey k,List<Slice> slices){return locked(k,()->{EventContext c=context();MovementValue r=positions.store(new Store(c,UUID.randomUUID(),k,qty(k),slices));
        physical(r,c,k,slices.stream().map(Slice::qtyBase).reduce(bd("0"),BigDecimal::add),1);return r;});}
    private static MovementValue issue(PoolKey k,String qty){return locked(k,()->{EventContext c=context();MovementValue r=values.issue(new Issue(c,UUID.randomUUID(),k,bd(qty),qty(k),Destination.COGS,c.sourceItemId()));physical(r,c,k,bd(qty),-1);return r;});}
    private static void adjust(PoolKey k,UUID source,String cost){locked(k,()->values.adjustSource(new SourceAdjustment(context(),source,new BigDecimal(cost),true)));}
    private static <T>T locked(PoolKey k,Supplier<T> action){return tx.execute(s->{mutex.lock(new InventoryKey(k.goodsId(),k.colorId()));return action.get();});}
    private static void physical(MovementValue r,EventContext c,PoolKey k,BigDecimal qty,int direction){if(r.replayed())return;
        db.update("INSERT INTO stock_movements(id,source_doc_type,source_doc_id,source_item_id,goods_id,color_id,warehouse_id,direction,qty,amount_local) VALUES (?,?,?,?,?,?,?,?,?,?)",
                r.movementId(),c.sourceDocType(),c.sourceDocId(),c.sourceItemId(),k.goodsId(),k.colorId(),k.warehouseId(),direction,qty,r.knownValueLocal());
        db.update("INSERT INTO stock_balances(warehouse_id,goods_id,color_id,qty,amount_local) VALUES (?,?,?,?,?) ON CONFLICT(warehouse_id,goods_id,color_id) DO UPDATE SET qty=stock_balances.qty+excluded.qty,amount_local=stock_balances.amount_local+excluded.amount_local",
                k.warehouseId(),k.goodsId(),k.colorId(),qty.multiply(BigDecimal.valueOf(direction)),r.knownValueLocal().multiply(BigDecimal.valueOf(direction)));}
    private static BigDecimal qty(PoolKey k){return sum("SELECT coalesce(sum(qty),0) FROM stock_balances WHERE goods_id=?",k.goodsId());}
    private static BigDecimal owned(PoolKey k,String kind){return db.queryForObject("SELECT coalesce(sum(n.owned_value_local),0) FROM stock_value_nodes n JOIN stock_value_pools p ON p.id=n.pool_id WHERE p.goods_id=? AND n.owner_kind=?",BigDecimal.class,k.goodsId(),kind);}
    private static BigDecimal sum(String sql,UUID id){return db.queryForObject(sql,BigDecimal.class,id);}
    private static void balance(PoolKey k,String qty,String value){money(qty(k),qty);money(sum("SELECT coalesce(sum(amount_local),0) FROM stock_balances WHERE goods_id=?",k.goodsId()),value);}
    private static BigDecimal bd(String n){return new BigDecimal(n).setScale(4);}
    private static void money(BigDecimal n,String expected){assertThat(n).isEqualByComparingTo(expected);}
    private static void drain(){for(int i=0;i<500;i++){List<PropagationWork> work=values.pendingWork(100);if(work.isEmpty())return;boolean progress=false;for(PropagationWork w:work)progress|=locked(w.lockKey(),()->values.propagate(w.taskId())).applied();assertThat(progress).isTrue();}fail("Propagation did not finish");}
    private static void await(CountDownLatch latch){try{if(!latch.await(15,TimeUnit.SECONDS))throw new IllegalStateException("barrier timeout");}catch(InterruptedException e){Thread.currentThread().interrupt();throw new IllegalStateException(e);}}
}
