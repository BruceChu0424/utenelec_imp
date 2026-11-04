package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.application.port.ApprovalCandidateDirectoryPort;
import org.junit.jupiter.api.Test;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MvcResult;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/** Real candidate SQL/HTTP; only the unchanged cross-domain eligibility port is stubbed. */
class DepartmentApprovalCandidateSearchPostgresTest extends AuthSessionPostgresTestSupport {
    @MockitoBean ApprovalCandidateDirectoryPort directory;

    @Test void qualifiedCandidatesRemainReachableAfterOneHundredWithLiteralMultiwordRanking() throws Exception {
        UUID department = department();
        String name = "替补_%\\" + UUID.randomUUID().toString().substring(0, 8);
        List<ApprovalCandidateDirectoryPort.Candidate> allowed = new ArrayList<>();
        UUID manager = employee(department, name + "负责人", "MANAGER-" + UUID.randomUUID());
        jdbc.update("INSERT INTO users(employee_id,login_account,password_hash,must_change_password) VALUES (?,?,'unused-test',false)",
                manager, "policy-manager-" + manager);
        allowed.add(new ApprovalCandidateDirectoryPort.Candidate(UUID.randomUUID(), manager));
        jdbc.update("UPDATE departments SET manager_id=? WHERE id=?", manager, department);
        UUID exact = null;
        for (int index = 0; index < 105; index++) {
            UUID id = employee(department, index == 0 ? name : name + index, "POLICY-" + UUID.randomUUID());
            if (index == 0) exact = id;
            allowed.add(new ApprovalCandidateDirectoryPort.Candidate(UUID.randomUUID(), id));
        }
        employee(department, name + "没有审批资格", "OUT-" + UUID.randomUUID());
        Set<String> prerequisites = Set.of("attachment:view", "attachment:download");
        when(directory.candidates(anyString(), eq(prerequisites))).thenReturn(allowed);
        String token = adminToken();
        Set<String> found = new HashSet<>();
        for (int page = 1; page <= 2; page++) {
            JsonNode result = page(token, department, name, page, 100);
            assertEquals(105, result.path("total").asInt());
            assertEquals(2, result.path("totalPages").asInt());
            if (page == 1) assertEquals(exact.toString(), result.path("items").get(0).path("id").asText());
            result.path("items").forEach(row -> found.add(row.path("id").asText()));
        }
        assertEquals(105, found.size());
        assertFalse(found.contains(manager.toString()));
        assertEquals(5, page(token, department, name, 2, 100).path("items").size());
        String code = jdbc.queryForObject("SELECT code FROM employees WHERE id=?", String.class, exact);
        JsonNode words = page(token, department, name + " " + code, 1, 1);
        assertEquals(1, words.path("total").asInt());
        verify(directory, atLeastOnce()).candidates("expense:approve:department", prerequisites);
        verify(directory, atLeastOnce()).candidates("application:approve:department", prerequisites);
        verify(directory, never()).candidates(anyString());
        Employee viewer = newEmployee(token, "DEPT_ENG");
        MvcResult denied = mvc.perform(get(path(department)).header("Authorization", "Bearer " + viewer.accessToken())).andReturn();
        assertEquals(403, denied.getResponse().getStatus(), body(denied));
    }

    @Test void emptyEligibilityAndExcessiveTextDoNotFallBackToAnUnrestrictedDirectory() throws Exception {
        when(directory.candidates(anyString(), eq(Set.of("attachment:view", "attachment:download")))).thenReturn(List.of());
        String token = adminToken();
        assertEquals(0, page(token, department(), "", 1, 100).path("total").asInt());
        MvcResult invalid = mvc.perform(get(path(department())).param("search", "a".repeat(201))
                .header("Authorization", "Bearer " + token)).andReturn();
        assertEquals(422, invalid.getResponse().getStatus(), body(invalid));
    }

    private JsonNode page(String token, UUID department, String search, int page, int size) throws Exception {
        MvcResult result = mvc.perform(get(path(department)).param("search", search).param("page", Integer.toString(page))
                .param("size", Integer.toString(size)).header("Authorization", "Bearer " + token)).andReturn();
        assertEquals(200, result.getResponse().getStatus(), body(result));
        assertNotNull(result.getResponse().getHeader("X-Uten-Read-Scope-Version"));
        return json(result);
    }

    private String path(UUID department) { return "/api/approval-policy/departments/" + department + "/candidates/page"; }
    private UUID department() { return jdbc.queryForObject("SELECT id FROM departments WHERE code='DEPT_HR'", UUID.class); }
    private UUID employee(UUID department, String name, String code) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES (?,?,?,'其他',?,DATE '2020-01-01','active','regular')
                """, id, code, name, department);
        return id;
    }
}
