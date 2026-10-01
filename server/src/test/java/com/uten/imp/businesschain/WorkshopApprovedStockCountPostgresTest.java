package com.uten.imp.businesschain;

import com.uten.imp.application.port.WorkshopStockCountPostingPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialCountService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialPeriodService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialSettingsService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.*;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ThreadLocalRandom;

import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.workshop-material.auto-close.enabled=false",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class WorkshopApprovedStockCountPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) { FullChainEndToEndTest.registerDataSource(registry); }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PlatformTransactionManager transactions;
    @Autowired TxSessionVars tx;
    @Autowired DocNumberService numbers;
    @Autowired WorkshopStockCountPostingPort posting;
    @Autowired WorkshopMaterialSettingsService settings;
    @Autowired WorkshopMaterialPeriodService periods;
    @Autowired WorkshopMaterialCountService counts;
    FullChainEndToEndTest fixture;
    record Shop(FullChainEndToEndTest.World world,UUID workshop,UUID unit,UUID goods,UUID bin,UUID period) {}
    record Request(UUID id,UUID line,UUID event) {}
    @AfterEach void logout() { SecurityContextHolder.clearContext(); }

    @Test void approvedOpeningAndLaterAdjustmentAreNotIssuedOrConsumedAgain() {
        Shop shop=shop(false);
        Request first=request(shop,"0",null,"100","100",null);
        assertEquals(0,qty(shop).signum(),"送审不动库存");
        assertThrows(ApiException.class,()->new TransactionTemplate(transactions).execute(s->posting.postApproved(first.id(),first.event())));
        var receipt=approve(shop,first);
        assertEquals(1,receipt.lines().size());
        equal("100",qty(shop));
        assertEquals("OPENING",kind(first));
        assertEquals("PENDING",db.queryForObject("SELECT result_state FROM stock_value_events WHERE source_doc_type='STOCK_COUNT_REQUEST' AND source_doc_id=? AND operation='RECEIVE'",
                String.class,first.id()),"期初没有价格不得核零成本");
        assertEquals(receipt,new TransactionTemplate(transactions).execute(s->posting.postApproved(first.id(),first.event())));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM workshop_material_count_adjustment_postings WHERE request_id=?",Integer.class,first.id()));
        Request lower=request(shop,"100","100","80","80",null);
        approve(shop,lower);
        assertEquals("ADJUSTMENT",kind(lower));
        equal("80",qty(shop));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM workshop_material_requisitions WHERE bin_warehouse_id=?",Integer.class,shop.bin()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM stock_movements WHERE warehouse_id=? AND movement_type=21",Integer.class,shop.bin()));
        var started=periods.startCount(shop.period(),new StartCountRequest(0L,null,key()));
        counts.saveLine(started.count().id(),"approved-opening-physical",new CountLineInput(null,"WEIGHED","LOOSE",
                shop.goods(),null,null,null,new BigDecimal("80"),null,null,null));
        counts.submit(started.count().id(),new VersionRequest(started.count().rowVersion(),key()));
        var periodLine=db.queryForMap("SELECT opening_qty,adjustment_qty,closing_qty,actual_qty FROM workshop_material_period_lines WHERE period_id=? AND goods_id=?",
                shop.period(),shop.goods());
        equal("100",(BigDecimal)periodLine.get("opening_qty"));
        equal("-20",(BigDecimal)periodLine.get("adjustment_qty"));
        equal("80",(BigDecimal)periodLine.get("closing_qty"));
        equal("0",(BigDecimal)periodLine.get("actual_qty"));
        equal("80",qty(shop));
    }

    @Test void staleApprovalRollsBackItsDecisionAndNeverOverwritesInventory() {
        Shop shop=shop(false);
        Request stale=request(shop,"0",null,"30","30",null);
        Request current=request(shop,"0",null,"20","20",null);
        approve(shop,current);
        assertThrows(ApiException.class,()->approve(shop,stale));
        assertEquals("PENDING",db.queryForObject("SELECT status FROM stock_count_requests WHERE id=?",String.class,stale.id()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM workshop_material_count_adjustment_postings WHERE request_id=?",Integer.class,stale.id()));
        equal("20",qty(shop));
        assertThrows(ApiException.class,()->new TransactionTemplate(transactions).execute(s->posting.postApproved(current.id(),UUID.randomUUID())));
        Request unitChanged=request(shop,"20","20","30","30",null);
        db.update("UPDATE unit_measurement_profiles SET mass_unit_code='G' WHERE unit_id=?",shop.unit());
        assertTrue(assertThrows(ApiException.class,()->approve(shop,unitChanged)).getMessage().contains("重量换算已变化"));
        assertEquals("PENDING",db.queryForObject("SELECT status FROM stock_count_requests WHERE id=?",String.class,unitChanged.id()));
        equal("20",qty(shop));
    }

    @Test void firstOrderMaterialUsesExplicitSetupAndRejectsConflictingWeight() {
        Shop shop=shop(true);
        Request missing=request(shop,"0",null,"10","10",null);
        assertTrue(assertThrows(ApiException.class,()->approve(shop,missing)).getMessage().contains("确认材料用途"));
        assertEquals("ORDER",db.queryForObject("SELECT issue_method FROM goods WHERE id=?",String.class,shop.goods()));
        Request mismatched=request(shop,"0",null,"10","10000","OWN");
        assertThrows(ApiException.class,()->approve(shop,mismatched));
        assertEquals("ORDER",db.queryForObject("SELECT issue_method FROM goods WHERE id=?",String.class,shop.goods()),"重量错误使首次设置一并回滚");
        Request correct=request(shop,"0",null,"10","10","OWN");
        approve(shop,correct);
        equal("10",qty(shop));
        assertEquals("PERIODIC",db.queryForObject("SELECT issue_method FROM goods WHERE id=?",String.class,shop.goods()));
    }

    private Shop shop(boolean order) {
        fixture=new FullChainEndToEndTest(); beans.autowireBean(fixture);
        String tag="approved-count-"+UUID.randomUUID().toString().substring(0,8);
        var world=fixture.seedWorld(tag); fixture.loginAs(world.superAdminUserId());
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment",tag);
        UUID workshop=ReflectionTestUtils.invokeMethod(assignment,"workshopId");
        UUID unit=UUID.randomUUID(),goods=UUID.randomUUID();
        int legacy=800_000_000+ThreadLocalRandom.current().nextInt(50_000_000);
        db.update("INSERT INTO units(id,legacy_id,code,name,status) VALUES (?,?,?,'千克','使用')",unit,legacy,"KG-"+tag);
        db.update("INSERT INTO unit_measurement_profiles(unit_id,measurement_dimension,mass_unit_code,provenance) VALUES (?,'MASS','KG','MANUAL_GOVERNANCE')",unit);
        db.update("""
                INSERT INTO goods(id,code,name,source_type,status,unit_id,unit_legacy_id,price,code_sequence,issue_method,periodic_cost_basis,min_qty)
                VALUES (?,?,?,'采购','使用',?,?,10,(SELECT coalesce(max(code_sequence),0)+1 FROM goods),?,?,0)
                """,goods,"COUNT-"+tag,"期初颗粒",unit,legacy,order?"ORDER":"PERIODIC",order?null:"OWN");
        var enabled=settings.update(workshop,new SettingsRequest(0L,true,world.warehouseId(),BusinessTime.today(),List.of(),key()));
        return new Shop(world,workshop,unit,goods,enabled.binWarehouseId(),enabled.currentPeriod().id());
    }

    private Request request(Shop shop,String expected,String expectedWeight,String target,String targetWeight,String basis) {
        return new TransactionTemplate(transactions).execute(status->{
            tx.bind(); UUID request=UUID.randomUUID(),line=UUID.randomUUID(),event=UUID.randomUUID();
            db.update("""
                    INSERT INTO stock_count_requests(id,request_no,warehouse_id,review_route,submitted_by,reason,command_key,request_hash)
                    VALUES (?,?,?,'WAREHOUSE',?,'核对现存实物',?,'test')
                    """,request,numbers.nextNumber(DocNumberPrefix.STOCK_COUNT_REQUEST),shop.bin(),shop.world().superAdminUserId(),key());
            db.update("""
                    INSERT INTO stock_count_request_lines(id,request_id,line_no,goods_id,unit_id,expected_qty,expected_weight_kg,
                        expected_weight_estimated,target_qty,target_weight_kg,weight_changed,material_setup_basis,goods_version,
                        goods_name,unit_name,kg_per_base_unit)
                    VALUES (?,?,1,?,?,?,?,FALSE,?,?,TRUE,?,(SELECT version FROM goods WHERE id=?),'颗粒','千克',1)
                    """,line,request,shop.goods(),shop.unit(),new BigDecimal(expected),expectedWeight==null?null:new BigDecimal(expectedWeight),
                    new BigDecimal(target),new BigDecimal(targetWeight),basis,shop.goods());
            return new Request(request,line,event);
        });
    }

    private WorkshopStockCountPostingPort.PostingResult approve(Shop shop,Request request) {
        return new TransactionTemplate(transactions).execute(status->{
            tx.bind();
            db.update("INSERT INTO stock_count_request_events(id,request_id,action,actor_id,request_version,command_key) VALUES (?,?,'APPROVE',?,1,?)",
                    request.event(),request.id(),shop.world().superAdminUserId(),key());
            db.update("UPDATE stock_count_requests SET status='APPROVED',row_version=1,approval_event_id=?,reviewed_by=?,reviewed_at=now() WHERE id=?",
                    request.event(),shop.world().superAdminUserId(),request.id());
            return posting.postApproved(request.id(),request.event());
        });
    }
    private BigDecimal qty(Shop shop) { return db.queryForObject("SELECT COALESCE(sum(qty),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,shop.bin(),shop.goods()); }
    private String kind(Request request) { return db.queryForObject("SELECT kind FROM workshop_material_count_adjustment_postings WHERE line_id=?",String.class,request.line()); }
    private static String key() { return "approved-count-"+UUID.randomUUID(); }
    private static void equal(String expected,BigDecimal actual) { assertNotNull(actual); assertEquals(0,new BigDecimal(expected).compareTo(actual)); }
}
