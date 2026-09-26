package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import jakarta.validation.Validation;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import java.util.stream.IntStream;
import static org.assertj.core.api.Assertions.*;

class AggregateMaterialOrderRequestBoundaryTest {
    private static AggregateMaterialOrderContracts.GroupInput group(int count) {
        return new AggregateMaterialOrderContracts.GroupInput("same-component",
                IntStream.range(0,count).mapToObj(i->new UUID(0,i+1L)).toList(),"BUY",BigDecimal.ONE,
                false,null,null,null,null,null,null,null,null);
    }

    @Test void sourcePathsAreNotLimitedToTheFiveHundredPhysicalDocumentLines() {
        try(var factory=Validation.buildDefaultValidatorFactory()) {
            var validator=factory.getValidator();
            assertThat(validator.validate(group(501))).isEmpty();
            assertThat(validator.validate(group(10000))).isEmpty();
            assertThat(validator.validate(group(10001))).anySatisfy(violation->
                    assertThat(violation.getPropertyPath().toString()).isEqualTo("materialLineIds"));
        }
    }

    @Test void multipleGroupsCannotMultiplyTheTotalSourceScopeLimit() {
        assertThatCode(()->AggregateMaterialOrderPreviewService.requireSourceScope(List.of(group(6000),group(4000)))).doesNotThrowAnyException();
        assertThatThrownBy(()->AggregateMaterialOrderPreviewService.requireSourceScope(List.of(group(6000),group(4001))))
                .isInstanceOf(ApiException.class).hasMessageContaining("10000");
    }
}
