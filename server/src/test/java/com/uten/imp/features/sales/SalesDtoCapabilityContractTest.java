package com.uten.imp.features.sales;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.sales.order.dto.OrderDetail;
import com.uten.imp.features.sales.order.dto.OrderListItem;
import com.uten.imp.features.sales.order.dto.OrderShippableLine;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentDetail;
import com.uten.imp.features.sales.other_shipment.dto.OtherShipmentListItem;
import com.uten.imp.features.sales.quote.dto.QuoteDetail;
import com.uten.imp.features.sales.quote.dto.QuoteListItem;
import com.uten.imp.features.sales.ret.dto.ReturnDetail;
import com.uten.imp.features.sales.ret.dto.ReturnListItem;
import com.uten.imp.features.sales.shipment.dto.ShipmentDetail;
import com.uten.imp.features.sales.shipment.dto.ShipmentListItem;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

import static org.junit.jupiter.api.Assertions.assertTrue;

class SalesDtoCapabilityContractTest {

    private final ObjectMapper objectMapper = new ObjectMapper();

    @Test
    void everyMutableSalesDocumentResponsePublishesServerComputedWritable() {
        List<Class<?>> responseTypes = List.of(
                QuoteListItem.class,
                QuoteDetail.class,
                OrderListItem.class,
                OrderDetail.class,
                OrderShippableLine.class,
                ShipmentListItem.class,
                ShipmentDetail.class,
                ReturnListItem.class,
                ReturnDetail.class,
                OtherShipmentListItem.class,
                OtherShipmentDetail.class);

        for (Class<?> responseType : responseTypes) {
            assertTrue(jsonProperties(responseType).contains("writable"),
                    () -> responseType.getSimpleName() + " must expose writable");
        }
    }

    @Test
    void shipmentResponsesPublishIndependentRejectCapability() {
        assertTrue(jsonProperties(ShipmentListItem.class).contains("canReject"));
        assertTrue(jsonProperties(ShipmentDetail.class).contains("canReject"));
    }

    private Set<String> jsonProperties(Class<?> type) {
        return objectMapper.getSerializationConfig()
                .introspect(objectMapper.constructType(type))
                .findProperties()
                .stream()
                .map(property -> property.getName())
                .collect(Collectors.toSet());
    }
}
