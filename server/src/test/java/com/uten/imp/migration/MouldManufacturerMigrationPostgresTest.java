package com.uten.imp.migration;

import com.uten.imp.support.MigratedProjectionSchema;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.nio.charset.StandardCharsets;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

@Testcontainers(disabledWithoutDocker = true)
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MouldManufacturerMigrationPostgresTest {
    @Container
    static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");

    @Test
    void forwardMigrationKeepsExistingMonthAndIdentifiersAndAllowsManufacturer() throws Exception {
        var db = new JdbcTemplate(new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
        MigratedProjectionSchema.createTables(db, "868", "moulds");
        var id = UUID.randomUUID();
        db.update("INSERT INTO moulds(id,legacy_id,name,code,mstatus,remark) VALUES(?,250,'旧模具','OLD-1','1995年7月','原备注')", id);
        try (var source = getClass().getResourceAsStream("/db/migration/V869__mould_manufacturer.sql")) {
            if (source == null) throw new IllegalStateException("Missing V869 migration");
            db.execute(new String(source.readAllBytes(), StandardCharsets.UTF_8));
        }
        var row = db.queryForMap("SELECT id,legacy_id,code,mstatus,remark,manufacturer FROM moulds WHERE id=?", id);
        assertThat(row).containsEntry("id", id).containsEntry("legacy_id", 250)
                .containsEntry("code", "OLD-1").containsEntry("mstatus", "1995年7月")
                .containsEntry("remark", "原备注").containsEntry("manufacturer", null);
        db.update("UPDATE moulds SET manufacturer='制造商甲' WHERE id=?", id);
        assertThat(db.queryForObject("SELECT manufacturer FROM moulds WHERE id=?", String.class, id))
                .isEqualTo("制造商甲");
    }
}
