package com.uten.imp.audit;

import com.uten.imp.common.time.BusinessTime;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.annotation.Profile;
import org.springframework.context.event.EventListener;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.Date;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Clock;
import java.time.LocalDate;

/**
 * 保证审计在线表当月及之后 {@value #MONTHS_AHEAD} 个月的月分区已经建好(ADR-105)。
 *
 * <p>审计表按月分区且不设兜底分区: 写到没有分区的月份会让整条业务事务失败。分区预建因此
 * 不跟留存开关走, 启动时和每天各做一次, 幂等; 留存任务运行时也会顺带预建。
 * 与其他调度任务一样云端实例不跑(ADR-031 本地唯一主库), 分区由本地主实例预建。
 */
@Slf4j
@Component
@Profile("!cloud")
public class AuditPartitionMaintainer {

    static final int MONTHS_AHEAD = 3;
    private static final String ENSURE_PARTITION_SQL =
            "SELECT fn_audit_ensure_partition('audit_log', ?)";

    private final DataSource dataSource;
    private final Clock clock;

    @Autowired
    public AuditPartitionMaintainer(DataSource dataSource) {
        this(dataSource, Clock.systemUTC());
    }

    AuditPartitionMaintainer(DataSource dataSource, Clock clock) {
        this.dataSource = dataSource;
        this.clock = clock;
    }

    @EventListener(ApplicationReadyEvent.class)
    public void ensureOnStartup() {
        try {
            ensureUpcoming();
        } catch (RuntimeException exception) {
            log.error("Failed to ensure upcoming audit partitions on startup", exception);
        }
    }

    @Scheduled(cron = "${uten.audit.partition.cron:0 7 1 * * *}", zone = "Asia/Shanghai")
    public void ensureUpcoming() {
        LocalDate month = LocalDate.now(clock.withZone(BusinessTime.ZONE)).withDayOfMonth(1);
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(ENSURE_PARTITION_SQL)) {
            for (int offset = 0; offset <= MONTHS_AHEAD; offset++) {
                statement.setDate(1, Date.valueOf(month.plusMonths(offset)));
                try (ResultSet ignored = statement.executeQuery()) {
                    // 返回新建分区名或空; 这里只需要保证存在。
                }
            }
        } catch (SQLException exception) {
            throw new IllegalStateException("审计分区预建失败", exception);
        }
    }
}
