package com.uten.imp.features.notice;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.common.time.BusinessTime;
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

    static final int DUE_DAYS = 3;
    static final String EVENT_SUBCONTRACT_RETURN_DUE =
            "SUBCONTRACT_RETURN_DUE";

    private final JdbcTemplate jdbc;
    private final BusinessEventPublisher outbox;

    @Scheduled(cron = "0 49 8 * * *", zone = "Asia/Shanghai")
    public void scan() {
        LocalDate businessDate = BusinessTime.today();
        try {
            var due = SubcontractReturnDueFacts.findDue(
                    jdbc, businessDate.plusDays(DUE_DAYS));
            for (SubcontractReturnDueFacts.Snapshot order : due) {
                try {
                    outbox.publishOnce(
                            EVENT_SUBCONTRACT_RETURN_DUE,
                            "SUBCONTRACT_ORDER",
                            order.orderId(),
                            Map.of("businessDate", businessDate.toString()),
                            EVENT_SUBCONTRACT_RETURN_DUE
                                    + ':' + order.orderId() + ':' + businessDate);
                } catch (RuntimeException ex) {
                    log.warn("委外回厂交期事件投递失败(下次扫描可重试)：orderId={}, error={}",
                            order.orderId(), ex.toString());
                }
            }
            if (!due.isEmpty()) {
                log.info("委外回厂交期扫描完成：{} 笔已出仓订单在 {} 天窗口内仍未物理回厂",
                        due.size(), DUE_DAYS);
            }
        } catch (RuntimeException ex) {
            log.warn("委外回厂交期扫描失败(不影响业务)：{}", ex.toString());
        }
    }
}
