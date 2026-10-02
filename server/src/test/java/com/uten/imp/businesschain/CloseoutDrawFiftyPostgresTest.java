package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocIssueBatchRequest;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.servlet.MockMvc;

import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/** Maximum ordinary batch with real planning/request/physical stock paths; fixture preparation is excluded from command timing. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.concurrency.verify-nested-footprint=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        // 50 单一批量收尾在 CI 共享 runner 上单事务耗时超过生产默认 40s，
        // 被 FulfillmentHttpDeadline 以「user request」取消语句。极端批量是
        // 本测试的意图本身，放宽到 10 分钟（CI 实测 844s 仍在跑 SQL）。
        "spring.transaction.default-timeout=600s",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
@Import(ProductionJdbcMeasurement.Configuration.class)
class CloseoutDrawFiftyPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties){FullChainEndToEndTest.registerDataSource(properties);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired StockDocService stock;
    @Autowired ObjectMapper json;
    @Autowired MockMvc http;

    @Test void fiftyReviewedDocumentsCommitCompletelyAndFrozenReplayDoesNotReissueAnyMovement()throws Exception {
        var fixtures=new CloseoutCommandRecoveryPostgresTest();ReflectionTestUtils.setField(fixtures,"beans",beans);
        ReflectionTestUtils.setField(fixtures,"db",db);ReflectionTestUtils.setField(fixtures,"stock",stock);
        Object setup=ReflectionTestUtils.invokeMethod(fixtures,"draws",50,true);
        List<UUID> ids=ReflectionTestUtils.invokeMethod(setup,"documents");assertEquals(50,ids.size());
        var actor=SecurityContextHolder.getContext().getAuthentication();var review=stock.issueBatchReview(ids);
        var request=new StockDocIssueBatchRequest();request.setIdempotencyKey("closeout-fifty-"+UUID.randomUUID());
        request.setProtocolVersion(2);request.setDocIds(ids);request.setReviews(review.documents().stream()
                .map(row->new StockDocIssueBatchRequest.DocumentReview(row.docId(),row.reviewToken())).toList());
        var sample=ProductionJdbcMeasurement.begin();long started=System.nanoTime();
        try {
            var response=http.perform(post("/api/stock/docs/issue-batch").with(authentication(actor))
                    .contentType("application/json").content(json.writeValueAsBytes(request))).andReturn().getResponse();
            assertEquals(200,response.getStatus(),response.getContentAsString());
            assertEquals(50,json.readTree(response.getContentAsByteArray()).path("issuedCount").asInt());
        }finally{ProductionJdbcMeasurement.end();}
        long commandMillis=(System.nanoTime()-started)/1_000_000L;
        var parameters=java.util.Map.of("ids",ids);var named=new org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate(db);
        assertEquals(0,named.queryForObject("SELECT count(*) FROM stock_document_items WHERE doc_id IN(:ids) AND NOT is_deleted AND fn_production_draw_item_requested_qty(id)>issued_qty",parameters,Integer.class));
        long movements=named.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_id IN(:ids)",parameters,Long.class);
        assertEquals(100,movements,"Each planned DRAW has two original input identities");
        assertEquals(1,db.queryForObject("SELECT count(*) FROM stock_draw_issue_batches WHERE idempotency_key=?",Integer.class,request.getIdempotencyKey()));
        var replay=http.perform(post("/api/stock/docs/issue-batch").with(authentication(actor))
                .contentType("application/json").content(json.writeValueAsBytes(request))).andReturn().getResponse();
        assertEquals(200,replay.getStatus(),replay.getContentAsString());assertEquals(50,json.readTree(replay.getContentAsByteArray()).path("replayedCount").asInt());
        assertEquals(movements,named.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_id IN(:ids)",parameters,Long.class));
        System.out.println("CLOSEOUT-DRAW-FIFTY commandMillis="+commandMillis+" metrics="+json.writeValueAsString(sample.result()));
        SecurityContextHolder.clearContext();
    }
}
