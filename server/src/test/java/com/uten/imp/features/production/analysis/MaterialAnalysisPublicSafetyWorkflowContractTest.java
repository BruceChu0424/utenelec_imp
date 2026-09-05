package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class MaterialAnalysisPublicSafetyWorkflowContractTest {

    @Test
    void notifyRequiresExplicitSafetyEchoAndCreatesTwoDistinctBuyLines()
            throws Exception {
        String source = source("MaterialAnalysisCommandService.java");

        assertThat(source)
                .contains("input.safetyReplenishmentQty()")
                .contains("公共安全库存补库已变化")
                .contains("SafetyDimension.of(plan.group())")
                .contains("生产需求精确备料")
                .contains("公共安全库存补库(不绑定单一物料分析)")
                .contains("action.safetySliceId()")
                .contains("safety_external_item_id = :safetyExternalItemId")
                .contains("NOTIFY-V3")
                .contains("|SAFETY|");
        assertThat(source).contains(
                "private record SafetyDimension(UUID goodsId, UUID colorId)");
        assertThat(source).contains("safetyOwners.putIfAbsent(");
        assertThat(source.indexOf("lockAnalysisInventoryDimensions(analysisId)"))
                .isLessThan(source.indexOf("analysisService.refreshLocked(analysisId)"));
        assertThat(source.indexOf("生产需求精确备料"))
                .isNotEqualTo(source.indexOf("公共安全库存补库(不绑定单一物料分析)"));
    }

    @Test
    void exactDemandAndPublicSafetyUseDifferentAuthorities() throws Exception {
        String command = source("MaterialAnalysisCommandService.java");
        String peg = source("PreplanAnalysisStockPegService.java");

        assertThat(command)
                .contains("allocateAction(actionId, analysisId, group.materials(), plan.demandQty())")
                .contains("MaterialView::demandSupplyGapQty")
                .contains("action.safetyQty().signum() > 0")
                .contains("markCreated(action.actionId(), \"PURCHASE_REQUEST\"");
        assertThat(peg)
                .contains("WHERE allocation.external_item_id = :externalItemId")
                .doesNotContain("allocation.external_item_id = action.safety_external_item_id");
    }

    @Test
    void splitProgressDrivesPartialPassFailureAndSafetyOnlyLifecycle()
            throws Exception {
        String analysis = source("MaterialAnalysisService.java");
        String command = source("MaterialAnalysisCommandService.java");
        String progress = source("MaterialAnalysisSupplyProgressService.java");

        assertThat(analysis)
                .contains("FROM v_preplan_buy_action_slice_progress progress")
                .contains("progress.demand_source_valid = TRUE")
                .contains("progress.safety_source_valid = TRUE")
                .contains("progress.demand_failed_qty + progress.safety_failed_qty > 0")
                .contains("progress.demand_order_exists OR progress.safety_order_exists")
                .contains("progress.safety_qualified_qty")
                .contains("action.safety_replenishment_qty = 0");
        assertThat(command)
                .contains("progress.demand_future_qty")
                .contains("new ActionDraft(")
                .contains("plan.demandQty(), plan.publicExtraQty()")
                .contains("safety_replenishment_qty, safety_stock_snapshot_qty");
        assertThat(progress)
                .contains("生产需求绑定 ")
                .contains("公共安全补库 ")
                .contains("action.safety_replenishment_qty > 0");
    }

    @Test
    void nonBuySafetyGapFailsClosed() throws Exception {
        String source = source("MaterialAnalysisCommandService.java");

        assertThat(source)
                .contains("本版本仅支持采购路线的公共安全库存补库")
                .contains("禁止重复下达委外/自制来伪装齐套");
    }

    private static String source(String file) throws Exception {
        return Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/analysis/" + file),
                StandardCharsets.UTF_8);
    }
}
