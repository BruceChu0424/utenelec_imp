package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.dto.DailyReportApproveRequest;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialUsageLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportOutputAllocationLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContext;
import org.springframework.security.core.context.SecurityContextHolder;

import java.math.BigDecimal;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.function.Supplier;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Complete, isolated inputs for the controlled runner's existing Spring context.
 * Preparation is outside the measured command. No balance or movement is seeded
 * directly: OTHER_IN approval supplies 2 units per manufactured child, and a real
 * DRAW is requested, approved and issued before the source segment starts.
 */
public final class ControlledDailyReportInputs {
    private ControlledDailyReportInputs() {}

    /**
     * goodsIds is the authoritative reconciliation scope across ALL warehouses.
     * warehouseIds contains only locations known at preparation time: approval
     * may create a line-side warehouse, so never limit reconciliation to that set.
     * command uses one stable approval key, making a repeated invocation a replay.
     * verify is read-only and must run after a successful command/replay settles.
     */
    public record Prepared(UUID reportId, Set<UUID> goodsIds, Set<UUID> warehouseIds,
                           Supplier<?> command, Runnable verify, Map<String, Object> metadata) {
        public Prepared {
            goodsIds = Set.copyOf(goodsIds);
            warehouseIds = Set.copyOf(warehouseIds);
            metadata = Map.copyOf(metadata);
        }
    }

    public static Prepared prepare(AutowireCapableBeanFactory beans, JdbcTemplate db,
                                   int receivers, String runTag) {
        Objects.requireNonNull(beans, "beans");
        Objects.requireNonNull(db, "db");
        if (!Set.of(1, 3, 11).contains(receivers)) {
            throw new IllegalArgumentException("Controlled daily-report receivers must be 1, 3 or 11");
        }
        if (runTag == null || runTag.isBlank() || runTag.length() > 80) {
            throw new IllegalArgumentException("runTag must be nonblank and at most 80 characters");
        }
        SecurityContext previous = SecurityContextHolder.getContext();
        SecurityContextHolder.setContext(SecurityContextHolder.createEmptyContext());
        try {
            return prepareAuthenticated(beans, db, receivers, runTag.strip());
        } finally {
            SecurityContextHolder.setContext(previous);
        }
    }

    private static Prepared prepareAuthenticated(AutowireCapableBeanFactory beans, JdbcTemplate db,
                                                 int receivers, String runTag) {
        var helper = new AggregateMaterialDirectTransferEndToEndTest();
        beans.autowireBean(helper);
        helper.before();
        var flow = helper.flow;
        var c = flow.createWithChild("1", receivers);
        var shared = flow.writer.submit(c.analysis(), flow.command(c, List.of(
                flow.input(c, c.child(), "MAKE", Integer.toString(receivers), false)))).batches().getFirst();
        List<UUID> parents = helper.issue(c, c.common(), "1");
        assertEquals(receivers, parents.size());
        UUID source = helper.segment(shared.planId());
        UUID sourceDemand = helper.demand(source);
        BigDecimal inputQuantity = BigDecimal.valueOf(receivers * 2L);
        flow.receive(c, c.material(), inputQuantity.toPlainString());
        helper.start(c, source);

        // seedWorld itself inserts only masters/BOM. Prove the scenario's raw
        // material entered via approved OTHER_IN and was really issued to source.
        quantity(inputQuantity, db.queryForObject("""
                SELECT COALESCE(SUM(movement.qty),0) FROM stock_movements movement
                JOIN stock_documents document ON document.id=movement.source_doc_id
                WHERE movement.goods_id=? AND movement.direction=1
                  AND document.doc_type='OTHER_IN' AND document.status=1 AND NOT document.is_deleted
                """, BigDecimal.class, c.material()), "raw input must have an approved inbound source");
        quantity(inputQuantity, netIssued(db, sourceDemand), "source segment must own real issued inputs");
        Set<UUID> goods = Set.of(c.material(), c.child(), c.common());

        UUID actorUserId = helper.worker(c);
        flow.fixture.loginAs(actorUserId);
        Authentication actor = Objects.requireNonNull(SecurityContextHolder.getContext().getAuthentication());
        var candidates = helper.direct().candidates(source, c.child(), null).candidates();
        assertEquals(receivers, candidates.size());
        List<UUID> receivingSegments = parents.stream().map(helper::segment).toList();
        List<UUID> receivingDemands = receivingSegments.stream().map(helper::demand).toList();
        assertEquals(Set.copyOf(receivingDemands), candidates.stream().map(candidate -> candidate.demandId())
                .collect(java.util.stream.Collectors.toSet()));

        var request = new DailyReportSaveRequest();
        request.setIdempotencyKey("controlled-report-" + source);
        request.setBillDate(BusinessTime.today());
        request.setWarehouseId(c.world().warehouseId());
        request.setDepartmentId(c.workshop());
        request.setWorkerIds(List.of(c.worker()));
        var item = new DailyReportItemLine();
        item.setLineNo(1);
        item.setExecutionSegmentId(source);
        item.setPlanItemId(db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?", UUID.class, source));
        item.setGoodsId(c.child());
        item.setUnitId(c.world().unitId());
        item.setUnitRate(BigDecimal.ONE);
        item.setQty(BigDecimal.valueOf(receivers));
        item.setAllocations(candidates.stream().map(candidate ->
                DailyReportOutputAllocationLine.direct(candidate.demandId(), BigDecimal.ONE)).toList());
        request.setItems(List.of(item));
        var usage = new DailyReportMaterialUsageLine();
        usage.setDemandId(sourceDemand);
        usage.setQtyBase(inputQuantity);
        request.setMaterialLines(List.of(usage));
        var reports = beans.getBean(ProductionDailyReportService.class);
        UUID reportId = reports.create(request).getId();
        assertStockLedgerMatchesBalances(db, goods);
        String approvalKey = "controlled-approve-" + reportId;

        // Capture the real fixture employee's authentication before measurement;
        // no login/permission-resolution SQL is accidentally added to approve.
        Supplier<?> command = () -> withActor(actor, () -> {
            var approval = new DailyReportApproveRequest();
            approval.setIdempotencyKey(approvalKey);
            return reports.approve(reportId, approval);
        });
        Runnable verify = () -> verifyApproved(db, reportId, c.child(), receivers,
                sourceDemand, inputQuantity, receivingSegments, receivingDemands, goods);
        Set<UUID> knownWarehouses = new LinkedHashSet<>(db.queryForList("""
                SELECT id FROM warehouses WHERE id=?
                  OR (is_line_side AND workshop_department_id=? AND NOT is_deleted)
                """, UUID.class, c.world().warehouseId(), c.workshop()));
        Map<String, Object> metadata = new LinkedHashMap<>();
        metadata.put("runTag", runTag);
        metadata.put("receivers", receivers);
        metadata.put("reportId", reportId);
        metadata.put("sourceSegmentId", source);
        metadata.put("sourceDemandId", sourceDemand);
        metadata.put("analysisId", c.analysis());
        metadata.put("actorUserId", actorUserId);
        metadata.put("receivingSegmentIds", receivingSegments);
        metadata.put("receivingDemandIds", receivingDemands);
        metadata.put("rawInputQty", inputQuantity.toPlainString());
        metadata.put("approvalKey", approvalKey);
        metadata.put("initialLedgerConsistent", true);
        metadata.put("stockSeed", "approved OTHER_IN -> requested/approved/issued DRAW -> source START");
        metadata.put("inventoryScope", "goodsIds across all warehouses, including line-side locations created by approval");
        return new Prepared(reportId, goods, knownWarehouses, command, verify, metadata);
    }

    private static <T> T withActor(Authentication actor, Supplier<T> work) {
        SecurityContext previous = SecurityContextHolder.getContext();
        SecurityContext context = SecurityContextHolder.createEmptyContext();
        context.setAuthentication(actor);
        SecurityContextHolder.setContext(context);
        try { return work.get(); }
        finally { SecurityContextHolder.setContext(previous); }
    }

    private static void verifyApproved(JdbcTemplate db, UUID reportId, UUID childGoods, int receivers,
                                       UUID sourceDemand, BigDecimal inputQuantity,
                                       List<UUID> receivingSegments, List<UUID> receivingDemands,
                                       Set<UUID> goods) {
        assertEquals(1, db.queryForObject("SELECT status FROM production_daily_reports WHERE id=?", Integer.class, reportId));
        assertEquals(receivers, db.queryForObject("""
                SELECT count(*) FROM production_fqc_inspections inspection
                JOIN production_daily_report_items item ON item.id=inspection.source_report_item_id
                WHERE item.report_id=? AND inspection.inspection_kind='WORKSHOP_SELF' AND inspection.status='RESOLVED'
                """, Integer.class, reportId));
        var inbounds = db.queryForList("""
                SELECT document.id, document.status, count(item.id) AS lines,
                       SUM(item.qty) AS qty, bool_and(warehouse.is_line_side) AS line_side
                FROM stock_documents document
                JOIN stock_document_items item ON item.doc_id=document.id AND NOT item.is_deleted
                JOIN warehouses warehouse ON warehouse.id=document.warehouse_id
                WHERE document.source_daily_report_id=? AND document.doc_type='FINISHED_IN' AND NOT document.is_deleted
                GROUP BY document.id, document.status
                """, reportId);
        assertEquals(receivers, inbounds.size(), "each transfer block retains its own inbound document");
        for (Map<String, Object> inbound : inbounds) {
            assertEquals(1, ((Number) inbound.get("status")).intValue());
            assertEquals(1L, ((Number) inbound.get("lines")).longValue());
            assertEquals(Boolean.TRUE, inbound.get("line_side"));
            quantity(BigDecimal.ONE, (BigDecimal) inbound.get("qty"), "each physical inbound is exactly one");
        }
        assertEquals(receivers, db.queryForObject("""
                SELECT count(*) FROM production_workshop_direct_transfer_items transfer
                JOIN production_daily_report_items item ON item.id=transfer.source_report_item_id
                WHERE item.report_id=? AND transfer.reversal_id IS NULL
                """, Integer.class, reportId), "a retry must not create additional transfers");
        for (int i = 0; i < receivingSegments.size(); i++) {
            UUID segment = receivingSegments.get(i);
            UUID demand = receivingDemands.get(i);
            quantity(BigDecimal.ONE, netIssued(db, demand), "each named receiver is issued exactly one");
            quantity(BigDecimal.ONE, db.queryForObject("""
                    SELECT COALESCE(SUM(transfer.qty),0) FROM production_workshop_direct_transfer_items transfer
                    JOIN production_daily_report_items item ON item.id=transfer.source_report_item_id
                    WHERE item.report_id=? AND transfer.to_demand_id=? AND transfer.reversal_id IS NULL
                    """, BigDecimal.class, reportId, demand), "source handover remains tied to its exact demand");
            assertEquals(0, db.queryForObject("SELECT count(*) FROM production_execution_segment_events WHERE execution_segment_id=? AND action='DRAW_REQUEST'",
                    Integer.class, segment), "direct recipients never submit warehouse picking requests");
        }
        quantity(inputQuantity, netIssued(db, sourceDemand), "report approval must not issue its raw material twice");
        quantity(BigDecimal.ZERO, db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?",
                BigDecimal.class, childGoods), "all produced child units were immediately handed over");
        assertStockLedgerMatchesBalances(db, goods);
    }

    private static BigDecimal netIssued(JdbcTemplate db, UUID demand) {
        return db.queryForObject("""
                SELECT COALESCE(SUM(CASE posting_type WHEN 'ISSUE' THEN qty_base WHEN 'ISSUE_REVERSE' THEN -qty_base ELSE 0 END),0)
                FROM production_material_stock_postings WHERE demand_id=?
                """, BigDecimal.class, demand);
    }

    private static void assertStockLedgerMatchesBalances(JdbcTemplate db, Set<UUID> goods) {
        String ids = "{" + String.join(",", goods.stream().map(UUID::toString).sorted().toList()) + "}";
        Long differences = db.queryForObject("""
                WITH balances AS (
                    SELECT warehouse_id,goods_id,color_id,SUM(qty) AS qty FROM stock_balances
                    WHERE goods_id=ANY(CAST(? AS uuid[])) GROUP BY warehouse_id,goods_id,color_id
                ), movements AS (
                    SELECT warehouse_id,goods_id,color_id,SUM(direction*qty) AS qty FROM stock_movements
                    WHERE goods_id=ANY(CAST(? AS uuid[])) GROUP BY warehouse_id,goods_id,color_id
                ), dimensions AS (
                    SELECT warehouse_id,goods_id,color_id FROM balances
                    UNION SELECT warehouse_id,goods_id,color_id FROM movements
                )
                SELECT count(*) FROM dimensions dimension
                LEFT JOIN balances balance ON balance.warehouse_id=dimension.warehouse_id AND balance.goods_id=dimension.goods_id
                  AND balance.color_id IS NOT DISTINCT FROM dimension.color_id
                LEFT JOIN movements movement ON movement.warehouse_id=dimension.warehouse_id AND movement.goods_id=dimension.goods_id
                  AND movement.color_id IS NOT DISTINCT FROM dimension.color_id
                WHERE COALESCE(balance.qty,0)<>COALESCE(movement.qty,0) OR COALESCE(balance.qty,0)<0
                """, Long.class, ids, ids);
        assertEquals(0L, differences, "each scoped warehouse/goods/color balance must match signed movement history");
    }

    private static void quantity(BigDecimal expected, BigDecimal actual, String message) {
        assertNotNull(actual, message);
        assertEquals(0, expected.compareTo(actual), message);
    }
}
