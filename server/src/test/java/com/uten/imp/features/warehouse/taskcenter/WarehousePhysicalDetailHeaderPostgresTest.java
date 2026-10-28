package com.uten.imp.features.warehouse.taskcenter;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.features.stock.StockDocAccessPolicy;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialScope;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.sql.Connection;
import java.util.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class WarehousePhysicalDetailHeaderPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private Connection connection;private NamedParameterJdbcTemplate jdbc;
    private final UUID actor=UUID.randomUUID(),warehouse=UUID.randomUUID(),outside=UUID.randomUUID();
    private WarehouseInboundTaskCenterQueryService inbound;private WarehouseOutboundTaskCenterQueryService outbound;
    @BeforeAll static void start()throws Exception{database=MigratedSchemaBaseline.openDatabase("warehouse_physical_headers");}
    @AfterAll static void stop()throws Exception{if(database!=null)database.close();}
    @BeforeEach void fixture()throws Exception {
        connection=database.openConnection();connection.setAutoCommit(false);
        try(var statement=connection.createStatement()) {
            statement.execute("CREATE SCHEMA physical_headers");statement.execute("SET LOCAL search_path=physical_headers,public");statement.execute("SET LOCAL jit=off");
        }
        MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection,"stock_documents","stock_document_items","warehouses","goods","colors","units",
                "purchase_receipts","purchase_receipt_items","subcontract_receipts","subcontract_receipt_items","production_daily_reports","production_daily_report_items",
                "production_finished_arrival_registrations","production_finished_arrival_registration_items","production_finished_arrival_registration_reversals",
                "production_fqc_inspections","production_fqc_inspection_sheets","production_fqc_inspection_sheet_items","production_finished_in_confirmations",
                "procurement_arrival_exceptions","inbound_expectations","inbound_expectation_items","production_fqc_legacy_exemptions","procurement_inspection_items",
                "procurement_inspection_events","procurement_iqc_stock_in_batch_items","procurement_iqc_stock_in_batches","procurement_iqc_rejection_cases","production_material_return_requests");
        try(var statement=connection.createStatement();var rows=statement.executeQuery("SELECT pg_get_viewdef('public.v_production_report_items_pending_registration'::regclass,true)")) {
            rows.next();String definition=rows.getString(1).replace("public.","");
            try(var create=connection.createStatement()){create.execute("CREATE VIEW v_production_report_items_pending_registration AS "+definition);}
        }
        jdbc=new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection,true));
        execute("INSERT INTO warehouses(id,name) VALUES(:id,'原料仓')","id",warehouse);
        var user=new AuthUser(UUID.randomUUID(),actor,"warehouse",Set.of("stock_doc:view"),false,true,false);
        var current=mock(SecurityContextCurrentUser.class);when(current.get()).thenReturn(Optional.of(user));when(current.employeeId()).thenReturn(Optional.of(actor));
        var scopes=mock(WarehouseTaskScopePort.class);when(scopes.current(any())).thenReturn(new WarehouseTaskScope(true,List.of(warehouse),false));
        doCallRealMethod().when(scopes).withQueryScopeCache(any());
        var stock=mock(StockDocAccessPolicy.class);var owners=new OwnerScope(false,Set.of(actor));when(stock.scope()).thenReturn(owners);
        when(stock.hasAuthority(anyString())).thenAnswer(call->call.getArgument(0).equals("stock_doc:view"));
        when(stock.nativeReadScope(anyString(),anyString(),any(OwnerScope.class))).thenAnswer(call->new NativeReadScope(
                call.getArgument(0)+" IN (:"+call.getArgument(1)+")",call.getArgument(1),Set.of(actor)));
        var production=mock(ProductionStockTaskAccessPolicy.class);var workshop=mock(WorkshopMaterialScope.class);
        inbound=new WarehouseInboundTaskCenterQueryService(jdbc,new ObjectMapper().findAndRegisterModules(),current,scopes,stock,production,workshop);
        var em=mock(EntityManager.class);when(em.createNativeQuery(anyString())).thenAnswer(call->query(call.getArgument(0)));
        outbound=new WarehouseOutboundTaskCenterQueryService(em,stock,current,scopes,production,mock(AuditDetailViewRecorder.class),workshop);
    }
    @AfterEach void rollback()throws Exception{if(connection!=null){connection.rollback();connection.close();}}

    @Test void inboundDetailQueriesUseOnlyTheOriginalVisiblePhysicalItemsBeforeCountPageAndExactMapping() {
        var document=document("OTHER_IN");String key="OTHER:STOCK_DOCUMENT:"+document;
        var columns=Map.of("goodsName","可见%_","quantity",">1.0000");
        var first=inbound.detail(key,warehouse,1,1,columns,"quantity","desc");
        var second=inbound.detail(key,warehouse,2,1,columns,"quantity","desc");
        assertThat(first.get("total")).isEqualTo(2L);assertThat(first.get("totalPages")).isEqualTo(2);
        var rows=(List<?>)first.get("items");var next=(List<?>)second.get("items");
        assertThat(((Map<?,?>)rows.getFirst()).get("quantityExact")).isEqualTo("2.0002");assertThat(((Map<?,?>)next.getFirst()).get("quantityExact")).isEqualTo("1.0001");
        assertThat(inbound.detail(key,warehouse,1,100,Map.of("goodsName","SECRET"),null,null).get("total")).isEqualTo(0L);
        assertThat(inbound.detail(key,warehouse,1,100,Map.of("giftQty","!=0"),null,null).get("total")).isEqualTo(0L);
        assertThat(((WarehouseTaskCenterContracts.Row)first.get("row")).id()).isEqualTo(document);
    }
    @Test void outboundDetailQueriesKeepTheSameWarehouseAndIdentityBoundaryAndNeverInferMissingMeasures() {
        var document=document("OTHER_OUT");String key="OTHER:STOCK_DOC:"+document;
        var columns=Map.of("goodsName","可见%_","quantity",">1.0000");
        var first=outbound.detail(key,warehouse,1,1,columns,"quantity","desc");
        var second=outbound.detail(key,warehouse,2,1,columns,"quantity","desc");
        assertThat(first.total()).isEqualTo(2);assertThat(first.totalPages()).isEqualTo(2);
        assertThat(first.lines().getFirst().getQuantityExact()).isEqualTo("2.0002");
        assertThat(second.lines().getFirst().getQuantityExact()).isEqualTo("1.0001");
        assertThat(outbound.detail(key,warehouse,1,100,Map.of("goodsName","SECRET"),null,null).total()).isZero();
        assertThat(outbound.detail(key,warehouse,1,100,Map.of("requestedQuantity","!=0"),null,null).total()).isZero();
        assertThat(first.document().id()).isEqualTo(document);
    }
    private UUID document(String type) {
        UUID id=UUID.randomUUID();execute("INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,status,issue_status,is_closed,is_deleted,maker_id,warehouse_id,created_at)"
                +" VALUES(:id,:type,'PHYSICAL','2026-10-28',0,0,FALSE,FALSE,:actor,:warehouse,now())","id",id,"type",type,"actor",actor,"warehouse",warehouse);
        for(int index=1;index<=3;index++) execute("INSERT INTO stock_document_items(id,doc_id,line_no,goods_name_snapshot,goods_code_snapshot,qty,weight,warehouse_id,is_deleted)"
                +" VALUES(:id,:document,:line,:name,'G',CAST(:qty AS numeric),0.1,:warehouse,FALSE)","id",UUID.randomUUID(),"document",id,"line",index,
                "name",index==3?"SECRET":"可见%_"+index,"qty",index==1?"1.0001":index==2?"2.0002":"99","warehouse",index==3?outside:warehouse);
        return id;
    }
    private Query query(String sql) {
        Map<String,Object> values=new LinkedHashMap<>();return mock(Query.class,call->{
            String method=call.getMethod().getName();
            if(method.equals("setParameter")){values.put(call.getArgument(0),call.getArgument(1));return call.getMock();}
            if(method.equals("getSingleResult"))return jdbc.queryForObject(sql,values,Object.class);
            if(method.equals("getResultList"))return jdbc.query(sql,values,(rs,index)->{Object[] row=new Object[rs.getMetaData().getColumnCount()];for(int col=0;col<row.length;col++) { row[col]=rs.getObject(col+1); } return row;});
            if(Query.class.isAssignableFrom(call.getMethod().getReturnType()))return call.getMock();return org.mockito.Answers.RETURNS_DEFAULTS.answer(call);
        });
    }
    private void execute(String sql, Object... values) {
        var parameters = new MapSqlParameterSource(com.uten.imp.support.KeyValueTestData.map(values));
        jdbc.update(sql, parameters);
    }
}
