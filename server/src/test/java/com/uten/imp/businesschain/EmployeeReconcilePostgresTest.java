package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.features.org.employee.reconcile.ReconcilePlanHousekeeping;
import com.uten.imp.features.org.employee.reconcile.ReconcilePlanStore;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * 员工资料批量核对更正 (V810/ADR-160) 的真库全链路：真 PostgreSQL + 完整安全过滤链 + 真实账号切换。
 * 证件核对页多选 → POST id-repair 生成计划 (服务端解密 + IdRepairAdvisor 建议 + 密文落库) →
 * GET 计划视图 (无 pii:view 打码) → @RequiresStepUp 再认证后逐人执行 changeIdentity →
 * 结果/审计/认领回写；过期清理、卡死回收、隔离与幂等由本类逐场景钉死。
 *
 * <p>所有证件号都是编造夹具（照 {@link EmployeeIdentityReviewPostgresTest} 的 withChecksum 现算），
 * 测试与断言消息都不把证件号写进日志。</p>
 */
class EmployeeReconcilePostgresTest extends AuthSessionPostgresTestSupport {

    private static final String STEP_UP_HEADER = "X-Uten-Step-Up";
    private static final String CHECK_DIGIT_REASON =
            "身份证号第18位校验码与前17位不符，通常是某一位数字录错或相邻两位颠倒，请对照证件逐位核对";
    private static final String SEQUENCE_ZERO_NOTE = "顺序码是 000，请对照证件";
    private static final String CIPHER_UNREADABLE_NOTE = "证件密文无法解密，需人工重新录入";
    private static final String NOT_RESIDENT_ID_NOTE = "证件类型不是身份证，本次不自动修复";
    private static final String SUPER_ADMIN_NOTE = "该员工绑定超级管理员账号，请单独修改";
    private static final String ALREADY_VALID_NOTE = "证件号已通过校验，无需核对";
    private static final String MISSING_IDENTITY_NOTE = "证件号未填写";
    private static final String DUPLICATE_IDENTITY_PREFIX = "该证件号码已被其他员工使用";

    @Autowired
    TxSessionVars tx;
    @Autowired
    PlatformTransactionManager transactionManager;
    @Autowired
    ReconcilePlanHousekeeping housekeeping;
    @Autowired
    ReconcilePlanStore reconcileStore;

    // ------------------------------------------------------------------
    // 1 + 2. 数据准备：十种存量档案 → 生成计划 → 行/项/统计/明文边界
    // ------------------------------------------------------------------

    @Test
    void idRepairPlanRowsKindsValuesAndNoticesMatchTheStoredIdentities() throws Exception {
        String admin = adminToken();
        Employee hr = newEmployee(admin, "DEPT_HR");
        Employee hr2 = newEmployee(admin, "DEPT_HR");
        int salt = ThreadLocalRandom.current().nextInt(100, 999);

        // 校验码错一位：造真号后改一位（会被另一人事认领）。
        String claimedCorrect = withChecksum("44200019850615" + String.format("%03d", salt));
        String claimedWrong = wrongCheckVariant(claimedCorrect);
        UUID claimed = legacyEmployee("V810-A-01", "核对甲一", "身份证", claimedWrong, phone(1, 1));
        // 密文故意写坏：当前版本前缀 + 非 PGP 正文。
        UUID unreadable = legacyEmployeeWithCipher("V810-A-02", "核对甲二", corruptCipher(), phone(1, 2));
        // 15 位老证号：升位候选必为 withChecksum(前 6 位 + 19 + 后 9 位)。
        String fifteen = "442000" + "850615" + String.format("%03d", (salt + 123) % 900 + 30);
        UUID fifteenId = legacyEmployee("V810-A-03", "核对甲三", "身份证", fifteen, phone(1, 3));
        String fifteenUpgraded = withChecksum("44200019" + "850615"
                + fifteen.substring(fifteen.length() - 3));
        // 多敲一位 (19 位)：把第 10 位复制一份，删除重复位的候选排第一。
        String nineteenBase = validWithoutAdjacentRepeat(REPEAT_FREE_PREFIX, salt + 321);
        String nineteen = nineteenBase.substring(0, 10) + nineteenBase.charAt(9) + nineteenBase.substring(10);
        UUID nineteenId = legacyEmployee("V810-A-04", "核对甲四", "身份证", nineteen, phone(1, 4));
        // 护照：证件类型不是身份证。
        UUID passport = legacyEmployee("V810-A-05", "核对甲五", "护照", "E" + (200000000 + salt), phone(1, 5));
        // 顺序码 000：90 种填法都过校验，无候选。
        UUID sequenceZero = legacyEmployee("V810-A-06", "核对甲六", "身份证", "44200019900307000X", phone(1, 6));
        // 含空格分隔符：去分隔符候选排第一。
        String spaceyValid = withChecksum("44200019901130" + String.format("%03d", (salt + 612) % 900 + 30));
        String spacey = spaceyValid.substring(0, 6) + " " + spaceyValid.substring(6, 14)
                + " " + spaceyValid.substring(14);
        UUID spaceyId = legacyEmployee("V810-A-07", "核对甲七", "身份证", spacey, phone(1, 7));
        // 绑超管账号的员工：不走批量更正。
        UUID superAdminBound = legacyEmployee("V810-A-08", "核对甲八", "身份证",
                wrongCheckVariant(withChecksum("44200019901231" + String.format("%03d", salt))), phone(1, 8));
        bindSuperAdminAccount(superAdminBound, salt);
        // 证号完全正确。
        UUID alreadyValid = legacyEmployee("V810-A-09", "核对甲九", "身份证",
                withChecksum("44200019901010" + String.format("%03d", salt)), phone(1, 9));
        // 没有证件号的存量档案。
        UUID missing = legacyEmployee("V810-A-10", "核对甲十", "身份证", null, phone(1, 10));

        // 多选顺序故意打乱：行号由服务端按工号排序决定。
        List<UUID> shuffled = Arrays.asList(passport, claimed, alreadyValid, fifteenId, spaceyId,
                unreadable, missing, sequenceZero, superAdminBound, nineteenId);
        MvcResult created = mvc.perform(json(post("/api/org/employee-reconcile/plans/id-repair"),
                Map.of("employeeIds", shuffled), hr.accessToken())).andReturn();
        assertEquals(200, created.getResponse().getStatus(), body(created));
        JsonNode view = json(created);
        UUID planId = UUID.fromString(view.path("id").asText());

        // 另一人事认领其中一人：认领展示是实时查询，之后 GET 再断言。
        ok(json(post("/api/org/hr-tasks/claims"),
                Map.of("taskType", "identity", "employeeId", claimed.toString()), hr2.accessToken()));

        // ---- 计划头：统计与行分布 ----
        assertEquals("OPEN", view.path("status").asText());
        assertNull(view.path("closedReason").asText(null));
        assertEquals("ID_REPAIR", view.path("source").asText());
        assertEquals("PAGE", view.path("origin").asText());
        assertTrue(view.path("canApply").asBoolean());
        assertTrue(view.path("readOnlyReason").isNull() || view.path("readOnlyReason").isMissingNode());
        assertEquals(employeeName(hr), view.path("actorName").asText());
        assertTrue(view.path("capabilities").path("viewPii").asBoolean());
        assertTrue(view.path("capabilities").path("piiEdit").asBoolean());
        JsonNode counts = view.path("counts");
        assertEquals(10, counts.path("rows").asInt());
        assertEquals(6, counts.path("update").asInt());
        assertEquals(6, counts.path("updateItems").asInt());
        assertEquals(3, counts.path("info").asInt());
        assertEquals(1, counts.path("same").asInt());
        assertEquals(0, counts.path("applied").asInt());
        assertEquals(0, counts.path("skipped").asInt());
        assertEquals(0, counts.path("failed").asInt());
        // 行按工号排序、行号从 1 连续编号。
        for (int i = 0; i < 10; i++) {
            JsonNode row = view.path("rows").get(i);
            assertEquals(i + 1, row.path("rowNo").asInt());
            assertEquals(String.format("V810-A-%02d", i + 1), row.path("employee").path("code").asText());
            assertEquals("核对甲" + "一二三四五六七八九十".charAt(i), row.path("employee").path("name").asText());
        }

        // ---- UPDATE 行：旧值/新值/依据/档位 ----
        JsonNode fifteenRow = rowOf(view, fifteenId);
        assertEquals("UPDATE", fifteenRow.path("kind").asText());
        assertEquals("身份证号应为18位，当前为15位", fifteenRow.path("reason").asText());
        JsonNode fifteenItem = fifteenRow.path("items").get(0);
        assertEquals(1, fifteenItem.path("itemNo").asInt());
        assertEquals(fifteen, fifteenItem.path("oldValue").asText());
        assertEquals(fifteenUpgraded, fifteenItem.path("newValue").asText());
        assertEquals("UPGRADE15", fifteenItem.path("basis").path("code").asText());
        assertEquals("15位升18位", fifteenItem.path("basis").path("label").asText());
        assertEquals("HIGH", fifteenItem.path("tier").asText());
        assertTrue(fifteenItem.path("preselected").asBoolean());
        assertTrue(fifteenItem.path("probability").asDouble() >= 0.9);
        assertTrue(fifteenItem.path("candidates").size() >= 1);
        assertEquals(fifteenUpgraded, fifteenItem.path("candidates").get(0).path("value").asText());

        JsonNode spaceyRow = rowOf(view, spaceyId);
        assertEquals("UPDATE", spaceyRow.path("kind").asText());
        assertEquals("身份证号应为18位，当前为20位", spaceyRow.path("reason").asText());
        JsonNode spaceyItem = spaceyRow.path("items").get(0);
        assertEquals(spacey, spaceyItem.path("oldValue").asText());
        assertEquals(spaceyValid, spaceyItem.path("newValue").asText());
        assertEquals("NORMALIZE", spaceyItem.path("basis").path("code").asText());
        assertEquals("去分隔符", spaceyItem.path("basis").path("label").asText());
        assertEquals("HIGH", spaceyItem.path("tier").asText());
        assertTrue(spaceyItem.path("preselected").asBoolean());

        JsonNode claimedRow = rowOf(view, claimed);
        assertEquals("UPDATE", claimedRow.path("kind").asText());
        assertEquals(CHECK_DIGIT_REASON, claimedRow.path("reason").asText());
        JsonNode claimedItem = claimedRow.path("items").get(0);
        assertEquals(claimedWrong, claimedItem.path("oldValue").asText());
        assertFalse(claimedItem.path("newValue").asText().isBlank());
        assertTrue(claimedItem.path("candidates").size() >= 1);
        assertTrue(claimedItem.path("suspectPositions").size() >= 1, "manual rows point out suspect positions");

        JsonNode nineteenRow = rowOf(view, nineteenId);
        assertEquals("UPDATE", nineteenRow.path("kind").asText());
        assertEquals("身份证号应为18位，当前为19位", nineteenRow.path("reason").asText());
        JsonNode nineteenItem = nineteenRow.path("items").get(0);
        assertEquals(nineteen, nineteenItem.path("oldValue").asText());
        assertEquals("DEL_REPEAT", nineteenItem.path("basis").path("code").asText());
        assertEquals("删除重复数字", nineteenItem.path("basis").path("label").asText());
        assertEquals(nineteenBase, nineteenItem.path("newValue").asText());
        assertEquals(nineteenBase, nineteenItem.path("candidates").get(0).path("value").asText());

        // 顺序码 000：UPDATE 行但无候选，提示放在 notes 里等人对照证件。
        JsonNode sequenceRow = rowOf(view, sequenceZero);
        assertEquals("UPDATE", sequenceRow.path("kind").asText());
        assertEquals("身份证号第15-17位顺序码不能全为0", sequenceRow.path("reason").asText());
        JsonNode sequenceItem = sequenceRow.path("items").get(0);
        assertEquals("44200019900307000X", sequenceItem.path("oldValue").asText());
        assertTrue(sequenceItem.path("newValue").isNull() || sequenceItem.path("newValue").isMissingNode());
        assertEquals("NONE", sequenceItem.path("tier").asText());
        assertEquals(0, sequenceItem.path("candidates").size());
        assertTrue(sequenceItem.path("notes").toString().contains(SEQUENCE_ZERO_NOTE));

        // 没有证件号：旧值/新值都为空，notes 提示「证件号未填写」。
        JsonNode missingRow = rowOf(view, missing);
        assertEquals("UPDATE", missingRow.path("kind").asText());
        assertTrue(missingRow.path("reason").isNull() || missingRow.path("reason").isMissingNode());
        JsonNode missingItem = missingRow.path("items").get(0);
        assertTrue(missingItem.path("oldValue").isNull() || missingItem.path("oldValue").isMissingNode());
        assertTrue(missingItem.path("newValue").isNull() || missingItem.path("newValue").isMissingNode());
        assertTrue(missingItem.path("notes").toString().contains(MISSING_IDENTITY_NOTE));

        // ---- INFO / SAME 行：items 为空，notices 给原因 ----
        assertInfoRow(view, unreadable, "CIPHER_UNREADABLE", CIPHER_UNREADABLE_NOTE);
        assertInfoRow(view, passport, "NOT_RESIDENT_ID", NOT_RESIDENT_ID_NOTE);
        assertInfoRow(view, superAdminBound, "SUPER_ADMIN_BOUND", SUPER_ADMIN_NOTE);
        JsonNode sameRow = rowOf(view, alreadyValid);
        assertEquals("SAME", sameRow.path("kind").asText());
        assertEquals(0, sameRow.path("items").size());
        assertEquals("ALREADY_VALID", sameRow.path("notices").get(0).path("code").asText());
        assertEquals(ALREADY_VALID_NOTE, sameRow.path("notices").get(0).path("message").asText());

        // ---- 明文只出现在 oldValue/newValue/candidates 字段 ----
        String createdBody = body(created);
        assertTrue(createdBody.contains(fifteen) && createdBody.contains(spacey)
                && createdBody.contains(nineteen));
        assertNoIdentityDigits(createdBody, claimedWrong, claimedCorrect, fifteen, fifteenUpgraded,
                nineteen, nineteenBase, spacey, spaceyValid, "44200019900307000X");

        // ---- 认领：另一人事处理中 ----
        JsonNode fetched = ok(get("/api/org/employee-reconcile/plans/" + planId), hr.accessToken());
        JsonNode claim = rowOf(fetched, claimed).path("claim");
        assertEquals(employeeName(hr2), claim.path("byName").asText());
        assertFalse(claim.path("byMe").asBoolean());
        assertFalse(claim.path("leaseUntil").isNull() || claim.path("leaseUntil").isMissingNode());
    }

    // ------------------------------------------------------------------
    // 3. 权限矩阵：打码 / 403 / 404 / 401 / 缺再认证
    // ------------------------------------------------------------------

    @Test
    void permissionMatrixMasksWithoutPiiViewAndRejectsWithoutPiiEdit() throws Exception {
        // 先造「无 pii:view 的人事」：写入个人覆盖会推进全局授权纪元 (V315 语句触发器)，
        // 之前签发的所有令牌随之作废，所以其余账号一律在覆盖之后再建、再登。
        Employee revoked = newEmployee(adminToken(), "DEPT_HR");
        jdbc.update("""
                INSERT INTO user_permission_overrides (user_id, permission_id, effect)
                SELECT ?, id, 'revoke' FROM permissions WHERE code = 'employee:pii:view'
                """, UUID.fromString(revoked.userId()));
        String admin = adminToken();
        Employee hr = newEmployee(admin, "DEPT_HR");
        Employee gm = newEmployee(admin, "GM");
        String noPiiViewToken = login(revoked.loginAccount(), EMPLOYEE_PASSWORD)
                .path("accessToken").asText();
        int salt = ThreadLocalRandom.current().nextInt(100, 999);
        String fifteen = "442000" + "850615" + String.format("%03d", (salt + 233) % 900 + 30);
        UUID employee = legacyEmployee("V810-B-01", "核对乙一", "身份证", fifteen, phone(2, 1));
        String upgraded = withChecksum("44200019" + "850615"
                + fifteen.substring(fifteen.length() - 3));

        JsonNode view = createPlan(hr, List.of(employee));
        UUID planId = UUID.fromString(view.path("id").asText());
        int rowNo = rowOf(view, employee).path("rowNo").asInt();

        // 无 pii:view 的人事 (有 employee:edit)：可读他人计划，但全部值打码、位置与候选清空。
        MvcResult masked = mvc.perform(auth(get("/api/org/employee-reconcile/plans/" + planId),
                noPiiViewToken))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.capabilities.viewPii").value(false))
                .andExpect(jsonPath("$.capabilities.piiEdit").value(true))
                .andExpect(jsonPath("$.canApply").value(false))
                .andExpect(jsonPath("$.rows[0].items[0].oldValue").value("****" + fifteen.substring(11)))
                .andExpect(jsonPath("$.rows[0].items[0].newValue").value("****" + upgraded.substring(14)))
                .andExpect(jsonPath("$.rows[0].items[0].diffPositions").isEmpty())
                .andExpect(jsonPath("$.rows[0].items[0].suspectPositions").isEmpty())
                .andExpect(jsonPath("$.rows[0].items[0].candidates").isEmpty())
                .andReturn();
        assertTrue(json(masked).path("readOnlyReason").asText().contains("只能查看"));
        assertNoIdentityDigits(body(masked), fifteen, upgraded);

        // 只有 employee:view 的总经办：生成计划 403 (缺 pii:edit)、列表 403 (缺 employee:edit)、
        // 单计划读取不暴露存在性 → 404。
        mvc.perform(json(post("/api/org/employee-reconcile/plans/id-repair"),
                Map.of("employeeIds", List.of(employee)), gm.accessToken()))
                .andExpect(status().isForbidden());
        mvc.perform(auth(get("/api/org/employee-reconcile/plans"), gm.accessToken()))
                .andExpect(status().isForbidden());
        mvc.perform(auth(get("/api/org/employee-reconcile/plans/" + planId), gm.accessToken()))
                .andExpect(status().isNotFound());

        // 未登录：401。
        mvc.perform(json(post("/api/org/employee-reconcile/plans/id-repair"),
                Map.of("employeeIds", List.of(employee)), null))
                .andExpect(status().isUnauthorized());

        // apply 不带再认证回执：403 REAUTH_REQUIRED（带一份合法行选择，确保不是 422 拦截）。
        mvc.perform(json(post("/api/org/employee-reconcile/plans/" + planId + "/apply"),
                applyBody(1, "never-reaches-business", rowNo), hr.accessToken()))
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.code").value("REAUTH_REQUIRED"));
    }

    // ------------------------------------------------------------------
    // 4. 执行链：建议 / 手输 / 候选三态 → 密文、校验、哈希、版本、派生字段、任务、审计、认领
    // ------------------------------------------------------------------

    @Test
    void applyRunsEachRowThroughChangeIdentityWithSuggestionManualAndCandidateValues() throws Exception {
        String admin = adminToken();
        Employee hr = newEmployee(admin, "DEPT_HR");
        int salt = ThreadLocalRandom.current().nextInt(100, 999);

        // 第 1 人：15 位升位 (HIGH 预选，直接采用建议值)。
        String fifteen = "442000" + "850615" + String.format("%03d", (salt + 456) % 900 + 30);
        UUID first = legacyEmployee("V810-C-01", "核对丙一", "身份证", fifteen, phone(3, 1));
        String firstExpected = withChecksum("44200019" + "850615"
                + fifteen.substring(fifteen.length() - 3));
        // 第 2 人：校验码错一位，人事对照证件手输真号。
        String secondCorrect = withChecksum("44200019900404" + String.format("%03d", salt));
        UUID second = legacyEmployee("V810-C-02", "核对丙二", "身份证",
                wrongCheckVariant(secondCorrect), phone(3, 2));
        // 第 3 人：多敲一位，从候选里选第一个 (删除重复数字)。
        String thirdBase = validWithoutAdjacentRepeat(REPEAT_FREE_PREFIX, salt + 789);
        String third = thirdBase.substring(0, 10) + thirdBase.charAt(9) + thirdBase.substring(10);
        UUID thirdEmployee = legacyEmployee("V810-C-03", "核对丙三", "身份证", third, phone(3, 3));

        JsonNode view = createPlan(hr, Arrays.asList(thirdEmployee, second, first));
        UUID planId = UUID.fromString(view.path("id").asText());
        int firstRow = rowOf(view, first).path("rowNo").asInt();
        int secondRow = rowOf(view, second).path("rowNo").asInt();
        int thirdRow = rowOf(view, thirdEmployee).path("rowNo").asInt();
        assertEquals(firstExpected, rowOf(view, first).path("items").get(0).path("newValue").asText());
        String thirdExpected = rowOf(view, thirdEmployee).path("items").get(0)
                .path("candidates").get(0).path("value").asText();
        Map<UUID, Integer> versionAtPlan = planEmployeeVersions(planId);
        assertEquals(versionAtPlan, currentEmployeeVersions(Arrays.asList(first, second, thirdEmployee)));

        // 本人认领第 1 人：更正成功后认领应释放。
        ok(json(post("/api/org/hr-tasks/claims"),
                Map.of("taskType", "identity", "employeeId", first.toString()), hr.accessToken()));

        long applyEventsBefore = countAudit("employee_reconcile.apply", null);
        JsonNode result = applyPlan(hr, planId, 1, "round-one", List.of(
                selection(firstRow, 1, null, null),
                selection(secondRow, 1, null, secondCorrect),
                selection(thirdRow, 1, 0, null)));
        assertEquals(2, result.path("planVersion").asInt());
        assertEquals(1, result.path("round").asInt());
        assertEquals(3, result.path("counts").path("applied").asInt(), result.toString());
        assertEquals(0, result.path("counts").path("skipped").asInt());
        assertEquals(0, result.path("counts").path("failed").asInt());
        assertEquals("已更正 3 人 3 处", result.path("summary").asText());
        for (JsonNode row : result.path("rows")) {
            assertEquals("APPLIED", row.path("result").asText());
            assertEquals("APPLIED", row.path("items").get(0).path("status").asText());
        }
        assertNoIdentityDigits(result.toString(), fifteen, firstExpected, third, thirdExpected);

        // ---- 数据库：密文解密 = 新值、校验 valid、哈希重算、版本 +1、派生字段重推 ----
        assertIdentityRewritten(first, firstExpected, versionAtPlan.get(first));
        assertIdentityRewritten(second, secondCorrect, versionAtPlan.get(second));
        assertIdentityRewritten(thirdEmployee, thirdExpected, versionAtPlan.get(thirdEmployee));

        // ---- 证件核对任务列表：三人都消失 ----
        JsonNode summary = ok(get("/api/org/hr-tasks/summary"), hr.accessToken());
        List<String> remaining = identityIds(summary);
        assertFalse(remaining.contains(first.toString()));
        assertFalse(remaining.contains(second.toString()));
        assertFalse(remaining.contains(thirdEmployee.toString()));

        // ---- 审计：计划创建 + 每人一条 apply，after 不带证件号 ----
        assertEquals(1, countAudit("employee_reconcile.plan_created", planId.toString()));
        assertEquals(applyEventsBefore + 3, countAudit("employee_reconcile.apply", null));
        for (UUID employeeId : List.of(first, second, thirdEmployee)) {
            List<String> afterTexts = jdbc.queryForList(
                    "SELECT after::text FROM audit_log WHERE action = 'employee_reconcile.apply' AND target_id = ?",
                    String.class, employeeId.toString());
            assertEquals(1, afterTexts.size(), "one apply audit event per employee");
            assertNoIdentityDigits(afterTexts.get(0), fifteen, firstExpected, secondCorrect, third,
                    thirdExpected);
        }

        // ---- 本人认领已释放 ----
        assertTrue(jdbc.queryForObject(
                "SELECT released_at IS NOT NULL FROM hr_task_claims WHERE task_type = 'identity' AND employee_id = ?",
                Boolean.class, first));

        // ---- 计划视图回读：行结果、项结果与来源三态 (appliedOrigin 只落库，不在视图里) ----
        JsonNode after = ok(get("/api/org/employee-reconcile/plans/" + planId), hr.accessToken());
        assertEquals(2, after.path("version").asInt());
        assertTrue(after.path("canApply").asBoolean());
        assertEquals(3, after.path("counts").path("applied").asInt());
        JsonNode firstAfter = rowOf(after, first).path("items").get(0);
        assertEquals("APPLIED", firstAfter.path("outcome").path("status").asText());
        assertEquals("SUGGESTED", appliedOrigin(planId, firstRow));
        assertEquals(firstExpected, firstAfter.path("newValue").asText());
        JsonNode secondAfter = rowOf(after, second).path("items").get(0);
        assertEquals("EDITED", appliedOrigin(planId, secondRow));
        assertEquals(secondCorrect, secondAfter.path("newValue").asText());
        JsonNode thirdAfter = rowOf(after, thirdEmployee).path("items").get(0);
        assertEquals("CANDIDATE", appliedOrigin(planId, thirdRow));
        assertEquals(thirdExpected, thirdAfter.path("newValue").asText());
        assertEquals("APPLIED", rowOf(after, first).path("result").path("status").asText());
        assertNoIdentityDigits(after.toString(), fifteen, firstExpected, secondCorrect, third, thirdExpected);
    }

    // ------------------------------------------------------------------
    // 5. 守卫：版本过期 / 证件号重复 / 他人认领
    // ------------------------------------------------------------------

    @Test
    void staleRowsDuplicateIdentityAndForeignClaimsAreIsolatedPerRow() throws Exception {
        String admin = adminToken();
        Employee hr = newEmployee(admin, "DEPT_HR");
        Employee hr2 = newEmployee(admin, "DEPT_HR");
        int salt = ThreadLocalRandom.current().nextInt(100, 999);

        String staleCorrect = withChecksum("44200019910303" + String.format("%03d", salt));
        String staleWrong = wrongCheckVariant(staleCorrect);
        UUID stale = legacyEmployee("V810-D-01", "核对丁一", "身份证", staleWrong, phone(4, 1));
        String fifteen = "442000" + "850615" + String.format("%03d", (salt + 678) % 900 + 30);
        UUID fine = legacyEmployee("V810-D-02", "核对丁二", "身份证", fifteen, phone(4, 2));
        String fineExpected = withChecksum("44200019" + "850615"
                + fifteen.substring(fifteen.length() - 3));
        String duplicateCorrect = withChecksum("44200019920202" + String.format("%03d", salt));
        String duplicateWrong = wrongCheckVariant(duplicateCorrect);
        UUID duplicate = legacyEmployee("V810-D-03", "核对丁三", "身份证", duplicateWrong, phone(4, 3));
        String claimedCorrect = withChecksum("44200019930101" + String.format("%03d", salt));
        UUID claimedByOther = legacyEmployee("V810-D-04", "核对丁四", "身份证",
                wrongCheckVariant(claimedCorrect), phone(4, 4));
        // 另一名员工已占用 duplicateCorrect。
        legacyEmployee("V810-D-05", "核对丁五", "身份证", duplicateCorrect, phone(4, 5));

        JsonNode view = createPlan(hr, Arrays.asList(claimedByOther, duplicate, fine, stale));
        UUID planId = UUID.fromString(view.path("id").asText());
        int staleRow = rowOf(view, stale).path("rowNo").asInt();
        int fineRow = rowOf(view, fine).path("rowNo").asInt();
        int duplicateRow = rowOf(view, duplicate).path("rowNo").asInt();
        int claimedRow = rowOf(view, claimedByOther).path("rowNo").asInt();

        // 生成计划后：另一账号 (超管) 改掉其中一人的证件号；另一人事认领另一人。
        String staleRewritten = withChecksum("44200019910404" + String.format("%03d", salt));
        MvcResult changed = mvc.perform(json(post("/api/org/employees/" + stale + "/change-identity"),
                Map.of("idType", "身份证", "idNumber", staleRewritten), admin)).andReturn();
        assertEquals(200, changed.getResponse().getStatus(), body(changed));
        ok(json(post("/api/org/hr-tasks/claims"),
                Map.of("taskType", "identity", "employeeId", claimedByOther.toString()), hr2.accessToken()));

        JsonNode result = applyPlan(hr, planId, 1, "guards", List.of(
                selection(staleRow, 1, null, null),
                selection(fineRow, 1, null, null),
                selection(duplicateRow, 1, null, duplicateCorrect),
                selection(claimedRow, 1, null, null)));
        assertEquals(1, result.path("counts").path("applied").asInt(), result.toString());
        assertEquals(2, result.path("counts").path("skipped").asInt());
        assertEquals(1, result.path("counts").path("failed").asInt());
        assertEquals("已更正 1 人 1 处，跳过 2 人（原因见结果列），失败 1 人（原因见结果列）",
                result.path("summary").asText());
        assertEquals("SKIPPED", rowResult(result, staleRow));
        assertEquals("APPLIED", rowResult(result, fineRow));
        assertEquals("FAILED", rowResult(result, duplicateRow));
        assertEquals("SKIPPED", rowResult(result, claimedRow));
        assertTrue(itemMessage(result, duplicateRow).contains(DUPLICATE_IDENTITY_PREFIX));

        // 数据库：被改走的人保持超管改的值；重复的人和被认领的人保持坏值；顺利的人已更正。
        assertEquals(staleRewritten, storedIdentity(stale));
        assertEquals(duplicateWrong, storedIdentity(duplicate));
        assertEquals(fineExpected, storedIdentity(fine));
        assertEquals(wrongCheckVariant(claimedCorrect), storedIdentity(claimedByOther));

        // 视图回读：守卫原因落在项结果上。
        JsonNode after = ok(get("/api/org/employee-reconcile/plans/" + planId), hr.accessToken());
        assertEquals("SKIPPED", rowOf(after, stale).path("result").path("status").asText());
        assertEquals("STALE_VERSION", rowOf(after, stale).path("items").get(0)
                .path("outcome").path("code").asText());
        assertEquals("CLAIMED_BY_OTHER", rowOf(after, claimedByOther).path("items").get(0)
                .path("outcome").path("code").asText());
        assertEquals("CONFLICT", rowOf(after, duplicate).path("items").get(0)
                .path("outcome").path("code").asText());
        assertTrue(rowOf(after, duplicate).path("items").get(0).path("outcome")
                .path("message").asText().contains(DUPLICATE_IDENTITY_PREFIX));
        assertNoIdentityDigits(after.toString(), staleWrong, staleRewritten, fifteen, fineExpected,
                duplicateCorrect, claimedCorrect);
    }

    // ------------------------------------------------------------------
    // 6. 幂等：同一 requestId 重放返回上次结果，不再写库
    // ------------------------------------------------------------------

    @Test
    void replayingTheSameRequestIdReturnsTheStoredResultWithoutWritingAgain() throws Exception {
        String admin = adminToken();
        Employee hr = newEmployee(admin, "DEPT_HR");
        int salt = ThreadLocalRandom.current().nextInt(100, 999);
        String fifteen = "442000" + "850615" + String.format("%03d", (salt + 890) % 900 + 30);
        UUID employee = legacyEmployee("V810-E-01", "核对戊一", "身份证", fifteen, phone(5, 1));
        String expected = withChecksum("44200019" + "850615"
                + fifteen.substring(fifteen.length() - 3));
        UUID employee2 = legacyEmployee("V810-E-02", "核对戊二", "身份证",
                wrongCheckVariant(withChecksum("44200019960606" + String.format("%03d", salt))), phone(5, 2));

        JsonNode view = createPlan(hr, Arrays.asList(employee, employee2));
        UUID planId = UUID.fromString(view.path("id").asText());
        JsonNode first = applyPlan(hr, planId, 1, "replay-me", List.of(
                selection(rowOf(view, employee).path("rowNo").asInt(), 1, null, null),
                selection(rowOf(view, employee2).path("rowNo").asInt(), 1, null, null)));
        assertEquals(2, first.path("counts").path("applied").asInt(), first.toString());
        int version = employeeVersion(employee);
        long applyEvents = countAudit("employee_reconcile.apply", null);

        JsonNode replay = applyPlan(hr, planId, first.path("planVersion").asInt(), "replay-me", List.of(
                selection(rowOf(view, employee).path("rowNo").asInt(), 1, null, null)));
        assertEquals(first.toString(), replay.toString(), "replay must return the stored result verbatim");

        assertEquals(version, employeeVersion(employee), "replay must not rewrite the employee");
        assertEquals(expected, storedIdentity(employee));
        assertEquals(1, jdbc.queryForObject(
                "SELECT count(*) FROM employee_reconcile_applies WHERE plan_id = ?", Integer.class, planId));
        assertEquals(applyEvents, countAudit("employee_reconcile.apply", null),
                "replay must not write new audit events");

        Employee other = newEmployee(admin, "DEPT_HR");
        mvc.perform(withStepUp(json(post("/api/org/employee-reconcile/plans/" + planId + "/apply"),
                applyBody(first.path("planVersion").asInt(), "replay-me", rowOf(view, employee).path("rowNo").asInt())),
                other.accessToken())).andExpect(status().isNotFound());
        mvc.perform(withStepUp(json(post("/api/org/employee-reconcile/plans/" + planId + "/apply"),
                applyBody(first.path("planVersion").asInt(), "new-round-same-item", rowOf(view, employee).path("rowNo").asInt())),
                hr.accessToken())).andExpect(status().isUnprocessableEntity());
        assertEquals("APPLIED", jdbc.queryForObject("""
                SELECT outcome FROM employee_reconcile_plan_items WHERE plan_id = ? AND row_no = ?
                """, String.class, planId, rowOf(view, employee).path("rowNo").asInt()));
    }

    // ------------------------------------------------------------------
    // 7. 过期清理：未执行项密文清空、已执行项保留、读取与执行都关门
    // ------------------------------------------------------------------

    @Test
    void expiredPlansAreClosedWithUnexecutedValuesPurgedAndExecutedKept() throws Exception {
        String admin = adminToken();
        Employee hr = newEmployee(admin, "DEPT_HR");
        int salt = ThreadLocalRandom.current().nextInt(100, 999);
        UUID executed = legacyEmployee("V810-F-01", "核对己一", "身份证",
                "442000" + "850615" + String.format("%03d", (salt + 111) % 900 + 30), phone(6, 1));
        UUID pending1 = legacyEmployee("V810-F-02", "核对己二", "身份证",
                wrongCheckVariant(withChecksum("44200019970707" + String.format("%03d", salt))), phone(6, 2));
        UUID pending2 = legacyEmployee("V810-F-03", "核对己三", "身份证",
                wrongCheckVariant(withChecksum("44200019980808" + String.format("%03d", salt))), phone(6, 3));

        JsonNode view = createPlan(hr, Arrays.asList(executed, pending1, pending2));
        UUID planId = UUID.fromString(view.path("id").asText());
        int executedRow = rowOf(view, executed).path("rowNo").asInt();
        int pendingRow = rowOf(view, pending1).path("rowNo").asInt();
        int pending2Row = rowOf(view, pending2).path("rowNo").asInt();
        String executedExpected = rowOf(view, executed).path("items").get(0).path("newValue").asText();
        JsonNode firstRound = applyPlan(hr, planId, 1, "before-expiry",
                List.of(selection(executedRow, 1, null, null)));
        assertEquals(1, firstRound.path("counts").path("applied").asInt(), firstRound.toString());
        assertEquals(executedExpected, storedIdentity(executed));

        // 计划 24 小时过期：把创建/过期时间改到过去，直接跑清理。
        jdbc.update("""
                UPDATE employee_reconcile_plans
                SET created_at = now() - interval '2 hours', expires_at = now() - interval '1 minute'
                WHERE id = ?
                """, planId);
        housekeeping.purge();

        assertEquals("CLOSED", planColumn(planId, "status"));
        assertEquals("EXPIRED", planColumn(planId, "closed_reason"));
        // 已执行项是更正记录：值密文保留；未执行项清空。
        assertTrue(itemValueEncPresent(planId, executedRow), "executed items keep their values");
        assertFalse(itemValueEncPresent(planId, pendingRow), "unexecuted items are purged");
        assertFalse(itemValueEncPresent(planId, pending2Row), "unexecuted items are purged");

        JsonNode fetched = ok(get("/api/org/employee-reconcile/plans/" + planId), hr.accessToken());
        assertEquals("CLOSED", fetched.path("status").asText());
        assertEquals("EXPIRED", fetched.path("closedReason").asText());
        assertFalse(fetched.path("canApply").asBoolean());
        assertEquals("核对计划已过期", fetched.path("readOnlyReason").asText());
        assertEquals(executedExpected, rowOf(fetched, executed).path("items").get(0)
                .path("newValue").asText(), "executed values still decrypt after the purge");
        JsonNode pendingValue = rowOf(fetched, pending1).path("items").get(0).path("newValue");
        assertTrue(pendingValue.isNull() || pendingValue.isMissingNode(),
                "unexecuted values are gone from the view");

        // 过期后执行：409 RECONCILE_PLAN_EXPIRED。
        mvc.perform(withStepUp(json(post("/api/org/employee-reconcile/plans/" + planId + "/apply"),
                applyBody(firstRound.path("planVersion").asInt(), "after-expiry", pendingRow)),
                hr.accessToken()))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.fieldErrors[0].field").value("errorCode"))
                .andExpect(jsonPath("$.fieldErrors[0].message").value("RECONCILE_PLAN_EXPIRED"));
    }

    @Test
    void expiredApplyingPlanClosesItsReceiptAndDoesNotBlockOtherCleanup() throws Exception {
        Employee hr = newEmployee(adminToken(), "DEPT_HR");
        UUID employee = legacyEmployee("V810-J-01", "核对过期执行", "身份证",
                "442000780422841", phone(10, 1));
        JsonNode view = createPlan(hr, List.of(employee));
        UUID planId = UUID.fromString(view.path("id").asText());
        UUID applyId = UUID.randomUUID();
        jdbc.update("""
                UPDATE employee_reconcile_plans
                SET status = 'APPLYING', applying_until = now() - interval '1 minute',
                    created_at = now() - interval '2 hours', expires_at = now() - interval '1 minute'
                WHERE id = ?
                """, planId);
        jdbc.update("""
                INSERT INTO employee_reconcile_applies(id, plan_id, round_no, request_id, actor_user_id)
                VALUES (?, ?, 1, 'expired-running', ?)
                """, applyId, planId, UUID.fromString(hr.userId()));

        housekeeping.purge();

        assertEquals("CLOSED", planColumn(planId, "status"));
        assertEquals("EXPIRED", planColumn(planId, "closed_reason"));
        assertNull(planColumn(planId, "applying_until"));
        assertEquals("INTERRUPTED", jdbc.queryForObject(
                "SELECT status FROM employee_reconcile_applies WHERE id = ?", String.class, applyId));
        assertFalse(itemValueEncPresent(planId, rowOf(view, employee).path("rowNo").asInt()));
        assertEquals(Boolean.FALSE, new TransactionTemplate(transactionManager).execute(
                ignored -> reconcileStore.renewApplyLease(planId, applyId)));
    }

    @Test
    void lockedConcurrentEmployeeEditIsRecheckedBeforeApplyingTheOldPlan() throws Exception {
        Employee hr = newEmployee(adminToken(), "DEPT_HR");
        UUID employee = legacyEmployee("V810-K-01", "核对并发更正", "身份证",
                "442000780422842", phone(11, 1));
        JsonNode view = createPlan(hr, List.of(employee));
        UUID planId = UUID.fromString(view.path("id").asText());
        int rowNo = rowOf(view, employee).path("rowNo").asInt();
        MockHttpServletRequestBuilder request = withStepUp(json(
                post("/api/org/employee-reconcile/plans/" + planId + "/apply"),
                applyBody(1, "concurrent-employee-edit", rowNo)), hr.accessToken());
        CountDownLatch locked = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        AtomicInteger blockerPid = new AtomicInteger();
        try (var workers = Executors.newFixedThreadPool(2)) {
            var editor = workers.submit(() -> new TransactionTemplate(transactionManager)
                    .executeWithoutResult(ignored -> {
                        blockerPid.set(jdbc.queryForObject("SELECT pg_backend_pid()", Integer.class));
                        jdbc.update("UPDATE employees SET version = version + 1 WHERE id = ?", employee);
                        locked.countDown();
                        try {
                            if (!release.await(20, TimeUnit.SECONDS)) {
                                throw new IllegalStateException("test lock release timed out");
                            }
                        } catch (InterruptedException interrupted) {
                            Thread.currentThread().interrupt();
                            throw new IllegalStateException(interrupted);
                        }
                    }));
            assertTrue(locked.await(10, TimeUnit.SECONDS));
            var applying = workers.submit(() -> mvc.perform(request).andReturn());
            boolean waiting = false;
            try {
                for (int attempt = 0; attempt < 400 && !waiting; attempt++) {
                    waiting = Boolean.TRUE.equals(jdbc.queryForObject("""
                            SELECT EXISTS (SELECT 1 FROM pg_stat_activity
                                           WHERE ? = ANY(pg_blocking_pids(pid)))
                            """, Boolean.class, blockerPid.get()));
                    if (!waiting) Thread.sleep(25);
                }
                assertTrue(waiting, "the apply request must reach the employee lock before it is released");
            } finally {
                release.countDown();
            }
            editor.get(10, TimeUnit.SECONDS);
            MvcResult response = applying.get(15, TimeUnit.SECONDS);
            assertEquals(200, response.getResponse().getStatus(), response.getResponse().getContentAsString());
            JsonNode result = objectMapper.readTree(response.getResponse().getContentAsString());
            assertEquals(0, result.path("counts").path("applied").asInt());
            assertEquals(1, result.path("counts").path("skipped").asInt());
            assertEquals("442000780422842", storedIdentity(employee));
        } finally {
            release.countDown();
        }
    }

    // ------------------------------------------------------------------
    // 8. 隔离：非创建人只读 / 404，APPLYING 排队，卡死回收
    // ------------------------------------------------------------------

    @Test
    void nonOwnerIsReadOnlyAndStaleApplyingRoundsAreReclaimed() throws Exception {
        String admin = adminToken();
        Employee hr = newEmployee(admin, "DEPT_HR");
        Employee hr2 = newEmployee(admin, "DEPT_HR");
        int salt = ThreadLocalRandom.current().nextInt(100, 999);
        UUID employee = legacyEmployee("V810-G-01", "核对庚一", "身份证",
                wrongCheckVariant(withChecksum("44200019990909" + String.format("%03d", salt))), phone(7, 1));

        JsonNode view = createPlan(hr, List.of(employee));
        UUID planId = UUID.fromString(view.path("id").asText());
        int rowNo = rowOf(view, employee).path("rowNo").asInt();

        // 非创建人 (同样有全套权限)：可读、只读。
        mvc.perform(auth(get("/api/org/employee-reconcile/plans/" + planId), hr2.accessToken()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.canApply").value(false))
                .andExpect(jsonPath("$.readOnlyReason").value("这是 " + employeeName(hr) + " 的核对，只能查看"));
        // 非创建人执行 → 404，不暴露存在性。
        mvc.perform(withStepUp(json(post("/api/org/employee-reconcile/plans/" + planId + "/apply"),
                applyBody(1, "foreign-actor", rowNo)), hr2.accessToken()))
                .andExpect(status().isNotFound());

        // 模拟一轮卡死的更正：计划 APPLYING (租约未到) + RUNNING 回执。
        jdbc.update("""
                UPDATE employee_reconcile_plans SET status = 'APPLYING',
                       applying_until = now() + interval '5 minutes'
                WHERE id = ?
                """, planId);
        jdbc.update("""
                INSERT INTO employee_reconcile_applies (id, plan_id, round_no, request_id, actor_user_id, status)
                VALUES (?, ?, 1, 'stuck-round', ?, 'RUNNING')
                """, UUID.randomUUID(), planId, UUID.fromString(hr.userId()));
        mvc.perform(auth(get("/api/org/employee-reconcile/plans/" + planId), hr.accessToken()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("APPLYING"))
                .andExpect(jsonPath("$.canApply").value(false));
        // 创建人并发第二轮：排队拒绝。
        mvc.perform(withStepUp(json(post("/api/org/employee-reconcile/plans/" + planId + "/apply"),
                applyBody(1, "concurrent", rowNo)), hr.accessToken()))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.fieldErrors[0].message").value("RECONCILE_PLAN_BUSY"));

        // 租约超时：清理把计划回 OPEN、版本 +1，RUNNING 回执置 INTERRUPTED。
        jdbc.update("UPDATE employee_reconcile_plans SET applying_until = now() - interval '1 minute' WHERE id = ?",
                planId);
        housekeeping.purge();
        assertEquals("OPEN", planColumn(planId, "status"));
        assertEquals("2", planColumn(planId, "version"));
        assertEquals("INTERRUPTED", jdbc.queryForObject(
                "SELECT status FROM employee_reconcile_applies WHERE plan_id = ? AND request_id = 'stuck-round'",
                String.class, planId));
        assertNull(planColumn(planId, "applying_until"));

        // 回收后老版本的执行请求被拒为已变化。
        mvc.perform(withStepUp(json(post("/api/org/employee-reconcile/plans/" + planId + "/apply"),
                applyBody(1, "after-reclaim", rowNo)), hr.accessToken()))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.fieldErrors[0].message").value("RECONCILE_PLAN_CHANGED"));
    }

    // ------------------------------------------------------------------
    // 9. discard：创建人放弃计划，未执行值清空，幂等
    // ------------------------------------------------------------------

    @Test
    void discardClosesThePlanAndClearsUnexecutedValues() throws Exception {
        String admin = adminToken();
        Employee hr = newEmployee(admin, "DEPT_HR");
        Employee hr2 = newEmployee(admin, "DEPT_HR");
        int salt = ThreadLocalRandom.current().nextInt(100, 999);
        String wrongNumber = wrongCheckVariant(withChecksum("44200020000101" + String.format("%03d", salt)));
        UUID employee = legacyEmployee("V810-H-01", "核对辛一", "身份证", wrongNumber, phone(8, 1));

        JsonNode view = createPlan(hr, List.of(employee));
        UUID planId = UUID.fromString(view.path("id").asText());
        int rowNo = rowOf(view, employee).path("rowNo").asInt();
        assertTrue(itemValueEncPresent(planId, rowNo));

        // 非创建人放弃 → 404。
        mvc.perform(auth(post("/api/org/employee-reconcile/plans/" + planId + "/discard"), hr2.accessToken()))
                .andExpect(status().isNotFound());

        // 创建人放弃：立即关闭、未执行值清空。
        MvcResult discarded = mvc.perform(
                auth(post("/api/org/employee-reconcile/plans/" + planId + "/discard"), hr.accessToken()))
                .andExpect(status().isOk()).andReturn();
        assertEquals("{}", body(discarded));
        assertEquals("CLOSED", planColumn(planId, "status"));
        assertEquals("DISCARDED", planColumn(planId, "closed_reason"));
        assertFalse(itemValueEncPresent(planId, rowNo));
        assertEquals(wrongNumber, storedIdentity(employee), "discard never touches the employee档案");

        mvc.perform(auth(get("/api/org/employee-reconcile/plans/" + planId), hr.accessToken()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.canApply").value(false))
                .andExpect(jsonPath("$.readOnlyReason").value("核对计划已放弃"));

        // 幂等：重复放弃仍成功，不再重复写审计。
        mvc.perform(auth(post("/api/org/employee-reconcile/plans/" + planId + "/discard"), hr.accessToken()))
                .andExpect(status().isOk());
        assertEquals(1, countAudit("employee_reconcile.discarded", planId.toString()));
    }

    // ==================================================================
    // 夹具与小工具
    // ==================================================================

    /**
     * 在顺序码区间里找一个合法且自身没有相邻重复数字的号：复制第 10 位后，19 位夹具里只有
     * 注入的那一处重复，「删除重复数字」候选严格排第一。前缀必须本身无相邻重复 (442000 有
     * 「44」/「00」，永远凑不出来)，所以用江苏 320102 + 无重复生日。
     */
    private static final String REPEAT_FREE_PREFIX = "32010219870314";

    private static String validWithoutAdjacentRepeat(String prefix14, int seqHint) {
        for (int tail = 0; tail < 900; tail++) {
            String seq = String.format("%03d", (seqHint + tail) % 900 + 50);
            if (seq.charAt(0) == seq.charAt(1) || seq.charAt(1) == seq.charAt(2)) {
                continue;
            }
            if (seq.charAt(0) == prefix14.charAt(prefix14.length() - 1)) {
                continue;
            }
            String candidate = withChecksum(prefix14 + seq);
            boolean repeat = false;
            for (int i = 0; i + 1 < candidate.length(); i++) {
                if (candidate.charAt(i) == candidate.charAt(i + 1)) {
                    repeat = true;
                    break;
                }
            }
            if (!repeat) {
                return candidate;
            }
        }
        throw new IllegalStateException("no clean fixture number available");
    }

    /** 把好号的校验位换成一个错的 (永远不会换回原值)。 */
    private static String wrongCheckVariant(String valid) {
        return valid.substring(0, 17) + (valid.charAt(17) == '1' ? '2' : '1');
    }

    /** 当前密钥版本 + 一段不是 PGP 报文的 base64：解密必失败。 */
    private String corruptCipher() {
        String version = new TransactionTemplate(transactionManager).execute(status -> {
            String sample = tx.encrypt("version-probe");
            return sample.substring(0, sample.indexOf(':'));
        });
        return version + ":" + Base64.getEncoder()
                .encodeToString("not a pgp message".getBytes(StandardCharsets.UTF_8));
    }

    private void bindSuperAdminAccount(UUID employeeId, int salt) {
        jdbc.update("""
                INSERT INTO users (id, employee_id, login_account, password_hash, is_super_admin)
                VALUES (?, ?, ?, 'no-login-for-this-fixture', true)
                """, UUID.randomUUID(), employeeId, "recon-super-" + salt);
    }

    private UUID legacyEmployee(String code, String name, String idType, String identity, String phone) {
        UUID id = UUID.randomUUID();
        String departmentId = jdbc.queryForObject(
                "SELECT id::text FROM departments WHERE code = 'DEPT_ENG' AND NOT is_deleted", String.class);
        jdbc.update("""
                INSERT INTO employees (id, code, full_name, id_type, department_id, hire_date,
                                       confirmed_at, status, employment_type)
                VALUES (?, ?, ?, ?, ?::uuid, DATE '2025-01-02', DATE '2025-04-02', 'active', 'regular')
                """, id, code, name, idType, departmentId);
        List<String> derived = new TransactionTemplate(transactionManager).execute(status -> {
            List<String> values = new ArrayList<>();
            values.add(identity == null ? null : tx.encrypt(identity));
            values.add(identity == null ? null : tx.hmac(identity));
            values.add(tx.encrypt(phone));
            values.add(tx.hmac(phone));
            return values;
        });
        jdbc.update("""
                INSERT INTO employee_sensitive (employee_id, id_card_enc, id_card_last4, id_card_hash,
                                                id_card_check, phone_enc, phone_hash)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, id, derived.get(0), identity == null ? null : identity.substring(Math.max(0, identity.length() - 4)),
                derived.get(1), identity == null ? null : "unchecked", derived.get(2), derived.get(3));
        return id;
    }

    private UUID legacyEmployeeWithCipher(String code, String name, String identityCipher, String phone) {
        UUID id = UUID.randomUUID();
        String departmentId = jdbc.queryForObject(
                "SELECT id::text FROM departments WHERE code = 'DEPT_ENG' AND NOT is_deleted", String.class);
        jdbc.update("""
                INSERT INTO employees (id, code, full_name, id_type, department_id, hire_date,
                                       confirmed_at, status, employment_type)
                VALUES (?, ?, ?, '身份证', ?::uuid, DATE '2025-01-02', DATE '2025-04-02', 'active', 'regular')
                """, id, code, name, departmentId);
        List<String> derived = new TransactionTemplate(transactionManager).execute(status ->
                List.of(tx.encrypt(phone), tx.hmac(phone)));
        jdbc.update("""
                INSERT INTO employee_sensitive (employee_id, id_card_enc, id_card_check, phone_enc, phone_hash)
                VALUES (?, ?, 'unchecked', ?, ?)
                """, id, identityCipher, derived.get(0), derived.get(1));
        return id;
    }

    private static String phone(int group, int sequence) {
        return "13" + String.format("%02d", group) + String.format("%07d", sequence + 4210);
    }

    private JsonNode createPlan(Employee hr, List<UUID> employeeIds) throws Exception {
        MvcResult result = mvc.perform(json(post("/api/org/employee-reconcile/plans/id-repair"),
                Map.of("employeeIds", employeeIds), hr.accessToken())).andReturn();
        assertEquals(200, result.getResponse().getStatus(), body(result));
        return json(result);
    }

    private JsonNode applyPlan(Employee hr, UUID planId, int planVersion, String requestId,
                               List<ObjectNode> rows) throws Exception {
        ObjectNode root = applyBody(planVersion, requestId, -1);
        rows.forEach(row -> root.withArray("rows").add(row));
        MvcResult result = mvc.perform(withStepUp(
                json(post("/api/org/employee-reconcile/plans/" + planId + "/apply"), root),
                hr.accessToken())).andReturn();
        assertEquals(200, result.getResponse().getStatus(), body(result));
        return json(result);
    }

    /** 单行申请体；rowNo < 0 时只放空行数组 (给到不了业务层的请求占位)。 */
    private ObjectNode applyBody(int planVersion, String requestId, int rowNo) {
        ObjectNode root = objectMapper.createObjectNode();
        root.put("planVersion", planVersion);
        root.put("requestId", requestId);
        root.putArray("rows");
        if (rowNo > 0) {
            root.withArray("rows").add(selection(rowNo, 1, null, null));
        }
        return root;
    }

    private ObjectNode selection(int rowNo, int itemNo, Integer candidateIndex, String value) {
        ObjectNode row = objectMapper.createObjectNode();
        row.put("rowNo", rowNo);
        ObjectNode item = row.putArray("items").addObject();
        item.put("itemNo", itemNo);
        if (candidateIndex != null) {
            item.put("candidateIndex", candidateIndex);
        }
        if (value != null) {
            item.put("value", value);
        }
        return row;
    }

    private MockHttpServletRequestBuilder auth(MockHttpServletRequestBuilder request, String token) {
        return request.header("Authorization", "Bearer " + token);
    }

    /** 无鉴权头的 JSON 请求 (withStepUp 负责补 Authorization)。 */
    private MockHttpServletRequestBuilder json(MockHttpServletRequestBuilder builder, Object body)
            throws Exception {
        return json(builder, body, null);
    }

    /** 每次执行都重新过一遍再认证 (回执一次性消费)：同时带上 Bearer 与一次性回执头。 */
    private MockHttpServletRequestBuilder withStepUp(MockHttpServletRequestBuilder request, String token)
            throws Exception {
        return auth(request, token).header(STEP_UP_HEADER, stepUp(token, EMPLOYEE_PASSWORD));
    }

    private JsonNode ok(org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder request,
                        String token) throws Exception {
        return ok(auth(request, token));
    }

    /** 已带鉴权头的请求直接执行。 */
    private JsonNode ok(org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder request)
            throws Exception {
        MvcResult result = mvc.perform(request).andReturn();
        assertEquals(200, result.getResponse().getStatus(), body(result));
        return json(result);
    }

    private String employeeName(Employee employee) {
        return jdbc.queryForObject("SELECT full_name FROM employees WHERE id = ?", String.class,
                UUID.fromString(employee.employeeId()));
    }

    private static JsonNode rowOf(JsonNode view, UUID employeeId) {
        for (JsonNode row : view.path("rows")) {
            if (employeeId.toString().equals(row.path("employee").path("id").asText())) {
                return row;
            }
        }
        throw new AssertionError("plan row missing for the prepared employee");
    }

    private static String rowResult(JsonNode applyResult, int rowNo) {
        for (JsonNode row : applyResult.path("rows")) {
            if (row.path("rowNo").asInt() == rowNo) {
                return row.path("result").asText();
            }
        }
        throw new AssertionError("apply result missing the prepared row");
    }

    private static String itemMessage(JsonNode applyResult, int rowNo) {
        for (JsonNode row : applyResult.path("rows")) {
            if (row.path("rowNo").asInt() == rowNo) {
                return row.path("items").get(0).path("message").asText();
            }
        }
        throw new AssertionError("apply result missing the prepared row");
    }

    private void assertInfoRow(JsonNode view, UUID employeeId, String noticeCode, String noticeMessage) {
        JsonNode row = rowOf(view, employeeId);
        assertEquals("INFO", row.path("kind").asText());
        assertEquals(0, row.path("items").size());
        assertEquals(noticeCode, row.path("notices").get(0).path("code").asText());
        assertEquals(noticeMessage, row.path("notices").get(0).path("message").asText());
    }

    private Map<UUID, Integer> planEmployeeVersions(UUID planId) {
        Map<UUID, Integer> versions = new LinkedHashMap<>();
        jdbc.query("SELECT employee_id, employee_version FROM employee_reconcile_plan_rows WHERE plan_id = ?",
                rs -> {
                    versions.put(rs.getObject("employee_id", UUID.class), rs.getInt("employee_version"));
                }, planId);
        return versions;
    }

    private Map<UUID, Integer> currentEmployeeVersions(List<UUID> employeeIds) {
        Map<UUID, Integer> versions = new LinkedHashMap<>();
        for (UUID employeeId : employeeIds) {
            versions.put(employeeId, employeeVersion(employeeId));
        }
        return versions;
    }

    private int employeeVersion(UUID employeeId) {
        return jdbc.queryForObject("SELECT version FROM employees WHERE id = ?", Integer.class, employeeId);
    }

    private String storedIdentity(UUID employeeId) {
        String cipher = jdbc.queryForObject(
                "SELECT id_card_enc FROM employee_sensitive WHERE employee_id = ?", String.class, employeeId);
        if (cipher == null) {
            return null;
        }
        return new TransactionTemplate(transactionManager).execute(status ->
                tx.tryDecrypt(cipher).orElse(null));
    }

    /** 执行后的全套数据库断言：密文、校验结果、哈希、乐观锁版本、按新号重推的派生字段。 */
    private void assertIdentityRewritten(UUID employeeId, String expected, int versionAtPlan) {
        assertEquals(expected, storedIdentity(employeeId));
        assertEquals("valid", jdbc.queryForObject(
                "SELECT id_card_check FROM employee_sensitive WHERE employee_id = ?", String.class, employeeId));
        String hash = new TransactionTemplate(transactionManager).execute(status -> tx.hmac(expected));
        assertEquals(hash, jdbc.queryForObject(
                "SELECT id_card_hash FROM employee_sensitive WHERE employee_id = ?", String.class, employeeId));
        assertEquals(versionAtPlan + 1, employeeVersion(employeeId));
        String birthMonthDay = expected.substring(10, 12) + "-" + expected.substring(12, 14);
        assertEquals(birthMonthDay, jdbc.queryForObject(
                "SELECT birth_month_day FROM employees WHERE id = ?", String.class, employeeId));
        String gender = (expected.charAt(16) - '0') % 2 == 1 ? "male" : "female";
        assertEquals(gender, jdbc.queryForObject(
                "SELECT gender FROM employees WHERE id = ?", String.class, employeeId));
    }

    private String planColumn(UUID planId, String column) {
        return jdbc.queryForObject("SELECT " + column + "::text FROM employee_reconcile_plans WHERE id = ?",
                String.class, planId);
    }

    private String appliedOrigin(UUID planId, int rowNo) {
        return jdbc.queryForObject(
                "SELECT applied_origin FROM employee_reconcile_plan_items WHERE plan_id = ? AND row_no = ?",
                String.class, planId, rowNo);
    }

    private boolean itemValueEncPresent(UUID planId, int rowNo) {
        Boolean present = jdbc.queryForObject("""
                SELECT (old_value_enc IS NOT NULL OR new_value_enc IS NOT NULL OR candidates_enc IS NOT NULL)
                FROM employee_reconcile_plan_items WHERE plan_id = ? AND row_no = ?
                """, Boolean.class, planId, rowNo);
        return Boolean.TRUE.equals(present);
    }

    private long countAudit(String action, String targetId) {
        Long count;
        if (targetId == null) {
            count = jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE action = ?", Long.class, action);
        } else {
            count = jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE action = ? AND target_id = ?",
                    Long.class, action, targetId);
        }
        return count == null ? 0 : count;
    }

    private static List<String> identityIds(JsonNode summary) {
        List<String> ids = new ArrayList<>();
        summary.path("identityReview").forEach(item -> ids.add(item.path("employeeId").asText()));
        return ids;
    }

    /**
     * 明文只允许出现在值字段里：先剥掉 UUID、时间戳、日期、概率小数与 oldValue/newValue/value
     * 的值，再检查剩余正文里既没有完整号码、也没有前 17 位或后四位。断言消息不带号码。
     * (概率是 4 位小数，会随机撞上某个号码的尾四位，不算泄漏。)
     */
    private static void assertNoIdentityDigits(String responseBody, String... identities) {
        String stripped = responseBody
                .replaceAll("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", "<id>")
                .replaceAll("\\d{4}-\\d{2}-\\d{2}T[^\"]*", "<ts>")
                .replaceAll("\\d{4}-\\d{2}-\\d{2}", "<date>")
                .replaceAll("\\\"probability\\\"\\s*:\\s*[0-9.Ee+-]+", "\\\"probability\\\":<p>")
                .replaceAll("\\\"(?:oldValue|newValue|value)\\\"\\s*:\\s*\\\"[^\"]*\\\"", "\\\"<v>\\\"");
        for (String identity : identities) {
            String compact = identity.replace(" ", "");
            assertTrue(!stripped.contains(compact) && !stripped.contains(identity),
                    "response must not carry identity digits outside value fields");
            if (compact.length() >= 18) {
                assertTrue(!stripped.contains(compact.substring(0, 17)),
                        "response must not carry the first seventeen digits");
            }
            assertTrue(!stripped.contains(compact.substring(compact.length() - 4)),
                    "response must not carry the last four digits");
        }
    }

    private static String withChecksum(String firstSeventeen) {
        int[] weights = {7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2};
        char[] checks = {'1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2'};
        int sum = 0;
        for (int i = 0; i < 17; i++) {
            sum += (firstSeventeen.charAt(i) - '0') * weights[i];
        }
        return firstSeventeen + checks[sum % 11];
    }
}
