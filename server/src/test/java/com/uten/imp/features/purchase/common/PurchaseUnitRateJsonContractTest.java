package com.uten.imp.features.purchase.common;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.finance.ProcurementQuantities;
import com.uten.imp.features.purchase.order.dto.OrderItemDto;
import com.uten.imp.features.purchase.order.dto.OrderItemLine;
import com.uten.imp.features.purchase.request.dto.RequestItemDto;
import com.uten.imp.features.purchase.ret.dto.ReturnItemDto;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;

/** An API edit round-trip must retain every legal NUMERIC(18,6) conversion-rate digit. */
class PurchaseUnitRateJsonContractTest {
    private static final String RATE_TEXT = "999999999999.000001";
    private static final BigDecimal RATE = new BigDecimal(RATE_TEXT);
    private static final BigDecimal QTY = new BigDecimal("100");
    private static final UUID GOODS = UUID.fromString("e377dcb4-2aef-4944-bdd1-b99a9b2c44b8");
    private static final UUID UNIT = UUID.fromString("4c9d3a25-18b4-4f4e-9ad8-c0e09d85a74d");
    private final ObjectMapper mapper = new ObjectMapper().findAndRegisterModules();

    static Stream<Arguments> responses() {
        return Stream.of(
            Arguments.of("request", new RequestItemDto(null, 1, GOODS, null, null, null, null,
                null, UNIT, RATE, QTY, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO, null, null, null, null, null, null,
                BigDecimal.ZERO, QTY, 1)),
            Arguments.of("order", new OrderItemDto(null, 1, GOODS, null, null, null, null,
                null, UNIT, RATE, QTY, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO,
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, null, null, null,
                null, null, null, null, BigDecimal.ZERO, List.of())),
            Arguments.of("return", new ReturnItemDto(null, 1, GOODS, null, null, null, null,
                null, UNIT, RATE, QTY, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO,
                null, null, null, null, null))
        );
    }

    @ParameterizedTest(name = "{0}: response text to actual save request keeps the exact base quantity")
    @MethodSource("responses")
    void normalJsonResponseAndOrderSaveRetainTheExactConversionRate(String kind, Object response) throws Exception {
        String body = mapper.writeValueAsString(response);
        var json = mapper.readTree(body);
        assertThat(json.path("unitRate").isNumber()).as(kind + " legacy numeric property").isTrue();
        assertThat(body).contains("\"unitRate\":" + RATE_TEXT);
        assertThat(json.path("unitRateExact").isTextual()).isTrue();
        assertThat(json.path("unitRateExact").textValue()).isEqualTo(RATE_TEXT);

        // The frontend forwards the exact string; a typed BigDecimal request must never pass through double.
        String saveBody = mapper.writeValueAsString(Map.of(
            "goodsId", GOODS, "unitId", UNIT, "unitRate", json.path("unitRateExact").textValue(),
            "qty", "100", "giftQty", "0"
        ));
        OrderItemLine request = mapper.readValue(saveBody, OrderItemLine.class);
        assertThat(request.getUnitRate()).isEqualTo(RATE);
        assertThat(request.getQty().multiply(request.getUnitRate()))
            .isEqualByComparingTo("99999999999900.0001");
        assertThat(ProcurementQuantities.of(ProcurementQuantities.EXTRA_GIFT,
            request.getQty(), request.getGiftQty(), request.getUnitRate()).physicalBase())
            .isEqualByComparingTo("99999999999900.0001");
    }
}
