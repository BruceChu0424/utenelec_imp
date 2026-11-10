package com.uten.imp.businesschain;

import com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.*;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderPreviewService;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderWriteService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.Comparator;

import static org.junit.jupiter.api.Assertions.*;

/** Company screenshot: change one component's order from demand 50 to 500. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class CompanyMaterialOrderQuantityEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MaterialAnalysisService analyses;
    @Autowired AggregateMaterialOrderPreviewService preview;
    @Autowired AggregateMaterialOrderWriteService writer;
    AggregateMaterialOrderEndToEndTest support;
    @BeforeEach void prepare(){support=new AggregateMaterialOrderEndToEndTest();beans.autowireBean(support);support.before();}
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @ParameterizedTest
    @CsvSource({"BUY,ORDER_ALL,500,false", "BUY,AVAILABLE_THEN_ORDER,481.8483,false",
            "BUY,AVAILABLE_THEN_ORDER,481.8483,true", "SUBCONTRACT,ORDER_ALL,500,false"})
    void editedQuantityRetainsExactOrderIntentAndSeparatesPublicStock(String route,String method,String ordered,boolean alreadyProjected) {
        var c=support.createMaterial("25",route);
        support.receive(c,c.material(),"18.1517");
        var current=analyses.detail(c.analysis());
        var candidates=current.flatMaterials().stream().filter(value->value.goodsId().equals(c.material())&&value.level()>0).toList();
        var order=Comparator.comparing(com.uten.imp.features.production.analysis.MaterialAnalysisContracts.MaterialView::planningUncoveredQty);
        var row=(alreadyProjected?candidates.stream().min(order):candidates.stream().max(order)).orElseThrow();
        assertEquals(0,new BigDecimal("50").compareTo(row.requiredQty()));
        UUID id=row.materialLineId();
        var group=new GroupInput("edited-component",List.of(id),route,new BigDecimal("500"),true,
                null,null,null,null,null,null,null,BigDecimal.ZERO,Map.of(id,new BigDecimal("500")),
                method.equals("ORDER_ALL"),"COVERAGE_TOTAL",method);
        var request=support.request(c,List.of(group));
        var shown=preview.preview(c.analysis(),request);
        assertNull(shown.groups().getFirst().blockedReason());
        var command=support.submit(shown,request);
        var result=writer.submit(c.analysis(),command);
        assertEquals(1,result.batches().size());
        var batch=result.batches().getFirst();
        String sql=route.equals("BUY")?"SELECT qty FROM purchase_request_items WHERE request_id=? AND NOT is_deleted"
                :"SELECT qty FROM subcontract_application_items WHERE application_id=? AND NOT is_deleted";
        BigDecimal actual=db.queryForObject(sql,BigDecimal.class,batch.documentId());
        assertEquals(0,new BigDecimal(ordered).compareTo(actual),
                ()->"Expected order "+ordered+" but wrote "+actual+"; before planningUncovered="+row.planningUncoveredQty());
        assertEquals(0,new BigDecimal("450").compareTo(batch.publicExtraQty()));
        assertTrue(writer.submit(c.analysis(),command).replayed());
        assertEquals(0,new BigDecimal("18.1517").compareTo(db.queryForObject(
                "SELECT SUM(qty) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,c.world().warehouseId(),c.material())));
    }
}
