package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionService;
import com.uten.imp.features.warehouse.inbound.dto.BatchInspectionDecideRequest;
import com.uten.imp.features.warehouse.inbound.dto.BatchInspectionPassRequest;
import com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.*;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;

import static org.junit.jupiter.api.Assertions.*;

/** Actual commercial approval, IQC funding/value facts, exact batch replay and SQL counts. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000"})
@Import(ProductionJdbcMeasurement.Configuration.class)
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners=ProcurementInspectionBatchEndToEndTest.Cleanup.class,
        mergeMode=TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class ProcurementInspectionBatchEndToEndTest {
    private static final PostgreSQLContainer<?> DATABASE=new PostgreSQLContainer<>("postgres:16-alpine");
    private static final String SECRET=UUID.randomUUID()+"-"+UUID.randomUUID();
    private static final BigDecimal RECEIVED=new BigDecimal("1.2500");
    private static final String REASON="真实批量品质报告";
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties) {
        DATABASE.start();
        properties.add("spring.datasource.url",DATABASE::getJdbcUrl);
        properties.add("spring.datasource.username",DATABASE::getUsername);
        properties.add("spring.datasource.password",DATABASE::getPassword);
        properties.add("uten.jwt.secret",()->SECRET);
        properties.add("uten.crypto.pgp-master-key",()->SECRET);
        properties.add("uten.crypto.hmac-key",()->SECRET);
        properties.add("uten.bootstrap.admin-login",()->"iqc-batch-bootstrap");
        properties.add("uten.bootstrap.admin-password",()->SECRET+"Aa1!");
    }
    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder(){return new DirtiesContextTestExecutionListener().getOrder()-1;}
        @Override public void afterTestClass(TestContext ignored){DATABASE.stop();}
    }
    @Autowired JdbcTemplate jdbc;
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired ProcurementInspectionService inspections;
    @Autowired PlatformTransactionManager manager;
    @AfterEach void cleanup(){SecurityContextHolder.clearContext();ProductionJdbcMeasurement.end();}

    @ParameterizedTest @ValueSource(strings={"PURCHASE","SUBCONTRACT"})
    void mixedDecisionsUseOneReceiptLockAndOrderUpdateAndReplayTheExactWholeBody(String type)throws Exception {
        Case source=prepare(type);var request=mixed(source);
        long version=analysisVersion(source);
        String ap=ap(source);
        ProductionJdbcMeasurement.Sample sample=ProductionJdbcMeasurement.begin();
        try {
            new TransactionTemplate(manager).executeWithoutResult(status->{
                long audit=orderUpdates(source);
                inspections.decideBatch(type,source.receipt(),request);
                assertEquals(audit+1,orderUpdates(source),"Three receipt items of one order require one actual order UPDATE");
            });
        } finally {ProductionJdbcMeasurement.end();}
        assertEquals(1,sample.commits);
        assertEquals(1,sample.fingerprints.getOrDefault(receiptLockFingerprint(),0L),
                "The complete receipt SELECT FOR UPDATE executes once, including PASS+FAIL of the same row");
        assertTrue(analysisVersion(source)<=version+1,"A receipt terminal transition can refresh its analysis only once");
        assertEquals(ap,ap(source),"Quality decisions cannot post or reprice AP");
        assertEquals(0,decimal("SELECT sum(warehouse_stocked_base_qty) FROM procurement_inspection_items WHERE receipt_id=?",source.receipt()).signum());
        for (var row:source.rows()) {
            money(decimal("SELECT passed_base_qty FROM procurement_inspection_items WHERE id=?",row.inspectionId()),"0.75");
            money(decimal("SELECT failed_base_qty FROM procurement_inspection_items WHERE id=?",row.inspectionId()),"0.5");
        }
        assertEquals(6,qualityEvents(source));
        assertEquals(1,jdbc.queryForObject("SELECT count(DISTINCT batch_request_hash) FROM procurement_inspection_events event JOIN procurement_inspection_items item ON item.id=event.inspection_item_id WHERE item.receipt_id=? AND event.action IN ('PASS','FAIL')",Integer.class,source.receipt()));
        money(decimal("SELECT sum(event.released_amount_local) FROM procurement_inspection_events event JOIN procurement_inspection_items item ON item.id=event.inspection_item_id WHERE item.receipt_id=? AND event.action='PASS'",source.receipt()),"112.5");
        money(decimal("SELECT sum(part.amount_local) FROM procurement_iqc_quality_consideration_parts part JOIN procurement_inspection_events event ON event.id=part.inspection_event_id JOIN procurement_inspection_items item ON item.id=event.inspection_item_id WHERE item.receipt_id=?",source.receipt()),"187.5");

        String committed=qualityDigest(source);
        var reordered=new ArrayList<>(request.items().stream().map(item->new BatchInspectionDecideRequest.Item(
                item.inspectionItemId(),item.expectedRemainingBaseQty().stripTrailingZeros(),
                item.passBaseQty().stripTrailingZeros(),item.failBaseQty().stripTrailingZeros(),item.idempotencyKey())).toList());
        Collections.reverse(reordered);
        inspections.decideBatch(type,source.receipt(),new BatchInspectionDecideRequest(reordered,"  "+REASON+"  "));
        assertEquals(committed,qualityDigest(source));
        var first=request.items().getFirst();
        rejectChanged(source,request,new BatchInspectionDecideRequest.Item(first.inspectionItemId(),new BigDecimal("2"),first.passBaseQty(),first.failBaseQty(),first.idempotencyKey()));
        rejectChanged(source,request,new BatchInspectionDecideRequest.Item(first.inspectionItemId(),first.expectedRemainingBaseQty(),first.passBaseQty(),BigDecimal.ZERO,first.idempotencyKey()));
        rejectChanged(source,request,new BatchInspectionDecideRequest.Item(first.inspectionItemId(),first.expectedRemainingBaseQty(),new BigDecimal("0.74"),new BigDecimal("0.51"),first.idempotencyKey()));
        conflict(()->inspections.decideBatch(type,source.receipt(),new BatchInspectionDecideRequest(request.items().subList(1,3),REASON)));
        conflict(()->inspections.decideBatch(type,source.receipt(),new BatchInspectionDecideRequest(request.items(),"不同结论原因")));
        assertEquals(committed,qualityDigest(source));
        assertEquals(ap,ap(source));
    }

    @Test void newFullPassBatchUsesOriginalEventKeysAndReplaysWithoutRepeatingQualityValue()throws Exception {
        Case source=prepare("PURCHASE");
        var request=new BatchInspectionPassRequest(source.rows().stream().map(row->new BatchInspectionPassRequest.Item(
                row.inspectionId(),RECEIVED,"full-pass-"+row.inspectionId())).toList(),null);
        var sample=ProductionJdbcMeasurement.begin();
        try {inspections.passBatch(source.type(),source.receipt(),request);} finally {ProductionJdbcMeasurement.end();}
        assertEquals(1,sample.fingerprints.getOrDefault(receiptLockFingerprint(),0L));
        assertEquals(3,qualityEvents(source));
        money(decimal("SELECT sum(passed_base_qty) FROM procurement_inspection_items WHERE receipt_id=?",source.receipt()),"3.75");
        money(decimal("SELECT sum(event.released_amount_local) FROM procurement_inspection_events event JOIN procurement_inspection_items item ON item.id=event.inspection_item_id WHERE item.receipt_id=? AND event.action='PASS'",source.receipt()),"187.5");
        assertEquals(0,jdbc.queryForObject("SELECT count(*) FROM procurement_inspection_events event JOIN procurement_inspection_items item ON item.id=event.inspection_item_id WHERE item.receipt_id=? AND event.action='PASS' AND event.released_weight IS NOT NULL",Integer.class,source.receipt()),"Unknown receipt weight cannot become a known zero");
        String committed=qualityDigest(source);
        inspections.passBatch(source.type(),source.receipt(),request);
        var reordered=new ArrayList<>(request.items());Collections.reverse(reordered);
        inspections.passBatch(source.type(),source.receipt(),new BatchInspectionPassRequest(reordered,"  "));
        conflict(()->inspections.passBatch(source.type(),source.receipt(),new BatchInspectionPassRequest(request.items().subList(1,3),null)));
        assertEquals(committed,qualityDigest(source));
        for(var item:request.items()) {
            UUID original=UUID.nameUUIDFromBytes(("PROCUREMENT_INSPECTION|"+item.inspectionItemId()+"|"+item.idempotencyKey()).getBytes(StandardCharsets.UTF_8));
            assertEquals(1,jdbc.queryForObject("SELECT count(*) FROM procurement_inspection_events WHERE id=? AND inspection_item_id=? AND action='PASS' AND batch_request_hash IS NOT NULL",Integer.class,original,item.inspectionItemId()));
        }
    }

    @Test void staleLaterMemberAndLateDatabaseErrorLeaveEveryOriginalFactUnchanged() {
        Case source=prepare("PURCHASE");var request=mixed(source);
        String before=qualityDigest(source);long version=analysisVersion(source);
        var stale=new ArrayList<>(request.items());var last=stale.getLast();
        stale.set(stale.size()-1,new BatchInspectionDecideRequest.Item(last.inspectionItemId(),new BigDecimal("1.2501"),last.passBaseQty(),last.failBaseQty(),last.idempotencyKey()));
        conflict(()->inspections.decideBatch(source.type(),source.receipt(),new BatchInspectionDecideRequest(stale,REASON)));
        assertEquals(before,qualityDigest(source));
        assertThrows(org.springframework.dao.DataAccessException.class,()->new TransactionTemplate(manager).executeWithoutResult(status->{
            inspections.decideBatch(source.type(),source.receipt(),request);
            assertEquals(6,qualityEvents(source),"Real quality and value work has already run before the late database failure");
            jdbc.queryForObject("SELECT 1/0",Integer.class);
        }));
        assertEquals(before,qualityDigest(source));
        assertEquals(version,analysisVersion(source));
        inspections.decideBatch(source.type(),source.receipt(),request);
        assertEquals(6,qualityEvents(source),"The same keys can execute after the entire original transaction rolled back");
    }

    @Test void existingSingleDecisionsAndLegacyPassBatchReplayWithoutInventedBatchEvidence() {
        Case source=prepare("PURCHASE");var items=new ArrayList<BatchInspectionPassRequest.Item>();
        for(var row:source.rows()) {
            String key="legacy-pass-"+row.inspectionId();
            inspections.dispose(source.type(),source.receipt(),row.inspectionId(),new InspectionDispositionRequest("PASS",RECEIVED,null,key));
            items.add(new BatchInspectionPassRequest.Item(row.inspectionId(),RECEIVED,key));
        }
        String original=qualityDigest(source);
        inspections.passBatch(source.type(),source.receipt(),new BatchInspectionPassRequest(items,null));
        inspections.dispose(source.type(),source.receipt(),items.getFirst().inspectionItemId(),new InspectionDispositionRequest("PASS",null,null,items.getFirst().idempotencyKey()));
        assertEquals(original,qualityDigest(source));
        assertEquals(0,jdbc.queryForObject("SELECT count(*) FROM procurement_inspection_events event JOIN procurement_inspection_items item ON item.id=event.inspection_item_id WHERE item.receipt_id=? AND batch_request_hash IS NOT NULL",Integer.class,source.receipt()));
    }

    @Test void partialOrLegacyMixedEvidenceCannotResumeAChangedBatch() {
        Case source=prepare("SUBCONTRACT");var request=mixed(source);var first=request.items().getFirst();
        inspections.dispose(source.type(),source.receipt(),first.inspectionItemId(),new InspectionDispositionRequest("PASS",first.passBaseQty(),REASON,first.idempotencyKey()+"-P"));
        String partial=qualityDigest(source);
        conflict(()->inspections.decideBatch(source.type(),source.receipt(),request));
        assertEquals(partial,qualityDigest(source));
        for(var item:request.items()) {
            if(!item.inspectionItemId().equals(first.inspectionItemId())) inspections.dispose(source.type(),source.receipt(),item.inspectionItemId(),new InspectionDispositionRequest("PASS",item.passBaseQty(),REASON,item.idempotencyKey()+"-P"));
            inspections.dispose(source.type(),source.receipt(),item.inspectionItemId(),new InspectionDispositionRequest("FAIL",item.failBaseQty(),REASON,item.idempotencyKey()+"-F"));
        }
        String legacy=qualityDigest(source);
        conflict(()->inspections.decideBatch(source.type(),source.receipt(),request));
        assertEquals(legacy,qualityDigest(source),"Historical NULL metadata cannot be backfilled from event times or audit rows");
    }

    private Case prepare(String type) {
        String tag="qb-"+UUID.randomUUID().toString().substring(0,8);
        var fixture=new WarehouseIqcMultiLineFixture(beans,jdbc).prepare(2,3,tag);
        var masters=new FullChainEndToEndTest();beans.autowireBean(masters);masters.loginAs(fixture.world().superAdminUserId());
        var rows=fixture.receipts().stream().filter(receipt->receipt.type().equals(type)).toList();
        UUID receipt=rows.getFirst().id();String prefix=type.equals("PURCHASE")?"purchase":"subcontract";
        UUID order=jdbc.queryForObject("SELECT DISTINCT item.order_id FROM "+prefix+"_order_items item JOIN "+prefix+"_receipt_items received ON received.order_item_id=item.id WHERE received.receipt_id=?",UUID.class,receipt);
        return new Case(type,receipt,order,fixture.analysisId(),rows);
    }
    private record Case(String type,UUID receipt,UUID order,UUID analysis,List<WarehouseIqcScaleFixture.Receipt> rows) {}
    private BatchInspectionDecideRequest mixed(Case source) {
        return new BatchInspectionDecideRequest(source.rows().stream().map(row->new BatchInspectionDecideRequest.Item(
                row.inspectionId(),RECEIVED,new BigDecimal("0.75"),new BigDecimal("0.50"),"mixed-"+row.inspectionId())).toList(),REASON);
    }
    private void rejectChanged(Case source,BatchInspectionDecideRequest request,BatchInspectionDecideRequest.Item changed) {
        var items=new ArrayList<>(request.items());items.set(0,changed);
        conflict(()->inspections.decideBatch(source.type(),source.receipt(),new BatchInspectionDecideRequest(items,request.reason())));
    }
    private static void conflict(Runnable action){assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,action::run).getCode());}
    private BigDecimal decimal(String sql,Object...args){return jdbc.queryForObject(sql,BigDecimal.class,args);}
    private static void money(BigDecimal value,String expected){assertEquals(0,value.compareTo(new BigDecimal(expected)));}
    private long analysisVersion(Case source){return jdbc.queryForObject("SELECT version FROM production_material_analyses WHERE id=?",Long.class,source.analysis());}
    private long orderUpdates(Case source){return jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE target_type=? AND target_id=? AND action='update'",Long.class,(source.type().equals("PURCHASE")?"purchase":"subcontract")+"_orders",source.order().toString());}
    private int qualityEvents(Case source){return jdbc.queryForObject("SELECT count(*) FROM procurement_inspection_events event JOIN procurement_inspection_items item ON item.id=event.inspection_item_id WHERE item.receipt_id=? AND event.action IN ('PASS','FAIL')",Integer.class,source.receipt());}
    private String ap(Case source){return jdbc.queryForObject("SELECT md5(coalesce(string_agg(to_jsonb(ledger)::text,',' ORDER BY id),'')) FROM ar_ap_ledger ledger WHERE source_doc_id=?",String.class,source.receipt());}
    private String qualityDigest(Case source) {
        return jdbc.queryForObject("""
                SELECT md5(concat(
                    (SELECT string_agg(to_jsonb(item)::text,',' ORDER BY item.id) FROM procurement_inspection_items item WHERE item.receipt_id=?),
                    (SELECT string_agg(to_jsonb(event)::text,',' ORDER BY event.id) FROM procurement_inspection_events event JOIN procurement_inspection_items item ON item.id=event.inspection_item_id WHERE item.receipt_id=?),
                    (SELECT string_agg(to_jsonb(part)::text,',' ORDER BY part.id) FROM procurement_iqc_quality_consideration_parts part JOIN procurement_inspection_events event ON event.id=part.inspection_event_id JOIN procurement_inspection_items item ON item.id=event.inspection_item_id WHERE item.receipt_id=?),
                    (SELECT string_agg(to_jsonb(node)::text,',' ORDER BY node.id) FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id=node.pool_id WHERE pool.goods_id IN (SELECT goods_id FROM procurement_inspection_items WHERE receipt_id=?))
                ))
                """,String.class,source.receipt(),source.receipt(),source.receipt(),source.receipt());
    }
    private static String receiptLockFingerprint()throws Exception {
        String sql="""
                SELECT id, warehouse_id, goods_id, color_id, unit_id, unit_rate,
                       received_base_qty, received_amount_local,
                       passed_base_qty, failed_base_qty, status, receipt_type,
                       received_weight, received_weight_unit_id
                FROM procurement_inspection_items
                WHERE receipt_type = ? AND receipt_id = ?
                ORDER BY id FOR UPDATE
                """;
        return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(sql.replaceAll("\\s+"," ").trim().getBytes(StandardCharsets.UTF_8))).substring(0,16);
    }
}
