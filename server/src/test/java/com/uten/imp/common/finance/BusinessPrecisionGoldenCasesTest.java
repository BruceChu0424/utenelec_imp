package com.uten.imp.common.finance;

import com.uten.imp.testsupport.BusinessPrecisionContractCases;
import java.math.BigDecimal;
import java.util.*;
import org.junit.jupiter.api.*;
import static org.assertj.core.api.Assertions.*;

class BusinessPrecisionGoldenCasesTest {
    @TestFactory List<DynamicTest> sharedCrossLanguageCases(){
        return BusinessPrecisionContractCases.load().stream().map(row->DynamicTest.dynamicTest(row.path("id").asText(),()->{
            var choices=new HashMap<String,BusinessPrecisionContext.Choice>();
            if(row.has("choice"))choices.put("ratio",new BusinessPrecisionContext.Choice(row.path("choice").path("scale").asInt(),row.path("choice").path("rounding").asText()));
            try(var ignored=BusinessPrecisionContext.use(choices)){
                var numerator=new BigDecimal(row.path("numerator").asText());var denominator=new BigDecimal(row.path("denominator").asText());int max=row.path("maxScale").asInt();
                if(row.has("required"))assertThatThrownBy(()->BusinessPrecisionContext.divide(numerator,denominator,"ratio","本次比率",max))
                    .isInstanceOfSatisfying(BusinessPrecisionRequiredException.class,error->assertThat(error.details()).containsEntry("reason",row.path("required").asText()));
                else assertThat(BusinessPrecisionContext.divide(numerator,denominator,"ratio","本次比率",max)).isEqualByComparingTo(row.path("expected").asText());
            }
        })).toList();
    }
}
