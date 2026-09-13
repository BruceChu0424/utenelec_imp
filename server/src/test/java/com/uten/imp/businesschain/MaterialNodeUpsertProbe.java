package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.math.BigDecimal;
import java.util.function.Function;

import static org.junit.jupiter.api.Assertions.*;

/** Executes the actual node SQL and an unfiltered conflict-path control against real fixture rows. */
final class MaterialNodeUpsertProbe {
    private MaterialNodeUpsertProbe() {}

    static JsonNode explain(EntityManager em,ObjectMapper json,UUID analysis,UUID actor,
                            List<Map<String,Object>> rows,boolean filtered) {
        String sql=filtered?ReflectionTestUtils.invokeMethod(MaterialAnalysisService.class,"nodeUpsertSql")
                :unfilteredControl();
        assertNotNull(sql);
        Query query=em.createNativeQuery("EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,FORMAT JSON) "+sql)
                .setParameter("snapshots",snapshots(analysis,actor,rows));
        try {
            JsonNode plan=json.readTree(query.getSingleResult().toString()).get(0);
            assertEquals("ModifyTable",plan.path("Plan").path("Node Type").asText());
            assertTrue(plan.path("Plan").has("Conflicting Tuples"),"Explain must expose the actual conflict counters");
            return plan;
        } catch(java.io.IOException failure) { throw new IllegalStateException(failure); }
    }

    /** Same typed proposed rows and final conflict guard, deliberately without the SELECT prefilter. */
    private static String unfilteredControl() {
        String sql=ReflectionTestUtils.invokeMethod(MaterialAnalysisService.class,"nodeUpsertSql");
        assertNotNull(sql);
        int start=sql.indexOf(" WHERE NOT EXISTS (");
        int end=sql.indexOf("\nORDER BY incoming._position",start);
        assertTrue(start>0&&end>start,"The control removes only the admission prefilter, not the final conflict guard");
        return sql.substring(0,start)+sql.substring(end);
    }

    @SuppressWarnings("unchecked")
    static String snapshots(UUID analysis,UUID actor,List<Map<String,Object>> rows) {
        var columns=(List<String>)ReflectionTestUtils.getField(MaterialAnalysisService.class,"NODE_INPUT_COLUMNS");
        Object shape=ReflectionTestUtils.getField(MaterialAnalysisService.class,"NODE_INPUT");
        assertNotNull(columns);assertNotNull(shape);assertEquals(36,columns.size());
        Function<Map<String,Object>,Object[]> values=row->{
            Object[] result=new Object[columns.size()];
            for(int index=0;index<columns.size();index++) {
                String column=columns.get(index);
                result[index]=switch(column) {
                    case "id" -> row.get("id");
                    case "analysis_id" -> analysis;
                    case "created_by","updated_by" -> actor;
                    case "allocated_available_qty","allocated_start_qty","allocated_finish_qty","allocated_ship_qty" -> BigDecimal.ZERO;
                    case "calculation_mode" -> "EDGE_RULE";
                    case "active" -> true;
                    default -> row.get(column);
                };
            }
            return result;
        };
        return ReflectionTestUtils.invokeMethod(shape,"json",rows,values);
    }

    static void assertUpdateGuardRan(JsonNode plan) {
        assertTrue(plan.path("Triggers").findValuesAsText("Trigger Name").contains("trg_guard_pma_material_exact_peg_identity"),
                "A genuine changed/activated row must still enter the real existing identity guard");
    }
}
