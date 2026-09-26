package com.uten.imp.features.production.analysis;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.*;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Real migrated functions in isolated projection schemas. The companion
 * aggregate order E2E suite exercises authorized writes and actual inventory. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class AggregateMaterialSourceCoveragePostgresTest {
    static final PostgreSQLContainer<?> DATABASE=new PostgreSQLContainer<>("postgres:16-alpine");
    Connection db;
    String schema;
    UUID analysis,unit,warehouse,component,parentGoods,anchor,batch,action,canonical,edge;
    record Source(UUID root,UUID parent,UUID material,UUID child,UUID plan,UUID planItem,UUID alias,UUID allocation) { }
    final List<Source> sources=new ArrayList<>();

    @BeforeAll static void migrate(){
        DATABASE.start();
        var migration=Flyway.configure().dataSource(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword())
                .locations("classpath:db/migration").target("713").load();
        migration.migrate();migration.validate();assertEquals(0,migration.migrate().migrationsExecuted);
    }
    @AfterAll static void stop(){DATABASE.stop();}
    @AfterEach void close()throws Exception{db.close();}
    @BeforeEach void fixture()throws Exception {
        db=DriverManager.getConnection(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword());
        schema="aggregate_scope_"+UUID.randomUUID().toString().replace("-","");
        sql("CREATE SCHEMA "+schema);sql("SET search_path TO "+schema+",public");
        for(String table:List.of("production_material_analyses","production_material_analysis_items","production_material_analysis_materials",
                "production_material_analysis_plan_links","production_plans","production_plan_items","production_execution_segments",
                "preplan_supply_actions","preplan_supply_action_allocations","preplan_aggregate_batches","preplan_aggregate_batch_events",
                "preplan_aggregate_material_aliases","preplan_make_entitlement_delegations","preplan_stock_entitlement_events",
                "preplan_analysis_stock_exact_pegs","stock_reservations","stock_documents","stock_document_items",
                "production_daily_reports","production_daily_report_items","preplan_root_output_events",
                "preplan_future_supply_transfers","preplan_future_supply_transfer_cancellations","preplan_reallocation_make_supplements",
                "v_preplan_stock_entitlement_beneficiary_balance","v_preplan_buy_action_slice_progress")) {
            com.uten.imp.support.MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(db,table);
            try(var statement=db.prepareStatement("""
                    SELECT attribute.attname,pg_get_expr(definition.adbin,definition.adrelid)
                    FROM pg_attribute attribute JOIN pg_attrdef definition ON definition.adrelid=attribute.attrelid AND definition.adnum=attribute.attnum
                    WHERE attribute.attrelid=CAST(? AS regclass)
                    """)) {
                statement.setString(1,"public."+table);
                try(var rows=statement.executeQuery()) {while(rows.next()) {
                    String value=rows.getString(2);
                    if(!value.contains("(")||List.of("now()","gen_random_uuid()","txid_current()").contains(value))
                        sql("ALTER TABLE "+table+" ALTER COLUMN \""+rows.getString(1)+"\" SET DEFAULT "+value);
                }}
            }
        }
        try(var statement=db.createStatement();var rows=statement.executeQuery("""
                SELECT pg_get_functiondef(procedure.oid) FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
                WHERE namespace.nspname='public' AND (procedure.proname LIKE 'fn_preplan_aggregate_%' OR procedure.proname LIKE 'fn_aggregate_%'
                  OR procedure.proname IN('fn_guard_aggregate_alias','fn_guard_aggregate_source_cancellation','fn_analysis_plan_material_matches',
                  'fn_finished_in_is_public_output','fn_daily_report_is_public_output','fn_preplan_allocation_received_qty','fn_preplan_action_received_qty',
                  'fn_preplan_allocation_effective_exact_qty','fn_preplan_allocation_admitted_qty','fn_preplan_action_admitted_qty',
                  'fn_preplan_action_has_future_transfer','fn_preplan_action_has_shared_claim_history','fn_preplan_direct_make_admitted_qty'))
                ORDER BY procedure.proname
                """)) {while(rows.next())sql(rows.getString(1).replace("FUNCTION public.","FUNCTION "+schema+"."));}
        analysis=UUID.randomUUID();unit=UUID.randomUUID();warehouse=UUID.randomUUID();component=UUID.randomUUID();parentGoods=UUID.randomUUID();
        anchor=UUID.randomUUID();batch=UUID.randomUUID();action=UUID.randomUUID();canonical=UUID.randomUUID();edge=UUID.randomUUID();
        sql("INSERT INTO production_material_analyses(id,status,warehouse_id,is_deleted) VALUES(?,'PARTIALLY_PLANNED',?,false)",analysis,warehouse);
        sql("INSERT INTO production_material_analysis_items(id,analysis_id,source_type,goods_id,unit_id,requested_qty,approved_qty,is_deleted) VALUES(?,?,'AGGREGATE_MAKE',?,?,3000,3000,false)",anchor,analysis,parentGoods,unit);
        sql("INSERT INTO preplan_supply_actions(id,analysis_id,route,operation_type,status,external_document_type,external_document_id,requested_qty,goods_id,unit_id) VALUES(?,?,'MAKE','SUPPLY','CREATED','PREPLAN_MAKE_TASK',?,3000,?,?)",action,analysis,anchor,parentGoods,unit);
        UUID sharedPlan=UUID.randomUUID();
        sql("INSERT INTO production_plans(id,material_analysis_id,material_analysis_item_id,status,is_deleted,is_canceled,is_closed) VALUES(?,?,?,1,false,false,false)",sharedPlan,analysis,anchor);
        sql("INSERT INTO production_material_analysis_plan_links(analysis_id,analysis_item_id,plan_id,submitted_qty,public_surplus_qty,allocation_status) VALUES(?,?,?,3000,0,'APPROVED')",analysis,anchor,sharedPlan);
        sql("INSERT INTO preplan_aggregate_batches(id,analysis_id,action_id,anchor_analysis_item_id,plan_id,route,row_version) VALUES(?,?,?,?,?,'MAKE',0)",batch,analysis,action,anchor,sharedPlan);
        material(canonical,anchor,edge.toString(),null,edge,component,"0");
    }

    @Test void threeExistingChildPlansCoverOneCanonicalWithoutRepeatingItsBom()throws Exception {
        for(int i=0;i<3;i++)sources.add(source("1000","0","1000","1000","3000"));
        amount("3000",value("SELECT inherited_pending_qty FROM fn_preplan_aggregate_alias_coverage(?)",analysis));
        amount("3000",value("SELECT inherited_arranged_qty FROM fn_preplan_aggregate_alias_coverage(?)",analysis));
        assertEquals("3",value("SELECT jsonb_array_length(source_aliases) FROM fn_preplan_aggregate_alias_coverage(?)",analysis));
        for(Source source:sources)amount("1000",value("SELECT fn_preplan_direct_make_admitted_qty(?,?)",source.child,source.material));
    }

    @Test void partialParentDelegationRetainsTheOriginalFiveHundredPromise()throws Exception {
        Source source=source("1500","500","1000","500","1000");
        amount("500",value("SELECT fn_preplan_aggregate_source_retained_qty(?)",source.material));
        amount("500",value("SELECT fn_preplan_aggregate_material_pending_qty(?)",source.material));
        amount("0",value("SELECT inherited_pending_qty FROM fn_preplan_aggregate_alias_coverage(?)",analysis));
    }

    @Test void fullParentDelegationCanInheritThatSameFiveHundredPromise()throws Exception {
        Source source=source("1500","0","1500","500","1500");
        amount("0",value("SELECT fn_preplan_aggregate_source_retained_qty(?)",source.material));
        amount("500",value("SELECT inherited_pending_qty FROM fn_preplan_aggregate_alias_coverage(?)",analysis));
    }

    @Test void partialDelegationDoesNotTakeOriginalPhysicalStockButCanTakeOnlyItsExcess()throws Exception {
        Source source=source("1500","500","1000","1000","1000");
        receipt(source,"700",false);
        balance(source.material,"700");
        amount("200",value("SELECT fn_preplan_aggregate_source_delegate_available_qty(?)",source.material));
        amount("300",value("SELECT inherited_pending_qty FROM fn_preplan_aggregate_alias_coverage(?)",analysis));
        sql("UPDATE v_preplan_stock_entitlement_beneficiary_balance SET effective_qty=500 WHERE beneficiary_analysis_material_id=?",source.material);
        balance(canonical,"200");delegated(source,"200");
        amount("0",value("SELECT fn_preplan_aggregate_source_delegate_available_qty(?)",source.material));
        amount("500",value("SELECT inherited_arranged_qty FROM fn_preplan_aggregate_alias_coverage(?)",analysis));
    }

    @Test void oneSharedPurchaseActionIsSlicedByAllocationAfterPartialReceipt()throws Exception {
        sql("UPDATE preplan_supply_actions SET route='BUY',external_document_type='PURCHASE_REQUEST',requested_qty=3300,public_surplus_qty=300 WHERE id=?",action);
        sql("INSERT INTO v_preplan_buy_action_slice_progress(action_id,demand_requested_qty,demand_qualified_qty,demand_future_qty,demand_source_valid) VALUES(?,3000,600,2400,true)",action);
        for(int i=0;i<3;i++)sources.add(source("1000","0","1000","1000","3000"));
        // First allocation in the established FIFO order received 600.
        UUID first=UUID.fromString(value("SELECT id FROM preplan_supply_action_allocations WHERE action_id=? ORDER BY created_at,id LIMIT 1",action));
        UUID reservation=UUID.randomUUID();
        sql("INSERT INTO stock_reservations(id,qty,consumed_qty,released_qty,status,is_deleted) VALUES(?,600,0,0,0,false)",reservation);
        sql("INSERT INTO preplan_analysis_stock_exact_pegs(stock_reservation_id,supply_action_allocation_id,qty) VALUES(?,?,600)",reservation,first);
        amount("600",value("SELECT fn_preplan_action_received_qty(?)",action));
        amount("2400",value("SELECT SUM(fn_preplan_aggregate_allocation_pending_qty(id)) FROM preplan_supply_action_allocations WHERE action_id=?",action));
        amount("400",value("SELECT fn_preplan_aggregate_allocation_pending_qty(?)",first));
    }

    @Test void partialReceiptReducesOnlyItsExactSourceAndReversalRestoresCoverage()throws Exception {
        for(int i=0;i<3;i++)sources.add(source("1000","0","1000","1000","3000"));
        Source source=sources.getFirst();UUID receipt=receipt(source,"600",false);UUID delegation=delegated(source,"600");
        amount("2400",value("SELECT inherited_pending_qty FROM fn_preplan_aggregate_alias_coverage(?)",analysis));
        amount("600",value("SELECT inherited_received_qty FROM fn_preplan_aggregate_alias_coverage(?)",analysis));
        sql("UPDATE stock_documents SET status=-1 WHERE id=?",receipt);
        UUID incoming=UUID.randomUUID();
        sql("INSERT INTO preplan_stock_entitlement_events(id,event_group_id,event_type,qty) VALUES(?,?,'MAKE_DELEGATE_IN',600)",incoming,delegation);
        sql("INSERT INTO preplan_stock_entitlement_events(event_type,source_entitlement_event_id,qty) VALUES('RELEASE',?,600)",incoming);
        amount("3000",value("SELECT inherited_pending_qty FROM fn_preplan_aggregate_alias_coverage(?)",analysis));
        amount("0",value("SELECT inherited_received_qty FROM fn_preplan_aggregate_alias_coverage(?)",analysis));
    }

    @Test void publicOutputCannotDischargeTheOriginalPrivateParentPromise()throws Exception {
        Source source=source("1000","0","1000","1000","1000");
        receipt(source,"100",true);
        amount("1000",value("SELECT pending_qty FROM fn_preplan_aggregate_direct_make_sources(?)",source.material));
        amount("1000",value("SELECT inherited_pending_qty FROM fn_preplan_aggregate_alias_coverage(?)",analysis));
    }

    @Test void frozenCanonicalCapacitySurvivesEffectiveZeroAndDoesNotDoubleAppendSnapshots()throws Exception {
        Source first=source("1000","0","1000","1000","3000");
        sql("INSERT INTO preplan_aggregate_batch_events(batch_id,event_type,resulting_version,canonical_capacity_deltas,source_capacity_deltas,alias_deltas) VALUES(?,'APPEND',1,CAST(? AS jsonb),CAST(? AS jsonb),CAST(? AS jsonb))",
                batch,"{\""+canonical+"\":300}","{\""+first.alias+"\":100}","{\""+first.alias+"\":100}");
        Source later=source("1000","0","1000","1000","3300");
        sql("UPDATE preplan_aggregate_material_aliases SET capacity_version=1 WHERE id=?",later.alias);
        amount("3300",value("SELECT fn_preplan_aggregate_material_capacity(?)",canonical));
        amount("1100",value("SELECT fn_preplan_aggregate_alias_source_capacity(?)",first.alias));
    }

    @Test void zeroTransferProofKeepsTheUnneededOldPrivatePlanWithoutCreatingCanonicalCoverage()throws Exception {
        Source source=source("1000","0","0","1000","1000");
        assertEquals("t",value("SELECT fn_preplan_aggregate_alias_identity_valid(?)",source.alias));
        assertEquals("f",value("SELECT fn_preplan_aggregate_alias_valid(?)",source.alias));
        amount("1000",value("SELECT fn_preplan_direct_make_admitted_qty(?,?)",source.child,source.material));
        amount("1000",value("SELECT fn_preplan_aggregate_source_retained_qty(?)",source.material));
        assertNull(value("SELECT inherited_pending_qty FROM fn_preplan_aggregate_alias_coverage(?)",analysis));
    }

    @Test void aliasIdentityRejectsANameOnlyOrWrongBomPathMatch()throws Exception {
        Source source=source("1000","0","1000","1000","1000");
        sql("UPDATE preplan_aggregate_material_aliases SET relative_bom_path=ARRAY[CAST(? AS uuid)] WHERE id=?",UUID.randomUUID(),source.alias);
        assertEquals("f",value("SELECT fn_preplan_aggregate_alias_valid(?)",source.alias));
        assertNull(value("SELECT inherited_pending_qty FROM fn_preplan_aggregate_alias_coverage(?)",analysis));
    }

    @Test void cancellationCannotDiscardDelegatedInputsUntilTheirControlledRelease()throws Exception {
        Source source=source("1000","0","1000","1000","1000");UUID delegation=delegated(source,"100");
        sql("CREATE TRIGGER aggregate_cancel BEFORE UPDATE OF status ON preplan_supply_actions FOR EACH ROW EXECUTE FUNCTION fn_guard_aggregate_source_cancellation()");
        SQLException rejected=assertThrows(SQLException.class,()->sql("UPDATE preplan_supply_actions SET status='CANCELLED' WHERE id=?",action));
        assertEquals("23514",rejected.getSQLState());
        UUID incoming=UUID.randomUUID();sql("INSERT INTO preplan_stock_entitlement_events(id,event_group_id,event_type,qty) VALUES(?,?,'MAKE_DELEGATE_IN',100)",incoming,delegation);
        sql("INSERT INTO preplan_stock_entitlement_events(event_type,source_entitlement_event_id,qty) VALUES('RELEASE',?,100)",incoming);
        sql("UPDATE preplan_supply_actions SET status='CANCELLED' WHERE id=?",action);
        amount("0",value("SELECT fn_preplan_aggregate_alias_qty(?)",source.alias));
    }

    private Source source(String capacity,String retained,String aliasQty,String planned,String canonicalCapacity)throws Exception {
        UUID root=UUID.randomUUID(),parent=UUID.randomUUID(),source=UUID.randomUUID(),child=UUID.randomUUID(),plan=UUID.randomUUID(),planItem=UUID.randomUUID(),alias=UUID.randomUUID(),allocation=UUID.randomUUID();
        String parentEdge=UUID.randomUUID().toString();
        sql("INSERT INTO production_material_analysis_items(id,analysis_id,source_type,is_deleted) VALUES(?,?,'SALES_ORDER_ITEM',false)",root,analysis);
        material(parent,root,parentEdge,null,UUID.fromString(parentEdge),parentGoods,capacity);
        material(source,root,parentEdge+"/"+edge,parentEdge,edge,component,retained);
        sql("INSERT INTO production_material_analysis_items(id,analysis_id,source_type,parent_analysis_material_id,goods_id,unit_id,requested_qty,approved_qty,is_deleted) VALUES(?,?,'MAKE_COMPONENT',?,?,?,CAST(? AS numeric),CAST(? AS numeric),false)",child,analysis,source,component,unit,planned,planned);
        sql("INSERT INTO production_plans(id,material_analysis_id,material_analysis_item_id,status,is_deleted,is_canceled,is_closed) VALUES(?,?,?,1,false,false,false)",plan,analysis,child);
        sql("INSERT INTO production_plan_items(id,plan_id,goods_id,unit_id,unit_rate,qty,is_deleted) VALUES(?,?,?,?,1,CAST(? AS numeric),false)",planItem,plan,component,unit,planned);
        sql("INSERT INTO production_material_analysis_plan_links(analysis_id,analysis_item_id,plan_id,submitted_qty,public_surplus_qty,allocation_status) VALUES(?,?,?,CAST(? AS numeric),0,'APPROVED')",analysis,child,plan,planned);
        sql("INSERT INTO preplan_supply_action_allocations(id,analysis_id,action_id,analysis_material_id,allocated_qty,external_item_id) VALUES(?,?,?,?,CAST(? AS numeric),?)",allocation,analysis,action,parent,new BigDecimal(aliasQty).signum()>0?aliasQty:capacity,anchor);
        sql("INSERT INTO preplan_aggregate_material_aliases(id,batch_id,source_parent_material_id,source_material_id,aggregate_material_id,relative_bom_path,qty,source_capacity_qty,canonical_capacity_qty,capacity_version) VALUES(?,?,?,?,?,ARRAY[CAST(? AS uuid)],CAST(? AS numeric),CAST(? AS numeric),CAST(? AS numeric),0)",alias,batch,parent,source,canonical,edge,aliasQty,capacity,canonicalCapacity);
        return new Source(root,parent,source,child,plan,planItem,alias,allocation);
    }
    private void material(UUID id,UUID owner,String key,String parent,UUID bom,UUID goods,String qty)throws Exception {
        sql("INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,node_key,parent_node_key,bom_item_id,goods_id,unit_id,depth,required_qty,confirmed_route,active,node_role) VALUES(?,?,?,?,?,?,?,?,1,CAST(? AS numeric),'MAKE',true,'BOM_COMPONENT')",id,analysis,owner,key,parent,bom,goods,unit,qty);
    }
    private UUID receipt(Source source,String qty,boolean publicOutput)throws Exception {
        UUID doc=UUID.randomUUID(),stockItem=UUID.randomUUID(),reportItem=UUID.randomUUID(),segment=UUID.randomUUID();
        sql("INSERT INTO production_daily_report_items(id,execution_segment_id,plan_item_id,is_public_output,is_actual_surplus) VALUES(?,?,?,?,?)",reportItem,segment,source.planItem,publicOutput,publicOutput);
        sql("INSERT INTO stock_documents(id,doc_type,status,is_deleted) VALUES(?,'FINISHED_IN',1,false)",doc);
        sql("INSERT INTO stock_document_items(id,doc_id,bill_type,upstream_item_id,source_daily_report_item_id,execution_segment_id,base_qty,is_deleted) VALUES(?,?,'FINISHED_IN',?,?,?,CAST(? AS numeric),false)",stockItem,doc,source.planItem,reportItem,segment,qty);return doc;
    }
    private UUID delegated(Source source,String qty)throws Exception {
        UUID id=UUID.randomUUID();sql("INSERT INTO preplan_make_entitlement_delegations(id,analysis_id,supply_action_id,aggregate_alias_id,source_analysis_material_id,target_analysis_material_id,qty) VALUES(?,?,?,?,?,?,CAST(? AS numeric))",id,analysis,action,source.alias,source.material,canonical,qty);return id;
    }
    private void balance(UUID material,String qty)throws Exception {sql("INSERT INTO v_preplan_stock_entitlement_beneficiary_balance(beneficiary_analysis_id,beneficiary_analysis_material_id,effective_qty) VALUES(?,?,CAST(? AS numeric))",analysis,material,qty);}
    private void sql(String command,Object...args)throws SQLException {try(var statement=db.prepareStatement(command)){for(int i=0;i<args.length;i++)statement.setObject(i+1,args[i]);statement.execute();}}
    private String value(String command,Object...args)throws SQLException {try(var statement=db.prepareStatement(command)){for(int i=0;i<args.length;i++)statement.setObject(i+1,args[i]);try(var rows=statement.executeQuery()){return rows.next()?rows.getString(1):null;}}}
    private static void amount(String expected,String actual){assertNotNull(actual);assertEquals(0,new BigDecimal(expected).compareTo(new BigDecimal(actual)),actual);}
}
