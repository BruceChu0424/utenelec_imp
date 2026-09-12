package com.uten.imp.features.notice;

import com.uten.imp.features.admin.serverstatus.ServerStatusService;
import com.uten.imp.features.admin.serverstatus.ServerStatusView;
import lombok.extern.slf4j.Slf4j;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 服务器状态告警推送（2026-09-11）。
 *
 * <p><b>解决的问题</b>：{@code ServerStatusProbe} 早就会算出「附件存储 91%」这类告警，
 * 但它们<b>只塞进页面返回值</b>——没人主动打开「工作台 → 服务器状态」就永远不知道。
 * 用户原话：「我就怕业务附件 196G 不够用」。现在定期采样，越线即站内通知。
 *
 * <p><b>发给谁</b>：持有 {@code server_status:alert:receive} 的活跃账号（见 V552）。
 * 与「谁能看这个页面」({@code server_status:view}) 分开授——能看和该被吵醒不是一回事。
 *
 * <p><b>不刷屏的三条</b>：
 * <ul>
 *   <li><b>节流走数据库</b>：同一个指标 + 同一个严重档，{@value #THROTTLE_HOURS} 小时内对同一个人
 *       只发一条。判据是 {@code notices.source_event}，因此<b>重启不会重新刷一遍</b>；</li>
 *   <li><b>升级立即发</b>：WARNING → CRITICAL 是不同的 source_event，不受上一档的节流压制；</li>
 *   <li><b>恢复只对危急发</b>：从 CRITICAL 回到正常时补一条「已恢复」，免得人一直悬着；
 *       警告档恢复不发（没必要为一次 81%→79% 打扰人）。</li>
 * </ul>
 *
 * <p><b>已知边界</b>：恢复通知靠<b>内存</b>里的上一轮严重档判定，进程重启后清空——
 * 重启前正处于 CRITICAL、重启后恰好恢复的那一次不会发「已恢复」（告警本身仍会按
 * 数据库节流正确发出）。为此不新增一张表：这条信息的价值不值一次迁移 + 审计触发器覆盖。
 *
 * <p>整条链路旁路：任何异常只记日志，绝不影响业务或状态页本身。
 *
 * <p><b>为什么住在 features.notice 而不是 features.admin.serverstatus</b>：架构边界
 * （ADR-017 / ArchitectureBoundaryTest）允许 {@code notice->admin}，不允许 {@code admin->notice}；
 * 而且全部通知定时任务（庆典/延期预警/预留超期/委外回厂）本来就在这个包里，放一起才好找。
 */
@Slf4j
@Component
@Profile("!cloud")
public class ServerStatusAlertScheduler {

    /** 同一指标同一严重档的最小重发间隔（小时）。 */
    static final int THROTTLE_HOURS = 6;

    // 类型与重要度都必须落在 NoticeService 的白名单内（TYPES / PRIORITIES）——
    // 写 "warning"/"info" 会在运行时被 NoticeService 直接拒绝（那两个值不在 TYPES 里）。
    // 危急走 urgent 顶到强提醒，警告走 system+important，恢复走 system+normal
    //（别为好消息打扰人）。
    private static final String TYPE_WARNING = "system";
    private static final String TYPE_CRITICAL = "urgent";
    private static final String TYPE_RECOVERED = "system";
    private static final String PRIORITY_WARNING = "important";
    private static final String PRIORITY_CRITICAL = "urgent";
    private static final String PRIORITY_RECOVERED = "normal";

    /** 接收本告警所需的权限码（V552）。 */
    static final String RECEIVE_AUTHORITY = "server_status:alert:receive";

    /** 点通知里的「查看详情」跳到状态页。 */
    private static final String ACTION_ROUTE = "/admin/server-status";

    private static final String PUBLISHER = "系统监控";

    private final ServerStatusService service;
    private final NoticeService notices;
    private final JdbcTemplate jdbc;

    /** 上一轮每个指标的严重档（仅用于「恢复」判定，见类注释的已知边界）。 */
    private final Map<String, String> lastSeverity = new HashMap<>();

    public ServerStatusAlertScheduler(ServerStatusService service,
                                      NoticeService notices,
                                      JdbcTemplate jdbc) {
        this.service = service;
        this.notices = notices;
        this.jdbc = jdbc;
    }

    /**
     * 每 5 分钟一轮。启动后先等 2 分钟——刚起来时堆/连接池的读数还没稳，
     * 立刻采样容易发一条开机即消失的假告警。
     */
    @Scheduled(fixedDelayString = "300000", initialDelayString = "120000")
    public void scan() {
        try {
            ServerStatusView snapshot = service.current();
            if (snapshot == null) return;
            List<ServerStatusView.Alert> alerts = snapshot.alerts() == null
                    ? List.of() : snapshot.alerts();

            // 本轮各指标的严重档；采样本身失败时（alerts 里只有 sampling/UNKNOWN）
            // 不清空上一轮状态，免得把「探测挂了」误判成「一切恢复」。
            Map<String, String> current = new LinkedHashMap<>();
            for (ServerStatusView.Alert alert : alerts) {
                if (alert == null || alert.key() == null) continue;
                current.put(alert.key(), alert.status());
            }
            boolean samplingBroken = current.containsKey("sampling");

            List<UUID> audience = null;
            for (ServerStatusView.Alert alert : alerts) {
                if (alert == null || alert.key() == null) continue;
                if (!"WARNING".equals(alert.status()) && !"CRITICAL".equals(alert.status())) {
                    continue;
                }
                if (audience == null) audience = receivers();
                if (audience.isEmpty()) return;
                boolean critical = "CRITICAL".equals(alert.status());
                publishThrottled(
                        audience,
                        sourceEvent(alert.key(), alert.status()),
                        (critical ? "【危急】" : "【警告】") + alert.message(),
                        alert.suggestion() == null || alert.suggestion().isBlank()
                                ? alert.message()
                                : alert.message() + "\n\n" + alert.suggestion(),
                        critical ? TYPE_CRITICAL : TYPE_WARNING,
                        critical ? PRIORITY_CRITICAL : PRIORITY_WARNING);
            }

            if (!samplingBroken) {
                for (Map.Entry<String, String> previous : lastSeverity.entrySet()) {
                    if (!"CRITICAL".equals(previous.getValue())) continue;
                    String now = current.get(previous.getKey());
                    if ("CRITICAL".equals(now)) continue;
                    if (audience == null) audience = receivers();
                    if (audience.isEmpty()) break;
                    publishThrottled(
                            audience,
                            sourceEvent(previous.getKey(), "RECOVERED"),
                            "【已恢复】" + previous.getKey(),
                            "此前处于危急状态的指标 " + previous.getKey() + " 已回到正常范围。",
                            TYPE_RECOVERED, PRIORITY_RECOVERED);
                }
                lastSeverity.clear();
                lastSeverity.putAll(current);
            }
        } catch (Exception unavailable) {
            log.warn("服务器状态告警扫描失败(不影响业务): {}", unavailable.toString());
        }
    }

    /** {@code SERVER_STATUS_ALERT:<指标>:<档>}；换档即换事件，因此升级不受旧档节流压制。 */
    static String sourceEvent(String key, String severity) {
        return "SERVER_STATUS_ALERT:" + key + ":" + severity;
    }

    private void publishThrottled(List<UUID> audience, String sourceEvent,
                                  String title, String content,
                                  String type, String priority) {
        Instant since = Instant.now().minus(Duration.ofHours(THROTTLE_HOURS));
        for (UUID userId : audience) {
            try {
                if (sentRecently(userId, sourceEvent, since)) continue;
                notices.publishForUser(userId, title, content, type, PUBLISHER,
                        ACTION_ROUTE, sourceEvent, priority);
            } catch (Exception failed) {
                log.warn("服务器状态告警发送失败 user={} event={}: {}",
                        userId, sourceEvent, failed.toString());
            }
        }
    }

    private boolean sentRecently(UUID userId, String sourceEvent, Instant since) {
        Integer hit = jdbc.queryForObject("""
                SELECT count(*) FROM notices notice
                JOIN notice_user_states state ON state.notice_id = notice.id
                WHERE notice.source_event = ? AND state.user_id = ?
                  AND notice.created_at >= ?
                """, Integer.class, sourceEvent, userId, java.sql.Timestamp.from(since));
        return hit != null && hit > 0;
    }

    /** 持有接收权的活跃账号（含超管）。 */
    private List<UUID> receivers() {
        List<UUID> result = new ArrayList<>(jdbc.query("""
                SELECT DISTINCT account.id
                FROM users account
                WHERE COALESCE(account.is_deleted,FALSE)=FALSE AND account.status='active'
                  AND (account.is_super_admin = TRUE OR EXISTS (
                      SELECT 1 FROM user_permission_overrides override
                      JOIN permissions permission ON permission.id = override.permission_id
                      WHERE override.user_id = account.id AND override.active = TRUE
                        AND override.effect = 'ALLOW' AND permission.code = ?
                        AND permission.active = TRUE)
                   OR EXISTS (
                      SELECT 1 FROM department_permissions allocation
                      JOIN permissions permission ON permission.id = allocation.permission_id
                      JOIN employees staff ON staff.id = account.employee_id
                      WHERE allocation.department_id = staff.department_id
                        AND permission.code = ? AND permission.active = TRUE))
                """, (rs, row) -> (UUID) rs.getObject(1), RECEIVE_AUTHORITY, RECEIVE_AUTHORITY));
        if (result.isEmpty()) {
            log.debug("没有账号持有 {}，服务器状态告警本轮不发送", RECEIVE_AUTHORITY);
        }
        return result;
    }
}
