package com.uten.imp.businesschain;

import com.uten.imp.features.production.analysis.MaterialAnalysisContracts;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.purchase.ret.PurchaseReturnService;
import com.uten.imp.features.subcontract.ret.SubcontractReturnService;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.features.finance.gl.SystemPostingStyleService;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import java.nio.file.*;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Explicit opt-in, synthetic loopback preparation; never an actual Web receipt. */
@EnabledIfEnvironmentVariable(named="UTEN_REMEDIATION_B_ALLOW_SEED",matches="true")
@SpringBootTest(properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false",
    "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
    "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=false"})
class FeedbackBPublicServicePrepTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry r){FeedbackBWebSeedTest.database(r);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired PurchaseReturnService purchase;
    @Autowired SubcontractReturnService subcontract;
    @Autowired GlPostingService gl;
    @Autowired SystemPostingStyleService styles;
    final tools.jackson.databind.ObjectMapper json=new tools.jackson.databind.ObjectMapper();
    FullChainEndToEndTest harness;
    Map seed;
    @BeforeEach void setup() throws Exception {
        harness=new FullChainEndToEndTest();beans.autowireBean(harness);
        seed=json.readValue(Files.readString(Path.of(required("UTEN_B_PREP_SEED"))),Map.class);
    }
    @AfterEach void cleanup(){SecurityContextHolder.clearContext();}
    static String required(String key){String value=System.getenv(key);if(value==null||value.isBlank())throw new IllegalStateException("Required fixture option: "+key);return value;}
    UUID id(Map m,String key){return UUID.fromString(m.get(key).toString());}
    AuthUser ordinary(UUID user,String permission){harness.loginAs(user);var auth=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();assertThat(auth.isSuperAdmin()).isFalse();assertThat(auth.getPermissions()).contains(permission);return auth;}
    void write(String variable,Object result)throws Exception{Path p=Path.of(required(variable));if(Files.exists(p))throw new IllegalStateException("Preserve previous evidence");Files.createDirectories(p.getParent());Files.writeString(p,json.writerWithDefaultPrettyPrinter().writeValueAsString(result));}
    BigDecimal num(String sql,Object...args){return db.queryForObject(sql,BigDecimal.class,args);}

    @Test void seedIndependentMaterialOrderCases()throws Exception {
        // A new fixture JVM must continue synthetic legacy master identifiers;
        // never rewrite existing masters or historical business source links.
        var sequence=(java.util.concurrent.atomic.AtomicInteger)org.springframework.test.util.ReflectionTestUtils.getField(FullChainEndToEndTest.class,"LEGACY_SEQ");
        sequence.accumulateAndGet(db.queryForObject("SELECT GREATEST(COALESCE(MAX(legacy_id),9000),9000) FROM units",Integer.class),Math::max);
        var output=new LinkedHashMap<String,Object>();
        for(String scenario:List.of("definite","unknown")) {
            var support=new AggregateMaterialOrderEndToEndTest();beans.autowireBean(support);support.before();
            var c=support.createMaterial("25","BUY");support.receive(c,c.material(),"18.1517");
            UUID planner=support.fixture.createUserWithPerms(c.world(),"b-web-"+scenario+"-"+UUID.randomUUID(),"production_material_analysis:view","production_material_analysis:route","production_material_analysis:notify","production_material_analysis:over_supply","goods:view","material_category:view","warehouse:view","purchase_request:view");
            String password=required("UTEN_REMEDIATION_B_ACCOUNT_PASSWORD");
            db.update("UPDATE users SET password_hash=?,must_change_password=FALSE WHERE id=?",beans.getBean(org.springframework.security.crypto.password.PasswordEncoder.class).encode(password),planner);
            db.update("UPDATE production_material_analyses SET maker_id=(SELECT employee_id FROM users WHERE id=?) WHERE id=?",planner,c.analysis());
            ordinary(planner,"production_material_analysis:route");var detail=analyses.detail(c.analysis());
            var materialRows=detail.flatMaterials().stream().filter(r->r.goodsId().equals(c.material())&&r.level()>0).map(r->Map.of("materialLineId",r.materialLineId(),"requiredQty",r.requiredQty().toPlainString(),"planningUncoveredQty",r.planningUncoveredQty().toPlainString())).toList();
            var isolated=new LinkedHashMap<String,Object>(seed);isolated.put("status","prep; independent actual Web fixture, no UI actions yet");isolated.put("scenario",scenario);
            isolated.put("planner",Map.of("userId",planner,"login",db.queryForObject("SELECT login_account FROM users WHERE id=?",String.class,planner)));
            isolated.put("materialOrder",Map.of("analysisId",c.analysis(),"analysisNo",detail.analysisNo(),"goodsId",c.material(),"warehouseId",c.world().warehouseId(),"rows",materialRows));
            Path file=Path.of(required("UTEN_B_PREP_OUTPUT")).getParent().resolve(scenario+"-seed.json");if(Files.exists(file))throw new IllegalStateException("Preserve previous synthetic seed");Files.writeString(file,json.writerWithDefaultPrettyPrinter().writeValueAsString(isolated));
            output.put(scenario,Map.of("seedFile",file.toString(),"analysisId",c.analysis(),"ordinaryPlanner",planner));
        }
        write("UTEN_B_PREP_OUTPUT",output);
    }

    @Test void stalePreviewViaSameOwnerRoutes()throws Exception {
        Map material=(Map)seed.get("materialOrder"),planner=(Map)seed.get("planner");
        UUID analysis=id(material,"analysisId"),user=id(planner,"userId");
        var auth=ordinary(user,"production_material_analysis:route");
        assertThat(auth.getPermissions()).contains("production_material_analysis:view");
        assertThat(db.queryForObject("SELECT maker_id FROM production_material_analyses WHERE id=?",UUID.class,analysis)).isEqualTo(auth.getEmployeeId());
        var before=analyses.detail(analysis);
        Path gate=Path.of(required("UTEN_B_TRANSPORT_GATE"));Files.createDirectories(gate);
        Path ready=gate.resolve("helper-ready.json");
        if(Files.exists(ready)||Files.exists(gate.resolve("release")))throw new IllegalStateException("Use a new gate tag; preserve old evidence");
        Files.writeString(ready,json.writeValueAsString(Map.of("status","prep: ordinary owner helper warm; no route mutation yet","analysisId",analysis,"actor",user,"version",before.version())));
        long deadline=System.nanoTime()+java.time.Duration.ofMinutes(10).toNanos();
        while(!Files.exists(gate.resolve("hold-ready.json"))) {
            if(System.nanoTime()>deadline)throw new IllegalStateException("No real UI request arrived; nothing was mutated");
            Thread.sleep(100);
        }
        var held=json.readValue(Files.readString(gate.resolve("hold-ready.json")),Map.class);
        assertThat(held.get("path")).isEqualTo("/api/production/material-analyses/"+analysis+"/aggregate-orders/submit");
        assertThat(held.get("method")).isEqualTo("POST");
        assertThat(analyses.detail(analysis).version()).isEqualTo(before.version());
        UUID line=id((Map)((List)material.get("rows")).getFirst(),"materialLineId");
        String key="web-stale-prep-"+UUID.randomUUID();
        var after=analyses.saveRoutes(analysis,new MaterialAnalysisContracts.RouteRequest(before.version(),before.fingerprint(),key,
            List.of(new MaterialAnalysisContracts.RouteDecision(line,null,"BUY","真实网页旧预览冲突验收：保持采购路线"))));
        assertThat(after.version()).isGreaterThan(before.version());
        write("UTEN_B_PREP_OUTPUT",Map.of("status","prep: real public saveRoutes committed; UI rejection still must be observed","analysisId",analysis,"actor",user,"httpEquivalent","PUT /api/production/material-analyses/"+analysis+"/routes","routeCommandKey",key,"beforeVersion",before.version(),"afterVersion",after.version()));
        Files.writeString(gate.resolve("release"),"Public saveRoutes committed; release original request bytes unchanged\n",StandardOpenOption.CREATE_NEW);
    }

    @Test void approveActualOldProgramReceiptOnlyDrafts()throws Exception {
        assertThat(seed.get("legacyProgram")).isEqualTo(true);
        UUID approver=id((Map)seed.get("approver"),"userId");
        var facts=new LinkedHashMap<String,Object>();
        // Preserve old rows before changing their lifecycle. No SQL mutates sources or order links.
        for(String kind:List.of("purchase","subcontract")){
            Map s=(Map)seed.get(kind);UUID draft=id(s,"legacyDraftId");
            var row=db.queryForMap("SELECT r.id,r.maker_id,r.created_by,r.status,i.id item_id,i.receipt_item_id,i.order_item_id,i.qty,i.price FROM "+kind+"_returns r JOIN "+kind+"_return_items i ON i.return_id=r.id WHERE r.id=?",draft);
            assertThat(row.get("order_item_id")).as("old public save must actually have stored receipt-only").isNull();
            assertThat(row.get("receipt_item_id")).isEqualTo(id(s,"receiptItemId"));
            assertThat(row.get("status")).isEqualTo(0);facts.put(kind+"Before",row);
        }
        write("UTEN_B_PREP_BEFORE_OUTPUT",facts);
        ordinary(approver,"purchase_return:approve");purchase.approve(id((Map)seed.get("purchase"),"legacyDraftId"));
        ordinary(approver,"subcontract_return:approve");subcontract.approve(id((Map)seed.get("subcontract"),"legacyDraftId"));
        for(String kind:List.of("purchase","subcontract")){
            Map s=(Map)seed.get(kind);UUID draft=id(s,"legacyDraftId");
            assertThat(db.queryForObject("SELECT order_item_id FROM "+kind+"_return_items WHERE return_id=?",UUID.class,draft)).isEqualTo(id(s,"orderItemId"));
            var before=(Map)facts.get(kind+"Before");
            assertThat(db.queryForObject("SELECT maker_id FROM "+kind+"_returns WHERE id=?",UUID.class,draft)).isEqualTo(before.get("maker_id"));
            assertThat(db.queryForObject("SELECT approver_id FROM "+kind+"_returns WHERE id=?",UUID.class,draft)).isEqualTo(db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,approver));
            assertThat(num("SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?",id(s,"warehouseId"),id(s,"goodsId"))).isEqualByComparingTo("9");
            assertThat(num("SELECT amount_local FROM stock_balances WHERE warehouse_id=? AND goods_id=?",id(s,"warehouseId"),id(s,"goodsId"))).isEqualByComparingTo(kind.equals("purchase")?"90":"540");
            assertThat(num("SELECT SUM(amount_original_local) FROM ar_ap_ledger WHERE source_doc_id=? AND status=1 AND direction='AP' AND NOT is_deleted",draft)).isEqualByComparingTo(kind.equals("purchase")?"-10":"-50");
            facts.put(kind+"After",db.queryForMap("SELECT r.id,r.maker_id,r.approver_id,r.status,r.total_local,i.id item_id,i.receipt_item_id,i.order_item_id,i.qty,i.price FROM "+kind+"_returns r JOIN "+kind+"_return_items i ON i.return_id=r.id WHERE r.id=?",draft));
        }
        // Independent synthetic accounting setup and ordinary posting actor; no return rewrite.
        var oldPurchase=(Map)facts.get("purchaseBefore");
        UUID oldMaker=(UUID)oldPurchase.get("maker_id"),oldCreator=(UUID)oldPurchase.get("created_by");
        UUID dept=db.queryForObject("SELECT department_id FROM employees WHERE id=?",UUID.class,oldMaker);
        // Reuse the old fixture's department; a new JVM's old harness legacy
        // sequence restarts at 9000 and must not create duplicate old units.
        var financeWorld=new FullChainEndToEndTest.World(dept,oldMaker,oldCreator,null,null,null,null,null,null,null,null,null,null,null,0);
        harness.loginAs(oldCreator);harness.seedChartOfAccounts();
        var role=styles.list().stream().filter(r->r.roleKey().equals("PROCUREMENT_RETURN_VARIANCE")).findFirst().orElseThrow();
        if(!role.usable()) {UUID style=UUID.randomUUID();db.update("INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,?,?,'EXPENSE',0,'使用')",style,"BPREPVAR-"+style,"合成退货价差科目");styles.configure(role.roleKey(),new SystemPostingStyleService.Configure(style,role.updatedAt()));}
        UUID poster=harness.createUserWithPerms(financeWorld,"b-upgrade-poster-"+UUID.randomUUID(),"finance_post:execute");
        ordinary(poster,"finance_post:execute");String period=seed.get("billDate").toString().substring(0,7);gl.generate(period);gl.generate(period);
        for(String kind:List.of("purchase","subcontract")){
            UUID draft=id((Map)seed.get(kind),"legacyDraftId");
            assertThat(num("SELECT SUM(e.direction*e.amount) FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id WHERE v.source_doc_id=? AND v.status=1 AND NOT v.is_deleted AND NOT e.is_deleted",draft)).isZero();
            assertThat(num("SELECT SUM(e.direction*e.amount) FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id WHERE v.source_doc_id=? AND e.style_id=system_posting_style_id('INVENTORY_ASSET') AND v.status=1 AND NOT v.is_deleted",draft)).isEqualByComparingTo(kind.equals("purchase")?"-10":"-60");
        }
        UUID sc=id((Map)seed.get("subcontract"),"legacyDraftId");
        assertThat(num("SELECT SUM(e.direction*e.amount) FROM gl_entries e JOIN gl_vouchers v ON v.id=e.voucher_id WHERE v.source_doc_id=? AND e.style_id=system_posting_style_id('PROCUREMENT_RETURN_VARIANCE') AND v.status=1 AND NOT v.is_deleted",sc)).isEqualByComparingTo("10");
        assertThat(num("SELECT count(*) FROM gl_vouchers WHERE source_type='PROC_RETURN_VARIANCE' AND source_doc_id=? AND NOT is_deleted",sc)).isEqualByComparingTo("1");
        facts.put("status","prep: actual old public saves, candidate public ordinary approvals, stock/AP/GL assertions passed; not Web acceptance");facts.put("approverUserId",approver);facts.put("ordinaryPostingUserId",poster);facts.put("period",period);write("UTEN_B_PREP_OUTPUT",facts);
    }
}
