package com.uten.imp.config.cloud;

import com.zaxxer.hikari.HikariDataSource;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.assertEquals;

class CloudDataSourceConfigTest {

    private final CloudDataSourceConfig config = new CloudDataSourceConfig();

    @Test
    void missingUrlUsernameOrPasswordFailsBeforePoolUse() {
        CloudDbProperties props = new CloudDbProperties();
        CloudDbProperties.Target primary = props.getPrimary();

        primary.setUsername("uten");
        primary.setPassword("secret");
        assertThrows(IllegalStateException.class, () -> config.primaryDataSource(props));

        primary.setUrl(trustedUrl("primary"));
        primary.setUsername(" ");
        assertThrows(IllegalStateException.class, () -> config.primaryDataSource(props));

        primary.setUsername("uten");
        primary.setPassword("");
        assertThrows(IllegalStateException.class, () -> config.primaryDataSource(props));

        primary.setPassword("secret");
        primary.setUrl("https://primary.example.test/uten");
        assertThrows(IllegalStateException.class, () -> config.primaryDataSource(props));

        primary.setUrl("jdbc:postgresql://primary.example.test:5432/uten?sslmode=require");
        assertThrows(IllegalStateException.class, () -> config.primaryDataSource(props));

        primary.setUrl("jdbc:postgresql://primary.example.test:5432/uten?sslmode=verify-full");
        assertThrows(IllegalStateException.class, () -> config.primaryDataSource(props));
    }

    @Test
    void replicaPoolIsReadOnlyWhilePrimaryPoolIsWritable() {
        CloudDbProperties props = configuredProperties();
        try (HikariDataSource primary =
                     (HikariDataSource) config.primaryDataSource(props);
             HikariDataSource replica =
                     (HikariDataSource) config.replicaDataSource(props)) {
            assertFalse(primary.isReadOnly());
            assertTrue(replica.isReadOnly());
            assertEquals("5", primary.getDataSourceProperties().getProperty("connectTimeout"));
            assertEquals("5", primary.getDataSourceProperties().getProperty("socketTimeout"));
            assertEquals("true", primary.getDataSourceProperties().getProperty("tcpKeepAlive"));
            assertEquals("SET jit = false; SET lock_timeout = '10s'; SET statement_timeout = '60s'; SET idle_in_transaction_session_timeout = '120s'", primary.getConnectionInitSql());
            assertEquals("SET jit = false; SET lock_timeout = '10s'; SET statement_timeout = '60s'; SET idle_in_transaction_session_timeout = '120s'", replica.getConnectionInitSql());
        }
    }

    @Test
    void deploymentOverrideAppliesToBothCloudPools() {
        org.springframework.test.util.ReflectionTestUtils.setField(config, "jitEnabled", true);
        try (HikariDataSource primary = (HikariDataSource) config.primaryDataSource(configuredProperties());
             HikariDataSource replica = (HikariDataSource) config.replicaDataSource(configuredProperties())) {
            assertEquals("SET jit = true; SET lock_timeout = '10s'; SET statement_timeout = '60s'; SET idle_in_transaction_session_timeout = '120s'", primary.getConnectionInitSql());
            assertEquals("SET jit = true; SET lock_timeout = '10s'; SET statement_timeout = '60s'; SET idle_in_transaction_session_timeout = '120s'", replica.getConnectionInitSql());
        }
    }

    /** ADR-107: 云端主/副池与普通连接池同一套服务端截止时间, 配置值只能是时长写法。 */
    @Test
    void cloudPoolsCarryTheSameServerSideDeadlinesAndRejectNonDurationValues() {
        try (HikariDataSource primary = (HikariDataSource) config.primaryDataSource(configuredProperties())) {
            assertEquals(120_000, primary.getLeakDetectionThreshold());
        }
        org.springframework.test.util.ReflectionTestUtils.setField(config, "lockTimeout", "5s'; DROP TABLE users; --");
        assertThrows(IllegalStateException.class, () -> config.primaryDataSource(configuredProperties()));
        assertEquals("2min", CloudDataSourceConfig.duration("x", " 2min "));
    }

    private CloudDbProperties configuredProperties() {
        CloudDbProperties props = new CloudDbProperties();
        configure(props.getPrimary(), "primary");
        configure(props.getReplica(), "replica");
        return props;
    }

    private void configure(CloudDbProperties.Target target, String host) {
        target.setUrl(trustedUrl(host));
        target.setUsername("uten");
        target.setPassword("secret");
    }

    private String trustedUrl(String host) {
        return "jdbc:postgresql://" + host
                + ".example.test:5432/uten?sslmode=verify-full"
                + "&sslrootcert=/etc/uten-imp/tls/company-root-ca.crt";
    }
}
