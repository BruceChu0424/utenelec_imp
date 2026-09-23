package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;

import java.time.Duration;
import java.time.OffsetDateTime;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/**
 * 服务端会话权威 (ADR-110; audit-retention-settings-02, security-09), 真库 + 可控时钟:
 * 空闲超时由服务端判定、登出立刻作废访问令牌、刷新不延长从登录起算的绝对期限、
 * 用户没在操作时发出的请求 (客户端带 X-Uten-Automatic: 1, 不论哪个端点) 不续期、
 * 人为请求每分钟至多写一次最后活动时间。
 */
class SessionIdleEnforcementPostgresTest extends AuthSessionPostgresTestSupport {

    private static final Duration IDLE = Duration.ofMinutes(30);
    private static final String AUTOMATIC = "X-Uten-Automatic";

    @Test
    void idleSessionIsRejectedByTheServerAndCannotBeRefreshed() throws Exception {
        Employee employee = newEmployee(adminToken());
        assertEquals(200, me(employee.accessToken()).getResponse().getStatus());

        clock.advance(IDLE.plusMinutes(1));

        MvcResult idle = me(employee.accessToken());
        assertEquals(401, idle.getResponse().getStatus());
        assertTrue(body(idle).contains("长时间没有操作"), body(idle));
        MvcResult refresh = mvc.perform(json(post("/api/auth/refresh"),
                Map.of("refreshToken", employee.refreshToken()), null)).andReturn();
        assertEquals(401, refresh.getResponse().getStatus());
        assertEquals(1, jdbc.queryForObject("""
                SELECT count(*) FROM auth_sessions s JOIN users u ON u.id = s.user_id
                WHERE u.login_account = ? AND s.revoked_reason = 'idle_timeout'
                """, Integer.class, employee.loginAccount()));
    }

    @Test
    void pollingWhileTheUserIsIdleNeverKeepsASessionAliveButHumanActivityDoes() throws Exception {
        Employee polling = newEmployee(adminToken());
        Employee working = newEmployee(adminToken());

        for (int round = 1; round <= 4; round++) {
            clock.advance(Duration.ofMinutes(10));
            // 两人的页面都在定时轮询 (角标计数, 以及不符合任何「计数」命名的普通详情/身份接口);
            // 只有 working 还有人为操作 (打开页面)
            int pollStatus = poll(polling);
            if (round <= 3) {
                assertEquals(200, pollStatus, "round " + round);
            } else {
                // 40 分钟里只有轮询: 服务端判定空闲 (阈值 30 分钟), 轮询本身也被拒
                assertEquals(401, pollStatus, "round " + round);
            }
            assertEquals(200, poll(working));
            assertEquals(200, me(working.accessToken()).getResponse().getStatus());
        }
        assertEquals(401, me(polling.accessToken()).getResponse().getStatus());
    }

    /** 用户没在操作时页面发出的请求: 与端点无关, 一律带「自动」声明头。 */
    private int poll(Employee employee) throws Exception {
        int badge = mvc.perform(get("/api/notices/unread-count")
                .header("Authorization", "Bearer " + employee.accessToken())
                .header(AUTOMATIC, "1"))
                .andReturn().getResponse().getStatus();
        int refresh = automaticMe(employee).getResponse().getStatus();
        assertEquals(badge, refresh, "判定只看人在不在场, 与端点无关");
        return badge;
    }

    private MvcResult automaticMe(Employee employee) throws Exception {
        return mvc.perform(get("/api/auth/me")
                .header("Authorization", "Bearer " + employee.accessToken())
                .header(AUTOMATIC, "1"))
                .andReturn();
    }

    @Test
    void logoutInvalidatesTheAccessTokenImmediately() throws Exception {
        Employee employee = newEmployee(adminToken());
        assertEquals(200, me(employee.accessToken()).getResponse().getStatus());

        MvcResult logout = mvc.perform(json(post("/api/auth/logout"),
                Map.of("refreshToken", employee.refreshToken()), null)).andReturn();
        assertEquals(200, logout.getResponse().getStatus());

        MvcResult afterLogout = me(employee.accessToken());
        assertEquals(401, afterLogout.getResponse().getStatus(), "未过期的访问令牌登出后立即失效");
    }

    @Test
    void refreshNeverExtendsTheAbsoluteLifetimeCountedFromLogin() throws Exception {
        String adminToken = adminToken();
        Employee employee = newEmployee(adminToken);
        // 让空闲判定不干扰: 本用例只看从登录起算的绝对期限 (默认 7 天)
        jdbc.update("UPDATE system_settings SET value = '525600' WHERE key = 'session_idle_timeout_minutes'");
        try {
            clock.advance(Duration.ofSeconds(1));
            JsonNode session = login(employee.loginAccount(), EMPLOYEE_PASSWORD);
            OffsetDateTime absolute = jdbc.queryForObject("""
                    SELECT absolute_expires_at FROM auth_sessions s JOIN users u ON u.id = s.user_id
                    WHERE u.login_account = ? AND s.revoked_at IS NULL ORDER BY s.created_at DESC LIMIT 1
                    """, OffsetDateTime.class, employee.loginAccount());
            String refresh = session.path("refreshToken").asText();
            clock.advance(Duration.ofDays(3));
            MvcResult rotated = mvc.perform(json(post("/api/auth/refresh"),
                    Map.of("refreshToken", refresh), null)).andReturn();
            assertEquals(200, rotated.getResponse().getStatus(), body(rotated));
            String nextRefresh = json(rotated).path("refreshToken").asText();
            OffsetDateTime refreshExpiry = jdbc.queryForObject(
                    "SELECT expires_at FROM refresh_tokens WHERE revoked_at IS NULL AND session_id = "
                            + "(SELECT sid FROM auth_sessions s JOIN users u ON u.id = s.user_id "
                            + "WHERE u.login_account = ? AND s.revoked_at IS NULL ORDER BY s.created_at DESC LIMIT 1)",
                    OffsetDateTime.class, employee.loginAccount());
            assertEquals(absolute.toInstant(), refreshExpiry.toInstant(), "轮换后的刷新令牌仍按登录时刻起算");

            clock.advance(Duration.ofDays(5));
            MvcResult expired = mvc.perform(json(post("/api/auth/refresh"),
                    Map.of("refreshToken", nextRefresh), null)).andReturn();
            assertEquals(401, expired.getResponse().getStatus());
        } finally {
            jdbc.update("UPDATE system_settings SET value = '30' WHERE key = 'session_idle_timeout_minutes'");
        }
    }

    @Test
    void lastSeenIsWrittenAtMostOncePerMinuteAndOnlyForHumanRequests() throws Exception {
        Employee employee = newEmployee(adminToken());
        clock.advance(Duration.ofMinutes(2));
        me(employee.accessToken());   // 预热权限快照缓存, 让下面三次只差会话续期这一条
        clock.advance(Duration.ofSeconds(61));

        long first = statements(() -> me(employee.accessToken()));
        long second = statements(() -> me(employee.accessToken()));
        clock.advance(Duration.ofSeconds(61));
        // 同一个端点, 用户没在操作时发出 (带自动声明头): 已到续期时间也不写
        long automatic = statements(() -> automaticMe(employee));
        long third = statements(() -> me(employee.accessToken()));

        // 第一个人为请求距上次记录已超过 60 秒 → 多一条 UPDATE; 紧接着的第二个不写
        assertEquals(second + 1, first, "first=" + first + " second=" + second);
        assertEquals(second, automatic, "automatic=" + automatic);
        assertEquals(second + 1, third, "third=" + third);
        System.out.println("MEASURE auth.me statements: touch=" + first + " noTouch=" + second
                + " automaticWhileIdle=" + automatic);
    }

    private long statements(ThrowingRunnable action) throws Exception {
        ProductionJdbcMeasurement.Sample sample = ProductionJdbcMeasurement.begin();
        try {
            action.run();
            return sample.logicalStatements;
        } finally {
            ProductionJdbcMeasurement.end();
        }
    }

    @FunctionalInterface
    interface ThrowingRunnable {
        void run() throws Exception;
    }
}
