package com.uten.imp.features.admin.materialforecast;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import java.nio.charset.StandardCharsets;
import static org.assertj.core.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class MaterialForecastSettingsPostgresTest {
    @Test void forwardSeedPreservesExplicitPolicyValues()throws Exception {
        try(var database=MigratedSchemaBaseline.openDatabase("market_portable_policy")) {
            var jdbc=new JdbcTemplate(new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword()));
            assertThat(jdbc.queryForObject("SELECT value FROM system_settings WHERE key='material_forecast.enabled'",String.class)).isEqualTo("true");
            jdbc.update("UPDATE system_settings SET value='false' WHERE key='material_forecast.enabled'");
            jdbc.update("UPDATE system_settings SET value='30' WHERE key='material_forecast.interval_minutes'");
            try(var sql=getClass().getResourceAsStream("/db/migration/V891__material_forecast_portable_settings.sql")) {jdbc.execute(new String(java.util.Objects.requireNonNull(sql).readAllBytes(),StandardCharsets.UTF_8));}
            assertThat(jdbc.queryForObject("SELECT value FROM system_settings WHERE key='material_forecast.enabled'",String.class)).isEqualTo("false");
            assertThat(jdbc.queryForObject("SELECT value FROM system_settings WHERE key='material_forecast.interval_minutes'",String.class)).isEqualTo("30");
            assertThat(jdbc.queryForObject("SELECT count(*) FROM system_settings WHERE key LIKE 'material_forecast.%'",Integer.class)).isEqualTo(4);
        }
    }
}
