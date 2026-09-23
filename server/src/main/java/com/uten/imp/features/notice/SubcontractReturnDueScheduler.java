package com.uten.imp.features.notice;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.time.LocalDate;
import java.util.Map;

/** Daily, idempotent warning for subcontract work not physically returned. */
@Slf4j
@Component
@Profile("!cloud")
@RequiredArgsConstructor
public class SubcontractReturnDueScheduler {

    static final String EVENT_SUBCONTRACT_RETURN_DUE =
            "SUBCONTRACT_RETURN_DUE";

    private final JdbcTemplate jdbc;
    private final BusinessEventPublisher outbox;
    private final SystemSettingsService settings;

    @Scheduled(cron = "0 49 8 * * *", zone = "Asia/Shanghai")
    public void scan() {
        LocalDate businessDate = BusinessTime.today();
        try {
            // 提前天数读系统设置「委外回厂预警提前天数」, 随事件一起下发, 投递时按同一窗口复核。
            int dueDays = settings.readInt(SystemSettingKey.SUBCONTRACT_RETURN_DUE_DAYS);
            var due = SubcontractReturnDueFacts.findDue(
                    jdbc, businessDate.plusDays(dueDays));
            for (SubcontractReturnDueFacts.Snapshot order : due) {
                try {
                    outbox.publishOnce(
                            EVENT_SUBCONTRACT_RETURN_DUE,
                            "SUBCONTRACT_ORDER",
                            order.orderId(),
                            Map.of("businessDate", businessDate.toString(),
                                    "dueDays", dueDays),
                            EVENT_SUBCONTRACT_RETURN_DUE
                                    + ':' + order.orderId() + ':' + businessDate);
                } catch (RuntimeException ex) {
                    log.warn("委外回厂交期事件投递失败(下次扫描可重试)：orderId={}, error={}",
                            order.orderId(), ex.toString());
                }
            }
            if (!due.isEmpty()) {
                log.info("委外回厂交期扫描完成：{} 笔已出仓订单在 {} 天窗口内仍未物理回厂",
                        due.size(), dueDays);
            }
        } catch (RuntimeException ex) {
            log.warn("委外回厂交期扫描失败(不影响业务)：{}", ex.toString());
        }
    }
}
