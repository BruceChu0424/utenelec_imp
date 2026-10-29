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
    @org.springframework.beans.factory.annotation.Autowired com.uten.imp.common.docnumber.DocNumberService numbering;
    @org.springframework.beans.factory.annotation.Autowired com.uten.imp.features.production.plan.ProductionProductNoAllocator productNumbers;
    @org.springframework.beans.factory.annotation.Autowired org.springframework.transaction.PlatformTransactionManager transactions;
    @Test void historyAndUncategorizedCandidatesRemainEligibleWhileRelatedAreOptionalAndEvidenceIsPaged() throws Exception {
        String token=adminToken(), marker="WM"+UUID.randomUUID().toString().replace("-","");
        UUID root=category(null,"反查范围"),screws=category(root,"螺丝类"),sockets=category(root,"插座"),notes=category(root,"说明关联类");
        UUID exact=goods(screws,"螺丝",marker,null),branch=goods(screws,"M3x20",marker,null);
        UUID feature=goods(sockets,"电话插座（螺丝接线式）",marker,null);
        UUID history=goods(null,"历史螺丝",marker,null),related=goods(notes,"仅说明提及",marker,"螺丝");
        UUID color=UUID.randomUUID(),historicalColor=UUID.randomUUID();
        jdbc.update("INSERT INTO colors(id,code,name) VALUES(?,?,?)",color,"WU-C-"+color,"反查黑色");
        jdbc.update("INSERT INTO colors(id,code,name,is_deleted,deleted_at) VALUES(?,?,?,true,NOW())",historicalColor,"WU-C-"+historicalColor,"历史白色");
        jdbc.update("UPDATE goods SET color_id=?,series=? WHERE id=?",color,"螺丝系列 A",exact);
        jdbc.update("UPDATE goods SET color_id=?,series=? WHERE id=?",historicalColor,"历史系列 B",history);
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
        assertEquals("反查黑色",rows.get(exact.toString()).path("colorName").asText());
        assertEquals("螺丝系列 A",rows.get(exact.toString()).path("series").asText());
        assertTrue(rows.get(branch.toString()).path("colorName").isNull());
        assertTrue(rows.get(branch.toString()).path("series").isNull());
        assertTrue(rows.get(history.toString()).path("autoCreated").asBoolean());
        assertTrue(rows.get(history.toString()).path("deleted").asBoolean());
        assertFalse(rows.get(history.toString()).path("currentBom").asBoolean());
        assertEquals("history-uncategorized",rows.get(history.toString()).path("categoryId").asText());
        assertEquals("历史白色",rows.get(history.toString()).path("colorName").asText());
        assertEquals("历史系列 B",rows.get(history.toString()).path("series").asText());
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

    @Test void relationshipHeadersFilterCompleteProductAggregatesWithoutFilteringIndividualHistoricalEvidence() throws Exception {
        String token=adminToken(),marker="HEADER_%"+UUID.randomUUID();
        UUID category=category(null,"表头分类"),material=goods(category,"表头原料",null,null);
        for(int product=0;product<3;product++){
            UUID parent=goods(category,marker+product,null,null),plan=UUID.randomUUID(),item=UUID.randomUUID();
            jdbc.update("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty) VALUES (?,?,?,1)",UUID.randomUUID(),parent,material);
            int evidenceCount=product==2?1:2;
            new org.springframework.transaction.support.TransactionTemplate(transactions).executeWithoutResult(status->{
                String bill=numbering.nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.PRODUCTION_PLAN);
                jdbc.update("INSERT INTO production_plans(id,bill_no,bill_date,status) VALUES (?,?,'2026-10-31',1)",plan,bill);
                String productNo=productNumbers.allocate(plan,Set.of());
                jdbc.update("INSERT INTO production_plan_items(id,plan_id,bill_no,bill_date,product_no,goods_id,qty) VALUES (?,?,?,'2026-10-31',?,?,1)",item,plan,bill,productNo,parent);
                // Historical expansion snapshots retain the same migration-only guard as the existing worker oracle.
                jdbc.queryForObject("SELECT set_config('app.legacy_import','on',true)",String.class);
                for(int evidence=0;evidence<evidenceCount;evidence++)
                    jdbc.update("INSERT INTO production_plan_costs(id,legacy_id,bill_item_id,bill_no,bill_date,goods_id,master_goods_id,node_class,qty) SELECT ?,COALESCE(MAX(legacy_id),1500000000)+1,?,?,'2026-10-31',?,?,0,.5 FROM production_plan_costs",UUID.randomUUID(),item,bill,material,parent);
            });
        }
        var base=get("/api/production/reports/where-used").param("materialGoodsId",material.toString())
                .param("f.search.goodsName",marker).param("f.search.legacyRequiredQty",">=0.75")
                .param("f.search.lastUsed","2026-10-01..2026-10-31").param("sort","goodsCode").param("size","1").param("page","2");
        JsonNode second=request(token,base);
        assertEquals(2,second.path("total").asInt(),second.toPrettyString());
        assertEquals(1,second.path("rows").size());
        assertEquals(0,second.path("rows").get(0).path("legacyRequiredQty").decimalValue().compareTo(java.math.BigDecimal.ONE));
        assertEquals(1,second.path("rows").get(0).path("__legacyProductionLineCount").asInt());
        assertEquals(13,second.path("columnSearchKeys").size());
        JsonNode sample=second.path("rows").get(0);
        for(JsonNode column:second.path("columns")){
            String key=column.path("key").asText(),type=column.path("type").asText();
            JsonNode value=sample.get(key);
            String input=value==null||value.isNull()?(type.equals("date")?"1999-01":type.equals("number")?">999999":"missing_%")
                    :value.asText();
            JsonNode filtered=request(token,get("/api/production/reports/where-used").param("materialGoodsId",material.toString())
                    .param("f.search."+key,input).param("size","1").param("sort",key));
            if(value!=null&&!value.isNull())assertTrue(filtered.path("total").asInt()>0,key+" "+filtered.toPrettyString());
        }
        JsonNode overflow=request(token,get("/api/production/reports/where-used").param("materialGoodsId",material.toString())
                .param("f.search.goodsName",marker).param("f.search.legacyRequiredQty",">=0.75").param("size","1").param("page","999"));
        assertEquals(2,overflow.path("total").asInt());assertTrue(overflow.path("rows").isEmpty());
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
