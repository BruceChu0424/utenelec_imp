package com.uten.imp.businesschain;

import com.uten.imp.UtenImpApplication;
import com.uten.imp.application.port.InventoryValuationPort;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.finance.BusinessPrecisionRequiredException;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.finance.gl.InventoryCostPostingService;
import com.uten.imp.features.sales.shipment.SalesShipmentService;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.boot.WebApplicationType;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.OffsetDateTime;
import java.time.YearMonth;
import java.util.*;
import java.util.function.Supplier;

import static org.assertj.core.api.Assertions.*;

/** Genuine pre-V1025 book rounding, followed by a real schema upgrade; no original value or guard is edited. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class LegacyValuationComponentUpgradePostgresTest {
    @Test void newCumulativeTargetSubtractsTheActualHistoricalPointWithoutChangingItsOriginalGl()throws Exception{
        Path logs=Files.createTempDirectory("uten-legacy-value-upgrade-");
        try(var postgres=new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("legacy_value_component_upgrade")
                .withReuse(false).withCreateContainerCmdModifier(cmd->cmd.getHostConfig().withMemory(1024L*1024*1024).withNanoCPUs(1_000_000_000L))){
            postgres.start();
            Legacy original;
            TestFlyway.configure().dataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword())
                    .locations("classpath:db/migration").target("1024").load().migrate();
            try{
                var old=new HistoricalInventoryJdbc(new org.springframework.jdbc.datasource.DriverManagerDataSource(
                        postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword()),"real-v1-base-"+UUID.randomUUID());
                var db=old.db;var world=old.world;old.enableGl("匿名真实旧四位成本与原GL核对");
                // Only original inputs are supplied. The actual old inventory
                // engine produces the historical amount, without an ORM factory.
                var received=old.receipt(world.goodsD(),null,"3","1.0001");UUID incoming=received.document().id();
                UUID shipmentItem=old.ship(world.goodsD(),"1");
                UUID source=db.queryForObject("SELECT result_node_id FROM stock_value_events WHERE source_doc_id=? AND operation='RECEIVE'",UUID.class,incoming);
                UUID sourceItem=db.queryForObject("SELECT id FROM stock_document_items WHERE doc_id=? AND NOT is_deleted",UUID.class,incoming);
                assertThat(amount(db,"SELECT sum(amount_delta_local) FROM stock_value_postings WHERE owner_kind='COGS' AND owner_id=?",shipmentItem)).isEqualByComparingTo("0.3334");
                assertThat(amount(db,"SELECT amount_local FROM stock_balances WHERE goods_id=?",world.goodsD())).isEqualByComparingTo("0.6667");
                old.postGl();
                assertThat(glAmount(db,world.goodsD())).isEqualByComparingTo("0.3334");
                old.receipt(world.goodsB(),world.colorId(),"2","7.1234");
                original=new Legacy(world,incoming,sourceItem,source,shipmentItem,storedFacts(db,world.goodsD()),glFacts(db,world.goodsD()),storedFacts(db,world.goodsB()));
            }finally{SecurityContextHolder.clearContext();}

            TestFlyway.configure().dataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword())
                    .locations("classpath:db/migration").load().migrate();
            try(var current=start(postgres,logs,"latest","after")){
                var db=current.getBean(JdbcTemplate.class);var fixture=fixture(current);fixture.loginAs(original.world().superAdminUserId());
                assertThat(db.queryForObject("SELECT CAST(? AS jsonb)=CAST(? AS jsonb)",Boolean.class,original.bookFacts(),storedFacts(db,original.goods()))).isTrue();
                assertThat(glFacts(db,original.goods())).isEqualTo(original.glFacts());
                assertUnrelatedActualSourceUnchanged(db,original);
                assertThat(amount(db,"SELECT value_precision_version FROM stock_value_nodes WHERE id=?",original.source())).isEqualByComparingTo("1");
                var values=current.getBean(InventoryValuationPort.class);
                var context=context(original,"upgrade-new-delta");
                var command=new InventoryValuationPort.SourceAdjustment(context,original.source(),BigDecimal.ONE,false);
                // Main's original cumulative target is authoritative: 2.0001/3
                // is finite .6667. The new posting is .6667 minus actual .3334.
                var choices=Map.<String,BusinessPrecisionContext.Choice>of();
                String purpose="stock.value.interval";
                var applied=adjust(current,command,original.goods(),choices);
                Map<String,Long> committed=counts(db);
                assertThat(adjust(current,command,original.goods(),choices).replayed()).isTrue();assertThat(counts(db)).isEqualTo(committed);
                drain(current,original.goods());
                assertThat(amount(db,"SELECT coalesce(sum(owned_value_local),0) FROM stock_value_nodes WHERE owner_kind='COGS' AND owner_id=?",original.shipmentItem())).isEqualByComparingTo("0.6667");
                assertThat(amount(db,"SELECT amount_local FROM stock_balances WHERE goods_id=?",original.goods())).isEqualByComparingTo("1.3334");
                assertUnrelatedActualSourceUnchanged(db,original);
                current.getBean(InventoryCostPostingService.class).post(period());
                assertThat(glAmount(db,original.goods())).isEqualByComparingTo("0.6667");
                assertThat(glFacts(db,original.goods())).containsAllEntriesOf(original.glFacts());
                inPrecision(Map.of(purpose,new BusinessPrecisionContext.Choice(0,"HALF_UP")),()->locked(current,original.goods(),()->values.reverseAdjustment(context(original,"upgrade-reverse-origin"),applied.eventId())));
                drain(current,original.goods());current.getBean(InventoryCostPostingService.class).post(period());
                assertThat(glAmount(db,original.goods())).isEqualByComparingTo("0.3334");
                assertThat(amount(db,"SELECT amount_local FROM stock_balances WHERE goods_id=?",original.goods())).isEqualByComparingTo("0.6667");
                assertThat(amount(db,"SELECT initial_known_value FROM stock_value_nodes WHERE id=?",original.source())).isEqualByComparingTo("1.0001");
                assertThat(glFacts(db,original.goods())).containsAllEntriesOf(original.glFacts());
                assertUnrelatedActualSourceUnchanged(db,original);
            }finally{SecurityContextHolder.clearContext();}
        }
    }

    @Test void twoActualLegacyConsumptionReturnsKeepTheirStoredPrefixesWhenTheNewWholeTargetAndItsInverseRun()throws Exception{
        Path logs=Files.createTempDirectory("uten-legacy-two-consumption-cursors-");
        try(var postgres=new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("legacy_two_consumption_cursors")){
            postgres.start();
            TestFlyway.configure().dataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword())
                .locations("classpath:db/migration").target("1024").load().migrate();
            CursorLegacy original;
            try{
                var before=new HistoricalInventoryJdbc(new org.springframework.jdbc.datasource.DriverManagerDataSource(
                        postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword()),"actual-old-consumption-prefix-"+UUID.randomUUID());
                var db=before.db;var world=before.world;
                before.receipt(world.goodsB(),null,"6","60");
                var incoming=before.receipt(world.goodsE(),null,"3","1.0001").document().id();
                UUID scope=before.produceA();
                UUID plan=db.queryForObject("SELECT plan_id FROM production_execution_segments WHERE id=?",UUID.class,scope);
                before.enableGl("真实旧双实耗游标与原GL");
                UUID orderItem=db.queryForObject("SELECT allocation.sales_order_item_id FROM execution_segment_sales_allocations allocation WHERE execution_segment_id=?",UUID.class,scope);
                before.ship(world.goodsA(),"1",orderItem);before.drain();before.postGl();
                var originalGl=glFacts(db,world.goodsA());assertThat(originalGl).isNotEmpty();
                var consumed=db.queryForMap("""
                    SELECT posting.id,posting.demand_id,event.result_node_id FROM production_material_settlement_postings posting
                    JOIN production_material_demands demand ON demand.id=posting.demand_id
                    JOIN stock_value_events event ON event.source_event_id=posting.id AND event.source_doc_type='PRODUCTION_CONSUMED_VALUE'
                    WHERE demand.plan_id=? AND demand.goods_id=? AND posting.source_posting_id IS NULL
                    """,plan,world.goodsE());
                var returns=new ArrayList<UUID>();
                for(String qty:List.of("0.1","0.2")){
                    before.reverseConsumption((UUID)consumed.get("id"),qty);
                }
                returns.addAll(db.queryForList("SELECT result_node_id FROM stock_value_events WHERE operation='CONSUMPTION_RETURN' AND source_node_id=? ORDER BY occurred_at,id",UUID.class,consumed.get("result_node_id")));
                assertThat(returns).hasSize(2);
                assertReturnPrefixes(db,returns,"0.0333","0.0667");
                assertThat(amount(db,"SELECT sum(basis_value_local) FROM stock_value_nodes WHERE id IN (?,?)",returns.get(0),returns.get(1))).isEqualByComparingTo("0.1");
                assertThat(amount(db,"SELECT sum(owned_value_local) FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=? AND node.owner_kind='COGS'",world.goodsA())).isEqualByComparingTo("20.3");
                UUID source=db.queryForObject("SELECT node.id FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=? AND node.kind='SOURCE'",UUID.class,world.goodsE());
                UUID item=db.queryForObject("SELECT id FROM stock_document_items WHERE doc_id=? AND goods_id=?",UUID.class,incoming,world.goodsE());
                original=new CursorLegacy(world,incoming,item,source,returns,originalGl,storedFacts(db,world.goodsE()),storedFacts(db,world.goodsA()));
            }finally{SecurityContextHolder.clearContext();}
            TestFlyway.configure().dataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword()).locations("classpath:db/migration").load().migrate();
            try(var after=start(postgres,logs,"latest","after-two-cursors")){
                var db=after.getBean(JdbcTemplate.class);var fixture=fixture(after);fixture.loginAs(original.world().superAdminUserId());
                assertThat(db.queryForObject("SELECT ?::jsonb=?::jsonb",Boolean.class,original.materialFacts(),storedFacts(db,original.world().goodsE()))).isTrue();
                assertThat(db.queryForObject("SELECT ?::jsonb=?::jsonb",Boolean.class,original.productFacts(),storedFacts(db,original.world().goodsA()))).isTrue();
                assertThat(glFacts(db,original.world().goodsA())).containsAllEntriesOf(original.glFacts());
                var values=after.getBean(InventoryValuationPort.class);
                var event=cursorContext(original,"whole-target-after-two-old-cursors");
                var adjusted=locked(after,original.world().goodsE(),()->values.adjustSource(new InventoryValuationPort.SourceAdjustment(event,original.source(),BigDecimal.ONE,false)));
                drainAll(fixture,original.world());
                assertReturnPrefixes(db,original.returns(),"0.06667","0.13334");
                assertThat(amount(db,"SELECT sum(basis_value_local) FROM stock_value_nodes WHERE id IN (?,?)",original.returns().get(0),original.returns().get(1))).isEqualByComparingTo("0.20001");
                assertThat(amount(db,"SELECT sum(owned_value_local) FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=? AND node.owner_kind='COGS'",original.world().goodsA())).isEqualByComparingTo("20.60003");
                assertThat(glFacts(db,original.world().goodsA())).containsAllEntriesOf(original.glFacts());
                inPrecision(Map.of("stock.value.interval",new BusinessPrecisionContext.Choice(0,"HALF_UP")),()->locked(after,original.world().goodsE(),()->values.reverseAdjustment(cursorContext(original,"inverse-two-old-cursors"),adjusted.eventId())));
                drainAll(fixture,original.world());
                assertReturnPrefixes(db,original.returns(),"0.0333","0.0667");
                assertThat(amount(db,"SELECT sum(basis_value_local) FROM stock_value_nodes WHERE id IN (?,?)",original.returns().get(0),original.returns().get(1))).isEqualByComparingTo("0.1");
                assertThat(amount(db,"SELECT sum(owned_value_local) FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=? AND node.owner_kind='COGS'",original.world().goodsA())).isEqualByComparingTo("20.3");
                assertThat(glFacts(db,original.world().goodsA())).containsAllEntriesOf(original.glFacts());
                assertThat(amount(db,"SELECT initial_known_value FROM stock_value_nodes WHERE id=?",original.source())).isEqualByComparingTo("1.0001");
                assertThat(BusinessPrecisionContext.choices()).isEmpty();
            }finally{SecurityContextHolder.clearContext();}
        }
    }
    private void assertReturnPrefixes(JdbcTemplate db,List<UUID> returns,String first,String second){
        assertThat(amount(db,"SELECT basis_value_local FROM stock_value_nodes WHERE id=?",returns.get(0))).isEqualByComparingTo(first);
        assertThat(amount(db,"SELECT basis_value_local FROM stock_value_nodes WHERE id=?",returns.get(1))).isEqualByComparingTo(second);
        assertThat(amount(db,"SELECT quantity_basis FROM stock_value_nodes WHERE id=?",returns.get(0))).isEqualByComparingTo("0.1");
        assertThat(amount(db,"SELECT quantity_basis FROM stock_value_nodes WHERE id=?",returns.get(1))).isEqualByComparingTo("0.2");
    }
    private void drainAll(FullChainEndToEndTest fixture,FullChainEndToEndTest.World world){
        org.springframework.test.util.ReflectionTestUtils.invokeMethod(fixture,"drainCostsWithFreshRunnerWithoutSession",world);
    }
    private InventoryValuationPort.EventContext cursorContext(CursorLegacy original,String action){UUID event=UUID.randomUUID();return new InventoryValuationPort.EventContext(event,"LEGACY_PARTIAL_CONSUMPTION_PROOF",original.incoming(),original.item(),1,original.world().superAdminUserId(),original.world().employeeId(),action+":"+event,OffsetDateTime.now());}
    private record CursorLegacy(FullChainEndToEndTest.World world,UUID incoming,UUID item,UUID source,List<UUID> returns,Map<String,String> glFacts,String materialFacts,String productFacts){}

    private ConfigurableApplicationContext start(PostgreSQLContainer postgres,Path logs,String target,String stage){
        if(!"latest".equals(target))throw new IllegalArgumentException("Current ORM requires the completed forward catalog");
        var args=new ArrayList<>(List.of("--spring.profiles.active=dev","--server.port=0",
                "--spring.datasource.url="+postgres.getJdbcUrl(),"--spring.datasource.username="+postgres.getUsername(),"--spring.datasource.password="+postgres.getPassword(),
                "--spring.flyway.url="+postgres.getJdbcUrl(),"--spring.flyway.user="+postgres.getUsername(),"--spring.flyway.password="+postgres.getPassword(),
                "--spring.flyway.validate-on-migrate=true","--spring.flyway.clean-disabled=true","--spring.flyway.baseline-on-migrate=false",
                "--uten.jwt.secret="+FullChainEndToEndTest.SHARED_JWT_SECRET,"--uten.crypto.pgp-master-key="+FullChainEndToEndTest.SHARED_PGP_KEY,
                "--uten.crypto.hmac-key="+FullChainEndToEndTest.SHARED_HMAC_KEY,"--uten.bootstrap.admin-login="+FullChainEndToEndTest.SHARED_ADMIN_LOGIN,
                "--uten.bootstrap.admin-password="+FullChainEndToEndTest.SHARED_ADMIN_PASSWORD,"--uten.audit.retention.enabled=false",
                "--uten.reporting.materialized-view-refresh.enabled=false","--uten.production.readiness-reconcile.enabled=false",
                "--uten.features.goods-owner-scope-enabled=false","--uten.storage.uploads-enabled=false","--uten.policy-intelligence.enabled=false",
                "--uten.inventory.value-work.enabled=false","--uten.storage.local-dir="+logs.resolve("storage"),"--logging.file.name="+logs.resolve(stage+".log")));
        return new SpringApplicationBuilder(UtenImpApplication.class).web(WebApplicationType.SERVLET).run(args.toArray(String[]::new));
    }
    private FullChainEndToEndTest fixture(ConfigurableApplicationContext context){var result=new FullChainEndToEndTest();context.getAutowireCapableBeanFactory().autowireBean(result);return result;}
    private InventoryValuationPort.AdjustmentValue adjust(ConfigurableApplicationContext context,InventoryValuationPort.SourceAdjustment command,UUID goods,Map<String,BusinessPrecisionContext.Choice> choices){return inPrecision(choices,()->locked(context,goods,()->context.getBean(InventoryValuationPort.class).adjustSource(command)));}
    private <T>T locked(ConfigurableApplicationContext context,UUID goods,Supplier<T> action){return new TransactionTemplate(context.getBean(PlatformTransactionManager.class)).execute(status->{context.getBean(TxSessionVars.class).bind();context.getBean(InventoryMutationLock.class).lock(new InventoryKey(goods,null));return action.get();});}
    private <T>T inPrecision(Map<String,BusinessPrecisionContext.Choice> choices,Supplier<T> action){try(var ignored=BusinessPrecisionContext.use(choices)){return action.get();}catch(RuntimeException|Error failure){throw failure;}catch(Exception failure){throw new IllegalStateException(failure);}}
    private void drain(ConfigurableApplicationContext context,UUID goods){var values=context.getBean(InventoryValuationPort.class);for(int batch=0;batch<200;batch++){var pending=values.pendingWork(100).stream().filter(task->task.lockKey().goodsId().equals(goods)).toList();if(pending.isEmpty())return;for(var task:pending)locked(context,goods,()->values.propagate(task.taskId()));}fail("Historical source durable work did not finish");}
    private InventoryValuationPort.EventContext context(Legacy original,String action){UUID event=UUID.randomUUID();return new InventoryValuationPort.EventContext(event,"LEGACY_COMPONENT_COST_PROOF",original.incoming(),original.sourceItem(),1,original.world().superAdminUserId(),original.world().employeeId(),action+":"+event,OffsetDateTime.now());}
    private String storedFacts(JdbcTemplate db,UUID goods){return db.queryForObject("""
            SELECT jsonb_build_object('nodes',(SELECT jsonb_agg(jsonb_build_object('id',n.id,'kind',n.kind,'initial',n.initial_known_value,
                'basis',n.basis_value_local,'owned',n.owned_value_local,'distributed',n.distributed_value_local,'qty',n.quantity_basis,
                'from',n.range_from,'to',n.range_to,'sourceInitial',n.source_initial_amount_exact,'source',n.source_amount_exact) ORDER BY n.id)
                FROM stock_value_nodes n JOIN stock_value_pools p ON p.id=n.pool_id WHERE p.goods_id=?),
                'edges',(SELECT jsonb_agg(jsonb_build_object('id',e.id,'parent',e.parent_node_id,'child',e.child_node_id,'initial',e.initial_allocated_amount,
                    'allocated',e.allocated_amount_local,'from',e.interval_from,'to',e.interval_to,'denominator',e.denominator) ORDER BY e.id)
                    FROM stock_value_edges e JOIN stock_value_nodes n ON n.id=e.parent_node_id JOIN stock_value_pools p ON p.id=n.pool_id WHERE p.goods_id=?))::text
            """,String.class,goods,goods);}
    private Map<String,Long> counts(JdbcTemplate db){var result=new TreeMap<String,Long>();for(String table:List.of("stock_value_nodes","stock_value_edges","stock_value_events","stock_value_node_revisions","stock_value_jobs","stock_value_tasks","stock_value_postings","stock_movements","inventory_cost_gl_links","gl_vouchers","gl_entries")){result.put(table,db.queryForObject("SELECT count(*) FROM "+table,Long.class));}return result;}
    private Map<String,String> glFacts(JdbcTemplate db,UUID goods){var result=new TreeMap<String,String>();db.query("SELECT link.posting_id::text id,(to_jsonb(link)||jsonb_build_object('voucher',to_jsonb(voucher),'entries',(SELECT jsonb_agg(to_jsonb(entry) ORDER BY line_no) FROM gl_entries entry WHERE entry.voucher_id=voucher.id)))::text fact FROM inventory_cost_gl_links link JOIN gl_vouchers voucher ON voucher.id=link.voucher_id JOIN stock_value_nodes node ON node.id=link.source_node_id JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=?",row->{result.put(row.getString("id"),row.getString("fact"));},goods);return result;}
    private BigDecimal glAmount(JdbcTemplate db,UUID goods){return amount(db,"SELECT coalesce(sum(link.amount_local),0) FROM inventory_cost_gl_links link JOIN stock_value_nodes node ON node.id=link.source_node_id JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id=?",goods);}
    private BigDecimal amount(JdbcTemplate db,String sql,Object...args){return db.queryForObject(sql,BigDecimal.class,args);}
    private void assertUnrelatedActualSourceUnchanged(JdbcTemplate db,Legacy original){
        assertThat(db.queryForObject("SELECT CAST(? AS jsonb)=CAST(? AS jsonb)",Boolean.class,original.unrelatedFacts(),storedFacts(db,original.world().goodsB()))).isTrue();
        assertThat(amount(db,"SELECT amount_local FROM stock_balances WHERE goods_id=? AND color_id=?",original.world().goodsB(),original.world().colorId())).isEqualByComparingTo("7.1234");
        assertThat(amount(db,"SELECT qty FROM stock_balances WHERE goods_id=? AND color_id=?",original.world().goodsB(),original.world().colorId())).isEqualByComparingTo("2");
    }
    private String period(){return YearMonth.from(BusinessTime.today()).toString();}
    private record Legacy(FullChainEndToEndTest.World world,UUID incoming,UUID sourceItem,UUID source,UUID shipmentItem,String bookFacts,Map<String,String> glFacts,String unrelatedFacts){UUID goods(){return world.goodsD();}}
}
