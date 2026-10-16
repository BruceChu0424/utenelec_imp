package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.org.department.WorkforceOverviewQuery;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.dao.DataAccessException;
import org.springframework.test.web.servlet.MvcResult;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;

/** 员工测试反馈的完整 HTTP→权限→事务→不可变历史→统计回归，使用独立 Testcontainers 数据库。 */
class EmployeeFeedbackPostgresTest extends AuthSessionPostgresTestSupport {
    @Autowired WorkforceOverviewQuery workforce;

    @Test
    void accountSearchFindsEmployeeNameAndCodeWhileRetainingLoginAndStatusFilters() throws Exception {
        String token = adminToken();
        Fixture target = fixture("姓名查询回归", true);
        for (String keyword : List.of(target.name(), target.code().toLowerCase(), target.login())) {
            JsonNode result = accountSearch(token, keyword, null);
            assertEquals(1, result.path("total").asInt(), result.toString());
            assertEquals(target.id().toString(), result.path("items").get(0).path("employeeId").asText());
        }
        assertEquals(0, accountSearch(token, target.name(), "locked").path("total").asInt());
        assertEquals(0, accountSearch(token, "__%", null).path("total").asInt(), "通配符按字面搜索");
        jdbc.update("UPDATE users SET is_deleted=true WHERE employee_id=?", target.id());
        assertEquals(0, accountSearch(adminToken(), target.name(), null).path("total").asInt());
    }

    @Test
    void correctionPreservesOriginalHistoryAuditsTheChangeAndMovesTheStatisticalHireDate() throws Exception {
        String token = adminToken();
        Fixture target = fixture("日期更正", false);
        LocalDate start = BusinessTime.today().minusMonths(6);
        var before = workforce.load(target.department(), start, BusinessTime.today());
        LocalDate corrected = target.hired().minusYears(1);
        MvcResult saved = update(token, target.id(), correction(target.hired(), corrected));
        assertEquals(200, saved.getResponse().getStatus(), body(saved));
        assertEquals(corrected.toString(), json(saved).path("hireDate").asText());
        assertEquals(target.hired(), date("SELECT event_date FROM employment_history WHERE id=?", target.onboard()));
        assertEquals(corrected, date("SELECT event_date FROM employment_history_effective WHERE id=?", target.onboard()));
        assertEquals(1, count("SELECT count(*) FROM employment_history WHERE employee_id=? AND event_type='onboard'", target.id()));
        assertEquals(1, count("SELECT count(*) FROM employment_history WHERE corrects_history_id=? AND event_type='hire_date_correction'", target.onboard()));
        assertEquals(before.hired()-1, workforce.load(target.department(), start, BusinessTime.today()).hired());
        assertTrue(count("SELECT count(*) FROM audit_log WHERE target_type='employees' AND target_id=? AND actor_id IS NOT NULL", target.id().toString()) > 0);
        assertTrue(count("SELECT count(*) FROM audit_log WHERE target_type='employment_history' AND target_id IN (SELECT id::text FROM employment_history WHERE corrects_history_id=?) AND actor_id IS NOT NULL", target.onboard()) > 0);
        // 原请求安全重试，不追加第二条更正，也不改变任职代次。
        assertEquals(200, update(token, target.id(), correction(target.hired(), corrected)).getResponse().getStatus());
        assertEquals(1, count("SELECT count(*) FROM employment_history WHERE corrects_history_id=?", target.onboard()));
        assertEquals(0, count("SELECT count(*) FROM employment_history WHERE employee_id=? AND event_type='rehire'", target.id()));
    }

    @Test
    void invalidLaterPartOfTheSameEditRollsBackProfileHistoryAndAuditTogether() throws Exception {
        String token = adminToken();
        Fixture target = fixture("事务回滚", false);
        Map<String,Object> request = correction(target.hired(), target.hired().minusDays(3));
        request.put("fullName", "不应保存的姓名");
        request.put("vehicles", List.of(Map.of("plateNo", "invalid?")));
        long auditBefore = count("SELECT count(*) FROM audit_log WHERE target_type='employees' AND target_id=?", target.id().toString());
        MvcResult failed = update(token, target.id(), request);
        assertEquals(422, failed.getResponse().getStatus(), body(failed));
        assertEquals(target.hired(), date("SELECT hire_date FROM employees WHERE id=?", target.id()));
        assertEquals(target.name(), jdbc.queryForObject("SELECT full_name FROM employees WHERE id=?", String.class, target.id()));
        assertEquals(0, count("SELECT count(*) FROM employment_history WHERE corrects_history_id=?", target.onboard()));
        assertEquals(auditBefore, count("SELECT count(*) FROM audit_log WHERE target_type='employees' AND target_id=?", target.id().toString()));
    }

    @Test
    void rejectsFutureAfterConfirmationAfterEmploymentEventsAndMissingReasonWithoutWriting() throws Exception {
        String token = adminToken();
        Fixture target = fixture("日期边界", false);
        assertRejected(token, target, correction(target.hired(), BusinessTime.today().plusDays(1)), 422);
        jdbc.update("UPDATE employees SET confirmed_at=? WHERE id=?", target.hired(), target.id());
        assertRejected(token, target, correction(target.hired(), target.hired().plusDays(1)), 422);
        jdbc.update("UPDATE employees SET confirmed_at=NULL WHERE id=?", target.id());
        jdbc.update("INSERT INTO employment_history(employee_id,event_type,event_date) VALUES (?,'transfer',?)", target.id(), target.hired().minusDays(1));
        assertRejected(token, target, correction(target.hired(), target.hired().plusDays(1)), 422);
        Map<String,Object> noReason = correction(target.hired(), target.hired().minusDays(2));
        noReason.remove("hireDateChangeReason");
        assertRejected(token, target, noReason, 422);
        assertRejected(token, target, correction(target.hired().minusDays(1), target.hired().minusDays(3)), 409);
        assertEquals(0, count("SELECT count(*) FROM employment_history WHERE corrects_history_id=?", target.onboard()));
    }

    @Test
    void concurrentCorrectionsWithTheSameBaselineCommitOnlyOne() throws Exception {
        String token = adminToken();
        Fixture target = fixture("并发日期", false);
        CountDownLatch start = new CountDownLatch(1);
        List<CompletableFuture<Integer>> requests = new ArrayList<>();
        for (int days : List.of(3, 4)) {
            requests.add(CompletableFuture.supplyAsync(() -> {
                try {
                    start.await(10, TimeUnit.SECONDS);
                    return update(token, target.id(), correction(target.hired(), target.hired().minusDays(days)))
                            .getResponse().getStatus();
                } catch (Exception error) { throw new RuntimeException(error); }
            }));
        }
        start.countDown();
        List<Integer> statuses = new ArrayList<>();
        for (var request : requests) statuses.add(request.get(45, TimeUnit.SECONDS));
        statuses.sort(Integer::compareTo);
        assertEquals(List.of(200,409), statuses);
        assertEquals(1, count("SELECT count(*) FROM employment_history WHERE corrects_history_id=?", target.onboard()));
    }

    @Test
    void ordinaryEmployeeCannotCorrectAnotherEmployeeAndHistoryRemainsAppendOnly() throws Exception {
        String admin = adminToken();
        Fixture target = fixture("权限边界", false);
        Employee ordinary = newEmployee(admin, "DEPT_ENG");
        assertRejected(ordinary.accessToken(), target, correction(target.hired(), target.hired().minusDays(1)), 403);
        assertThrows(DataAccessException.class, () -> jdbc.update(
                "UPDATE employment_history SET event_date=? WHERE id=?", target.hired().minusDays(1), target.onboard()));
        Fixture other = fixture("来源边界", false);
        assertThrows(DataAccessException.class, () -> jdbc.update(
                "INSERT INTO employment_history(employee_id,event_type,event_date,corrects_history_id) VALUES (?,'hire_date_correction',?,?)",
                target.id(), target.hired().minusDays(1), other.onboard()));
    }

    @Test
    void correctionKeepsEveryReemploymentGenerationAndEventDateIntact() throws Exception {
        String token=adminToken();
        Fixture target=fixture("复职日期",false);
        LocalDate resigned=target.hired().plusDays(1), rehired=target.hired().plusDays(2);
        jdbc.update("INSERT INTO employment_history(employee_id,event_type,from_dept_id,event_date) VALUES (?,'resign',?,?)",target.id(),target.department(),resigned);
        jdbc.update("INSERT INTO employment_history(employee_id,event_type,to_dept_id,event_date) VALUES (?,'rehire',?,?)",target.id(),target.department(),rehired);
        var before=workforce.load(target.department(),BusinessTime.today().minusMonths(6),BusinessTime.today());
        assertEquals(200,update(token,target.id(),correction(target.hired(),target.hired().minusYears(1))).getResponse().getStatus());
        assertEquals(resigned,date("SELECT event_date FROM employment_history WHERE employee_id=? AND event_type='resign'",target.id()));
        assertEquals(rehired,date("SELECT event_date FROM employment_history WHERE employee_id=? AND event_type='rehire'",target.id()));
        assertEquals(1,count("SELECT count(*) FROM employment_history WHERE employee_id=? AND event_type='rehire'",target.id()));
        var after=workforce.load(target.department(),BusinessTime.today().minusMonths(6),BusinessTime.today());
        assertEquals(before.hired()-1,after.hired());
        assertEquals(before.rehired(),after.rehired());
        assertEquals(before.departed(),after.departed());
    }

    @Test
    void importedEmployeeWithoutOnboardHistoryCanBeCorrectedWithoutInventingAnOnboard() throws Exception {
        String token=adminToken();
        Fixture target=fixture("缺历史导入",false,false);
        LocalDate corrected=target.hired().minusDays(3);
        assertEquals(200,update(token,target.id(),correction(target.hired(),corrected)).getResponse().getStatus());
        assertEquals(0,count("SELECT count(*) FROM employment_history_effective WHERE employee_id=?",target.id()));
        assertEquals(1,count("SELECT count(*) FROM employment_history WHERE employee_id=? AND event_type='hire_date_correction' AND corrects_history_id IS NULL",target.id()));
        assertTrue(workforce.load(target.department(),BusinessTime.today().minusMonths(6),BusinessTime.today()).missingHistory()>0);
    }

    @Test
    void ambiguousMultipleOnboardEventsRejectCorrectionWithoutChoosingAHistory() throws Exception {
        String token=adminToken();
        Fixture target=fixture("历史歧义",false);
        jdbc.update("INSERT INTO employment_history(employee_id,event_type,event_date) VALUES (?,'onboard',?)",target.id(),target.hired());
        assertRejected(token,target,correction(target.hired(),target.hired().minusDays(3)),409);
        assertEquals(0,count("SELECT count(*) FROM employment_history WHERE corrects_history_id=?",target.onboard()));
    }

    @Test
    void lifecycleChronologyUsesLatestEffectiveEventAfterCorrectingAnOriginallyLaterOnboard() throws Exception {
        String token=adminToken();
        Fixture target=fixture("有效事件排序",false);
        LocalDate transferDate=target.hired().minusMonths(2);
        jdbc.update("INSERT INTO employment_history(employee_id,event_type,to_dept_id,event_date) VALUES (?,'transfer',?,?)",target.id(),target.department(),transferDate);
        assertEquals(200,update(token,target.id(),correction(target.hired(),target.hired().minusYears(1))).getResponse().getStatus());
        var request=json(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post("/api/org/employees/"+target.id()+"/transfer"),
                Map.of("toDepartmentId",target.department().toString(),"effectiveDate",transferDate.minusDays(1).toString()),token);
        MvcResult result=mvc.perform(request).andReturn();
        assertEquals(422,result.getResponse().getStatus(),body(result));
        assertTrue(body(result).contains(transferDate.toString()),body(result));
        assertEquals(1,count("SELECT count(*) FROM employment_history WHERE employee_id=? AND event_type='transfer'",target.id()));
    }

    private JsonNode accountSearch(String token, String query, String status) throws Exception {
        var request = get("/api/admin/users").param("search", query).header("Authorization", "Bearer "+token);
        if (status != null) request.param("status", status);
        MvcResult result = mvc.perform(request).andReturn();
        assertEquals(200,result.getResponse().getStatus(),body(result));
        return json(result);
    }

    private MvcResult update(String token, UUID id, Map<String,Object> request) throws Exception {
        return mvc.perform(json(put("/api/org/employees/"+id), request, token)).andReturn();
    }

    private static Map<String,Object> correction(LocalDate expected, LocalDate corrected) {
        return new java.util.HashMap<>(Map.of("hireDate",corrected.toString(),"expectedHireDate",expected.toString(),
                "hireDateChangeReason","核对纸质入职档案后更正"));
    }

    private void assertRejected(String token, Fixture target, Map<String,Object> request, int status) throws Exception {
        MvcResult result = update(token,target.id(),request);
        assertEquals(status,result.getResponse().getStatus(),body(result));
        assertEquals(target.hired(),date("SELECT hire_date FROM employees WHERE id=?",target.id()));
    }

    private Fixture fixture(String name, boolean account) {
        return fixture(name,account,true);
    }
    private Fixture fixture(String name, boolean account, boolean hasHistory) {
        UUID id=UUID.randomUUID(), onboard=UUID.randomUUID();
        String code="HRFB-"+id, login="hrfb-"+id;
        String fullName=name+id.toString().substring(0,8);
        UUID department=jdbc.queryForObject("SELECT id FROM departments WHERE code='DEPT_HR'",UUID.class);
        LocalDate hired=BusinessTime.today().minusDays(2);
        jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES (?,?,?,'其他',?,?,'probation','regular')
                """,id,code,fullName,department,hired);
        if(hasHistory) jdbc.update("INSERT INTO employment_history(id,employee_id,event_type,to_dept_id,event_date) VALUES (?,?,'onboard',?,?)",onboard,id,department,hired);
        if(account) jdbc.update("INSERT INTO users(employee_id,login_account,password_hash,must_change_password) VALUES (?,?,'unused-test',false)",id,login);
        return new Fixture(id,onboard,department,hired,fullName,code,login);
    }
    private LocalDate date(String sql,Object arg) { return jdbc.queryForObject(sql,LocalDate.class,arg); }
    private long count(String sql,Object arg) { return jdbc.queryForObject(sql,Long.class,arg); }
    private record Fixture(UUID id,UUID onboard,UUID department,LocalDate hired,String name,String code,String login) {}
}
