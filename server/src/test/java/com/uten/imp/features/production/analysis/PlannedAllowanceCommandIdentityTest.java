package com.uten.imp.features.production.analysis;

import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.IssueWorkshopPlansRequest;
import com.uten.imp.features.production.plan.ProductionOverproductionAllowance;
import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

class PlannedAllowanceCommandIdentityTest {
    private final UUID analysis=UUID.randomUUID(), line=UUID.randomUUID(), warehouse=UUID.randomUUID();

    @Test void omittedGoodsDefaultIsNotInterchangeableWithAnExplicitAllowance() {
        assertEquals(hash(null,null),hash(null,false));
        assertNotEquals(hash(null,null),hash(".100000",false));
        assertNotEquals(hash(null,true),hash(".1",true));
        assertNotEquals(hash(null,false),hash("0",false));
    }

    @Test void equivalentExplicitNumbersKeepTheirIdentityAndPublicIntentionRemainsDistinct() {
        assertEquals(hash(".1",null),hash(".100000",false));
        assertEquals(hash(".2",false),hash(".200000",null));
        assertNotEquals(hash(".2",false),hash(".200001",false));
        assertNotEquals(hash(".1",false),hash(".1",true));
        assertNotEquals(hash(null,false),hash(null,true));
    }

    @Test void theSameNumericContractAppliesWithoutAnHttpValidator() {
        assertEquals(0,ProductionOverproductionAllowance.DEFAULT_RATE.compareTo(ProductionOverproductionAllowance.normalize(null)));
        assertEquals(0,ProductionOverproductionAllowance.normalize(new BigDecimal("0")).signum());
        assertEquals(0,new BigDecimal("1.5").compareTo(ProductionOverproductionAllowance.normalize(new BigDecimal("1.5000000"))));
        assertThrows(ApiException.class,()->ProductionOverproductionAllowance.normalize(new BigDecimal(".0000001")));
        assertThrows(ApiException.class,()->ProductionOverproductionAllowance.normalize(new BigDecimal("-1")));
        assertThrows(ApiException.class,()->ProductionOverproductionAllowance.normalize(new BigDecimal("1000")));
    }

    private String hash(String rate,Boolean publicOnly) {
        var row=new IssueWorkshopPlansRequest.IssuePlanLine(null,line,BigDecimal.TEN,null,null,null,null,null,null,null,
                publicOnly,rate==null?null:new BigDecimal(rate));
        var request=new IssueWorkshopPlansRequest(1L,"a".repeat(64),"fixed-command-key",warehouse,LocalDate.of(2026,9,24),null,true,List.of(row));
        return ReflectionTestUtils.invokeMethod(MaterialAnalysisCommandService.class,"issueHash",analysis,request);
    }
}
