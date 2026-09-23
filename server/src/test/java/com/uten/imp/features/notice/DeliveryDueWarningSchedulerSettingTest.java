package com.uten.imp.features.notice;

import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

import java.time.LocalDate;
import java.util.List;

import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** audit-retention-settings-12: 交货期预警提前天数读系统设置, 改成 5 天后扫描窗口按 5 天走。 */
class DeliveryDueWarningSchedulerSettingTest {

    @Test
    void scanWindowFollowsTheConfiguredWarningDays() {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        SystemSettingsService settings = mock(SystemSettingsService.class);
        when(settings.readInt(SystemSettingKey.DELIVERY_DUE_WARNING_DAYS)).thenReturn(5);
        LocalDate businessDay = LocalDate.of(2026, 9, 24);
        when(jdbc.queryForList(anyString(), eq(businessDay.plusDays(5)))).thenReturn(List.of());

        new DeliveryDueWarningScheduler(jdbc, mock(ChainNoticeService.class), settings).scan(businessDay);

        verify(jdbc).queryForList(anyString(), eq(LocalDate.of(2026, 9, 29)));
    }
}
