package com.uten.imp.features.notice;

import com.uten.imp.application.port.LoginFailureObservationPort;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.sql.Timestamp;
import java.time.Instant;
import java.util.UUID;

/** Authentication audit is durable across application restarts and shared by local/cloud login. */
@Component
@Profile("!cloud")
@RequiredArgsConstructor
@Slf4j
class LoginFailureAlertScheduler {
    private final JdbcTemplate jdbc;
    private final LoginFailureObservationPort observation;
    private final ServerAlertAudience audience;
    private final NoticeService notices;

    @Scheduled(fixedDelayString = "60000", initialDelayString = "120000")
    void scan() {
        try {
            var failures = observation.recentFailures(Instant.now().minusSeconds(600));
            if (failures.isEmpty()) return;
            for (UUID user : audience.receivers()) {
                for (var failure : failures) {
                    String source = "SERVER_STATUS_ALERT:LOGIN_FAILURE:" + failure.sourceFingerprint();
                    Integer sent = jdbc.queryForObject("""
                            SELECT count(*) FROM notices n JOIN notice_user_states s ON s.notice_id=n.id
                            WHERE n.source_event=? AND s.user_id=? AND n.created_at>=?
                            """, Integer.class, source, user, Timestamp.from(Instant.now().minusSeconds(21600)));
                    if (sent != null && sent > 0) continue;
                    notices.publishForUser(user, "检测到连续登录失败",
                            "同一网络来源在最近 10 分钟内登录失败 " + failure.attempts()
                                    + " 次。登录限流与账号锁定继续生效，请联系管理员核对安全审计。",
                            "urgent", "系统监控", "/admin/server-status", source, "urgent");
                }
            }
        } catch (RuntimeException unavailable) {
            log.warn("登录安全告警暂不可用，下轮重试: {}", unavailable.getClass().getSimpleName());
        }
    }
}
