package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonUnwrapped;
import com.fasterxml.jackson.core.JsonGenerator;
import com.fasterxml.jackson.core.io.SerializedString;
import com.fasterxml.jackson.databind.JsonSerializer;
import com.fasterxml.jackson.databind.SerializerProvider;
import com.fasterxml.jackson.databind.annotation.JsonSerialize;

import java.io.IOException;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;

/** Exact, explicitly negotiated wire compression; it never changes the domain snapshot. */
public final class MaterialAnalysisSparseProjection {
    public static final String VERSION = "shared-material-defaults-v2";
    private static final List<Field> FIELDS = materialFields();

    private MaterialAnalysisSparseProjection() {}

    public static SparseAnalysis project(AnalysisView source) {
        MaterialDefaults defaults = new MaterialDefaults(source.flatMaterials().isEmpty()
                ? null : source.flatMaterials().getFirst());
        return new SparseAnalysis(source, defaults, new SparseMaterials(source.flatMaterials(), defaults),
                MaterialAnalysisResponseProjection.sharedWarehouses(source), VERSION);
    }

    public record SparseAnalysis(
            @JsonUnwrapped @JsonIgnoreProperties("flatMaterials") AnalysisView source,
            MaterialDefaults materialDefaults,
            SparseMaterials flatMaterials,
            Map<String, List<WarehouseBreakdown>> warehouseBreakdownsByMaterialKey,
            String projection) {}

    public record SparseGenerateResult(SparseAnalysis analysis, boolean replayed, List<GeneratedPlan> plans) {}

    /** One scalar/reference array per response, not one map or JSON tree per material. */
    @JsonSerialize(using = DefaultsSerializer.class)
    public static final class MaterialDefaults {
        private final Object[] values;

        private MaterialDefaults(MaterialView prototype) {
            values = prototype == null ? new Object[0] : new Object[FIELDS.size()];
            for (int i = 0; i < values.length; i++) values[i] = FIELDS.get(i).read(prototype);
        }
    }

    /** Reuses the authorized immutable source list; serialization streams each sparse row. */
    @JsonSerialize(using = MaterialsSerializer.class)
    public record SparseMaterials(List<MaterialView> source, MaterialDefaults defaults) {}

    public static final class DefaultsSerializer extends JsonSerializer<MaterialDefaults> {
        @Override public void serialize(MaterialDefaults defaults, JsonGenerator generator, SerializerProvider provider)
                throws IOException {
            generator.writeStartObject();
            for (int i = 0; i < defaults.values.length; i++) {
                generator.writeFieldName(FIELDS.get(i).encodedName());
                provider.defaultSerializeValue(defaults.values[i], generator);
            }
            generator.writeEndObject();
        }
    }

    public static final class MaterialsSerializer extends JsonSerializer<SparseMaterials> {
        @Override public void serialize(SparseMaterials materials, JsonGenerator generator, SerializerProvider provider)
                throws IOException {
            generator.writeStartArray();
            for (MaterialView material : materials.source()) {
                generator.writeStartObject();
                for (int i = 0; i < FIELDS.size(); i++) {
                    Field field = FIELDS.get(i);
                    Object value = field.read(material);
                    // BigDecimal.equals also compares scale. A sparse value is omitted
                    // only when expansion can restore exactly the original typed value.
                    if (!Objects.equals(value, materials.defaults().values[i])) {
                        generator.writeFieldName(field.encodedName());
                        provider.defaultSerializeValue(value, generator);
                    }
                }
                generator.writeEndObject();
            }
            generator.writeEndArray();
        }
    }

    private record Field(String name, SerializedString encodedName, MethodHandle accessor) {
        Field(String name, MethodHandle accessor) { this(name, new SerializedString(name), accessor); }
        Object read(MaterialView material) {
            try { return accessor.invokeExact(material); }
            catch (RuntimeException | Error failure) { throw failure; }
            catch (Throwable failure) { throw new IllegalStateException("Cannot read material projection field " + name, failure); }
        }
    }

    private static List<Field> materialFields() {
        try {
            List<Field> result = new ArrayList<>();
            var lookup = MethodHandles.publicLookup();
            var type = MethodType.methodType(Object.class, MaterialView.class);
            for (var component : MaterialView.class.getRecordComponents()) {
                if (!component.getName().equals("warehouseBreakdown")) {
                    result.add(new Field(component.getName(), lookup.unreflect(component.getAccessor()).asType(type)));
                }
            }
            result.add(new Field("nodeRole", lookup.unreflect(MaterialView.class.getMethod("nodeRole")).asType(type)));
            return List.copyOf(result);
        } catch (ReflectiveOperationException failure) {
            throw new ExceptionInInitializerError(failure);
        }
    }
}
