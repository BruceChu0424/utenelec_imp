package com.uten.imp.features.admin.platformsetting;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.awt.image.BufferedImage;
import java.nio.charset.StandardCharsets;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Real V838 -> V839 upgrades, including the legacy six/seven-argument overlap. */
@Testcontainers(disabledWithoutDocker = true)
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PlatformBrandingMigrationPostgresTest {
    @Container
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("branding_v838_template").withReuse(false);
    private String databaseName;
    private JdbcTemplate jdbc;

    @BeforeAll
    static void migratePreviousSchema() {
        migration(POSTGRES.getDatabaseName(), "838").migrate();
    }

    @BeforeEach
    void clonePreviousSchema() throws Exception {
        databaseName = "branding_v839_" + UUID.randomUUID().toString().replace("-", "");
        try (var ignored = MigratedSchemaBaseline.cloneConnection(POSTGRES, databaseName)) {
            jdbc = new JdbcTemplate(new DriverManagerDataSource(
                    MigratedSchemaBaseline.jdbcUrlFor(POSTGRES, databaseName),
                    POSTGRES.getUsername(), POSTGRES.getPassword()));
        }
        assertNull(jdbc.queryForObject("SELECT to_regclass('public.platform_branding')::text", String.class));
        assertEquals(1, jdbc.update("UPDATE system_settings SET value='9' WHERE key='login_rate_limit_per_minute'"));
    }

    @AfterEach
    void dropClone() throws Exception {
        if (databaseName != null) {
            var result = POSTGRES.execInContainer("dropdb", "-U", POSTGRES.getUsername(),
                    "--if-exists", "--force", databaseName);
            assertEquals(0, result.getExitCode(), result.getStderr());
        }
    }

    @Test
    void upgradesFreshSevenArgumentHistoryWithScopedAudit() throws Exception {
        assertNull(jdbc.queryForObject("SELECT to_regprocedure('public.fn_audit_track_table(text,text,text,boolean,text[],boolean)')::text", String.class));
        assertUpgradeAndScopedAudit();
    }

    @Test
    void upgradesWhenLegacySixArgumentAndCurrentSevenArgumentFunctionsCoexist() throws Exception {
        // Restore the exact historical V670 function, without changing any applied migration or its checksum.
        String historical = new ClassPathResource("db/migration/V670__audit_three_list_policy_change_only_rows.sql")
                .getContentAsString(StandardCharsets.UTF_8);
        int start = historical.indexOf("CREATE OR REPLACE FUNCTION public.fn_audit_track_table(");
        int end = historical.indexOf("REVOKE ALL ON FUNCTION public.fn_audit_track_table", start);
        assertTrue(start >= 0 && end > start);
        jdbc.execute(historical.substring(start, end));
        assertEquals(2L, jdbc.queryForObject("SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='fn_audit_track_table'", Long.class));
        assertUpgradeAndScopedAudit();
    }

    private void assertUpgradeAndScopedAudit() throws Exception {
        var savedSettings = jdbc.queryForList("SELECT to_jsonb(setting)::text FROM system_settings setting ORDER BY key", String.class);
        assertEquals(1, migration(databaseName, "839").migrate().migrationsExecuted);
        assertEquals(savedSettings, jdbc.queryForList("SELECT to_jsonb(setting)::text FROM system_settings setting ORDER BY key", String.class));
        assertEquals(1L, jdbc.queryForObject("SELECT count(*) FROM flyway_schema_history WHERE version='839' AND success", Long.class));
        assertEquals("PRESERVE", jdbc.queryForObject("SELECT disposition FROM fn_business_reset_table_policy() WHERE table_name='platform_branding'", String.class));
        assertEquals(1L, jdbc.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgrelid='public.platform_branding'::regclass AND NOT tgisinternal AND tgenabled='A' AND tgfoid='public.fn_audit()'::regprocedure", Long.class));
        assertEquals(0L, jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE target_type='platform_branding'", Long.class));

        byte[] logo = PlatformLogoImage.decode(PlatformLogoImageTest.encoded(
                new BufferedImage(3, 2, BufferedImage.TYPE_INT_ARGB), "PNG"));
        assertEquals(1, jdbc.update("UPDATE platform_branding SET company_name='升级后品牌',logo_png=?,logo_sha256=? WHERE id=1",
                logo, PlatformLogoImage.sha256(logo)));
        assertEquals(1L, jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE target_type='platform_branding' AND event_category='system' AND \"after\"->>'company_name'='升级后品牌'", Long.class));
        assertEquals(PlatformLogoImage.sha256(logo), jdbc.queryForObject("SELECT \"after\"->>'logo_sha256' FROM audit_log WHERE target_type='platform_branding'", String.class));
        assertEquals(0L, jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE target_type='platform_branding' AND ((\"before\" ? 'logo_png') OR (\"after\" ? 'logo_png'))", Long.class));
        jdbc.update("UPDATE platform_branding SET company_name=company_name,updated_at=updated_at + interval '1 second' WHERE id=1");
        assertEquals(1L, jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE target_type='platform_branding'", Long.class));

        assertEquals(0, migration(databaseName, "839").migrate().migrationsExecuted);
        assertEquals("升级后品牌", jdbc.queryForObject("SELECT company_name FROM platform_branding WHERE id=1", String.class));
        assertArrayEquals(logo, jdbc.queryForObject("SELECT logo_png FROM platform_branding WHERE id=1", byte[].class));
    }

    private static Flyway migration(String databaseName, String target) {
        return Flyway.configure().dataSource(MigratedSchemaBaseline.jdbcUrlFor(POSTGRES, databaseName),
                        POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration").target(target).load();
    }
}
