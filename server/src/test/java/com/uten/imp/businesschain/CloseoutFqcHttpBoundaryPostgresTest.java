package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.execution.ProductionCompletionReverseService;
import com.uten.imp.features.production.quality.ProductionFqcInspectionService;
import com.uten.imp.features.production.quality.ProductionFqcContracts.*;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.test.util.AopTestUtils;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.servlet.MockMvc;

import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyCollection;
import static org.mockito.Mockito.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/** Same actual FQC inputs retain different documented HTTP transaction boundaries. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.concurrency.verify-nested-footprint=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
class CloseoutFqcHttpBoundaryPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties){FullChainEndToEndTest.registerDataSource(properties);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper json;
    @Autowired MockMvc http;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired StockDocService stock;
    @Autowired ProductionFinishedArrivalRegistrationService arrivals;
    @Autowired ProductionFqcInspectionService quality;
    @MockitoSpyBean ProductionCompletionReverseService completion;
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void sequentialHandlingKeepsEarlierSuccessWhenTheNextReportIsExplicitlyRejected()throws Exception {
        Object source=source();List<UUID> ids=ReflectionTestUtils.invokeMethod(source,"inspections");
        var actor=SecurityContextHolder.getContext().getAuthentication();
        var first=http.perform(post("/api/production/quality-inspections/"+ids.getFirst()+"/decisions").with(authentication(actor))
                .contentType("application/json").content(json.writeValueAsBytes(new DecisionRequest("PASS",null,null,null,null,"row-first-"+UUID.randomUUID())))).andReturn().getResponse();
        assertEquals(200,first.getStatus(),first.getContentAsString());
        var second=http.perform(post("/api/production/quality-inspections/"+ids.getLast()+"/decisions").with(authentication(actor))
                .contentType("application/json").content(json.writeValueAsBytes(new DecisionRequest("FAIL",null,null,"REWORK",null,"row-second-"+UUID.randomUUID())))).andReturn().getResponse();
        assertTrue(second.getStatus()==400||second.getStatus()==422,second.getContentAsString());
        assertEquals(1,eventCount(ids.getFirst()));assertEquals(0,eventCount(ids.getLast()));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_fqc_inspections WHERE id=? AND status='RESOLVED'",Integer.class,ids.getFirst()));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_fqc_inspections WHERE id=? AND status='PENDING'",Integer.class,ids.getLast()));
    }
    @Test void passAllLateBoundaryFailureRollsBackEveryQualityPhysicalAndParentResult()throws Exception {
        Object source=source();List<UUID> ids=ReflectionTestUtils.invokeMethod(source,"inspections");UUID report=ReflectionTestUtils.invokeMethod(source,"reportId");
        var actor=SecurityContextHolder.getContext().getAuthentication();String key="atomic-fqc-"+UUID.randomUUID();
        var target=AopTestUtils.<ProductionCompletionReverseService>getUltimateTargetObject(completion);
        doThrow(new IllegalStateException("closeout final FQC projection failure")).when(target).afterFinishedInboundBatchApproved(anyCollection());
        try {
            var response=http.perform(post("/api/production/quality-inspections/decisions/pass-all").with(authentication(actor))
                    .contentType("application/json").content(json.writeValueAsBytes(new PassAllBatchRequest(ids,key)))).andReturn().getResponse();
            assertTrue(response.getStatus()>=500,response.getContentAsString());
        }finally{doCallRealMethod().when(target).afterFinishedInboundBatchApproved(anyCollection());}
        for(UUID id:ids)assertEquals(0,eventCount(id));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM stock_documents WHERE source_daily_report_id=?",Integer.class,report));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_fqc_pass_all_batches WHERE idempotency_key=?",Integer.class,key));
        assertEquals(2,db.queryForObject("SELECT count(*) FROM production_fqc_inspections WHERE source_report_id=? AND status='PENDING'",Integer.class,report));
    }
    private Object source(){var fixture=new ProductionFqcPreStockBatchEndToEndTest();ReflectionTestUtils.setField(fixture,"beans",beans);ReflectionTestUtils.setField(fixture,"db",db);
        ReflectionTestUtils.setField(fixture,"analyses",analyses);ReflectionTestUtils.setField(fixture,"commands",commands);ReflectionTestUtils.setField(fixture,"stock",stock);ReflectionTestUtils.setField(fixture,"arrivals",arrivals);
        return ReflectionTestUtils.invokeMethod(fixture,"prepare",2,"prestock");}
    private int eventCount(UUID id){return db.queryForObject("SELECT count(*) FROM production_fqc_decision_events WHERE inspection_id=?",Integer.class,id);}
}
