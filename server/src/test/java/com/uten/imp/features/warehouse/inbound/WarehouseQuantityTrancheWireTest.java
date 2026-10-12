package com.uten.imp.features.warehouse.inbound;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

class WarehouseQuantityTrancheWireTest {
    private final ObjectMapper mapper = new ObjectMapper();

    @Test void inspectionLineItemRetainsTrancheAndLegacyConstructor() {
        UUID id=UUID.randomUUID();
        var legacy=new WarehouseQualityResultContracts.InspectionLineItem(id,null,null,null,null,null,null,null,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,null,null,null,null);
        assertEquals("LEGACY", legacy.quantityTranche());
        var charged=new WarehouseQualityResultContracts.InspectionLineItem(id,null,null,null,null,null,null,null,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,null,null,null,null,"CHARGED");
        assertEquals("CHARGED",mapper.valueToTree(charged).get("quantityTranche").textValue());
        var gift=new WarehouseQualityResultContracts.InspectionLineItem(id,null,null,null,null,null,null,null,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,null,null,null,null,"GIFT");
        assertEquals("GIFT",mapper.valueToTree(gift).get("quantityTranche").textValue());
        assertEquals(mapper.valueToTree(charged).get("inspectionItemId"), mapper.valueToTree(gift).get("inspectionItemId"));
    }

    @Test void releasedSliceRetainsTrancheAndLegacyConstructor() {
        UUID id=UUID.randomUUID();
        var legacy=new ProcurementIqcStockInContracts.ReleasedSlice(id,id,null,null,null,null,null,null,null,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,null,null,null,null,null,null,null);
        assertEquals("LEGACY", legacy.quantityTranche());
        var charged=new ProcurementIqcStockInContracts.ReleasedSlice(id,id,null,null,null,null,null,null,null,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,null,null,null,null,null,null,null,"CHARGED");
        assertEquals("CHARGED",mapper.valueToTree(charged).get("quantityTranche").textValue());
        var gift=new ProcurementIqcStockInContracts.ReleasedSlice(id,id,null,null,null,null,null,null,null,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE,null,null,null,null,null,null,null,"GIFT");
        assertEquals("GIFT",mapper.valueToTree(gift).get("quantityTranche").textValue());
        assertEquals(mapper.valueToTree(charged).get("inspectionItemId"), mapper.valueToTree(gift).get("inspectionItemId"));
    }

    @Test void stockInHistoryItemRetainsTrancheAndLegacyConstructor() {
        UUID id=UUID.randomUUID();
        var legacy=new ProcurementIqcStockInContracts.StockInHistoryItem(id,null,id,null,null,null,null,null,BigDecimal.ONE,BigDecimal.ONE,null,null,null,null,null,null,null);
        assertEquals("LEGACY", legacy.quantityTranche());
        var charged=new ProcurementIqcStockInContracts.StockInHistoryItem(id,null,id,null,null,null,null,null,BigDecimal.ONE,BigDecimal.ONE,null,null,null,null,null,null,null,"CHARGED");
        assertEquals("CHARGED",mapper.valueToTree(charged).get("quantityTranche").textValue());
        var gift=new ProcurementIqcStockInContracts.StockInHistoryItem(id,null,id,null,null,null,null,null,BigDecimal.ONE,BigDecimal.ONE,null,null,null,null,null,null,null,"GIFT");
        assertEquals("GIFT",mapper.valueToTree(gift).get("quantityTranche").textValue());
        assertEquals(mapper.valueToTree(charged).get("stockInItemId"), mapper.valueToTree(gift).get("stockInItemId"));
    }
}
