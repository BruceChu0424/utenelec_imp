package com.uten.imp.features.production.mrp;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDemand;
import com.uten.imp.features.stock.allocation.ProductionMaterialAllocationFacade.AllocationResult;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ProductionExecutionWarehouseDrawTest {
    @Test
    void completeKitDrawsFromEachMaterialsActualWarehouse() {
        var plastic = demand("10");
        var hardware = demand("4");
        UUID plasticWarehouse = UUID.randomUUID();
        UUID hardwareWarehouse = UUID.randomUUID();
        var split = ProductionExecutionPackageCommandService.drawQuantitiesByWarehouse(
                List.of(plastic, hardware), List.of(
                        allocation(plastic, plasticWarehouse, "10"),
                        allocation(hardware, hardwareWarehouse, "4")));

        assertThat(split).hasSize(2);
        assertThat(split.get(plasticWarehouse)).containsOnlyKeys(plastic.getId());
        assertThat(split.get(plasticWarehouse).get(plastic.getId())).isEqualByComparingTo("10");
        assertThat(split.get(hardwareWarehouse)).containsOnlyKeys(hardware.getId());
        assertThat(split.get(hardwareWarehouse).get(hardware.getId())).isEqualByComparingTo("4");
    }

    @Test
    void oneMaterialCanBeSplitWithoutRepeatingTheWholeDemandInBothDraws() {
        var material = demand("10");
        UUID firstWarehouse = UUID.randomUUID();
        UUID secondWarehouse = UUID.randomUUID();
        var split = ProductionExecutionPackageCommandService.drawQuantitiesByWarehouse(
                List.of(material), List.of(
                        allocation(material, firstWarehouse, "3"),
                        allocation(material, firstWarehouse, "2"),
                        allocation(material, secondWarehouse, "5"),
                        allocation(demand("100"), secondWarehouse, "100")));

        assertThat(split.get(firstWarehouse).get(material.getId())).isEqualByComparingTo("5");
        assertThat(split.get(secondWarehouse).get(material.getId())).isEqualByComparingTo("5");
        assertThat(split.get(secondWarehouse)).hasSize(1);
    }

    @Test
    void partialStockAndOverAllocationCannotProduceAReadyKit() {
        var material = demand("10");
        for (String quantity : List.of("9", "11")) {
            assertThatThrownBy(() -> ProductionExecutionPackageCommandService
                    .drawQuantitiesByWarehouse(List.of(material), List.of(
                            allocation(material, UUID.randomUUID(), quantity))))
                    .isInstanceOf(ApiException.class)
                    .hasMessageContaining("完整库存");
        }
    }

    @Test
    void allocationWithoutActualWarehouseCannotBeRelabelledAsThePlanWarehouse() {
        var material = demand("10");
        assertThatThrownBy(() -> ProductionExecutionPackageCommandService
                .drawQuantitiesByWarehouse(List.of(material), List.of(
                        allocation(material, null, "10"))))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("实际子仓");
    }

    private static ProductionMaterialDemand demand(String quantity) {
        var demand = new ProductionMaterialDemand();
        demand.setId(UUID.randomUUID());
        demand.setRequiredQty(new BigDecimal(quantity));
        return demand;
    }

    private static AllocationResult allocation(
            ProductionMaterialDemand demand, UUID warehouseId, String quantity) {
        return new AllocationResult(demand.getId(), UUID.randomUUID(), UUID.randomUUID(),
                new BigDecimal(quantity), false, warehouseId);
    }
}
