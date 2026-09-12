package com.uten.imp.businesschain;

import com.uten.imp.features.production.quality.ProductionFqcInspectionService;
import com.uten.imp.features.production.quality.ProductionFqcContracts.*;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.*;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.beans.factory.config.BeanPostProcessor;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DelegatingDataSource;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.*;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import javax.sql.DataSource;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Proxy;
import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.*;

/** Actual decisions/releases with one complete view query, including replay and rollback. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000"})
@Import(ProductionFqcBatchViewEndToEndTest.ViewCounter.class)
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners=ProductionFqcBatchViewEndToEndTest.Cleanup.class,
        mergeMode=TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class ProductionFqcBatchViewEndToEndTest {
    private static final PostgreSQLContainer<?> DATABASE=new PostgreSQLContainer<>("postgres:16-alpine");
    private static final String SECRET=UUID.randomUUID()+"-"+UUID.randomUUID();
    private static final ThreadLocal<AtomicInteger> VIEW_QUERIES=new ThreadLocal<>();
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties) {
        DATABASE.start();
        properties.add("spring.datasource.url",DATABASE::getJdbcUrl);
        properties.add("spring.datasource.username",DATABASE::getUsername);
        properties.add("spring.datasource.password",DATABASE::getPassword);
        properties.add("uten.jwt.secret",()->SECRET);
        properties.add("uten.crypto.pgp-master-key",()->SECRET);
        properties.add("uten.crypto.hmac-key",()->SECRET);
        properties.add("uten.bootstrap.admin-login",()->"fqc-view-bootstrap");
        properties.add("uten.bootstrap.admin-password",()->SECRET+"Aa1!");
    }
    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder(){return new DirtiesContextTestExecutionListener().getOrder()-1;}
        @Override public void afterTestClass(TestContext ignored){DATABASE.stop();}
    }
    @Autowired JdbcTemplate jdbc;
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired ProductionFqcInspectionService quality;
    @Autowired ProductionFinishedArrivalRegistrationService arrivals;
    @Autowired PlatformTransactionManager manager;
    @AfterEach void cleanup(){SecurityContextHolder.clearContext();VIEW_QUERIES.remove();}

    @Test void fiveRowsAcrossTwoWarehousesKeepAllDetailFieldsAndUseOneFinalViewForNewAndReplay() {
        var source=prepare(List.of(new String[]{"3","3","4"},new String[]{"5","5"}));
        UUID first=source.inspections().getFirst();
        InspectionView initial=quality.detail(first);
        quality.decide(first,new DecisionRequest("PASS",initial.reportedQty().divide(new BigDecimal("2")),null,null,null,"fqc-view-partial-"+first));
        var request=new PassAllBatchRequest(source.inspections().reversed(),"fqc-view-batch-"+UUID.randomUUID());
        PassAllBatchResult result=oneView(()->quality.passAll(request));
        assertFalse(result.replay());
        var expectedOrder=source.inspections().stream().sorted(Comparator.comparing(UUID::toString)).toList();
        assertEquals(expectedOrder,result.items().stream().map(PassAllBatchItem::inspectionId).toList());
        for(PassAllBatchItem row:result.items()) {
            assertEquals(quality.detail(row.inspectionId()),row.inspection(),"All 33 fields must equal the authoritative final single-detail view");
            assertEquals("RESOLVED",row.inspection().status());
            assertEquals(0,row.inspection().reportedQty().compareTo(row.inspection().authorizedInboundQty()));
            assertTrue(row.inspection().place().startsWith("FQC-VIEW-"));
            assertEquals("FQC complete snapshot",row.inspection().registrationRemark());
            assertNotNull(row.inspection().receiverName());
            assertEquals(1,jdbc.queryForObject("SELECT count(*) FROM production_fqc_pass_all_batch_items WHERE batch_id=? AND inspection_id=? AND decision_event_id=?",Integer.class,result.batchId(),row.inspectionId(),row.decisionEventId()));
            assertEquals(1,jdbc.queryForObject("SELECT count(*) FROM business_outbox WHERE dedupe_key=?",Integer.class,"PRODUCTION_FQC_RELEASED:"+row.decisionEventId()));
            assertEquals(1,jdbc.queryForObject("SELECT count(*) FROM business_outbox WHERE dedupe_key=?",Integer.class,"PRODUCTION_FQC_RESOLVED:"+row.inspectionId()));
        }
        assertEquals(2,result.items().stream().map(item->item.inspection().warehouseId()).distinct().count());
        assertEquals(6,sourceCount("stock_documents","source_daily_report_id",source),"One earlier partial PASS plus five batch decisions retain six distinct FINISHED_IN documents");
        assertEquals(0,jdbc.queryForObject("SELECT coalesce(sum(qty),0) FROM stock_balances WHERE goods_id=?",BigDecimal.class,source.goods()).signum(),"FQC creates drafts, never qualified physical stock");
        PassAllBatchResult replay=oneView(()->quality.passAll(request));
        assertTrue(replay.replay());assertEquals(result.batchId(),replay.batchId());assertEquals(result.items(),replay.items());
        assertEquals(6,sourceCount("stock_documents","source_daily_report_id",source));
    }

    @Test void databaseFailureAfterTheFinalViewRollsBackDecisionDraftReleaseAndBatchLinks() {
        var source=prepare(Collections.singletonList(new String[]{"5","5"}));
        var request=new PassAllBatchRequest(source.inspections(),"fqc-view-rollback-"+UUID.randomUUID());
        assertThrows(org.springframework.dao.DataAccessException.class,()->new TransactionTemplate(manager).executeWithoutResult(status->{
            var result=oneView(()->quality.passAll(request));
            assertEquals(2,result.items().size());
            assertEquals(2,sourceCount("stock_documents","source_daily_report_id",source));
            jdbc.queryForObject("SELECT 1/0",Integer.class);
        }));
        assertEquals(0,sourceCount("stock_documents","source_daily_report_id",source));
        assertEquals(0,jdbc.queryForObject("SELECT count(*) FROM production_fqc_decision_events WHERE inspection_id IN (SELECT id FROM production_fqc_inspections WHERE source_report_id=ANY(string_to_array(?,',')::uuid[]))",Integer.class,reportIds(source)));
        assertEquals(0,jdbc.queryForObject("SELECT count(*) FROM production_fqc_pass_all_batches WHERE idempotency_key=?",Integer.class,request.idempotencyKey()));
        var retried=oneView(()->quality.passAll(request));assertFalse(retried.replay());assertEquals(2,retried.items().size());
    }

    private Source prepare(List<String[]> reportQuantities) {
        var masters=new FullChainEndToEndTest();beans.autowireBean(masters);
        var world=masters.seedWorld("fv-"+UUID.randomUUID().toString().substring(0,8));
        ReflectionTestUtils.invokeMethod(masters,"receiveOpeningInputsForA",world,Integer.toString(10*reportQuantities.size()));
        List<UUID> reports=new ArrayList<>(),inspections=new ArrayList<>();int reportIndex=0;
        for(String[] quantities:reportQuantities) {
            Object report=ReflectionTestUtils.invokeMethod(masters,"approvedMultiLineReportOfNewPlan",world,(Object)quantities);
            UUID reportId=ReflectionTestUtils.invokeMethod(report,"id");assertNotNull(reportId);reports.add(reportId);
            UUID warehouse=world.warehouseId();
            if(reportIndex++>0) {warehouse=UUID.randomUUID();jdbc.update("INSERT INTO warehouses(id,parent_id,code,name,status,is_accountable) VALUES(?,?,?,?,'使用',TRUE)",warehouse,world.warehouseId(),"FV-"+warehouse,"FQC other actual warehouse");}
            var items=jdbc.queryForList("SELECT id FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted ORDER BY line_no",UUID.class,reportId);
            arrivals.register(reportId,new ArrivalRegistrationRequest("fqc-view-register-"+reportId,warehouse,
                    items.stream().map(id->new ArrivalRegistrationItemRequest(id,"FQC-VIEW-"+id)).toList(),"FQC complete snapshot"));
            inspections.addAll(jdbc.queryForList("SELECT id FROM production_fqc_inspections WHERE source_report_id=? ORDER BY id",UUID.class,reportId));
        }
        masters.loginAs(world.superAdminUserId());return new Source(world.goodsA(),reports,inspections);
    }
    private record Source(UUID goods,List<UUID> reports,List<UUID> inspections) {}
    private int sourceCount(String table,String column,Source source){return jdbc.queryForObject("SELECT count(*) FROM "+table+" WHERE "+column+"=ANY(string_to_array(?,',')::uuid[])",Integer.class,reportIds(source));}
    private static String reportIds(Source source){return String.join(",",source.reports().stream().map(UUID::toString).toList());}
    private static PassAllBatchResult oneView(java.util.function.Supplier<PassAllBatchResult> work) {
        AtomicInteger count=new AtomicInteger();VIEW_QUERIES.set(count);
        try {var result=work.get();assertEquals(1,count.get(),"Count actual JDBC executions of the full FQC detail SQL");return result;}
        finally {VIEW_QUERIES.remove();}
    }

    /** Narrow test-only counter: no SQL values, bindings or domain results are changed or captured. */
    @TestConfiguration(proxyBeanMethods=false)
    static class ViewCounter {
        @Bean static BeanPostProcessor fqcViewCounter(){return new BeanPostProcessor(){
            @Override public Object postProcessAfterInitialization(Object bean,String name) {
                if(!(bean instanceof DataSource source))return bean;
                return new DelegatingDataSource(source){
                    @Override public Connection getConnection()throws SQLException{return measured(super.getConnection());}
                    @Override public Connection getConnection(String user,String password)throws SQLException{return measured(super.getConnection(user,password));}
                };
            }
        };}
        private static Connection measured(Connection target) {
            return (Connection)Proxy.newProxyInstance(Connection.class.getClassLoader(),new Class<?>[]{Connection.class},(proxy,method,args)->{
                Object value=invoke(target,method,args);
                if(value instanceof PreparedStatement statement&&args!=null&&args.length>0&&args[0] instanceof String sql
                        &&sql.contains("COALESCE(release.authorized_qty, 0)")) {
                    return Proxy.newProxyInstance(PreparedStatement.class.getClassLoader(),new Class<?>[]{PreparedStatement.class},(p,m,a)->{
                        if(m.getName().startsWith("execute")&&VIEW_QUERIES.get()!=null)VIEW_QUERIES.get().incrementAndGet();
                        return invoke(statement,m,a);
                    });
                }
                return value;
            });
        }
        private static Object invoke(Object target,java.lang.reflect.Method method,Object[] args)throws Throwable {
            try{return method.invoke(target,args);}catch(InvocationTargetException failed){throw failed.getCause();}
        }
    }
}
