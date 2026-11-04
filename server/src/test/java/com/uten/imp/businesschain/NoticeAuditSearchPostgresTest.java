package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;

import java.util.HashSet;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/** The dedicated directories retain their own recipients/historical actor authority before paging. */
class NoticeAuditSearchPostgresTest extends AuthSessionPostgresTestSupport {
    @Test void noticePagesKeepOnlyCurrentEnabledRecipientsAndFindAncestorWords() throws Exception {
        String suffix = UUID.randomUUID().toString().substring(0, 8);
        UUID parent = department("通知祖先_%\\" + suffix, baseDepartment(), "二级班组");
        UUID leaf = department("通知叶部门" + suffix, parent, "三级科室");
        String name = "通知人员" + suffix;
        for (int index = 0; index < 21; index++) employee(leaf, name + index, true, "active");
        employee(leaf, name + "无账号", false, "active");
        UUID disabled = employee(leaf, name + "停用", true, "active");
        jdbc.update("UPDATE users SET status='disabled' WHERE employee_id=?", disabled);
        employee(leaf, name + "离职", true, "resigned");
        String token = adminToken();
        Set<String> found = new HashSet<>();
        for (int page = 1; page <= 2; page++) {
            JsonNode result = request(token, get("/api/notices/audience/employees/page")
                    .param("search", "通知祖先_%\\" + suffix + " " + name)
                    .param("departmentId", parent.toString()).param("includeSubtree", "true")
                    .param("page", Integer.toString(page)).param("size", "20"));
            assertEquals(21, result.path("total").asInt());
            assertEquals(2, result.path("totalPages").asInt());
            result.path("items").forEach(row -> {
                found.add(row.path("id").asText());
                assertEquals("active", row.path("accountStatus").asText());
                assertEquals("active", row.path("employmentStatus").asText());
            });
        }
        assertEquals(21, found.size());
        assertEquals(0, request(token, get("/api/notices/audience/employees/page").param("search", name)
                .param("departmentId", parent.toString())).path("total").asInt());
        // Empty input is also a real paged query, not a missing department-path alias.
        assertEquals(21, request(token, get("/api/notices/audience/employees/page")
                .param("departmentId", leaf.toString()).param("size", "1")).path("total").asInt());
        Employee viewer = newEmployee(token, "DEPT_ENG");
        MvcResult denied = mvc.perform(get("/api/notices/audience/employees/page")
                .header("Authorization", "Bearer " + viewer.accessToken())).andReturn();
        assertEquals(403, denied.getResponse().getStatus(), body(denied));
    }

    @Test void auditActorPagesRetainDeletedStaffAndBlockedVisitorsWithExplicitUnassignedFilter() throws Exception {
        String suffix = UUID.randomUUID().toString().substring(0, 8);
        UUID employee = employee(baseDepartment(), "历史审计" + suffix, true, "resigned");
        UUID staff = jdbc.queryForObject("SELECT id FROM users WHERE employee_id=?", UUID.class, employee);
        jdbc.update("UPDATE users SET is_deleted=true,status='disabled' WHERE id=?", staff);
        UUID visitor = UUID.randomUUID();
        String hash = visitor.toString().replace("-", "").repeat(2);
        String visitorNo = "V" + String.format("%08d", (visitor.getLeastSignificantBits() & 0x7fffffffL) % 100000000);
        jdbc.update("""
                INSERT INTO visitor_accounts(id,phone_enc,phone_hash,name,visitor_no,status)
                VALUES (?,encode(pgp_sym_encrypt('13900000001','auth-session-pgp-key-0123456789-test-only'),'base64'),?,?,?,'blocked')
                """, visitor, hash, "审计访客" + suffix, visitorNo);
        String token = adminToken();
        JsonNode historical = request(token, get("/api/admin/audit-logs/actors").param("keyword", "历史审计" + suffix)
                .param("actorType", "staff").param("size", "1"));
        assertEquals(1, historical.path("total").asInt());
        assertEquals(staff.toString(), historical.path("items").get(0).path("actorId").asText());
        assertEquals("deleted", historical.path("items").get(0).path("accountStatus").asText());
        assertEquals("resigned", historical.path("items").get(0).path("employmentStatus").asText());
        JsonNode visitors = request(token, get("/api/admin/audit-logs/actors").param("keyword", suffix).param("actorType", "visitor"));
        assertEquals(1, visitors.path("total").asInt());
        assertEquals(visitor.toString(), visitors.path("items").get(0).path("actorId").asText());
        assertEquals("blocked", visitors.path("items").get(0).path("accountStatus").asText());
        assertFalse(visitors.toString().contains("phone_enc"));
        JsonNode unknown = request(token, get("/api/admin/audit-logs/actors").param("keyword", suffix).param("unassignedOnly", "true"));
        // Current schema requires users.employee_id; do not bypass that guard
        // to manufacture an unassigned account. Visitors must not leak into the staff-only bucket.
        assertEquals(0, unknown.path("total").asInt());
    }

    @Test void auditWordsAndDepartmentNarrowingAreAppliedBeforeStablePages() throws Exception {
        String suffix = UUID.randomUUID().toString().substring(0, 8);
        UUID parent = department("审计祖先_%\\" + suffix, baseDepartment(), "二级班组");
        UUID leaf = department("审计叶部门", parent, "三级科室");
        UUID employee = employee(leaf, "审计姓名" + suffix, true, "active");
        UUID actor = jdbc.queryForObject("SELECT id FROM users WHERE employee_id=?", UUID.class, employee);
        String token = adminToken();
        JsonNode found = request(token, get("/api/admin/audit-logs/actors")
                .param("keyword", "审计祖先_%\\" + suffix + " 审计姓名")
                .param("departmentId", parent.toString()).param("includeSubtree", "true").param("size", "1"));
        assertEquals(1, found.path("total").asInt());
        assertEquals(actor.toString(), found.path("items").get(0).path("actorId").asText());
        assertEquals(0, request(token, get("/api/admin/audit-logs/actors").param("keyword", suffix)
                .param("departmentId", parent.toString())).path("total").asInt());
        MvcResult invalid = mvc.perform(get("/api/admin/audit-logs/actors").param("actorType", "unknown")
                .header("Authorization", "Bearer " + token)).andReturn();
        assertEquals(422, invalid.getResponse().getStatus(), body(invalid));
        Employee viewer = newEmployee(token, "DEPT_ENG");
        MvcResult denied = mvc.perform(get("/api/admin/audit-logs/actors")
                .header("Authorization", "Bearer " + viewer.accessToken())).andReturn();
        assertEquals(403, denied.getResponse().getStatus(), body(denied));
    }

    private JsonNode request(String token, MockHttpServletRequestBuilder request) throws Exception {
        MvcResult result = mvc.perform(request.header("Authorization", "Bearer " + token)).andReturn();
        assertEquals(200, result.getResponse().getStatus(), body(result));
        assertNotNull(result.getResponse().getHeader("X-Uten-Read-Scope-Version"));
        return json(result);
    }

    private UUID baseDepartment() { return jdbc.queryForObject("SELECT id FROM departments WHERE code='DEPT_HR'", UUID.class); }

    private UUID department(String name, UUID parent, String level) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES (?,?,?,?,?)", id, "NOTICE-AUDIT-" + id, name, parent, level);
        return id;
    }

    private UUID employee(UUID department, String name, boolean account, String status) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES (?,?,?,'其他',?,DATE '2020-01-01',?,'regular')
                """, id, "NOTICE-AUDIT-" + id, name, department, status);
        if (account) jdbc.update("INSERT INTO users(employee_id,login_account,password_hash,must_change_password) VALUES (?,?,'unused-test',false)",
                id, "notice-audit-" + id);
        return id;
    }
}
