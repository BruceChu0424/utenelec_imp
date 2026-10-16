package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/** Real HTTP, JPA ranking, native inventory SQL, paging and bounded category location. */
class MasterCategorySearchPostgresTest extends AuthSessionPostgresTestSupport {
    @Test
    void globalFacetsSpanCategoriesWhileExplicitCategoryFacetsRemainScoped() throws Exception {
        String token=adminToken(), marker="FACET-"+UUID.randomUUID();
        UUID owner=jdbc.queryForObject("SELECT id FROM employees WHERE NOT is_deleted ORDER BY id LIMIT 1",UUID.class);
        UUID left=category(null,"左分类"), right=category(null,"右分类");
        goods(left,"L-"+UUID.randomUUID(),marker+"-left",null,null);
        goods(right,"R-"+UUID.randomUUID(),marker+"-right",null,null);
        for (String domain : List.of("goods","mould","client","supplier")) {
            UUID scoped=left;
            if (!domain.equals("goods")) {
                String table=domain.equals("mould")?"moulds":domain.equals("client")?"clients":"suppliers";
                String categories=domain.equals("mould")?"mould_categories":domain.equals("client")?"client_categories":"supplier_categories";
                scoped=UUID.randomUUID(); UUID other=UUID.randomUUID();
                jdbc.update("INSERT INTO "+categories+"(id,code,name) VALUES (?,?,?),(?,?,?)",scoped,"FC-"+scoped,"左分类",other,"FC-"+other,"右分类");
                jdbc.update("INSERT INTO "+table+"(id,code,name,category_id,code_sequence) VALUES (?,?,?,?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM "+table+"))",
                        UUID.randomUUID(),"F-"+UUID.randomUUID(),marker+"-left",scoped);
                jdbc.update("INSERT INTO "+table+"(id,code,name,category_id,code_sequence) VALUES (?,?,?,?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM "+table+"))",
                        UUID.randomUUID(),"F-"+UUID.randomUUID(),marker+"-right",other);
                if (!domain.equals("mould")) jdbc.update("UPDATE "+table+" SET owner_employee_id=? WHERE name=?",owner,marker+"-left");
            }
            String endpoint="/api/master/"+(domain.equals("goods")?domain:domain+"s")+"/facets";
            MvcResult global=mvc.perform(get(endpoint).header("Authorization","Bearer "+token)).andReturn();
            assertEquals(200,global.getResponse().getStatus(),body(global));
            assertTrue(json(global).path("name").toString().contains(marker+"-left"),body(global));
            assertTrue(json(global).path("name").toString().contains(marker+"-right"),body(global));
            if (domain.equals("client") || domain.equals("supplier")) {
                assertTrue(json(global).path("empId").toString().contains(owner.toString()),body(global));
                assertTrue(json(global).path("nullCounts").path("empId").asLong()>=1,body(global));
            }
            MvcResult category=mvc.perform(get(endpoint).param("categoryId",scoped.toString())
                    .header("Authorization","Bearer "+token)).andReturn();
            assertEquals(200,category.getResponse().getStatus(),body(category));
            assertTrue(json(category).path("name").toString().contains(marker+"-left"),body(category));
            assertFalse(json(category).path("name").toString().contains(marker+"-right"),body(category));
            MvcResult missing=mvc.perform(get(endpoint).param("categoryId",UUID.randomUUID().toString())
                    .header("Authorization","Bearer "+token)).andReturn();
            assertEquals(200,missing.getResponse().getStatus(),body(missing));
            assertTrue(json(missing).path("name").isEmpty(),body(missing));
            json(missing).path("nullCounts").elements().forEachRemaining(count->assertEquals(0,count.asLong(),body(missing)));
        }
    }

    @Test
    void categoryBranchGoodsAreNotLostWhenAnUnrelatedHiddenFieldAlsoMatches() throws Exception {
        String token = adminToken(), word = "QS" + UUID.randomUUID().toString().replace("-", "").substring(0, 12);
        UUID root = category(null, "基础"), screws = category(root, word + "螺丝类"), coated = category(screws, "镀锌件"), switches = category(root, "开关");
        UUID branch = goods(coated, "Z-" + UUID.randomUUID(), "钢制件", "M3", null);
        UUID hidden = goods(switches, "A-" + UUID.randomUUID(), "双联开关", "M3", word);
        goods(screws, "Y-" + UUID.randomUUID(), "其他件", "M4", null);
        UUID outside = category(null, word + "螺丝"), outsideGoods = goods(outside, "O-" + UUID.randomUUID(), "范围外", "M3", null);

        JsonNode first = goodsSearch(token, root, word + " M3", 1, 1);
        assertEquals(2, first.path("total").asInt(), first.toString());
        assertEquals(branch.toString(), first.path("items").get(0).path("id").asText());
        JsonNode second = goodsSearch(token, root, word + " M3", 2, 1);
        assertEquals(hidden.toString(), second.path("items").get(0).path("id").asText());
        MvcResult locations = mvc.perform(get("/api/master/goods/search-category-ids")
                .param("keyword", word + " M3").param("categoryRootIds", root.toString()).param("includeRelated", "true")
                .header("Authorization", "Bearer " + token)).andReturn();
        assertEquals(200, locations.getResponse().getStatus(), body(locations));
        List<String> ids = strings(json(locations));
        assertTrue(ids.contains(coated.toString()));
        assertFalse(ids.contains(outside.toString()));
        assertFalse(first.toString().contains(outsideGoods.toString()));

        MvcResult inventory = mvc.perform(get("/api/stock/instant-inventory")
                .param("keyword", word + " M3").param("categoryId", root.toString()).param("size", "1")
                .header("Authorization", "Bearer " + token)).andReturn();
        assertEquals(200, inventory.getResponse().getStatus(), body(inventory));
        // Inventory's supported fields omit master-only paper notes; category linkage still finds the branch.
        assertEquals(1, json(inventory).path("total").asInt(), body(inventory));
        assertEquals(branch.toString(), json(inventory).path("items").get(0).path("goodsId").asText());
    }

    @Test
    void namesPrecedeCodesCategoryMatchesAndHiddenNotesBeforePagination() throws Exception {
        String token = adminToken(), word = "QR" + UUID.randomUUID().toString().replace("-", "").substring(0, 12);
        UUID root = category(null, "检索根"), direct = category(root, word), other = category(root, "其他");
        // Force the exact record into the larger UUID category: UUID-only relocation must fail this case.
        if (direct.toString().compareTo(other.toString()) > 0) {
            UUID swap = direct; direct = other; other = swap;
            jdbc.update("UPDATE material_categories SET name=? WHERE id=?", word, direct);
            jdbc.update("UPDATE material_categories SET name='其他' WHERE id=?", other);
        }
        UUID code = goods(other, word, "完整编号命中", null, null);
        UUID name = goods(other, "A1-" + UUID.randomUUID(), word, null, null);
        UUID branch = goods(direct, "A0-" + UUID.randomUUID(), "分类下实际货品", null, null);
        UUID note = goods(other, "00-" + UUID.randomUUID(), "备注中提及", null, word);
        List<String> ids = new ArrayList<>();
        for (int page = 1; page <= 4; page++) ids.add(goodsSearch(token, root, word, page, 1).path("items").get(0).path("id").asText());
        assertEquals(List.of(name.toString(), code.toString(), branch.toString(), note.toString()), ids);
        List<String> nativeIds = new ArrayList<>();
        for (int page = 1; page <= 3; page++) {
            MvcResult inventory = mvc.perform(get("/api/stock/instant-inventory").param("keyword", word)
                    .param("categoryId", root.toString()).param("page", Integer.toString(page)).param("size", "1")
                    .header("Authorization", "Bearer " + token)).andReturn();
            assertEquals(200, inventory.getResponse().getStatus(), body(inventory));
            nativeIds.add(json(inventory).path("items").get(0).path("goodsId").asText());
        }
        assertEquals(List.of(name.toString(), code.toString(), branch.toString()), nativeIds);
        for (String endpoint : List.of("/api/master/goods/search-category-ids", "/api/stock/instant-inventory/search-category-ids")) {
            MvcResult located = mvc.perform(get(endpoint).param("keyword", word).param("categoryRootIds", root.toString())
                    .header("Authorization", "Bearer " + token)).andReturn();
            assertEquals(200, located.getResponse().getStatus(), body(located));
            assertEquals(List.of(other.toString(), direct.toString()), strings(json(located)), endpoint);
        }
    }

    private JsonNode goodsSearch(String token, UUID root, String query, int page, int size) throws Exception {
        MvcResult result = mvc.perform(get("/api/master/goods").param("keyword", query).param("includeRelated", "true")
                .param("categoryRootIds", root.toString()).param("excludeDisabled", "true").param("excludeStub", "true")
                .param("page", Integer.toString(page)).param("size", Integer.toString(size))
                .header("Authorization", "Bearer " + token)).andReturn();
        assertEquals(200, result.getResponse().getStatus(), body(result));
        return json(result);
    }

    private UUID category(UUID parent, String name) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO material_categories(id,code,name,parent_id) VALUES (?,?,?,?)", id, "SC-" + id, name, parent);
        return id;
    }

    private UUID goods(UUID category, String code, String name, String model, String note) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO goods(id,category_id,code,name,model,paper,status,auto_created,code_sequence) "
                + "VALUES (?,?,?,?,?,?,'使用',false,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))",
                id, category, code, name, model, note);
        return id;
    }

    private static List<String> strings(JsonNode node) {
        List<String> values = new ArrayList<>();
        node.forEach(item -> values.add(item.asText()));
        return values;
    }
}
