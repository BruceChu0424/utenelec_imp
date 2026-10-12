package com.uten.imp.features.sales.order;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.util.DecimalText;
import org.junit.jupiter.api.Test;

import java.lang.reflect.Constructor;
import java.math.BigDecimal;
import java.util.Arrays;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class CommercialListExactDisplayContractTest {
    private static final List<String> TYPES = List.of(
            "sales.order.dto.OrderListItem", "sales.quote.dto.QuoteListItem",
            "sales.shipment.dto.ShipmentListItem", "sales.other_shipment.dto.OtherShipmentListItem",
            "sales.ret.dto.ReturnListItem", "purchase.order.dto.OrderListItem",
            "purchase.request.dto.RequestListItem", "purchase.receipt.dto.ReceiptListItem",
            "purchase.ret.dto.ReturnListItem", "subcontract.application.dto.ApplicationListItem",
            "subcontract.inquiry.dto.InquiryListItem", "subcontract.material_issue.dto.MaterialIssueListItem",
            "subcontract.material_return.dto.MaterialReturnListItem", "subcontract.order.dto.OrderListItem",
            "subcontract.receipt.dto.ReceiptListItem", "subcontract.ret.dto.ReturnListItem",
            "subcontract.waste.dto.WasteListItem");

    @Test
    void actualListJacksonResponsesKeepSmallAndLargeDecimalsWithoutChangingNumericFields() throws Exception {
        for (String type : TYPES) {
            Class<?> cls = Class.forName("com.uten.imp.features." + type);
            Constructor<?> ctor = Arrays.stream(cls.getConstructors())
                    .min(java.util.Comparator.comparingInt(Constructor::getParameterCount)).orElseThrow();
            Object[] args = Arrays.stream(ctor.getParameterTypes()).map(t -> {
                if (t == boolean.class) return Boolean.FALSE;
                if (t == int.class) return Integer.valueOf(0);
                if (t == long.class) return Long.valueOf(0);
                if (t == short.class) return Short.valueOf((short) 0);
                return null;
            }).toArray();
            for (String name : List.of("totalLocal", "totalOriginal")) {
                java.lang.reflect.Field field;
                try { field = cls.getDeclaredField(name); }
                catch (NoSuchFieldException ignored) { continue; }
                Object dto = ctor.newInstance(args);
                field.setAccessible(true);
                for (String raw : List.of("0.0001", "99999999999999.9999")) {
                    var amount = new BigDecimal(raw);
                    field.set(dto, amount);
                    var mapper = new ObjectMapper().findAndRegisterModules()
                            .enable(com.fasterxml.jackson.databind.DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS);
                    var json = mapper.readTree(mapper.writeValueAsString(dto));
                    assertThat(json.get(name + "Exact").textValue()).as(type).isEqualTo(DecimalText.of(amount));
                    assertThat(json.get(name).decimalValue()).as(type).isEqualByComparingTo(amount);
                }
                field.set(dto, null);
                assertThat(new ObjectMapper().findAndRegisterModules().valueToTree(dto).get(name + "Exact").isNull()).isTrue();
                try {
                    var masked = cls.getDeclaredField("priceMasked");
                    masked.setAccessible(true);
                    masked.set(dto, true);
                    field.set(dto, new BigDecimal("99999999999999.9999"));
                    assertThat(new ObjectMapper().findAndRegisterModules().valueToTree(dto).get(name + "Exact").isNull()).as(type).isTrue();
                } catch (NoSuchFieldException ignored) {
                    // DTOs without a mask flag rely on the already null-authorized numeric value.
                }
            }
        }
    }
}
