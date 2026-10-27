package com.uten.imp.common.finance;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class SubcontractMaterialDeliveryDifferenceTest {
    @Test void materialPriceMaskingRetainsExactSourceOrderFactsAndSourceUnit() throws Exception {
        for (String type : List.of("Issue", "Return")) {
            String prefix = "com.uten.imp.features.subcontract.material_" + type.toLowerCase() + ".";
            Class<?> dtoClass = Class.forName(prefix + "dto.Material" + type + "ItemDto");
            var constructor = dtoClass.getConstructors()[0];
            Object[] arguments = new Object[constructor.getParameterCount()];
            for (int index = 0; index < arguments.length; index++) {
                if (constructor.getParameterTypes()[index] == boolean.class) arguments[index] = false;
            }
            var dto = (ProcurementSourceOrderDifferenceResponse) constructor.newInstance(arguments);
            UUID sourceUnit = UUID.randomUUID();
            dto.setSourceOrderDifferenceQty(new BigDecimal("-9007199254740993.0001"));
            dto.setSourceOrderDifferenceUnitId(sourceUnit);
            Class<?> service = Class.forName(prefix + "SubcontractMaterial" + type + "Service");
            var mask = service.getDeclaredMethod("maskItemPrices", dtoClass);
            mask.setAccessible(true);
            var masked = (ProcurementSourceOrderDifferenceResponse) mask.invoke(null, dto);
            assertThat(masked.getSourceOrderDifferenceQtyExact()).as(type).isEqualTo("-9007199254740993.0001");
            assertThat(masked.getSourceOrderDifferenceUnitId()).isEqualTo(sourceUnit);
        }
    }
}
