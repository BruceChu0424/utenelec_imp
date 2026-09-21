package com.uten.imp.features.subcontract.short_delivery;

import com.uten.imp.common.time.BusinessTime;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.time.LocalDate;

/**
 * ADR-098：分批到货过了预计到齐日仍未到齐的短交案件, 每天早上提醒一次(Outbox 幂等键 = 案件 + 业务日)。
 * 只发通知不改状态; 判定页与任务中心按「有效状态」把它当待判定(逾期)显示并计红徽章。
 */
@Slf4j
@Component
@Profile("!cloud")
@RequiredArgsConstructor
public class SubcontractShortDeliveryOverdueScheduler {

    private final SubcontractShortDeliveryService service;

    @Scheduled(cron = "0 53 8 * * *", zone = "Asia/Shanghai")
    public void scan() {
        LocalDate businessDate = BusinessTime.today();
        try {
            int due = service.publishOverdueWaiting(businessDate);
            if (due > 0) {
                log.info("委外回厂短交逾期扫描完成：{} 个分批到货案件已过预计到齐日仍未到齐", due);
            }
        } catch (RuntimeException ex) {
            log.warn("委外回厂短交逾期扫描失败(不影响业务)：{}", ex.toString());
        }
    }
}
