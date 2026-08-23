package com.uten.imp.features.production.fulfillment;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionMakeReceiptLifecycleContractTest {

    @Test
    void confirmationPegsEveryDirectMakeShortageBeforeStatusRefresh()
            throws Exception {
        String source = source(
                "production/mrp/ProductionExecutionPackageCommandService.java");
        int generated = source.indexOf(
                "generateSelfMadeSubplansForPackage(");
        int pegged = source.indexOf("createMakeSupplyPegs(", generated);
        int refreshed = source.indexOf(
                "ledger.refreshDemandStatuses(", pegged);
        int helper = source.indexOf(
                "private void createMakeSupplyPegs(");

        assertThat(generated).isGreaterThanOrEqualTo(0);
        assertThat(pegged).isGreaterThan(generated);
        assertThat(refreshed).isGreaterThan(pegged);
        assertThat(helper).isGreaterThan(refreshed);
        assertThat(source.substring(helper))
                .contains("\"PRODUCTION_PLAN_ITEM\"")
                .contains("peggedDemands.equals(shortageByDemand.keySet())")
                .contains("compareTo(source.capacity()) != 0");
    }

    @Test
    void approvedAndReversedFinishedInboundUseSameReadinessLedger()
            throws Exception {
        String readiness = source(
                "production/fulfillment/ProductionExecutionReadinessService.java");
        String completion = source(
                "production/execution/ProductionCompletionReverseService.java");
        String stock = source("stock/StockDocService.java");

        assertThat(readiness)
                .contains("onFinishedInboundApproved(")
                .contains("beforeFinishedInboundReversed(")
                .contains("ReceiptKind.MAKE")
                .contains("production_material_make_receipt_allocations")
                .contains("allocationPegColumn")
                .contains("supply_peg_id");
        assertThat(completion)
                .contains("readiness.onFinishedInboundApproved(")
                .contains("readiness.beforeFinishedInboundReversed(");

        int chain = stock.indexOf("applyFinishedInChain(d, items, +1)");
        int approved = stock.indexOf("d.setStatus(STATUS_APPROVED)", chain);
        int flushed = stock.indexOf("em.flush()", approved);
        int promotion = stock.indexOf(
                "afterFinishedInboundApproved(", flushed);
        assertThat(chain).isGreaterThanOrEqualTo(0);
        assertThat(approved).isGreaterThan(chain);
        assertThat(flushed).isGreaterThan(approved);
        assertThat(promotion).isGreaterThan(flushed);
    }

    @Test
    void packageReleasesMakePegsBeforeClosingTheirChildSource()
            throws Exception {
        String source = source(
                "production/mrp/ProductionPlanningPackageService.java");
        int lifecycle = source.indexOf("private PlanningPackageLifecycleResult lifecycle(");
        int release = source.indexOf("ledger.releaseLocked(", lifecycle);
        int closeSubplans = source.indexOf("closeSubplans(documents, action, request)", release);

        assertThat(lifecycle).isGreaterThanOrEqualTo(0);
        assertThat(release).isGreaterThan(lifecycle);
        assertThat(closeSubplans).isGreaterThan(release);
    }


    @Test
    void userDeferLockOrderAndRekitGenerationAreExplicit()
            throws Exception {
        String readiness = source(
                "production/fulfillment/ProductionExecutionReadinessService.java");
        String stock = source("stock/StockDocService.java");

        assertThat(readiness)
                .contains("segment.auto_promote_when_ready = TRUE")
                .contains("AND auto_promote_when_ready = TRUE")
                .contains("packageId + \":REKIT:\" + demand.id()")
                .contains("+ \":\" + triggeringReceiptId")
                .contains("+ reservationId)");

        int approve = stock.indexOf("public StockDocDetail approve(");
        int approvePrelock = stock.indexOf(
                "lockFinishedInboundProductionDimensions(", approve);
        int approveInventory = stock.indexOf(
                "lockInventory(items)", approvePrelock);
        int reverse = stock.indexOf("public StockDocDetail reverse(");
        int reversePrelock = stock.indexOf(
                "lockFinishedInboundProductionDimensions(", reverse);
        int reverseInventory = stock.indexOf(
                "lockInventory(items)", reversePrelock);

        assertThat(approvePrelock).isGreaterThan(approve);
        assertThat(approveInventory).isGreaterThan(approvePrelock);
        assertThat(reversePrelock).isGreaterThan(reverse);
        assertThat(reverseInventory).isGreaterThan(reversePrelock);
    }

    @Test
    void legacyEventlessPreplanOwnerCanPromoteWaitingSegmentToReady()
            throws Exception {
        String readiness = source(
                "production/fulfillment/ProductionExecutionReadinessService.java");
        int start = readiness.indexOf("private boolean isFullyAvailable(");
        int end = readiness.indexOf(
                "private void lockExecutionSegmentMaterialDimensions(", start);
        String availability = readiness.substring(start, end)
                .replaceAll("\\s+", " ");

        assertThat(availability)
                .contains("WHEN EXISTS (")
                .contains("preplan_stock_entitlement_events tracked")
                .contains(
                        "v_preplan_stock_entitlement_beneficiary_balance")
                .contains("entitlement.beneficiary_analysis_id = :analysisId")
                .contains("material.analysis_item_id = :analysisItemId")
                .contains(
                        "WHEN preplan_reservation.owner_id = :analysisId")
                .contains("preplan_reservation.qty")
                .contains("preplan_reservation.owner_type = 'PREPLAN_ANALYSIS'")
                .contains(
                        "preplan_reservation.warehouse_id = :warehouseId")
                .contains("COALESCE(balance.qty, 0)"
                        + " - COALESCE(reserved.qty, 0)"
                        + " + COALESCE(own.qty, 0)");
    }

    private static String source(String relative) throws Exception {
        return Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/" + relative));
    }
}
