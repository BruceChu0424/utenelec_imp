package com.uten.imp.common.inventory;

import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.List;
import static org.junit.jupiter.api.Assertions.*;

class MainWarehouseStockBudgetTest {
    private static BigDecimal n(String value) { return new BigDecimal(value); }
    private static MainWarehouseStockBudget.Leaf<String> leaf(String key, String available, String own, String qualified) {
        return new MainWarehouseStockBudget.Leaf<>(key,n(available),n(own),n(qualified));
    }

    @Test void onePublicBufferAcrossTwoLeavesAndNoBufferFromQualifiedPrivateStock() {
        var shared = MainWarehouseStockBudget.distribute(List.of(leaf("A","30","0","0"),leaf("B","70","0","0")),n("20"));
        assertEquals(n("30"),shared.get("A")); assertEquals(n("50"),shared.get("B"));
        var owned = MainWarehouseStockBudget.distribute(List.of(leaf("A","0","30","30"),leaf("B","70","0","0")),n("20"));
        assertEquals(n("30"),owned.get("A")); assertEquals(n("50"),owned.get("B"));
    }

    @Test void legacyOwnedMaterialIsPrioritizedButStillRespectsTheOnePublicBuffer() {
        var available = MainWarehouseStockBudget.distribute(List.of(leaf("A","30","0","0"),leaf("B","0","70","0")),n("20"));
        assertEquals(n("10"),available.get("A")); assertEquals(n("70"),available.get("B"));
        assertEquals(n("20"), MainWarehouseStockBudget.safetyGap(n("30"),n("5"),n("5")));
    }

    @Test void duplicatePhysicalKeysCannotDoubleCountStock() {
        assertThrows(IllegalArgumentException.class, () -> MainWarehouseStockBudget.distribute(
                List.of(leaf("A","30","0","0"),leaf("A","70","0","0")),n("20")));
    }
}
