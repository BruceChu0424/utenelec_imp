package com.uten.imp.features.applications;
import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
class BusinessApplicationWorkflowTest {
    @Test void distinctPaperRoutesHaveNoPayrollOrAccidentalPayment(){
        assertEquals(List.of("DEPARTMENT","EXECUTIVE","FINANCE_RECEIVE"),BusinessApplicationWorkflow.stages("TRAVEL"));
        assertEquals(List.of("DEPARTMENT","FINANCE_INITIAL","FINANCE_REVIEW","EXECUTIVE","PAYMENT"),BusinessApplicationWorkflow.stages("PAYMENT"));
        assertEquals(BusinessApplicationWorkflow.stages("PAYMENT"),BusinessApplicationWorkflow.stages("PREPAYMENT"));
        assertEquals(List.of("PROCUREMENT","FINANCE_REVIEW","VICE_EXECUTIVE","EXECUTIVE","PAYMENT"),BusinessApplicationWorkflow.stages("SUPPLIER_PAYMENT"));
        assertThrows(ApiException.class,()->BusinessApplicationWorkflow.stages("PAYROLL_PAYMENT"));
        assertNull(BusinessApplicationWorkflow.next("TRAVEL","FINANCE_RECEIVE"));
        assertThrows(ApiException.class,()->BusinessApplicationWorkflow.next("TRAVEL","PAYMENT"));
    }
    @Test void exactAmountRejectsRoundingExponentsAndNegativeOrZeroPayments(){
        assertEquals(new BigDecimal("22011.68"),BusinessApplicationWorkflow.amount("22011.68",false));
        assertEquals(new BigDecimal("0"),BusinessApplicationWorkflow.amount("0",true));
        assertNull(BusinessApplicationWorkflow.amount(null,true));assertNull(BusinessApplicationWorkflow.amount("",true));
        String full="1234567890123456789012345678901234567890.123456789012345678901234";
        assertEquals(new BigDecimal(full),BusinessApplicationWorkflow.amount(full,false));
        assertEquals(new BigDecimal("1.001"),BusinessApplicationWorkflow.amount("1.001",false));
        for(String value:List.of("1.0000000000000000000000001","-1","1e2","NaN","Infinity","0","10000000000000000000000000000000000000000"))assertThrows(ApiException.class,()->BusinessApplicationWorkflow.amount(value,false),value);
    }
    @Test void taskCenterAliasesRetainEachIndependentNode(){
        assertEquals(Set.of("VICE_EXECUTIVE","EXECUTIVE"),BusinessApplicationWorkflow.scope("MANAGEMENT"));
        assertEquals(Set.of("DEPARTMENT","PROCUREMENT"),BusinessApplicationWorkflow.scope("PMC"));
        assertEquals(Set.of("FINANCE_INITIAL","FINANCE_REVIEW","FINANCE_RECEIVE","PAYMENT","FINANCE_POSTING"),BusinessApplicationWorkflow.scope("FINANCE"));
        assertEquals("application:receive",BusinessApplicationWorkflow.permission("FINANCE_RECEIVE"));
        assertEquals("application:pay",BusinessApplicationWorkflow.permission("PAYMENT"));
    }
    @Test void sharedPaperFixtureMatchesEveryKindAndItsContextualStageLabels() throws Exception {
        var contract=new com.fasterxml.jackson.databind.ObjectMapper().readTree(java.nio.file.Files.readString(java.nio.file.Path.of("../clients/windows_legacy/progress/contracts/employee-applications-workflow.json")));
        for(String kind:BusinessApplicationWorkflow.KINDS.keySet()){
            var stages=contract.path("orderedStages").path(kind);var actual=BusinessApplicationWorkflow.stages(kind);assertEquals(actual.size(),stages.size());
            for(int i=0;i<actual.size();i++){
                String stage=actual.get(i);assertEquals(stage,stages.get(i).asText());
                var override=contract.path("stageLabels").path(kind).path(stage);String expected=override.isMissingNode()?contract.path("stageLabels").path("default").path(stage).asText():override.asText();
                assertEquals(expected,BusinessApplicationWorkflow.label(kind,stage));
            }
        }
    }
}
