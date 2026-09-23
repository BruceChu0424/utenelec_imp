package com.uten.imp.features.notice;
import com.uten.imp.common.util.NativeValueConverters;

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
import java.time.temporal.ChronoUnit;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 延期预警每日扫描（SOP §一：交货前 N 天未结案 → 通知业务员 + 调度；列表标红由订单 DTO delayWarning 派生承担）。
 * N 读系统设置「交货期预警提前天数」(delivery_due_warning_days), 每次扫描时读取, 改完次日生效。
 *
 * <p>每天 08:23 跑一次（避开整点/半点拥堵）。同一订单同一接收人同日只发一条
 * （按 notices 标题+接收人+当日已发去重，不新增表）。扫描与发送全部旁路，异常只记日志。
 */
@Slf4j
@Component
@Profile("!cloud")
@RequiredArgsConstructor
public class DeliveryDueWarningScheduler {

    private final JdbcTemplate jdbc;
    private final ChainNoticeService chainNotice;
    private final SystemSettingsService settings;

    @Scheduled(cron = "0 23 8 * * *", zone = "Asia/Shanghai")
    public void scan() {
        scan(BusinessTime.today());
    }

    /** 以给定业务日期扫描 (测试可注入日期, 不依赖真实时钟)。 */
    void scan(LocalDate today) {
        try {
            int dueDays = settings.readInt(SystemSettingKey.DELIVERY_DUE_WARNING_DAYS);
            LocalDate deadline = today.plusDays(dueDays);
            // 只管业务链订单（chain_status > 0）：历史迁移单 chain=0 不预警，避免老库遗留单刷屏
            List<Map<String, Object>> rows = jdbc.queryForList("""
                    SELECT DISTINCT o.id, o.deliver_date FROM sales_orders o
                    WHERE o.status = 1 AND o.is_closed = false AND o.is_stopped = false
                      AND o.deliver_date IS NOT NULL AND o.deliver_date <= ?
                      AND EXISTS (SELECT 1 FROM sales_order_items i
                          WHERE i.order_id = o.id AND COALESCE(i.is_deleted, false) = false
                            AND COALESCE(i.chain_status, 0) > 0)
                    """, deadline);
            for (Map<String, Object> r : rows) {
                LocalDate deliver = NativeValueConverters.toLocalDate(r.get("deliver_date"));
                long daysLeft = ChronoUnit.DAYS.between(today, deliver);
                chainNotice.notifyDeliveryDueIfNotSentToday((UUID) r.get("id"), daysLeft);
            }
            if (!rows.isEmpty()) {
                log.info("延期预警扫描完成：{} 笔订单在 {} 天窗口内", rows.size(), dueDays);
            }
        } catch (Exception e) {
            log.warn("延期预警扫描失败(不影响业务): {}", e.toString());
        }
    }
}
