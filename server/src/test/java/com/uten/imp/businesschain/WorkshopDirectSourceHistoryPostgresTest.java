package com.uten.imp.businesschain;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Actual V614 schema with all guards enabled; V615 must only add proven source metadata. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class WorkshopDirectSourceHistoryPostgresTest {
    private static PostgreSQLContainer<?> postgres;
    private static String templateUrl;
    private static String username;
    private static String password;
    @BeforeAll static void prepareTemplate() {
        postgres=new PostgreSQLContainer<>("postgres:16-alpine").withDatabaseName("history_template");
        postgres.start();
        templateUrl=postgres.getJdbcUrl();
        username=postgres.getUsername();
        password=postgres.getPassword();
        migrate(templateUrl,"614");
    }
    @AfterAll static void closeTemplate(){if(postgres!=null)postgres.stop();}
    private record Database(String url,JdbcTemplate jdbc,TransactionTemplate tx) {}
    private static Database database() {
        String name="history_"+UUID.randomUUID().toString().replace("-","");
        var admin=new JdbcTemplate(new DriverManagerDataSource(templateUrl,username,password));
        admin.execute("CREATE DATABASE "+name+" TEMPLATE history_template");
        String url=templateUrl.replace("/history_template","/"+name);
        var source=new DriverManagerDataSource(url,username,password);
        return new Database(url,new JdbcTemplate(source),new TransactionTemplate(new DataSourceTransactionManager(source)));
    }
    @Test void singleSourceIssueReturnAndReleaseKeepOriginalFactsAndRebuildExactSlices() {
        {
            var database=database();var db=database.jdbc();var tx=database.tx();
            var f=tx.execute(ignored->seed(db,false));
            String before=facts(db,f);
            migrate(database.url(),"615");
            assertThat(facts(db,f)).isEqualTo(before);
            qty(db,"6","SELECT SUM(effective_qty) FROM v_workshop_direct_source_allocations WHERE stock_reservation_id=?",f.reservation());
            qty(db,"3","SELECT SUM(net_issued_qty) FROM v_workshop_direct_source_allocations WHERE stock_reservation_id=?",f.reservation());
            assertThat(db.queryForObject("SELECT COUNT(*) FROM production_workshop_direct_source_events event JOIN production_workshop_direct_source_allocations allocation ON allocation.id=event.source_allocation_id WHERE allocation.stock_reservation_id=? AND historical",Integer.class,f.reservation())).isEqualTo(3);
            assertThat(db.queryForList("""
                    SELECT event.event_type||':'||event.qty_base::text
                    FROM production_workshop_direct_source_events event
                    JOIN production_workshop_direct_source_allocations allocation ON allocation.id=event.source_allocation_id
                    WHERE allocation.stock_reservation_id=? ORDER BY event.event_type
                    """,String.class,f.reservation())).containsExactly("GOOD_RETURN:2.0000","ISSUE:5.0000","RELEASE:4.0000");
            assertThat(db.queryForObject("""
                    SELECT COUNT(*) FROM production_workshop_direct_source_events returned
                    JOIN production_workshop_direct_source_events issued ON issued.id=returned.counter_event_id
                    JOIN production_workshop_direct_source_allocations allocation ON allocation.id=returned.source_allocation_id
                    WHERE allocation.stock_reservation_id=? AND returned.event_type='GOOD_RETURN'
                      AND issued.event_type='ISSUE' AND issued.source_allocation_id=returned.source_allocation_id
                    """,Integer.class,f.reservation())).isOne();
        }
    }

    @Test void ambiguousMultipleSourcePartialIssueStopsUpgradeAndRollsBackAllNewDdl() {
        {
            var database=database();var db=database.jdbc();var tx=database.tx();
            var f=tx.execute(ignored->seed(db,true));
            String before=facts(db,f);
            assertThatThrownBy(()->migrate(database.url(),"615")).hasStackTraceContaining("Ambiguous historical multi-source");
            assertThat(facts(db,f)).isEqualTo(before);
            assertThat(db.queryForObject("SELECT to_regclass('public.production_workshop_direct_source_allocations') IS NULL",Boolean.class)).isTrue();
            assertThat(db.queryForObject("SELECT to_regclass('public.production_workshop_direct_source_events') IS NULL",Boolean.class)).isTrue();
            assertThat(db.queryForObject("SELECT COUNT(*) FROM flyway_schema_history WHERE version='615' AND success",Integer.class)).isZero();
        }
    }

    @Test void releasedQuantityCannotInventOriginalSourceBeyondPhysicalReceipt() {
        var database=database();var db=database.jdbc();
        var f=database.tx().execute(ignored->seed(db,false,true));
        String before=facts(db,f);
        assertThatThrownBy(()->migrate(database.url(),"615"))
                .hasStackTraceContaining("workshop material reservation lacks exact dedicated direct-transfer source");
        assertThat(facts(db,f)).isEqualTo(before);
        assertThat(db.queryForObject("SELECT to_regclass('public.production_workshop_direct_source_allocations') IS NULL",Boolean.class)).isTrue();
        assertThat(db.queryForObject("SELECT COUNT(*) FROM flyway_schema_history WHERE version='615' AND success",Integer.class)).isZero();
    }

    @Test void unprovenConsumedOpeningStopsUpgradeWithoutChangingTheOldFacts() throws Exception {
        var database=database();var db=database.jdbc();
        migrate(database.url(),"618");
        UUID reservation;
        try(var connection=db.getDataSource().getConnection()) {
            Object fixture=ReflectionTestUtils.invokeMethod(
                    Class.forName("com.uten.imp.features.production.fulfillment.ProductionPurchaseReceiptProvenancePostgresTest"),
                    "createFixture",connection);
            reservation=ReflectionTestUtils.invokeMethod(fixture,"reservationId");
        }
        // A V618-accepted discrepancy must stop the migration, not become a
        // runtime exception or an invented ISSUE in the unified model.
        db.update("UPDATE stock_reservations SET consumed_qty=3 WHERE id=?",reservation);
        String before=db.queryForObject("SELECT to_jsonb(reservation)::text FROM stock_reservations reservation WHERE id=?",String.class,reservation);
        assertThatThrownBy(()->migrate(database.url(),"619"))
                .hasStackTraceContaining("requires migration reconciliation")
                .hasStackTraceContaining(reservation.toString())
                .hasStackTraceContaining("projected 3.0000").hasStackTraceContaining("net issued 0");
        assertThat(db.queryForObject("SELECT to_jsonb(reservation)::text FROM stock_reservations reservation WHERE id=?",String.class,reservation)).isEqualTo(before);
        qty(db,"3","SELECT consumed_qty FROM stock_reservations WHERE id=?",reservation);
        assertThat(db.queryForObject("SELECT status::integer FROM stock_reservations WHERE id=?",Integer.class,reservation)).isZero();
        assertThat(db.queryForObject("SELECT COUNT(*) FROM production_material_stock_postings WHERE reservation_id=?",Integer.class,reservation)).isZero();
        assertThat(db.queryForObject("SELECT to_regclass('public.production_workshop_material_custody_moves') IS NULL",Boolean.class)).isTrue();
        assertThat(db.queryForObject("SELECT COUNT(*) FROM information_schema.columns WHERE table_name='stock_reservations' AND column_name='material_projection_tx_id'",Integer.class)).isZero();
        assertThat(db.queryForObject("SELECT COUNT(*) FROM flyway_schema_history WHERE version='619' AND success",Integer.class)).isZero();
    }

    @Test void completeIssueAndReturnReversalFactsCanUpgradeToTheUnifiedConsumptionModel() {
        var database=database();var db=database.jdbc();
        var f=database.tx().execute(ignored->seed(db,false,false,false));
        database.tx().executeWithoutResult(ignored->{
            UUID actor=db.queryForObject("SELECT created_by FROM production_material_stock_postings WHERE reservation_id=? AND posting_type='ISSUE'",UUID.class,f.reservation());
            db.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,actor.toString());
            var returned=db.queryForMap("SELECT p.id,p.stock_document_item_id,item.doc_id FROM production_material_stock_postings p JOIN stock_document_items item ON item.id=p.stock_document_item_id WHERE p.reservation_id=? AND p.posting_type='GOOD_RETURN'",f.reservation());
            reverseHistoryPosting(db,f,(UUID)returned.get("id"),"GOOD_RETURN_REVERSE",new BigDecimal("2"),6,-1,actor);
            db.update("UPDATE stock_reservations SET consumed_qty=5 WHERE id=?",f.reservation());
            db.update("UPDATE stock_balances SET qty=qty-2 WHERE id=(SELECT supply_id FROM stock_reservations WHERE id=?)",f.reservation());
            db.update("UPDATE stock_documents SET status=-1 WHERE id=?",returned.get("doc_id"));
            UUID issue=db.queryForObject("SELECT id FROM production_material_stock_postings WHERE reservation_id=? AND posting_type='ISSUE'",UUID.class,f.reservation());
            reverseHistoryPosting(db,f,issue,"ISSUE_REVERSE",new BigDecimal("5"),5,1,actor);
            db.update("UPDATE stock_balances SET qty=qty+5 WHERE id=(SELECT supply_id FROM stock_reservations WHERE id=?)",f.reservation());
            db.update("UPDATE stock_reservations SET consumed_qty=0 WHERE id=?",f.reservation());
            db.update("UPDATE stock_document_items SET issued_qty=0 WHERE id=(SELECT stock_document_item_id FROM production_material_stock_postings WHERE id=?)",issue);
        });
        migrate(database.url(),"619");
        qty(db,"0","SELECT consumed_qty FROM stock_reservations WHERE id=?",f.reservation());
        qty(db,"0","SELECT SUM(net_issued_qty) FROM v_workshop_direct_source_allocations WHERE stock_reservation_id=?",f.reservation());
        assertThat(db.queryForObject("SELECT COUNT(*) FROM production_material_stock_postings WHERE reservation_id=?",Integer.class,f.reservation())).isEqualTo(4);
    }

    private static void reverseHistoryPosting(JdbcTemplate db,History history,UUID original,String type,BigDecimal qty,int movementType,int direction,UUID actor) {
        var row=db.queryForMap("SELECT p.stock_document_item_id,item.doc_id,item.unit_id,held.goods_id,held.warehouse_id FROM production_material_stock_postings p JOIN stock_document_items item ON item.id=p.stock_document_item_id JOIN stock_reservations held ON held.id=p.reservation_id WHERE p.id=?",original);
        UUID event=UUID.randomUUID(),posting=UUID.randomUUID(),movement=UUID.randomUUID();
        db.update("INSERT INTO production_material_stock_events(id,stock_document_id,event_type,idempotency_key,request_hash,created_by) VALUES(?,?,?,?,?,?)",event,row.get("doc_id"),type,"history-counter-"+event,"e".repeat(64),actor);
        db.update("INSERT INTO production_material_stock_postings(id,event_id,stock_document_item_id,demand_id,reservation_id,posting_type,qty_base,source_posting_id,created_by) VALUES(?,?,?,?,?,?,?,?,?)",posting,event,row.get("stock_document_item_id"),history.demand(),history.reservation(),type,qty,original,actor);
        db.update("INSERT INTO stock_movements(id,transaction_date,movement_type,source_doc_type,source_doc_id,source_item_id,goods_id,warehouse_id,direction,qty,unit_id,unit_rate,created_by) VALUES(?,now(),?,'STOCK_DOC',?,?,?,?,?,?,?,1,?)",movement,movementType,row.get("doc_id"),row.get("stock_document_item_id"),row.get("goods_id"),row.get("warehouse_id"),direction,qty,row.get("unit_id"),actor);
        db.update("INSERT INTO production_material_movement_links(event_id,document_item_id,movement_id,created_by) VALUES(?,?,?,?)",event,row.get("stock_document_item_id"),movement,actor);
    }

    private static void migrate(String url,String version) {
        Flyway.configure().dataSource(url,username,password).locations("classpath:db/migration").target(version).load().migrate();
    }
    private record Task(UUID plan,UUID item,UUID pack,UUID segment) {}
    private record History(UUID reservation,UUID demand,UUID parentPlan) {}

    private static History seed(JdbcTemplate db,boolean multiple) {
        return seed(db,multiple,false);
    }

    private static History seed(JdbcTemplate db,boolean multiple,boolean overclaimed) {
        return seed(db,multiple,overclaimed,true);
    }

    private static History seed(JdbcTemplate db,boolean multiple,boolean overclaimed,boolean startParent) {
        var fixture=new FullChainEndToEndTest();ReflectionTestUtils.setField(fixture,"jdbc",db);
        var w=fixture.seedWorld(multiple?"history615-many":"history615-one");
        db.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,w.superAdminUserId().toString());
        UUID workshop=db.queryForObject("SELECT id FROM departments WHERE code='WS_ZHUSU'",UUID.class);
        UUID worker=w.employeeId(),rack=UUID.randomUUID(),component=UUID.randomUUID(),product=UUID.randomUUID();
        db.update("UPDATE employees SET department_id=? WHERE id=?",workshop,worker);
        db.update("INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable,is_line_side,workshop_department_id) VALUES(?,?,?,?,'使用',true,true,?)",rack,"hist-rack-"+rack,"history rack",w.warehouseId(),workshop);
        fixture.insertGoods(component,"hist-c-"+component,"history component","自制",w.unitId(),w.unitLegacy());
        fixture.insertGoods(product,"hist-p-"+product,"history parent","自制",w.unitId(),w.unitLegacy());
        fixture.insertBom(component,w.goodsD(),"1");
        db.update("UPDATE goods_bom_items SET hard_gate=false,control_stage='REFERENCE' WHERE goods_id=?",component);
        fixture.insertBom(product,component,"1");
        Task producer=task(db,w,component,workshop,worker,true);
        Task parent=task(db,w,product,workshop,worker,false);
        db.update("INSERT INTO subplan_links(plan_id,subplan_id,created_by) VALUES(?,?,?)",parent.plan(),producer.plan(),w.superAdminUserId());
        UUID demand=UUID.randomUUID();
        db.update("""
                INSERT INTO production_material_demands(id,package_id,plan_id,warehouse_id,goods_id,unit_id,required_qty,
                  supply_route,status,idempotency_key,execution_segment_id,source_plan_item_id,per_product_qty,requirement_mode)
                VALUES(?,?,?,?,?,?,10,'MAKE','ALLOCATED',?,?,?,1,'LINEAR')
                """,demand,parent.pack(),parent.plan(),w.warehouseId(),component,w.unitId(),"hist-demand-"+demand,parent.segment(),parent.item());
        int count=multiple?2:1;
        for(int i=0;i<count;i++)receipt(db,w,producer,parent,demand,rack,component,workshop,worker,multiple||overclaimed?"5":"10");
        UUID balance=UUID.randomUUID(),reservation=UUID.randomUUID();
        db.update("INSERT INTO stock_balances(id,goods_id,warehouse_id,qty) VALUES(?,?,?,?)",balance,component,rack,overclaimed?5:10);
        db.update("""
                INSERT INTO stock_reservations(id,goods_id,warehouse_id,qty,consumed_qty,released_qty,status,source,
                  source_doc_type,source_doc_id,owner_type,owner_id,purpose,demand_id,supply_type,supply_id,idempotency_key)
                VALUES(?,?,?,10,0,?,0,0,'PRODUCTION_PLANNING_PACKAGE',?,'PRODUCTION_MATERIAL_DEMAND',?,'PRODUCTION_MATERIAL',?,'STOCK_BALANCE',?,?)
                """,reservation,component,rack,overclaimed?5:0,parent.pack(),demand,demand,balance,"hist-held-"+reservation);
        UUID draw=stockDocument(db,w,"DRAW",rack,workshop,null),drawItem=stockItem(db,w,draw,"DRAW",component,overclaimed?"5":multiple?"10":"6",null,null,null);
        db.update("INSERT INTO production_planning_package_documents(package_id,execution_segment_id,document_type,document_id,document_no,created_by) VALUES(?,?,'DRAW',?,'historical draw',?)",parent.pack(),parent.segment(),draw,w.superAdminUserId());
        db.update("INSERT INTO production_planning_package_document_items(package_id,demand_id,document_type,document_id,document_item_id,created_by) VALUES(?,?,'DRAW',?,?,?)",parent.pack(),demand,draw,drawItem,w.superAdminUserId());
        if(overclaimed) {
            db.update("UPDATE stock_reservations SET released_qty=5 WHERE id=?",reservation);
            return new History(reservation,demand,parent.plan());
        }
        UUID issue=posting(db,w,draw,drawItem,demand,reservation,rack,component,"ISSUE","5",null);
        db.update("UPDATE stock_document_items SET issued_qty=5 WHERE id=?",drawItem);
        db.update("UPDATE stock_reservations SET consumed_qty=5 WHERE id=?",reservation);
        db.update("UPDATE stock_balances SET qty=5 WHERE id=?",balance);
        if(startParent)start(db,parent.segment());
        if(!multiple) {
            UUID returned=stockDocument(db,w,"WDRAW",rack,workshop,null);
            UUID returnItem=stockItem(db,w,returned,"WDRAW",component,"2",null,null,drawItem);
            posting(db,w,returned,returnItem,demand,reservation,rack,component,"GOOD_RETURN","2",issue);
            db.update("UPDATE stock_reservations SET consumed_qty=3,released_qty=4 WHERE id=?",reservation);
            db.update("UPDATE stock_balances SET qty=7 WHERE id=?",balance);
        }
        return new History(reservation,demand,parent.plan());
    }

    private static Task task(JdbcTemplate db,FullChainEndToEndTest.World w,UUID product,UUID workshop,UUID worker,boolean producer) {
        UUID plan=UUID.randomUUID(),item=UUID.randomUUID(),pack=UUID.randomUUID(),segment=UUID.randomUUID();
        String number=number(db,"PRODUCTION_PLAN");
        db.update("INSERT INTO production_plans(id,bill_no,bill_date,status,maker_id,department_id,worker_id) VALUES(?,?,CURRENT_DATE,1,?,?,?)",plan,number,w.employeeId(),workshop,worker);
        db.update("INSERT INTO production_plan_items(id,plan_id,bill_no,bill_date,line_no,product_no,goods_id,unit_id,unit_rate,qty,fqty) VALUES(?,?,?,CURRENT_DATE,1,?,?,?,1,10,?)",item,plan,number,"hist-product-"+item,product,w.unitId(),producer?10:0);
        db.update("INSERT INTO production_planning_packages(id,plan_id,warehouse_id,idempotency_key,request_hash,preview_fingerprint,status,execution_model_version) VALUES(?,?,?, ?,?,?,'CONFIRMED',1)",pack,plan,w.warehouseId(),"hist-pack-"+pack,"a".repeat(64),"b".repeat(64));
        db.update("""
                INSERT INTO production_execution_segments(id,package_id,plan_id,source_plan_item_id,segment_no,segment_code,client_segment_key,
                  product_goods_id,product_unit_id,product_unit_rate,planned_qty,status,bom_fingerprint,idempotency_key,
                  material_requirement_mode,zero_material_reason,workshop_department_id,responsible_employee_id,
                  start_route,continuous_supply,route_confirmed_at)
                VALUES(?,?,?,?,1,?,?,?, ?,1,10,'READY',?,?,?, ?,?,? ,?, ?,now())
                """,segment,pack,plan,item,number(db,"PRODUCTION_EXECUTION_SEGMENT"),"hist-segment-"+segment,product,w.unitId(),"c".repeat(64),"hist-key-"+segment,
                producer?"ZERO_MATERIAL":"DEMANDED",producer?"NO_PRODUCTION_HARD_GATE":null,workshop,worker,producer?"FULL_KIT":"CONTINUOUS",!producer);
        if(producer)start(db,segment);
        return new Task(plan,item,pack,segment);
    }

    private static void start(JdbcTemplate db,UUID segment) {
        db.update("UPDATE production_execution_segments SET status='DISPATCHED',plan_begin_date=CURRENT_DATE,plan_end_date=CURRENT_DATE WHERE id=?",segment);
        db.update("UPDATE production_execution_segments SET status='IN_PROGRESS' WHERE id=?",segment);
    }

    private static void receipt(JdbcTemplate db,FullChainEndToEndTest.World w,Task producer,Task parent,UUID demand,UUID rack,UUID goods,UUID workshop,UUID worker,String qty) {
        UUID report=UUID.randomUUID(),reportItem=UUID.randomUUID(),transfer=UUID.randomUUID(),inspection=UUID.randomUUID(),decision=UUID.randomUUID();
        String reportNo=number(db,"PRODUCTION_DAILY_REPORT");
        db.update("INSERT INTO production_daily_reports(id,bill_no,bill_date,warehouse_id,department_id,maker_id,status) VALUES(?,?,CURRENT_DATE,?,?,?,1)",report,reportNo,w.warehouseId(),workshop,worker);
        db.update("INSERT INTO production_daily_report_items(id,report_id,bill_no,bill_date,line_no,plan_item_id,execution_segment_id,goods_id,unit_id,unit_rate,qty,destination,direct_transfer_demand_id) VALUES(?,?,?,CURRENT_DATE,1,?,?,?,?,1,?,'WORKSHOP',?)",reportItem,report,reportNo,producer.item(),producer.segment(),goods,w.unitId(),new BigDecimal(qty),demand);
        db.update("INSERT INTO production_workshop_direct_transfers(id,source_report_id,line_side_warehouse_id,workshop_department_id,idempotency_key,created_by) VALUES(?,?,?,?,?,?)",transfer,report,rack,workshop,"hist-transfer-"+transfer,w.superAdminUserId());
        db.update("INSERT INTO production_workshop_direct_transfer_items(transfer_id,source_report_item_id,to_execution_segment_id,to_demand_id,qty) VALUES(?,?,?,?,?)",transfer,reportItem,parent.segment(),demand,new BigDecimal(qty));
        db.update("INSERT INTO production_fqc_inspections(id,source_report_id,source_report_item_id,source_plan_item_id,execution_segment_id,warehouse_id,goods_id,unit_id,unit_rate,reported_qty,report_maker_id,inspection_kind,created_by) VALUES(?,?,?,?,?,?,?,?,1,?,?,'WORKSHOP_SELF',?)",inspection,report,reportItem,producer.item(),producer.segment(),rack,goods,w.unitId(),new BigDecimal(qty),worker,w.superAdminUserId());
        db.update("INSERT INTO production_fqc_decision_events(id,inspection_id,decision,pass_qty,fail_qty,idempotency_key,request_hash,decided_by_employee_id,created_by) VALUES(?,?,'PASS',?,0,?,?,?,?)",decision,inspection,new BigDecimal(qty),"hist-pass-"+decision,"d".repeat(64),worker,w.superAdminUserId());
        UUID document=stockDocument(db,w,"FINISHED_IN",rack,workshop,report);
        UUID incoming=stockItem(db,w,document,"FINISHED_IN",goods,qty,reportItem,producer.segment(),producer.item());
        movement(db,w,document,incoming,rack,goods,13,1,new BigDecimal(qty));
    }

    private static UUID stockDocument(JdbcTemplate db,FullChainEndToEndTest.World w,String type,UUID warehouse,UUID workshop,UUID report) {
        UUID id=UUID.randomUUID();db.update("INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,warehouse_id,department_id,maker_id,status,source_daily_report_id) VALUES(?,?,?,CURRENT_DATE,?,?,?,1,?)",id,type,number(db,"STOCK_"+type),warehouse,workshop,w.employeeId(),report);return id;
    }
    private static UUID stockItem(JdbcTemplate db,FullChainEndToEndTest.World w,UUID document,String type,UUID goods,String qty,UUID reportItem,UUID segment,UUID upstream) {
        UUID id=UUID.randomUUID();db.update("INSERT INTO stock_document_items(id,doc_id,bill_type,bill_no,bill_date,line_no,goods_id,unit_id,unit_rate,qty,base_qty,source_daily_report_item_id,execution_segment_id,upstream_item_id,goods_snapshot_source) VALUES(?,?,?,(SELECT bill_no FROM stock_documents WHERE id=?),CURRENT_DATE,1,?,?,1,?,?,?,?,?,'MASTER_AT_SAVE')",id,document,type,document,goods,w.unitId(),new BigDecimal(qty),new BigDecimal(qty),reportItem,segment,upstream);return id;
    }
    private static UUID movement(JdbcTemplate db,FullChainEndToEndTest.World w,UUID doc,UUID item,UUID warehouse,UUID goods,int type,int direction,BigDecimal qty) {
        UUID id=UUID.randomUUID();db.update("INSERT INTO stock_movements(id,transaction_date,movement_type,source_doc_type,source_doc_id,source_item_id,goods_id,warehouse_id,direction,qty,unit_id,unit_rate,created_by) VALUES(?,now(),?,'STOCK_DOC',?,?,?,?,?,?,?,1,?)",id,type,doc,item,goods,warehouse,direction,qty,w.unitId(),w.superAdminUserId());return id;
    }
    private static UUID posting(JdbcTemplate db,FullChainEndToEndTest.World w,UUID doc,UUID item,UUID demand,UUID reservation,UUID warehouse,UUID goods,String type,String qty,UUID source) {
        UUID event=UUID.randomUUID(),post=UUID.randomUUID();db.update("INSERT INTO production_material_stock_events(id,stock_document_id,event_type,idempotency_key,request_hash,created_by) VALUES(?,?,?,?,?,?)",event,doc,type,"hist-material-"+event,"e".repeat(64),w.superAdminUserId());
        db.update("INSERT INTO production_material_stock_postings(id,event_id,stock_document_item_id,demand_id,reservation_id,posting_type,qty_base,source_posting_id,created_by) VALUES(?,?,?,?,?,?,?,?,?)",post,event,item,demand,reservation,type,new BigDecimal(qty),source,w.superAdminUserId());
        UUID movement=movement(db,w,doc,item,warehouse,goods,type.equals("ISSUE")?5:6,type.equals("ISSUE")?-1:1,new BigDecimal(qty));
        db.update("INSERT INTO production_material_movement_links(event_id,document_item_id,movement_id,created_by) VALUES(?,?,?,?)",event,item,movement,w.superAdminUserId());return post;
    }
    private static String facts(JdbcTemplate db,History f) {
        return db.queryForObject("SELECT jsonb_build_object('reservation',(SELECT to_jsonb(r) FROM stock_reservations r WHERE id=?),'postings',(SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) FROM production_material_stock_postings p WHERE reservation_id=?),'movements',(SELECT jsonb_agg(to_jsonb(m) ORDER BY m.id) FROM stock_movements m JOIN production_material_movement_links l ON l.movement_id=m.id JOIN production_material_stock_postings p ON p.event_id=l.event_id AND p.stock_document_item_id=l.document_item_id WHERE p.reservation_id=?))::text",String.class,f.reservation(),f.reservation(),f.reservation());
    }
    private static void qty(JdbcTemplate db,String expected,String sql,Object... args){assertThat(db.queryForObject(sql,BigDecimal.class,args)).isEqualByComparingTo(expected);}
    private static String number(JdbcTemplate db,String namespace) {
        return db.queryForObject("""
                WITH allocated AS (INSERT INTO business_document_sequences(namespace_key,sequence_date,last_seq)
                VALUES(?,(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai')::date,1)
                ON CONFLICT(namespace_key,sequence_date) DO UPDATE SET last_seq=business_document_sequences.last_seq+1
                RETURNING namespace_key,sequence_date,last_seq)
                SELECT registry.fixed_prefix||CASE WHEN registry.identifier_family='SYSTEM'
                  THEN lpad(allocated.last_seq::text,8,'0')
                  ELSE to_char(allocated.sequence_date,'YYYYMMDD')||lpad(allocated.last_seq::text,6,'0') END
                FROM allocated JOIN business_identifier_namespaces registry USING(namespace_key)
                """,String.class,namespace);
    }
}
