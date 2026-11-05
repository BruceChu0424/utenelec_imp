package com.uten.imp.features.production.execution;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import static org.assertj.core.api.Assertions.*;

class DeliveryProcessingServiceTest {
    @Test void partialProcessingIsExactAndCompletesOnlyAtTheFrozenQuantity() {
        BigDecimal required=new BigDecimal("300.0000");
        BigDecimal first=DeliveryProcessingService.validatedCompleted(required,BigDecimal.ZERO,new BigDecimal("120.1250"),"已激光并核对图样A");
        BigDecimal second=DeliveryProcessingService.validatedCompleted(required,first,new BigDecimal("179.8750"),"余量完成并检验");
        assertThat(first).isEqualByComparingTo("120.1250");
        assertThat(second).isEqualByComparingTo(required);
    }
    @Test void overreportDoesNotCreateAnOutputOrDiscardAnExistingCompletion() {
        assertThatThrownBy(()->DeliveryProcessingService.validatedCompleted(new BigDecimal("300"),new BigDecimal("200"),new BigDecimal("100.0001"),"记录"))
                .isInstanceOf(ApiException.class).hasMessageContaining("超过");
    }
    @Test void quantitiesAndActualEvidenceCannotBeFabricatedWithBlankOrInvalidInputs() {
        for(String value:new String[]{"0","-1","0.0000000000000000000000001","10000000000000000000000000000000000000000"})
            assertThatThrownBy(()->DeliveryProcessingService.validatedCompleted(new BigDecimal("1000000000000000"),BigDecimal.ZERO,new BigDecimal(value),"记录"))
                    .isInstanceOf(ApiException.class);
        assertThatThrownBy(()->DeliveryProcessingService.validatedCompleted(BigDecimal.TEN,BigDecimal.ZERO,BigDecimal.ONE,"  "))
                .isInstanceOf(ApiException.class).hasMessageContaining("实际记录");
    }
}
