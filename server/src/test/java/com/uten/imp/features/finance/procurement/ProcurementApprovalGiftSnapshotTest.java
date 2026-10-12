package com.uten.imp.features.finance.procurement;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.ProcurementOrderApprovalPort.ItemSnapshot;
import com.uten.imp.application.port.ProcurementOrderApprovalPort.OrderSnapshot;
import com.uten.imp.common.finance.ProcurementQuantities;
import com.uten.imp.common.util.HashUtil;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class ProcurementApprovalGiftSnapshotTest {
    private final UUID order=UUID.randomUUID(),item=UUID.randomUUID(),goods=UUID.randomUUID();
    private final ObjectMapper mapper=new ObjectMapper().findAndRegisterModules();
    private ItemSnapshot line(BigDecimal gift,String semantics){
        return new ItemSnapshot(item,1,null,goods,null,null,BigDecimal.ONE,BigDecimal.TEN,BigDecimal.ONE,
                BigDecimal.TEN,BigDecimal.TEN,null,null,null,gift,semantics);
    }
    private String json(ItemSnapshot line){
        return ProcurementApprovalSnapshot.json(new OrderSnapshot("PURCHASE",order,"PO-QA",LocalDate.of(2026,10,11),
                null,null,null,BigDecimal.ONE,null,BigDecimal.ZERO,null,null,null,BigDecimal.TEN,BigDecimal.TEN,List.of(line)),mapper);
    }
    @Test void legacyHashesRemainByteIdenticalToHistoricalConstructor(){
        var legacy=new ItemSnapshot(item,1,null,goods,null,null,BigDecimal.ONE,BigDecimal.TEN,BigDecimal.ONE,
                BigDecimal.TEN,BigDecimal.TEN,null);
        assertEquals(json(legacy),json(line(new BigDecimal("7.125"),ProcurementQuantities.LEGACY)));
        assertFalse(json(legacy).contains("giftQty"));
    }
    @Test void newGiftQuantityAndSemanticsAreFinanceFrozenFacts(){
        String first=json(line(BigDecimal.ONE,ProcurementQuantities.EXTRA_GIFT));
        assertTrue(first.contains("\"giftQty\":\"1\""));
        assertTrue(first.contains("CHARGED_PLUS_GIFT_V1"));
        assertNotEquals(HashUtil.sha256(first),HashUtil.sha256(json(line(new BigDecimal("2"),ProcurementQuantities.EXTRA_GIFT))));
        assertNotEquals(HashUtil.sha256(first),HashUtil.sha256(json(line(BigDecimal.ONE,ProcurementQuantities.LEGACY))));
        assertEquals(first,json(line(new BigDecimal("1.0000"),ProcurementQuantities.EXTRA_GIFT)));
    }
}
