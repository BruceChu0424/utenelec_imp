package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.test.web.servlet.MvcResult;

import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/** Flat master dictionaries use complete authorized SQL results for matching and rank before paging. */
class FlatMasterSearchAccuracyPostgresTest extends AuthSessionPostgresTestSupport {
    @ParameterizedTest
    @CsvSource({"colors,/api/master/colors", "units,/api/master/units", "currencies,/api/master/currencies", "accounts,/api/master/accounts"})
    void allWordsAreRequiredWildcardsAreLiteralAndExactNamesLeadBeforePaging(String table,String path) throws Exception {
        String salt=UUID.randomUUID().toString().substring(0,8);
        String name="检索"+salt;
        Fixture contains=insert(table,"前"+name+"后","A-"+salt);
        Fixture prefix=insert(table,name+"助理","M-"+salt);
        Fixture exact=insert(table,name,"Z-"+salt);
        Fixture deleted=insert(table,name+"已删除","B-"+salt);
        jdbc.update("UPDATE "+table+" SET is_deleted=true WHERE id=?",deleted.id());
        Fixture literal=insert(table,"字面_%\\"+salt,"L-"+salt);
        String token=adminToken();
        List<UUID> expected=List.of(exact.id(),prefix.id(),contains.id());
        for(int index=0;index<expected.size();index++) {
            JsonNode page=search(token,path,name,index+1,1);
            assertEquals(3,page.path("total").asInt(),page.toString());
            assertEquals(expected.get(index).toString(),page.path("items").get(0).path("id").asText());
        }
        assertEquals(1,search(token,path,prefix.name()+" "+prefix.code(),1,20).path("total").asInt());
        assertEquals(0,search(token,path,prefix.name()+" 不存在",1,20).path("total").asInt());
        JsonNode wildcard=search(token,path,"_%\\"+salt,1,20);
        assertEquals(1,wildcard.path("total").asInt(),wildcard.toString());
        assertEquals(literal.id().toString(),wildcard.path("items").get(0).path("id").asText());
        if(table.equals("accounts")) {
            MvcResult anonymous=mvc.perform(get(path).param("keyword",name)).andReturn();
            assertEquals(401,anonymous.getResponse().getStatus(),body(anonymous));
        }
    }

    @Test
    void warehouseKeepsMainHierarchyFirstAndRanksMatchesWithinChildren() throws Exception {
        UUID main=mainWarehouse();
        String salt=UUID.randomUUID().toString().substring(0,8), name="仓库检索"+salt;
        String original=jdbc.queryForObject("SELECT location FROM warehouses WHERE id=?",String.class,main);
        try {
            jdbc.update("UPDATE warehouses SET location=? WHERE id=?","前 "+name+" 后",main);
            Fixture contains=warehouse(main,"前"+name+"后","A-"+salt);
            Fixture prefix=warehouse(main,name+"辅助","M-"+salt);
            Fixture exact=warehouse(main,name,"Z-"+salt);
            String token=adminToken();
            JsonNode data=search(token,"/api/master/warehouses",name,1,20);
            assertEquals(List.of(main.toString(),exact.id().toString(),prefix.id().toString(),contains.id().toString()),
                    java.util.stream.StreamSupport.stream(data.path("items").spliterator(),false)
                            .map(row->row.path("id").asText()).toList());
            JsonNode mixed=search(token,"/api/master/warehouses",exact.name()+" "+exact.code(),1,20);
            assertEquals(1,mixed.path("total").asInt());
            Fixture literal=warehouse(main,"字面_%\\"+salt,"L-"+salt);
            JsonNode escaped=search(token,"/api/master/warehouses","_%\\"+salt,1,20);
            assertEquals(literal.id().toString(),escaped.path("items").get(0).path("id").asText());
        } finally { jdbc.update("UPDATE warehouses SET location=? WHERE id=?",original,main); }
    }

    @Test
    void warehouseKeeperCandidatesUseAllWordsAndLiteralMatchingWithoutIncludingDepartedPeople() throws Exception {
        String salt=UUID.randomUUID().toString().substring(0,8), name="仓库人员"+salt;
        UUID department=jdbc.queryForObject("SELECT id FROM departments WHERE code='DEPT_HR'",UUID.class);
        UUID employee=UUID.randomUUID();
        String code="KEEP-"+salt;
        jdbc.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES (?,?,?,'其他',?,DATE '2020-01-01','active','regular')",employee,code,name,department);
        String token=adminToken();
        MvcResult result=mvc.perform(get("/api/master/warehouses/keeper-candidates")
                .param("keyword",name+" "+code).header("Authorization","Bearer "+token)).andReturn();
        assertEquals(200,result.getResponse().getStatus(),body(result));
        assertEquals(1,json(result).size());
        assertEquals(employee.toString(),json(result).get(0).path("employeeId").asText());
        MvcResult literal=mvc.perform(get("/api/master/warehouses/keeper-candidates")
                .param("keyword",name+" %").header("Authorization","Bearer "+token)).andReturn();
        assertEquals(200,literal.getResponse().getStatus(),body(literal));
        assertEquals(0,json(literal).size());
    }

    private JsonNode search(String token,String path,String keyword,int page,int size) throws Exception {
        MvcResult result=mvc.perform(get(path).param("keyword",keyword).param("page",Integer.toString(page))
                .param("size",Integer.toString(size)).header("Authorization","Bearer "+token)).andReturn();
        assertEquals(200,result.getResponse().getStatus(),body(result));
        return json(result);
    }

    private Fixture insert(String table,String name,String suffix) {
        if(!Set.of("colors","units","currencies","accounts").contains(table)) throw new IllegalArgumentException(table);
        UUID id=UUID.randomUUID(); String code="FLAT-"+suffix;
        jdbc.update("INSERT INTO "+table+"(id,code,name,status) VALUES (?,?,?,?)",id,code,name,table.equals("accounts")?"禁用":"使用");
        return new Fixture(id,code,name);
    }
    private Fixture warehouse(UUID parent,String name,String suffix) {
        UUID id=UUID.randomUUID();String code="FLAT-WH-"+suffix;
        jdbc.update("INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable) VALUES (?,?,?,?,'使用',true)",id,code,name,parent);
        return new Fixture(id,code,name);
    }
    private UUID mainWarehouse() {
        List<UUID> roots=jdbc.queryForList("SELECT id FROM warehouses WHERE parent_id IS NULL AND NOT is_deleted",UUID.class);
        if(!roots.isEmpty()) return roots.getFirst();
        UUID id=UUID.randomUUID();
        jdbc.update("INSERT INTO warehouses(id,code,name,status,is_accountable) VALUES (?,'001','主仓','使用',true)",id);
        return id;
    }
    private record Fixture(UUID id,String code,String name) {}
}
