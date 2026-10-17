package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.common.util.CategoryKeywordSearch;
import com.uten.imp.common.util.GoodsSearchPolicy;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;
import com.uten.imp.security.AuthUser;
import org.apache.poi.ss.usermodel.WorkbookFactory;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;

import java.io.ByteArrayInputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/** Full migrated PostgreSQL, real HTTP/security/JPA/native/exports; no handwritten schema fixture. */
@TestPropertySource(properties = "uten.features.goods-owner-scope-enabled=true")
class GoodsSearchPolicyPostgresTest extends AuthSessionPostgresTestSupport {
    @Autowired GoodsService service;

    @Test void facetCandidateSearchFindsValuesBeyondPreviewAndPagesWholeAuthorizedScope() throws Exception {
        String token = adminToken();
        UUID root = category(null, "表头全量候选"), outside = category(null, "候选范围之外");
        for (int index = 0; index < 60; index++) {
            for (int copy = 0; copy < 2; copy++) {
                goods(root, "FACET-" + UUID.randomUUID(), "高频货品" + index, "80-B", null);
            }
        }
        UUID first = goods(root, "Z-" + UUID.randomUUID(), "V4一开", "80-B", null);
        UUID second = goods(root, "Z-" + UUID.randomUUID(), "v4二开", "80-B", null);
        UUID literal = goods(root, "Z-" + UUID.randomUUID(), "V4%_开关", "80-B", null);
        goods(root, "Z-" + UUID.randomUUID(), "V4其他型号", "90-B", null);
        goods(outside, "Z-" + UUID.randomUUID(), "V4范围外", "80-B", null);
        JsonNode preview = request(token, get("/api/master/goods/facets")
                .param("categoryId", root.toString()).param("model", "80-B"));
        assertEquals(50, preview.path("name").size());
        assertFalse(facetValues(preview, "name").contains("V4一开"), "The old 50-bucket preview cannot find this real value");
        assertFalse(facetValues(preview, "name").contains("V4%_开关"));
        Set<String> found = new java.util.HashSet<>();
        for (int page = 1; page <= 3; page++) {
            JsonNode candidates = request(token, get("/api/master/goods/facet-values")
                    .param("categoryId", root.toString()).param("field", "name").param("search", "v4")
                    .param("model", "80-B").param("name", "V4一开")
                    .param("page", Integer.toString(page)).param("size", "1"));
            assertEquals(1, candidates.path("items").size());
            found.add(candidates.path("items").get(0).path("value").asText());
            assertEquals(page < 3, candidates.path("hasMore").asBoolean());
        }
        assertEquals(Set.of("V4一开", "v4二开", "V4%_开关"), found);
        JsonNode columnFiltered = request(token, get("/api/master/goods/facet-values")
                .param("categoryId", root.toString()).param("field", "name").param("search", "v4")
                .param("search.model", "80-b").param("name", "V4一开"));
        Set<String> columnFilteredNames = new java.util.HashSet<>();
        columnFiltered.path("items").forEach(row -> columnFilteredNames.add(row.path("value").asText()));
        assertEquals(Set.of("V4一开", "v4二开", "V4%_开关"), columnFilteredNames,
                "Full candidates must retain other column keywords and category scope while releasing their own exact value");
        assertFalse(columnFiltered.path("hasMore").asBoolean());
        JsonNode escaped = request(token, get("/api/master/goods/facet-values")
                .param("categoryId", root.toString()).param("field", "name").param("search", "%_"));
        assertEquals(1, escaped.path("items").size());
        assertEquals("V4%_开关", escaped.path("items").get(0).path("value").asText());
        JsonNode exact = request(token, get("/api/master/goods").param("categoryId", root.toString())
                .param("name", "V4一开").param("size", "1"));
        assertEquals(List.of(first.toString()), ids(exact));
        assertEquals(1, exact.path("total").asInt(), "Choosing a candidate must keep exact filtering");

        UUID nextSwitch = goods(root, "KW-" + UUID.randomUUID(), "远端候选开关", "80-B", null);
        UUID wrongSeries = goods(root, "KW-" + UUID.randomUUID(), "异系列开关", "80-B", null);
        UUID wrongName = goods(root, "KW-" + UUID.randomUUID(), "5M插座", "80-B", null);
        jdbc.update("UPDATE goods SET series='5M' WHERE id IN (?,?,?)", literal, nextSwitch, wrongName);
        jdbc.update("UPDATE goods SET series='7M' WHERE id=?", wrongSeries);
        Set<String> keywordCandidates = new java.util.HashSet<>();
        for (int page = 1; page <= 2; page++) {
            JsonNode candidates = request(token, get("/api/master/goods/facet-values")
                    .param("categoryId", root.toString()).param("field", "name")
                    .param("name", "V4%_开关").param("search.name", "开关").param("search.series", "5M")
                    .param("page", Integer.toString(page)).param("size", "1"));
            assertEquals(1, candidates.path("items").size());
            keywordCandidates.add(candidates.path("items").get(0).path("value").asText());
            assertEquals(page == 1, candidates.path("hasMore").asBoolean());
        }
        assertEquals(Set.of("V4%_开关", "远端候选开关"), keywordCandidates,
                "Candidates beyond the preview must intersect name and series keywords without retaining their own exact value");

        jdbc.update("UPDATE goods SET color_legacy_id=? WHERE id=?", 2147000991, first);
        jdbc.update("UPDATE goods SET unit_legacy_id=? WHERE id=?", 2147000992, second);
        jdbc.update("UPDATE goods SET color_legacy_id=0,unit_legacy_id=0 WHERE id=?", literal);
        for (String field : List.of("colorLegacyId", "unitLegacyId")) {
            String raw = field.equals("colorLegacyId") ? "2147000991" : "2147000992";
            JsonNode unresolved = request(token, get("/api/master/goods/facet-values")
                    .param("categoryId", root.toString()).param("field", field).param("search", "#" + raw));
            assertEquals(1, unresolved.path("items").size());
            assertEquals(raw, unresolved.path("items").get(0).path("value").asText());
            assertEquals("#" + raw, unresolved.path("items").get(0).path("label").asText());
            JsonNode emptyLegacy = request(token, get("/api/master/goods/facet-values")
                    .param("categoryId", root.toString()).param("field", field).param("search", "(空)"));
            assertEquals(1, emptyLegacy.path("items").size());
            assertEquals("0", emptyLegacy.path("items").get(0).path("value").asText());
            assertEquals("(空)", emptyLegacy.path("items").get(0).path("label").asText());
        }

        Employee actor = newEmployee(token, "DEPT_ENG");
        UUID other = UUID.fromString(newEmployee(token, "DEPT_ENG").employeeId());
        UUID hidden = goods(root, "Z-" + UUID.randomUUID(), "V4不可见货品", "80-B", null);
        jdbc.update("UPDATE goods SET owner_employee_id=? WHERE id=?", other, hidden);
        JsonNode authorized = request(actor.accessToken(), get("/api/master/goods/facet-values")
                .param("categoryId", root.toString()).param("field", "name").param("search", "v4")
                .param("model", "80-B"));
        assertEquals(3, authorized.path("items").size());
        assertFalse(authorized.toString().contains("不可见"));
        MvcResult unsupported = mvc.perform(get("/api/master/goods/facet-values")
                .header("Authorization", "Bearer " + token).param("field", "price")).andReturn();
        assertEquals(422, unsupported.getResponse().getStatus());
    }

    @Test void categoryIntentPrimaryAndOptionalRelatedHaveOneRankBeforePagingAndExport() throws Exception {
        String token = adminToken();
        UUID root = category(null, "策略范围"), screws = category(root, "螺丝类"), child = category(screws, "镀锌件"), sockets = category(root, "电话插座");
        UUID exactName = goods(sockets, "N-"+UUID.randomUUID(), "螺丝", null, null);
        UUID exactCode = goods(sockets, "螺丝", "完整编号命中", null, null);
        UUID branch = goods(child, "M3-"+UUID.randomUUID(), "M3x20", "M3", null);
        UUID feature = goods(sockets, "F-"+UUID.randomUUID(), "电话插座（螺丝接线式）", null, null);
        UUID note = goods(sockets, "A-"+UUID.randomUUID(), "说明中提及", null, "螺丝");
        UUID disabled = goods(child, "D-"+UUID.randomUUID(), "停用件", null, null);
        jdbc.update("UPDATE goods SET status='禁用' WHERE id=?", disabled);
        UUID stub = goods(child, "S-"+UUID.randomUUID(), "不明件", null, null);
        jdbc.update("UPDATE goods SET auto_created=true WHERE id=?", stub);
        UUID deleted = goods(child, "X-"+UUID.randomUUID(), "已删件", null, null);
        jdbc.update("UPDATE goods SET is_deleted=true,deleted_at=NOW() WHERE id=?", deleted);
        List<String> primary = List.of(exactName.toString(), exactCode.toString(), branch.toString());
        List<String> expanded = List.of(exactName.toString(), exactCode.toString(), branch.toString(), feature.toString(), note.toString());
        assertEquals(primary, ids(search(token, root, null, "螺丝", false, 1, 20)));
        List<String> paged = new ArrayList<>();
        Map<String,Integer> ranks = new LinkedHashMap<>();
        for (int page=1;page<=expanded.size();page++) {
            JsonNode result = search(token, root, null, "螺丝", true, page, 1);
            assertEquals(5,result.path("total").asInt(),result.toString());
            JsonNode row=result.path("items").get(0);
            paged.add(row.path("id").asText());
            ranks.put(row.path("id").asText(),row.path("searchRank").asInt());
            assertEquals(page<=3?"PRIMARY":"RELATED",row.path("searchMatchKind").asText());
        }
        assertEquals(expanded,paged);
        assertNativeParity(root, "螺丝", true, expanded, ranks);
        for (boolean related : List.of(false,true)) {
            MvcResult exported=mvc.perform(json(post("/api/master/goods/export")
                    .param("categoryRootIds",root.toString()).param("keyword","螺丝")
                    .param("includeRelated",Boolean.toString(related)).param("excludeDisabled","true").param("excludeStub","true"),Map.of("password",""),token)).andReturn();
            assertEquals(200,exported.getResponse().getStatus(),body(exported));
            try(var book=WorkbookFactory.create(new ByteArrayInputStream(exported.getResponse().getContentAsByteArray()))) {
                assertEquals(related?5:3,book.getSheetAt(0).getLastRowNum());
            }
        }
        JsonNode ordinary=search(token,root,null,"",false,1,100), expandedEmpty=search(token,root,null," \u3000\t ",true,1,100);
        assertEquals(ids(ordinary),ids(expandedEmpty));
        assertEquals(ordinary.path("total"),expandedEmpty.path("total"));
        ordinary.path("items").forEach(row->{assertFalse(row.has("searchRank"));assertFalse(row.has("searchMatchKind"));});
        Map<String,Integer> zeroRanks=new HashMap<>();ids(ordinary).forEach(id->zeroRanks.put(id,0));
        assertNativeParity(root," \u3000\t ",true,ids(ordinary),zeroRanks);
    }

    @Test void allWordsCanSpanIdentityCategoryAndOptionalNotesWithoutWildcardOrUnicodeLeaks() throws Exception {
        String token=adminToken();
        UUID root=category(null,"混合范围"), screws=category(root,"螺丝类"), sockets=category(root,"插座");
        UUID primary=goods(screws,"P-"+UUID.randomUUID(),"M3x20",null,null);
        UUID insideRelated=goods(screws,"R-"+UUID.randomUUID(),"M4x20",null,"M3");
        UUID mixedRelated=goods(sockets,"M-"+UUID.randomUUID(),"M3电话模块",null,"螺丝");
        goods(sockets,"N-"+UUID.randomUUID(),"不满足所有词",null,"M3");
        UUID connector=goods(sockets,"C-"+UUID.randomUUID(),"电话插座（螺丝接线式）",null,null);
        for(String query:List.of("螺丝\u3000M3","螺丝\u00a0M3","螺丝类 M3","螺丝类别 M3")) {
            assertEquals(List.of(primary.toString()),ids(search(token,root,null,query,false,1,100)),query);
        }
        JsonNode expanded=search(token,root,null,"螺丝\u3000M3",true,1,100);
        assertEquals(3,expanded.path("total").asInt(),expanded.toString());
        assertEquals(primary.toString(),expanded.path("items").get(0).path("id").asText());
        assertEquals(Set.of(primary.toString(),insideRelated.toString(),mixedRelated.toString()),Set.copyOf(ids(expanded)));
        expanded.path("items").forEach(row->assertEquals(row.path("id").asText().equals(primary.toString())?"PRIMARY":"RELATED",row.path("searchMatchKind").asText()));
        Map<String,Integer> ranks=new HashMap<>();expanded.path("items").forEach(row->ranks.put(row.path("id").asText(),row.path("searchRank").asInt()));
        assertNativeParity(root,"螺丝\u3000M3",true,ids(expanded),ranks);
        assertEquals(List.of(connector.toString()),ids(search(token,root,null,"螺丝接线式",false,1,100)));
        UUID literal=goods(sockets,"L-"+UUID.randomUUID(),"字面规格",null,null);
        UUID near=goods(sockets,"L-"+UUID.randomUUID(),"近似规格",null,null);
        jdbc.update("UPDATE goods SET spec=? WHERE id=?","M_100%\\A",literal);
        jdbc.update("UPDATE goods SET spec=? WHERE id=?","MZ100X\\A",near);
        assertEquals(List.of(literal.toString()),ids(search(token,root,null,"M_100%\\A",false,1,100)));
        assertEquals(0,search(token,root,null,"M_100%\\A\u00a0missing",true,1,100).path("total").asInt());
    }

    @Test void explicitCategoryOverridesInferenceAndIntersectsRootsWhileFacetCanSwitchItsOwnFilter() throws Exception {
        String token=adminToken();
        UUID root=category(null,"显式范围"), screws=category(root,"螺丝类"), sockets=category(root,"插座"), outside=category(null,"其他根");
        goods(screws,"P-"+UUID.randomUUID(),"M3x20",null,null);
        UUID feature=goods(sockets,"F-"+UUID.randomUUID(),"电话插座（螺丝接线式）","X",null);
        goods(sockets,"F-"+UUID.randomUUID(),"电脑插座（螺丝接线式）","Y",null);
        goods(sockets,"F-"+UUID.randomUUID(),"电视插座（螺丝接线式）",null,null);
        goods(sockets,"N-"+UUID.randomUUID(),"说明相关插座","Z","螺丝");
        goods(outside,"O-"+UUID.randomUUID(),"螺丝",null,null);
        assertEquals(3,search(token,root,sockets,"螺丝",false,1,100).path("total").asInt());
        assertEquals(0,search(token,root,outside,"螺丝",true,1,100).path("total").asInt());
        JsonNode facets=request(token,get("/api/master/goods/facets").param("keyword","螺丝")
                .param("categoryId",sockets.toString()).param("categoryRootIds",root.toString())
                .param("excludeDisabled","true").param("excludeStub","true").param("model","X"));
        assertEquals(Set.of("X","Y"),facetValues(facets,"model"));
        assertEquals(1,facets.path("nullCounts").path("model").asInt());
        assertEquals(Set.of("电话插座（螺丝接线式）"),facetValues(facets,"name"));
        assertEquals(1,request(token,get("/api/master/goods").param("keyword","螺丝").param("model","X")
                .param("categoryId",sockets.toString()).param("categoryRootIds",root.toString())).path("total").asInt());
        JsonNode relatedFacets=request(token,get("/api/master/goods/facets").param("keyword","螺丝").param("includeRelated","true")
                .param("categoryId",sockets.toString()).param("categoryRootIds",root.toString()));
        assertEquals(Set.of("X","Y","Z"),facetValues(relatedFacets,"model"));
        JsonNode emptyFacets=request(token,get("/api/master/goods/facets").param("keyword","螺丝").param("includeRelated","true")
                .param("categoryId",outside.toString()).param("categoryRootIds",root.toString()));
        assertTrue(emptyFacets.path("name").isEmpty());emptyFacets.path("nullCounts").elements().forEachRemaining(n->assertEquals(0,n.asLong()));
        JsonNode locations=request(token,get("/api/master/goods/search-category-ids").param("keyword","螺丝")
                .param("categoryId",sockets.toString()).param("categoryRootIds",root.toString()));
        assertEquals(List.of(sockets.toString()),strings(locations));
        assertTrue(ids(search(token,root,sockets,"螺丝",false,1,100)).contains(feature.toString()));
        UUID child=category(sockets,"子类"), filteredOut=goods(child,"Y-"+UUID.randomUUID(),"子类插座（螺丝接线式）","Y",null);
        JsonNode filteredLocations=request(token,get("/api/master/goods/search-category-ids").param("keyword","螺丝").param("model","X")
                .param("categoryId",sockets.toString()).param("categoryRootIds",root.toString()));
        assertEquals(List.of(sockets.toString()),strings(filteredLocations));
        assertFalse(filteredLocations.toString().contains(child.toString()));
    }

    @Test void ownerAndCommercialMasksSurviveExpandedResultsFacetsLocationAndExport() throws Exception {
        String admin=adminToken();Employee actor=newEmployee(admin,"DEPT_ENG");
        UUID own=UUID.fromString(actor.employeeId());
        UUID other=UUID.fromString(newEmployee(admin,"DEPT_ENG").employeeId());
        UUID root=category(null,"归属搜索"), visible=category(root,"可见类"), hidden=category(root,"其他归属类");
        String word="OWNER"+UUID.randomUUID().toString().replace("-","");
        UUID owned=goods(visible,"OWN-"+UUID.randomUUID(),word+" A",null,null);
        UUID shared=goods(visible,"PUB-"+UUID.randomUUID(),word+" B",null,null);
        UUID related=goods(visible,"REL-"+UUID.randomUUID(),"说明相关",null,word);
        UUID foreign=goods(hidden,"HID-"+UUID.randomUUID(),word+" C",null,word);
        jdbc.update("UPDATE goods SET owner_employee_id=?,price=42,zk=0.8 WHERE id IN (?,?)",own,owned,related);
        jdbc.update("UPDATE goods SET owner_employee_id=?,price=99 WHERE id=?",other,foreign);
        assertEquals(Set.of(owned.toString(),shared.toString()),Set.copyOf(ids(search(actor.accessToken(),root,null,word,false,1,100))));
        assertEquals(Set.of(owned.toString(),shared.toString(),related.toString()),Set.copyOf(ids(search(actor.accessToken(),root,null,word,true,1,100))));
        JsonNode facets=request(actor.accessToken(),get("/api/master/goods/facets").param("keyword",word).param("includeRelated","true").param("categoryRootIds",root.toString()));
        assertFalse(facets.toString().contains(word+" C"));
        assertEquals(3,facets.path("name").size());
        JsonNode locations=request(actor.accessToken(),get("/api/master/goods/search-category-ids").param("keyword",word).param("includeRelated","true").param("categoryRootIds",root.toString()));
        assertEquals(List.of(visible.toString()),strings(locations));
        AuthUser limited=new AuthUser(UUID.fromString(actor.userId()),own,"fixture-limited",Set.of("goods:view","goods:export"),false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(limited,null,limited.getAuthorities()));
        try {
            var filter=new GoodsQueryFilter(null,Set.of(root),word,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,true,true,null,null,null,null,true);
            var exported=service.export(filter,null,null,100);
            assertEquals(3,exported.total());
            assertTrue(exported.columns().stream().noneMatch(column->Set.of("price","discount").contains(column.key())));
            assertTrue(exported.rows().stream().noneMatch(row->row.containsKey("price")||row.containsKey("discount")));
            assertTrue(service.list(filter,1,100,null,null).getItems().stream().allMatch(row->row.getPrice()==null&&row.getDiscount()==null));
        } finally {SecurityContextHolder.clearContext();}
    }

    @Test void moreThan32BusinessRootsKeepOneComparableRankAndExplicitSelectionIntersections() throws Exception {
        String token=adminToken(),word="BATCH"+UUID.randomUUID().toString().replace("-","");
        List<UUID> roots=new ArrayList<>();UUID exact=null;
        for(int index=0;index<34;index++) {
            UUID root=category(null,"批量范围"+index);roots.add(root);
            UUID id=goods(root,"B-"+UUID.randomUUID(),index==33?word:word+" "+index,null,null);
            if(index==33)exact=id;
        }
        UUID related=goods(roots.get(33),"A-"+UUID.randomUUID(),"说明附带匹配",null,word);
        List<JsonNode> merged=new ArrayList<>();long total=0,selectedTotal=0;
        for(List<UUID> batch:List.of(roots.subList(0,32),roots.subList(32,34))) {
            var query=get("/api/master/goods").param("keyword",word).param("includeRelated","true").param("size","100")
                    .param("categoryRootIds",batch.stream().map(UUID::toString).toArray(String[]::new));
            JsonNode result=request(token,query);total+=result.path("total").asLong();result.path("items").forEach(merged::add);
            JsonNode selected=request(token,get("/api/master/goods").param("keyword",word).param("size","100")
                    .param("categoryId",roots.get(33).toString()).param("categoryRootIds",batch.stream().map(UUID::toString).toArray(String[]::new)));
            selectedTotal+=selected.path("total").asLong();
        }
        merged.sort(java.util.Comparator.comparingInt((JsonNode row)->row.path("searchRank").asInt())
                .thenComparing(row->row.path("code").asText()).thenComparing(row->row.path("id").asText()));
        assertEquals(35,total);assertEquals(35,merged.stream().map(row->row.path("id").asText()).distinct().count());
        assertEquals(exact.toString(),merged.getFirst().path("id").asText());
        assertEquals(related.toString(),merged.getLast().path("id").asText());
        assertEquals("RELATED",merged.getLast().path("searchMatchKind").asText());
        assertEquals(1,selectedTotal,"Business-root batches intersect the explicitly selected category; no root union may widen it");
    }

    @Test void disjointCategorySubjectsAreAmbiguousButNestedSubjectsHaveOneClearPrimaryBranch() throws Exception {
        String token=adminToken();
        UUID root=category(null,"多主体范围"),screws=category(root,"螺丝类"),cross=category(screws,"十字螺丝"),sockets=category(root,"插座");
        UUID feature=goods(sockets,"F-"+UUID.randomUUID(),"电话插座（十字螺丝接线式）",null,null);
        UUID nested=goods(cross,"P-"+UUID.randomUUID(),"M3x20",null,null);
        UUID note=goods(screws,"N-"+UUID.randomUUID(),"M4x20",null,"插座");
        for(String query:List.of("螺丝 插座","螺丝 十字螺丝")) {
            UUID first=query.equals("螺丝 插座")?feature:nested;
            UUID second=query.equals("螺丝 插座")?note:feature;
            assertEquals(List.of(first.toString()),ids(search(token,root,null,query,false,1,100)));
            JsonNode expanded=search(token,root,null,query,true,1,100);
            assertEquals(List.of(first.toString(),second.toString()),ids(expanded));
            assertEquals("PRIMARY",expanded.path("items").get(0).path("searchMatchKind").asText());
            assertEquals("RELATED",expanded.path("items").get(1).path("searchMatchKind").asText());
            Map<String,Integer> ranks=new HashMap<>();expanded.path("items").forEach(row->ranks.put(row.path("id").asText(),row.path("searchRank").asInt()));
            assertNativeParity(root,query,true,ids(expanded),ranks);
        }
    }

    @Test void subjectHeadAndExactSubjectKeepUncategorizedRealPartsAndPreferDoesNotHardNarrowSelectedScope() throws Exception {
        String token=adminToken();
        UUID root=category(null,"主体证明"),screws=category(root,"螺丝类"),sockets=category(root,"插座");
        UUID exact=goods(null,"Z-"+UUID.randomUUID(),"螺丝",null,null);
        jdbc.update("UPDATE goods SET spec='4*50' WHERE id=?",exact);
        UUID suffix=goods(null,"A-"+UUID.randomUUID(),"加长安装螺丝",null,null);
        jdbc.update("UPDATE goods SET spec='4*50' WHERE id=?",suffix);
        UUID embedded=goods(null,"B-"+UUID.randomUUID(),"加长安装螺丝4*50",null,null);
        UUID bracket=goods(null,"C-"+UUID.randomUUID(),"铁螺丝（4*50）",null,null);
        UUID whitespace=goods(null,"D-"+UUID.randomUUID(),"加长\u00a0安装螺丝 4*50",null,null);
        UUID feature=goods(null,"E-"+UUID.randomUUID(),"电话插座（螺丝接线式4*50）",null,null);
        UUID component=goods(null,"F-"+UUID.randomUUID(),"出线片组件(铁螺丝4*50)",null,null);
        UUID falseSize=goods(null,"G-"+UUID.randomUUID(),"螺丝4位接线组件4*50",null,null);
        JsonNode primary=request(token,get("/api/master/goods").param("keyword","螺丝 4*50").param("size","100"));
        assertEquals(Set.of(exact.toString(),suffix.toString(),embedded.toString(),bracket.toString(),whitespace.toString()),Set.copyOf(ids(primary)));
        assertEquals(exact.toString(),primary.path("items").get(0).path("id").asText());
        assertEquals(2,primary.path("items").get(0).path("searchRank").asInt());
        JsonNode expanded=request(token,get("/api/master/goods").param("keyword","螺丝 4*50").param("includeRelated","true").param("size","100"));
        assertEquals(8,expanded.path("total").asInt(),expanded.toString());
        expanded.path("items").forEach(row->assertEquals(Set.of(feature.toString(),component.toString(),falseSize.toString()).contains(row.path("id").asText())?"RELATED":"PRIMARY",row.path("searchMatchKind").asText()));
        Map<String,Integer> ranks=new HashMap<>();expanded.path("items").forEach(row->ranks.put(row.path("id").asText(),row.path("searchRank").asInt()));
        assertNativeParity(null,"螺丝 4*50",true,ids(expanded),ranks);
        UUID scoped=goods(screws,"H-"+UUID.randomUUID(),"M3x20",null,null);
        UUID scopedFeature=goods(sockets,"I-"+UUID.randomUUID(),"电话插座（螺丝接线式）",null,null);
        JsonNode prefer=search(token,root,root,"螺丝",false,1,100);
        assertEquals(List.of(scoped.toString(),scopedFeature.toString()),ids(prefer));
        prefer.path("items").forEach(row->assertEquals("PRIMARY",row.path("searchMatchKind").asText()));
        Map<String,Integer> preferRanks=new HashMap<>();prefer.path("items").forEach(row->preferRanks.put(row.path("id").asText(),row.path("searchRank").asInt()));
        assertNativeParity(root,"螺丝",false,ids(prefer),preferRanks,GoodsSearchPolicy.SubjectMode.PREFER);
        UUID locks=category(null,"lock类"),clocks=category(null,"其他计时器");
        UUID lock=goods(null,"LOCK-"+UUID.randomUUID(),"lock",null,null),clock=goods(clocks,"CLOCK-"+UUID.randomUUID(),"clock",null,null);
        JsonNode english=request(token,get("/api/master/goods").param("keyword","lock").param("size","100"));
        assertEquals(List.of(lock.toString()),ids(english));
        assertFalse(ids(english).contains(clock.toString()));
    }

    @Test void exactModelAndSeriesStayPrimaryAcrossCategoryNamesWithoutPromotingPartialIdentityFeatures() throws Exception {
        String token=adminToken();UUID root=category(null,"系列精确范围"),seriesCategory=category(root,"V9.1"),other=category(root,"其他系列");
        UUID branch=goods(seriesCategory,"C-"+UUID.randomUUID(),"分类实体",null,null);
        UUID model=goods(other,"A-"+UUID.randomUUID(),"型号精确实体","V9.1",null);
        UUID series=goods(other,"B-"+UUID.randomUUID(),"系列精确实体",null,null);
        jdbc.update("UPDATE goods SET series='V9.1' WHERE id=?",series);
        UUID partial=goods(other,"D-"+UUID.randomUUID(),"型号部分提及","X V9.1 feature",null);
        JsonNode primary=search(token,root,null,"V9.1",false,1,100);
        assertEquals(List.of(model.toString(),series.toString(),branch.toString()),ids(primary));
        primary.path("items").forEach(row->assertEquals("PRIMARY",row.path("searchMatchKind").asText()));
        JsonNode expanded=search(token,root,null,"V9.1",true,1,100);
        assertEquals(partial.toString(),expanded.path("items").get(3).path("id").asText());
        assertEquals("RELATED",expanded.path("items").get(3).path("searchMatchKind").asText());
        Map<String,Integer> ranks=new HashMap<>();expanded.path("items").forEach(row->ranks.put(row.path("id").asText(),row.path("searchRank").asInt()));
        assertNativeParity(root,"V9.1",true,ids(expanded),ranks);
    }

    @Test void allSelectableUnscopedSearchIncludesRealUncategorizedGoodsWithoutWideningEligibilityOrOwnerScope() throws Exception {
        String admin=adminToken();Employee actor=newEmployee(admin,"DEPT_ENG");
        UUID owner=UUID.fromString(actor.employeeId()),other=UUID.fromString(newEmployee(admin,"DEPT_ENG").employeeId());
        UUID root=category(null,"全部可选范围"),selected=category(root,"螺丝类"),unit=activeUnit();
        Map<String,JsonNode> before=new HashMap<>();
        for(String query:List.of("螺丝","螺丝 4*50"))for(boolean related:List.of(false,true)) {
            before.put(query+related,search(actor.accessToken(),null,null,query,related,1,100));
        }
        List<UUID> fixture=new ArrayList<>();
        try {
            UUID uncategorized=goods(null,"ALL-A-"+UUID.randomUUID(),"螺丝",null,null);fixture.add(uncategorized);
            UUID categorized=goods(selected,"ALL-B-"+UUID.randomUUID(),"螺丝",null,null);fixture.add(categorized);
            UUID hidden=goods(null,"ALL-C-"+UUID.randomUUID(),"螺丝",null,null);fixture.add(hidden);
            UUID disabled=goods(null,"ALL-D-"+UUID.randomUUID(),"螺丝",null,null);fixture.add(disabled);
            UUID stub=goods(null,"ALL-E-"+UUID.randomUUID(),"螺丝",null,null);fixture.add(stub);
            UUID deleted=goods(null,"ALL-F-"+UUID.randomUUID(),"螺丝",null,null);fixture.add(deleted);
            for(UUID id:fixture)jdbc.update("UPDATE goods SET unit_id=?,spec='4*50',issue_method='ORDER' WHERE id=?",unit,id);
            jdbc.update("UPDATE goods SET owner_employee_id=? WHERE id=?",owner,uncategorized);
            jdbc.update("UPDATE goods SET owner_employee_id=? WHERE id=?",other,hidden);
            jdbc.update("UPDATE goods SET status='禁用' WHERE id=?",disabled);
            jdbc.update("UPDATE goods SET auto_created=true WHERE id=?",stub);
            jdbc.update("UPDATE goods SET is_deleted=true,deleted_at=NOW() WHERE id=?",deleted);
            for(String query:List.of("螺丝","螺丝 4*50"))for(boolean related:List.of(false,true)) {
                JsonNode baseline=before.get(query+related);
                // Matches the explicit all-selectable picker: no category or root parameter,
                // while disabled and migration-placeholder exclusions remain enabled.
                JsonNode result=search(actor.accessToken(),null,null,query,related,1,100);
                Set<String> expected=new java.util.HashSet<>(ids(baseline));
                expected.add(uncategorized.toString());expected.add(categorized.toString());
                assertEquals(expected,Set.copyOf(ids(result)),result.toString());
                assertEquals(baseline.path("total").asLong()+2,result.path("total").asLong());
                JsonNode found=null;
                for(JsonNode row:result.path("items"))if(row.path("id").asText().equals(uncategorized.toString()))found=row;
                assertNotNull(found);
                assertFalse(found.hasNonNull("categoryId"));
                assertEquals(unit.toString(),found.path("unitId").asText());
                assertEquals("个",found.path("unitName").asText());
                assertEquals("使用",found.path("status").asText());
                assertFalse(found.path("autoCreated").asBoolean());
                assertEquals("PRIMARY",found.path("searchMatchKind").asText());
                assertEquals(query.equals("螺丝")?0:2,found.path("searchRank").asInt());
                List<JsonNode> paged=new ArrayList<>();
                for(int page=1;page<=(result.path("total").asInt()+1)/2;page++) {
                    JsonNode part=search(actor.accessToken(),null,null,query,related,page,2);
                    assertEquals(result.path("total"),part.path("total"));
                    part.path("items").forEach(paged::add);
                }
                List<JsonNode> all=new ArrayList<>();result.path("items").forEach(all::add);
                assertEquals(all,paged,"Pagination must preserve the same null-category row, rank and metadata");
                assertEquals(List.of(categorized.toString()),ids(search(actor.accessToken(),root,null,query,related,1,100)));
                assertEquals(List.of(categorized.toString()),ids(search(actor.accessToken(),null,selected,query,related,1,100)));
            }
            JsonNode administrative=search(admin,null,null,"螺丝 4*50",false,1,100);
            assertTrue(ids(administrative).contains(hidden.toString()),"The owner-hidden row is a real primary match for an authorized administrator");
            JsonNode withoutEligibilityFilters=request(admin,get("/api/master/goods").param("keyword","螺丝 4*50")
                    .param("excludeDisabled","false").param("excludeStub","false").param("size","100"));
            assertTrue(ids(withoutEligibilityFilters).containsAll(List.of(disabled.toString(),stub.toString())));
            assertFalse(ids(withoutEligibilityFilters).contains(deleted.toString()));
        } finally {
            for(UUID id:fixture)jdbc.update("UPDATE goods SET is_deleted=true,deleted_at=COALESCE(deleted_at,NOW()) WHERE id=?",id);
        }
    }

    @Test void realUncategorizedComponentKeepsBomQuantityUniquenessSelfAndCycleGuards() throws Exception {
        String token=adminToken();UUID unit=activeUnit();
        UUID parent=goods(null,"BOM-P-"+UUID.randomUUID(),"无分类父件",null,null);
        UUID component=goods(null,"BOM-C-"+UUID.randomUUID(),"无分类真实组件",null,null);
        UUID extra=goods(null,"BOM-Q-"+UUID.randomUUID(),"无分类用量校验组件",null,null);
        for(UUID id:List.of(parent,component,extra))jdbc.update("UPDATE goods SET unit_id=?,issue_method='ORDER' WHERE id=?",unit,id);
        JsonNode created=request(token,json(post("/api/master/goods/{id}/bom",parent),
                Map.of("componentGoodsId",component,"qty",new java.math.BigDecimal("2.5")),token));
        assertEquals(component.toString(),created.path("componentGoodsId").asText());
        assertEquals("个",created.path("componentUnitName").asText());
        assertEquals(0,new java.math.BigDecimal("2.5").compareTo(created.path("qty").decimalValue()));
        assertBomRejected(token,parent,component,java.math.BigDecimal.ONE,409,"CONFLICT");
        assertBomRejected(token,component,parent,java.math.BigDecimal.ONE,409,"CONFLICT");
        assertBomRejected(token,component,component,java.math.BigDecimal.ONE,422,"VALIDATION_FAILED");
        assertBomRejected(token,parent,extra,java.math.BigDecimal.ZERO,422,"VALIDATION_FAILED");
        JsonNode current=request(token,get("/api/master/goods/{id}/bom",parent));
        assertEquals(1,current.size());
        assertEquals(created.path("id"),current.get(0).path("id"));
        assertEquals(created.path("qty"),current.get(0).path("qty"));
        assertEquals(0,request(token,get("/api/master/goods/{id}/bom",component)).size());
    }

    private void assertBomRejected(String token,UUID parent,UUID component,java.math.BigDecimal qty,int status,String code) throws Exception {
        MvcResult result=mvc.perform(json(post("/api/master/goods/{id}/bom",parent),Map.of("componentGoodsId",component,"qty",qty),token)).andReturn();
        assertEquals(status,result.getResponse().getStatus(),body(result));
        assertEquals(code,json(result).path("code").asText());
    }

    private UUID activeUnit() {
        UUID id=UUID.randomUUID();
        jdbc.update("INSERT INTO units(id,code,name,status) VALUES(?,?,'个','使用')",id,"GP-UNIT-"+id);
        return id;
    }

    private void assertNativeParity(UUID root,String keyword,boolean related,List<String> expected,Map<String,Integer> expectedRanks) {
        assertNativeParity(root,keyword,related,expected,expectedRanks,GoodsSearchPolicy.SubjectMode.STRICT);
    }
    private void assertNativeParity(UUID root,String keyword,boolean related,List<String> expected,Map<String,Integer> expectedRanks,GoodsSearchPolicy.SubjectMode mode) {
        List<CategoryKeywordSearch.Node> nodes=jdbc.query("SELECT id,parent_id,name,code FROM material_categories WHERE NOT is_deleted",(rs,n)->new CategoryKeywordSearch.Node(rs.getObject(1,UUID.class),rs.getObject(2,UUID.class),rs.getString(3),rs.getString(4)));
        GoodsSearchPolicy policy=new GoodsSearchPolicy(keyword,nodes,true,related,mode);
        var sql=policy.nativeSearch("kw","g.category_id","g.code","g.name",List.of("g.name","g.code","g.model","g.spec","g.series","g.c_number","g.material","g.name_en","m.code"),List.of("g.paper","g.require_remark"));
        Map<String,Object> parameters=new HashMap<>(sql.parameters());if(root!=null)parameters.put("root",root);
        String scope=root==null?"":" AND g.category_id IN (WITH RECURSIVE scope AS (SELECT id FROM material_categories WHERE id=:root UNION SELECT c.id FROM material_categories c JOIN scope s ON c.parent_id=s.id) SELECT id FROM scope)";
        var rows=new NamedParameterJdbcTemplate(jdbc).queryForList("SELECT g.id,"+sql.rank()+" AS search_rank FROM goods g LEFT JOIN moulds m ON m.id=g.mould_id WHERE NOT g.is_deleted AND NOT g.auto_created AND (g.status IS NULL OR g.status<>'禁用')"+scope+" AND "+sql.condition()+" ORDER BY search_rank,g.code,g.id",parameters);
        assertEquals(expected,rows.stream().map(row->row.get("id").toString()).toList());
        for(var row:rows)assertEquals(expectedRanks.get(row.get("id").toString()),((Number)row.get("search_rank")).intValue());
    }
    private JsonNode search(String token,UUID root,UUID selected,String keyword,boolean related,int page,int size) throws Exception {
        var request=get("/api/master/goods").param("keyword",keyword).param("includeRelated",Boolean.toString(related))
                .param("excludeDisabled","true").param("excludeStub","true").param("page",Integer.toString(page)).param("size",Integer.toString(size));
        if(root!=null)request.param("categoryRootIds",root.toString());
        if(selected!=null)request.param("categoryId",selected.toString());
        return request(token,request);
    }
    private JsonNode request(String token,MockHttpServletRequestBuilder request) throws Exception {
        MvcResult result=mvc.perform(request.header("Authorization","Bearer "+token)).andReturn();
        assertEquals(200,result.getResponse().getStatus(),body(result));return json(result);
    }
    private UUID category(UUID parent,String name){UUID id=UUID.randomUUID();jdbc.update("INSERT INTO material_categories(id,code,name,parent_id) VALUES(?,?,?,?)",id,"GP-"+id,name,parent);return id;}
    private UUID goods(UUID category,String code,String name,String model,String paper){UUID id=UUID.randomUUID();jdbc.update("INSERT INTO goods(id,category_id,code,name,model,paper,status,auto_created,code_sequence) VALUES(?,?,?,?,?,?,'使用',false,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))",id,category,code,name,model,paper);return id;}
    private static List<String> ids(JsonNode page){List<String> ids=new ArrayList<>();page.path("items").forEach(row->ids.add(row.path("id").asText()));return ids;}
    private static List<String> strings(JsonNode array){List<String> values=new ArrayList<>();array.forEach(row->values.add(row.asText()));return values;}
    private static Set<String> facetValues(JsonNode facets,String field){Set<String> values=new java.util.HashSet<>();facets.path(field).forEach(row->values.add(row.path("value").asText()));return values;}
}
