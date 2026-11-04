package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/** Migrated PostgreSQL and real controller/security: keeper candidates remain complete without exhaustive UI reads. */
class WarehouseKeeperSearchPostgresTest extends AuthSessionPostgresTestSupport {
    private static final String PATH = "/api/master/warehouses/keeper-candidates";

    @Test void pagesKeepLegacyOrderingWarningFactsAndWarehouseEditAuthority() throws Exception {
        String name = "仓管候选" + UUID.randomUUID().toString().substring(0, 8);
        UUID department = department();
        for (int index = 0; index < 23; index++) employee(department, name + (index == 0 ? "" : index), index == 0);
        String token = adminToken();
        MvcResult legacy = mvc.perform(get(PATH).param("keyword", name).header("Authorization", "Bearer " + token)).andReturn();
        assertEquals(200, legacy.getResponse().getStatus(), body(legacy));
        JsonNode expected = json(legacy);
        List<JsonNode> actual = new ArrayList<>();
        for (int page = 1; page <= 5; page++) {
            JsonNode result = page(token, name, page, 5, null, false);
            assertEquals(23, result.path("total").asInt());
            assertEquals(5, result.path("totalPages").asInt());
            result.path("items").forEach(actual::add);
        }
        assertEquals(23, actual.size());
        for (int index = 0; index < actual.size(); index++) assertEquals(expected.get(index), actual.get(index));
        assertTrue(actual.getFirst().path("hasAccount").asBoolean());
        assertFalse(actual.getFirst().path("duplicateName").asBoolean());
        Employee viewer = newEmployee(token, "DEPT_ENG");
        MvcResult denied = mvc.perform(get(PATH + "/page").header("Authorization", "Bearer " + viewer.accessToken())).andReturn();
        assertEquals(403, denied.getResponse().getStatus(), body(denied));
    }

    @Test void ancestorAndLiteralWordsFilterBeforeDepartmentPaging() throws Exception {
        UUID parent = UUID.randomUUID(), leaf = UUID.randomUUID();
        String suffix = UUID.randomUUID().toString().substring(0, 8);
        String parentName = "仓管祖先_%\\" + suffix;
        jdbc.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES (?,?,?,?,'二级班组')",
                parent, "KEEPER-P-" + suffix, parentName, department());
        jdbc.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES (?,?,?,?,'三级科室')",
                leaf, "KEEPER-L-" + suffix, "叶部门", parent);
        UUID employee = employee(leaf, "候选张" + suffix, false);
        String token = adminToken();
        JsonNode result = page(token, parentName + " 候选张", 1, 1, parent, true);
        assertEquals(1, result.path("total").asInt());
        assertEquals(employee.toString(), result.path("items").get(0).path("employeeId").asText());
        assertEquals(0, page(token, parentName + " 候选张", 1, 1, parent, false).path("total").asInt());
        assertEquals(0, page(token, "候选张" + suffix, 1, 1, UUID.randomUUID(), true).path("total").asInt());
    }

    @Test void moreThanFiveThousandPeopleStillReturnOnlyTheRequestedPage() throws Exception {
        String prefix = "大目录" + UUID.randomUUID().toString().substring(0, 8);
        UUID department = department();
        jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                SELECT gen_random_uuid(), ? || n, ? || n, '其他', ?, DATE '2020-01-01', 'active', 'regular'
                FROM generate_series(1,5005) n
                """, "KEEPER-" + prefix, prefix, department);
        String token = adminToken();
        JsonNode result = page(token, prefix, 1, 100, department, false);
        assertEquals(5005, result.path("total").asInt());
        assertEquals(51, result.path("totalPages").asInt());
        assertEquals(100, result.path("items").size());
        assertEquals(5, page(token, prefix, 51, 100, department, false).path("items").size());
    }

    private JsonNode page(String token, String query, int page, int size, UUID department, boolean subtree) throws Exception {
        var request = get(PATH + "/page").param("keyword", query).param("page", Integer.toString(page))
                .param("size", Integer.toString(size)).param("includeSubtree", Boolean.toString(subtree));
        if (department != null) request.param("departmentId", department.toString());
        MvcResult result = mvc.perform(request.header("Authorization", "Bearer " + token)).andReturn();
        assertEquals(200, result.getResponse().getStatus(), body(result));
        assertNotNull(result.getResponse().getHeader("X-Uten-Read-Scope-Version"));
        return json(result);
    }

    private UUID department() {
        return jdbc.queryForObject("SELECT id FROM departments WHERE code='DEPT_HR'", UUID.class);
    }

    private UUID employee(UUID department, String name, boolean account) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES (?,?,?,'其他',?,DATE '2020-01-01','active','regular')
                """, id, "KEEPER-" + id, name, department);
        if (account) jdbc.update("INSERT INTO users(employee_id,login_account,password_hash,must_change_password) VALUES (?,?,'unused-test',false)",
                id, "keeper-" + id);
        return id;
    }
}
