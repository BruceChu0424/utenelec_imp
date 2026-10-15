package com.uten.imp.features.stock;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryContracts;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemDto;
import com.uten.imp.features.subcontract.plan.dto.OutboundContracts;
import com.uten.imp.features.sales.shipment.warehouse.WarehouseSalesOutboundLine;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.Arrays;

import static org.junit.jupiter.api.Assertions.*;

class OutboundQuantityTextJsonTest {
    private final ObjectMapper mapper = new ObjectMapper().findAndRegisterModules();
    private static final BigDecimal MAXIMUM = new BigDecimal("99999999999999.9999");

    @Test
    void subcontractTaskProvidesOriginalUpperBoundCurrentAndAvailableFacts() {
        var line = new OutboundContracts.OutboundTaskLine(null, null, 1, null, null,
                null, null, null, null, null, MAXIMUM, new BigDecimal("0.0001"), null, null);
        var json = mapper.valueToTree(line);
        assertEquals(MAXIMUM.toPlainString(), json.path("requestedQtyExact").textValue());
        assertEquals("0.0001", json.path("qtyExact").textValue());
        assertTrue(json.path("stockAvailableQtyExact").isNull());
        assertTrue(json.path("requestedQty").isNumber(), "legacy numeric field remains compatible");
    }

    @Test
    void actualMaterialIssueDraftKeepsQtyAndSixPlaceUnitRateWithoutRounding() throws Exception {
        var constructor = MaterialIssueItemDto.class.getConstructors()[0];
        Object[] arguments = Arrays.stream(constructor.getParameterTypes())
                .map(type -> type == boolean.class ? Boolean.FALSE : null).toArray();
        var item = (MaterialIssueItemDto) constructor.newInstance(arguments);
        ReflectionTestUtils.setField(item, "qty", MAXIMUM);
        ReflectionTestUtils.setField(item, "requestedQty", new BigDecimal("0.0001"));
        ReflectionTestUtils.setField(item, "unitRate", new BigDecimal("0.000001"));
        var json = mapper.valueToTree(item);
        assertEquals(MAXIMUM.toPlainString(), json.path("qtyExact").textValue());
        assertEquals("0.0001", json.path("requestedQtyExact").textValue());
        assertEquals("0.000001", json.path("unitRateExact").textValue());
        ReflectionTestUtils.setField(item, "qty", null);
        assertTrue(mapper.valueToTree(item).path("qtyExact").isNull());
    }

    @Test
    void warehouseDiscoverySuggestionsAndConfiguredSourcesKeepDecimalText() {
        var suggestion = new ProductionMaterialDiscoveryContracts.SuggestedItem(
                null, null, null, null, null, null, null, MAXIMUM, null, null);
        var configured = new ProductionMaterialDiscoveryContracts.Item(null, null, null,
                null, null, null, null, null, null, null, null, new BigDecimal("0.0001"), null, null);
        assertEquals(MAXIMUM.toPlainString(), mapper.valueToTree(suggestion).path("qtyExact").textValue());
        assertEquals("0.0001", mapper.valueToTree(configured).path("qtyExact").textValue());
        var unknown = new ProductionMaterialDiscoveryContracts.SuggestedItem(
                null, null, null, null, null, null, null, null, null, null);
        assertTrue(mapper.valueToTree(unknown).path("qtyExact").isNull());
    }

    @Test
    void salesWarehouseReadModelPreservesAuthoritativeQuantityAlongsideLegacyNumber() throws Exception {
        var line = mapper.readValue("{\"quantity\":" + MAXIMUM.toPlainString() + "}",
                WarehouseSalesOutboundLine.class);
        assertEquals(MAXIMUM, line.quantity());
        assertEquals(MAXIMUM.toPlainString(), mapper.valueToTree(line).path("quantityExact").textValue());
    }
}
