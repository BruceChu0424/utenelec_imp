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
    void priceAcceptsFourDecimalPlacesWithoutFloatingPointConversion() {
        GoodsSaveRequest request = requestWithPrice(new BigDecimal("12345678901234.1234"));

        assertTrue(validator.validate(request).isEmpty());
    }

    @Test
    void priceRejectsValuesThatDoNotFitNumericEighteenFour() {
        assertFalse(validator.validate(
                        requestWithPrice(new BigDecimal("123.12345")))
                .isEmpty());
        assertFalse(validator.validate(
                        requestWithPrice(new BigDecimal("123456789012345.1234")))
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
