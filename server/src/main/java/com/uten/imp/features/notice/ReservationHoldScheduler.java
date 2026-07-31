package com.uten.imp.features.notice;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 预留持有逾期每日扫描（V178 缺口 A）。
 *
 * <p>扫"有生效预留、持有截止已过、订单未结案/未中止/未发完"的订单，通知归属销售跟进
 * （尽快发货，或改量/取消释放库存，或由主管做稀缺让单）。<b>默认只通知、不自动释放</b>——
 * 自动释放须同步回写 sales_order_items.reserved_qty/chain_status 才不库存漂移，留后续 opt-in。
 *
 * <p>持有截止 = COALESCE(预留 hold_until, 订单交货日 + 宽限期)，与交货前 3 天的延期预警
 * （{@link DeliveryDueWarningScheduler}）互补、不重叠：那个管"快到期"，本扫描管"已过交货+
 * 宽限期仍占着货"（对标 SAP OMBN 保留期 + RM07RVER 批清理，并补上三大 ERP 都缺的"过期提醒"）。
 *
 * <p>每天 08:37 跑（避开 08:23 延期预警与其它整点拥堵）。扫描与发送全旁路，异常只记日志。
 *
 * <p>架构：本类在 notice 包，故意不 import stock 特性（避免 notice→stock 跨特性边，ADR-017）。
 * 宽限期本地常量，须与 {@code StockReservationService.HOLD_GRACE_DAYS} 保持同值（销售侧逾期天数
 * 计算用后者，本扫描用前者）。
 */
@Slf4j
@Component
@RequiredArgsConstructor
public class ReservationHoldScheduler {

    /** 持有宽限期（天）：交货日过后再容忍 N 天才视为逾期持有。须与 StockReservationService.HOLD_GRACE_DAYS 同值。 */
    private static final int HOLD_GRACE_DAYS = 7;

    private final JdbcTemplate jdbc;
    private final ChainNoticeService chainNotice;

    @Scheduled(cron = "0 37 8 * * *", zone = "Asia/Shanghai")
    public void scan() {
        try {
            int grace = HOLD_GRACE_DAYS;
            // 一张订单多条预留时取最早截止；只保留截止已过的；只算 hold_until 非空或交货日非空的行
            List<Map<String, Object>> rows = jdbc.queryForList("""
                    WITH held AS (
                        SELECT i.order_id,
                               MIN(CASE
                                   WHEN r.hold_until IS NOT NULL THEN r.hold_until
                                   ELSE (COALESCE(i.deliver_date, o.deliver_date)
                                         + make_interval(days => ?))::timestamptz
                               END) AS deadline
                        FROM stock_reservations r
                        JOIN sales_order_items i ON i.id = r.order_item_id
                        JOIN sales_orders o ON o.id = i.order_id
                        WHERE r.is_deleted = FALSE AND r.status = 0
                          AND (r.qty - r.consumed_qty - r.released_qty) > 0
                          AND o.status = 1
                          AND COALESCE(o.is_closed, FALSE) = FALSE
                          AND COALESCE(o.is_stopped, FALSE) = FALSE
                          AND COALESCE(i.chain_status, 0) > 0
                          AND (r.hold_until IS NOT NULL
                               OR COALESCE(i.deliver_date, o.deliver_date) IS NOT NULL)
                        GROUP BY i.order_id
                    )
                    SELECT order_id, deadline FROM held WHERE deadline < now()
                    """, grace);
            Instant now = Instant.now();
            int notified = 0;
            for (Map<String, Object> r : rows) {
                Object dl = r.get("deadline");
                if (dl == null) continue;
                Instant deadline = (dl instanceof java.sql.Timestamp t) ? t.toInstant()
                        : ((java.util.Date) dl).toInstant();
                long overdue = Math.max(0, Duration.between(deadline, now).toDays());
                chainNotice.notifyReservationHoldOverdueIfNotSentToday((UUID) r.get("order_id"), overdue);
                notified++;
            }
            if (notified > 0) {
                log.info("预留持有逾期扫描完成：{} 笔订单持有截止已过（宽限 {} 天）", notified, grace);
            }
        } catch (Exception e) {
            log.warn("预留持有逾期扫描失败（不影响业务）: {}", e.toString());
        }
    }
}
