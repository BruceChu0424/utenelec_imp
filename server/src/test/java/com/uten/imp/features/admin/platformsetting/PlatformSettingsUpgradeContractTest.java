package com.uten.imp.features.admin.platformsetting;

import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsUpgradeReadProbe;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.annotation.Transactional;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Pattern;
import static org.junit.jupiter.api.Assertions.*;

/** Default upgrades cannot silently replace company/user choices; intentional conversions need explicit review. */
class PlatformSettingsUpgradeContractTest {
    private static final Path SOURCE = Path.of("src/main/java");
    private static final Path PLATFORM = SOURCE.resolve("com/uten/imp/features/admin/platformsetting");
    private static final Path MIGRATIONS = Path.of("src/main/resources/db/migration");
    private static final Pattern BRAND_DML = Pattern.compile("(?is)\\b(?:INSERT\\s+INTO|UPDATE|DELETE\\s+FROM|TRUNCATE(?:\\s+TABLE)?|MERGE\\s+INTO)\\s+(?:public\\s*\\.\\s*)?platform_branding\\b");
    private static final Pattern RETIRED_CHOICES = Pattern.compile("(?is)\\b(?:UPDATE|DELETE\\s+FROM|TRUNCATE(?:\\s+TABLE)?|DROP\\s+TABLE(?:\\s+IF\\s+EXISTS)?)\\s+(?:public\\s*\\.\\s*)?(?:platform_branding|system_settings|user_preferences|notice_popup_preferences)\\b");

    @Test void futureRegistryDefaultsOrBoundsCannotInvalidatePreviouslyValidSavedChoices() {
        // Compatibility oracle for the V839 era, not another runtime setting registry.
        for (String prior : List.of("login_rate_limit_per_minute:1:100000", "login_ip_rate_limit_per_minute:1:1000000",
                "lockout_threshold:1:1000", "lockout_minutes:1:525600", "password_history_size:0:100", "temp_password_ttl_hours:1:168",
                "export_rate_limit_per_minute:1:10000", "session_idle_timeout_minutes:1:525600", "impersonation_window_minutes:1:120",
                "jwt_access_ttl_minutes:5:1440", "jwt_refresh_ttl_days:1:30", "sms_code_ttl_minutes:1:1440",
                "sms_send_interval_seconds:1:86400", "sms_daily_limit:1:10000", "export_max_rows:1:100000",
                "delivery_due_warning_days:1:30", "reservation_hold_grace_days:1:90", "subcontract_return_due_days:1:30",
                "badge_poll_seconds:15:600", "audit_hot_retention_months:1:120", "audit_archive_retention_months:0:240",
                "updater_check_interval_days:0:365")) {
            String[] values = prior.split(":");
            SystemSettingKey current = SystemSettingKey.of(values[0]).orElseThrow(() -> new AssertionError("Retiring a saved setting requires explicit compatibility review: " + prior));
            assertTrue(current.numeric());
            assertEquals(values[0].startsWith("jwt_") ? SystemSettingKey.Type.LONG : SystemSettingKey.Type.INT, current.type(),
                    "Existing consumer/setting types need a reviewed compatibility conversion");
            assertTrue(current.min() <= Long.parseLong(values[1]) && current.max() >= Long.parseLong(values[2]),
                    "Previously valid values must remain effective; review intentional restrictions before changing " + current.key());
            assertTrue(SystemSettingsUpgradeReadProbe.isValidStoredChoice(current, values[1]));
            assertTrue(SystemSettingsUpgradeReadProbe.isValidStoredChoice(current, values[2]));
        }
        assertEquals(SystemSettingKey.Type.BOOL, SystemSettingKey.CELEBRATION_AUTO_ENABLED.type());
        assertEquals(SystemSettingKey.Type.STRING, SystemSettingKey.CELEBRATION_AUTO_TYPES.type());
        assertEquals(SystemSettingKey.Type.STRING, SystemSettingKey.CELEBRATION_PUBLISHER_NAME.type());
        assertTrue(SystemSettingsUpgradeReadProbe.isValidStoredChoice(SystemSettingKey.CELEBRATION_AUTO_TYPES, "birthday,anniversary"));
        assertTrue(SystemSettingsUpgradeReadProbe.isValidStoredChoice(SystemSettingKey.CELEBRATION_PUBLISHER_NAME, "x".repeat(100)));
    }

    @Test void onlyVersionCheckedAdministratorCommandWritesCompanyBranding() throws Exception {
        var mutationFiles = new ArrayList<String>(); var saveCallFiles = new ArrayList<String>();
        try (var files = Files.walk(SOURCE)) {
            for (Path file : files.filter(path -> path.toString().endsWith(".java")).toList()) {
                String source = code(Files.readString(file));
                if (BRAND_DML.matcher(source).find()) mutationFiles.add(file.getFileName().toString());
                var owners = Pattern.compile("\\bPlatformBrandingRepository\\s+([A-Za-z_$][\\w$]*)").matcher(source);
                while (owners.find()) if (Pattern.compile("\\b" + Pattern.quote(owners.group(1)) + "\\.save\\s*\\(").matcher(source).find())
                    saveCallFiles.add(file.getFileName().toString());
            }
        }
        assertEquals(List.of("PlatformBrandingRepository.java"), mutationFiles);
        assertEquals(List.of("PlatformSettingsService.java"), saveCallFiles);
        String repository = code(Files.readString(PLATFORM.resolve("PlatformBrandingRepository.java")));
        assertTrue(repository.contains("WHERE id=1 AND version=?"));
        String service = code(Files.readString(PLATFORM.resolve("PlatformSettingsService.java")));
        assertEquals(1L, Pattern.compile("\\brepository\\.save\\s*\\(").matcher(service).results().count());
        assertTrue(service.indexOf("before.version() != normalized.expectedVersion()") < service.indexOf("repository.save("));
        assertTrue(service.indexOf("tx.bindActor(") < service.indexOf("repository.save("));
    }

    @Test void persistedSettingsAndBrandingHaveNoStartupDefaultWriter() throws Exception {
        Pattern lifecycle = Pattern.compile("@PostConstruct|@EventListener|\\b(?:ApplicationRunner|CommandLineRunner|InitializingBean|SmartInitializingSingleton|ApplicationReadyEvent|ContextRefreshedEvent|afterPropertiesSet)\\b");
        try (var files = Files.list(PLATFORM)) {
            for (Path file : files.filter(path -> path.toString().endsWith(".java")).toList())
                assertFalse(lifecycle.matcher(code(Files.readString(file))).find(), file + " must not initialize stored company choices at startup");
        }
        for (String path : List.of("com/uten/imp/features/admin/systemsetting/SystemSettingsService.java", "com/uten/imp/features/preference/UserPreferenceService.java"))
            assertFalse(lifecycle.matcher(code(Files.readString(SOURCE.resolve(path)))).find(), path + " must not reapply package defaults at startup");
        for (String method : List.of("current", "currentIdentity", "logo")) {
            var reader = java.util.Arrays.stream(PlatformSettingsService.class.getDeclaredMethods()).filter(value -> value.getName().equals(method)).findFirst().orElseThrow();
            assertTrue(reader.getAnnotation(Transactional.class).readOnly());
        }
    }

    @Test void oneFlywaySeedAndFutureDefaultUpgradesCannotResetExistingChoices() throws Exception {
        String seed = code(Files.readString(MIGRATIONS.resolve("V839__company_platform_branding.sql")));
        assertEquals(1L, Pattern.compile("(?is)INSERT\\s+INTO\\s+platform_branding\\b").matcher(seed).results().count());
        assertFalse(RETIRED_CHOICES.matcher(seed).find());
        try (var files = Files.list(MIGRATIONS)) {
            for (Path file : files.filter(path -> path.getFileName().toString().matches("V\\d+__.*\\.sql")).toList()) {
                int version = Integer.parseInt(file.getFileName().toString().replaceFirst("^V(\\d+)__.*", "$1"));
                if (version <= 839) continue;
                String source = code(Files.readString(file));
                assertFalse(BRAND_DML.matcher(source).find(), file + " cannot seed/reset an existing company's branding; review any intentional data conversion separately");
                assertFalse(RETIRED_CHOICES.matcher(source).find(), file + " cannot reset stored company/user choices during a default upgrade");
                assertFalse(Pattern.compile("(?is)INSERT\\s+INTO\\s+(?:public\\.)?(?:system_settings|user_preferences|notice_popup_preferences)\\b[^;]*ON\\s+CONFLICT[^;]*DO\\s+UPDATE").matcher(source).find(),
                        file + " new-key seed must not overwrite an existing selected value");
                assertFalse(Pattern.compile("(?is)ALTER\\s+TABLE\\s+(?:public\\.)?(?:platform_branding|system_settings|user_preferences|notice_popup_preferences)\\b[^;]*\\bDROP\\s+(?:COLUMN\\s+)?").matcher(source).find(),
                        file + " existing configuration columns require a reviewed compatibility migration");
            }
        }
    }

    private static String code(String source) {
        return source.replaceAll("(?s)/\\*.*?\\*/", "").replaceAll("(?m)^\\s*//.*$", "").replaceAll("(?m)^\\s*--.*$", "");
    }
}
