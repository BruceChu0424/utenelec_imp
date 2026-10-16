package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;
import java.util.List;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/** The manual alias tab uses ordinary literal search, independent of automatic alias resolution. */
class ClientGoodsAliasSearchPostgresTest extends AuthSessionPostgresTestSupport {
    @Test void clientAliasUiRanksRealGoodsNamesAndKeepsEveryWordClientScopeAndPageCount() throws Exception {
        String token=adminToken(), word="CA"+UUID.randomUUID().toString().replace("-", "");
        UUID client=client(), otherClient=client();
        UUID exact=alias(client, "OTHER-"+UUID.randomUUID(), word, "标签甲", null);
        UUID prefix=alias(client, "OTHER-"+UUID.randomUUID(), word+"后缀", "标签乙", null);
        UUID code=alias(client, word, "普通货品", "标签丙", null);
        alias(otherClient, "OUT-"+UUID.randomUUID(), word, "范围外", null);
        for(int index=0;index<3;index++) {
            JsonNode page=search(token,client,word,index+1,1);
            assertEquals(3,page.path("total").asInt(),page.toString());
            assertEquals(List.of(exact,prefix,code).get(index).toString(),page.path("items").get(0).path("id").asText());
        }
        String literal="M3_20%\\A";
        UUID wanted=alias(client,"L-"+UUID.randomUUID(),"螺丝",word+"客户叫法",literal);
        alias(client,"X-"+UUID.randomUUID(),"螺丝",word+"客户叫法二","M3X20AZA");
        JsonNode compound=search(token,client,word+" 螺丝 "+literal,1,20);
        assertEquals(1,compound.path("total").asInt(),compound.toString());
        assertEquals(wanted.toString(),compound.path("items").get(0).path("id").asText());
        assertEquals(0,search(token,client,word+" 不存在",1,20).path("total").asInt());
        assertEquals(401,mvc.perform(get("/api/master/clients/"+client+"/goods-aliases").param("keyword",word)).andReturn().getResponse().getStatus());
    }
    private JsonNode search(String token,UUID client,String text,int page,int size) throws Exception {
        MvcResult result=mvc.perform(get("/api/master/clients/"+client+"/goods-aliases").param("keyword",text)
                .param("page",Integer.toString(page)).param("size",Integer.toString(size)).header("Authorization","Bearer "+token)).andReturn();
        assertEquals(200,result.getResponse().getStatus(),body(result));return json(result);
    }
    private UUID client(){UUID id=UUID.randomUUID();jdbc.update("INSERT INTO clients(id,code,name,code_sequence) VALUES (?,?,'别名检索客户',(SELECT COALESCE(MAX(code_sequence),0)+1 FROM clients))",id,"AC-"+id);return id;}
    private UUID alias(UUID client,String code,String name,String alias,String model){
        UUID goods=UUID.randomUUID(),id=UUID.randomUUID();
        jdbc.update("INSERT INTO goods(id,code,name,model,code_sequence) VALUES (?,?,?,?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))",goods,code,name,model);
        jdbc.update("INSERT INTO client_goods_aliases(id,client_id,alias_kind,alias_text,alias_norm,goods_id,first_confirmed_at,last_confirmed_at) VALUES (?,?,'PART_NO',?,?,?,now(),now())",id,client,alias,alias,goods);
        return id;
    }
}
