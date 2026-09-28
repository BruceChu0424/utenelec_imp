package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class PreplanInboundAllocationProjectionContractTest {

    @Test
    void expectedAndActualPathsAreBatchedAmountFreeAndConserved()
            throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/analysis/"
                        + "PreplanInboundAllocationProjectionService.java"),
                StandardCharsets.UTF_8);
        assertThat(source)
                .contains("expectedForPassEvents(")
                .contains("expectedForOrderItems(")
                .contains("actualForBatches(")
                .contains("fn_preplan_order_public_source_qty")
                .contains("fn_preplan_order_exact_attributed_qty")
                .contains("production_material_receipt_allocations")
                .contains("production_material_subcontract_receipt_allocations")
                .contains("allocation.receipt_item_id IN (:receiptItemIds)")
                .contains("warehouse stock-in allocation projection is not conserved")
                .doesNotContain("idempotency_key LIKE")
                .doesNotContain("client.name")
                .doesNotContain("amount_local")
                .doesNotContain("price");
    }

    @Test
    void arrivalPreviewAndStockInFillSharesInOneUrgencyOrder() throws Exception {
        // 到货预览必须与入库时的真实归属同一次序，否则预览给仓库看的产品/计划/仓库与实际入库不一致。
        assertThat(PreplanAnalysisStockPegService.INBOUND_ALLOCATION_ORDER)
                .containsSubsequence("action.operation_type", "action.created_at", "action.id",
                        "owner.line_priority NULLS LAST", "owner.delivery_date NULLS LAST",
                        "allocation.created_at", "allocation.id")
                .endsWith(PreplanAnalysisStockPegService.ALLOCATION_URGENCY_ORDER);
        String projection = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/analysis/"
                        + "PreplanInboundAllocationProjectionService.java"),
                StandardCharsets.UTF_8);
        String stockIn = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/analysis/"
                        + "PreplanAnalysisStockPegService.java"),
                StandardCharsets.UTF_8);
        assertThat(projection).contains("ORDER BY allocation.external_item_id,%2$s")
                .contains("PreplanAnalysisStockPegService.INBOUND_ALLOCATION_ORDER");
        assertThat(stockIn).contains(".formatted(INBOUND_ALLOCATION_ORDER)")
                .contains(".formatted(ALLOCATION_URGENCY_ORDER)");
        // 次序正文只写在常量里一次。
        String urgency = "owner.line_priority NULLS LAST";
        assertThat(stockIn.indexOf(urgency)).isPositive().isEqualTo(stockIn.lastIndexOf(urgency));
    }

    @Test
    void wrongWarehouseKeepsActualAndAllIntendedTargets() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/production/analysis/"
                        + "PreplanInboundAllocationProjectionService.java"),
                StandardCharsets.UTF_8);
        assertThat(source)
                .contains("mismatchedIntendedWarehouses")
                .contains("intendedWarehouses(slices)")
                .contains("实际入库仓与预定主仓不一致")
                .contains("不会跨仓绑定")
                .contains("actualWarehouseId")
                .contains("targetWarehouseId");
    }
}
