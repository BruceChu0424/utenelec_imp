package com.uten.imp.features.warehouse.finishedin;

import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
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
class ProductionFinishedInboundHeaderPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private Connection connection;private NamedParameterJdbcTemplate jdbc;
    private EntityManager em;private ProductionStockTaskAccessPolicy access;private ProductionFinishedInboundTaskService service;
    @BeforeAll static void start()throws Exception {database=MigratedSchemaBaseline.openDatabase("finished_inbound_headers");}
    @AfterAll static void stop()throws Exception {if(database!=null)database.close();}
    @BeforeEach void fixture()throws Exception {
        connection=database.openConnection();connection.setAutoCommit(false);
        try(var statement=connection.createStatement()){
            statement.execute("CREATE SCHEMA finished_headers");statement.execute("SET LOCAL search_path=finished_headers,public");statement.execute("SET LOCAL jit=off");
        }
        MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection,"stock_documents","stock_document_items","production_daily_reports",
                "production_daily_report_items","production_plan_items","production_plans","production_finished_in_confirmations","goods","colors","units","warehouses",
                "production_finished_arrival_registration_items","production_finished_arrival_registrations","production_finished_arrival_registration_reversals",
                "production_fqc_inspections","production_fqc_inspection_sheet_items","production_fqc_inspection_sheets","production_fqc_legacy_exemptions");
        try(var statement=connection.createStatement();var rows=statement.executeQuery("SELECT pg_get_viewdef('public.v_production_report_items_pending_registration'::regclass,true)")) {
            rows.next();String definition=rows.getString(1).replace("public.","");
            try(var create=connection.createStatement()){create.execute("CREATE VIEW v_production_report_items_pending_registration AS "+definition);}
        }
        jdbc=new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection,true));
        em=mock(EntityManager.class);when(em.createNativeQuery(anyString())).thenAnswer(call->query(call.getArgument(0)));
        access=mock(ProductionStockTaskAccessPolicy.class);when(access.canAccessWarehouseTasks()).thenReturn(true);
        service=new ProductionFinishedInboundTaskService(em,access);
    }
    @AfterEach void rollback()throws Exception {if(connection!=null){connection.rollback();connection.close();}}

    @Test void headersKeepUnitGroupsChineseDatesAndTheExactCopiedQuantityCellBeforeCountAndPage() {
        UUID warehouse=UUID.randomUUID(),outside=UUID.randomUUID(),pieces=UUID.randomUUID(),metres=UUID.randomUUID();
        execute("INSERT INTO units(id,name) VALUES(:id,'件')","id",pieces);execute("INSERT INTO units(id,name) VALUES(:id,'米')","id",metres);
        execute("INSERT INTO warehouses(id,name) VALUES(:id,'成品仓')","id",warehouse);
        UUID wanted=document(warehouse,pieces,metres,"FIN%_MATCH","2026-10-27T16:00:00Z",true);
        document(warehouse,pieces,metres,"FIN%_NEXT","2026-10-28T16:00:00Z",true);
        document(outside,pieces,metres,"FIN%_HIDDEN","2026-10-27T16:00:00Z",true);
        UUID unknown=document(warehouse,null,null,"FIN-UNKNOWN",null,false);
        var scope=new WarehouseTaskScope(true,List.of(warehouse),false);
        var columns=Map.of("taskNo","FIN%_MATCH","lineCount",">=1.5","documentDate","2026-10-01..2026-10-28",
                "createdAt","2026-10-28","pendingQty","2 件 · 3 米 (其中实际超产 3 米)");
        var page=service.list("",null,null,1,1,scope,"documentDate","asc",null,null,columns);
        assertThat(page.getTotal()).isEqualTo(1);
        assertThat(page.getItems()).singleElement().satisfies(task->{
            assertThat(task.taskId()).isEqualTo(wanted);assertThat(task.pendingQty()).isEqualByComparingTo("5");
            assertThat(task.pendingQtyText()).isEqualTo("2 件 · 3 米");assertThat(task.actualSurplusNote()).isEqualTo("其中实际超产 3 米");
        });
        assertThat(service.list("",null,null,1,20,scope,null,null,null,null,Map.of("taskNo","FIN%_MATCH","pendingQty","5")).getTotal()).isZero();
        var missing=service.list("",null,null,1,20,scope,null,null,null,null,Map.of("pendingQty","待核验"));
        assertThat(missing.getItems()).extracting(ProductionFinishedInboundTask::taskId).containsExactly(unknown);
        assertThat(missing.getItems().getFirst().pendingQtyText()).isEqualTo("待核验");
        assertThat(service.facets("",null,null,scope,null,null,columns).get("taskNo")).hasSize(1);
        clearInvocations(em);when(access.canAccessWarehouseTasks()).thenReturn(false);
        assertThat(service.list("",null,null,1,20,scope,null,null,null,null,Map.of("lineCount","NaN")).getTotal()).isZero();verifyNoInteractions(em);
    }

    private UUID document(UUID warehouse,UUID pieces,UUID metres,String bill,String enteredAt,boolean known) {
        UUID id=UUID.randomUUID(),report=UUID.randomUUID();
        execute("INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,status,is_closed,is_deleted,warehouse_id,created_at)"
                +" VALUES(:id,'FINISHED_IN',:bill,'2026-10-28',0,FALSE,FALSE,:warehouse,CAST(:created AS timestamptz))",
                "id",id,"bill",bill,"warehouse",warehouse,"created",enteredAt);
        execute("INSERT INTO production_daily_reports(id,bill_no,bill_date,status,is_deleted) VALUES(:id,'REPORT%_','2026-10-28',1,FALSE)","id",report);
        for(int index=0;index<(known?2:1);index++) {
            UUID source=UUID.randomUUID();int qty=known?(index==0?2:3):9;
            execute("INSERT INTO production_daily_report_items(id,report_id,output_lot_id,qty,is_actual_surplus,is_public_output,is_deleted)"
                    +" VALUES(:id,:report,:lot,:qty,:surplus,FALSE,FALSE)","id",source,"report",report,"lot",UUID.randomUUID(),"qty",qty,"surplus",index==1);
            execute("INSERT INTO stock_document_items(id,doc_id,line_no,source_daily_report_item_id,goods_name_snapshot,qty,unit_id,is_deleted)"
                    +" VALUES(:id,:document,:line,:source,'成品',:qty,:unit,FALSE)","id",UUID.randomUUID(),"document",id,"line",index+1,"source",source,"qty",qty,"unit",index==0?pieces:metres);
        }
        return id;
    }
    private Query query(String sql) {
        Map<String,Object> parameters=new LinkedHashMap<>();
        return mock(Query.class,call->{
            String method=call.getMethod().getName();
            if(method.equals("setParameter")){parameters.put(call.getArgument(0),call.getArgument(1));return call.getMock();}
            if(method.equals("getSingleResult"))return jdbc.queryForObject(sql,parameters,Object.class);
            if(method.equals("getResultList"))return jdbc.query(sql,parameters,(rs,index)->{
                Object[] row=new Object[rs.getMetaData().getColumnCount()];for(int col=0;col<row.length;col++)row[col]=rs.getObject(col+1);return row;
            });
            if(Query.class.isAssignableFrom(call.getMethod().getReturnType()))return call.getMock();
            return org.mockito.Answers.RETURNS_DEFAULTS.answer(call);
        });
    }
    private void execute(String sql,Object...values) {
        var parameters=new MapSqlParameterSource();for(int index=0;index<values.length;index+=2)parameters.addValue((String)values[index],values[index+1]);jdbc.update(sql,parameters);
    }
}
