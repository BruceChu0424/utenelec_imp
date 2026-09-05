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
