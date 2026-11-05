package com.uten.imp.features.master.reference;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.CurrentStaffAuthorityPort;
import com.uten.imp.features.master.goods.dto.GoodsListItem;
import org.junit.jupiter.api.Test;
import java.nio.file.Files;
import java.nio.file.Path;
import java.math.BigDecimal;
import java.util.HashSet;
import java.util.Set;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

class GoodsReferenceProjectionTest {
    @Test void selectionPreservesIndependentlyMaskedValuesAndQuantityRulesWithoutGrantingMasterWrites() throws Exception {
        Path path = Path.of("contracts/business-master-references/v1.json");
        if (!Files.exists(path)) path = Path.of("..").resolve(path);
        var contract = new ObjectMapper().readTree(Files.readString(path));
        var source = contract.path("goods");
        for (var fixture : contract.path("cases")) {
            Set<String> grants = new HashSet<>();
            fixture.path("grants").forEach(node -> grants.add(node.asText()));
            var staff = mock(CurrentStaffAuthorityPort.class);
            when(staff.currentStaffPermissions()).thenReturn(grants);
            var access = new BusinessMasterReferenceAccess(staff);
            var item = mock(GoodsListItem.class);
            // The owning service masks price and discount independently before projection.
            when(item.getPrice()).thenReturn(fixture.path("priceVisible").asBoolean() ? source.path("price").decimalValue() : null);
            if (fixture.path("priceVisible").asBoolean()) {
                when(item.getCurrencyId()).thenReturn(java.util.UUID.fromString("28b14f75-c08c-4867-9dbf-55a650a0fc13"));
                when(item.getCurrencyCode()).thenReturn("002"); when(item.getCurrencyName()).thenReturn("美金");
                when(item.getCurrencyIsBase()).thenReturn(false);
            }
            when(item.getDiscount()).thenReturn(fixture.path("discountVisible").asBoolean() ? source.path("discount").decimalValue() : null);
            when(item.getStockQty()).thenReturn(source.path("stockQty").decimalValue());
            when(item.getStockQtyDisplayText()).thenReturn("9007199254740993.123456");
            when(item.getStockPlace()).thenReturn(source.path("stockPlace").asText());
            when(item.getMinOrderQty()).thenReturn(source.path("minOrderQty").decimalValue());
            when(item.getOrderMultipleQty()).thenReturn(source.path("orderMultipleQty").decimalValue());
            when(item.getIssueMethod()).thenReturn(source.path("issueMethod").asText());
            when(item.getPeriodicCostBasis()).thenReturn(source.path("periodicCostBasis").asText());
            when(item.getBulkPackageQty()).thenReturn(source.path("bulkPackageQty").decimalValue());
            when(item.isRecycledMaterial()).thenReturn(true);
            when(item.isWritable()).thenReturn(true);
            var row = GoodsReferenceProjection.of(item, access.canReadMasterGoods());
            assertThat(row.containsKey("price")).as(fixture.path("name").asText()).isEqualTo(fixture.path("priceVisible").asBoolean());
            for(String key : Set.of("currencyId","currencyCode","currencyName","currencyIsBase"))
                assertThat(row.containsKey(key)).as(key).isEqualTo(fixture.path("priceVisible").asBoolean());
            assertThat(row.containsKey("discount")).isEqualTo(fixture.path("discountVisible").asBoolean());
            assertThat(row.containsKey("stockQty")).isEqualTo(fixture.path("stockVisible").asBoolean());
            assertThat(row.containsKey("stockQtyDisplayText")).isEqualTo(fixture.path("stockVisible").asBoolean());
            if (row.containsKey("stockQtyDisplayText")) assertThat(row.get("stockQtyDisplayText")).isEqualTo("9007199254740993.123456");
            if (row.containsKey("price")) assertThat((BigDecimal) row.get("price")).isEqualByComparingTo("39.13");
            if (row.containsKey("discount")) assertThat((BigDecimal) row.get("discount")).isEqualByComparingTo("0.2");
            assertThat(row).containsEntry("stockPlace", "A-01").containsEntry("issueMethod", "PERIODIC")
                    .containsEntry("periodicCostBasis", "OWN").containsEntry("recycledMaterial", true).containsEntry("writable", false);
            for (String key : Set.of("minOrderQty", "orderMultipleQty", "bulkPackageQty")) {
                assertThat((BigDecimal) row.get(key)).isEqualByComparingTo(source.path(key).decimalValue());
            }
            assertThat(row).doesNotContainKeys("cost", "stockAmount", "bankAccount", "phone", "credit");
        }
    }
}
