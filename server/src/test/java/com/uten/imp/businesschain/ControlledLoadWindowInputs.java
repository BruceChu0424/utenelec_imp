package com.uten.imp.businesschain;

import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.quality.ProductionFqcContracts.PassAllBatchRequest;
import com.uten.imp.features.production.quality.ProductionFqcInspectionService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocIssueBatchRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService;
import com.uten.imp.security.AuthUser;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.util.ReflectionTestUtils;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.BooleanSupplier;
import java.util.function.Supplier;
import static org.junit.jupiter.api.Assertions.*;

/** New commands with immutable receipt identities; this factory never fabricates stock balances. */
final class ControlledLoadWindowInputs {
    record Input(String scenario, UUID commandId, Set<UUID> goods, Supplier<?> command,
                 Runnable verifyBusinessFacts, BooleanSupplier receiptExists, Map<String, Object> metadata) { }
    private final AutowireCapableBeanFactory beans;
    private final JdbcTemplate db;
    ControlledLoadWindowInputs(AutowireCapableBeanFactory beans, JdbcTemplate db) { this.beans = beans; this.db = db; }

    Input prepare(String scenario) {
        UUID id = UUID.randomUUID();
        if (scenario.startsWith("daily-report-")) {
            var original = ControlledDailyReportInputs.prepare(beans, db, Integer.parseInt(scenario.substring(13)), "window-" + id);
            var metadata = new LinkedHashMap<>(original.metadata());
            metadata.put("scenario", scenario); metadata.put("commandId", id);
            return new Input(scenario, id, original.goodsIds(), original.command(), original.verify(), () ->
                    db.queryForObject("SELECT count(*) FROM production_daily_report_commands WHERE report_id=? AND command_kind='APPROVE' AND idempotency_key=? AND actor_user_id=?",
                            Integer.class, original.reportId(), original.metadata().get("approvalKey"), original.metadata().get("actorUserId")) == 1, metadata);
        }
        if (scenario.startsWith("fqc-20-")) return fqc(id, scenario.substring(7));
        if (scenario.startsWith("draw-")) return draw(id, Integer.parseInt(scenario.substring(5)));
        throw new IllegalArgumentException("Unknown scenario " + scenario);
    }

    private Input fqc(UUID id, String mode) {
        var fixture = new ProductionFqcPreStockBatchEndToEndTest();
        for (var entry : Map.<String, Object>of("beans", beans, "db", db,
                "analyses", beans.getBean(MaterialAnalysisService.class), "commands", beans.getBean(MaterialAnalysisCommandService.class),
                "stock", beans.getBean(StockDocService.class), "arrivals", beans.getBean(ProductionFinishedArrivalRegistrationService.class)).entrySet())
            ReflectionTestUtils.setField(fixture, entry.getKey(), entry.getValue());
        Object prepared = ReflectionTestUtils.invokeMethod(fixture, "prepare", 20, mode);
        FullChainEndToEndTest.World world = ReflectionTestUtils.invokeMethod(prepared, "world");
        UUID report = ReflectionTestUtils.invokeMethod(prepared, "reportId");
        List<UUID> inspections = ReflectionTestUtils.invokeMethod(prepared, "inspections");
        assertNotNull(world); assertNotNull(report); assertNotNull(inspections);
        String key = "load-window-fqc-" + id;
        var request = new PassAllBatchRequest(inspections, key);
        Authentication authentication = SecurityContextHolder.getContext().getAuthentication();
        UUID actor = ((AuthUser) authentication.getPrincipal()).getId();
        var quality = beans.getBean(ProductionFqcInspectionService.class);
        return new Input("fqc-20-" + mode, id, goods(world), withActor(authentication, () -> quality.passAll(request)),
                () -> ReflectionTestUtils.invokeMethod(fixture, "assertFacts", prepared), () -> db.queryForObject("""
                    SELECT count(*) FROM production_fqc_pass_all_batches batch
                    WHERE batch.created_by=? AND batch.idempotency_key=? AND batch.inspection_count=20
                      AND (SELECT count(*) FROM production_fqc_pass_all_batch_items item WHERE item.batch_id=batch.id)=20
                    """, Integer.class, actor, key) == 1,
                Map.of("scenario", "fqc-20-" + mode, "commandId", id, "reportId", report,
                        "inspectionIds", inspections, "actorUserId", actor, "idempotencyKey", key,
                        "source", "real priced OTHER_IN/DRAW/report/arrival"));
    }

    private Input draw(UUID id, int count) {
        var fixture = new FullChainEndToEndTest(); beans.autowireBean(fixture);
        var world = fixture.seedWorld("load-window-draw-" + id);
        fixture.loginAs(world.superAdminUserId());
        ReflectionTestUtils.invokeMethod(fixture, "receiveOpeningInputsForA", world, Integer.toString(count * 10));
        List<UUID> documents = new ArrayList<>();
        for (int i = 0; i < count; i++) documents.add(ReflectionTestUtils.invokeMethod(fixture,
                "generateSingleWarehouseDraw", world, "window-draw-plan-" + UUID.randomUUID()));
        fixture.requestWorkshopDraws("window-draw-" + id, documents);
        var request = new StockDocIssueBatchRequest(); request.setIdempotencyKey("load-window-draw-" + id); request.setDocIds(documents);
        Authentication authentication = SecurityContextHolder.getContext().getAuthentication();
        UUID actor = ((AuthUser) authentication.getPrincipal()).getId();
        return new Input("draw-" + count, id, goods(world), withActor(authentication, () -> beans.getBean(StockDocService.class).issueFullBatch(request)),
                () -> {
                    for (UUID document : documents) {
                        assertEquals(1, db.queryForObject("SELECT status FROM stock_documents WHERE id=?", Integer.class, document));
                        assertEquals(0, db.queryForObject("SELECT count(*) FROM stock_document_items WHERE doc_id=? AND NOT is_deleted AND issued_qty<>fn_production_draw_item_requested_qty(id)", Integer.class, document));
                        assertEquals(1, db.queryForObject("SELECT count(*) FROM production_material_stock_events WHERE stock_document_id=? AND event_type='ISSUE'", Integer.class, document));
                    }
                }, () -> db.queryForObject("SELECT count(*) FROM stock_draw_issue_batches WHERE actor_user_id=? AND idempotency_key=?",
                        Integer.class, actor, request.getIdempotencyKey()) == 1,
                Map.of("scenario", "draw-" + count, "commandId", id, "documentIds", documents, "actorUserId", actor,
                        "idempotencyKey", request.getIdempotencyKey(), "source", "priced OTHER_IN B20+E10 per A10 plan"));
    }
    private static Set<UUID> goods(FullChainEndToEndTest.World world) { return Set.of(world.goodsA(), world.goodsB(), world.goodsC(), world.goodsD(), world.goodsE()); }
    private static Supplier<?> withActor(Authentication authentication, Supplier<?> action) {
        return () -> {
            var previous = SecurityContextHolder.getContext(); var selected = SecurityContextHolder.createEmptyContext();
            selected.setAuthentication(authentication); SecurityContextHolder.setContext(selected);
            try { return action.get(); } finally { SecurityContextHolder.setContext(previous); }
        };
    }
}
