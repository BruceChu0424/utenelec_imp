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

        primary.setUrl("jdbc:postgresql://primary.example.test:5432/uten?sslmode=verify-full");
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
        }
    }

    private CloudDbProperties configuredProperties() {
        CloudDbProperties props = new CloudDbProperties();
        configure(props.getPrimary(), "primary");
        configure(props.getReplica(), "replica");
        return props;
    }

    private void configure(CloudDbProperties.Target target, String host) {
        target.setUrl("jdbc:postgresql://" + host
                + ".example.test:5432/uten?sslmode=verify-full");
        target.setUsername("uten");
        target.setPassword("secret");
    }
}
