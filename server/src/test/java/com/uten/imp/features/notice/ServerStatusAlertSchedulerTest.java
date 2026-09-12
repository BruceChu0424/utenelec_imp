package com.uten.imp.features.notice;

import com.uten.imp.features.admin.serverstatus.ServerStatusService;
import com.uten.imp.features.admin.serverstatus.ServerStatusView;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.sql.Timestamp;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 服务器状态告警推送的四条硬约束。
 *
 * <p>背景：告警此前只塞进状态页返回值，没人推。用户 2026-09-11：
 * 「有任何报警 都推给我」「我就怕业务附件 196G 不够用」。
 */
class ServerStatusAlertSchedulerTest {

    private ServerStatusService status;
    private NoticeService notices;
    private JdbcTemplate jdbc;
    private ServerStatusAlertScheduler scheduler;
    private final UUID receiver = UUID.randomUUID();

    @BeforeEach
    @SuppressWarnings("unchecked")
    void setUp() {
        status = mock(ServerStatusService.class);
        notices = mock(NoticeService.class);
        jdbc = mock(JdbcTemplate.class);
        // 默认：有一个接收人，且从没发过（不被节流）。
        when(jdbc.query(anyString(), any(RowMapper.class), any(Object[].class)))
                .thenReturn(List.of(receiver));
        when(jdbc.query(anyString(), any(RowMapper.class), any(), any()))
                .thenReturn(List.of(receiver));
        when(jdbc.queryForObject(anyString(), eq(Integer.class), any(), any(), any()))
                .thenReturn(0);
        scheduler = new ServerStatusAlertScheduler(status, notices, jdbc);
    }

    private void snapshot(ServerStatusView.Alert... alerts) {
        ServerStatusView view = mock(ServerStatusView.class);
        when(view.alerts()).thenReturn(List.of(alerts));
        when(status.current()).thenReturn(view);
    }

    /**
     * 类型与重要度必须落在 NoticeService 白名单内。写 "warning"/"info" 会被
     * NoticeService 直接拒绝——那是运行期才炸的错，这里在编译期之外再钉一道。
     */
    @Test
    void publishesWithWhitelistedTypeAndPriority() {
        snapshot(new ServerStatusView.Alert("disk-1", "CRITICAL", "附件存储 使用率危急", "清理或扩容"));

        scheduler.scan();

        ArgumentCaptor<String> type = ArgumentCaptor.forClass(String.class);
        ArgumentCaptor<String> priority = ArgumentCaptor.forClass(String.class);
        verify(notices).publishForUser(eq(receiver), anyString(), anyString(),
                type.capture(), anyString(), anyString(), anyString(), priority.capture());
        // NoticeService.TYPES / PRIORITIES 里的合法值。
        assertThat(type.getValue()).isEqualTo("urgent");
        assertThat(priority.getValue()).isEqualTo("urgent");
    }

    /** NORMAL / UNKNOWN 不该催人：拿不到数不等于有事要办。 */
    @Test
    void ignoresNormalAndUnknownMetrics() {
        snapshot(new ServerStatusView.Alert("disk-1", "NORMAL", "正常", ""),
                new ServerStatusView.Alert("backup", "UNKNOWN", "读不到", ""));

        scheduler.scan();

        verify(notices, never()).publishForUser(any(), anyString(), anyString(),
                anyString(), anyString(), anyString(), anyString(), anyString());
    }

    /** 节流判据必须带「同一指标 + 同一档」，否则升级会被旧档压住。 */
    @Test
    void throttleKeyCarriesBothMetricAndSeverity() {
        assertThat(ServerStatusAlertScheduler.sourceEvent("disk-1", "WARNING"))
                .isEqualTo("SERVER_STATUS_ALERT:disk-1:WARNING");
        assertThat(ServerStatusAlertScheduler.sourceEvent("disk-1", "CRITICAL"))
                .isNotEqualTo(ServerStatusAlertScheduler.sourceEvent("disk-1", "WARNING"));
    }

    /** 节流命中时不发——重启也不会重新刷一遍（判据在 notices 表里，不在内存）。 */
    @Test
    void skipsWhenAlreadySentWithinWindow() {
        when(jdbc.queryForObject(anyString(), eq(Integer.class), any(), any(), any()))
                .thenReturn(1);
        snapshot(new ServerStatusView.Alert("disk-1", "WARNING", "附件存储 使用率偏高", ""));

        scheduler.scan();

        verify(notices, never()).publishForUser(any(), anyString(), anyString(),
                anyString(), anyString(), anyString(), anyString(), anyString());
        // 节流窗口是按时间比的，必须真的传了一个时间下界进去。
        verify(jdbc).queryForObject(anyString(), eq(Integer.class),
                eq(ServerStatusAlertScheduler.sourceEvent("disk-1", "WARNING")),
                eq(receiver), any(Timestamp.class));
    }

    /** 探测本身挂掉（sampling）时不得把上一轮的 CRITICAL 误判成「已恢复」。 */
    @Test
    void brokenSamplingDoesNotFakeRecovery() {
        snapshot(new ServerStatusView.Alert("disk-1", "CRITICAL", "附件存储 使用率危急", ""));
        scheduler.scan(); // 记住 disk-1 = CRITICAL

        snapshot(new ServerStatusView.Alert("sampling", "UNKNOWN", "采样不可用", ""));
        scheduler.scan();

        // 第二轮不该出现任何「已恢复」。
        verify(notices, never()).publishForUser(any(),
                org.mockito.ArgumentMatchers.contains("已恢复"), anyString(),
                anyString(), anyString(), anyString(), anyString(), anyString());
        // 第一轮那条危急通知照发（只发了一次）。
        verify(notices, times(1)).publishForUser(any(), anyString(), anyString(),
                anyString(), anyString(), anyString(), anyString(), anyString());
    }

    /** 危急消失后补一条「已恢复」，免得人一直悬着。 */
    @Test
    void sendsRecoveryAfterCriticalClears() {
        snapshot(new ServerStatusView.Alert("disk-1", "CRITICAL", "附件存储 使用率危急", ""));
        scheduler.scan();

        snapshot(new ServerStatusView.Alert("disk-1", "NORMAL", "正常", ""));
        scheduler.scan();

        verify(notices).publishForUser(eq(receiver),
                org.mockito.ArgumentMatchers.contains("已恢复"), anyString(),
                eq("system"), anyString(), anyString(),
                eq(ServerStatusAlertScheduler.sourceEvent("disk-1", "RECOVERED")),
                eq("normal"));
    }

    /** 没有接收人时整轮静默——不抛异常、不影响业务。 */
    @Test
    void staysSilentWithoutReceivers() {
        when(jdbc.query(anyString(), any(RowMapper.class), any(), any()))
                .thenReturn(List.of());
        snapshot(new ServerStatusView.Alert("disk-1", "CRITICAL", "危急", ""));

        scheduler.scan();

        verify(notices, never()).publishForUser(any(), anyString(), anyString(),
                anyString(), anyString(), anyString(), anyString(), anyString());
    }

    /** 任何异常只记日志，绝不冒泡到定时器线程。 */
    @Test
    void swallowsProbeFailure() {
        when(status.current()).thenThrow(new IllegalStateException("probe down"));
        scheduler.scan();
        verify(notices, never()).publishForUser(any(), anyString(), anyString(),
                anyString(), anyString(), anyString(), anyString(), anyString());
    }

    @Test
    void throttleWindowIsSixHours() {
        assertThat(ServerStatusAlertScheduler.THROTTLE_HOURS).isEqualTo(6);
        assertThat(Instant.now()).isNotNull();
    }
}
