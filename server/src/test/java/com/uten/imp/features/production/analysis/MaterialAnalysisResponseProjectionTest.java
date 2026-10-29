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

@SuppressWarnings("removal")
class MaterialAnalysisResponseProjectionTest {
    private final ObjectMapper json = new ObjectMapper().findAndRegisterModules()
            .enable(com.fasterxml.jackson.databind.DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS)
            .disable(com.fasterxml.jackson.databind.SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);
    private final UUID analysisId = UUID.randomUUID();
    private final UUID warehouse = UUID.randomUUID();
    private final String materialKey = UUID.randomUUID() + "|NONE|" + UUID.randomUUID();

    @Test void serverOwnedRecipeKeysSurviveLegacyAndBothCompressedRepresentations() throws Exception {
        var first=material("recipe-a",stock("0"));
        var second=material("recipe-b",stock("0"));
        var view=view(List.of(first,second));
        JsonNode expected=wireTree(view.aggregateRecipeKeysByMaterialLineId());
        assertEquals(2,expected.size());
        assertEquals(expected.get(first.materialLineId().toString()),expected.get(second.materialLineId().toString()));
        for(JsonNode snapshot:List.of(wireTree(view),wireTree(MaterialAnalysisResponseProjection.project(view)),
                wireTree(MaterialAnalysisSparseProjection.project(view)))) {
            assertEquals(expected,snapshot.path("aggregateRecipeKeysByMaterialLineId"));
        }
        ObjectNode replay=(ObjectNode)wireTree(view);
        for(JsonNode row:replay.path("flatMaterials"))((ObjectNode)row).remove("nodeRole");
        replay.set("aggregateRecipeKeysByMaterialLineId",json.valueToTree(Map.of(first.materialLineId(),"untrusted-replay-key")));
        assertEquals(expected,wireTree(json.treeToValue(replay,AnalysisView.class).aggregateRecipeKeysByMaterialLineId()));
    }

    @Test void everyProductKeepsAllPlanReferencesAcrossLegacyAndCompressedResponses() throws Exception {
        var references = List.of(new PlanReference(UUID.randomUUID(), "PP-002", 1),
                new PlanReference(UUID.randomUUID(), "PP-001", 0));
        ProductView root = json.convertValue(Map.of("analysisLineId", UUID.randomUUID(),
                "sourceType", "SALES_ORDER_ITEM", "latestPlanId", references.getFirst().planId(),
                "latestPlanNo", references.getFirst().planNo(), "planReferences", references), ProductView.class);
        ProductView shared = json.convertValue(Map.of("analysisLineId", UUID.randomUUID(),
                "sourceType", "AGGREGATE_MAKE", "planReferences", List.of(references.getFirst())), ProductView.class);
        ProductView unplanned = json.convertValue(Map.of("analysisLineId", UUID.randomUUID(),
                "sourceType", "MAKE_COMPONENT"), ProductView.class);
        assertEquals(List.of(), unplanned.planReferences(), "Older snapshots safely default to an empty list");
        assertNull(new PlanReference(UUID.randomUUID(), "legacy-plan").status(), "Legacy references do not guess a plan's approval state");
        var view = view(List.of(material("plan-references", stock("0"))), List.of(root, shared, unplanned));
        for (JsonNode snapshot : List.of(wireTree(view),
                expand(wireTree(MaterialAnalysisResponseProjection.project(view))),
                expand(wireTree(MaterialAnalysisSparseProjection.project(view))))) {
            assertEquals(wireTree(references), snapshot.path("products").get(0).path("planReferences"));
            assertEquals(references.getFirst().planId().toString(), snapshot.path("products").get(0).path("latestPlanId").asText());
            assertEquals(wireTree(List.of(references.getFirst())), snapshot.path("products").get(1).path("planReferences"));
            assertTrue(snapshot.path("products").get(2).path("planReferences").isEmpty());
        }
    }

    @Test void exactDefaultQuantityFactsSurviveLegacyAndBothCompressedRepresentations() throws Exception {
        ObjectNode raw=(ObjectNode)wireTree(material("decimal",stock("0")));
        raw.remove("nodeRole");
        raw.put("additionalSupplyRecommendedQty",new BigDecimal("9999999999999.9999"));
        raw.put("minOrderQty",new BigDecimal("9999999999999.9999"));
        raw.put("orderMultipleQty",new BigDecimal("0.0001"));
        raw.put("mainWarehouseSafetyReplenishmentGapQty",new BigDecimal("9999999999999.9999"));
        MaterialView material=json.treeToValue(raw,MaterialView.class);
        var view=view(List.of(material));
        for(JsonNode snapshot:List.of(wireTree(view),expand(wireTree(MaterialAnalysisResponseProjection.project(view))),
                expand(wireTree(MaterialAnalysisSparseProjection.project(view))))) {
            JsonNode row=snapshot.path("flatMaterials").get(0);
            assertEquals("9999999999999.9999",row.path("quantityFactsExact").path("additionalSupplyRecommendedQty").asText());
            assertEquals("9999999999999.9999",row.path("quantityFactsExact").path("minOrderQty").asText());
            assertEquals("0.0001",row.path("quantityFactsExact").path("orderMultipleQty").asText());
            assertEquals("9999999999999.9999",row.path("quantityFactsExact").path("mainWarehouseSafetyReplenishmentGapQty").asText());
            assertTrue(row.path("additionalSupplyRecommendedQty").isNumber(),"Old clients keep their number field");
        }
        var preparation=new AggregatePreparationView(BigDecimal.ONE,BigDecimal.ZERO,BigDecimal.ZERO,BigDecimal.ZERO,true,
                new BigDecimal("9999999999999.9999"),BigDecimal.ZERO,List.of(),true);
        assertEquals("9999999999999.9999",wireTree(preparation).path("planningUncoveredQtyExact").asText());
    }

    @Test void exactDownstreamSharesSurviveEveryWireProjectionAtMaximumAndMinimumQuantity() throws Exception {
        ObjectNode raw=(ObjectNode)wireTree(material("downstream-decimal",stock("0")));
        raw.remove("nodeRole");
        raw.set("downstreamReferences",json.valueToTree(List.of(
                new DownstreamReference(UUID.randomUUID(),"BUY","OPEN","PURCHASE_REQUEST",UUID.randomUUID(),"REQ-1",
                        new BigDecimal("9999999999999.9999"),new BigDecimal("9999999999999.9999")),
                new DownstreamReference(UUID.randomUUID(),"MAKE","CREATED","PRODUCTION_PLAN",UUID.randomUUID(),"PLAN-1",
                        new BigDecimal("0.0001")))));
        var view=view(List.of(json.treeToValue(raw,MaterialView.class)));
        for(JsonNode snapshot:List.of(wireTree(view),expand(wireTree(MaterialAnalysisResponseProjection.project(view))),
                expand(wireTree(MaterialAnalysisSparseProjection.project(view))))) {
            JsonNode refs=snapshot.path("flatMaterials").get(0).path("downstreamReferences");
            assertEquals("9999999999999.9999",refs.get(0).path("quantityFactsExact").path("allocatedQty").asText());
            assertEquals("9999999999999.9999",refs.get(0).path("quantityFactsExact").path("growableLineQty").asText());
            assertEquals("0.0001",refs.get(1).path("quantityFactsExact").path("allocatedQty").asText());
            assertFalse(refs.get(1).path("quantityFactsExact").has("growableLineQty"));
            assertTrue(refs.get(0).path("allocatedQty").isNumber());
        }
    }

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
        unusual.put("sourceRequiredQty", new BigDecimal("1000.0000"));
        unusual.put("routeConfirmed", true);
        unusual.set("notifiedTargets", json.valueToTree(List.of("BUY")));
        MaterialView prototype = json.treeToValue(unusual, MaterialView.class);
        ObjectNode other = unusual.deepCopy();
        other.put("materialLineId", UUID.randomUUID().toString());
        other.putNull("spec");
        other.put("requiredQty", new BigDecimal("0.0000"));
        other.put("sourceRequiredQty", BigDecimal.ZERO);
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

    @Test
    void aggregatePreviewAndSubmitNegotiateTheSameExactProjectionAndMeasureBothWireResponses() throws Exception {
        AnalysisView view = view(java.util.stream.IntStream.range(0, 1000)
                .mapToObj(index -> material("aggregate-" + index, stock("0.0000"))).toList());
        var source = new AggregateMaterialOrderContracts.SourcePreview(view.flatMaterials().getFirst().materialLineId(),
                analysisId, "original source", 1, null, new BigDecimal("10.0001"), new BigDecimal("10.0001"),
                new BigDecimal("10.0001"), BigDecimal.ZERO);
        var group = json.convertValue(Map.of("clientGroupKey", "original-group", "route", "BUY",
                "publicExtraQty", new BigDecimal("0.0000"), "sources", List.of(source),
                "sharedBomChildren", List.of()), AggregateMaterialOrderContracts.GroupPreview.class);
        var preview = new AggregateMaterialOrderContracts.Preview(analysisId, view.version(), view.fingerprint(),
                "b".repeat(64), List.of(group), view);
        var submitted = new AggregateMaterialOrderContracts.SubmitResult(view, true,
                List.of(new AggregateMaterialOrderContracts.BatchResult(UUID.randomUUID(), "original-group", "BUY",
                        "PURCHASE_REQUEST", UUID.randomUUID(), "PR-001", null, analysisId,
                        new BigDecimal("10.0001"), BigDecimal.ZERO, List.of(source))),
                List.of(new AggregateMaterialOrderContracts.MaterialIdentityBridge(List.of(source.materialLineId()),
                        UUID.randomUUID(), "original/path", new BigDecimal("10.0001"))));
        var previews = mock(AggregateMaterialOrderPreviewService.class);
        var writer = mock(AggregateMaterialOrderContracts.Writer.class);
        when(previews.preview(eq(analysisId), any())).thenReturn(preview);
        when(writer.submit(eq(analysisId), any())).thenReturn(submitted);
        MockMvc mvc = MockMvcBuilders.standaloneSetup(new AggregateMaterialOrderController(previews, writer))
                .setControllerAdvice(new MaterialAnalysisResponseProjection())
                .setMessageConverters(new MappingJackson2HttpMessageConverter(json)).build();
        ObjectNode request = json.createObjectNode();
        request.put("version", view.version()).put("fingerprint", view.fingerprint())
                .put("idempotencyKey", "original-command").put("warehouseId", warehouse.toString())
                .put("billDate", "2026-10-13").put("approveNow", true);
        request.set("groups", json.valueToTree(List.of(Map.of("clientGroupKey", "original-group", "route", "BUY",
                "qty", "10.0001", "materialLineIds", List.of(source.materialLineId())))));
        for (String action : List.of("preview", "submit")) {
            Object original = action.equals("preview") ? preview : submitted;
            JsonNode originalTree = wireTree(original);
            if (action.equals("submit")) request.put("previewFingerprint", preview.previewFingerprint());
            byte[] legacy = json.writeValueAsBytes(original);
            for (String version : List.of("legacy", MaterialAnalysisResponseProjection.VERSION,
                    MaterialAnalysisResponseProjection.VERSION_V2, "unknown-future-version")) {
                var http = post("/api/production/material-analyses/" + analysisId + "/aggregate-orders/" + action)
                        .contentType("application/json").content(json.writeValueAsBytes(request));
                if (!version.equals("legacy")) http.queryParam("projection", version);
                if (version.equals("unknown-future-version")) {
                    http.header("X-Material-Analysis-Projection", MaterialAnalysisResponseProjection.VERSION_V2);
                }
                var response = mvc.perform(http).andExpect(status().isOk()).andReturn().getResponse();
                byte[] body = response.getContentAsByteArray();
                ObjectNode restored = (ObjectNode) json.readTree(body);
                boolean compressed = version.equals(MaterialAnalysisResponseProjection.VERSION)
                        || version.equals(MaterialAnalysisResponseProjection.VERSION_V2);
                if (compressed) restored.set("analysis", expand(restored.get("analysis")));
                assertEquals(originalTree, restored, action + " retains every receipt, allocation, fingerprint and bridge");
                assertTrue(response.getHeaders("Vary").contains("X-Material-Analysis-Projection"));
                if (version.equals(MaterialAnalysisResponseProjection.VERSION_V2)) {
                    assertTrue(body.length < legacy.length / 3, action + " must not resend every repeated material field");
                    System.out.println("AGGREGATE-WIRE " + json.writeValueAsString(Map.of("action", action,
                            "materials", 1000, "legacyJsonBytes", legacy.length, "projectedJsonBytes", body.length,
                            "legacyGzipBytes", gzipSize(legacy), "projectedGzipBytes", gzipSize(body))));
                }
            }
            var headerResponse = mvc.perform(post("/api/production/material-analyses/" + analysisId + "/aggregate-orders/" + action)
                            .header("X-Material-Analysis-Projection", MaterialAnalysisResponseProjection.VERSION_V2)
                            .contentType("application/json").content(json.writeValueAsBytes(request)))
                    .andExpect(status().isOk()).andReturn().getResponse();
            assertEquals(MaterialAnalysisResponseProjection.VERSION_V2,
                    json.readTree(headerResponse.getContentAsByteArray()).path("analysis").path("projection").asText());
            assertEquals(originalTree, wireTree(original), "Negotiated projection must never mutate an idempotent domain receipt");
        }
    }

    private static int gzipSize(byte[] value) throws java.io.IOException {
        var bytes = new java.io.ByteArrayOutputStream();
        try (var compressed = new java.util.zip.GZIPOutputStream(bytes)) { compressed.write(value); }
        return bytes.size();
    }

    private MockMvc controller(MaterialAnalysisService service, MaterialAnalysisCommandService commands) {
        return MockMvcBuilders.standaloneSetup(new MaterialAnalysisController(service, commands,
                        mock(MaterialStockReallocationService.class), mock(ProductionGoodsWorkshopPreferenceService.class),
                        mock(MaterialAnalysisSupplyProgressService.class),
                        mock(AnalysisLinkedSalesOrderService.class),
                        mock(AuditDetailViewRecorder.class), null, mock(MaterialAnalysisPlanWithdrawalService.class)))
                .setControllerAdvice(new MaterialAnalysisResponseProjection())
                .setMessageConverters(new MappingJackson2HttpMessageConverter(json)).build();
    }

    private AnalysisView view(List<MaterialView> materials) {
        return view(materials, List.of());
    }

    private AnalysisView view(List<MaterialView> materials, List<ProductView> products) {
        return new AnalysisView(analysisId, "ACTIVE", 3, "a".repeat(64), "a".repeat(64), warehouse,
                List.of(warehouse), OffsetDateTime.parse("2026-09-12T00:00:00Z"), products, materials, List.of(), List.of(),
                List.of("VIEW"), false, null, Map.of(), 2);
    }

    private MaterialView material(String suffix, List<WarehouseBreakdown> stocks) {
        return json.convertValue(Map.of("materialLineId", UUID.nameUUIDFromBytes(suffix.getBytes(java.nio.charset.StandardCharsets.UTF_8)),
                "analysisLineId", analysisId, "nodeKey", "root/" + suffix, "materialKey", materialKey,
                "requiredQty", new BigDecimal("10.0001"), "shortageQty", new BigDecimal("8.0000"),
                "sourceRequiredQty", new BigDecimal("5.0000"),
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
