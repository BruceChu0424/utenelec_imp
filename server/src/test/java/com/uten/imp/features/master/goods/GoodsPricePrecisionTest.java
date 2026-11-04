package com.uten.imp.features.master.goods;

import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class GoodsPricePrecisionTest {

    private final Validator validator = Validation
            .buildDefaultValidatorFactory()
            .getValidator();

    @Test
    void priceAcceptsNativeFortyByTwentyFourWithoutFloatingPointConversion() {
        GoodsSaveRequest request = requestWithPrice(new BigDecimal("1234567890123456789012345678901234567890.123456789012345678901234"));

        assertTrue(validator.validate(request).isEmpty());
    }

    @Test
    void priceRejectsValuesOutsideNativeCapacity() {
        assertFalse(validator.validate(
                        requestWithPrice(new BigDecimal("0.0000000000000000000000001")))
                .isEmpty());
        assertFalse(validator.validate(
                        requestWithPrice(new BigDecimal("10000000000000000000000000000000000000000")))
                .isEmpty());
    }

    private static GoodsSaveRequest requestWithPrice(BigDecimal price) {
        GoodsSaveRequest request = new GoodsSaveRequest();
        request.setCategoryId(UUID.randomUUID());
        request.setName("测试货品");
        request.setPrice(price);
        return request;
    }
}
