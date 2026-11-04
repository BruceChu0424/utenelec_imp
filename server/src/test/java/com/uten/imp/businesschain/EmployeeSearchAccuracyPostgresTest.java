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
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

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

    @Test
    void exactAccountSummaryRetainsListVisibilityAndSupportPermissionWithoutCredentialFields() throws Exception {
        String token = adminToken();
        Fixture target = fixture("精确账号" + UUID.randomUUID().toString().substring(0, 8), true, "resigned");
        UUID userId = jdbc.queryForObject("SELECT id FROM users WHERE employee_id=?", UUID.class, target.id());
        MvcResult visible = mvc.perform(get("/api/admin/users/" + userId + "/summary")
                .header("Authorization", "Bearer " + token)).andReturn();
        assertEquals(200, visible.getResponse().getStatus(), body(visible));
        JsonNode summary = json(visible);
        assertEquals(userId.toString(), summary.path("id").asText());
        assertEquals("resigned", summary.path("employeeStatus").asText());
        assertFalse(summary.path("currentEmployee").asBoolean());
        assertFalse(summary.has("passwordHash"));
        assertFalse(summary.has("isSuperAdmin"));

        Employee viewer = newEmployee(token, "DEPT_ENG");
        MvcResult denied = mvc.perform(get("/api/admin/users/" + userId + "/summary")
                .header("Authorization", "Bearer " + viewer.accessToken())).andReturn();
        assertEquals(403, denied.getResponse().getStatus(), body(denied));
        jdbc.update("UPDATE employees SET is_deleted=TRUE WHERE id=?", target.id());
        token = adminToken(); // The fixture mutation also retires the previous authorization epoch.
        MvcResult hidden = mvc.perform(get("/api/admin/users/" + userId + "/summary")
                .header("Authorization", "Bearer " + token)).andReturn();
        assertEquals(404, hidden.getResponse().getStatus(), body(hidden));
    }

    @Test
    void rosterSearchMatchesAncestorDepartmentNamesBeforePaginationWithoutChangingDepartmentScope() throws Exception {
        String suffix = UUID.randomUUID().toString().substring(0, 8);
        Fixture target = fixture("路径人员" + suffix, true);
        UUID ancestor = UUID.randomUUID(), leaf = UUID.randomUUID();
        jdbc.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES (?,?,?,?,'二级班组')",
                ancestor, "SEARCH-PARENT-" + suffix, "祖先_%\\" + suffix, target.department());
        jdbc.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES (?,?,?,?,'三级科室')",
                leaf, "SEARCH-LEAF-" + suffix, "叶部门" + suffix, ancestor);
        jdbc.update("UPDATE employees SET department_id=? WHERE id=?", leaf, target.id());
        String token = adminToken();
        JsonNode result = search(token, "/api/org/employees", "祖先_%\\" + suffix + " 路径人员", 1, 1);
        assertEquals(1, result.path("total").asInt());
        assertEquals(target.id().toString(), result.path("items").get(0).path("id").asText());
        MvcResult outside = mvc.perform(get("/api/org/employees").param("search", "祖先_%\\" + suffix)
                .param("departmentId", target.department().toString()).param("includeSubtree", "false")
                .header("Authorization", "Bearer " + token)).andReturn();
        assertEquals(200, outside.getResponse().getStatus(), body(outside));
        assertEquals(0, json(outside).path("total").asInt());
    }

    @Test
    void dedicatedCandidateReadBodiesKeepThousandExclusionsDepartmentScopeAndOriginalAuthority() throws Exception {
        String suffix = UUID.randomUUID().toString().substring(0, 8);
        Fixture selected = fixture("候选人员" + suffix, true);
        Fixture excluded = fixture("候选人员" + suffix + "助理", true);
        UUID ancestor = UUID.randomUUID(), leaf = UUID.randomUUID();
        String ancestorName = "候选祖先_%\\" + suffix;
        jdbc.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES (?,?,?,?,'二级班组')",
                ancestor, "CAND-PARENT-" + suffix, ancestorName, selected.department());
        jdbc.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES (?,?,?,?,'三级科室')",
                leaf, "CAND-LEAF-" + suffix, "候选叶部门" + suffix, ancestor);
        jdbc.update("UPDATE employees SET department_id=? WHERE id IN (?,?)", leaf, selected.id(), excluded.id());
        String token = adminToken();
        var exclusions = new java.util.ArrayList<UUID>();
        exclusions.add(excluded.id());
        for (int index = 1; index < 1000; index++) exclusions.add(UUID.randomUUID());
        for (String path : List.of("/api/master/clients/access-candidates", "/api/admin/data-handovers/candidates")) {
            var payload = new java.util.LinkedHashMap<String, Object>();
            payload.put(path.contains("data-handovers") ? "query" : "search", ancestorName + " 候选人员");
            if (path.contains("data-handovers")) payload.put("role", "source");
            payload.put("departmentId", ancestor); payload.put("includeSubtree", true);
            payload.put("excludeEmployeeIds", exclusions); payload.put("page", 1); payload.put("size", 1);
            MvcResult result = mvc.perform(json(post(path + "/query"), payload, token)).andReturn();
            assertEquals(200, result.getResponse().getStatus(), body(result));
            assertNotNull(result.getResponse().getHeader("X-Uten-Read-Scope-Version"));
            assertEquals(1, json(result).path("total").asInt());
            assertEquals(selected.id().toString(), json(result).path("items").get(0).path("employeeId").asText());
            payload.put("includeSubtree", false);
            MvcResult empty = mvc.perform(json(post(path + "/query"), payload, token)).andReturn();
            assertEquals(200, empty.getResponse().getStatus(), body(empty));
            assertEquals(0, json(empty).path("total").asInt());
            payload.put("excludeEmployeeIds", java.util.Collections.nCopies(1001, excluded.id()));
            MvcResult invalid = mvc.perform(json(post(path + "/query"), payload, token)).andReturn();
            assertEquals(422, invalid.getResponse().getStatus(), body(invalid));
        }
        Employee viewer = newEmployee(token, "DEPT_ENG");
        for (String path : List.of("/api/master/clients/access-candidates/query", "/api/admin/data-handovers/candidates/query")) {
            MvcResult denied = mvc.perform(json(post(path), java.util.Map.of("role", "source"), viewer.accessToken())).andReturn();
            assertEquals(403, denied.getResponse().getStatus(), body(denied));
        }
    }

    private JsonNode search(String token,String path,String search,int page,int size) throws Exception {
        MvcResult result=mvc.perform(get(path).param("search",search).param("page",Integer.toString(page))
                .param("size",Integer.toString(size)).header("Authorization","Bearer "+token)).andReturn();
        assertEquals(200,result.getResponse().getStatus(),body(result));
        return json(result);
    }

    @Test
    void protectedProvisionAndSimulationPagesKeepOriginalFactsAndAdministrativeIdentity() throws Exception {
        String suffix=UUID.randomUUID().toString().substring(0,8);
        Fixture unprovisioned=fixture("开户目录"+suffix,false);
        fixture("开户目录"+suffix+"请假",false,"onLeave");
        fixture("开户目录"+suffix+"离职",false,"resigned");
        fixture("开户目录"+suffix+"已号",true);
        Fixture noAccount=fixture("模拟目录"+suffix+"未号",false);
        Fixture locked=fixture("模拟目录"+suffix+"锁定",true);
        jdbc.update("UPDATE users SET status='locked' WHERE employee_id=?",locked.id());
        fixture("模拟目录"+suffix+"试用",true,"probation");
        String token=adminToken();
        JsonNode provision=search(token,"/api/admin/users/provision-candidates/page","开户目录"+suffix,1,1);
        assertEquals(2,provision.path("total").asInt());
        assertEquals(unprovisioned.id().toString(),provision.path("items").get(0).path("employeeId").asText());
        assertFalse(provision.path("items").get(0).has("phoneEnc"));
        assertFalse(provision.path("items").get(0).has("idCardEnc"));
        var targetIds=new java.util.HashSet<String>();var accountStates=new java.util.HashSet<String>();
        for(int page=1;page<=2;page++) {
            JsonNode targets=search(token,"/api/admin/impersonation/targets/page","模拟目录"+suffix,page,1);
            assertEquals(2,targets.path("total").asInt());
            targetIds.add(targets.path("items").get(0).path("employeeId").asText());
            accountStates.add(targets.path("items").get(0).path("accountStatus").asText());
        }
        assertEquals(java.util.Set.of(noAccount.id().toString(),locked.id().toString()),targetIds);
        assertEquals(java.util.Set.of("notProvisioned","locked"),accountStates);
        UUID adminEmployee=jdbc.queryForObject("SELECT employee_id FROM users WHERE login_account=?",UUID.class,ADMIN_LOGIN);
        String adminName=jdbc.queryForObject("SELECT full_name FROM employees WHERE id=?",String.class,adminEmployee);
        JsonNode admins=search(token,"/api/admin/impersonation/targets/page",adminName,1,100);
        assertTrue(java.util.stream.StreamSupport.stream(admins.path("items").spliterator(),false)
                .anyMatch(row->adminEmployee.toString().equals(row.path("employeeId").asText())),
                "Search visibility must not be replaced by start-time super-admin rejection");
        MvcResult tree=mvc.perform(get("/api/admin/impersonation/targets/departments")
                .header("Authorization","Bearer "+token)).andReturn();
        assertEquals(200,tree.getResponse().getStatus(),body(tree));assertTrue(json(tree).isArray());
        assertNotNull(tree.getResponse().getHeader("X-Uten-Read-Scope-Version"));
        Employee viewer=newEmployee(token,"DEPT_ENG");
        for(String path:List.of("/api/admin/users/provision-candidates/page","/api/admin/impersonation/targets/page",
                "/api/admin/impersonation/targets/departments")) {
            MvcResult denied=mvc.perform(get(path).header("Authorization","Bearer "+viewer.accessToken())).andReturn();
            assertEquals(403,denied.getResponse().getStatus(),body(denied));
        }
    }

    @Test
    void companyPrincipalPageKeepsAccountIdsAndReadOnlyAuthorityWithoutHrDirectoryAccess() throws Exception {
        String suffix=UUID.randomUUID().toString().substring(0,8);
        Fixture target=fixture("目录主体"+suffix,true);
        Fixture locked=fixture("目录主体"+suffix+"锁定",true);
        fixture("目录主体"+suffix+"未号",false);
        UUID ancestor=UUID.randomUUID(),leaf=UUID.randomUUID();
        String rootName="主体祖先_%\\"+suffix;
        jdbc.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES (?,?,?,?,'二级班组')",
                ancestor,"PRINCIPAL-ROOT-"+suffix,rootName,target.department());
        jdbc.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES (?,?,?,?,'三级科室')",
                leaf,"PRINCIPAL-LEAF-"+suffix,"主体部门"+suffix,ancestor);
        jdbc.update("UPDATE employees SET department_id=? WHERE id IN (?,?)",leaf,target.id(),locked.id());
        jdbc.update("UPDATE users SET status='locked' WHERE employee_id=?",locked.id());
        String admin=adminToken(); Employee reader=newEmployee(admin,"DEPT_ENG");
        jdbc.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'grant' FROM permissions"
                +" WHERE code='company_file:view' ON CONFLICT(user_id,permission_id) DO UPDATE SET effect='grant',active=TRUE",UUID.fromString(reader.userId()));
        jdbc.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'revoke' FROM permissions"
                +" WHERE code IN ('employee:view','department:view') ON CONFLICT(user_id,permission_id) DO UPDATE SET effect='revoke',active=TRUE",UUID.fromString(reader.userId()));
        String token=login(reader.loginAccount(),EMPLOYEE_PASSWORD).path("accessToken").asText();
        MvcResult page=mvc.perform(get("/api/company-files/principals/page").param("type","USER")
                .param("search",rootName+" 目录主体").param("departmentId",ancestor.toString()).param("includeSubtree","true")
                .param("page","1").param("size","1").header("Authorization","Bearer "+token)).andReturn();
        assertEquals(200,page.getResponse().getStatus(),body(page));
        assertNotNull(page.getResponse().getHeader("X-Uten-Read-Scope-Version"));
        assertEquals(1,json(page).path("total").asInt());
        UUID account=jdbc.queryForObject("SELECT id FROM users WHERE employee_id=?",UUID.class,target.id());
        assertEquals(account.toString(),json(page).path("items").get(0).path("id").asText());
        assertEquals("USER",json(page).path("items").get(0).path("type").asText());
        assertNotEquals(target.id().toString(),json(page).path("items").get(0).path("id").asText());
        MvcResult hr=mvc.perform(get("/api/org/employees").header("Authorization","Bearer "+token)).andReturn();
        assertEquals(403,hr.getResponse().getStatus(),body(hr));
        MvcResult department=mvc.perform(get("/api/company-files/principals/page").param("type","DEPARTMENT")
                .param("search","主体部门 "+suffix).param("departmentId",UUID.randomUUID().toString())
                .header("Authorization","Bearer "+token)).andReturn();
        assertEquals(200,department.getResponse().getStatus(),body(department));
        assertEquals(leaf.toString(),json(department).path("items").get(0).path("id").asText());
        assertEquals("DEPARTMENT",json(department).path("items").get(0).path("type").asText());
        jdbc.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'revoke' FROM permissions"
                +" WHERE code='company_file:view' ON CONFLICT(user_id,permission_id) DO UPDATE SET effect='revoke',active=TRUE",UUID.fromString(reader.userId()));
        token=login(reader.loginAccount(),EMPLOYEE_PASSWORD).path("accessToken").asText();
        MvcResult denied=mvc.perform(get("/api/company-files/principals/page").header("Authorization","Bearer "+token)).andReturn();
        assertEquals(403,denied.getResponse().getStatus(),body(denied));
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
