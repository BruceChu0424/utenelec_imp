package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.features.warehouse.inbound.dto.BatchInspectionDecideRequest;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

class ProcurementInspectionBatchCommandTest {
    @Test void completeIdentityNormalizesScaleOrderAndReasonButDistinguishesEveryDecisionField() {
        UUID receipt=UUID.randomUUID(),first=UUID.randomUUID(),second=UUID.randomUUID();
        var a=line(first,"1.25","0.75","0.5","batch-command-first");var b=line(second,"1.25","1.25","0","batch-command-second");
        var original=command(receipt,List.of(a,b),"结论");
        assertEquals(original.requestHash(),command(receipt,List.of(b,line(first,"1.2500","0.7500","0.5000","batch-command-first"))," 结论 ").requestHash());
        assertNotEquals(original.requestHash(),command(receipt,List.of(a),"结论").requestHash());
        assertNotEquals(original.requestHash(),command(UUID.randomUUID(),List.of(a,b),"结论").requestHash());
        assertNotEquals(original.requestHash(),command(receipt,List.of(line(first,"2","0.75","0.5",a.idempotencyKey()),b),"结论").requestHash());
        assertNotEquals(original.requestHash(),command(receipt,List.of(line(first,"1.25","0.5","0.75",a.idempotencyKey()),b),"结论").requestHash());
        assertNotEquals(original.requestHash(),command(receipt,List.of(a,b),"另一结论").requestHash());
        assertEquals(3,original.events().size());assertEquals(4,original.candidateEventIds().size(),"The zero FAIL branch also participates in historical identity lookup");
    }
    @Test void internalPassFailSuffixesPreserveOldUuidsAndSupportTheDeclared128CharacterKey() {
        UUID inspection=UUID.randomUUID();String key="x".repeat(128);
        var batch=command(UUID.randomUUID(),List.of(line(inspection,"1","0.5","0.5",key)),"结论");
        assertEquals(UUID.nameUUIDFromBytes(("PROCUREMENT_INSPECTION|"+inspection+"|"+key+"-P").getBytes(StandardCharsets.UTF_8)),batch.events().getFirst().id());
        assertEquals(UUID.nameUUIDFromBytes(("PROCUREMENT_INSPECTION|"+inspection+"|"+key+"-F").getBytes(StandardCharsets.UTF_8)),batch.events().getLast().id());
        String old="original-eight-key";
        assertEquals(ProcurementInspectionService.dispositionEventId(inspection,old+"-P"),ProcurementInspectionService.derivedDispositionEventId(inspection,old,"-P"));
    }
    private static BatchInspectionDecideRequest.Item line(UUID id,String remaining,String pass,String fail,String key){return new BatchInspectionDecideRequest.Item(id,new BigDecimal(remaining),new BigDecimal(pass),new BigDecimal(fail),key);}
    private static ProcurementInspectionBatchCommand command(UUID receipt,List<BatchInspectionDecideRequest.Item> lines,String reason){return ProcurementInspectionBatchCommand.decide("PURCHASE",receipt,new BatchInspectionDecideRequest(lines,reason));}
}
