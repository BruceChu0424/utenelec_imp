package com.uten.imp.features.production.fulfillment;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.lang.reflect.InvocationTargetException;
import java.math.BigDecimal;
import java.util.Arrays;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ProcurementOrderTerminationSourceServiceTest {
    @SuppressWarnings("unchecked")
    private static Map<String,Object> parameters(Object[] pairs) throws ReflectiveOperationException {
        var method=ProcurementOrderTerminationSourceService.class.getDeclaredMethod("args",Object[].class);
        method.setAccessible(true);
        return (Map<String,Object>)method.invoke(null,(Object)pairs);
    }

    @Test void completePairsIncludeTheLastValueAndPreserveNullableSourceIdentity() throws Exception {
        UUID item=UUID.randomUUID();
        Map<String,Object> values=parameters(new Object[]{"item",item,"row",null,"qty",BigDecimal.ONE});
        assertThat(values).hasSize(3).containsEntry("item",item).containsEntry("row",null)
                .containsEntry("qty",BigDecimal.ONE);
        assertThat(parameters(new Object[]{"item",item})).containsExactlyEntriesOf(Map.of("item",item));
        assertThat(parameters(new Object[0])).isEmpty();
    }

    @ParameterizedTest @ValueSource(ints={1,3,5})
    void unmatchedKeyIsRejectedBeforeReadingAPastEndValue(int length) {
        Object[] incomplete=new Object[length];
        Arrays.fill(incomplete,"synthetic");
        assertThatThrownBy(()->parameters(incomplete)).isInstanceOf(InvocationTargetException.class)
                .hasCauseInstanceOf(IllegalArgumentException.class)
                .hasRootCauseMessage("Expected complete SQL parameter key/value pairs");
    }

    @Test void absentPairArrayIsAnExplicitContractFailure() {
        assertThatThrownBy(()->parameters(null)).isInstanceOf(InvocationTargetException.class)
                .hasCauseInstanceOf(IllegalArgumentException.class);
    }
}
