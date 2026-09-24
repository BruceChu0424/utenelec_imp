package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.execution.ProductionOverproductionRateService;
import com.uten.imp.features.production.execution.ProductionOverproductionRateContracts.*;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
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
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProductionOverproductionRateEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ProductionOverproductionRateService rates;
    private UUID segment;

    @BeforeEach void prepare(){
        var fixture=new WorkshopPublicSurplusEndToEndTest();
        beans.autowireBean(fixture);fixture.prepare();
        Object task=ReflectionTestUtils.invokeMethod(fixture,"createStartedTask","rate-review-"+UUID.randomUUID(),false);
        segment=ReflectionTestUtils.invokeMethod(task,"segment");
    }
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void requestKeepsOldRateUntilApprovalAndEveryReplayIsSideEffectFree(){
        assertRate(".10");
        var command=new SubmitRequest(segment,0L,new BigDecimal(".20"),"模具稳定试产后申请允许超产20%","rate-submit-"+UUID.randomUUID());
        RequestView pending=rates.submit(command);
        assertEquals("PENDING",pending.status());assertRate(".10");
        assertEquals(0,new BigDecimal(".10").compareTo(pending.beforeSnapshot().path("items").get(0).path("allowedOverproductionRate").decimalValue()));
        assertEquals(0,new BigDecimal(".20").compareTo(pending.afterSnapshot().path("items").get(0).path("allowedOverproductionRate").decimalValue()));
        assertEquals(pending.id(),rates.submit(command).id());
        assertEquals(pending.id(),rates.context(segment).pendingRequestId());
        var approve=new DecisionRequest(pending.rowVersion(),"rate-approve-"+UUID.randomUUID(),"已核对生产安排");
        assertEquals("APPROVED",rates.decide(pending.id(),approve,true).status());assertRate(".20");
        assertEquals("APPROVED",rates.decide(pending.id(),approve,true).status());
        assertEquals(1L,rates.context(segment).rateVersion());assertNull(rates.context(segment).pendingRequestId());
        assertEquals(1,db.queryForObject("SELECT COUNT(*) FROM production_overproduction_rate_decisions WHERE request_id=?",Integer.class,pending.id()));
        assertEquals(2,db.queryForObject("SELECT COUNT(*) FROM business_outbox WHERE aggregate_id=? AND event_type IN (?,?)",Integer.class,
                pending.id(),ProductionOverproductionRateService.SUBMITTED,ProductionOverproductionRateService.APPROVED));
        assertThrows(ApiException.class,()->rates.decide(pending.id(),new DecisionRequest(0L,"another-decision-"+UUID.randomUUID(),"重复审批"),true));
        assertThrows(RuntimeException.class,()->db.update("UPDATE production_execution_segments SET allowed_overproduction_rate=.9 WHERE id=?",segment));
        assertRate(".20");
    }

    @Test void returnedProposalDoesNotBecomeTheComparisonBaselineOfResubmission(){
        assertEquals(0L,rates.context(segment).requestGeneration());
        var first=rates.submit(new SubmitRequest(segment,0L,new BigDecimal(".15"),"拟调整为15%","rate-return-"+UUID.randomUUID()));
        rates.decide(first.id(),new DecisionRequest(0L,"return-"+UUID.randomUUID(),"请补充试产依据"),false);
        assertRate(".10");assertEquals(0L,rates.context(segment).rateVersion());
        assertEquals(1L,rates.context(segment).requestGeneration());
        var second=rates.submit(new SubmitRequest(segment,0L,new BigDecimal(".25"),"补充依据后改为25%","rate-resubmit-"+UUID.randomUUID()));
        assertNotEquals(first.id(),second.id());
        assertEquals(0,new BigDecimal(".10").compareTo(second.beforeRate()));
        assertEquals("RETURNED",rates.detail(first.id()).status());
        assertEquals("请补充试产依据",rates.detail(first.id()).decisionReason());
        assertThrows(ApiException.class,()->rates.submit(new SubmitRequest(segment,0L,new BigDecimal(".30"),"另一个并行申请","rate-duplicate-"+UUID.randomUUID())));
        rates.decide(second.id(),new DecisionRequest(0L,"approve-resubmit-"+UUID.randomUUID(),null),true);
        assertRate(".25");
        assertThrows(ApiException.class,()->rates.submit(new SubmitRequest(segment,0L,new BigDecimal(".35"),"陈旧版本不能提交","rate-stale-"+UUID.randomUUID())));
        assertEquals(2,db.queryForObject("SELECT COUNT(*) FROM production_overproduction_rate_requests WHERE execution_segment_id=?",Integer.class,segment));
        assertEquals(2L,rates.context(segment).requestGeneration());
    }

    @Test void ordinaryReportPermissionCannotSubmitOrApproveARateChange(){
        var administrator=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        var limited=new AuthUser(administrator.getId(),administrator.getEmployeeId(),administrator.getUsername(),
                Set.of("production_execution:view","production_daily_report:create"),false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(limited,null,limited.getAuthorities()));
        assertThrows(ApiException.class,()->rates.submit(new SubmitRequest(segment,0L,new BigDecimal(".2"),"无权限不能提交","rate-denied-"+UUID.randomUUID())));
        assertThrows(ApiException.class,()->rates.count());
        assertRate(".10");
        assertEquals(0,db.queryForObject("SELECT COUNT(*) FROM production_overproduction_rate_requests WHERE execution_segment_id=?",Integer.class,segment));
    }

    private void assertRate(String expected){assertEquals(0,new BigDecimal(expected).compareTo(db.queryForObject(
            "SELECT allowed_overproduction_rate FROM production_execution_segments WHERE id=?",BigDecimal.class,segment)));}
}
