package com.uten.imp.businesschain;

import com.uten.imp.testsupport.FixtureDatabaseProperties;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.math.BigDecimal;
import java.util.Map;
import java.util.List;
import java.util.UUID;
import javax.sql.DataSource;
import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.MigrationVersion;
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
@SpringBootTest(properties={"spring.profiles.active=dev","spring.flyway.target=1031",
        "uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.inventory.value-work.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=false",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only", // gitleaks:allow synthetic fixture.
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", // gitleaks:allow synthetic fixture.
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class IqcExactProofUpgradeEndToEndTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder(){return new DirtiesContextTestExecutionListener().getOrder()-1;}
        @Override public void afterTestClass(TestContext ignored){PG.stop();}
    }
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){PG.start();FixtureDatabaseProperties.bindSameRole(registry,PG::getJdbcUrl,PG::getUsername,PG::getPassword);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired DataSource data;
    @Autowired JdbcTemplate db;
    @Autowired MockMvc http;
    @Autowired ObjectMapper json;
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void realLegacyRowsRetainTheirOldProofWhileEveryNewFactHasExactEvidence()throws Exception {
        var helper=new ProcurementOrderClosureEndToEndTest();beans.autowireBean(helper);helper.setup();
        var old=helper.fixture("iqc-before-exact-proof","0");UUID oldReceipt=helper.receipt(old,"4","0");helper.finishExistingIqc(old,oldReceipt);
        String before=facts(oldReceipt,false);
        UUID[] legacy=helper.legacyUnknownOrder(old.world());
        String oldOrder=db.queryForObject("SELECT to_jsonb(o)::text FROM purchase_orders o WHERE id=?",String.class,legacy[0]);
        String oldItem=db.queryForObject("SELECT to_jsonb(i)::text FROM purchase_order_items i WHERE id=?",String.class,legacy[1]);
        Flyway.configure().dataSource(data).locations("classpath:db/migration").target(MigrationVersion.LATEST).load().migrate();
        assertThat(facts(oldReceipt,true)).isEqualTo(before);
        helper.assertLegacyUnknownOrderReadOnly(legacy[0],legacy[1],oldOrder,oldItem);
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
        String value=after?"to_jsonb(value)-'numeric_proof_version'-'business_precision_policy'":"to_jsonb(value)";
        return db.queryForObject("SELECT jsonb_build_object('events',(SELECT jsonb_agg("+value+" ORDER BY value.id) FROM procurement_inspection_events value JOIN procurement_inspection_items inspection ON inspection.id=value.inspection_item_id WHERE inspection.receipt_id=?),'items',(SELECT jsonb_agg("+value+" ORDER BY value.id) FROM procurement_iqc_stock_in_batch_items value JOIN procurement_iqc_stock_in_batches batch ON batch.id=value.batch_id WHERE batch.receipt_id=?))::text",String.class,receipt,receipt);
    }
}
