package com.uten.imp.features.admin.platformsetting;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsUpgradeReadProbe;
import com.uten.imp.features.preference.UserPreference;
import com.uten.imp.features.preference.UserPreferenceId;
import com.uten.imp.features.preference.UserPreferenceRepository;
import com.uten.imp.features.preference.UserPreferenceService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.exception.FlywayValidateException;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;
import java.awt.image.BufferedImage;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Upgrade is code/schema evolution against the same company database, never an initialization/reset. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PlatformSettingsUpgradePostgresTest {
    private static final String BRAND_COLUMNS = "id,version,company_name,company_aliases,platform_name,tagline,"
            + "primary_color,secondary_color,login_notice,support_phone,support_email,website,logo_png,logo_sha256,updated_at,updated_by";
    // Fixed prior-version valid choices, deliberately independent of later package defaults/bounds.
    private static final Map<String, String> SAVED_RUNTIME = Map.ofEntries(
            Map.entry("login_rate_limit_per_minute", "9"), Map.entry("login_ip_rate_limit_per_minute", "420"),
            Map.entry("lockout_threshold", "8"), Map.entry("lockout_minutes", "21"),
            Map.entry("password_history_size", "8"), Map.entry("temp_password_ttl_hours", "60"),
            Map.entry("export_rate_limit_per_minute", "13"), Map.entry("session_idle_timeout_minutes", "95"),
            Map.entry("impersonation_window_minutes", "40"), Map.entry("jwt_access_ttl_minutes", "27"),
            Map.entry("jwt_refresh_ttl_days", "13"), Map.entry("sms_code_ttl_minutes", "9"),
            Map.entry("sms_send_interval_seconds", "75"), Map.entry("sms_daily_limit", "13"),
            Map.entry("export_max_rows", "54321"), Map.entry("celebration.auto_enabled", "true"),
            Map.entry("celebration.auto_types", "anniversary"), Map.entry("celebration.publisher_name", "原公司行政部"),
            Map.entry("delivery_due_warning_days", "8"), Map.entry("reservation_hold_grace_days", "17"),
            Map.entry("subcontract_return_due_days", "8"), Map.entry("badge_poll_seconds", "55"),
            Map.entry("audit_hot_retention_months", "9"), Map.entry("audit_archive_retention_months", "42"),
            Map.entry("updater_check_interval_days", "11"));
    @TempDir Path temporaryMigrations;
    private MigratedSchemaBaseline.ScopedDatabase database;
    private JdbcTemplate jdbc;
    private PlatformBrandingDto savedBrand;
    private byte[] savedLogo;
    private UUID actorId;
    private SecurityContextCurrentUser actor;
    private Snapshot saved;

    @BeforeEach void persistPreviousCompanyChoices() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("platform_upgrade_preservation");
        var source = new DriverManagerDataSource(database.getJdbcUrl(), database.getUsername(), database.getPassword());
        jdbc = new JdbcTemplate(source);
        actorId = UUID.randomUUID();
        UUID departmentId = UUID.randomUUID(), employeeId = UUID.randomUUID();
        jdbc.update("INSERT INTO departments(id,code,name,level) VALUES (?,'UPGRADE-PREFS','升级夹具部门','一级部门')", departmentId);
        jdbc.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES (?,'UPGRADE-PREFS-EMP','升级夹具管理员','其他',?,DATE '2026-01-01','active','regular')", employeeId, departmentId);
        jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,is_super_admin,must_change_password) VALUES (?,?,'upgrade-fixture-admin','unused','active',true,false)", actorId, employeeId);
        actor = mock(SecurityContextCurrentUser.class);
        when(actor.get()).thenReturn(Optional.of(new AuthUser(actorId, employeeId, "upgrade-fixture-admin",
                Set.of("authorization:manage"), false, true, true)));
        String original = PlatformLogoImageTest.encoded(new BufferedImage(7, 5, BufferedImage.TYPE_INT_ARGB), "PNG");
        var service = freshBrandService(mock(AuditService.class), mock(TxSessionVars.class));
        savedBrand = new TransactionTemplate(new DataSourceTransactionManager(source)).execute(status -> service.update(
                new PlatformBrandingDto.Update(0, "保留设置电器公司", "Saved Electric\n原公司简称", "原公司平台", "已保存标语",
                        "#123456", "#654321", "升级前已保存的登录提示", "010-123456", "support@example.test", "https://example.test/company", original, false)));
        savedLogo = new PlatformBrandingRepository(jdbc).logo(savedBrand.version()).orElseThrow();
        for (var entry : SAVED_RUNTIME.entrySet())
            assertEquals(1, jdbc.update("UPDATE system_settings SET value=?,updated_by=? WHERE key=?", entry.getValue(), actorId, entry.getKey()));
        jdbc.update("INSERT INTO user_preferences(user_id,pref_key,pref_value,updated_at) VALUES (?,'themeMode','\"dark\"'::jsonb,'2026-10-01T03:04:05Z'),(?,'table.layout','{\"hidden\":[\"amount\"],\"order\":[\"code\",\"name\"]}'::jsonb,'2026-10-02T03:04:05Z')", actorId, actorId);
        jdbc.update("INSERT INTO notice_popup_preferences(user_id,source_event,disabled_at) VALUES (?,'PROCUREMENT_FINANCE_SUBMITTED','2026-10-03T03:04:05Z')", actorId);
        saved = snapshot();
    }

    @AfterEach void close() throws Exception { if (database != null) database.close(); }

    @Test void applicationRestartAndRepeatedFlywayKeepEverySavedValueAndOriginalLogoByte() throws Exception {
        assertFreshReadsUseSavedCompany();
        assertEquals(saved, snapshot());
        for (int restart = 0; restart < 2; restart++) {
            assertEquals(0, migration("classpath:db/migration").migrate().migrationsExecuted);
            assertFreshReadsUseSavedCompany();
            assertEquals(saved, snapshot(), "restart/migrate must not reset values, timestamps, actors or logo bytes");
        }
        assertEquals(1L, jdbc.queryForObject("SELECT count(*) FROM flyway_schema_history WHERE version='839' AND success", Long.class));
    }

    @Test void appendOnlyFutureSchemaUpgradeKeepsOldChoicesAndRemainsReadableByExistingApi() throws Exception {
        int nextVersion = Integer.parseInt(migration("classpath:db/migration").info().current().getVersion().getVersion()) + 1;
        Files.writeString(temporaryMigrations.resolve("V" + nextVersion + "__upgrade_preservation_probe.sql"), """
                ALTER TABLE platform_branding ADD COLUMN future_upgrade_probe text NOT NULL DEFAULT 'new package default';
                ALTER TABLE system_settings ADD COLUMN future_upgrade_probe text NOT NULL DEFAULT 'new package default';
                ALTER TABLE user_preferences ADD COLUMN future_upgrade_probe text NOT NULL DEFAULT 'new package default';
                ALTER TABLE notice_popup_preferences ADD COLUMN future_upgrade_probe text NOT NULL DEFAULT 'new package default';
                """, StandardCharsets.UTF_8);
        String future = "filesystem:" + temporaryMigrations.toAbsolutePath();
        assertEquals(1, migration("classpath:db/migration", future).migrate().migrationsExecuted);
        assertEquals(saved, snapshot(), "new-column defaults must not rewrite existing choices");
        assertFreshReadsUseSavedCompany();
        assertEquals(0, migration("classpath:db/migration", future).migrate().migrationsExecuted);
        assertEquals(saved, snapshot());
    }

    @Test void modifiedHistoricalSeedDefaultsFailValidationWithoutResettingTheCompany() throws Exception {
        Path resolved = Path.of(getClass().getClassLoader().getResource("db/migration").toURI());
        try (var migrations = Files.list(resolved)) {
            for (Path source : migrations.filter(path -> path.getFileName().toString().endsWith(".sql")).toList())
                Files.copy(source, temporaryMigrations.resolve(source.getFileName()));
        }
        Path seed = temporaryMigrations.resolve("V839__company_platform_branding.sql");
        Files.writeString(seed, Files.readString(seed).replace("中山市优腾电器有限公司", "另一新包默认公司"), StandardCharsets.UTF_8);
        assertThrows(FlywayValidateException.class, () -> migration("filesystem:" + temporaryMigrations.toAbsolutePath()).migrate());
        assertEquals(saved, snapshot());
        assertFreshReadsUseSavedCompany();
    }

    private void assertFreshReadsUseSavedCompany() throws Exception {
        var audit = mock(AuditService.class); var tx = mock(TxSessionVars.class);
        var brand = freshBrandService(audit, tx);
        // These are the exact implementations called by GET /platform/branding and GET /admin/platform-settings.
        assertEquals(savedBrand, new PublicPlatformBrandingController(brand).current().getBody());
        assertEquals(savedBrand, new PlatformSettingsController(brand).current().getBody());
        assertArrayEquals(savedLogo, new PublicPlatformBrandingController(brand).logo(savedBrand.version()).getBody());
        assertEquals(savedBrand.companyName(), brand.currentIdentity().companyName());
        assertEquals(List.of("Saved Electric", "原公司简称"), brand.currentIdentity().companyAliases());
        var runtime = SystemSettingsUpgradeReadProbe.freshReader(jdbc, audit, tx);
        for (var entry : SAVED_RUNTIME.entrySet()) {
            SystemSettingKey key = SystemSettingKey.of(entry.getKey()).orElseThrow();
            switch (key.type()) {
                case INT -> assertEquals(Integer.parseInt(entry.getValue()), runtime.readInt(key));
                case LONG -> assertEquals(Long.parseLong(entry.getValue()), runtime.readLong(key));
                case BOOL -> assertEquals(Boolean.parseBoolean(entry.getValue()), runtime.readBool(key));
                case STRING -> assertEquals(entry.getValue(), runtime.readString(key));
            }
        }
        var listed = runtime.list();
        for (var entry : SAVED_RUNTIME.entrySet())
            assertEquals(entry.getValue(), listed.stream().filter(value -> value.key().equals(entry.getKey())).findFirst().orElseThrow().value());
        var preferences = freshPreferenceReader(tx).currentUserPreferences();
        assertEquals("dark", preferences.get("themeMode").asText());
        assertEquals("amount", preferences.get("table.layout").path("hidden").get(0).asText());
        verifyNoInteractions(audit, tx);
    }

    private PlatformSettingsService freshBrandService(AuditService audit, TxSessionVars tx) {
        return new PlatformSettingsService(new PlatformBrandingRepository(jdbc), actor, tx, audit, new StorageProperties());
    }
    private UserPreferenceService freshPreferenceReader(TxSessionVars tx) {
        UserPreferenceRepository repository = mock(UserPreferenceRepository.class, invocation -> {
            if (!"findByIdUserId".equals(invocation.getMethod().getName())) throw new AssertionError("Restart must read preferences only");
            return jdbc.query("SELECT user_id,pref_key,pref_value::text,updated_at FROM user_preferences WHERE user_id=?", (rs, index) -> {
                var value = new UserPreference(); value.setId(new UserPreferenceId(rs.getObject("user_id", UUID.class), rs.getString("pref_key")));
                value.setPrefValue(rs.getString("pref_value")); value.setUpdatedAt(rs.getObject("updated_at", OffsetDateTime.class).toInstant()); return value;
            }, invocation.getArgument(0, UUID.class));
        });
        return new UserPreferenceService(repository, actor, new ObjectMapper(), tx);
    }
    private Flyway migration(String... locations) {
        return Flyway.configure().dataSource(database.getJdbcUrl(), database.getUsername(), database.getPassword())
                .locations(locations).load();
    }
    private Snapshot snapshot() {
        return new Snapshot(jdbc.queryForObject("SELECT to_jsonb(original)::text FROM (SELECT " + BRAND_COLUMNS + " FROM platform_branding) original", String.class),
                jdbc.queryForList("SELECT to_jsonb(original)::text FROM (SELECT key,value,updated_at,updated_by FROM system_settings ORDER BY key) original", String.class),
                jdbc.queryForList("SELECT to_jsonb(original)::text FROM (SELECT user_id,pref_key,pref_value,updated_at FROM user_preferences ORDER BY user_id,pref_key) original", String.class),
                jdbc.queryForList("SELECT to_jsonb(original)::text FROM (SELECT user_id,source_event,disabled_at FROM notice_popup_preferences ORDER BY user_id,source_event) original", String.class));
    }
    private record Snapshot(String brandIncludingOriginalBytes, List<String> runtimeRows, List<String> preferenceRows,
                            List<String> noticePopupRows) {}
}
