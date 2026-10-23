package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.production.quality.ProductionFqcContracts.LotDecisionRequest;
import com.uten.imp.features.production.quality.ProductionFqcInspectionService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.FinishedInboundConfirmRequest;
import com.uten.imp.features.stock.dto.FinishedInboundBatchConfirmRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalLotRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.BatchArrivalRegistrationRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.boot.webmvc.test.autoconfigure.MockMvcPrint;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.servlet.MockMvc;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static com.uten.imp.testsupport.BusinessHttpRequests.authenticated;
import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** One selected physical lot must never register or receive its sibling in the same report. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.workshop-material.auto-close.enabled=false", "uten.inventory.value-work.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only"
})
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class ProductionFinishedSelectedLotEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties) {
        FullChainEndToEndTest.registerDataSource(properties);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper json;
    @Autowired MockMvc http;
    @Autowired ProductionFinishedArrivalRegistrationService arrivals;
    @Autowired ProductionFqcInspectionService quality;
    @Autowired StockDocService stock;

    @AfterEach void clear() { SecurityContextHolder.clearContext(); }

    @ParameterizedTest
    @ValueSource(booleans = {false, true})
    void selectingOneLotLeavesItsSiblingPendingThroughRegistrationQualityAndStock(boolean preStock) throws Exception {
        var fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        var world = fixture.seedWorld("finished-selected-" + UUID.randomUUID().toString().substring(0, 6));
        ReflectionTestUtils.invokeMethod(fixture, "receiveOpeningInputsForA", world, "20");
        Object report = ReflectionTestUtils.invokeMethod(fixture, "approvedMultiLineReportOfNewPlan",
                world, (Object) new String[]{"3", "7"});
        UUID reportId = ReflectionTestUtils.invokeMethod(report, "id");
        assertThat(reportId).isNotNull();
        fixture.loginAs(world.superAdminUserId());

        var initial = arrivals.batchDetail(List.of(reportId)).getFirst();
        assertThat(initial.lots()).hasSize(2);
        var selected = initial.lots().getFirst();
        var sibling = initial.lots().get(1);
        assertThat(selected.lotId()).isNotEqualTo(sibling.lotId());
        assertThat(selected.members()).hasSize(1);
        assertThat(sibling.members()).hasSize(1);
        UUID selectedItem = selected.members().getFirst().reportItemId();
        UUID siblingItem = sibling.members().getFirst().reportItemId();
        String siblingBefore = sourceSnapshot(siblingItem);
        assertThat(selected.reportedQty()).isEqualByComparingTo("3");
        assertThat(sibling.reportedQty()).isEqualByComparingTo("7");

        var request = new BatchArrivalRegistrationRequest("selected-lot-" + reportId,
                List.of(new ArrivalLotRequest(selected.lotId(), world.warehouseId(), "SELECTED-A",
                        preStock ? selected.reportedQty() : null, null)), null, preStock);
        String body = json.writeValueAsString(request);
        var actor = SecurityContextHolder.getContext().getAuthentication();
        http.perform(post("/api/warehouse/production-finished-in/arrival-registrations/batch")
                .with(authenticated(actor)).contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().isOk());
        fixture.loginAs(world.superAdminUserId());

        assertThat(db.queryForList("""
                SELECT item.source_report_item_id
                FROM production_finished_arrival_registration_items item
                JOIN production_finished_arrival_registrations registration ON registration.id=item.registration_id
                WHERE registration.source_report_id=? AND item.reversal_id IS NULL
                """, UUID.class, reportId)).containsExactly(selectedItem);
        assertThat(db.queryForList("SELECT source_report_item_id FROM production_fqc_inspections WHERE source_report_id=? AND status<>'CANCELLED'",
                UUID.class, reportId)).containsExactly(selectedItem);
        assertSiblingPending(reportId, sibling.lotId(), siblingItem, siblingBefore);

        quality.decideLot(selected.lotId(), new LotDecisionRequest(selected.reportedQty(), BigDecimal.ZERO,
                null, null, "selected-lot-pass-" + reportId));
        UUID document = db.queryForObject("SELECT id FROM stock_documents WHERE source_daily_report_id=? AND doc_type='FINISHED_IN' AND NOT is_deleted",
                UUID.class, reportId);
        assertThat(db.queryForList("SELECT source_daily_report_item_id FROM stock_document_items WHERE doc_id=? AND NOT is_deleted",
                UUID.class, document)).containsExactly(selectedItem);
        if (!preStock) {
            assertThat(db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_id=?", Integer.class, document)).isZero();
            var accepted = new FinishedInboundConfirmRequest.Lot();
            accepted.setLotId(selected.lotId());
            accepted.setAcceptedQty(selected.reportedQty());
            var confirmation = new FinishedInboundConfirmRequest();
            confirmation.setIdempotencyKey("selected-lot-count-" + reportId);
            confirmation.setLots(List.of(accepted));
            stock.confirmFinishedInbound(document, confirmation);
        }
        assertThat(db.queryForObject("SELECT status FROM stock_documents WHERE id=?", Integer.class, document)).isEqualTo(1);
        assertThat(db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_movements WHERE source_doc_id=? AND direction=1",
                BigDecimal.class, document)).isEqualByComparingTo(selected.reportedQty());
        assertSiblingPending(reportId, sibling.lotId(), siblingItem, siblingBefore);

        int registrations = db.queryForObject("SELECT count(*) FROM production_finished_arrival_registrations WHERE source_report_id=?", Integer.class, reportId);
        int movements = db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_id=?", Integer.class, document);
        http.perform(post("/api/warehouse/production-finished-in/arrival-registrations/batch")
                .with(authenticated(actor)).contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().isOk());
        fixture.loginAs(world.superAdminUserId());
        assertThat(db.queryForObject("SELECT count(*) FROM production_finished_arrival_registrations WHERE source_report_id=?", Integer.class, reportId)).isEqualTo(registrations);
        assertThat(db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_id=?", Integer.class, document)).isEqualTo(movements);
        assertSiblingPending(reportId, sibling.lotId(), siblingItem, siblingBefore);
    }

    @Test
    void selectedFinalCountLeavesUnselectedStockItemsPendingAndReplayCannotExpand() {
        var fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        var world = fixture.seedWorld("finished-item-" + UUID.randomUUID().toString().substring(0, 6));
        ReflectionTestUtils.invokeMethod(fixture, "receiveOpeningInputsForA", world, "20");
        Object report = ReflectionTestUtils.invokeMethod(fixture, "approvedMultiLineReportOfNewPlan",
                world, (Object) new String[]{"3", "7"});
        UUID reportId = ReflectionTestUtils.invokeMethod(report, "id");
        fixture.loginAs(world.superAdminUserId());
        var lots = arrivals.batchDetail(List.of(reportId)).getFirst().lots();
        arrivals.batchRegister(new BatchArrivalRegistrationRequest("final-count-register-" + reportId,
                lots.stream().map(lot -> new ArrivalLotRequest(lot.lotId(), world.warehouseId(), "FINAL-A", null, null)).toList(),
                null, false));
        List<UUID> inspectionIds = db.queryForList("SELECT id FROM production_fqc_inspections WHERE source_report_id=? AND status='PENDING'",
                UUID.class, reportId);
        quality.passAll(new com.uten.imp.features.production.quality.ProductionFqcContracts.PassAllBatchRequest(
                inspectionIds, "final-count-pass-" + reportId));
        UUID documentId = db.queryForObject("SELECT id FROM stock_documents WHERE source_daily_report_id=? AND doc_type='FINISHED_IN' AND status=0 AND NOT is_deleted",
                UUID.class, reportId);
        List<UUID> itemIds = db.queryForList("SELECT id FROM stock_document_items WHERE doc_id=? AND NOT is_deleted ORDER BY qty,id",
                UUID.class, documentId);
        assertThat(itemIds).hasSize(2);
        var request = new FinishedInboundBatchConfirmRequest();
        request.setIdempotencyKey("final-count-selected-" + reportId);
        request.setDocumentIds(List.of(documentId));
        request.setItemIds(List.of(itemIds.getFirst()));
        var result = stock.confirmFinishedInboundBatch(request);
        assertThat(result.confirmedCount()).isEqualTo(1);
        assertThat(db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_movements WHERE source_doc_id=? AND direction=1",
                BigDecimal.class, documentId)).isEqualByComparingTo("3");
        assertThat(db.queryForObject("SELECT COALESCE(SUM(item.qty),0) FROM stock_document_items item JOIN stock_documents document ON document.id=item.doc_id WHERE document.source_daily_report_id=? AND document.doc_type='FINISHED_IN' AND document.status=0 AND NOT document.is_deleted AND NOT item.is_deleted",
                BigDecimal.class, reportId)).isEqualByComparingTo("7");
        assertThat(stock.confirmFinishedInboundBatch(request).replay()).isTrue();
        request.setItemIds(itemIds);
        org.junit.jupiter.api.Assertions.assertThrows(com.uten.imp.common.web.ApiException.class,
                () -> stock.confirmFinishedInboundBatch(request));
        assertThat(db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_item_id=?", Integer.class, itemIds.get(1))).isZero();
    }

    private void assertSiblingPending(UUID report, UUID siblingLot, UUID siblingItem, String before) {
        assertThat(arrivals.batchDetail(List.of(report)).getFirst().lots())
                .extracting(lot -> lot.lotId()).containsExactly(siblingLot);
        assertThat(db.queryForObject("SELECT count(*) FROM production_fqc_inspections WHERE source_report_item_id=?",
                Integer.class, siblingItem)).isZero();
        assertThat(sourceSnapshot(siblingItem)).isEqualTo(before);
    }

    private String sourceSnapshot(UUID item) {
        return db.queryForObject("SELECT row_to_json(item)::text FROM production_daily_report_items item WHERE item.id=?", String.class, item);
    }
}
