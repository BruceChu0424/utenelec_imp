package com.uten.imp.businesschain;

import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.util.PSQLException;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.ConnectionCallback;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false", "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false", "uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only", "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only", "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProductionMaterialConsumptionProjectionEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PlatformTransactionManager manager;
    ProductionQuantityAdversarialEndToEndTest fixture;

    @BeforeEach void prepare(){fixture=new ProductionQuantityAdversarialEndToEndTest();beans.autowireBean(fixture);fixture.prepare();}
    @AfterEach void clear(){fixture.logout();}

    @Test void callersCannotHideNakedConsumptionByResettingTransactionMetadataTwice() {
        Object task=readyWithFirstFive("aq-projection-forge");UUID reservation=reservation(task);
        var failure=assertThrows(RuntimeException.class,()->new TransactionTemplate(manager).executeWithoutResult(ignored->{
            beans.getBean(TxSessionVars.class).bind();
            db.update("UPDATE stock_reservations SET consumed_qty=6,status=0,material_projection_tx_id=pg_current_xact_id(),material_projection_initial_consumed_qty=6 WHERE id=?",reservation);
            db.update("UPDATE stock_reservations SET material_projection_tx_id=pg_current_xact_id(),material_projection_initial_consumed_qty=consumed_qty WHERE id=?",reservation);
            quantity("5","SELECT material_projection_initial_consumed_qty FROM stock_reservations WHERE id=?",reservation);
        }));
        assertProjectionFailure(failure);
        quantity("5","SELECT consumed_qty FROM stock_reservations WHERE id=?",reservation);
        quantity("5","SELECT SUM(CASE posting_type WHEN 'ISSUE' THEN qty_base ELSE -qty_base END) FROM production_material_stock_postings WHERE reservation_id=?",reservation);
    }

    @Test void savepointRollbackRestoresTheFirstBaselineAndLaterRealIssueCanFinishTheReservation() {
        Object task=readyWithFirstFive("aq-projection-savepoint");UUID reservation=reservation(task);
        new TransactionTemplate(manager).executeWithoutResult(ignored->{
            beans.getBean(TxSessionVars.class).bind();
            db.execute((ConnectionCallback<Void>)connection->{
                var point=connection.setSavepoint("consumption_probe");
                db.update("UPDATE stock_reservations SET consumed_qty=6,status=0 WHERE id=?",reservation);
                db.update("UPDATE stock_reservations SET consumed_qty=7,material_projection_initial_consumed_qty=7 WHERE id=?",reservation);
                quantity("5","SELECT material_projection_initial_consumed_qty FROM stock_reservations WHERE id=?",reservation);
                connection.rollback(point);connection.releaseSavepoint(point);
                return null;
            });
            quantity("5","SELECT consumed_qty FROM stock_reservations WHERE id=?",reservation);
            invoke("issueSlice",task,"5");
            quantity("5","SELECT material_projection_initial_consumed_qty FROM stock_reservations WHERE id=?",reservation);
            quantity("5","SELECT SUM(qty_base) FROM production_material_stock_postings WHERE reservation_id=? AND recorded_tx_id=pg_current_xact_id()",reservation);
        });
        quantity("10","SELECT consumed_qty FROM stock_reservations WHERE id=?",reservation);
        assertEquals(1,db.queryForObject("SELECT status::integer FROM stock_reservations WHERE id=?",Integer.class,reservation));
        UUID warehouse=ReflectionTestUtils.invokeMethod(task,"leaf"),goods=ReflectionTestUtils.invokeMethod(task,"material");
        quantity("0","SELECT qty FROM stock_balances WHERE warehouse_id=? AND goods_id=?",warehouse,goods);
    }

    private Object readyWithFirstFive(String tag) {
        Object task=invoke("create",tag,false,"10");
        UUID warehouse=ReflectionTestUtils.invokeMethod(task,"leaf"),goods=ReflectionTestUtils.invokeMethod(task,"material");
        invoke("confirm",task,"CONTINUOUS");invoke("receive",task,goods,warehouse,"10");invoke("issueSlice",task,"5");
        return task;
    }
    private UUID reservation(Object task){UUID demand=invoke("parentDemand",task);return db.queryForObject("SELECT id FROM stock_reservations WHERE demand_id=? AND NOT is_deleted",UUID.class,demand);}
    private <T>T invoke(String method,Object... args){return ReflectionTestUtils.invokeMethod(fixture,method,args);}
    private void quantity(String expected,String sql,Object... args){assertEquals(0,new BigDecimal(expected).compareTo(db.queryForObject(sql,BigDecimal.class,args)));}
    private static void assertProjectionFailure(Throwable failure){
        while(failure.getCause()!=null)failure=failure.getCause();
        var postgres=assertInstanceOf(PSQLException.class,failure);
        assertEquals("23514",postgres.getSQLState());
        assertEquals("production_material_consumed_projection_guard",postgres.getServerErrorMessage().getConstraint());
    }
}
