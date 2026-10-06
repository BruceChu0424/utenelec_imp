package com.uten.imp.application.port;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.ai.AiPlatformPostgresTestSupport;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SubmitterPrincipalRestorer;
import org.junit.jupiter.api.AfterEach;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.time.LocalDate;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * 单据状态类 AI 工具(P1-3)的真库底座: 真实 PostgreSQL + 全部迁移, 员工经入职接口开号, 调用工具时的主体由
 * {@link SubmitterPrincipalRestorer} 从库里按部门授权与个人覆盖重建(与后台 AI 任务同一条路), 不手写权限集合。
 * 单据本身用 JDBC 落最小夹具(与既有单据真库测试同一写法)。
 */
public abstract class AiDocumentStatusToolPostgresSupport extends AiPlatformPostgresTestSupport {

    protected static final LocalDate BILL_DATE = LocalDate.of(2026, 10, 6);
    private static final AtomicInteger SEQUENCE = new AtomicInteger(ThreadLocalRandom.current().nextInt(100_000, 800_000));

    @Autowired
    private SubmitterPrincipalRestorer principals;

    @AfterEach
    void clearPrincipal() {
        SecurityContextHolder.clearContext();
    }

    /** 业务单号: 前缀 + 日期 + 6 位序号(号段触发器的注册格式)。 */
    protected static String billNo(String prefix) {
        return prefix + BILL_DATE.toString().replace("-", "") + "%06d".formatted(SEQUENCE.incrementAndGet());
    }

    /** 部门授权(已有则不变), 授权会推进全局授权纪元, 所以之后的主体一律现取。 */
    protected void grant(String departmentCode, String... permissions) {
        for (String permission : permissions) {
            jdbc.update("""
                    INSERT INTO department_permissions(department_id, permission_id)
                    SELECT d.id, p.id FROM departments d CROSS JOIN permissions p
                    WHERE d.code = ? AND p.code = ? AND NOT d.is_deleted
                    ON CONFLICT DO NOTHING
                    """, departmentCode, permission);
        }
    }

    /** 个人覆盖撤掉一个权限点(如全量查看), 让归属范围生效。 */
    protected void revoke(Staff staff, String permission) {
        jdbc.update("""
                INSERT INTO user_permission_overrides(user_id, permission_id, effect)
                SELECT ?::uuid, id, 'revoke' FROM permissions WHERE code = ?
                ON CONFLICT (user_id, permission_id) DO UPDATE SET effect = 'revoke'
                """, staff.userId(), permission);
    }

    /** 以该员工当前的服务端账号状态作为调用主体(权限、部门归属都按库里现值)。 */
    protected AuthUser actAs(Staff staff) {
        UUID userId = UUID.fromString(staff.userId());
        var stamps = principals.currentStamps(userId).orElseThrow();
        AuthUser user = principals.restore(userId, stamps.authVersion(), stamps.authorizationEpoch());
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(user, null, user.getAuthorities()));
        return user;
    }

    protected String fullName(Staff staff) {
        return jdbc.queryForObject("SELECT full_name FROM employees WHERE id = ?::uuid", String.class, staff.employeeId());
    }

    protected UUID unit(String name) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO units(id, code, name) VALUES (?, ?, ?)", id, "AIT-U-" + id, name);
        return id;
    }

    protected UUID goods(String code, String name, UUID unit) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO goods(id, code, name, unit_id, code_sequence)
                VALUES (?, ?, ?, ?, (SELECT COALESCE(MAX(code_sequence), 0) + 1 FROM goods))
                """, id, code, name, unit);
        return id;
    }

    protected UUID warehouse() {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO warehouses(id, code, name) VALUES (?, ?, 'AI 工具测试仓')", id, "AIT-W-" + id);
        return id;
    }

    protected static void assertForbidden(Runnable action) {
        assertThatThrownBy(action::run).isInstanceOf(ApiException.class)
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.FORBIDDEN);
    }

    /** A stored answer whose evidence no longer matches the reader's current read is refused. */
    protected static void assertEvidenceRefused(AiChatToolPort tool, Map<String, Object> evidence) {
        assertForbidden(() -> tool.authorizeResultRead(evidence));
    }

    @SuppressWarnings("unchecked")
    protected static Map<String, Object> evidence(Map<String, Object> result) {
        assertThat(result.get("_toolEvidence")).isInstanceOf(Map.class);
        return (Map<String, Object>) result.get("_toolEvidence");
    }
}
