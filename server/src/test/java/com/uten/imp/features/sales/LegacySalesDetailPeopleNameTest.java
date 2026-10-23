package com.uten.imp.features.sales;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.sales.order.dto.OrderDetail;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentDetail;
import com.uten.imp.features.sales.ret.dto.ReturnDetail;
import com.uten.imp.features.sales.shipment.dto.ShipmentDetail;
import org.junit.jupiter.api.Test;

import java.lang.reflect.Constructor;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class LegacySalesDetailPeopleNameTest {

    @Test
    void additivePersonnelNamesKeepOriginalConstructorsAndSerializeAsFlatProperties() throws Exception {
        ObjectMapper mapper = new ObjectMapper().findAndRegisterModules();
        for (Contract contract : List.of(
                new Contract(OrderDetail.class, 51, false),
                new Contract(ShipmentDetail.class, 46, true),
                new Contract(OtherShipmentDetail.class, 32, true),
                new Contract(ReturnDetail.class, 34, false))) {
            Constructor<?>[] constructors = contract.type().getDeclaredConstructors();
            assertEquals(1, constructors.length, contract.type().getSimpleName());
            Constructor<?> constructor = constructors[0];
            assertEquals(contract.originalParameterCount(), constructor.getParameterCount(),
                    "The existing constructor signature must not gain the display-only state");
            Object[] arguments = new Object[constructor.getParameterCount()];
            Class<?>[] types = constructor.getParameterTypes();
            for (int index = 0; index < types.length; index++) {
                if (types[index] == boolean.class) arguments[index] = false;
                else if (types[index] == short.class) arguments[index] = (short) 0;
                else if (types[index] == int.class) arguments[index] = 0;
                else if (types[index] == long.class) arguments[index] = 0L;
                assertFalse(types[index].getSimpleName().equals("HistoricalWorkerNames"));
            }
            Object detail = constructor.newInstance(arguments);
            contract.type().getMethod("setSellerName", String.class).invoke(detail, "历史业务员(UT0191)");
            if (contract.sender()) {
                contract.type().getMethod("setSenderName", String.class).invoke(detail, "历史发货人(UT0192)");
            }
            JsonNode json = mapper.valueToTree(detail);
            assertEquals("历史业务员(UT0191)", json.path("sellerName").asText());
            assertTrue(json.path("sellerId").isNull(), "A display name must not create a role UUID");
            assertFalse(json.has("historicalWorkerNames"), "Internal state is not part of the API");
            if (contract.sender()) {
                assertEquals("历史发货人(UT0192)", json.path("senderName").asText());
                assertTrue(json.path("senderId").isNull());
            } else {
                assertFalse(json.has("senderName"));
            }
        }
    }

    private record Contract(Class<?> type, int originalParameterCount, boolean sender) {}
}
