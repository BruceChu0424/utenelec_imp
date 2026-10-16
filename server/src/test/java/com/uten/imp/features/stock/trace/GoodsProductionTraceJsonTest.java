package com.uten.imp.features.stock.trace;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import java.math.BigDecimal;
import java.util.Arrays;
import java.util.List;
import static com.uten.imp.features.stock.trace.GoodsProductionTraceContracts.*;
import static org.junit.jupiter.api.Assertions.*;

class GoodsProductionTraceJsonTest {
    private final ObjectMapper mapper=new ObjectMapper().findAndRegisterModules();
    private static final List<Class<?>> RESPONSES=List.of(TraceRow.class,ProductionReport.class,ReceiptSource.class);

    @ParameterizedTest
    @ValueSource(strings={"12345678901234.0001","0.00001","1E-7","1E+3","0.0000","-0.0001","-12345678901234.0001"})
    void everyQuantityCrossesJsonAsExactPlainDecimalText(String original) throws Exception {
        BigDecimal value=new BigDecimal(original);
        String expected=value.stripTrailingZeros().toPlainString();
        for(Class<?> type:RESPONSES) {
            var json=mapper.readTree(mapper.writeValueAsBytes(response(type,value)));
            for(var component:type.getRecordComponents()) {
                if(component.getType()!=BigDecimal.class)continue;
                var quantity=json.path(component.getName());
                assertTrue(quantity.isTextual(),type.getSimpleName()+"."+component.getName()+" must not become a JSON number");
                assertEquals(expected,quantity.textValue(),type.getSimpleName()+"."+component.getName());
                assertEquals(0,value.compareTo(new BigDecimal(quantity.textValue())));
                assertFalse(quantity.textValue().matches(".*[eE].*"),"Clients consume plain decimals only");
            }
        }
    }

    @Test
    void unknownConsumptionAndMaskedQuantitiesRemainNull() throws Exception {
        for(Class<?> type:RESPONSES) {
            var json=mapper.readTree(mapper.writeValueAsBytes(response(type,null)));
            for(var component:type.getRecordComponents())if(component.getType()==BigDecimal.class)
                assertTrue(json.path(component.getName()).isNull(),type.getSimpleName()+"."+component.getName());
        }
    }

    private static Object response(Class<?> type,BigDecimal quantity) throws Exception {
        var constructor=type.getDeclaredConstructors()[0];
        Object[] arguments=Arrays.stream(constructor.getParameterTypes())
                .map(parameter->parameter==BigDecimal.class?quantity:parameter==List.class?List.of():null).toArray();
        return constructor.newInstance(arguments);
    }
}
