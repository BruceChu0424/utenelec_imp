package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.mrp.PlanningPackageLifecycleRequest;
import com.uten.imp.features.production.mrp.ProductionPlanningPackageService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.security.AuthUser;
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

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Real cancellation proves the shared receipt history scope; it does not fabricate a completed issue. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.concurrency.verify-nested-footprint=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class CloseoutDeletedReceiptReadScopePostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties){FullChainEndToEndTest.registerDataSource(properties);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired StockDocService stock;
    @Autowired ProductionPlanningPackageService packages;
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void legallyCancelledDrawKeepsOriginalProductionHistoryButStillRequiresCurrentWarehouseOrganization() {
        var setup=new CloseoutCommandRecoveryPostgresTest();ReflectionTestUtils.setField(setup,"beans",beans);
        ReflectionTestUtils.setField(setup,"db",db);ReflectionTestUtils.setField(setup,"stock",stock);
        Object source=ReflectionTestUtils.invokeMethod(setup,"draws",1,false);
        List<UUID> documents=ReflectionTestUtils.invokeMethod(source,"documents");UUID document=documents.getFirst();
        FullChainEndToEndTest fixture=ReflectionTestUtils.invokeMethod(source,"fixture");
        FullChainEndToEndTest.World world=ReflectionTestUtils.invokeMethod(source,"world");
        var identity=db.queryForMap("SELECT id AS package_id,plan_id FROM production_planning_packages WHERE id=(SELECT package_id FROM production_planning_package_documents WHERE document_id=? LIMIT 1)",document);
        packages.cancel((UUID)identity.get("plan_id"),(UUID)identity.get("package_id"),
                new PlanningPackageLifecycleRequest("closeout-cancel-"+UUID.randomUUID(),"保留已删除历史范围"));
        assertTrue(db.queryForObject("SELECT is_deleted FROM stock_documents WHERE id=?",Boolean.class,document));
        assertTrue(db.queryForObject("SELECT fn_is_production_linked_stock_document(?)",Boolean.class,document));
        UUID user=fixture.createUserWithPerms(world,"history-warehouse-"+UUID.randomUUID(),"stock_doc:view");
        UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,user);
        UUID warehouseDepartment=db.queryForObject("SELECT id FROM departments WHERE code='SUB_WH' AND NOT is_deleted",UUID.class);
        db.update("UPDATE employees SET department_id=? WHERE id=?",warehouseDepartment,employee);
        var actor=new AuthUser(user,employee,"historical-draw-reader",Set.of("stock_doc:view"),false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new org.springframework.security.authentication.UsernamePasswordAuthenticationToken(actor,null,actor.getAuthorities()));
        stock.requireIssueBatchReceiptReadable(documents);
        assertEquals(ErrorCode.NOT_FOUND,assertThrows(ApiException.class,()->stock.issueBatchReview(documents)).getCode());
        db.update("UPDATE employees SET department_id=? WHERE id=?",world.departmentId(),employee);
        assertEquals(ErrorCode.NOT_FOUND,assertThrows(ApiException.class,()->stock.requireIssueBatchReceiptReadable(documents)).getCode());
        assertEquals(1,db.queryForObject("SELECT count(*) FROM stock_documents WHERE id=?",Integer.class,document));
    }
}
