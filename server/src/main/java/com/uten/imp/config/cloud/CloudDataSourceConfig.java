package com.uten.imp.config.cloud;

import com.zaxxer.hikari.HikariDataSource;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.boot.jdbc.DataSourceBuilder;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Primary;
import org.springframework.context.annotation.Profile;

import javax.sql.DataSource;

/**
 * 云端双数据源装配（仅 {@code cloud} profile）。主库=on-prem（经 VPN/专线），副本=云端本地只读 PG。
 * {@link CloudRoutingDataSource} 为 {@link Primary}，Hibernate/EntityManagerFactory 自动经它路由。
 *
 * <p>非 cloud profile（dev/prod/测试）完全不装配本类 → 单数据源 auto-config 路径零改动、零影响。
 */
@Configuration
@Profile("cloud")
public class CloudDataSourceConfig {

    @Bean("primaryDataSource")
    public DataSource primaryDataSource(CloudDbProperties props) {
        return build("primary", props.getPrimary());
    }

    @Bean("replicaDataSource")
    public DataSource replicaDataSource(CloudDbProperties props) {
        return build("replica", props.getReplica());
    }

    @Bean
    @Primary
    public DataSource routingDataSource(@Qualifier("primaryDataSource") DataSource primary,
                                        @Qualifier("replicaDataSource") DataSource replica,
                                        PrimaryHealthIndicator health) {
        return new CloudRoutingDataSource(primary, replica, health);
    }

    private DataSource build(String pool, CloudDbProperties.Target t) {
        if (t.getUrl() == null || t.getUrl().isBlank()) {
            // fail-fast：cloud profile 缺密钥/URL 不应静默启动。
            throw new IllegalStateException(
                    "app.cloud.db." + pool + ".url 未配置：cloud profile 必须设置 "
                            + (pool.contains("primary") ? "UTEN_DB_PRIMARY_URL" : "UTEN_DB_REPLICA_URL"));
        }
        HikariDataSource ds = DataSourceBuilder.create()
                .type(HikariDataSource.class)
                .url(t.getUrl())
                .username(t.getUsername())
                .password(t.getPassword())
                .build();
        ds.setPoolName("cloud-" + pool);
        ds.setMaximumPoolSize(20);
        ds.setMinimumIdle(2);
        ds.setConnectionTimeout(5_000);
        return ds;
    }
}
