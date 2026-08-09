package com.uten.imp.config.cloud;

import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.Statement;

/**
 * 云端主库可达性探针。周期 SELECT 1 探主库；不可达则标记 down，{@link CloudRoutingDataSource}
 * 据此降级（只读走副本、写 503）。仅 cloud profile。
 */
@Slf4j
@Component
@Profile("cloud")
public class PrimaryHealthIndicator {

    private final DataSource primaryDataSource;
    private volatile boolean up = true;

    public PrimaryHealthIndicator(@Qualifier("primaryDataSource") DataSource primaryDataSource) {
        this.primaryDataSource = primaryDataSource;
    }

    /** 主库是否可达。 */
    public boolean isUp() {
        return up;
    }

    /** 测试/运维用：手动翻转状态。 */
    void setUp(boolean up) {
        boolean was = this.up;
        this.up = up;
        if (was != up) {
            log.info("主库可达性手动翻转 -> {}", up ? "UP" : "DOWN");
        }
    }

    @Scheduled(fixedDelayString = "${uten.cloud.primary-health-interval-ms:10000}",
            initialDelayString = "${uten.cloud.primary-health-initial-delay-ms:30000}")
    public void ping() {
        try (Connection c = primaryDataSource.getConnection();
             Statement st = c.createStatement()) {
            st.execute("SELECT 1");
            if (!up) {
                log.info("主库恢复可达，云端退出只读降级");
            }
            up = true;
        } catch (Exception e) {
            if (up) {
                log.warn("主库不可达，云端进入只读降级（写请求将 503）: {}", e.getClass().getSimpleName());
            }
            up = false;
        }
    }
}
