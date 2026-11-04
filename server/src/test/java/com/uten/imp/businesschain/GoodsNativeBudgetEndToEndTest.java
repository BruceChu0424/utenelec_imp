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
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.transaction.PlatformTransactionManager;
import com.uten.imp.security.TxSessionVars;

/** Native goods values cross the real HTTP/service/DB boundary; old stored values remain unchanged. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
@TestExecutionListeners(listeners=GoodsNativeBudgetEndToEndTest.Cleanup.class,mergeMode=TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
@SpringBootTest(properties={"spring.profiles.active=dev","spring.flyway.target=1032",
        "uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.inventory.value-work.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=false",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only", // gitleaks:allow synthetic fixture.
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", // gitleaks:allow synthetic fixture.
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class GoodsNativeBudgetEndToEndTest {
    private static final String MIGRATIONS=snapshotMigrations();
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder(){return new DirtiesContextTestExecutionListener().getOrder()-1;}
        @Override public void afterTestClass(TestContext ignored){PG.stop();}
    }
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){PG.start();FixtureDatabaseProperties.bindSameRole(registry,PG::getJdbcUrl,PG::getUsername,PG::getPassword);registry.add("spring.flyway.locations",()->MIGRATIONS);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired DataSource data;
    @Autowired JdbcTemplate db;
    @Autowired MockMvc http;
    @Autowired ObjectMapper json;
    @Autowired PlatformTransactionManager transactions;
    @Autowired TxSessionVars tx;
    @AfterEach void logout(){SecurityContextHolder.clearContext();}
    private static final String FULL="1234567890123456789012345678901234567890.123456789012345678901234";
    @Test void migrationDoesNotRewriteHistoryAndActualHttpKeepsFullFactsAndCas()throws Exception {
        var harness=new FullChainEndToEndTest();beans.autowireBean(harness);var world=harness.seedWorld("goods-native-budget");harness.loginAs(world.superAdminUserId());
        db.update("UPDATE goods SET source_e=7.1234 WHERE id=?",world.goodsA());
        String before=db.queryForObject("SELECT jsonb_agg(to_jsonb(goods) ORDER BY id)::text FROM goods",String.class);
        Flyway.configure().dataSource(data).locations(MIGRATIONS).target(MigrationVersion.fromVersion("1034")).load().migrate();
        assertThat(db.queryForObject("SELECT jsonb_agg(to_jsonb(goods) ORDER BY id)::text FROM goods",String.class)).isEqualTo(before);
        assertThat(db.queryForObject("SELECT count(*) FROM goods_bom_material_cost_adoptions",Integer.class)).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM goods_bom_periodic_quantity_adoptions",Integer.class)).isZero();
        UUID category=UUID.randomUUID();db.update("INSERT INTO material_categories(id,code,name,level) VALUES(?,?,?,0)",category,"GOODS-NATIVE-CAT","匿名完整值分类");
        var actor=SecurityContextHolder.getContext().getAuthentication();
        var input=new java.util.LinkedHashMap<String,Object>();input.put("categoryId",category);input.put("name","匿名完整值货品");input.put("unitId",world.unitId());input.put("price",FULL);input.put("discount","0.123456789012345678901234");input.put("sourceE",FULL);input.put("workRate","99.123456789012345678901234");input.put("currencyId",world.currencyId());
        var created=http.perform(post("/api/master/goods").with(authenticated(actor)).contentType("application/json").content(json.writeValueAsBytes(input))).andReturn().getResponse();
        assertThat(created.getStatus()).as(created.getContentAsString()).isEqualTo(200);
        var result=json.readTree(created.getContentAsString());if(result.has("data"))result=result.get("data");
        UUID goods=UUID.fromString(result.get("id").asText());long version=result.get("version").asLong();
        assertThat(result.get("priceDisplayText").asText()).isEqualTo(FULL);assertThat(result.get("budgetExact").get("sourceE").asText()).isEqualTo(FULL);
        assertThat(db.queryForObject("SELECT source_e::text FROM goods WHERE id=?",String.class,goods)).isEqualTo(FULL);
        input.remove("price");input.remove("discount");input.remove("currencyId");input.remove("sourceE");input.remove("workRate");input.put("name","匿名只改名称");input.put("version",version);
        var saved=http.perform(put("/api/master/goods/"+goods).with(authenticated(actor)).contentType("application/json").content(json.writeValueAsBytes(input))).andReturn().getResponse();
        assertThat(saved.getStatus()).as(saved.getContentAsString()).isEqualTo(200);
        assertThat(db.queryForObject("SELECT price::text||'|'||zk::text||'|'||source_e::text FROM goods WHERE id=?",String.class,goods)).isEqualTo(FULL+"|0.123456789012345678901234|"+FULL);
        var stale=http.perform(put("/api/master/goods/"+goods).with(authenticated(actor)).contentType("application/json").content(json.writeValueAsBytes(input))).andReturn().getResponse();
        assertThat(stale.getStatus()).isEqualTo(409);
        var tooMany=new java.util.LinkedHashMap<>(input);tooMany.put("price","1e40");tooMany.remove("version");
        var rejected=http.perform(put("/api/master/goods/"+goods).with(authenticated(actor)).contentType("application/json").content(json.writeValueAsBytes(tooMany))).andReturn().getResponse();
        assertThat(rejected.getStatus()).isIn(400,422);assertThat(db.queryForObject("SELECT price::text FROM goods WHERE id=?",String.class,goods)).isEqualTo(FULL);
        long current=db.queryForObject("SELECT version FROM goods WHERE id=?",Long.class,goods);
        for(String suffix:List.of("subcontract-loss-policy","purchase-receipt-policy")){
            var policy=suffix.startsWith("subcontract")?Map.of("expectedVersion",current,"percent","1.123456789012345678901234"):Map.of("version",current,"allowedOverReceiptPct","1.123456789012345678901234");
            var response=http.perform(put("/api/master/goods/"+goods+"/"+suffix).with(authenticated(actor)).contentType("application/json").content(json.writeValueAsBytes(policy))).andReturn().getResponse();
            assertThat(response.getStatus()).as(response.getContentAsString()).isEqualTo(200);current=db.queryForObject("SELECT version FROM goods WHERE id=?",Long.class,goods);
        }
        assertThat(db.queryForObject("SELECT subcontract_allowed_loss_pct::text||'|'||purchase_allowed_over_receipt_pct::text FROM goods WHERE id=?",String.class,goods)).isEqualTo("1.123456789012345678901234|1.123456789012345678901234");
        // One real BOM source_e write freezes the actual inputs and adoption, never a later GET policy.
        var transaction=new TransactionTemplate(transactions);
        SecurityContextHolder.clearContext();
        assertThatThrownBy(()->transaction.executeWithoutResult(status->{tx.bind();db.update("UPDATE goods SET source_e=fn_goods_bom_material_cost(id),version=version+1 WHERE id=?",world.goodsA());}))
                .hasMessageContaining("requires the current transaction actor");
        assertThat(db.queryForObject("SELECT count(*) FROM goods_bom_material_cost_adoptions WHERE goods_id=?",Integer.class,world.goodsA())).isZero();
        harness.loginAs(world.superAdminUserId());
        transaction.executeWithoutResult(status->{tx.bind();db.update("UPDATE goods SET source_e=fn_goods_bom_material_cost(id),version=version+1 WHERE id=?",world.goodsA());});
        assertThat(db.queryForObject("SELECT count(*) FROM goods_bom_material_cost_adoptions WHERE goods_id=?",Integer.class,world.goodsA())).isEqualTo(1);
        assertThat(db.queryForObject("SELECT original_sources->'sources'->0->>'designQty' FROM goods_bom_material_cost_adoptions WHERE goods_id=?",String.class,world.goodsA())).isNotBlank();
        // Actual HTTP BOM write: raw qty/price, actual result, and the master-source formula share one transaction.
        var line=http.perform(post("/api/master/goods/"+goods+"/bom").with(authenticated(actor)).contentType("application/json")
                .content(json.writeValueAsBytes(Map.of("componentGoodsId",world.goodsD(),"qty","1","price",FULL)))).andReturn().getResponse();
        assertThat(line.getStatus()).as(line.getContentAsString()).isEqualTo(200);
        var lineJson=json.readTree(line.getContentAsString());if(lineJson.has("data")){lineJson=lineJson.get("data");}UUID row=UUID.fromString(lineJson.get("id").asText());
        assertThat(lineJson.get("priceText").asText()).isEqualTo(FULL);assertThat(lineJson.get("totalText").asText()).isEqualTo(FULL);
        assertThat(db.queryForObject("SELECT count(*) FROM business_numeric_input_evidence WHERE owner_kind='GOODS_BOM_LINE' AND owner_id=? AND source_row_id=?",Integer.class,goods,row)).isEqualTo(3);
        var more=Map.of("componentGoodsId",world.goodsD(),"qty","1.000000000000000000000001","price","1.000000000000000000000001");
        var noChoice=http.perform(put("/api/master/goods/"+goods+"/bom/"+row).with(authenticated(actor)).contentType("application/json").content(json.writeValueAsBytes(more))).andReturn().getResponse();
        assertThat(noChoice.getStatus()).as(noChoice.getContentAsString()).isEqualTo(422);
        assertThat(db.queryForObject("SELECT total::text FROM goods_bom_items WHERE id=?",String.class,row)).isEqualTo(FULL);
        var accepted=http.perform(put("/api/master/goods/"+goods+"/bom/"+row).with(authenticated(actor)).header("X-Uten-Precision-Choices",precision("goods.bom.line-amount"))
                .contentType("application/json").content(json.writeValueAsBytes(more))).andReturn().getResponse();
        assertThat(accepted.getStatus()).as(accepted.getContentAsString()).isEqualTo(200);
        assertThat(db.queryForObject("SELECT total FROM goods_bom_items WHERE id=?",BigDecimal.class,row)).isEqualByComparingTo("1.000000000000000000000002");
        assertThat(db.queryForObject("SELECT original_decimal FROM business_numeric_input_evidence WHERE owner_kind='GOODS_BOM_LINE' AND source_row_id=? AND field_key='total' ORDER BY created_at DESC LIMIT 1",String.class,row))
                .isEqualTo("1.000000000000000000000002000000000000000000000001");
        var summary=http.perform(put("/api/master/goods/"+goods+"/bom/"+row).with(authenticated(actor)).contentType("application/json")
                .content(json.writeValueAsBytes(Map.of("componentGoodsId",world.goodsD(),"summary","只改备注保原采用金额")))).andReturn().getResponse();
        assertThat(summary.getStatus()).as(summary.getContentAsString()).isEqualTo(200);
        assertThat(db.queryForObject("SELECT total FROM goods_bom_items WHERE id=?",BigDecimal.class,row)).isEqualByComparingTo("1.000000000000000000000002");
        assertThat(db.queryForObject("SELECT count(*) FROM business_numeric_input_evidence WHERE owner_kind='GOODS_BOM_LINE' AND source_row_id=? AND field_key='total'",Integer.class,row)).isEqualTo(2);
        // Switch an actual mass component from qty/basis to one periodic quantity, preserving the old basis.
        UUID kg=UUID.randomUUID(),material=UUID.randomUUID();
        db.update("INSERT INTO units(id,code,name,status) VALUES(?,?,'千克','使用')",kg,"KG-NATIVE-BOM");
        db.update("INSERT INTO unit_measurement_profiles(unit_id,measurement_dimension,mass_unit_code,provenance) VALUES(?,'MASS','KG','MANUAL_GOVERNANCE')",kg);
        db.update("INSERT INTO goods(id,code,name,source_type,status,unit_id,price,code_sequence) VALUES(?,?,?,'采购','使用',?,1,(SELECT coalesce(max(code_sequence),0)+1 FROM goods))",material,"NATIVE-KG-MATERIAL","匿名周期物料",kg);
        var add=http.perform(post("/api/master/goods/"+world.goodsA()+"/bom").with(authenticated(actor)).contentType("application/json")
                .content(json.writeValueAsBytes(Map.of("componentGoodsId",material,"qty","1","basisOutputQty","3","price","1")))).andReturn().getResponse();
        assertThat(add.getStatus()).as(add.getContentAsString()).isEqualTo(200);
        var batch=Map.of("idempotencyKey","goods-native-periodic-switch","items",List.of(Map.of("goodsId",material,"expectedVersion",0,"issueMethod","PERIODIC","periodicCostBasis","OWN","bulkPackageQty","1.123456789012345678901234","isRecycledMaterial",false)));
        var stop=http.perform(put("/api/master/goods/issue-method/batch").with(authenticated(actor)).contentType("application/json").content(json.writeValueAsBytes(batch))).andReturn().getResponse();
        assertThat(stop.getStatus()).as(stop.getContentAsString()).isEqualTo(422);
        assertThat(db.queryForObject("SELECT issue_method FROM goods WHERE id=?",String.class,material)).isEqualTo("ORDER");
        var switched=http.perform(put("/api/master/goods/issue-method/batch").with(authenticated(actor)).header("X-Uten-Precision-Choices",precision("goods.bom.periodic-per-piece"))
                .contentType("application/json").content(json.writeValueAsBytes(batch))).andReturn().getResponse();
        assertThat(switched.getStatus()).as(switched.getContentAsString()).isEqualTo(200);
        assertThat(db.queryForObject("SELECT original_sources->>'originalBasis' FROM goods_bom_periodic_quantity_adoptions WHERE component_goods_id=?",String.class,material)).isEqualTo("3");
        assertThat(db.queryForObject("SELECT qty FROM goods_bom_items WHERE goods_id=? AND component_goods_id=?",BigDecimal.class,world.goodsA(),material)).isEqualByComparingTo("0.333333333333333333333333");
        assertThat(db.queryForObject("SELECT bulk_package_qty FROM goods WHERE id=?",BigDecimal.class,material)).isEqualByComparingTo("1.123456789012345678901234");
        // A real preview exercises DB writes and rolls all of them back. Confirmation reuses its frozen choice.
        var staged=Map.of("action","ADD","targetGoodsIds",List.of(world.goodsC()),"componentGoodsIds",List.of(),
                "items",List.of(Map.of("componentGoodsId",material,"unitWeightGrams","1.234567890123456789012345","price","1","confirmUnusualWeight",true)));
        var preview=http.perform(post("/api/master/goods/bom/batch-maintenance/preview").with(authenticated(actor))
                .header("X-Uten-Precision-Choices",precision("goods.bom.periodic-per-piece")).contentType("application/json").content(json.writeValueAsBytes(staged))).andReturn().getResponse();
        assertThat(preview.getStatus()).as(preview.getContentAsString()).isEqualTo(200);
        assertThat(db.queryForObject("SELECT count(*) FROM goods_bom_periodic_quantity_adoptions WHERE goods_id=?",Integer.class,world.goodsC())).isZero();
        var reviewed=json.readTree(preview.getContentAsString());if(reviewed.has("data"))reviewed=reviewed.get("data");
        String token=reviewed.get("previewToken").asText();var commit=Map.of("previewToken",token,"confirmSharedChanges",true);
        var changed=http.perform(post("/api/master/goods/bom/batch-maintenance/commit").with(authenticated(actor))
                .header("X-Uten-Precision-Choices",precision("goods.bom.line-amount")).contentType("application/json").content(json.writeValueAsBytes(commit))).andReturn().getResponse();
        assertThat(changed.getStatus()).as(changed.getContentAsString()).isEqualTo(409);
        assertThat(db.queryForObject("SELECT count(*) FROM goods_bom_items WHERE goods_id=? AND component_goods_id=?",Integer.class,world.goodsC(),material)).isZero();
        var committed=http.perform(post("/api/master/goods/bom/batch-maintenance/commit").with(authenticated(actor))
                .contentType("application/json").content(json.writeValueAsBytes(commit))).andReturn().getResponse();
        assertThat(committed.getStatus()).as(committed.getContentAsString()).isEqualTo(200);
        assertThat(db.queryForObject("SELECT qty FROM goods_bom_items WHERE goods_id=? AND component_goods_id=?",BigDecimal.class,world.goodsC(),material)).isEqualByComparingTo("0.001234567890123456789012");
        assertThat(db.queryForObject("SELECT original_sources->>'originalQuantity' FROM goods_bom_periodic_quantity_adoptions WHERE goods_id=?",String.class,world.goodsC())).isEqualTo("1.234567890123456789012345");
        harness.loginAs(world.superAdminUserId());
        var frozen=db.queryForList("SELECT id,original_sources::text AS sources FROM goods_bom_material_cost_adoptions WHERE goods_id=? ORDER BY id",world.goodsA());
        transaction.executeWithoutResult(status->{tx.bind();db.update("UPDATE goods SET price=101 WHERE id=?",world.goodsE());});
        for(var proof:frozen) assertThat(db.queryForObject("SELECT original_sources::text FROM goods_bom_material_cost_adoptions WHERE id=?",String.class,proof.get("id"))).isEqualTo(proof.get("sources"));
    }    private String precision(String purpose)throws Exception {
        return java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(json.writeValueAsBytes(Map.of("version",1,"choices",Map.of(purpose,Map.of("scale",24,"rounding","DOWN")))));
    }
    private static String snapshotMigrations() {
        try {
            var source=java.nio.file.Path.of(java.util.Objects.requireNonNull(GoodsNativeBudgetEndToEndTest.class.getClassLoader().getResource("db/migration")).toURI());
            var target=java.nio.file.Files.createTempDirectory("uten-goods-native-migrations-").toAbsolutePath().normalize();
            try(var paths=java.nio.file.Files.list(source)) {
                for(var file:paths.filter(path->path.getFileName().toString().endsWith(".sql")).sorted().toList()) {
                    byte[] bytes=java.nio.file.Files.readAllBytes(file);
                    java.nio.file.Files.write(target.resolve(file.getFileName()),bytes);
                    if(!java.util.Arrays.equals(bytes,java.nio.file.Files.readAllBytes(file))) throw new IllegalStateException("Migration source changed while taking the isolated test snapshot");
                }
            }
            return "filesystem:"+target.toString().replace('\\','/');
        } catch(Exception failure) { throw new IllegalStateException("Cannot snapshot the actual live migration source",failure); }
    }

}
