package com.uten.imp.migration;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Executes the actual immutable SQL functions and real capture/projection triggers
 * against nonempty source ledgers in an isolated PostgreSQL 16 database. This is
 * a shared-curve regression, not a replacement for a full company-clone upgrade. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class RootFulfillmentSharedCurvePostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    private Connection db;

    @BeforeAll static void start(){PG.start();}
    @AfterAll static void stop(){PG.stop();}
    @org.junit.jupiter.api.AfterEach void close()throws Exception{db.close();}

    @BeforeEach void baseline()throws Exception {
        db=DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        sql("DROP SCHEMA public CASCADE; CREATE SCHEMA public");
        sql("""
            CREATE TABLE production_material_analyses(id uuid PRIMARY KEY,is_deleted boolean NOT NULL DEFAULT false,status text NOT NULL DEFAULT 'ACTIVE');
            CREATE TABLE production_material_analysis_materials(id uuid PRIMARY KEY,per_product_qty numeric);
            CREATE TABLE production_material_analysis_items(id uuid PRIMARY KEY,analysis_id uuid NOT NULL,
              root_material_id uuid,requested_qty numeric NOT NULL,submitted_qty numeric NOT NULL DEFAULT 0,
              approved_qty numeric NOT NULL DEFAULT 0,delivery_plan_snapshot jsonb,root_fulfilled_qty numeric NOT NULL DEFAULT 0,
              ready_now_qty numeric NOT NULL DEFAULT 0,ready_by_date_qty numeric NOT NULL DEFAULT 0,
              ready_start_qty numeric NOT NULL DEFAULT 0,ready_finish_qty numeric NOT NULL DEFAULT 0,
              ready_ship_qty numeric NOT NULL DEFAULT 0,updated_at timestamptz DEFAULT now());
            CREATE TABLE stock_reservations(id uuid PRIMARY KEY,qty numeric NOT NULL,released_qty numeric NOT NULL DEFAULT 0,
              consumed_qty numeric NOT NULL DEFAULT 0,is_deleted boolean NOT NULL DEFAULT false);
            CREATE TABLE preplan_sales_stock_adoptions(id uuid PRIMARY KEY,analysis_id uuid NOT NULL,
              analysis_item_id uuid NOT NULL,root_material_id uuid NOT NULL,reservation_id uuid NOT NULL,
              qty_base numeric NOT NULL,adoption_sequence bigint GENERATED ALWAYS AS IDENTITY);
            CREATE TABLE preplan_root_output_events(id uuid PRIMARY KEY,analysis_item_id uuid NOT NULL,
              event_kind text NOT NULL,qty_base numeric NOT NULL);
            CREATE TABLE sales_delivery_fulfillment_allocations(id uuid PRIMARY KEY,analysis_item_id uuid NOT NULL);
            CREATE TABLE sales_delivery_fulfillment_events(id uuid PRIMARY KEY,allocation_id uuid NOT NULL,
              event_type text NOT NULL,order_qty numeric NOT NULL);
            """);
        String original=resource("V1056__delivery_original_order_stock_claims.sql");
        sql(original.substring(0,original.indexOf("CREATE TABLE sales_delivery_order_claims")));
        sql(function(resource("V1108__same_sales_source_stock_adoption.sql"),"fn_preplan_adopted_sales_stock_base"));
        String old=resource("V478__analysis_root_supply_fulfillment.sql");
        sql(function(old,"fn_project_root_output_quantity"));
        sql(function(old,"fn_check_root_output_quantity"));
        sql("""
            CREATE TRIGGER trg_project_root_output_quantity AFTER INSERT ON preplan_root_output_events
              FOR EACH ROW EXECUTE FUNCTION fn_project_root_output_quantity();
            CREATE CONSTRAINT TRIGGER trg_check_root_output_quantity AFTER INSERT OR UPDATE ON production_material_analysis_items
              DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_check_root_output_quantity();
            """);
        String adoption=resource("V1108__same_sales_source_stock_adoption.sql");
        int refresh=adoption.indexOf("CREATE OR REPLACE FUNCTION fn_refresh_adopted_sales_stock_quantity()");
        sql(adoption.substring(refresh,adoption.indexOf("COMMENT ON TABLE preplan_sales_stock_adoptions",refresh)));
    }

    @Test void nonemptyBomKeepsOriginalDeliveryLedgerAndIgnoresFinishedProductDelta()throws Exception {
        World w=world("BOM","10","3");
        UUID allocation=UUID.randomUUID();
        update("INSERT INTO sales_delivery_fulfillment_allocations VALUES(?,?)",allocation,w.item());
        update("INSERT INTO sales_delivery_fulfillment_events VALUES(?,?, 'FULFILL',6)",UUID.randomUUID(),allocation);
        update("INSERT INTO sales_delivery_fulfillment_events VALUES(?,?, 'REVERSE',1)",UUID.randomUUID(),allocation);
        output(w,"FULFILL","3");
        amount("5",base(w));amount("0",scalar("SELECT qty_source FROM preplan_root_output_events WHERE analysis_item_id=?",w.item()));
        String oldRows=sourceRows(w);
        brokenV1108();
        amount("1",base(w)); // actual nonempty V1108 regression, not a hypothetical definition comparison.
        System.out.println("ROOT_CURVE_RED_BOM original=5 overwritten=1 original_source_rows_preserved=true");
        repair();
        amount("5",base(w));amount("5",delta(w,"300"));amount("5",delta(w,"-300"));
        assertEquals(oldRows,sourceRows(w),"forward repair must not rewrite original event, credit, item or BOM ledger rows");
        output(w,"FULFILL","3");
        amount("5",base(w));
        assertEquals(0,number("SELECT count(*) FROM preplan_root_output_events WHERE analysis_item_id=? AND qty_source<>0",w.item()));
        amount("5",scalar("SELECT root_fulfilled_qty FROM production_material_analysis_items WHERE id=?",w.item()));
    }

    @Test void adoptionAndNewRootOutputsShareCaptureAndReversalCreditAtTheRemainingCap()throws Exception {
        World w=world("ASSEMBLED","10","1");
        adopt(w,"6");
        brokenV1108();
        amount("6",base(w));amount("1",delta(w,"1"));
        SQLException failure=assertThrows(SQLException.class,()->output(w,"FULFILL","1"));
        assertEquals("23514",failure.getSQLState());
        assertEquals(0,number("SELECT count(*) FROM preplan_root_output_events WHERE analysis_item_id=?",w.item()));
        System.out.println("ROOT_CURVE_RED_CREDIT adoption=6 original_delta_result=1 capture_sqlstate=23514 output_insert_rolled_back=true");
        String originalAdoption=scalar("SELECT to_jsonb(a)::text FROM preplan_sales_stock_adoptions a WHERE analysis_item_id=?",w.item());
        repair();
        amount("6",base(w));amount("7",delta(w,"1"));
        UUID first=output(w,"FULFILL","1");
        amount("1",scalar("SELECT qty_source FROM preplan_root_output_events WHERE id=?",first));
        amount("7",base(w));
        UUID capped=output(w,"FULFILL","8");
        amount("3",scalar("SELECT qty_source FROM preplan_root_output_events WHERE id=?",capped));
        amount("10",base(w));
        amount("3",decimal(base(w)).subtract(decimal(delta(w,"-8"))));
        output(w,"REVERSE","8");
        amount("7",base(w));
        amount("1",scalar("SELECT qty_source FROM preplan_root_output_events WHERE id=?",first));
        amount("3",scalar("SELECT qty_source FROM preplan_root_output_events WHERE id=?",capped));
        assertEquals(1,number("SELECT count(*) FROM preplan_root_output_events WHERE analysis_item_id=? AND event_kind='REVERSE' AND qty_source IS NULL",w.item()));
        update("UPDATE production_material_analyses SET status='CANCELLED' WHERE id=?",w.analysis());
        amount("1",base(w));
        amount("1",scalar("SELECT root_fulfilled_qty FROM production_material_analysis_items WHERE id=?",w.item()));
        assertEquals(originalAdoption,scalar("SELECT to_jsonb(a)::text FROM preplan_sales_stock_adoptions a WHERE analysis_item_id=?",w.item()),"cancellation must not rewrite the original adoption");
    }

    @Test void fractionalAdoptionRetainsTheOriginalFrozenDifferenceAndReservationReleaseCurve()throws Exception {
        World w=world("ASSEMBLED","2","3");
        adopt(w,"2");brokenV1108();repair();
        amount("0.6666",base(w));amount("1",delta(w,"1"));
        UUID output=output(w,"FULFILL","1");
        amount("0.3334",scalar("SELECT qty_source FROM preplan_root_output_events WHERE id=?",output));
        amount("1",base(w));
        amount("0.3334",decimal(base(w)).subtract(decimal(delta(w,"-1"))));
        update("UPDATE stock_reservations SET released_qty=1 WHERE id=?",w.reservation());
        amount("0.6666",base(w));
        amount("0.6666",scalar("SELECT root_fulfilled_qty FROM production_material_analysis_items WHERE id=?",w.item()));
        amount("0.3334",scalar("SELECT qty_source FROM preplan_root_output_events WHERE id=?",output));
        amount("2",scalar("SELECT qty_base FROM preplan_sales_stock_adoptions WHERE analysis_item_id=?",w.item()));
    }

    private World world(String mode,String requested,String perProduct)throws Exception {
        World w=new World(UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID());
        update("INSERT INTO production_material_analyses(id) VALUES(?)",w.analysis());
        update("INSERT INTO production_material_analysis_materials VALUES(?,?)",w.root(),decimal(perProduct));
        update("INSERT INTO production_material_analysis_items(id,analysis_id,root_material_id,requested_qty,delivery_plan_snapshot) VALUES(?,?,?,?,jsonb_build_object('mode',?::text))",
                w.item(),w.analysis(),w.root(),decimal(requested),mode);
        return w;
    }
    private void adopt(World w,String qty)throws Exception {
        update("INSERT INTO stock_reservations(id,qty) VALUES(?,?)",w.reservation(),decimal(qty));
        update("INSERT INTO preplan_sales_stock_adoptions(id,analysis_id,analysis_item_id,root_material_id,reservation_id,qty_base) VALUES(?,?,?,?,?,?)",
                UUID.randomUUID(),w.analysis(),w.item(),w.root(),w.reservation(),decimal(qty));
    }
    private UUID output(World w,String kind,String qty)throws Exception {
        UUID id=UUID.randomUUID();
        update("INSERT INTO preplan_root_output_events(id,analysis_item_id,event_kind,qty_base) VALUES(?,?,?,?)",id,w.item(),kind,decimal(qty));
        return id;
    }
    private void brokenV1108()throws Exception {sql(function(resource("V1108__same_sales_source_stock_adoption.sql"),"fn_root_fulfilled_source_qty"));}
    private void repair()throws Exception {
        // A diagnostic red invocation can leave the original V1108 public entry
        // in place; the same unchanged assertions then fail on the real data.
        if(!Boolean.getBoolean("uten.root.curve.reproduceOriginal"))
            sql(resource("V1111__shared_root_fulfillment_source_curve.sql"));
    }
    private String sourceRows(World w)throws Exception {
        return scalar("SELECT jsonb_build_object('item',(SELECT to_jsonb(i) FROM production_material_analysis_items i WHERE id=?),"
                +"'outputs',(SELECT jsonb_agg(to_jsonb(e) ORDER BY id) FROM preplan_root_output_events e WHERE analysis_item_id=?),"
                +"'bom',(SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id) FROM sales_delivery_fulfillment_events e JOIN sales_delivery_fulfillment_allocations a ON a.id=e.allocation_id WHERE a.analysis_item_id=?))::text",
                w.item(),w.item(),w.item());
    }
    private String base(World w)throws Exception{return scalar("SELECT fn_root_fulfilled_source_qty(?)",w.item());}
    private String delta(World w,String qty)throws Exception{return scalar("SELECT fn_root_fulfilled_source_qty_with_delta(?,?)",w.item(),decimal(qty));}
    private int number(String query,Object... args)throws Exception{return Integer.parseInt(scalar(query,args));}
    private String scalar(String query,Object... args)throws Exception {
        try(var statement=db.prepareStatement(query)){for(int i=0;i<args.length;i++)statement.setObject(i+1,args[i]);
            try(var rows=statement.executeQuery()){assertTrue(rows.next());return rows.getString(1);}}
    }
    private void update(String query,Object... args)throws Exception {
        try(var statement=db.prepareStatement(query)){for(int i=0;i<args.length;i++)statement.setObject(i+1,args[i]);statement.executeUpdate();}
    }
    private void sql(String query)throws Exception{try(var statement=db.createStatement()){statement.execute(query);}}
    private static BigDecimal decimal(String value){return new BigDecimal(value);}
    private static void amount(String expected,String actual){amount(expected,decimal(actual));}
    private static void amount(String expected,BigDecimal actual){assertEquals(0,decimal(expected).compareTo(actual),"expected "+expected+" but got "+actual);}
    private static String resource(String name)throws Exception {
        try(var input=RootFulfillmentSharedCurvePostgresTest.class.getClassLoader().getResourceAsStream("db/migration/"+name)){
            assertNotNull(input,name);return new String(input.readAllBytes(),StandardCharsets.UTF_8);}
    }
    private static String function(String source,String name) {
        int start=source.indexOf("CREATE OR REPLACE FUNCTION "+name+"(");
        if(start<0)start=source.indexOf("CREATE FUNCTION "+name+"(");
        assertTrue(start>=0,"missing original function "+name);
        int end=source.indexOf("$$;",start);assertTrue(end>start);return source.substring(start,end+3);
    }
    private record World(UUID analysis,UUID item,UUID root,UUID reservation) { }
}
