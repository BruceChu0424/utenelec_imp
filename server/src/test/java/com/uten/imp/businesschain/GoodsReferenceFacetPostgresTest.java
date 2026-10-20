package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import org.apache.poi.ss.usermodel.WorkbookFactory;
import org.junit.jupiter.api.Test;
import org.springframework.test.context.TestPropertySource;
import java.io.ByteArrayInputStream;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;

/** Real migrated PostgreSQL + security + JPA + HTTP: modern UUID dictionaries need no legacy snapshot. */
@TestPropertySource(properties = "uten.features.goods-owner-scope-enabled=true")
class GoodsReferenceFacetPostgresTest extends AuthSessionPostgresTestSupport {
    @Test void uuidAndExactLegacyReferencesShareCandidatesFiltersNullCountsAndExports() throws Exception {
        String token = adminToken();
        UUID category = UUID.randomUUID(), color = UUID.randomUUID(), unit = UUID.randomUUID();
        UUID oldColor = UUID.randomUUID(), oldUnit = UUID.randomUUID();
        jdbc.update("INSERT INTO material_categories(id,code,name) VALUES(?,?,?)", category, "RF-"+category, "引用候选范围");
        jdbc.update("INSERT INTO colors(id,code,name) VALUES(?,?,?)", color, "RC-"+color, "现代黑色");
        jdbc.update("INSERT INTO colors(id,code,name,legacy_id) VALUES(?,?,?,?)", oldColor, "RC-"+oldColor, "历史白色", 199991101);
        jdbc.update("INSERT INTO units(id,code,name,status) VALUES(?,?,?,'使用')", unit, "RU-"+unit, "现代个");
        jdbc.update("INSERT INTO units(id,code,name,status,legacy_id) VALUES(?,?,?,'使用',?)", oldUnit, "RU-"+oldUnit, "历史件", 199991102);
        UUID modern = goods(category, "现代引用", color, unit, null, null);
        UUID conflict = goods(category, "UUID优先", color, unit, 199991101, 199991102);
        UUID historical = goods(category, "历史精确回落", null, null, 199991101, 199991102);
        UUID unresolved = goods(category, "未知旧引用", null, null, 199991191, 199991192);
        UUID empty = goods(category, "未设置引用", null, null, null, null);
        JsonNode list = request(token, get("/api/master/goods").param("categoryId", category.toString()));
        JsonNode modernRow = findRow(list, modern);
        assertEquals("现代黑色", modernRow.path("colorName").asText());
        assertEquals("现代个", modernRow.path("unitName").asText());
        assertTrue(modernRow.path("colorLegacyId").isNull());
        assertTrue(modernRow.path("unitLegacyId").isNull());
        JsonNode preview = request(token, get("/api/master/goods/facets").param("categoryId", category.toString()));
        assertEquals(3, preview.path("colorRef").size());
        assertEquals(3, preview.path("unitRef").size());
        assertEquals(1, preview.path("nullCounts").path("colorRef").asInt());
        assertEquals(1, preview.path("nullCounts").path("unitRef").asInt());
        for (String field : List.of("colorRef", "unitRef")) {
            UUID id = field.equals("colorRef") ? color : unit;
            UUID legacyId = field.equals("colorRef") ? oldColor : oldUnit;
            JsonNode candidates = request(token, get("/api/master/goods/facet-values")
                    .param("categoryId", category.toString()).param("field", field).param("search", "现代")
                    .param(field, legacyId.toString()));
            assertEquals(1, candidates.path("items").size(), "The menu releases its own selected reference");
            assertEquals(id.toString(), candidates.path("items").get(0).path("value").asText());
            assertEquals(2, candidates.path("items").get(0).path("count").asInt());
            JsonNode selected = request(token, get("/api/master/goods").param("categoryId", category.toString()).param(field, id.toString()));
            assertEquals(Set.of(modern.toString(), conflict.toString()), ids(selected));
            assertEquals(Set.of(historical.toString()), ids(request(token, get("/api/master/goods")
                    .param("categoryId", category.toString()).param(field, legacyId.toString()))));
            assertEquals(Set.of(empty.toString()), ids(request(token, get("/api/master/goods")
                    .param("categoryId", category.toString()).param("nullFields", field))));
            var exported = mvc.perform(json(post("/api/master/goods/export").param("categoryId", category.toString())
                    .param(field, id.toString()), Map.of("password", ""), token)).andReturn();
            assertEquals(200, exported.getResponse().getStatus(), body(exported));
            try (var workbook = WorkbookFactory.create(new ByteArrayInputStream(exported.getResponse().getContentAsByteArray()))) {
                assertEquals(2, workbook.getSheetAt(0).getLastRowNum());
            }
        }
        assertEquals(Set.of(unresolved.toString()), ids(request(token, get("/api/master/goods")
                .param("categoryId", category.toString()).param("unitRef", "legacy:199991192"))));
        assertEquals(Set.of(conflict.toString(), historical.toString()), ids(request(token, get("/api/master/goods")
                .param("categoryId", category.toString()).param("unitLegacyId", "199991102"))), "Old clients retain exact snapshot filtering");
        assertEquals(Set.of(conflict.toString(), historical.toString()), ids(request(token, get("/api/master/goods")
                .param("categoryId", category.toString()).param("unitRef", "199991102"))), "Saved pre-UUID integer selections retain exact snapshot semantics");
        assertEquals(422, mvc.perform(get("/api/master/goods").header("Authorization", "Bearer "+token)
                .param("unitRef", "现代个")).andReturn().getResponse().getStatus(), "Display names cannot establish identity");
        Employee actor = newEmployee(token, "DEPT_ENG");
        UUID other = UUID.fromString(newEmployee(token, "DEPT_ENG").employeeId());
        jdbc.update("UPDATE goods SET owner_employee_id=? WHERE id=?", other, modern);
        JsonNode visible = request(actor.accessToken(), get("/api/master/goods/facet-values").param("categoryId", category.toString())
                .param("field", "unitRef").param("search", "现代"));
        assertEquals(1, visible.path("items").get(0).path("count").asInt(), "Source object authorization applies before aggregation");
    }
    @Test void duplicateNamesNeverMergeDistinctUuidTargetsAndDeletedCanonicalNeverFallsBack() throws Exception {
        String token = adminToken(); UUID category = UUID.randomUUID(), first = UUID.randomUUID(), second = UUID.randomUUID();
        jdbc.update("INSERT INTO material_categories(id,code,name) VALUES(?,?,?)", category, "RF-"+category, "同名引用范围");
        for (UUID id : List.of(first, second)) jdbc.update("INSERT INTO colors(id,code,name) VALUES(?,?,?)", id, "RC-"+id, "同名色");
        UUID a = goods(category, "同名甲", first, null, null, null), b = goods(category, "同名乙", second, null, null, null);
        JsonNode found = request(token, get("/api/master/goods/facet-values").param("categoryId", category.toString()).param("field", "colorRef").param("search", "同名色"));
        assertEquals(Set.of(first.toString(), second.toString()), values(found.path("items")));
        jdbc.update("UPDATE colors SET legacy_id=? WHERE id=?", 199991103, second);
        jdbc.update("UPDATE goods SET color_legacy_id=? WHERE id=?", 199991103, a);
        assertThrows(org.springframework.dao.DataIntegrityViolationException.class,
                () -> jdbc.update("UPDATE colors SET is_deleted=true,deleted_at=NOW() WHERE id=?", first),
                "The production in-use deletion guard remains authoritative");
        // An explicit historical broken reference can predate current write validation. Seed its
        // already-deleted target before the source; never disable or bypass a deletion trigger.
        UUID deleted = UUID.randomUUID();
        jdbc.update("INSERT INTO colors(id,code,name,is_deleted,deleted_at) VALUES(?,?,?,true,NOW())", deleted, "RC-"+deleted, "已删历史色");
        UUID broken = goods(category, "历史已删UUID", deleted, null, 199991103, null);
        assertEquals(Set.of(b.toString()), ids(request(token, get("/api/master/goods").param("categoryId", category.toString()).param("colorRef", second.toString()))));
        assertEquals(Set.of(a.toString()), ids(request(token, get("/api/master/goods").param("categoryId", category.toString()).param("colorRef", first.toString()))));
        assertEquals(Set.of(broken.toString()), ids(request(token, get("/api/master/goods").param("categoryId", category.toString()).param("colorRef", deleted.toString()))));
    }
    private UUID goods(UUID category, String name, UUID color, UUID unit, Integer legacyColor, Integer legacyUnit) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO goods(id,category_id,code,name,color_id,unit_id,color_legacy_id,unit_legacy_id,status,auto_created,code_sequence) VALUES(?,?,?,?,?,?,?,?,'使用',false,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))",
                id, category, "RG-"+id, name, color, unit, legacyColor, legacyUnit); return id;
    }
    private JsonNode request(String token, org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder request) throws Exception {
        var result = mvc.perform(request.header("Authorization", "Bearer "+token)).andReturn();
        assertEquals(200, result.getResponse().getStatus(), body(result)); return json(result);
    }
    private static JsonNode findRow(JsonNode page, UUID id) { for (JsonNode row : page.path("items")) if (id.toString().equals(row.path("id").asText())) return row; throw new AssertionError(id); }
    private static Set<String> ids(JsonNode page) { Set<String> result = new HashSet<>(); page.path("items").forEach(row -> result.add(row.path("id").asText())); return result; }
    private static Set<String> values(JsonNode rows) { Set<String> result = new HashSet<>(); rows.forEach(row -> result.add(row.path("value").asText())); return result; }
}
