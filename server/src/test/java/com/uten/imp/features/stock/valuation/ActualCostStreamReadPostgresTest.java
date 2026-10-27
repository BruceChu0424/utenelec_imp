package com.uten.imp.features.stock.valuation;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.GoodsActualCostQueryPort.*;
import com.uten.imp.common.export.*;
import com.uten.imp.features.master.goods.costing.*;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.*;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.time.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicBoolean;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Real migrated column types and RR/cursor SQL; private projection fixtures do
 * not claim to validate valuation command CHECK/FK/append-only mutations. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ActualCostStreamReadPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase lease;
    private static DriverManagerDataSource source;
    private static EntityManagerFactory factory;
    private static NamedParameterJdbcTemplate db;
    private static TransactionTemplate read;
    private static final String SCHEMA="actual_stream_fixture";
    private static final List<String> TABLES=List.of("stock_value_production_cost_objects","stock_value_pools",
            "stock_value_production_cost_revisions","production_execution_segments","stock_value_production_cost_tasks",
            "stock_value_production_cost_dirty","stock_value_jobs","stock_value_production_cost_inputs","stock_value_nodes",
            "stock_value_events","stock_value_node_revisions","stock_value_production_cost_outputs","stock_movements");
    private static final UUID GOODS=UUID.randomUUID(),COMPONENT=UUID.randomUUID(),OBJECT=UUID.randomUUID(),REVISION=UUID.randomUUID(),
            PRODUCT_POOL=UUID.randomUUID(),INPUT_POOL=UUID.randomUUID(),UNIT=UUID.randomUUID();
    private static final OffsetDateTime AT=OffsetDateTime.parse("2026-10-26T00:00:00Z");
    private final ObjectMapper json=new ObjectMapper().findAndRegisterModules();
    private GoodsActualCostQueryService facts;
    private GoodsActualCostSnapshotService snapshots;

    @BeforeAll static void baseline() throws Exception {
        lease=MigratedSchemaBaseline.openDatabase("actual_cost_stream");
        var catalogSource = new DriverManagerDataSource(lease.getJdbcUrl(),lease.getUsername(),lease.getPassword());
        var admin=new NamedParameterJdbcTemplate(catalogSource);
        admin.getJdbcTemplate().execute("CREATE SCHEMA "+SCHEMA);
        try (var connection = catalogSource.getConnection()) {
            connection.setSchema(SCHEMA);
            com.uten.imp.support.MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection, TABLES.toArray(String[]::new));
        }
        String url=lease.getJdbcUrl()+(lease.getJdbcUrl().contains("?")?"&":"?")+"currentSchema="+SCHEMA+",public";
        source=new DriverManagerDataSource(url,lease.getUsername(),lease.getPassword());db=new NamedParameterJdbcTemplate(source);
        var bean=new LocalContainerEntityManagerFactoryBean();bean.setDataSource(source);bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp.security");bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none"));bean.afterPropertiesSet();
        factory=bean.getObject();read=new TransactionTemplate(new JpaTransactionManager(factory));
        read.setReadOnly(true);read.setIsolationLevel(java.sql.Connection.TRANSACTION_REPEATABLE_READ);
    }
    @AfterAll static void close() throws Exception {
        if (factory != null) {
            factory.close();
        }
        if (lease != null) {
            lease.close();
        }
    }
    @BeforeEach void seed() throws Exception {
        for(String table:TABLES)db.getJdbcTemplate().execute("TRUNCATE "+SCHEMA+"."+table);
        row("stock_value_pools",Map.of("id",PRODUCT_POOL,"goods_id",GOODS));row("stock_value_pools",Map.of("id",INPUT_POOL,"goods_id",COMPONENT));
        row("production_execution_segments",Map.of("id",OBJECT));
        UUID input=UUID.randomUUID(),event=UUID.randomUUID(),output=UUID.randomUUID(),movement=UUID.randomUUID();
        input(input,event,AT);
        row("stock_value_nodes",Map.of("id",output,"pool_id",PRODUCT_POOL));
        row("stock_movements",Map.of("id",movement,"transaction_date",AT,"source_doc_type","PRODUCTION_REPORT"));
        row("stock_value_production_cost_outputs",Map.of("execution_segment_id",OBJECT,"source_node_id",output,"movement_id",movement,"qty_base",new BigDecimal("2.500000000000001"),"created_at",AT));
        var frozen=new ArrayList<Map<String,Object>>();frozen.add(frozenInput(input,"12.500000000000000001"));
        // Duplicate node evidence keeps the first array ordinal, as legacy LIMIT 1 did.
        frozen.add(frozenInput(input,"999"));
        revision(REVISION,1,frozen,List.of(Map.of("source",output,"qty","2.500000000000001")));
        row("stock_value_production_cost_objects",Map.of("execution_segment_id",OBJECT,"product_pool_id",PRODUCT_POOL,
                "source_kind","PRODUCTION_EXECUTION","version",1,"state","FINAL","current_revision_id",REVISION,"created_at",AT));
        facts=new GoodsActualCostQueryService(db);
        snapshots=new GoodsActualCostSnapshotService(facts,mock(GoodsCostSheetService.class),new GoodsCostJson(json),json);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("synthetic",null,
                List.of(new SimpleGrantedAuthority("goods:cost:view"),new SimpleGrantedAuthority("goods:cost:export"))));
    }
    @AfterEach void actor(){SecurityContextHolder.clearContext();}
    private Query query(){return new Query(GOODS,null,null,null,null);}

    @Test void streamMatchesLegacyExactHashAndEveryOriginalSheetOnActualPostgres() {
        read.executeWithoutResult(tx->{
            var old=snapshots.read(query());
            assertThat(old.snapshot().inputs().getFirst().knownAmountLocal()).isEqualByComparingTo("12.500000000000000001");
            var expected=GoodsActualCostDocumentMapper.map(old.snapshot(),old.digest());
            Map<String,List<Map<String,Object>>> rows=new LinkedHashMap<>();
            try(var sink=DocumentPageSink.open(new DocumentPageSink.Consumer(){
                @Override
                public void begin(DocumentPageSink.Header header){assertThat(header.expectedPrimaryRows()).isEqualTo(1);}
                @Override
                public void accept(DocumentPageSink.Page page){assertThat(page.rows()).hasSizeLessThanOrEqualTo(100);rows.computeIfAbsent(page.sectionId(),key->new ArrayList<>()).addAll(page.rows());}
            })) {snapshots.streamExport(query(),old.digest(),ExportDocument.MAX_SECTION_ROWS);}
            for(int index=0;index<expected.sections().size();index++)assertThat(rows.get("actual-"+index)).isEqualTo(expected.sections().get(index).rows());
        });
    }

    @Test void aLateCommittedNewRevisionCannotEnterTheAlreadyHashedFileButAppearsOnRefresh() {
        String initial=read.execute(tx->snapshots.read(query()).digest());
        var committed=new AtomicBoolean();var count=new java.util.concurrent.atomic.AtomicInteger();
        read.executeWithoutResult(tx->{
            try(var sink=DocumentPageSink.open(new DocumentPageSink.Consumer(){
                @Override
                public void begin(DocumentPageSink.Header header){
                    UUID node=UUID.randomUUID();input(node,UUID.randomUUID(),AT.plusSeconds(1));
                    UUID next=UUID.randomUUID();
                    var first=db.queryForObject("SELECT input_snapshot::text FROM stock_value_production_cost_revisions WHERE id=:id",Map.of("id",REVISION),String.class);
                    try {
                        var entries=json.readValue(first,new com.fasterxml.jackson.core.type.TypeReference<List<Map<String,Object>>>(){});
                        entries.add(frozenInput(node,"7"));revision(next,2,entries,List.of());
                    }catch(Exception error){throw new RuntimeException(error);}
                    var other=new NamedParameterJdbcTemplate(new DriverManagerDataSource(source.getUrl(),lease.getUsername(),lease.getPassword()));
                    other.update("UPDATE stock_value_production_cost_objects SET current_revision_id=:next WHERE execution_segment_id=:id",Map.of("next",next,"id",OBJECT));
                    committed.set(true);
                }
                @Override
                public void accept(DocumentPageSink.Page page){if(page.sectionId().equals("actual-1"))count.addAndGet(page.rows().size());}
            })) {snapshots.streamExport(query(),initial,ExportDocument.MAX_SECTION_ROWS);}
        });
        assertThat(committed).isTrue();assertThat(count).hasValue(1);
        String refreshed=read.execute(tx->snapshots.read(query()).digest());
        assertThat(refreshed).isNotEqualTo(initial);
    }

    @Test void aCursorHandleCannotEscapeItsTransactionSnapshot() {
        StreamingRead handle=read.execute(tx->facts.openStream(query(),ExportDocument.MAX_SECTION_ROWS,rows->{}));
        assertThatThrownBy(()->handle.inputs(row->{})).isInstanceOf(IllegalStateException.class);handle.close();
    }

    @Test void smallLegacyRouteRejectsAll501FactsBeforeReadingOrHashingTheirPayloads() {
        db.update("INSERT INTO stock_value_events(id,source_doc_type,occurred_at) SELECT gen_random_uuid(),'B1_OVER_LIMIT',:at FROM generate_series(1,500)",Map.of("at",AT));
        db.update("INSERT INTO stock_value_nodes(id,pool_id,creation_event_id) SELECT id,:pool,id FROM stock_value_events WHERE source_doc_type='B1_OVER_LIMIT'",Map.of("pool",INPUT_POOL));
        db.update("INSERT INTO stock_value_production_cost_inputs(execution_segment_id,input_node_id,input_kind,created_at) SELECT :object,id,'DIRECT_CONSUMPTION',:at FROM stock_value_events WHERE source_doc_type='B1_OVER_LIMIT'",Map.of("object",OBJECT,"at",AT));
        db.update("UPDATE stock_value_production_cost_revisions SET input_snapshot=(SELECT jsonb_agg(jsonb_build_object('node',input_node_id,'revision',1)) FROM stock_value_production_cost_inputs) WHERE id=:revision",Map.of("revision",REVISION));
        var batches=new java.util.concurrent.atomic.AtomicInteger();
        assertThatThrownBy(()->read.executeWithoutResult(tx->{
            try(var source=facts.openStream(query(),LegacyExportBudget.MAX_ROWS,rows->batches.incrementAndGet())) {
                throw new AssertionError("over-limit source must not open");
            }
        })).isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("后台导出任务");
        assertThat(batches).hasValue(0);
        assertThat(db.queryForObject("SELECT count(*) FROM stock_value_production_cost_inputs",Map.of(),Long.class)).isEqualTo(501L);
        // The source fact count can fit while independently preserved gaps do
        // not. Both small-route failures must explicitly direct to the task.
        db.update("DELETE FROM stock_value_production_cost_inputs WHERE input_node_id IN (SELECT id FROM stock_value_events WHERE source_doc_type='B1_OVER_LIMIT' ORDER BY id LIMIT 250)",Map.of());
        db.update("UPDATE stock_value_production_cost_revisions SET input_snapshot=(SELECT jsonb_agg(jsonb_build_object('node',input_node_id,'revision',1,'identity','{}'::jsonb)) FROM stock_value_production_cost_inputs) WHERE id=:revision",Map.of("revision",REVISION));
        assertThat(db.queryForObject("SELECT count(*) FROM stock_value_production_cost_inputs",Map.of(),Long.class)).isEqualTo(251L);
        assertThatThrownBy(()->read.executeWithoutResult(tx->{
            try(var source=facts.openStream(query(),LegacyExportBudget.MAX_ROWS,rows->{})) {throw new AssertionError("over-limit gaps must not open");}
        })).isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("后台导出任务").hasMessageNotContaining("50000");
    }

    private void input(UUID node,UUID event,OffsetDateTime at) {
        row("stock_value_events",Map.of("id",event,"source_doc_type","MATERIAL_ISSUE","occurred_at",at));
        row("stock_value_nodes",Map.of("id",node,"pool_id",INPUT_POOL,"creation_event_id",event,"value_model","EXACT_SOURCE_SHARES",
                "initial_bound_lower",new BigDecimal("12.5"),"initial_bound_upper",new BigDecimal("12.5")));
        row("stock_value_production_cost_inputs",Map.of("execution_segment_id",OBJECT,"input_node_id",node,"input_kind","DIRECT_CONSUMPTION","created_at",at));
    }
    private Map<String,Object> frozenInput(UUID node,String value){return Map.of("node",node,"revision",1,"quantityBasis","2.5","returnedQty","0","value",value,"pending",0,
            "valueModel","EXACT_SOURCE_SHARES","exactLower",value,"exactUpper",value,
            "identity",Map.of("state","COMPLETE","goodsId",COMPONENT,"goodsCode","0001","goodsName","原始龘","unitId",UNIT,"unitName","PCS"));}
    private void revision(UUID id,int version,List<Map<String,Object>> inputs,List<Map<String,Object>> outputs) throws Exception {
        var other=new NamedParameterJdbcTemplate(new DriverManagerDataSource(source.getUrl(),lease.getUsername(),lease.getPassword()));
        other.update("INSERT INTO stock_value_production_cost_revisions(id,execution_segment_id,version,target_qty_base,output_qty_base,scope_complete,input_snapshot,output_snapshot,occurred_at) VALUES(:id,:scope,:version,100,10,true,CAST(:inputs AS jsonb),CAST(:outputs AS jsonb),:at)",
                Map.of("id",id,"scope",OBJECT,"version",version,"inputs",json.writeValueAsString(inputs),"outputs",json.writeValueAsString(outputs),"at",AT));
    }
    private void row(String table,Map<String,?> values) {
        // A separate connection also makes late-commit writes independent of the reader's RR resource.
        var other=new NamedParameterJdbcTemplate(new DriverManagerDataSource(source.getUrl(),lease.getUsername(),lease.getPassword()));
        other.update("INSERT INTO "+SCHEMA+"."+table+"("+String.join(",",values.keySet())+") VALUES("+
                String.join(",",values.keySet().stream().map(key->":"+key).toList())+")",values);
    }
}
