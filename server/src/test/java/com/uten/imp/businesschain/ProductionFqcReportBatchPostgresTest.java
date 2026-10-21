package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine;
import com.uten.imp.features.production.execution.ProductionCompletionReverseService;
import com.uten.imp.features.production.quality.ProductionFqcContracts.*;
import com.uten.imp.features.production.quality.ProductionFqcInspectionService;
import com.uten.imp.features.production.quality.ProductionFqcRecordQueryService;
import com.uten.imp.features.production.quality.ProductionQualityMutationFootprintService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.warehouse.finishedin.FinishedArrivalTestSupport;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.mockito.ArgumentCaptor;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.boot.webmvc.test.autoconfigure.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.test.util.AopTestUtils;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.servlet.MockMvc;

import java.math.BigDecimal;
import java.util.*;
import java.util.concurrent.*;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyCollection;
import static org.mockito.Mockito.*;
import static com.uten.imp.testsupport.BusinessHttpRequests.authenticated;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/** Exact quantities and original row receipts across one real FQC report transaction. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false", "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false", "uten.concurrency.verify-nested-footprint=false",
        "uten.workshop-material.auto-close.enabled=false", "uten.inventory.value-work.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class ProductionFqcReportBatchPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties) { FullChainEndToEndTest.registerDataSource(properties); }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper json;
    @Autowired MockMvc http;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired StockDocService stock;
    @Autowired ProductionFinishedArrivalRegistrationService arrivals;
    @Autowired ProductionFqcInspectionService quality;
    @Autowired ProductionFqcRecordQueryService records;
    @MockitoSpyBean ProductionCompletionReverseService completion;
    @MockitoSpyBean ProductionQualityMutationFootprintService footprints;
    @AfterEach void clear() { SecurityContextHolder.clearContext(); }

    @Test void searchQueuesAndDecisionRecordsUseLiteralWordsWithoutChangingPendingQuantities() {
        Source source = source(2);
        var inspection = quality.detail(source.ids().getFirst());
        String name = "检索成品" + UUID.randomUUID() + "10%_";
        String oldName = db.queryForObject("SELECT name FROM goods WHERE id=?",String.class,inspection.goodsId());
        db.update("UPDATE goods SET name=? WHERE id=?",name,inspection.goodsId());
        try {
            String compound = "10%_\t" + inspection.reportNo();
            var first = quality.list("ACTIVE",compound,null,1,1);
            var second = quality.list("ACTIVE",compound,null,2,1);
            assertEquals(2,first.getTotal());
            assertNotEquals(first.getItems().getFirst().id(),second.getItems().getFirst().id());
            amount("1",first.getItems().getFirst().remainingQty());
            assertEquals(0,quality.list("ACTIVE","10__ "+inspection.reportNo(),null,1,20).getTotal());
            var sheets = quality.listSheets("ACTIVE",compound,1,20);
            assertEquals(1,sheets.getTotal());
            assertEquals(2,sheets.getItems().getFirst().itemCount());
            quality.decide(source.ids().getFirst(),new DecisionRequest("PASS",new BigDecimal(".25"),null,null,null,"search-decision-"+UUID.randomUUID()));
            var result = records.list(null,compound,null,null,null,null,null,1,20,null,null,null,null,null);
            assertEquals(1,result.total());
            assertEquals(source.ids().getFirst(),result.items().getFirst().inspectionId());
            amount(".25",result.items().getFirst().passQty());
            assertEquals(1,records.facets(null,compound,null,null,null,null,null).get("sourceNo").size());
            assertEquals(0,records.list(null,"10__ "+inspection.reportNo(),null,null,null,null,null,1,20,null,null,null,null,null).total());
        } finally {
            db.update("UPDATE goods SET name=? WHERE id=?",oldName,inspection.goodsId());
        }
    }

    @Test void mixedExactRowsCommitPhysicalSourcesAndReplayTheirOriginalLotAndSingleKeys() throws Exception {
        Source source = source(3);
        var lot = lotRow(source.ids().get(0), ".6", ".2", "REWORK");
        var single = singleRow(source.ids().get(1), "PASS", ".75", null, null);
        var rejected = lotRow(source.ids().get(2), "0", "1", "SCRAP");
        var request = new ReportDecisionRequest(List.of(lot, single, rejected));
        var result = call(source.actor(), request, 200);
        assertResponse(request, result, false, false, false);
        amount(".2", quality.detail(source.ids().get(0)).remainingQty());
        amount(".25", quality.detail(source.ids().get(1)).remainingQty());
        amount("0", quality.detail(source.ids().get(2)).remainingQty());
        amount("1.35", scalar("SELECT COALESCE(SUM(m.qty),0) FROM stock_movements m JOIN stock_documents d ON d.id=m.source_doc_id WHERE d.source_daily_report_id=? AND m.direction=1", source.report()));
        amount("1.2", scalar("SELECT SUM(a.authorized_qty) FROM production_fqc_recovery_authorizations a JOIN production_fqc_inspections i ON i.id=a.source_inspection_id WHERE i.source_report_id=?", source.report()));
        assertEquals(0, db.queryForObject("""
                SELECT count(*) FROM production_fqc_release_commands c
                JOIN production_fqc_inspections i ON i.id=c.inspection_id
                JOIN stock_document_items item ON item.id=c.stock_document_item_id
                WHERE i.source_report_id=? AND (c.source_report_item_id<>i.source_report_item_id
                  OR item.source_daily_report_item_id<>i.source_report_item_id)
                """, Integer.class, source.report()));
        Map<String, String> facts = facts();
        assertResponse(request, call(source.actor(), request, 200), true, true, true);
        assertTrue(quality.decideLot(lot.targetId(), originalLot(lot)).replay());
        assertTrue(quality.decide(single.targetId(), originalSingle(single)).replay());
        assertEquals(facts, facts(), "Report retries and old endpoint retries cannot duplicate any physical/value/quality facts");
    }

    @Test void oldCommittedRowsAndFreshRowsShareOneReportWithoutRequiringOldLotWriteFootprints() throws Exception {
        Source source = source(3);
        var oldLot = lotRow(source.ids().get(0), ".4", "0", null);
        var oldSingle = singleRow(source.ids().get(1), "PASS", ".25", null, null);
        var fresh = lotRow(source.ids().get(2), ".5", "0", null);
        UUID lotCommand = quality.decideLot(oldLot.targetId(), originalLot(oldLot)).lotCommandId();
        UUID singleCommand = quality.decide(oldSingle.targetId(), originalSingle(oldSingle)).decisionEventId();
        clearInvocations(footprints);
        var request = new ReportDecisionRequest(List.of(oldLot, fresh, oldSingle));
        var result = call(source.actor(), request, 200);
        assertResponse(request, result, true, false, true);
        assertEquals(lotCommand, result.items().get(0).commandId());
        assertEquals(singleCommand, result.items().get(2).commandId());
        @SuppressWarnings("unchecked") ArgumentCaptor<Collection<UUID>> scope = ArgumentCaptor.forClass(Collection.class);
        verify(footprints).beginInspections(scope.capture());
        assertEquals(Set.of(source.ids().get(1), source.ids().get(2)), Set.copyOf(scope.getValue()));
        amount("1.15", scalar("SELECT SUM(passed_qty) FROM production_fqc_inspections WHERE source_report_id=?", source.report()));
    }

    @Test void allLotReplayNeverReentersMutableFootprintEvenAfterOriginalRowsAreResolved() throws Exception {
        Source source = source(2);
        var request = new ReportDecisionRequest(source.ids().stream().map(id -> lotRow(id, "1", "0", null)).toList());
        var original = call(source.actor(), request, 200);
        Map<String, String> facts = facts();
        var target = AopTestUtils.<ProductionQualityMutationFootprintService>getUltimateTargetObject(footprints);
        doThrow(new IllegalStateException("No writable source available after closeout")).when(target).beginInspections(anyCollection());
        try {
            var replay = call(source.actor(), request, 200);
            assertResponse(request, replay, true, true);
            assertEquals(original.items().stream().map(ReportDecisionItemResult::commandId).toList(),
                    replay.items().stream().map(ReportDecisionItemResult::commandId).toList());
        } finally { doCallRealMethod().when(target).beginInspections(anyCollection()); }
        assertEquals(facts, facts());
    }

    @Test void laterExcessQuantityAndLaterPhysicalFailureRollBackEveryFreshRow() throws Exception {
        Source source = source(2);
        var first = lotRow(source.ids().get(0), ".5", ".5", "REWORK");
        var excessive = lotRow(source.ids().get(1), "2", "0", null);
        Map<String, String> before = facts();
        call(source.actor(), new ReportDecisionRequest(List.of(first, excessive)), 409);
        assertEquals(before, facts(), "A late quantity rejection rolls back the earlier quality and recovery events");
        var second = lotRow(source.ids().get(1), "1", "0", null);
        var request = new ReportDecisionRequest(List.of(first, second));
        var target = AopTestUtils.<ProductionCompletionReverseService>getUltimateTargetObject(completion);
        doThrow(new IllegalStateException("final report inbound projection failed")).when(target).afterFinishedInboundBatchApproved(anyCollection());
        try { call(source.actor(), request, 500); }
        finally { doCallRealMethod().when(target).afterFinishedInboundBatchApproved(anyCollection()); }
        assertEquals(before, facts(), "Late real stock finalization must roll back events, stock and value in the same transaction");
        assertResponse(request, call(source.actor(), request, 200), false, false);
    }

    @Test void originalKeyContentConflictCannotCommitAnEarlierFreshRowAndLegacyActorIsChecked() throws Exception {
        Source source = source(2);
        var oldLot = lotRow(source.ids().get(1), ".25", "0", null);
        quality.decideLot(oldLot.targetId(), originalLot(oldLot));
        var changed = new ReportDecisionItem("LOT", oldLot.targetId(), null, new BigDecimal(".5"), BigDecimal.ZERO,
                null, null, oldLot.idempotencyKey());
        Map<String, String> before = facts();
        call(source.actor(), new ReportDecisionRequest(List.of(lotRow(source.ids().get(0), "1", "0", null), changed)), 409);
        assertEquals(before, facts());
        var original = singleRow(source.ids().get(0), "PASS", ".25", null, null);
        quality.decide(original.targetId(), originalSingle(original));
        Source otherActor = source(1);
        before = facts();
        call(otherActor.actor(), new ReportDecisionRequest(List.of(original)), 409);
        assertEquals(before, facts(), "Inspection keys retain the original actor check across the new endpoint");
    }

    @Test void duplicateOverlappingTargetsAndMissingAuthorityOrQualityScopeAreRejectedWithoutEffects() throws Exception {
        Source source = source(1);
        var lot = lotRow(source.ids().getFirst(), "1", "0", null);
        var single = singleRow(source.ids().getFirst(), "PASS", "1", null, null);
        Map<String, String> before = facts();
        call(source.actor(), new ReportDecisionRequest(List.of(lot, lot)), 422);
        call(source.actor(), new ReportDecisionRequest(List.of(lot, single)), 422);
        AuthUser actor = (AuthUser) source.actor().getPrincipal();
        for (Set<String> permissions : List.of(Set.of("production_quality_inspection:view"),
                Set.of("production_quality_inspection:view", "production_quality_inspection:approve"))) {
            AuthUser restricted = new AuthUser(actor.getId(), null, actor.getLoginAccount(), permissions, false, true, false);
            call(new UsernamePasswordAuthenticationToken(restricted, null, restricted.getAuthorities()),
                    new ReportDecisionRequest(List.of(lot)), 403);
        }
        assertEquals(before, facts());
    }

    @Test void mixedMultiSliceLotRetainsDemandFirstPassAndSurplusFirstFailure() throws Exception {
        var fixture = new WorkshopPublicSurplusEndToEndTest();
        beans.autowireBean(fixture); fixture.prepare();
        Object task = ReflectionTestUtils.invokeMethod(fixture, "createStartedTask", "fqc-report-lot-" + UUID.randomUUID(), false, "1000");
        List<ReportablePlanLine> sources = ReflectionTestUtils.invokeMethod(fixture, "sources", task);
        UUID report = ReflectionTestUtils.invokeMethod(fixture, "approveReport", task, sources.getFirst(), "1100", "1000");
        Object world = ReflectionTestUtils.invokeMethod(task, "world");
        UUID warehouse = ReflectionTestUtils.invokeMethod(world, "warehouseId");
        FinishedArrivalTestSupport.registerAll(arrivals, report, "mixed-lot-arrival-" + report, warehouse, "FQC-MIXED", null, false);
        List<Map<String, Object>> slices = db.queryForList("SELECT i.id, item.is_actual_surplus, item.output_lot_id FROM production_fqc_inspections i JOIN production_daily_report_items item ON item.id=i.source_report_item_id WHERE i.source_report_id=? ORDER BY item.is_actual_surplus", report);
        assertEquals(2, slices.size());
        UUID demand = (UUID) slices.getFirst().get("id"), surplus = (UUID) slices.getLast().get("id");
        var lot = lotRow(demand, "950", "150", "REWORK");
        Source single = source(1);
        var singleRow = singleRow(single.ids().getFirst(), "PASS", ".5", null, null);
        var request = new ReportDecisionRequest(List.of(lot, singleRow));
        assertResponse(request, call(single.actor(), request, 200), false, false);
        amount("950", quality.detail(demand).passedQty()); amount("50", quality.detail(demand).failedQty());
        amount("0", quality.detail(surplus).passedQty()); amount("100", quality.detail(surplus).failedQty());
        amount("950", scalar("SELECT SUM(item.qty) FROM stock_document_items item JOIN stock_documents document ON document.id=item.doc_id WHERE document.source_daily_report_id=? AND NOT item.is_deleted", report));
        Map<String, String> facts = facts();
        assertResponse(request, call(single.actor(), request, 200), true, true);
        assertEquals(facts, facts());
    }

    @Test void concurrentOppositeRowOrderReplaysOneCommittedReportWithoutDeadlockOrDuplicateSources() throws Exception {
        Source source = source(2);
        List<ReportDecisionItem> rows = source.ids().stream().map(id -> lotRow(id, "1", "0", null)).toList();
        CountDownLatch ready = new CountDownLatch(2), start = new CountDownLatch(1);
        try (ExecutorService executor = Executors.newFixedThreadPool(2)) {
            List<Future<ReportDecisionResult>> results = new ArrayList<>();
            for (List<ReportDecisionItem> order : List.of(rows, rows.reversed())) {
                results.add(executor.submit(() -> {
                    SecurityContextHolder.getContext().setAuthentication(source.actor());
                    ready.countDown();
                    try { assertTrue(start.await(20, TimeUnit.SECONDS)); return quality.decideReport(new ReportDecisionRequest(order)); }
                    finally { SecurityContextHolder.clearContext(); }
                }));
            }
            assertTrue(ready.await(20, TimeUnit.SECONDS)); start.countDown();
            var first = results.getFirst().get(60, TimeUnit.SECONDS);
            var second = results.getLast().get(60, TimeUnit.SECONDS);
            assertEquals(2, java.util.stream.Stream.concat(first.items().stream(), second.items().stream())
                    .filter(ReportDecisionItemResult::replay).count());
        }
        assertEquals(2, db.queryForObject("SELECT count(*) FROM production_fqc_decision_events e JOIN production_fqc_inspections i ON i.id=e.inspection_id WHERE i.source_report_id=?", Integer.class, source.report()));
        amount("2", scalar("SELECT SUM(m.qty) FROM stock_movements m JOIN stock_documents d ON d.id=m.source_doc_id WHERE d.source_daily_report_id=? AND m.direction=1", source.report()));
    }

    private Source source(int count) {
        var fixture = new ProductionFqcPreStockBatchEndToEndTest();
        for (var field : Map.of("beans", beans, "db", db, "analyses", analyses, "commands", commands, "stock", stock, "arrivals", arrivals).entrySet()) {
            ReflectionTestUtils.setField(fixture, field.getKey(), field.getValue());
        }
        Object scenario = ReflectionTestUtils.invokeMethod(fixture, "prepare", count, "prestock");
        return new Source(ReflectionTestUtils.invokeMethod(scenario, "reportId"),
                ReflectionTestUtils.invokeMethod(scenario, "inspections"), SecurityContextHolder.getContext().getAuthentication());
    }

    private ReportDecisionItem lotRow(UUID inspection, String pass, String fail, String disposition) {
        UUID lot = db.queryForObject("SELECT item.output_lot_id FROM production_fqc_inspections i JOIN production_daily_report_items item ON item.id=i.source_report_item_id WHERE i.id=?", UUID.class, inspection);
        return new ReportDecisionItem("LOT", lot, null, new BigDecimal(pass), new BigDecimal(fail), disposition,
                disposition == null ? null : "检验报告不良处置", "report-lot-" + UUID.randomUUID());
    }
    private static ReportDecisionItem singleRow(UUID inspection, String decision, String pass, String fail, String disposition) {
        return new ReportDecisionItem("INSPECTION", inspection, decision, pass == null ? null : new BigDecimal(pass),
                fail == null ? null : new BigDecimal(fail), disposition, disposition == null ? null : "检验报告不良处置",
                "report-inspection-" + UUID.randomUUID());
    }
    private static LotDecisionRequest originalLot(ReportDecisionItem row) {
        return new LotDecisionRequest(row.passQty(), row.failQty(), row.dispositionCode(), row.reason(), row.idempotencyKey());
    }
    private static DecisionRequest originalSingle(ReportDecisionItem row) {
        return new DecisionRequest(row.decision(), row.passQty(), row.failQty(), row.dispositionCode(), row.reason(), row.idempotencyKey());
    }
    private ReportDecisionResult call(Authentication actor, ReportDecisionRequest request, int status) throws Exception {
        SecurityContextHolder.getContext().setAuthentication(actor);
        var response = http.perform(post("/api/production/quality-inspections/decisions/report").with(authenticated(actor))
                .contentType("application/json").content(json.writeValueAsBytes(request))).andReturn().getResponse();
        assertEquals(status, response.getStatus(), response.getContentAsString());
        SecurityContextHolder.getContext().setAuthentication(actor);
        return status == 200 ? json.readValue(response.getContentAsByteArray(), ReportDecisionResult.class) : null;
    }
    private static void assertResponse(ReportDecisionRequest request, ReportDecisionResult result, boolean... replay) {
        assertEquals(request.items().size(), result.items().size());
        for (int index = 0; index < request.items().size(); index++) {
            var expected = request.items().get(index); var actual = result.items().get(index);
            assertEquals(expected.targetType(), actual.targetType()); assertEquals(expected.targetId(), actual.targetId());
            assertEquals(expected.idempotencyKey(), actual.idempotencyKey()); assertNotNull(actual.commandId());
            assertEquals(replay[index], actual.replay());
            if ("LOT".equals(expected.targetType())) { assertNotNull(actual.lot()); assertNull(actual.inspection()); assertEquals(expected.targetId(), actual.lot().lotId()); }
            else { assertNotNull(actual.inspection()); assertNull(actual.lot()); assertEquals(expected.targetId(), actual.inspection().id()); }
        }
    }
    private Map<String, String> facts() {
        Map<String, String> result = new LinkedHashMap<>();
        for (String table : List.of("production_fqc_inspections", "production_fqc_lot_decision_commands", "production_fqc_decision_events",
                "production_fqc_contribution_adjustments", "production_fqc_recovery_authorizations", "production_fqc_release_commands",
                "production_fqc_release_allocations", "stock_documents", "stock_document_items", "stock_movements", "stock_balances",
                "stock_value_pools", "stock_value_events", "stock_value_nodes", "stock_value_edges", "stock_value_postings", "stock_value_position_transfers")) {
            result.put(table, db.queryForObject("SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, E'\\n' ORDER BY to_jsonb(t)::text),'')) FROM " + table + " t", String.class));
        }
        return result;
    }
    private BigDecimal scalar(String sql, Object arg) { return db.queryForObject(sql, BigDecimal.class, arg); }
    private static void amount(String expected, BigDecimal actual) { assertNotNull(actual); assertEquals(0, new BigDecimal(expected).compareTo(actual)); }
    private record Source(UUID report, List<UUID> ids, Authentication actor) {}
}
