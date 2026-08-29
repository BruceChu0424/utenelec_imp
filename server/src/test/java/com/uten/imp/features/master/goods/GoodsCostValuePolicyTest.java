package com.uten.imp.features.master.goods;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class GoodsCostValuePolicyTest {

    private final Validator validator = Validation
            .buildDefaultValidatorFactory()
            .getValidator();

    @Test
    void requestRejectsNegativeAmountsAndRatesAboveOneHundred() {
        GoodsSaveRequest request = validRequest();
        request.setMachiningE(new BigDecimal("-0.0950"));
        request.setMakeRate(new BigDecimal("100.0001"));

        assertThat(validator.validate(request))
                .extracting(violation -> violation.getPropertyPath().toString())
                .contains("machiningE", "makeRate");
        assertThatThrownBy(() -> GoodsCostValuePolicy.validateRequest(request))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void requestAcceptsExactStorageAndPercentageBounds() {
        GoodsSaveRequest request = validRequest();
        request.setSourceE(GoodsCostValuePolicy.MAX_AMOUNT);
        request.setWorkRate(GoodsCostValuePolicy.MAX_RATE);
        request.setCTotal(BigDecimal.ZERO.setScale(4));

        assertThat(validator.validate(request)).isEmpty();
        assertThatCode(() -> GoodsCostValuePolicy.validateRequest(request))
                .doesNotThrowAnyException();
    }

    @Test
    void entityGuardAlsoCoversLegacyOnlyManageAndElectricCosts() {
        Goods goods = new Goods();
        goods.setManageE(new BigDecimal("-0.0001"));

        assertThatThrownBy(() -> GoodsCostValuePolicy.validateEntity(goods))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("管理费");

        goods.setManageE(BigDecimal.ZERO);
        goods.setElectricE(GoodsCostValuePolicy.MAX_AMOUNT.add(new BigDecimal("0.0001")));
        assertThatThrownBy(() -> GoodsCostValuePolicy.validateEntity(goods))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("电气费");
    }

    private static GoodsSaveRequest validRequest() {
        GoodsSaveRequest request = new GoodsSaveRequest();
        request.setCategoryId(UUID.randomUUID());
        request.setName("测试货品");
        return request;
    }
}
