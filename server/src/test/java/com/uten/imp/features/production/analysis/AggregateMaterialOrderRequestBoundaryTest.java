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
    @Test void splitQuantityDecimalStringsArriveWithoutFloatingPointConversion() throws Exception {
        var mapper=new com.fasterxml.jackson.databind.ObjectMapper();
        var left=mapper.readValue("""
                {"clientGroupKey":"left","materialLineIds":["00000000-0000-0000-0000-000000000001"],
                 "route":"MAKE","qty":"333333333333.3333","allowPublicExtra":true}
                """,AggregateMaterialOrderContracts.GroupInput.class);
        var right=mapper.readValue("""
                {"clientGroupKey":"right","materialLineIds":["00000000-0000-0000-0000-000000000002"],
                 "route":"MAKE","qty":"666666666666.6666","allowPublicExtra":true}
                """,AggregateMaterialOrderContracts.GroupInput.class);
        assertThat(left.qty().add(right.qty())).isEqualByComparingTo("999999999999.9999");
        try(var factory=Validation.buildDefaultValidatorFactory()) {
            assertThat(factory.getValidator().validate(left)).isEmpty();
            assertThat(factory.getValidator().validate(right)).isEmpty();
        }
        var source=new AggregateMaterialOrderContracts.SourcePreview(new UUID(0,1),new UUID(0,2),"source",0,
                null,BigDecimal.ONE,BigDecimal.ONE,new BigDecimal("333333333333.3333"),BigDecimal.ZERO);
        var encoded=mapper.valueToTree(source);
        assertThat(encoded.path("allocatedQty").isNumber()).isTrue();
        assertThat(encoded.path("allocatedQtyExact").asText()).isEqualTo("333333333333.3333");
        assertThat(mapper.treeToValue(encoded,AggregateMaterialOrderContracts.SourcePreview.class).allocatedQty())
                .isEqualByComparingTo(source.allocatedQty());
        var group=new AggregateMaterialOrderContracts.GroupPreview("wire","compat","MAKE",new UUID(0,3),"code","name",
                null,"",null,"",BigDecimal.ONE,BigDecimal.ZERO,BigDecimal.ONE,left.qty(),right.qty(),BigDecimal.ZERO,
                null,null,null,null,null,null,null,List.of(source),List.of(),null);
        var groupJson=mapper.valueToTree(group);
        assertThat(groupJson.path("publicExtraQty").isNumber()).isTrue();
        assertThat(groupJson.path("publicExtraQtyExact").asText()).isEqualTo("666666666666.6666");
        assertThat(mapper.treeToValue(groupJson,AggregateMaterialOrderContracts.GroupPreview.class).publicExtraQty())
                .isEqualByComparingTo(right.qty());
    }

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
