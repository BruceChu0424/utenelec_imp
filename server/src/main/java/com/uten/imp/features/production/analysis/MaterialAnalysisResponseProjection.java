package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonUnwrapped;
import org.springframework.core.MethodParameter;
import org.springframework.http.MediaType;
import org.springframework.http.converter.HttpMessageConverter;
import org.springframework.http.converter.json.MappingJackson2HttpMessageConverter;
import org.springframework.http.server.ServerHttpRequest;
import org.springframework.http.server.ServerHttpResponse;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.servlet.mvc.method.annotation.ResponseBodyAdvice;
import org.springframework.web.util.UriComponentsBuilder;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;

/**
 * Optional wire representation of the same authorized analysis snapshot.
 * Warehouses are dimension facts, so repeated BOM paths share one list instead
 * of serializing (and decoding) all warehouses for every node. Domain services,
 * command fingerprints, idempotent results and old clients retain their DTOs.
 */
@RestControllerAdvice(assignableTypes = MaterialAnalysisController.class)
public class MaterialAnalysisResponseProjection implements ResponseBodyAdvice<Object> {
    public static final String VERSION = "shared-warehouses-v1";
    public static final String VERSION_V2 = MaterialAnalysisSparseProjection.VERSION;

    @Override
    public boolean supports(MethodParameter method, Class<? extends HttpMessageConverter<?>> converter) {
        return MappingJackson2HttpMessageConverter.class.isAssignableFrom(converter)
                && (method.getParameterType() == AnalysisView.class || method.getParameterType() == GenerateResult.class);
    }

    @Override
    public Object beforeBodyWrite(Object body, MethodParameter method, MediaType contentType,
            Class<? extends HttpMessageConverter<?>> converter, ServerHttpRequest request, ServerHttpResponse response) {
        response.getHeaders().add("Vary", "X-Material-Analysis-Projection");
        String projection = UriComponentsBuilder.fromUri(request.getURI()).build().getQueryParams().getFirst("projection");
        if (projection == null) projection = request.getHeaders().getFirst("X-Material-Analysis-Projection");
        if (VERSION_V2.equals(projection)) {
            if (body instanceof AnalysisView analysis) return MaterialAnalysisSparseProjection.project(analysis);
            if (body instanceof GenerateResult generated) {
                return new MaterialAnalysisSparseProjection.SparseGenerateResult(
                        MaterialAnalysisSparseProjection.project(generated.analysis()), generated.replayed(), generated.plans());
            }
        }
        if (!VERSION.equals(projection)) return body;
        if (body instanceof AnalysisView analysis) return project(analysis);
        if (body instanceof GenerateResult generated) {
            return new SharedGenerateResult(project(generated.analysis()), generated.replayed(), generated.plans());
        }
        return body;
    }

    public static SharedAnalysis project(AnalysisView analysis) {
        List<SharedMaterial> materials = analysis.flatMaterials().stream().map(SharedMaterial::new).toList();
        return new SharedAnalysis(analysis, materials, sharedWarehouses(analysis), VERSION);
    }

    static Map<String, List<WarehouseBreakdown>> sharedWarehouses(AnalysisView analysis) {
        Map<String, List<WarehouseBreakdown>> shared = new LinkedHashMap<>();
        for (MaterialView material : analysis.flatMaterials()) {
            String key = material.materialKey();
            if (key == null || key.isBlank()) throw new IllegalStateException("Material stock projection requires its stable dimension key");
            List<WarehouseBreakdown> stock = Objects.requireNonNull(material.warehouseBreakdown(), "Warehouse snapshot");
            List<WarehouseBreakdown> existing = shared.putIfAbsent(key, stock);
            if (existing != null && !existing.equals(stock)) {
                // Never coalesce mismatching facts into a apparently valid stock
                // total. This must be corrected at the authoritative projection.
                throw new IllegalStateException("One material dimension has conflicting warehouse snapshots");
            }
        }
        return Collections.unmodifiableMap(shared);
    }

    public record SharedAnalysis(
            @JsonUnwrapped @JsonIgnoreProperties("flatMaterials") AnalysisView source,
            List<SharedMaterial> flatMaterials,
            Map<String, List<WarehouseBreakdown>> warehouseBreakdownsByMaterialKey,
            String projection) {}

    public record SharedMaterial(
            @JsonUnwrapped @JsonIgnoreProperties("warehouseBreakdown") MaterialView source) {}

    public record SharedGenerateResult(SharedAnalysis analysis, boolean replayed, List<GeneratedPlan> plans) {}
}
