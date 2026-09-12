package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.features.production.mrp.ProductionGoodsWorkshopPreferenceService;
import org.junit.jupiter.api.Test;
import org.springframework.http.converter.json.MappingJackson2HttpMessageConverter;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class MaterialAnalysisResponseProjectionTest {
    private final ObjectMapper json = new ObjectMapper().findAndRegisterModules()
            .enable(com.fasterxml.jackson.databind.DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS)
            .disable(com.fasterxml.jackson.databind.SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);
    private final UUID analysisId = UUID.randomUUID();
    private final UUID warehouse = UUID.randomUUID();
    private final String materialKey = UUID.randomUUID() + "|NONE|" + UUID.randomUUID();

    @Test
    void httpNegotiationPreservesEveryLegacyFieldAndSharesOnlyIdenticalDimensionFacts() throws Exception {
        AnalysisView view = view(List.of(material("1", stock("0.0000")), material("2", stock("0.0000"))));
        MaterialAnalysisService service = mock(MaterialAnalysisService.class);
        when(service.detail(analysisId)).thenReturn(view);
        MockMvc mvc = controller(service, mock(MaterialAnalysisCommandService.class));
        JsonNode legacy = json.readTree(mvc.perform(get("/api/production/material-analyses/" + analysisId))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsByteArray());
        assertEquals(wireTree(view), legacy);
        JsonNode shared = json.readTree(mvc.perform(get("/api/production/material-analyses/" + analysisId)
                        .queryParam("projection", MaterialAnalysisResponseProjection.VERSION))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsByteArray());
        assertEquals(1, shared.get("warehouseBreakdownsByMaterialKey").size());
        assertFalse(shared.has("source"));
        for (JsonNode node : shared.get("flatMaterials")) assertFalse(node.has("warehouseBreakdown"));
        assertEquals(legacy, expand(shared));
        assertEquals(legacy, json.readTree(mvc.perform(get("/api/production/material-analyses/" + analysisId)
                        .queryParam("projection", "future-unknown"))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsByteArray()));
    }

    @Test
    void workshopResultUsesTheSameNegotiatedSnapshotAndKeepsReplayAndPlans() throws Exception {
        AnalysisView view = view(List.of(material("1", stock("12.3456"))));
        GenerateResult result = new GenerateResult(view, true, List.of(new GeneratedPlan(UUID.randomUUID(), "PLAN-1",
                "APPROVED", null, null, List.of(UUID.randomUUID()), List.of(), List.of())));
        MaterialAnalysisCommandService commands = mock(MaterialAnalysisCommandService.class);
        when(commands.issueWorkshopPlans(eq(analysisId), any())).thenReturn(result);
        MockMvc mvc = controller(mock(MaterialAnalysisService.class), commands);
        byte[] body = json.writeValueAsBytes(Map.of("version", 3, "fingerprint", "a".repeat(64),
                "warehouseId", warehouse, "idempotencyKey", "unchanged-command-key", "billDate", "2026-09-12",
                "lines", List.of(Map.of("analysisLineId", UUID.randomUUID(), "qty", new BigDecimal("1.0001")))));
        JsonNode actual = json.readTree(mvc.perform(post("/api/production/material-analyses/" + analysisId + "/issue-plans")
                        .queryParam("projection", MaterialAnalysisResponseProjection.VERSION)
                        .contentType("application/json").content(body))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsByteArray());
        assertEquals(wireTree(view), expand(actual.get("analysis")));
        assertTrue(actual.get("replayed").asBoolean());
        assertEquals(wireTree(result.plans()), actual.get("plans"));
        verify(commands).issueWorkshopPlans(eq(analysisId), any());
    }

    @Test
    void dimensionCollisionsAreRejectedAndEmptyWarehousesRemainExplicit() throws Exception {
        assertThrows(IllegalStateException.class, () -> MaterialAnalysisResponseProjection.project(
                view(List.of(material("1", stock("1.0000")), material("2", stock("2.0000"))))));
        JsonNode empty = wireTree(MaterialAnalysisResponseProjection.project(view(List.of(material("1", List.of())))));
        assertTrue(empty.get("warehouseBreakdownsByMaterialKey").get(materialKey).isEmpty());
        assertEquals(wireTree(view(List.of(material("1", List.of())))).get("flatMaterials").get(0).get("warehouseBreakdown"),
                expand(empty).get("flatMaterials").get(0).get("warehouseBreakdown"));
    }

    @Test
    void manyPathsKeepOneWarehouseListWithoutDroppingZeroesOrFalseFields() throws Exception {
        List<WarehouseBreakdown> stocks = stock("0.0000");
        List<MaterialView> nodes = java.util.stream.IntStream.range(0, 1000)
                .mapToObj(i -> material(Integer.toString(i), stocks)).toList();
        AnalysisView view = view(nodes);
        byte[] original = json.writeValueAsBytes(view);
        byte[] compact = json.writeValueAsBytes(MaterialAnalysisResponseProjection.project(view));
        assertTrue(compact.length < original.length - 250000, "Repeated warehouse objects must disappear from the wire");
        assertTrue(wireTree(view).equals(expand(json.readTree(compact))),
                "Expanding the shared wire form must preserve all node and warehouse fields");
    }

    private MockMvc controller(MaterialAnalysisService service, MaterialAnalysisCommandService commands) {
        return MockMvcBuilders.standaloneSetup(new MaterialAnalysisController(service, commands,
                        mock(MaterialStockReallocationService.class), mock(ProductionGoodsWorkshopPreferenceService.class),
                        mock(MaterialAnalysisSupplyProgressService.class), mock(SubcontractMakeTaskService.class),
                        mock(AuditDetailViewRecorder.class)))
                .setControllerAdvice(new MaterialAnalysisResponseProjection())
                .setMessageConverters(new MappingJackson2HttpMessageConverter(json)).build();
    }

    private AnalysisView view(List<MaterialView> materials) {
        return new AnalysisView(analysisId, "ACTIVE", 3, "a".repeat(64), "a".repeat(64), warehouse,
                List.of(warehouse), OffsetDateTime.parse("2026-09-12T00:00:00Z"), List.of(), materials, List.of(), List.of(),
                List.of("VIEW"), false, null, Map.of(), 2);
    }

    private MaterialView material(String suffix, List<WarehouseBreakdown> stocks) {
        return json.convertValue(Map.of("materialLineId", UUID.nameUUIDFromBytes(suffix.getBytes(java.nio.charset.StandardCharsets.UTF_8)),
                "analysisLineId", analysisId, "nodeKey", "root/" + suffix, "materialKey", materialKey,
                "requiredQty", new BigDecimal("10.0001"), "shortageQty", new BigDecimal("8.0000"),
                "routeConfirmed", false, "warehouseBreakdown", stocks), MaterialView.class);
    }

    private List<WarehouseBreakdown> stock(String value) {
        BigDecimal zero = new BigDecimal(value);
        return List.of(new WarehouseBreakdown(warehouse, "MAIN-1", "真实仓", zero, zero, zero, zero, zero, zero,
                zero, zero, zero, null));
    }

    private JsonNode wireTree(Object value) throws Exception {
        return json.readTree(json.writeValueAsBytes(value));
    }

    private ObjectNode expand(JsonNode projected) {
        ObjectNode result = projected.deepCopy();
        JsonNode stocks = result.remove("warehouseBreakdownsByMaterialKey");
        result.remove("projection");
        for (JsonNode node : result.get("flatMaterials")) {
            ((ObjectNode) node).set("warehouseBreakdown", stocks.get(node.get("materialKey").asText()));
        }
        return result;
    }
}
