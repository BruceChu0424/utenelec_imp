package com.uten.imp.migration;

import com.uten.imp.support.MigratedProjectionSchema;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;

@Testcontainers(disabledWithoutDocker = true)
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProcurementDefaultPriceContextMigrationPostgresTest {
    @Container static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");

    @Test void existingPricesSurviveWithoutInventedCommercialContext() throws Exception {
        JdbcTemplate db = new JdbcTemplate(new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
        MigratedProjectionSchema.createTables(db,"619","suppliers","colors","units","currencies","goods");
        UUID goods = UUID.randomUUID();
        db.update("INSERT INTO goods(id,default_purchase_price,default_subcontract_price) VALUES (?,78.125,11.25)", goods);
        db.execute(Files.readString(Path.of("src/main/resources/db/migration/V620__procurement_default_price_context.sql")));
        assertThat(db.queryForObject("SELECT default_purchase_price FROM goods WHERE id=?", BigDecimal.class, goods)).isEqualByComparingTo("78.125");
        assertThat(db.queryForObject("SELECT default_subcontract_price FROM goods WHERE id=?", BigDecimal.class, goods)).isEqualByComparingTo("11.25");
        assertThat(db.queryForObject("SELECT default_purchase_price_unit_id FROM goods WHERE id=?", UUID.class, goods)).isNull();
        assertThat(db.queryForObject("SELECT default_subcontract_price_currency_id FROM goods WHERE id=?", UUID.class, goods)).isNull();
    }
}
