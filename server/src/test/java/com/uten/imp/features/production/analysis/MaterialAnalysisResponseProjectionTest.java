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

    @Test
    void sparseRowsExpandToEveryOriginalFieldIncludingExplicitNullZeroFalseAndEmptyArrays() throws Exception {
        ObjectNode unusual = (ObjectNode) wireTree(material("prototype", stock("0.0000")));
        unusual.remove("nodeRole");
        unusual.put("spec", "prototype specification");
        unusual.put("requiredQty", new BigDecimal("12345678901234.5678"));
        unusual.put("routeConfirmed", true);
        unusual.set("notifiedTargets", json.valueToTree(List.of("BUY")));
        MaterialView prototype = json.treeToValue(unusual, MaterialView.class);
        ObjectNode other = unusual.deepCopy();
        other.put("materialLineId", UUID.randomUUID().toString());
        other.putNull("spec");
        other.put("requiredQty", new BigDecimal("0.0000"));
        other.put("routeConfirmed", false);
        other.set("notifiedTargets", json.createArrayNode());
        AnalysisView view = view(List.of(prototype, json.treeToValue(other, MaterialView.class)));
        JsonNode compact = wireTree(MaterialAnalysisSparseProjection.project(view));
        assertEquals(MaterialAnalysisResponseProjection.VERSION_V2, compact.path("projection").asText());
        assertTrue(compact.path("flatMaterials").get(0).isEmpty(), "The prototype can be represented by an empty sparse row");
        JsonNode overrides = compact.path("flatMaterials").get(1);
        assertTrue(overrides.has("spec") && overrides.get("spec").isNull());
        assertTrue(overrides.has("requiredQty") && overrides.get("requiredQty").decimalValue().signum() == 0);
        assertTrue(overrides.has("routeConfirmed") && !overrides.get("routeConfirmed").asBoolean());
        assertTrue(overrides.has("notifiedTargets") && overrides.get("notifiedTargets").isEmpty());
        assertEquals(wireTree(view), expand(compact));
        assertEquals(new BigDecimal("12345678901234.5678"), compact.path("materialDefaults").path("requiredQty").decimalValue());
    }

    @Test
    void sparseEmptyAndLargeSnapshotsReuseSourceListWithoutConstructingASecondMaterialTree() throws Exception {
        AnalysisView empty = view(List.of());
        JsonNode emptyWire = wireTree(MaterialAnalysisSparseProjection.project(empty));
        assertTrue(emptyWire.path("materialDefaults").isEmpty());
        assertTrue(emptyWire.path("flatMaterials").isEmpty());
        assertEquals(wireTree(empty), expand(emptyWire));
        List<MaterialView> nodes = java.util.stream.IntStream.range(0, 1000)
                .mapToObj(i -> material("sparse-" + i, stock("0.0000"))).toList();
        AnalysisView view = view(nodes);
        var projected = MaterialAnalysisSparseProjection.project(view);
        assertSame(view.flatMaterials(), projected.flatMaterials().source());
        byte[] legacy = json.writeValueAsBytes(view);
        byte[] compact = json.writeValueAsBytes(projected);
        assertTrue(compact.length < legacy.length / 3, "Repeated fields belong to one explicit default object");
        assertEquals(wireTree(view), expand(json.readTree(compact)));
        assertEquals(wireTree(view), expand(wireTree(MaterialAnalysisResponseProjection.project(view))), "v1 remains unchanged");
    }

    @Test
    void sparseProjectionNegotiatesByQueryOrHeaderAndQueryHasPrecedence() throws Exception {
        AnalysisView view = view(List.of(material("1", stock("0.0000")), material("2", stock("0.0000"))));
        MaterialAnalysisService service = mock(MaterialAnalysisService.class);
        when(service.detail(analysisId)).thenReturn(view);
        MockMvc mvc = controller(service, mock(MaterialAnalysisCommandService.class));
        for (boolean query : List.of(false, true)) {
            var request = get("/api/production/material-analyses/" + analysisId);
            if (query) request.queryParam("projection", MaterialAnalysisResponseProjection.VERSION_V2);
            else request.header("X-Material-Analysis-Projection", MaterialAnalysisResponseProjection.VERSION_V2);
            var response = mvc.perform(request).andExpect(status().isOk()).andReturn().getResponse();
            assertTrue(response.getHeaders("Vary").contains("X-Material-Analysis-Projection"));
            assertEquals(wireTree(view), expand(json.readTree(response.getContentAsByteArray())));
        }
        var legacy = mvc.perform(get("/api/production/material-analyses/" + analysisId)
                        .queryParam("projection", "unknown-future-version")
                        .header("X-Material-Analysis-Projection", MaterialAnalysisResponseProjection.VERSION_V2))
                .andExpect(status().isOk()).andReturn().getResponse();
        assertEquals(wireTree(view), json.readTree(legacy.getContentAsByteArray()));
        var generated = new GenerateResult(view, true, List.of());
        var sparseGenerated = new MaterialAnalysisSparseProjection.SparseGenerateResult(
                MaterialAnalysisSparseProjection.project(view), generated.replayed(), generated.plans());
        var wire = wireTree(sparseGenerated);
        assertEquals(wireTree(view), expand(wire.path("analysis")));
        assertTrue(wire.path("replayed").asBoolean());
    }

    @Test
    void sparseProjectionDoesNotReplaceEqualDecimalsWithADifferentScale() throws Exception {
        MaterialView original = material("decimal-scale", stock("0"));
        ObjectNode input = (ObjectNode) wireTree(original);
        input.remove("nodeRole");
        MaterialView morePrecise = json.readValue(json.writeValueAsString(input)
                .replace("\"requiredQty\":10.0001", "\"requiredQty\":10.000100"), MaterialView.class);
        assertEquals(4, original.requiredQty().scale());
        assertEquals(6, morePrecise.requiredQty().scale());
        byte[] compact = json.writeValueAsBytes(MaterialAnalysisSparseProjection.project(view(List.of(original, morePrecise))));
        assertTrue(json.readTree(compact).path("flatMaterials").get(1).has("requiredQty"));
        assertTrue(new String(compact, java.nio.charset.StandardCharsets.UTF_8).contains("\"requiredQty\":10.000100"));
    }

    private MockMvc controller(MaterialAnalysisService service, MaterialAnalysisCommandService commands) {
        return MockMvcBuilders.standaloneSetup(new MaterialAnalysisController(service, commands,
                        mock(MaterialStockReallocationService.class), mock(ProductionGoodsWorkshopPreferenceService.class),
                        mock(MaterialAnalysisSupplyProgressService.class), mock(SubcontractMakeTaskService.class),
                        mock(AnalysisLinkedSalesOrderService.class),
                        mock(AuditDetailViewRecorder.class), null))
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
        JsonNode defaults = result.remove("materialDefaults");
        result.remove("projection");
        for (JsonNode node : result.get("flatMaterials")) {
            if (defaults != null) {
                ObjectNode hydrated = defaults.deepCopy();
                hydrated.setAll((ObjectNode) node);
                ((ObjectNode) node).removeAll();
                ((ObjectNode) node).setAll(hydrated);
            }
            ((ObjectNode) node).set("warehouseBreakdown", stocks.get(node.get("materialKey").asText()));
        }
        return result;
    }
}
