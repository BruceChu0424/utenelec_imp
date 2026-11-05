package com.uten.imp.businesschain;

import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.postgresql.util.PGobject;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.util.*;
import static org.assertj.core.api.Assertions.assertThat;

/** SQL predicate fixtures only; the real partial-production/shipment flow is MixedScenario E2E. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class DirectMakeDeliveryClosedCreditPostgresTest {
    private static final PostgreSQLContainer DB=new PostgreSQLContainer("postgres:16-alpine");
    private static JdbcTemplate jdbc;
    private final UUID analysis=UUID.randomUUID(),child=UUID.randomUUID(),source=UUID.randomUUID(),material=UUID.randomUUID(),
            orderItem=UUID.randomUUID(),goods=UUID.randomUUID(),unit=UUID.randomUUID(),edge=UUID.randomUUID(),warehouse=UUID.randomUUID(),
            handoff=UUID.randomUUID(),origin=UUID.randomUUID(),exact=UUID.randomUUID(),receiptItem=UUID.randomUUID(),receipt=UUID.randomUUID(),
            planItem=UUID.randomUUID(),plan=UUID.randomUUID(),component=UUID.randomUUID(),shipmentItem=UUID.randomUUID(),shipment=UUID.randomUUID(),
            movement=UUID.randomUUID(),held=UUID.randomUUID(),allocation=UUID.randomUUID(),fulfilled=UUID.randomUUID(),release=UUID.randomUUID(),originalReservation=UUID.randomUUID();
    private static final List<String> TABLES=List.of("production_material_analysis_items","production_material_analysis_materials",
            "sales_delivery_entitlement_handoffs","preplan_stock_entitlement_events","preplan_analysis_stock_exact_pegs",
            "stock_document_items","stock_documents","production_plan_items","production_plans","sales_shipment_delivery_components",
            "sales_shipment_items","sales_shipments","stock_movements","stock_reservations","sales_delivery_fulfillment_allocations",
            "sales_delivery_fulfillment_groups","sales_delivery_fulfillment_events","sales_delivery_entitlement_restores","preplan_reallocation_make_supplements");

    @BeforeAll static void database() throws Exception {
        DB.start();
        var admin=new JdbcTemplate(new DriverManagerDataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword()));
        admin.execute("CREATE SCHEMA direct_make_credit");
        String url=DB.getJdbcUrl()+(DB.getJdbcUrl().contains("?")?"&":"?")+"currentSchema=direct_make_credit";
        jdbc=new JdbcTemplate(new DriverManagerDataSource(url,DB.getUsername(),DB.getPassword()));
        jdbc.execute("""
                CREATE TABLE production_material_analysis_items(id uuid PRIMARY KEY,analysis_id uuid,parent_analysis_material_id uuid,source_type text,is_deleted boolean DEFAULT false,delivery_plan_snapshot jsonb,sales_order_item_id uuid,requested_qty numeric);
                CREATE TABLE production_material_analysis_materials(id uuid PRIMARY KEY,analysis_id uuid,analysis_item_id uuid,delivery_frontier boolean,delivery_context boolean,depth int,goods_id uuid,color_id uuid,unit_id uuid,node_key text,required_qty numeric);
                CREATE TABLE sales_delivery_entitlement_handoffs(id uuid PRIMARY KEY,component_id uuid,allocation_id uuid,source_analysis_id uuid,source_material_id uuid,entitlement_material_id uuid,entitlement_analysis_id uuid,aggregate_alias_id uuid,source_entitlement_event_id uuid,source_reservation_id uuid,target_reservation_id uuid,release_event_id uuid,quantity numeric);
                CREATE TABLE preplan_stock_entitlement_events(id uuid PRIMARY KEY,event_type text,stock_reservation_id uuid,beneficiary_analysis_id uuid,beneficiary_analysis_material_id uuid,source_exact_peg_id uuid,counter_event_id uuid);
                CREATE TABLE preplan_analysis_stock_exact_pegs(id uuid PRIMARY KEY,make_source_analysis_item_id uuid,make_public_claim_id uuid,source_receipt_type text,stock_reservation_id uuid,source_stock_document_item_id uuid,source_stock_document_id uuid,qty numeric);
                CREATE TABLE stock_document_items(id uuid PRIMARY KEY,doc_id uuid,bill_type text,is_deleted boolean DEFAULT false,upstream_item_id uuid);
                CREATE TABLE stock_documents(id uuid PRIMARY KEY,status int,is_deleted boolean DEFAULT false);
                CREATE TABLE production_plan_items(id uuid PRIMARY KEY,plan_id uuid,is_deleted boolean DEFAULT false);
                CREATE TABLE production_plans(id uuid PRIMARY KEY,material_analysis_id uuid,material_analysis_item_id uuid,is_deleted boolean DEFAULT false);
                CREATE TABLE sales_shipment_delivery_components(id uuid PRIMARY KEY,order_item_id uuid,goods_id uuid,color_id uuid,unit_id uuid,bom_fingerprint text,bom_path jsonb,reversal_movement_id uuid,shipment_item_id uuid,shipment_id uuid,movement_id uuid,required_qty numeric,warehouse_id uuid);
                CREATE TABLE sales_shipment_items(id uuid PRIMARY KEY,shipment_id uuid,order_item_id uuid,is_deleted boolean DEFAULT false);
                CREATE TABLE sales_shipments(id uuid PRIMARY KEY,status int,is_deleted boolean DEFAULT false);
                CREATE TABLE stock_movements(id uuid PRIMARY KEY,source_doc_type text,source_doc_id uuid,source_item_id uuid,movement_type int,direction int,qty numeric,goods_id uuid,color_id uuid,warehouse_id uuid,unit_id uuid);
                CREATE TABLE stock_reservations(id uuid PRIMARY KEY,owner_type text,owner_id uuid,qty numeric,consumed_qty numeric,released_qty numeric,status int,is_deleted boolean DEFAULT false);
                CREATE TABLE sales_delivery_fulfillment_allocations(id uuid PRIMARY KEY,analysis_id uuid,analysis_item_id uuid,shipment_item_id uuid);
                CREATE TABLE sales_delivery_fulfillment_groups(shipment_item_id uuid PRIMARY KEY,shipment_id uuid,order_item_id uuid,state text);
                CREATE TABLE sales_delivery_fulfillment_events(id uuid PRIMARY KEY,allocation_id uuid,event_type text,counter_event_id uuid);
                CREATE TABLE sales_delivery_entitlement_restores(id uuid PRIMARY KEY,handoff_id uuid);
                CREATE TABLE preplan_reallocation_make_supplements(child_analysis_item_id uuid,source_analysis_material_id uuid,qty numeric);
                CREATE FUNCTION fn_preplan_aggregate_source_capacity(p_material uuid) RETURNS numeric LANGUAGE sql STABLE AS $$SELECT required_qty FROM production_material_analysis_materials WHERE id=p_material$$;
                """);
        jdbc.execute(new ClassPathResource("db/migration/V1058__direct_make_closed_delivery_credit.sql").getContentAsString(StandardCharsets.UTF_8));
    }
    @AfterAll static void stop(){DB.stop();}

    @BeforeEach void candidate() throws Exception {
        jdbc.execute("TRUNCATE "+String.join(",",TABLES));
        row("production_material_analysis_items","id",source,"analysis_id",analysis,"source_type","SALES_ORDER_ITEM","delivery_plan_snapshot",json("{\"mode\":\"BOM\",\"bomFingerprint\":\"recipe\"}"),"sales_order_item_id",orderItem);
        row("production_material_analysis_items","id",child,"analysis_id",analysis,"parent_analysis_material_id",material,"source_type","MAKE_COMPONENT","requested_qty",new BigDecimal("10"));
        row("production_material_analysis_materials","id",material,"analysis_id",analysis,"analysis_item_id",source,"delivery_frontier",true,"delivery_context",false,"depth",1,"goods_id",goods,"unit_id",unit,"node_key",edge.toString(),"required_qty",new BigDecimal("6"));
        row("sales_delivery_entitlement_handoffs","id",handoff,"component_id",component,"allocation_id",allocation,"source_analysis_id",analysis,"source_material_id",material,"entitlement_material_id",material,"entitlement_analysis_id",analysis,"source_entitlement_event_id",origin,"source_reservation_id",originalReservation,"target_reservation_id",held,"release_event_id",release,"quantity",new BigDecimal("4"));
        row("preplan_stock_entitlement_events","id",origin,"event_type","ORIGIN_MAKE","stock_reservation_id",originalReservation,"beneficiary_analysis_id",analysis,"beneficiary_analysis_material_id",material,"source_exact_peg_id",exact);
        row("preplan_analysis_stock_exact_pegs","id",exact,"make_source_analysis_item_id",child,"source_receipt_type","MAKE","stock_reservation_id",originalReservation,"source_stock_document_item_id",receiptItem,"source_stock_document_id",receipt,"qty",new BigDecimal("4"));
        row("stock_document_items","id",receiptItem,"doc_id",receipt,"bill_type","FINISHED_IN","upstream_item_id",planItem);
        row("stock_documents","id",receipt,"status",1);
        row("production_plan_items","id",planItem,"plan_id",plan);
        row("production_plans","id",plan,"material_analysis_id",analysis,"material_analysis_item_id",child);
        row("sales_shipment_delivery_components","id",component,"order_item_id",orderItem,"goods_id",goods,"unit_id",unit,"bom_fingerprint","recipe","bom_path",json("[\""+edge+"\"]"),"shipment_item_id",shipmentItem,"shipment_id",shipment,"movement_id",movement,"required_qty",new BigDecimal("4"),"warehouse_id",warehouse);
        row("sales_shipment_items","id",shipmentItem,"shipment_id",shipment,"order_item_id",orderItem);
        row("sales_shipments","id",shipment,"status",1);
        row("stock_movements","id",movement,"source_doc_type","SALES_SHIPMENT","source_doc_id",shipment,"source_item_id",component,"movement_type",3,"direction",-1,"qty",new BigDecimal("4"),"goods_id",goods,"warehouse_id",warehouse,"unit_id",unit);
        row("stock_reservations","id",held,"owner_type","SALES_DELIVERY_COMPONENT_SHIPMENT","owner_id",component,"qty",new BigDecimal("4"),"consumed_qty",new BigDecimal("4"),"released_qty",BigDecimal.ZERO,"status",1);
        row("sales_delivery_fulfillment_allocations","id",allocation,"analysis_id",analysis,"analysis_item_id",source,"shipment_item_id",shipmentItem);
        row("sales_delivery_fulfillment_groups","shipment_item_id",shipmentItem,"shipment_id",shipment,"order_item_id",orderItem,"state","COMPLETED");
        row("sales_delivery_fulfillment_events","id",fulfilled,"allocation_id",allocation,"event_type","FULFILL");
    }

    @Test void exactClosedMakeAddsBackOnlyTheAlreadyAttributedPartOfThePrivateTotal(){
        assertThat(closed()).isEqualByComparingTo("4");assertThat(total()).isEqualByComparingTo("10");assertThat(admitted()).isEqualByComparingTo("10");
        assertThat(jdbc.queryForObject("SELECT fn_preplan_aggregate_source_capacity(?)",BigDecimal.class,material)).isEqualByComparingTo("6");
        assertThat(jdbc.queryForObject("SELECT fn_preplan_direct_make_delivery_closed_qty(?,?)",BigDecimal.class,UUID.randomUUID(),material)).isZero();
        assertThat(jdbc.queryForObject("SELECT fn_preplan_direct_make_delivery_closed_qty(?,?)",BigDecimal.class,child,UUID.randomUUID())).isZero();
    }

    @Test void unknownCurrentCapacityDoesNotBecomeANewRightFromHistoricalShipments(){
        jdbc.update("UPDATE production_material_analysis_materials SET required_qty=NULL WHERE id=?",material);
        assertThat(closed()).isEqualByComparingTo("4");assertThat(total()).isNull();assertThat(admitted()).isZero();
    }

    @Test void fullyDeliveredAndAlreadyAttributedQuantityLeavesNoNewAdmission(){
        jdbc.update("UPDATE production_material_analysis_materials SET required_qty=0 WHERE id=?",material);
        jdbc.update("UPDATE sales_delivery_entitlement_handoffs SET quantity=10 WHERE id=?",handoff);
        jdbc.update("UPDATE stock_reservations SET qty=10,consumed_qty=10 WHERE id=?",held);
        jdbc.update("UPDATE sales_shipment_delivery_components SET required_qty=10 WHERE id=?",component);
        jdbc.update("UPDATE stock_movements SET qty=10 WHERE id=?",movement);
        jdbc.update("UPDATE preplan_analysis_stock_exact_pegs SET qty=10 WHERE id=?",exact);
        assertThat(closed()).isEqualByComparingTo("10");assertThat(total()).isEqualByComparingTo("10");
        assertThat(jdbc.queryForObject("SELECT GREATEST(fn_preplan_direct_make_admitted_qty(?,?)-(SELECT sum(qty) FROM preplan_analysis_stock_exact_pegs WHERE make_source_analysis_item_id=?),0)",BigDecimal.class,child,material,child)).isZero();
    }

    @ParameterizedTest
    @ValueSource(strings={"BUY","ISSUED_ONLY","CANCELLED","RESTORED","REVERSED","OTHER_ORDER","OTHER_PATH","ALIAS","OTHER_MAKE_SOURCE","NO_KIT_FULFILL","UNCONSUMED_HOLD"})
    void nonClosedOrForeignCandidatesNeverCredit(String kind) throws Exception {
        switch(kind){
            case "BUY"->jdbc.update("UPDATE preplan_stock_entitlement_events SET event_type='ORIGIN_IQC' WHERE id=?",origin);
            case "ISSUED_ONLY"->jdbc.update("UPDATE sales_shipment_delivery_components SET movement_id=NULL WHERE id=?",component);
            case "CANCELLED"->jdbc.update("UPDATE sales_delivery_fulfillment_groups SET state='CANCELLED' WHERE shipment_item_id=?",shipmentItem);
            case "RESTORED"->row("sales_delivery_entitlement_restores","id",UUID.randomUUID(),"handoff_id",handoff);
            case "REVERSED"->row("sales_delivery_fulfillment_events","id",UUID.randomUUID(),"allocation_id",allocation,"event_type","REVERSE","counter_event_id",fulfilled);
            case "OTHER_ORDER"->jdbc.update("UPDATE sales_shipment_delivery_components SET order_item_id=? WHERE id=?",UUID.randomUUID(),component);
            case "OTHER_PATH"->jdbc.update("UPDATE sales_shipment_delivery_components SET bom_path=CAST(? AS jsonb) WHERE id=?","[\""+UUID.randomUUID()+"\"]",component);
            case "ALIAS"->jdbc.update("UPDATE sales_delivery_entitlement_handoffs SET aggregate_alias_id=? WHERE id=?",UUID.randomUUID(),handoff);
            case "OTHER_MAKE_SOURCE"->jdbc.update("UPDATE preplan_analysis_stock_exact_pegs SET make_source_analysis_item_id=? WHERE id=?",UUID.randomUUID(),exact);
            case "NO_KIT_FULFILL"->jdbc.update("DELETE FROM sales_delivery_fulfillment_events WHERE id=?",fulfilled);
            case "UNCONSUMED_HOLD"->jdbc.update("UPDATE stock_reservations SET consumed_qty=0,status=0 WHERE id=?",held);
            default->throw new IllegalArgumentException(kind);
        }
        assertThat(closed()).as(kind).isZero();assertThat(total()).as(kind).isEqualByComparingTo("6");assertThat(admitted()).as(kind).isEqualByComparingTo("6");
    }

    private BigDecimal closed(){return jdbc.queryForObject("SELECT fn_preplan_direct_make_delivery_closed_qty(?,?)",BigDecimal.class,child,material);}
    private BigDecimal total(){return jdbc.queryForObject("SELECT fn_preplan_direct_make_total_capacity(?,?)",BigDecimal.class,child,material);}
    private BigDecimal admitted(){return jdbc.queryForObject("SELECT fn_preplan_direct_make_admitted_qty(?,?)",BigDecimal.class,child,material);}
    private static PGobject json(String value) throws Exception {var json=new PGobject();json.setType("jsonb");json.setValue(value);return json;}
    private static void row(String table,Object... values){
        var fields=new ArrayList<String>();var arguments=new ArrayList<Object>();
        for(int index=0;index<values.length;index+=2){fields.add((String)values[index]);arguments.add(values[index+1]);}
        jdbc.update("INSERT INTO "+table+"("+String.join(",",fields)+") VALUES("+String.join(",",Collections.nCopies(fields.size(),"?"))+")",arguments.toArray());
    }
}
