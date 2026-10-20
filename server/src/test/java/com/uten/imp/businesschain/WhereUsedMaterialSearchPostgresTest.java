package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/** Actual MATERIAL candidate SQL/security/controller against the fully migrated schema; report calculations are unchanged. */
@TestPropertySource(properties="uten.features.goods-owner-scope-enabled=true")
class WhereUsedMaterialSearchPostgresTest extends AuthSessionPostgresTestSupport {
    @Test void historyAndUncategorizedCandidatesRemainEligibleWhileRelatedAreOptionalAndEvidenceIsPaged() throws Exception {
        String token=adminToken(), marker="WM"+UUID.randomUUID().toString().replace("-","");
        UUID root=category(null,"反查范围"),screws=category(root,"螺丝类"),sockets=category(root,"插座"),notes=category(root,"说明关联类");
        UUID exact=goods(screws,"螺丝",marker,null),branch=goods(screws,"M3x20",marker,null);
        UUID feature=goods(sockets,"电话插座（螺丝接线式）",marker,null);
        UUID history=goods(null,"历史螺丝",marker,null),related=goods(notes,"仅说明提及",marker,"螺丝");
        jdbc.update("UPDATE goods SET status='禁用',auto_created=true,is_deleted=true,deleted_at=NOW() WHERE id=?",history);
        UUID parent=goods(sockets,"母件",null,null);
        jdbc.update("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty) VALUES(?,?,?,1)",UUID.randomUUID(),parent,exact);
        String query=marker+"\u3000螺丝";
        List<String> paged=new ArrayList<>();Map<String,JsonNode> rows=new HashMap<>();
        for(int page=1;page<=4;page++) {
            JsonNode result=search(token,query,null,false,page,1);
            assertEquals(4,result.path("total").asInt(),result.toString());
            JsonNode row=result.path("items").get(0);paged.add(row.path("id").asText());rows.put(row.path("id").asText(),row);
            assertEquals("PRIMARY",row.path("searchMatchKind").asText());
        }
        assertEquals(List.of(exact.toString(),history.toString(),branch.toString(),feature.toString()),paged);
        assertTrue(rows.get(exact.toString()).path("currentBom").asBoolean());
        assertTrue(rows.get(history.toString()).path("autoCreated").asBoolean());
        assertTrue(rows.get(history.toString()).path("deleted").asBoolean());
        assertFalse(rows.get(history.toString()).path("currentBom").asBoolean());
        assertEquals("history-uncategorized",rows.get(history.toString()).path("categoryId").asText());
        JsonNode expanded=search(token,query,null,true,1,50);
        assertEquals(5,expanded.path("total").asInt());
        assertEquals(related.toString(),expanded.path("items").get(4).path("id").asText());
        assertEquals("RELATED",expanded.path("items").get(4).path("searchMatchKind").asText());
        JsonNode overflow=search(token,query,null,true,999,1);
        assertTrue(overflow.path("items").isEmpty());assertEquals(5,overflow.path("total").asInt());assertEquals(5,overflow.path("totalPages").asInt());
        JsonNode primaryLocations=request(token,get("/api/production/reports/where-used/material-category-matches").param("keyword",query));
        assertEquals(Set.of(screws.toString(),sockets.toString(),"history-uncategorized"),Set.copyOf(strings(primaryLocations.path("items"))));
        JsonNode expandedLocations=request(token,get("/api/production/reports/where-used/material-category-matches").param("keyword",query).param("includeRelated","true"));
        assertEquals(Set.of(screws.toString(),sockets.toString(),notes.toString(),"history-uncategorized"),Set.copyOf(strings(expandedLocations.path("items"))));
        assertEquals(3,search(token,query,root.toString(),false,1,50).path("total").asInt());
        JsonNode historical=search(token,query,"history-uncategorized",false,1,50);
        assertEquals(List.of(history.toString()),ids(historical));
        assertEquals(0,search(token,query,UUID.randomUUID().toString(),true,1,50).path("total").asInt());
    }

    @Test void literalCharactersUnicodeWordsAndBlankCategoryBrowsingKeepTheirOwnContracts() throws Exception {
        String token=adminToken(),suffix=UUID.randomUUID().toString().replace("-","");
        String literal="WM_100%\\A"+suffix;
        UUID category=category(null,"字面反查"),exact=goods(category,"literal material",literal,null);
        goods(category,"literal material",literal.replace("_","X").replace("%","Z"),null);
        assertEquals(List.of(exact.toString()),ids(search(token,literal+"\u00a0literal",null,false,1,50)));
        assertEquals(0,search(token,literal+"\u3000missing",null,true,1,50).path("total").asInt());
        assertEquals(0,search(token," \u3000\t ",null,true,1,50).path("total").asInt());
        JsonNode browsed=search(token," \u3000\t ",category.toString(),true,1,50);
        assertEquals(2,browsed.path("total").asInt());
        browsed.path("items").forEach(row->{assertFalse(row.has("searchRank"));assertFalse(row.has("searchMatchKind"));});
    }

    private JsonNode search(String token,String keyword,String category,boolean related,int page,int size)throws Exception{
        var builder=get("/api/production/reports/where-used/materials").param("keyword",keyword).param("includeRelated",Boolean.toString(related)).param("page",Integer.toString(page)).param("size",Integer.toString(size));
        if(category!=null){ builder.param("categoryId",category); }return request(token,builder);
    }
    private JsonNode request(String token,MockHttpServletRequestBuilder request)throws Exception{MvcResult result=mvc.perform(request.header("Authorization","Bearer "+token)).andReturn();assertEquals(200,result.getResponse().getStatus(),body(result));return json(result);}
    private UUID category(UUID parent,String name){UUID id=UUID.randomUUID();jdbc.update("INSERT INTO material_categories(id,code,name,parent_id) VALUES(?,?,?,?)",id,"WU-"+id,name,parent);return id;}
    private UUID goods(UUID category,String name,String model,String remark){UUID id=UUID.randomUUID();jdbc.update("INSERT INTO goods(id,category_id,code,name,model,require_remark,status,auto_created,code_sequence) VALUES(?,?,?,?,?,?,'使用',false,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))",id,category,"W-"+id,name,model,remark);return id;}
    private static List<String> ids(JsonNode result){List<String> ids=new ArrayList<>();result.path("items").forEach(row->ids.add(row.path("id").asText()));return ids;}
    private static List<String> strings(JsonNode array){List<String> values=new ArrayList<>();array.forEach(row->values.add(row.asText()));return values;}
}
