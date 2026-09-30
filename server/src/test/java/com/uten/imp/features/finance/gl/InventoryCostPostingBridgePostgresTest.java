package com.uten.imp.features.finance.gl;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.application.port.GoodsActualCostQueryPort;
import com.uten.imp.features.stock.valuation.GoodsActualCostQueryService;
import com.uten.imp.features.finance.cost.FinanceCostService;
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
import java.time.LocalDate;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Executes the actual new migration and read/projection SQL in its own disposable PostgreSQL. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class InventoryCostPostingBridgePostgresTest {
    private static final PostgreSQLContainer<?> DB=new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate db;
    private static EntityManagerFactory factory;
    private static EntityManager em;
    private static TransactionTemplate tx;
    private static GoodsActualCostQueryService actual;
    private static final UUID ACTOR=UUID.randomUUID();
    @BeforeAll static void start(){
        DB.start();var dataSource=new DriverManagerDataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword());
        db=new JdbcTemplate(dataSource);actual=new GoodsActualCostQueryService(new NamedParameterJdbcTemplate(dataSource));
        var bean=new LocalContainerEntityManagerFactoryBean();bean.setDataSource(dataSource);bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp.features.common.taskclaim");var props=new Properties();props.put("hibernate.hbm2ddl.auto","none");bean.setJpaProperties(props);bean.afterPropertiesSet();
        factory=bean.getObject();em=SharedEntityManagerCreator.createSharedEntityManager(factory);tx=new TransactionTemplate(new JpaTransactionManager(factory));
    }
    @AfterAll static void stop(){if(factory!=null)factory.close();DB.stop();}
    @BeforeEach void schema() throws Exception {
        db.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public");
        db.execute(resource("/db/inventory-cost-bridge-fixture.sql"));
        db.execute(resource("/db/migration/V754__inventory_cost_posting_bridge.sql"));
        db.execute(resource("/db/migration/V756__production_cost_frozen_identity.sql"));
        db.update("INSERT INTO users VALUES(?)",ACTOR);
        db.update("INSERT INTO payment_styles VALUES(?,?),(?,?)",UUID.randomUUID(),"SALES_COST",UUID.randomUUID(),"INVENTORY_ASSET");
    }
    @Test void currentAndHistoricalActualCostsUseFrozenEvidenceNotMasterBudget() throws Exception {
        Case data=production();
        var first=actual.snapshot(new GoodsActualCostQueryPort.Query(data.goods(),null,null,null,null));
        assertThat(first.summary().knownInputCostLocal()).isEqualByComparingTo("12");
        assertThat(first.summary().allocatedOutputCostLocal()).isEqualByComparingTo("12");
        assertThat(first.summary().actualUnitCostLocal()).isEqualByComparingTo("2");
        assertThat(first.summary().fullCostComplete()).isFalse();
        assertThat(first.inputs().getFirst().quantityBasis()).isEqualTo("PERIODIC_ALLOCATION");
        UUID material=first.inputs().getFirst().goodsId(),unit=first.inputs().getFirst().unitId();
        db.update("UPDATE goods SET code='CHANGED',name='renamed master' WHERE id=?",material);
        db.update("UPDATE units SET name='renamed unit dictionary' WHERE id=?",unit);
        var renamed=actual.snapshot(new GoodsActualCostQueryPort.Query(data.goods(),null,null,null,data.revision()));
        assertThat(renamed.inputs().getFirst().goodsCode()).isEqualTo("M");
        assertThat(renamed.inputs().getFirst().goodsName()).isEqualTo("material");
        assertThat(renamed.inputs().getFirst().unitName()).isEqualTo("个");
        assertThat(renamed.inputs().getFirst().exactAmountLower()).isEqualByComparingTo("12");
        var snapshotWriter=new com.uten.imp.features.stock.valuation.InventoryProductionCostService(
                new NamedParameterJdbcTemplate(db.getDataSource()),
                org.mockito.Mockito.mock(com.uten.imp.features.stock.InventoryMutationLock.class),
                org.mockito.Mockito.mock(com.uten.imp.features.stock.valuation.InventoryValuationService.class));
        Map<String,Object> newSnapshot=org.springframework.test.util.ReflectionTestUtils.invokeMethod(snapshotWriter,"snapshot",data.scope());
        JsonNode frozenIdentity=new ObjectMapper().readTree(newSnapshot.get("inputs").toString()).get(0).path("identity");
        assertThat(frozenIdentity.path("goodsName").asText()).isEqualTo("material");
        assertThat(frozenIdentity.path("unitName").asText()).isEqualTo("个");
        db.update("UPDATE goods SET c_total=999999 WHERE id=?",data.goods());
        UUID next=revision(data,2,"18","9");
        db.update("UPDATE stock_value_nodes SET basis_value_local=18,revision=2,bound_lower=18,bound_upper=18 WHERE id=?",data.input());
        db.update("UPDATE stock_value_production_cost_objects SET current_revision_id=?,version=2 WHERE execution_segment_id=?",next,data.scope());
        var historical=actual.snapshot(new GoodsActualCostQueryPort.Query(data.goods(),data.scope(),null,null,data.revision()));
        assertThat(historical.summary().allocatedOutputCostLocal()).isEqualByComparingTo("12");
        assertThat(historical.summary().knownInputCostLocal()).isEqualByComparingTo("12");
        assertThat(historical.costObjects().getFirst().historicalRevision()).isTrue();
        assertThat(historical.inputs().getFirst().exactAmountLower()).isEqualByComparingTo("12");
        var september=actual.snapshot(new GoodsActualCostQueryPort.Query(data.goods(),null,LocalDate.of(2026,9,1),LocalDate.of(2026,9,30),null));
        assertThat(september.summary().knownInputCostLocal()).isEqualByComparingTo("18");
        assertThat(september.summary().allocatedOutputCostLocal()).isEqualByComparingTo("9");
        assertThat(september.summary().scopeAllocatedOutputCostLocal()).isEqualByComparingTo("18");
        assertThat(september.summary().excludedOutputCostLocal()).isEqualByComparingTo("9");
        assertThat(september.summary().outputQtyBase()).isEqualByComparingTo("3");
        assertThat(september.summary().actualUnitCostLocal()).isEqualByComparingTo("3");
        assertThat(september.inputs().getFirst().exactAmountLower()).isEqualByComparingTo("18");
        assertThat(september.inputs().getFirst().unitName()).isEqualTo("个");
        var json=new ObjectMapper().findAndRegisterModules().readTree(new ObjectMapper().findAndRegisterModules().writeValueAsString(september));
        assertThat(json.path("summary").path("knownInputCostLocal").isTextual()).isTrue();
        db.update("UPDATE stock_value_production_cost_outputs SET withdrawn_movement_id=? WHERE source_node_id=?",UUID.randomUUID(),data.output2());
        var withdrawal=actual.snapshot(new GoodsActualCostQueryPort.Query(data.goods(),null,null,null,null));
        assertThat(withdrawal.outputs()).anyMatch(GoodsActualCostQueryPort.OutputLine::withdrawn);
        assertThat(withdrawal.summary().outputQtyBase()).isEqualByComparingTo("3");
        assertThat(withdrawal.summary().pending()).isTrue();
        assertThat(withdrawal.summary().actualUnitCostLocal()).isNull();
    }
    @Test void unknownLegacyAndApplyingCostsNeverBecomeConfirmedZero(){
        UUID absent=UUID.randomUUID();var missing=actual.snapshot(new GoodsActualCostQueryPort.Query(absent,null,null,null,null));
        assertThat(missing.summary().knownInputCostLocal()).isNull();assertThat(missing.summary().pending()).isTrue();
        Case data=production();db.update("UPDATE stock_value_nodes SET value_model='LEGACY_4_PROJECTION' WHERE id=?",data.input());
        var legacy=actual.snapshot(new GoodsActualCostQueryPort.Query(data.goods(),null,null,null,null));
        assertThat(legacy.summary().knownInputCostLocal()).isNull();assertThat(legacy.summary().actualUnitCostLocal()).isNull();
        db.update("UPDATE stock_value_nodes SET value_model='EXACT_SOURCE_SHARES' WHERE id=?",data.input());
        db.update("UPDATE stock_value_production_cost_objects SET state='PENDING_CLASSIFICATION' WHERE execution_segment_id=?",data.scope());
        assertThat(actual.snapshot(new GoodsActualCostQueryPort.Query(data.goods(),null,null,null,null)).costObjects().getFirst().state()).isEqualTo("PENDING_CLASSIFICATION");
        db.update("UPDATE stock_value_production_cost_objects SET state='APPLYING' WHERE execution_segment_id=?",data.scope());
        db.update("UPDATE stock_value_production_cost_tasks SET status='PENDING' WHERE output_source_node_id=?",data.output2());
        var applying=actual.snapshot(new GoodsActualCostQueryPort.Query(data.goods(),null,null,null,null));
        assertThat(applying.summary().allocatedOutputCostLocal()).isNull();
        assertThat(applying.summary().heldWipLocal()).isNull();
        assertThat(applying.summary().actualUnitCostLocal()).isNull();
        assertThat(applying.costObjects().getFirst().state()).isEqualTo("APPLYING");
    }
    @Test void signedReturnsLateCostsAndRetryAppendBalancedImmutableVouchers(){
        Cogs data=cogs();
        assertThat(db.queryForObject("SELECT sum(amount_local) FROM v_stock_actual_cogs_postings",BigDecimal.class)).isEqualByComparingTo("70");
        assertThat(db.queryForObject("SELECT posting_status FROM v_inventory_cost_gl_status WHERE posting_id=?",String.class,data.sale())).isEqualTo("DISABLED_PENDING_RECONCILIATION");
        db.update("UPDATE inventory_cost_gl_policy SET enabled=true,effective_from='2026-09-01',reconciliation_reference='verified fixture actual cost'");
        assertThat(db.queryForObject("SELECT posting_status FROM v_inventory_cost_gl_status WHERE posting_id=?",String.class,data.late())).isEqualTo("TARGET_PERIOD_REQUIRED");
        assertThatThrownBy(()->post("2026-09")).hasMessageContaining("待核价");
        db.update("INSERT INTO inventory_cost_gl_period_choices(posting_id,target_period,reason,created_by) VALUES(?,'2026-10','late invoice adjustment',?)",data.late(),ACTOR);
        assertThat(post("2026-09")).isEqualTo(2);assertThat(post("2026-09")).isZero();
        assertThat(db.queryForObject("SELECT sum(amount) FROM gl_entries WHERE direction=1 AND period='2026-09'",BigDecimal.class)).isEqualByComparingTo("60");
        db.update("UPDATE inventory_cost_gl_periods SET status='CLOSED',closed_at=now(),closed_by=?,close_reason='checked' WHERE period='2026-09'",ACTOR);
        assertThat(post("2026-10")).isEqualTo(1);
        assertThat(db.queryForObject("SELECT sum(amount) FROM gl_entries WHERE direction=1",BigDecimal.class)).isEqualByComparingTo("70");
        assertThat(db.queryForObject("SELECT sum(direction*amount) FROM gl_entries",BigDecimal.class)).isZero();
        assertThatThrownBy(()->db.update("UPDATE gl_entries SET amount=999 WHERE period='2026-09'")).hasMessageContaining("不可改写");
        assertThatThrownBy(()->db.update("DELETE FROM gl_vouchers WHERE source_type='ACTUAL_COGS'")).hasMessageContaining("不可改写");
    }
    @Test void closedAndLegacyPeriodsRemainVisibleAndCannotSilentlyPost(){
        Cogs data=cogs();db.update("UPDATE inventory_cost_gl_policy SET enabled=true,effective_from='2026-09-01',reconciliation_reference='verified fixture actual cost'");
        db.update("INSERT INTO inventory_cost_gl_periods(period,status,closed_at,closed_by,close_reason) VALUES('2026-09','CLOSED',now(),?,'closed fixture')",ACTOR);
        assertThat(db.queryForObject("SELECT posting_status FROM v_inventory_cost_gl_status WHERE posting_id=?",String.class,data.sale())).isEqualTo("TARGET_PERIOD_CLOSED");
        assertThatThrownBy(()->post("2026-09")).hasMessageContaining("历史对账");
        db.update("INSERT INTO gl_vouchers(voucher_no,period,source,source_type,source_doc_id) VALUES('old-CB','2026-09','AUTO','COST_CARRY',?)",data.shipment());
        assertThat(db.queryForObject("SELECT posting_status FROM v_inventory_cost_gl_status WHERE posting_id=?",String.class,data.sale())).isEqualTo("LEGACY_VOUCHER_RECONCILIATION_REQUIRED");
        assertThat(db.queryForObject("SELECT count(*) FROM inventory_cost_gl_links",Integer.class)).isZero();
    }
    @Test void backdatedCostCreatedAfterCutoverStillRequiresExplicitPostingPeriod(){
        Cogs data=cogs();db.update("UPDATE inventory_cost_gl_policy SET enabled=true,effective_from='2026-10-01',reconciliation_reference='verified fixture actual cost'");
        assertThat(db.queryForObject("SELECT posting_status FROM v_inventory_cost_gl_status WHERE posting_id=?",String.class,data.sale())).isEqualTo("BEFORE_CUTOVER");
        assertThat(db.queryForObject("SELECT posting_status FROM v_inventory_cost_gl_status WHERE posting_id=?",String.class,data.late())).isEqualTo("TARGET_PERIOD_REQUIRED");
    }
    @Test void missingHistoricalIdentityAndEvidenceNeverFallBackToCurrentMastersOrNode(){
        Case data=production(false);
        db.update("UPDATE stock_value_production_cost_revisions SET input_snapshot=jsonb_build_array((input_snapshot->0)-'identity') WHERE id=?",data.revision());
        var missing=actual.snapshot(new GoodsActualCostQueryPort.Query(data.goods(),null,null,null,data.revision()));
        assertThat(missing.inputs().getFirst().goodsCode()).isNull();
        assertThat(missing.inputs().getFirst().goodsName()).isNull();
        assertThat(missing.inputs().getFirst().unitName()).isNull();
        assertThat(missing.summary().pending()).isTrue();
        assertThat(missing.gaps()).anyMatch(gap->gap.code().equals("ORIGINAL_INPUT_IDENTITY_MISSING"));
        db.update("UPDATE stock_value_nodes SET basis_value_local=999,revision=99,bound_lower=999,bound_upper=999 WHERE id=?",data.input());
        db.update("UPDATE stock_value_production_cost_revisions SET input_snapshot=jsonb_build_array((input_snapshot->0)-'value'-'quantityBasis'-'revision'-'pending') WHERE id=?",data.revision());
        var unavailable=actual.snapshot(new GoodsActualCostQueryPort.Query(data.goods(),null,null,null,data.revision()));
        assertThat(unavailable.inputs().getFirst().knownAmountLocal()).isNull();
        assertThat(unavailable.inputs().getFirst().grossQtyBase()).isNull();
        assertThat(unavailable.inputs().getFirst().exactAmountLower()).isNull();
        assertThat(unavailable.summary().actualUnitCostLocal()).isNull();
    }
    @Test void newPhysicalEvidenceUsesLockedOriginalDocumentAndCannotBeRewritten(){
        Case data=production();UUID material=db.queryForObject("SELECT goods_id FROM stock_value_pools WHERE id=(SELECT pool_id FROM stock_value_nodes WHERE id=?)",UUID.class,data.input());
        UUID pool=db.queryForObject("SELECT pool_id FROM stock_value_nodes WHERE id=?",UUID.class,data.input());
        UUID unit=db.queryForObject("SELECT unit_id FROM goods WHERE id=?",UUID.class,material);
        UUID item=UUID.randomUUID(),movement=UUID.randomUUID(),issued=UUID.randomUUID(),consumed=UUID.randomUUID();
        db.update("INSERT INTO stock_document_items VALUES(?,?, 'ORIGINAL-CODE','原单物料名称','MASTER_AT_APPROVAL',now(),?,1)",item,material,unit);
        db.update("INSERT INTO stock_movements(id,goods_id,warehouse_id,transaction_date,movement_type,direction,qty,source_doc_type,source_doc_id,source_item_id) VALUES(?,?,?,now(),5,-1,1,'STOCK_DOC',?,?)",movement,material,UUID.randomUUID(),UUID.randomUUID(),item);
        db.update("INSERT INTO stock_value_nodes(id,pool_id,kind,movement_id,quantity_basis,basis_value_local) VALUES(?,?,'ISSUE_POSITION',?,1,1),(?,?,'ISSUE_POSITION',NULL,1,1)",issued,pool,movement,consumed,pool);
        db.update("INSERT INTO stock_value_position_transfers(event_id,source_root_id,target_node_id) VALUES(?,?,?)",UUID.randomUUID(),issued,consumed);
        db.update("UPDATE goods SET code='NOW',name='当前物料名称' WHERE id=?",material);
        db.update("UPDATE units SET name='当前单位名' WHERE id=?",unit);
        String identity=db.queryForObject("SELECT fn_production_cost_input_identity(?,NULL)::text",String.class,consumed);
        assertThat(identity).contains("ORIGINAL-CODE","原单物料名称","个","COMPLETE").doesNotContain("当前物料名称","当前单位名");
        assertThatThrownBy(()->db.update("UPDATE stock_movements SET cost_identity_snapshot='{}' WHERE id=?",movement)).hasMessageContaining("不可改写");
    }
    @Test void forwardMigrationDoesNotBackfillCurrentMasterIntoExistingFacts() throws Exception {
        db.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public");
        db.execute(resource("/db/inventory-cost-bridge-fixture.sql"));
        db.execute(resource("/db/migration/V754__inventory_cost_posting_bridge.sql"));
        UUID unit=UUID.randomUUID(),goods=UUID.randomUUID(),pool=UUID.randomUUID(),node=UUID.randomUUID(),movement=UUID.randomUUID();
        db.update("INSERT INTO units(id,name) VALUES(?,'现在的单位')",unit);
        db.update("INSERT INTO goods(id,code,name,unit_id) VALUES(?,'CURRENT','现在的名称',?)",goods,unit);
        db.update("INSERT INTO stock_value_pools(id,goods_id) VALUES(?,?)",pool,goods);
        db.update("INSERT INTO stock_value_nodes(id,pool_id,kind,quantity_basis,basis_value_local) VALUES(?,?,'SOURCE',1,1)",node,pool);
        db.update("INSERT INTO stock_movements(id,goods_id,transaction_date,movement_type,direction,qty) VALUES(?,?,now(),5,-1,1)",movement,goods);
        db.execute(resource("/db/migration/V756__production_cost_frozen_identity.sql"));
        assertThat(db.queryForObject("SELECT origin_identity_snapshot IS NULL FROM stock_value_nodes WHERE id=?",Boolean.class,node)).isTrue();
        assertThat(db.queryForObject("SELECT cost_identity_snapshot IS NULL FROM stock_movements WHERE id=?",Boolean.class,movement)).isTrue();
        String evidence=db.queryForObject("SELECT fn_production_cost_input_identity(?,NULL)::text",String.class,node);
        assertThat(evidence).contains("MISSING").doesNotContain("现在的单位","现在的名称","CURRENT");
    }
    @Test void unpricedZeroWithoutPostingBlocksGenerationAndCloseButConfirmedZeroDoesNot(){
        UUID goods=UUID.randomUUID(),unit=UUID.randomUUID(),pool=UUID.randomUUID(),node=UUID.randomUUID(),event=UUID.randomUUID();
        UUID movement=UUID.randomUUID(),shipment=UUID.randomUUID(),item=UUID.randomUUID();
        db.update("INSERT INTO units(id,name) VALUES(?,'个')",unit);
        db.update("INSERT INTO goods(id,code,name,unit_id) VALUES(?,'ZERO','待定价实物',?)",goods,unit);
        db.update("INSERT INTO stock_value_pools(id,goods_id,warehouse_id) VALUES(?,?,?)",pool,goods,UUID.randomUUID());
        db.update("INSERT INTO sales_shipments VALUES(?,?,'2026-08-31',1,false)",shipment,UUID.randomUUID());
        db.update("INSERT INTO sales_shipment_items VALUES(?,?,?,false)",item,shipment,goods);
        db.update("INSERT INTO stock_value_nodes(id,pool_id,creation_event_id,kind,owner_kind,owner_id,quantity_basis,basis_value_local,pending_parents,movement_id) VALUES(?,?,?,'ISSUE_POSITION','COGS',?,1,0,1,?)",node,pool,event,item,movement);
        db.update("INSERT INTO stock_value_events(id,operation,source_doc_type,source_doc_id,source_item_id,occurred_at,movement_id,result_node_id) VALUES(?,'ISSUE','SALES_SHIPMENT',?,?,'2026-09-01T00:00:00Z',?,?)",event,shipment,item,movement,node);
        db.update("INSERT INTO stock_movements(id,goods_id,transaction_date,movement_type,direction,qty,source_doc_type,source_doc_id,source_item_id) VALUES(?,?,'2026-09-01T00:00:00Z',3,-1,1,'SALES_SHIPMENT',?,?)",movement,goods,shipment,item);
        assertThat(db.queryForObject("SELECT count(*) FROM stock_value_postings",Integer.class)).isZero();
        var current=org.mockito.Mockito.mock(com.uten.imp.security.SecurityContextCurrentUser.class);
        org.mockito.Mockito.when(current.requireId()).thenReturn(ACTOR);
        var service=new InventoryCostPostingService(em,org.mockito.Mockito.mock(com.uten.imp.security.TxSessionVars.class),current,
                org.mockito.Mockito.mock(com.uten.imp.application.port.InventoryCostPostingQueryPort.class));
        assertThatThrownBy(()->post("2026-09")).hasMessageContaining("尚未启用");
        assertThatThrownBy(()->tx.execute(status->{service.close("2026-09",new InventoryCostPostingService.ClosePeriod(0,"核对本期"));return null;})).hasMessageContaining("尚未启用");
        db.update("UPDATE inventory_cost_gl_policy SET enabled=true,effective_from='2026-09-01',reconciliation_reference='reviewed zero cost fixture'");
        assertThat(service.periods("2026-08","2026-09")).extracting(InventoryCostPostingService.PeriodView::pendingCount).containsExactly(0L,1L);
        assertThatThrownBy(()->post("2026-09")).hasMessageContaining("待核价");
        assertThatThrownBy(()->tx.execute(status->{service.close("2026-09",new InventoryCostPostingService.ClosePeriod(0,"核对本期"));return null;})).hasMessageContaining("未定价");
        db.update("UPDATE stock_value_nodes SET pending_parents=0 WHERE id=?",node);
        assertThat(service.periods("2026-09","2026-09").getFirst().pendingCount()).isZero();
        assertThat(post("2026-09")).isZero();
        tx.execute(status->{service.close("2026-09",new InventoryCostPostingService.ClosePeriod(0,"已确认零成本"));return null;});
        assertThat(db.queryForObject("SELECT status FROM inventory_cost_gl_periods WHERE period='2026-09'",String.class)).isEqualTo("CLOSED");
    }
    @Test void financeReportKeepsReturnOnlyPeriodsAndDoesNotInventNetProfit(){
        Cogs data=cogs();UUID client=db.queryForObject("SELECT client_id FROM sales_shipments WHERE id=?",UUID.class,data.shipment());
        db.update("INSERT INTO clients(id,code,name) VALUES(?,'CLIENT','return-only client')",client);
        db.update("UPDATE sales_shipments SET bill_date='2026-08-05' WHERE id=?",data.shipment());
        db.update("UPDATE stock_value_events SET occurred_at='2026-08-10T00:00:00Z' WHERE id=(SELECT event_id FROM stock_value_postings WHERE id=?)",data.sale());
        db.update("UPDATE stock_value_events SET occurred_at='2026-10-10T00:00:00Z' WHERE id=(SELECT event_id FROM stock_value_postings WHERE id=?)",data.late());
        db.update("INSERT INTO ar_ap_ledger(client_id,direction,source_doc_type,bill_date,amount_original_local,amount_original,currency_id) VALUES(?,'AR','SALES_RETURN','2026-09-10',-80,-5,?)",client,UUID.randomUUID());
        var report=new FinanceCostService(em).salesCostSummary(null,LocalDate.of(2026,9,1),LocalDate.of(2026,9,30),1,50);
        assertThat(report.rows()).hasSize(1);var row=report.rows().getFirst();
        assertThat((BigDecimal)row.get("saleAmount")).isEqualByComparingTo("-80");
        assertThat((BigDecimal)row.get("saleCost")).isEqualByComparingTo("-40");
        assertThat(row.get("saleCostExact")).isEqualTo("-40");
        assertThat(row.get("netProfit")).isNull();assertThat(row.get("manageFee")).isNull();assertThat(row.get("taxFee")).isNull();
        assertThat(row.get("currencyBasis")).isEqualTo("LOCAL");
    }
    @Test void financeReportAggregatesFrozenLocalAmountsAcrossCurrenciesAndRetainsConfirmedZero(){
        Cogs data=cogs();UUID client=db.queryForObject("SELECT client_id FROM sales_shipments WHERE id=?",UUID.class,data.shipment());
        db.update("INSERT INTO clients(id,code,name) VALUES(?,'CLIENT','multi-currency client')",client);
        db.update("INSERT INTO ar_ap_ledger(client_id,direction,source_doc_type,bill_date,amount_original_local,amount_original,currency_id) VALUES(?,'AR','SALES_SHIPMENT','2026-09-10',100,10,?),(?,'AR','SALES_SHIPMENT','2026-09-10',100,20,?)",client,UUID.randomUUID(),client,UUID.randomUUID());
        var costs=new FinanceCostService(em);
        assertThat((BigDecimal)costs.salesCostSummary(null,LocalDate.of(2026,9,1),LocalDate.of(2026,9,30),1,50).rows().getFirst().get("saleAmount")).isEqualByComparingTo("200");
        Case production=production();db.update("UPDATE stock_value_nodes SET basis_value_local=0 WHERE id IN(?,?,?)",production.input(),production.output1(),production.output2());
        var row=costs.productCost("P",LocalDate.of(2026,9,1),LocalDate.of(2026,9,30),1,50).rows().getFirst();
        assertThat((BigDecimal)row.get("actualCost")).isZero();assertThat(row.get("actualState")).isEqualTo("VALUATION_FINAL");
        db.update("UPDATE stock_value_production_cost_outputs SET withdrawn_movement_id=? WHERE source_node_id=?",UUID.randomUUID(),production.output1());
        row=costs.productCost("P",LocalDate.of(2026,9,1),LocalDate.of(2026,9,30),1,50).rows().getFirst();
        assertThat(row.get("actualCost")).isNull();assertThat(row.get("actualState")).isEqualTo("WITHDRAWN");
    }
    private int post(String period){return tx.execute(status->{em.createNativeQuery("SELECT set_config('app.actor_id',:actor,true)").setParameter("actor",ACTOR.toString()).getSingleResult();return ActualInventoryCostGlProjection.postReady(em,period);});}
    private record Case(UUID goods,UUID scope,UUID input,UUID output1,UUID output2,UUID movement1,UUID movement2,UUID revision){}
    private Case production(){return production(true);}
    private Case production(boolean identity){
        UUID goods=UUID.randomUUID(),material=UUID.randomUUID(),unit=UUID.randomUUID(),scope=UUID.randomUUID(),productPool=UUID.randomUUID(),inputPool=UUID.randomUUID(),input=UUID.randomUUID(),output1=UUID.randomUUID(),output2=UUID.randomUUID(),m1=UUID.randomUUID(),m2=UUID.randomUUID(),event=UUID.randomUUID(),warehouse=UUID.randomUUID();
        db.update("INSERT INTO units(id,name) VALUES(?,'个')",unit);db.update("INSERT INTO goods(id,code,name,unit_id,c_total) VALUES(?,'P','product',?,1),(?,'M','material',?,2)",goods,unit,material,unit);
        db.update("INSERT INTO stock_value_pools VALUES(?,?,?,NULL),(?,?,?,NULL)",productPool,warehouse,goods,inputPool,warehouse,material);
        db.update("INSERT INTO production_execution_segments VALUES(?,'ZX-ACTUAL')",scope);
        db.update("INSERT INTO stock_value_events(id,operation,source_doc_type,source_doc_id,source_item_id,occurred_at) VALUES(?,'POSITION_MOVE','WORKSHOP_PERIOD_SETTLEMENT',?,?,'2026-09-01T00:00:00Z')",event,scope,UUID.randomUUID());
        db.update("INSERT INTO stock_value_nodes(id,pool_id,creation_event_id,kind,quantity_basis,basis_value_local,bound_lower,bound_upper,initial_bound_lower,initial_bound_upper,movement_id) VALUES(?,?,?,?,3,12,12,12,12,12,NULL),(?,?,?,'SOURCE',3,6,6,6,6,6,?),(?,?,?,'SOURCE',3,6,6,6,6,6,?)",input,inputPool,event,identity?"SOURCE":"ISSUE_POSITION",output1,productPool,event,m1,output2,productPool,event,m2);
        db.update("INSERT INTO stock_movements(id,goods_id,warehouse_id,transaction_date,movement_type,direction,qty,source_doc_type,source_doc_id,source_item_id) VALUES(?,?,?,'2026-09-10T00:00:00Z',13,1,3,'STOCK_DOC',?,?),(?,?,?,'2026-10-10T00:00:00Z',13,1,3,'STOCK_DOC',?,?)",m1,goods,warehouse,scope,UUID.randomUUID(),m2,goods,warehouse,scope,UUID.randomUUID());
        db.update("INSERT INTO stock_value_production_cost_objects(execution_segment_id,product_pool_id,source_kind,version,state) VALUES(?,?,'PRODUCTION_EXECUTION',1,'FINAL')",scope,productPool);
        db.update("INSERT INTO stock_value_production_cost_inputs(input_node_id,execution_segment_id,approved_posting_id,input_kind) VALUES(?,?,?,'PERIODIC_MATERIAL')",input,scope,UUID.randomUUID());
        db.update("INSERT INTO stock_value_production_cost_outputs(source_node_id,execution_segment_id,movement_id,qty_base) VALUES(?,?,?,3),(?,?,?,3)",output1,scope,m1,output2,scope,m2);
        Case base=new Case(goods,scope,input,output1,output2,m1,m2,null);UUID revision=revision(base,1,"12","6");db.update("UPDATE stock_value_production_cost_objects SET current_revision_id=? WHERE execution_segment_id=?",revision,scope);
        return new Case(goods,scope,input,output1,output2,m1,m2,revision);
    }
    private UUID revision(Case data,int version,String amount,String each){
        UUID revision=UUID.randomUUID();
        db.update("""
                INSERT INTO stock_value_production_cost_revisions(id,execution_segment_id,version,target_qty_base,output_qty_base,scope_complete,input_snapshot,output_snapshot,occurred_at,source_doc_type,source_doc_id,source_item_id)
                VALUES(?,?,?,6,6,true,jsonb_build_array(jsonb_build_object('node',?::text,'revision',?::int,'quantityBasis',3,'returnedQty',0,'value',?::numeric,'pending',0,'identity',fn_production_cost_input_identity(?::uuid,NULL))),
                jsonb_build_array(jsonb_build_object('source',?::text,'movement',?::text,'qty',3),jsonb_build_object('source',?::text,'movement',?::text,'qty',3)),now(),'PRODUCTION_COST_APPROVAL',?,?)
                """,revision,data.scope(),version,data.input(),version,new BigDecimal(amount),data.input(),data.output1(),data.movement1(),data.output2(),data.movement2(),data.scope(),UUID.randomUUID());
        if(version>1)db.update("INSERT INTO stock_value_node_revisions(node_id,revision,event_id,after_bound_lower,after_bound_upper) VALUES(?,?,?,?,?)",data.input(),version,UUID.randomUUID(),new BigDecimal(amount),new BigDecimal(amount));
        db.update("INSERT INTO stock_value_production_cost_tasks(id,execution_segment_id,revision_id,input_node_id,output_source_node_id,desired_value_local,status) VALUES(?,?,?,?,?,?,'APPLIED'),(?,?,?,?,?,?,'APPLIED')",UUID.randomUUID(),data.scope(),revision,data.input(),data.output1(),new BigDecimal(each),UUID.randomUUID(),data.scope(),revision,data.input(),data.output2(),new BigDecimal(each));
        return revision;
    }
    private record Cogs(UUID sale,UUID returned,UUID late,UUID shipment){}
    private Cogs cogs(){
        UUID pool=UUID.randomUUID(),node=UUID.randomUUID(),shipment=UUID.randomUUID(),item=UUID.randomUUID(),goods=UUID.randomUUID();
        db.update("INSERT INTO stock_value_pools VALUES(?,?,?,NULL)",pool,UUID.randomUUID(),goods);
        db.update("INSERT INTO sales_shipments VALUES(?,?,'2026-09-05',1,false)",shipment,UUID.randomUUID());
        db.update("INSERT INTO sales_shipment_items VALUES(?,?,?,false)",item,shipment,goods);
        db.update("INSERT INTO stock_value_nodes(id,pool_id,kind,owner_kind,basis_value_local) VALUES(?,?,'ISSUE_POSITION','COGS',100)",node,pool);
        UUID sale=posting(node,item,"ISSUE","100","2026-09-05"),returned=posting(node,item,"POSITION_MOVE","-40","2026-09-10"),late=posting(node,item,"COST_ADJUST","10","2026-10-02");
        return new Cogs(sale,returned,late,shipment);
    }
    private UUID posting(UUID node,UUID owner,String operation,String amount,String created){
        UUID event=UUID.randomUUID(),posting=UUID.randomUUID();
        db.update("INSERT INTO stock_value_events(id,operation,source_doc_type,source_doc_id,source_item_id,occurred_at) VALUES(?,?,'SALES_SHIPMENT',?,?,'2026-09-10T00:00:00Z')",event,operation,UUID.randomUUID(),owner);
        db.update("INSERT INTO stock_value_postings(id,event_id,node_id,owner_kind,owner_id,amount_delta_local,created_at) VALUES(?,?,?,'COGS',?,?,?::date)",posting,event,node,owner,new BigDecimal(amount),created);
        return posting;
    }
    private static String resource(String path) throws Exception {try(var input=InventoryCostPostingBridgePostgresTest.class.getResourceAsStream(path)){return new String(Objects.requireNonNull(input).readAllBytes(),StandardCharsets.UTF_8);}}
}
