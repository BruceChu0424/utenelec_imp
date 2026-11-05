package com.uten.imp.businesschain;

import com.uten.imp.testsupport.FixtureDatabaseProperties;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.math.BigDecimal;
import java.util.Map;
import java.util.List;
import java.util.UUID;
import javax.sql.DataSource;
import com.uten.imp.testsupport.HistoricalJdbcNativeSql;
import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.boot.webmvc.test.autoconfigure.MockMvcPrint;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.*;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.*;
import static com.uten.imp.testsupport.BusinessHttpRequests.authenticated;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/** Actual protected receipt/PASS/stock-in facts exist before V1032; none are retagged as legacy by a test. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
@TestExecutionListeners(listeners=IqcExactProofUpgradeEndToEndTest.Cleanup.class,mergeMode=TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
@SpringBootTest(properties={"spring.profiles.active=dev",
        "uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.inventory.value-work.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=false",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only", // gitleaks:allow synthetic fixture.
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", // gitleaks:allow synthetic fixture.
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class IqcExactProofUpgradeEndToEndTest {
    private static final String MIGRATIONS=snapshotMigrations();
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    private static UUID oldReceipt;
    private static UUID oldActor;
    private static UUID[] legacy;
    private static String before,oldOrder,oldItem,upgradedOrder,upgradedItem;
    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder(){return new DirtiesContextTestExecutionListener().getOrder()-1;}
        @Override public void afterTestClass(TestContext ignored){PG.stop();}
    }
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry)throws Exception {
        PG.start();
        var source=new org.springframework.jdbc.datasource.DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        TestFlyway.configure().dataSource(source).locations(MIGRATIONS).target("1031").load().migrate();
        var oldDb=new JdbcTemplate(source);
        var harness=new FullChainEndToEndTest();ReflectionTestUtils.setField(harness,"jdbc",oldDb);
        var world=harness.seedWorld("iqc-before-exact-proof");
        oldActor=world.superAdminUserId();
        var transactions=new org.springframework.transaction.support.TransactionTemplate(new org.springframework.jdbc.datasource.DataSourceTransactionManager(source));
        var statements=HistoricalJdbcNativeSql.statements(oldDb);
        var numbers=new com.uten.imp.common.docnumber.DocNumberService(statements);
        oldReceipt=transactions.execute(status->{
            oldDb.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,world.superAdminUserId().toString());
            UUID order=UUID.randomUUID(),orderItem=UUID.randomUUID(),receipt=UUID.randomUUID(),item=UUID.randomUUID(),inspection=UUID.randomUUID();
            String orderNo=numbers.nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.PURCHASE_ORDER);
            String receiptNo=numbers.nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.PURCHASE_RECEIPT);
            oldDb.update("INSERT INTO purchase_orders(id,bill_no,bill_date,supplier_id,warehouse_id,currency_id,exchange_rate,total_original,total_local,maker_id,status,quantity_semantics) VALUES(?,?,CURRENT_DATE,?,?,?,1,100,100,?,1,'CHARGED_PLUS_GIFT_V1')",order,orderNo,world.supplierId(),world.warehouseId(),world.currencyId(),world.employeeId());
            oldDb.update("INSERT INTO purchase_order_items(id,bill_no,bill_date,order_id,line_no,goods_id,unit_id,unit_rate,qty,price,amount_original,amount_local,received_qty,returned_qty,goods_snapshot_source,quantity_semantics) VALUES(?,?,CURRENT_DATE,?,1,?,?,1,10,10,100,100,4,0,'MASTER_AT_SAVE','CHARGED_PLUS_GIFT_V1')",orderItem,orderNo,order,world.goodsD(),world.unitId());
            oldDb.update("INSERT INTO purchase_receipts(id,bill_no,bill_date,supplier_id,warehouse_id,currency_id,exchange_rate,total_original,total_local,maker_id,status,quantity_semantics) VALUES(?,?,CURRENT_DATE,?,?,?,1,40,40,?,1,'CHARGED_PLUS_GIFT_V1')",receipt,receiptNo,world.supplierId(),world.warehouseId(),world.currencyId(),world.employeeId());
            oldDb.update("INSERT INTO purchase_receipt_items(id,bill_no,bill_date,receipt_id,order_item_id,line_no,goods_id,unit_id,unit_rate,qty,price,amount_original,amount_local,replacement_intent,goods_snapshot_source,quantity_semantics,charged_base_qty,gift_base_qty) VALUES(?,?,CURRENT_DATE,?,?,1,?,?,1,4,10,40,40,'NORMAL','MASTER_AT_SAVE','CHARGED_PLUS_GIFT_V1',4,0)",item,receiptNo,receipt,orderItem,world.goodsD(),world.unitId());
            oldDb.execute((org.springframework.jdbc.core.ConnectionCallback<Void>)connection->{
                com.uten.imp.support.ProcurementReceiptFixtureSupport.postOriginalReceiptPayable(connection,"PURCHASE",receipt,world.superAdminUserId());
                oldDb.update("INSERT INTO procurement_receipt_consideration_parts(id,receipt_type,receipt_id,receipt_item_id,billing_mode,base_qty,nominal_original,nominal_local,payable_original,payable_local,created_by,quantity_tranche) VALUES(?,'PURCHASE',?,?,'STANDARD',4,40,40,40,40,?,'CHARGED')",UUID.randomUUID(),receipt,item,world.superAdminUserId());
                oldDb.update("INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,receipt_item_id,warehouse_id,goods_id,unit_id,unit_rate,received_base_qty,received_amount_local,quantity_tranche,status) VALUES(?,'PURCHASE',?,?,?,?,?,1,4,40,'CHARGED','PENDING')",inspection,receipt,item,world.warehouseId(),world.goodsD(),world.unitId());
                oldDb.update("INSERT INTO procurement_inspection_events(id,inspection_item_id,action,base_qty,actor_employee_id) VALUES(?,?,'RECEIVED',4,?)",UUID.randomUUID(),inspection,world.employeeId());
                oldDb.update("UPDATE procurement_inspection_items SET passed_base_qty=4,status='RESOLVED',passed_at=now() WHERE id=?",inspection);
                oldDb.update("INSERT INTO procurement_inspection_events(id,inspection_item_id,action,base_qty,reason,actor_employee_id,requires_warehouse_stock_in,released_amount_local) VALUES(?,?,'PASS',4,'原采购实际品质放行',?,true,40)",UUID.randomUUID(),inspection,world.employeeId());
                com.uten.imp.support.ProcurementReceiptFixtureSupport.appendExistingQualityConsideration(connection,"PURCHASE",receipt,world.superAdminUserId());
                return null;
            });
            return receipt;
        });
        stockHistoricalReceipt(oldDb,source,world,transactions);
        before=facts(oldDb,oldReceipt,false);
        // The original unknown-conversion fixture remains a genuine pre-V1033
        // imported order. It never passes a current new-row/import guard.
        legacy=transactions.execute(status->{
            oldDb.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,world.superAdminUserId().toString());
            UUID order=UUID.randomUUID(),item=UUID.randomUUID();int imported=940000000+Math.floorMod(order.hashCode(),1000000);
            String bill=numbers.nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.PURCHASE_ORDER);
            oldDb.update("INSERT INTO purchase_orders(id,legacy_id,bill_no,bill_date,supplier_id,warehouse_id,maker_id,status,is_closed,exchange_rate) VALUES(?,?,?,CURRENT_DATE,?,?,?,1,FALSE,NULL)",order,imported,bill,world.supplierId(),world.warehouseId(),world.employeeId());
            oldDb.update("INSERT INTO purchase_order_items(id,legacy_id,order_id,bill_no,bill_date,line_no,goods_id,unit_id,unit_rate,qty,received_qty,returned_qty,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at) SELECT ?,?,?,?,CURRENT_DATE,1,id,NULL,NULL,10,0,0,code,name,'LEGACY_IMPORT',now() FROM goods WHERE id=?",item,imported,order,bill,world.goodsD());
            return new UUID[]{order,item};
        });
        oldOrder=oldDb.queryForObject("SELECT to_jsonb(o)::text FROM purchase_orders o WHERE id=?",String.class,legacy[0]);
        oldItem=oldDb.queryForObject("SELECT to_jsonb(i)::text FROM purchase_order_items i WHERE id=?",String.class,legacy[1]);
        TestFlyway.configure().dataSource(source).locations(MIGRATIONS).load().migrate();
        assertThat(facts(oldDb,oldReceipt,true)).isEqualTo(before);
        assertHistoricalOrderColumns(oldDb);
        upgradedOrder=oldDb.queryForObject("SELECT to_jsonb(o)::text FROM purchase_orders o WHERE id=?",String.class,legacy[0]);
        upgradedItem=oldDb.queryForObject("SELECT (to_jsonb(i)-'quantity_adoption_version'-'quantity_precision_policy'-'charged_base_qty'-'gift_base_qty')::text FROM purchase_order_items i WHERE id=?",String.class,legacy[1]);
        FixtureDatabaseProperties.bindSameRole(registry,PG::getJdbcUrl,PG::getUsername,PG::getPassword);
        registry.add("spring.flyway.locations",()->MIGRATIONS);
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired DataSource data;
    @Autowired JdbcTemplate db;
    @Autowired MockMvc http;
    @Autowired ObjectMapper json;
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void realLegacyRowsRetainTheirOldProofWhileEveryNewFactHasExactEvidence()throws Exception {
        var helper=new ProcurementOrderClosureEndToEndTest();beans.autowireBean(helper);helper.setup();
        ((FullChainEndToEndTest)ReflectionTestUtils.getField(helper,"harness")).loginAs(oldActor);
        assertThat(facts(oldReceipt,true)).isEqualTo(before);
        helper.assertLegacyUnknownOrderReadOnly(legacy[0],legacy[1],upgradedOrder,upgradedItem);
        assertHistoricalOrderColumns(db);
        var weighed=helper.fixture("receipt-raw-weight-native-adoption","0");
        String rawWeight="1.0000000000000000000000001";UUID weighedReceipt;
        try(var policy=com.uten.imp.common.finance.BusinessPrecisionContext.use(Map.of("weight.kg-field",new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(24,"DOWN")))){
            weighedReceipt=ReflectionTestUtils.invokeMethod(helper,"receipt",weighed,"3","0",false,new BigDecimal(rawWeight));
        }
        assertThat(db.queryForObject("SELECT weight FROM purchase_receipt_items WHERE receipt_id=?",BigDecimal.class,weighedReceipt)).isEqualByComparingTo("1");
        assertThat(db.queryForObject("SELECT original_decimal FROM business_numeric_input_evidence WHERE owner_kind='PURCHASE_RECEIPT' AND owner_id=? AND field_key='actualWeightKg'",String.class,weighedReceipt)).isEqualTo(rawWeight);
        assertThat(db.queryForObject("SELECT received_weight FROM procurement_inspection_items WHERE receipt_id=?",BigDecimal.class,weighedReceipt)).isEqualByComparingTo("1");
        var wire=helper.fixture("iqc-real-http-native-quantity","0");
        UUID pending=ReflectionTestUtils.invokeMethod(helper,"receipt",wire,"3","0",false);
        UUID inspection=db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_id=?",UUID.class,pending);
        var actor=SecurityContextHolder.getContext().getAuthentication();String tiny="0.000000000000000000000001";
        String path="/api/procurement/inspection/PURCHASE/"+pending+"/"+inspection+"/dispose";
        var request=Map.of("action","PASS","baseQty",tiny,"reason","匿名HTTP真实小数","idempotencyKey","iqc-http-native-tiny");
        var passed=http.perform(post(path).with(authenticated(actor)).contentType("application/json").content(json.writeValueAsBytes(request))).andReturn().getResponse();
        assertThat(passed.getStatus()).as(passed.getContentAsString()).isEqualTo(200);
        var rejected=http.perform(post(path).with(authenticated(actor)).contentType("application/json").content(json.writeValueAsBytes(Map.of("action","PASS","baseQty","1e-25","idempotencyKey","iqc-http-too-many-places")))).andReturn().getResponse();
        assertThat(rejected.getStatus()).isIn(400,422);
        assertThat(db.queryForObject("SELECT count(*) FROM procurement_inspection_events WHERE inspection_item_id=? AND action='PASS'",Integer.class,inspection)).isEqualTo(1);
        UUID pass=db.queryForObject("SELECT id FROM procurement_inspection_events WHERE inspection_item_id=? AND action='PASS'",UUID.class,inspection);
        var harness=(FullChainEndToEndTest)ReflectionTestUtils.getField(helper,"harness");harness.loginAs(wire.world().superAdminUserId());harness.loginAs(harness.createIqcWarehouseConfirmer(wire.world(),"iqc-http-native-warehouse"));
        var warehouseActor=SecurityContextHolder.getContext().getAuthentication();
        var confirmation=Map.of("idempotencyKey","iqc-http-native-confirm","items",List.of(Map.of("passEventId",pass.toString(),"baseQty",tiny,"expectedRemainingBaseQty",tiny,"warehouseId",wire.world().warehouseId().toString(),"place","HTTP-A")));
        var confirmed=http.perform(post("/api/warehouse/iqc-stock-ins/PURCHASE/"+pending+"/confirm").with(authenticated(warehouseActor)).contentType("application/json").content(json.writeValueAsBytes(confirmation))).andReturn().getResponse();
        assertThat(confirmed.getStatus()).as(confirmed.getContentAsString()).isEqualTo(200);
        assertThat(db.queryForObject("SELECT base_qty FROM procurement_iqc_stock_in_batch_items WHERE pass_event_id=?",BigDecimal.class,pass)).isEqualByComparingTo("1e-24");
        assertThat(db.queryForObject("SELECT bool_and(event.numeric_proof_version=1 AND event.business_precision_policy IS NULL) FROM procurement_inspection_events event JOIN procurement_inspection_items inspection ON inspection.id=event.inspection_item_id WHERE inspection.receipt_id=?",Boolean.class,oldReceipt)).isTrue();
        assertThat(db.queryForObject("SELECT bool_and(item.numeric_proof_version=1 AND item.business_precision_policy IS NULL) FROM procurement_iqc_stock_in_batch_items item JOIN procurement_iqc_stock_in_batches batch ON batch.id=item.batch_id WHERE batch.receipt_id=?",Boolean.class,oldReceipt)).isTrue();
        var fresh=helper.fixture("iqc-after-exact-proof","0");UUID receipt=helper.receipt(fresh,"9.999999999999999999999999","0");helper.finishExistingIqc(fresh,receipt);
        assertThat(db.queryForObject("SELECT bool_and(event.numeric_proof_version=2 AND event.business_precision_policy IS NOT NULL) FROM procurement_inspection_events event JOIN procurement_inspection_items inspection ON inspection.id=event.inspection_item_id WHERE inspection.receipt_id=?",Boolean.class,receipt)).isTrue();
        assertThat(db.queryForObject("SELECT bool_and(item.numeric_proof_version=2 AND item.business_precision_policy IS NOT NULL) FROM procurement_iqc_stock_in_batch_items item JOIN procurement_iqc_stock_in_batches batch ON batch.id=item.batch_id WHERE batch.receipt_id=?",Boolean.class,receipt)).isTrue();
        assertThatThrownBy(()->db.update("INSERT INTO procurement_inspection_events SELECT (jsonb_populate_record(NULL::procurement_inspection_events,to_jsonb(event)||jsonb_build_object('id',?::uuid,'numeric_proof_version',1,'business_precision_policy',NULL))).* FROM procurement_inspection_events event JOIN procurement_inspection_items inspection ON inspection.id=event.inspection_item_id WHERE inspection.receipt_id=? LIMIT 1",UUID.randomUUID(),receipt)).hasMessageContaining("new IQC facts require an exact proof version");
        assertThat(facts(oldReceipt,true)).isEqualTo(before);
    }
    private String facts(UUID receipt,boolean after){
        return facts(db,receipt,after);
    }
    private static String facts(JdbcTemplate db,UUID receipt,boolean after){
        String value=after?"to_jsonb(value)-'numeric_proof_version'-'business_precision_policy'":"to_jsonb(value)";
        return db.queryForObject("SELECT jsonb_build_object('events',(SELECT jsonb_agg("+value+" ORDER BY value.id) FROM procurement_inspection_events value JOIN procurement_inspection_items inspection ON inspection.id=value.inspection_item_id WHERE inspection.receipt_id=?),'items',(SELECT jsonb_agg("+value+" ORDER BY value.id) FROM procurement_iqc_stock_in_batch_items value JOIN procurement_iqc_stock_in_batches batch ON batch.id=value.batch_id WHERE batch.receipt_id=?))::text",String.class,receipt,receipt);
    }

    private static void assertHistoricalOrderColumns(JdbcTemplate db) {
        // New provenance columns do not replace any original historical field.
        assertThat(db.queryForObject("SELECT (SELECT jsonb_object_agg(key,value) FROM jsonb_each(to_jsonb(o)) WHERE key IN(SELECT jsonb_object_keys(CAST(? AS jsonb))))::text FROM purchase_orders o WHERE id=?",String.class,oldOrder,legacy[0])).isEqualTo(oldOrder);
        assertThat(db.queryForObject("SELECT (SELECT jsonb_object_agg(key,value) FROM jsonb_each(to_jsonb(i)) WHERE key IN(SELECT jsonb_object_keys(CAST(? AS jsonb))))::text FROM purchase_order_items i WHERE id=?",String.class,oldItem,legacy[1])).isEqualTo(oldItem);
    }

    /** Same acquisition, quality custody and stock writer as the current receipt
     * fixture, executed as native JDBC against the real historical catalog. */
    private static void stockHistoricalReceipt(JdbcTemplate db,DataSource source,FullChainEndToEndTest.World world,
            org.springframework.transaction.support.TransactionTemplate transactions) {
        var named=new org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate(source);
        var mutex=new com.uten.imp.features.stock.InventoryMutationLock(HistoricalJdbcNativeSql.statements(db));
        var evidence=new com.uten.imp.features.stock.valuation.ProcurementCostSourceEvidenceService(named);
        var positions=new com.uten.imp.features.stock.valuation.InventoryPositionService(named,mutex,java.util.Optional.of(evidence::approved));
        transactions.executeWithoutResult(status->{
            UUID actor=world.superAdminUserId();
            db.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,actor.toString());
            var row=db.queryForMap("""
                    SELECT inspection.id inspection,pass.id pass,part.id part,quality.id quality
                    FROM procurement_inspection_items inspection
                    JOIN procurement_inspection_events pass ON pass.inspection_item_id=inspection.id AND pass.action='PASS'
                    JOIN procurement_iqc_quality_consideration_parts quality ON quality.inspection_event_id=pass.id
                    JOIN procurement_receipt_consideration_parts part ON part.id=quality.consideration_part_id
                    WHERE inspection.receipt_id=?
                    """,oldReceipt);
            UUID inspection=(UUID)row.get("inspection"),pass=(UUID)row.get("pass"),part=(UUID)row.get("part"),quality=(UUID)row.get("quality");
            var pool=new com.uten.imp.application.port.InventoryValuationPort.PoolKey(world.warehouseId(),world.goodsD(),null);
            mutex.lock(new com.uten.imp.features.stock.InventoryKey(world.goodsD(),null));
            UUID balance=UUID.randomUUID();db.update("INSERT INTO stock_balances(id,warehouse_id,goods_id,qty,amount_local) VALUES(?,?,?,0,0)",balance,world.warehouseId(),world.goodsD());
            var acquired=positions.acquire(new com.uten.imp.application.port.InventoryPositionPort.Acquire(
                    context(world,"PROCUREMENT_ACQUIRE",part,oldReceipt,part),pool,part,1,
                    com.uten.imp.application.port.InventoryPositionPort.Owner.QUALITY_PENDING,part,List.of()));
            var passed=positions.move(new com.uten.imp.application.port.InventoryPositionPort.Move(
                    context(world,"PROCUREMENT_QUALITY",quality,pass,quality),pool,
                    com.uten.imp.application.port.InventoryPositionPort.Owner.QUALITY_PASSED,quality,
                    List.of(new com.uten.imp.application.port.InventoryPositionPort.Slice(acquired.positionRootId(),new BigDecimal("4"),quality))));
            UUID batch=UUID.randomUUID(),item=UUID.randomUUID(),movement=UUID.randomUUID(),stockPart=UUID.randomUUID();
            db.update("INSERT INTO procurement_iqc_stock_in_batches(id,actor_user_id,actor_employee_id,receipt_type,receipt_id,idempotency_key,request_hash,confirmed_count) VALUES(?,?,?,'PURCHASE',?,?,?,1)",batch,actor,world.employeeId(),oldReceipt,"historical-iqc-stock-"+batch,"f".repeat(64));
            db.update("INSERT INTO procurement_iqc_stock_in_batch_items(id,batch_id,position,inspection_item_id,pass_event_id,stock_movement_id,warehouse_id,goods_id,expected_remaining_base_qty,base_qty,amount_local,place_snapshot) VALUES(?,?,1,?,?,?,?,?,4,4,40,'CLOSE-BIN')",item,batch,inspection,pass,movement,world.warehouseId(),world.goodsD());
            db.update("INSERT INTO procurement_iqc_stock_consideration_parts(id,stock_in_item_id,quality_part_id,base_qty,amount_original,amount_local,created_by) VALUES(?,?,?,4,40,40,?)",stockPart,item,quality,actor);
            var stored=positions.store(new com.uten.imp.application.port.InventoryPositionPort.Store(
                    context(world,"PURCHASE_RECEIPT",movement,oldReceipt,item),movement,pool,BigDecimal.ZERO,
                    List.of(new com.uten.imp.application.port.InventoryPositionPort.Slice(passed.positionRootId(),new BigDecimal("4"),stockPart)),false));
            assertThat(stored.knownValueLocal()).isEqualByComparingTo("40");
            db.update("INSERT INTO stock_movements(id,transaction_date,movement_type,source_doc_type,source_doc_id,source_item_id,goods_id,warehouse_id,direction,qty,unit_id,unit_rate,amount_local) VALUES(?,now(),1,'PURCHASE_RECEIPT',?,?,?,?,1,4,?,1,?)",movement,oldReceipt,item,world.goodsD(),world.warehouseId(),world.unitId(),stored.knownValueLocal());
            db.update("UPDATE stock_balances SET qty=4,amount_local=? WHERE id=?",stored.knownValueLocal(),balance);
            db.update("UPDATE procurement_inspection_items SET warehouse_stocked_base_qty=4,warehouse_stocked_amount_local=40 WHERE id=?",inspection);
        });
    }

    private static com.uten.imp.application.port.InventoryValuationPort.EventContext context(
            FullChainEndToEndTest.World world,String kind,UUID event,UUID document,UUID item) {
        return new com.uten.imp.application.port.InventoryValuationPort.EventContext(event,kind,document,item,1,
                world.superAdminUserId(),world.employeeId(),kind+":"+event,java.time.OffsetDateTime.now());
    }

    private static String snapshotMigrations() {
        try {
            var source=java.nio.file.Path.of(java.util.Objects.requireNonNull(IqcExactProofUpgradeEndToEndTest.class.getClassLoader().getResource("db/migration")).toURI());
            var target=java.nio.file.Files.createTempDirectory("uten-iqc-exact-migrations-").toAbsolutePath().normalize();
            try(var paths=java.nio.file.Files.list(source)) {
                for(var file:paths.filter(path->path.getFileName().toString().endsWith(".sql")).sorted().toList()) {
                    byte[] bytes=java.nio.file.Files.readAllBytes(file);java.nio.file.Files.write(target.resolve(file.getFileName()),bytes);
                    if(!java.util.Arrays.equals(bytes,java.nio.file.Files.readAllBytes(file)))throw new IllegalStateException("Migration source changed while taking isolated snapshot");
                }
            }
            return "filesystem:"+target.toString().replace('\\','/');
        } catch(Exception failure) { throw new IllegalStateException("Cannot snapshot actual migration source",failure); }
    }
}
