package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;
import java.math.BigDecimal;
import java.util.*;
import static com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.*;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class MaterialRowOrderMethodTest {
    @Test void totalCoverageDistinguishesFullNewOrderFromUsingTheExisting120() {
        assertQty("1000",MaterialOrderQuantity.incremental(q("1000"),"COVERAGE_TOTAL",q("1000"),q("880"),"ORDER_ALL"));
        assertQty("880",MaterialOrderQuantity.incremental(q("1000"),"COVERAGE_TOTAL",q("1000"),q("880"),"AVAILABLE_THEN_ORDER"));
        assertQty("880",MaterialOrderQuantity.incremental(q("1000"),"COVERAGE_TOTAL",q("1000"),q("880"),"AVAILABLE_ONLY"));
        assertFalse(MaterialOrderQuantity.skipClaims("AVAILABLE_ONLY",true));
        assertTrue(MaterialOrderQuantity.availableOnly("AVAILABLE_ONLY"));
        assertFalse(MaterialOrderQuantity.availableOnly("AVAILABLE_THEN_ORDER"));
        assertTrue(MaterialOrderQuantity.skipClaims("ORDER_ALL",false));
    }
    @Test void fullStockAndFourDecimalBoundariesPreserveTotalVersusNewQuantity() {
        for(String text:List.of("0.0001","1","1000","999999999999.9999")) {
            BigDecimal amount=q(text);
            assertQty(text,MaterialOrderQuantity.incremental(amount,"COVERAGE_TOTAL",amount,BigDecimal.ZERO,"ORDER_ALL"));
            assertQty("0",MaterialOrderQuantity.incremental(amount,"COVERAGE_TOTAL",amount,BigDecimal.ZERO,"AVAILABLE_THEN_ORDER"));
            assertQty(text,MaterialOrderQuantity.incremental(amount,null,amount,BigDecimal.ZERO,"AVAILABLE_THEN_ORDER"));
        }
        assertThrows(ApiException.class,()->MaterialOrderQuantity.incremental(q("1"),"INVALID",q("1"),q("1"),"ORDER_ALL"));
        assertThrows(ApiException.class,()->MaterialOrderQuantity.skipClaims("UNKNOWN",false));
    }
    @Test void aggregateConvertsEachOriginalSourceOnceAndRetainsPerRowPolicy() {
        UUID first=UUID.randomUUID(),second=UUID.randomUUID();
        MaterialView a=row(first,"1000","880"),b=row(second,"1000","0");
        var input=new GroupInput("two-origins",List.of(first,second),"BUY",q("2000"),true,null,null,null,null,null,null,null,BigDecimal.ZERO,
                Map.of(first,q("1000"),second,q("1000")),false,"COVERAGE_TOTAL","AVAILABLE_THEN_ORDER");
        var effective=AggregateMaterialOrderPreviewService.incrementalInput(input,Map.of(first,a,second,b));
        assertQty("880",effective.qty());assertQty("880",effective.sourceRequestedQtyByMaterialLineId().get(first));
        assertQty("0",effective.sourceRequestedQtyByMaterialLineId().get(second));
        assertNull(effective.quantityMode());assertEquals("AVAILABLE_THEN_ORDER",effective.orderMethod());
        assertSame(effective,AggregateMaterialOrderPreviewService.incrementalInput(effective,Map.of(first,a,second,b)));
    }
    @Test void nullableOldPolicyIsNotInventedDuringFrozenRequestSerialization() throws Exception {
        var old=new GroupInput("old-frozen",List.of(UUID.randomUUID()),"BUY",q("1000"),false,null,null,null,null,null,null,null,BigDecimal.ZERO);
        ObjectMapper mapper=new ObjectMapper();String oldJson=mapper.writeValueAsString(old);
        assertFalse(oldJson.contains("skipAutoClaim"));assertFalse(oldJson.contains("quantityMode"));assertFalse(oldJson.contains("orderMethod"));
        GroupInput restored=mapper.readValue(oldJson,GroupInput.class);
        assertEquals(old,restored);assertTrue(restored.skipClaims(true));assertFalse(restored.skipClaims(false));
        var explicit=new GroupInput(old.clientGroupKey(),old.materialLineIds(),old.route(),old.qty(),false,null,null,null,null,null,null,null,BigDecimal.ZERO,Map.of(),false,"COVERAGE_TOTAL","ORDER_ALL");
        assertTrue(explicit.skipClaims(false));assertEquals(explicit,mapper.readValue(mapper.writeValueAsString(explicit),GroupInput.class));
    }
    @Test void stockOnlyParentDoesNotActivateNewChildrenAndKeepsExistingProduction() {
        var shortage=new MaterialAnalysisService.NodeAllocation(q("120"),q("880"));
        assertQty("880",MaterialAnalysisService.parentPlannedOutput(shortage,MaterialAnalysisService.ParentSupplyCommitment.NONE));
        var only=new MaterialAnalysisService.ParentSupplyCommitment(q("0"),q("0"),q("0"),q("0"),q("0"));
        assertQty("0",MaterialAnalysisService.parentPlannedOutput(shortage,only));
        var alreadyRunning=new MaterialAnalysisService.ParentSupplyCommitment(q("0"),q("200"),q("200"),q("0"),q("200"));
        assertQty("200",MaterialAnalysisService.parentPlannedOutput(shortage,alreadyRunning));
    }
    @Test void salesStockDoesNotReduceAdmittedRequirementOrRewriteExistingPartialAnalysis() {
        var full=salesSource("1000","120");assertNull(full.planningBlockedReason());assertQty("1000",full.requestedQty());
        var oldPartial=salesSource("880","120");assertNull(oldPartial.planningBlockedReason());assertQty("880",oldPartial.requestedQty());
        var allStock=salesSource("1000","1000");assertNull(allStock.planningBlockedReason());assertQty("1000",allStock.requestedQty());
    }
    private static MaterialAnalysisService.SourceLine salesSource(String requested,String reserved) {
        Object[] values=new Object[44];
        for(int index: new int[]{16,17,18,19,20,21,22,23,24,25,26,27,36,37,38,39,40})values[index]=BigDecimal.ZERO;
        values[0]=UUID.randomUUID();values[1]="SALES_ORDER_ITEM";values[2]=UUID.randomUUID();values[3]=UUID.randomUUID();
        values[8]=UUID.randomUUID();values[14]=UUID.randomUUID();values[16]=BigDecimal.ONE;values[17]=q(requested);values[20]=q("1000");values[24]=q(reserved);
        values[28]=(short)1;values[29]=false;values[30]=false;values[31]=false;values[32]=false;values[35]=1;values[43]=true;
        return MaterialAnalysisService.SourceLine.from(values);
    }
    private static MaterialView row(UUID id,String required,String pending) {
        MaterialView row=mock(MaterialView.class);when(row.materialLineId()).thenReturn(id);when(row.requiredQty()).thenReturn(q(required));
        when(row.sourceRequiredQty()).thenReturn(q(required));when(row.planningUncoveredQty()).thenReturn(q(pending));return row;
    }
    private static BigDecimal q(String text){return new BigDecimal(text);}
    private static void assertQty(String expected,BigDecimal actual){assertEquals(0,q(expected).compareTo(actual));}
}
