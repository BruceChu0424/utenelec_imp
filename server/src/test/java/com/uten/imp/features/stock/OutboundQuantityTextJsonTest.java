package com.uten.imp.features.stock;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryContracts;
import com.uten.imp.features.production.fulfillment.ProductionDrawDiscoveryBatchContracts;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemDto;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest;
import com.uten.imp.features.subcontract.plan.dto.OutboundContracts;
import com.uten.imp.features.sales.shipment.warehouse.WarehouseSalesOutboundLine;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;
import jakarta.validation.Validation;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.Arrays;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.*;

class OutboundQuantityTextJsonTest {
    private final ObjectMapper mapper = new ObjectMapper().findAndRegisterModules();
    private static final BigDecimal MAXIMUM = new BigDecimal("99999999999999.9999");

    static Stream<String> quantityTokens() {
        // These are raw request JSON tokens, never decoded via a double first.
        return Stream.of("\"99999999999999.9999\"", "\"0.0001\"",
                "99999999999999.9999", "0.0001");
    }

    @ParameterizedTest
    @MethodSource("quantityTokens")
    void actualDrawIssueAndCancelRequestsBindTextAndLegacyNumbersExactly(String token) throws Exception {
        BigDecimal expected = new BigDecimal(token.replace("\"", ""));
        var issue = mapper.readValue("""
                {"idempotencyKey":"DRAW-ISSUE-0123456789abcdef","reason":"精确出库",
                 "lines":[{"itemId":"00000000-0000-0000-0000-000000000001","qty":%s,
                           "weightKg":0.025,"qtyFromWeight":true}]}
                """.formatted(token), StockDocIssueRequest.class);
        var cancel = mapper.readValue("""
                {"idempotencyKey":"DRAW-ISSUE-REVERSE-0123456789abcdef","reason":"原仓退回",
                 "lines":[{"itemId":"00000000-0000-0000-0000-000000000001","qty":%s}]}
                """.formatted(token), StockDocIssueRequest.class);
        assertEquals(expected, issue.getLines().getFirst().getQty());
        assertEquals(expected, cancel.getLines().getFirst().getQty());
        assertEquals(issue.getLines().getFirst().getItemId(), cancel.getLines().getFirst().getItemId());
        assertEquals(new BigDecimal("0.025"), issue.getLines().getFirst().getWeightKg());
        assertEquals(Boolean.TRUE, issue.getLines().getFirst().getQtyFromWeight());
        assertNull(cancel.getLines().getFirst().getWeightKg());
        assertNull(cancel.getLines().getFirst().getQtyFromWeight());
        assertEquals("原仓退回", cancel.getReason());
        try (var factory = Validation.buildDefaultValidatorFactory()) {
            assertTrue(factory.getValidator().validate(issue).isEmpty());
            assertTrue(factory.getValidator().validate(cancel).isEmpty());
        }
    }

    @ParameterizedTest
    @MethodSource("quantityTokens")
    void actualSubcontractUpdateBindsQuantityTextWithoutChangingSourceOrConversion(String token) throws Exception {
        var update = mapper.readValue("""
                {"billDate":"2026-10-15","deliverDate":null,
                 "warehouseId":"00000000-0000-0000-0000-000000000002",
                 "items":[{"id":"00000000-0000-0000-0000-000000000001",
                           "goodsId":"00000000-0000-0000-0000-000000000003",
                           "unitId":"00000000-0000-0000-0000-000000000004",
                           "planItemId":"00000000-0000-0000-0000-000000000005",
                           "orderItemId":"00000000-0000-0000-0000-000000000006",
                           "qty":%s,"unitRate":"0.000001","weight":0.025,"qtyFromWeight":false}]}
                """.formatted(token), MaterialIssueSaveRequest.class);
        var line = update.getItems().getFirst();
        assertEquals(new BigDecimal(token.replace("\"", "")), line.getQty());
        assertEquals(new BigDecimal("0.000001"), line.getUnitRate());
        assertEquals(new BigDecimal("0.025"), line.getWeight());
        assertEquals(Boolean.FALSE, line.getQtyFromWeight());
        assertEquals("00000000-0000-0000-0000-000000000005", line.getPlanItemId().toString());
        assertEquals("00000000-0000-0000-0000-000000000006", line.getOrderItemId().toString());
        assertNull(update.getDeliverDate());
        try (var factory = Validation.buildDefaultValidatorFactory()) {
            assertTrue(factory.getValidator().validate(update).isEmpty());
        }
    }

    @ParameterizedTest
    @MethodSource("quantityTokens")
    void discoveryConfigureAndActualBatchBindOriginalQuantityTextAndLegacyNumbers(String token) throws Exception {
        String items = """
                [{"goodsId":"00000000-0000-0000-0000-000000000003",
                  "unitId":"00000000-0000-0000-0000-000000000004",
                  "warehouseId":"00000000-0000-0000-0000-000000000002","qty":%s}]
                """.formatted(token);
        var configure = mapper.readValue("""
                {"expectedVersion":7,"idempotencyKey":"ca538012-e707-4b83-aed6-dda8b6096913","items":%s}
                """.formatted(items), ProductionMaterialDiscoveryContracts.Configure.class);
        var batch = mapper.readValue("""
                {"idempotencyKey":"ca538012-e707-4b83-aed6-dda8b6096913","docIds":[],
                 "discoveries":[{"requestId":"00000000-0000-0000-0000-000000000007",
                                 "expectedVersion":7,"items":%s}],"reason":"实料出库"}
                """.formatted(items), ProductionDrawDiscoveryBatchContracts.Request.class);
        BigDecimal expected = new BigDecimal(token.replace("\"", ""));
        assertEquals(expected, configure.items().getFirst().qty());
        assertEquals(expected, batch.discoveries().getFirst().items().getFirst().qty());
        assertEquals(configure.items(), batch.discoveries().getFirst().items());
        assertEquals(Long.valueOf(7), configure.expectedVersion());
        assertEquals(Long.valueOf(7), batch.discoveries().getFirst().expectedVersion());
    }

    @Test
    void stringBindingKeepsExistingPositiveAndRequiredDrawGuards() throws Exception {
        try (var factory = Validation.buildDefaultValidatorFactory()) {
            for (String token : new String[]{"\"0\"", "\"-0.0001\"", "null"}) {
                var issue = mapper.readValue("""
                        {"idempotencyKey":"DRAW-ISSUE-0123456789abcdef",
                         "lines":[{"itemId":"00000000-0000-0000-0000-000000000001","qty":%s}]}
                        """.formatted(token), StockDocIssueRequest.class);
                assertTrue(factory.getValidator().validate(issue).stream()
                        .anyMatch(value -> value.getPropertyPath().toString().endsWith("qty")), token);
            }
        }
        assertThrows(com.fasterxml.jackson.core.JsonProcessingException.class,
                () -> mapper.readValue("""
                        {"lines":[{"itemId":"00000000-0000-0000-0000-000000000001","qty":"NaN"}]}
                        """, StockDocIssueRequest.class));
    }

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
