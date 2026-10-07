package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.ProductionOverLimitDispositionService;
import com.uten.imp.features.production.dailyreport.ProductionOverLimitDispositionContracts.DecisionRequest;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine;
import com.uten.imp.security.AuthUser;
import com.uten.imp.support.DailyReportApproveRequests;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import java.math.BigDecimal;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProductionOverLimitDispositionEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ProductionDailyReportService reports;
    @Autowired ProductionOverLimitDispositionService dispositions;
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void draftsCanBeCorrectedAndDeletedWithoutPublishingAnApprovalTask(){
        Scenario s=draft();
        UUID first=caseId(s.report());
        assertEquals("DRAFT",dispositions.detail(first).status());
        assertFalse(dispositions.detail(first).canDecide());
        assertThrows(ApiException.class,()->dispositions.decide(first,decision("ACCEPT_PUBLIC",0,"draft")));
        s.request().setExpectedVersion(reports.detail(s.report()).getRowVersion());
        s.request().getItems().getFirst().setQty(new BigDecimal("1250"));
        reports.update(s.report(),s.request());
        UUID revised=caseId(s.report());
        assertNotEquals(first,revised);
        assertEquals(0,new BigDecimal("150").compareTo(dispositions.detail(revised).overLimitQty()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM business_outbox WHERE aggregate_id IN (?,?) AND event_type='PRODUCTION_OVER_LIMIT_PENDING'",Integer.class,first,revised));
        reports.delete(s.report());
        assertEquals("WITHDRAWN",dispositions.detail(revised).status());
        assertEquals(0,new BigDecimal("100").compareTo(db.queryForObject("SELECT fn_execution_actual_surplus_available(?)",BigDecimal.class,s.segment())));
    }

    @Test void heldAndReturnedFactsRemainActualAndApprovalDoesNotChangeThePlanOrRate(){
        Scenario s=draft();approve(s);
        UUID id=caseId(s.report());
        var initial=dispositions.detail(id);
        var hold=decision("HOLD",initial.rowVersion(),"hold");
        var held=dispositions.decide(id,hold);
        assertEquals("HELD",held.status());
        assertEquals("HELD",dispositions.decide(id,hold).status());
        assertThrows(ApiException.class,()->dispositions.decide(id,new DecisionRequest("ACCEPT_PUBLIC","变换内容不可重用同键",hold.expectedVersion(),hold.idempotencyKey())));
        assertThrows(ApiException.class,()->dispositions.decide(id,decision("ACCEPT_PUBLIC",initial.rowVersion(),"stale")));
        var returned=dispositions.decide(id,decision("RETURN_FOR_REVIEW",held.rowVersion(),"verify"));
        assertEquals("RETURNED",returned.status());assertTrue(returned.canDecide());
        assertEquals(0,new BigDecimal("1200").compareTo(db.queryForObject("SELECT sum(qty) FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted",BigDecimal.class,s.report())));
        assertFalse(db.queryForObject("SELECT fn_daily_report_output_authorized(?)",Boolean.class,returned.reportItemId()));
        var accepted=dispositions.decide(id,decision("ACCEPT_PUBLIC",returned.rowVersion(),"accept"));
        assertEquals("ACCEPTED",accepted.status());assertFalse(accepted.canDecide());assertEquals(3,accepted.decisionHistory().size());
        assertTrue(db.queryForObject("SELECT fn_daily_report_output_authorized(?)",Boolean.class,accepted.reportItemId()));
        assertEquals(0,new BigDecimal("1000").compareTo(db.queryForObject("SELECT planned_qty FROM production_execution_segments WHERE id=?",BigDecimal.class,s.segment())));
        assertEquals(0,new BigDecimal(".10").compareTo(db.queryForObject("SELECT allowed_overproduction_rate FROM production_execution_segments WHERE id=?",BigDecimal.class,s.segment())));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM stock_documents WHERE source_daily_report_id=? AND doc_type='FINISHED_IN'",Integer.class,s.report()));
        assertThrows(RuntimeException.class,()->db.update("UPDATE production_over_limit_dispositions SET qty=99 WHERE id=?",id));
        assertThrows(RuntimeException.class,()->db.update("DELETE FROM production_over_limit_decisions WHERE disposition_id=?",id));
    }

    @Test void reporterCannotApproveAndWithdrawalRemovesAuthorizationButKeepsTheHistory(){
        Scenario s=draft();approve(s);UUID id=caseId(s.report());
        var admin=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        var worker=new AuthUser(admin.getId(),admin.getEmployeeId(),admin.getUsername(),
            Set.of("production_execution:view","production_daily_report:view","production_daily_report:create"),false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(worker,null,worker.getAuthorities()));
        assertThrows(ApiException.class,()->dispositions.decide(id,decision("ACCEPT_PUBLIC",1,"denied")));
        assertThrows(ApiException.class,()->dispositions.count());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_over_limit_decisions WHERE disposition_id=?",Integer.class,id));
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(admin,null,admin.getAuthorities()));
        var accepted=dispositions.decide(id,decision("ACCEPT_PUBLIC",dispositions.detail(id).rowVersion(),"before-reverse"));
        reports.reverse(s.report());
        assertEquals("WITHDRAWN",dispositions.detail(id).status());
        assertFalse(db.queryForObject("SELECT fn_daily_report_output_authorized(?)",Boolean.class,accepted.reportItemId()));
        assertEquals(1,dispositions.detail(id).decisionHistory().size());
        assertThrows(ApiException.class,()->dispositions.decide(id,decision("ACCEPT_PUBLIC",dispositions.detail(id).rowVersion(),"after-reverse")));
    }

    private Scenario draft(){
        var fixture=new WorkshopPublicSurplusEndToEndTest();beans.autowireBean(fixture);fixture.prepare();
        Object task=ReflectionTestUtils.invokeMethod(fixture,"createStartedTask","overlimit-disposition-"+UUID.randomUUID(),false,"1000");
        List<ReportablePlanLine> sources=ReflectionTestUtils.invokeMethod(fixture,"sources",task);
        DailyReportSaveRequest request=ReflectionTestUtils.invokeMethod(fixture,"reportRequest",task,sources.getFirst(),"1200","1000");
        request.getItems().getFirst().setOverLimitReason("尾批实物已完成，需计划核实接收");
        UUID report=reports.create(request).getId();
        return new Scenario(report,ReflectionTestUtils.invokeMethod(task,"segment"),request);
    }
    private void approve(Scenario s){reports.approve(s.report(),DailyReportApproveRequests.freshKey());}
    private UUID caseId(UUID report){return db.queryForObject("SELECT id FROM production_over_limit_dispositions WHERE report_id=?",UUID.class,report);}
    private DecisionRequest decision(String action,long version,String key){return new DecisionRequest(action,"已核实本批实际产量及保管去向",version,key+"-"+UUID.randomUUID());}
    private record Scenario(UUID report,UUID segment,DailyReportSaveRequest request){}
}
