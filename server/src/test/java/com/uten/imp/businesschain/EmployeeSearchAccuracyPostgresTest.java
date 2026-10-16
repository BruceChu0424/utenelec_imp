package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.features.org.department.staffpermission.DepartmentPermissionStaffQuery;
import com.uten.imp.features.org.department.staffpermission.OrganizationPermissionManagementScopeService.StaffSearchAuthority;
import com.uten.imp.features.org.department.staffpermission.OrganizationPermissionManagementScopeService.StaffSearchScope;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.test.web.servlet.MvcResult;

import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/** Ordinary HR searches must rank/filter on the authorized database result before paging. */
class EmployeeSearchAccuracyPostgresTest extends AuthSessionPostgresTestSupport {
    @Autowired DepartmentPermissionStaffQuery staff;

    @Test
    void ordinaryEmployeeAndAccountSearchRequireAllWordsAcrossFieldsAndTreatWildcardsLiterally() throws Exception {
        String salt=UUID.randomUUID().toString().substring(0,8);
        Fixture target=fixture("行政核对"+salt,true);
        String token=adminToken();
        String departmentName=jdbc.queryForObject("SELECT name FROM departments WHERE id=?",String.class,target.department());
        for(String query:List.of(target.name()+" "+departmentName, departmentName+" "+target.code())) {
            JsonNode result=search(token,"/api/org/employees",query,1,20);
            assertEquals(1,result.path("total").asInt(),result.toString());
            assertEquals(target.id().toString(),result.path("items").get(0).path("id").asText());
        }
        assertEquals(1,search(token,"/api/admin/users",target.name()+" "+target.code(),1,20).path("total").asInt());
        assertEquals(0,search(token,"/api/org/employees",target.name()+" 不存在部门",1,20).path("total").asInt());
        Fixture literal=fixture("字面_%\\"+salt,true);
        token=adminToken();
        for(String path:List.of("/api/org/employees","/api/admin/users")) {
            JsonNode result=search(token,path,"_%\\"+salt,1,20);
            assertEquals(1,result.path("total").asInt(),result.toString());
            String key=path.endsWith("users")?"employeeId":"id";
            assertEquals(literal.id().toString(),result.path("items").get(0).path(key).asText());
        }
    }

    @Test
    void exactNamePrecedesPrefixAndContainsBeforeEmployeeAccountAndStaffPaging() throws Exception {
        String name="陈力"+UUID.randomUUID().toString().substring(0,8);
        Fixture contains=fixture("附加"+name+"尾",true);
        Fixture prefix=fixture(name+"助手",true);
        Fixture exact=fixture(name,true);
        String token=adminToken();
        List<UUID> expected=List.of(exact.id(),prefix.id(),contains.id());
        for(String path:List.of("/api/org/employees","/api/admin/users")) {
            for(int index=0;index<expected.size();index++) {
                JsonNode result=search(token,path,name,index+1,1);
                assertEquals(3,result.path("total").asInt(),result.toString());
                String key=path.endsWith("users")?"employeeId":"id";
                assertEquals(expected.get(index).toString(),result.path("items").get(0).path(key).asText());
            }
        }
        var authority=new StaffSearchAuthority(StaffSearchScope.SUPER_ADMIN_COMPANY,null);
        for(int index=0;index<expected.size();index++) {
            var result=staff.query(authority,exact.department(),null,name,index+1,1);
            assertEquals(3,result.total());
            assertEquals(expected.get(index),result.staff().getFirst().employeeId());
        }
        var mixed=staff.query(authority,exact.department(),null,exact.name()+" "+exact.code(),1,1);
        assertEquals(exact.id(),mixed.staff().getFirst().employeeId());
        assertEquals(0,staff.query(new StaffSearchAuthority(StaffSearchScope.MANAGER_SUBTREES,UUID.randomUUID()),
                null,null,name,1,20).total(),"关键词不能放开经理部门边界");
    }

    @Test
    void provisioningCandidatesShareWordAndRankRulesWithoutAdmittingExistingAccountsOrDepartedEmployees() throws Exception {
        String name="开号排序"+UUID.randomUUID().toString().substring(0,8);
        Fixture contains=fixture("前"+name+"后",false);
        Fixture prefix=fixture(name+"助理",false);
        Fixture exact=fixture(name,false);
        fixture(name+"已有账号",true);
        fixture(name+"离职",false,"resigned");
        String token=adminToken();
        JsonNode candidates=candidates(token,name);
        assertEquals(List.of(exact.id().toString(),prefix.id().toString(),contains.id().toString()),
                java.util.stream.StreamSupport.stream(candidates.spliterator(),false)
                        .map(row->row.path("employeeId").asText()).toList());
        assertEquals(1,candidates(token,exact.name()+" "+exact.code()).size());
        assertEquals(0,candidates(token,name+" %").size());
    }

    private JsonNode search(String token,String path,String search,int page,int size) throws Exception {
        MvcResult result=mvc.perform(get(path).param("search",search).param("page",Integer.toString(page))
                .param("size",Integer.toString(size)).header("Authorization","Bearer "+token)).andReturn();
        assertEquals(200,result.getResponse().getStatus(),body(result));
        return json(result);
    }

    private JsonNode candidates(String token,String query) throws Exception {
        MvcResult result=mvc.perform(get("/api/admin/users/provision-candidates").param("search",query)
                .header("Authorization","Bearer "+token)).andReturn();
        assertEquals(200,result.getResponse().getStatus(),body(result));
        return json(result);
    }

    private Fixture fixture(String name,boolean account) {
        return fixture(name,account,"active");
    }
    private Fixture fixture(String name,boolean account,String status) {
        UUID id=UUID.randomUUID();
        String code="HRSEARCH-"+id;
        UUID department=jdbc.queryForObject("SELECT id FROM departments WHERE code='DEPT_HR'",UUID.class);
        jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES (?,?,?,'其他',?,DATE '2020-01-01',?,'regular')
                """,id,code,name,department,status);
        if(account) jdbc.update("INSERT INTO users(employee_id,login_account,password_hash,must_change_password) VALUES (?,?,'unused-test',false)",id,"hrsearch-"+id);
        return new Fixture(id,department,code,name);
    }
    private record Fixture(UUID id,UUID department,String code,String name) {}
}
