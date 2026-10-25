package com.uten.imp.features.admin.platformsetting;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;
import java.awt.image.BufferedImage;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import static org.junit.jupiter.api.Assertions.*;

/** Fully migrated disposable PostgreSQL clone; no company database or server is accessed. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PlatformBrandingPostgresTest {
    MigratedSchemaBaseline.ScopedDatabase database;
    JdbcTemplate jdbc;
    PlatformBrandingRepository repo;
    TransactionTemplate tx;

    @BeforeEach void open() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("platform_branding");
        var source = new DriverManagerDataSource(database.getJdbcUrl(), database.getUsername(), database.getPassword());
        jdbc = new JdbcTemplate(source); repo = new PlatformBrandingRepository(jdbc);
        tx = new TransactionTemplate(new DataSourceTransactionManager(source));
    }
    @AfterEach void close() throws Exception { if (database != null) database.close(); }

    @Test void freshBrandingDefaultsAreExplicit() {
        var value = repo.current();
        assertEquals(0, value.version()); assertEquals("中山市优腾电器有限公司", value.companyName());
        assertEquals("优腾综合管理平台", value.platformName()); assertEquals("德国工匠 · 质造开关", value.tagline());
        assertEquals("", value.companyAliases());
        assertFalse(value.hasLogo()); assertTrue(repo.logo(null).isEmpty());
        assertThrows(DataAccessException.class, () -> jdbc.update("INSERT INTO platform_branding SELECT 2,version,company_name,company_aliases,platform_name,tagline,primary_color,secondary_color,login_notice,support_phone,support_email,website,logo_png,logo_sha256,updated_at,updated_by FROM platform_branding"));
    }

    @Test void settingsLogoDigestAndVersionCommitTogetherAndNoImageBytesEnterAudit() throws Exception {
        byte[] image = image();
        var saved = tx.execute(status -> {
            var old = repo.lock(); assertEquals(0, old.dto().version());
            return repo.save(request(0, "品牌甲"), image, PlatformLogoImage.sha256(image), null);
        });
        assertNotNull(saved); assertEquals(1, saved.version()); assertTrue(saved.hasLogo());
        assertArrayEquals(image, repo.logo(1).orElseThrow()); assertTrue(repo.logo(0).isEmpty());
        assertEquals(1L, jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE target_type='platform_branding'", Long.class));
        assertEquals(0L, jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE target_type='platform_branding' AND ((\"before\" ? 'logo_png') OR (\"after\" ? 'logo_png'))", Long.class));
        assertEquals("system", jdbc.queryForObject("SELECT event_category FROM audit_log WHERE target_type='platform_branding'", String.class));
    }

    @Test void failedSaveRollsBackMetadataLogoAndAudit() throws Exception {
        byte[] image = image();
        assertThrows(IllegalStateException.class, () -> tx.executeWithoutResult(status -> {
            repo.lock(); repo.save(request(0, "不应保存"), image, PlatformLogoImage.sha256(image), null);
            throw new IllegalStateException("rollback fixture");
        }));
        assertEquals(0, repo.current().version()); assertFalse(repo.current().hasLogo());
        assertEquals(0L, jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE target_type='platform_branding'", Long.class));
    }

    @Test void simultaneousAdminsCannotOverwriteTheSameExpectedVersion() throws Exception {
        var locked = new CountDownLatch(1); var secondStarted = new CountDownLatch(1);
        try (var pool = Executors.newFixedThreadPool(2)) {
            var first = pool.submit(() -> tx.execute(status -> {
                repo.lock(); locked.countDown();
                try { assertTrue(secondStarted.await(5, TimeUnit.SECONDS)); }
                catch (InterruptedException error) { throw new IllegalStateException(error); }
                return repo.save(request(0, "首位管理员"), null, null, null);
            }));
            assertTrue(locked.await(5, TimeUnit.SECONDS));
            var second = pool.submit(() -> {
                secondStarted.countDown();
                return assertThrows(ApiException.class, () -> tx.execute(status -> {
                    repo.lock(); return repo.save(request(0, "第二位管理员"), null, null, null);
                }));
            });
            assertEquals(1, first.get(10, TimeUnit.SECONDS).version());
            assertEquals(ErrorCode.CONFLICT, second.get(10, TimeUnit.SECONDS).getCode());
            assertEquals("首位管理员", repo.current().companyName());
        }
    }

    @Test void otherConnectedCompanyDatabaseCannotSeeSavedLogoOrNames() throws Exception {
        byte[] image = image();
        tx.executeWithoutResult(status -> { repo.lock(); repo.save(request(0, "公司甲"), image, PlatformLogoImage.sha256(image), null); });
        try (var other = MigratedSchemaBaseline.openDatabase("platform_other_company")) {
            var alternate = new PlatformBrandingRepository(new JdbcTemplate(new DriverManagerDataSource(other.getJdbcUrl(), other.getUsername(), other.getPassword())));
            assertEquals("中山市优腾电器有限公司", alternate.current().companyName());
            assertFalse(alternate.current().hasLogo()); assertTrue(alternate.logo(null).isEmpty());
        }
    }

    @Test void databaseConstraintsRejectOversizedOrUnverifiedLogo() {
        assertThrows(DataAccessException.class, () -> jdbc.update("UPDATE platform_branding SET logo_png=?,logo_sha256=? WHERE id=1", new byte[524289], "0".repeat(64)));
        assertThrows(DataAccessException.class, () -> jdbc.update("UPDATE platform_branding SET logo_png=?,logo_sha256=NULL WHERE id=1", new byte[]{1, 2, 3}));
        assertFalse(repo.current().hasLogo());
    }

    private static byte[] image() throws Exception { return PlatformLogoImage.decode(PlatformLogoImageTest.encoded(new BufferedImage(3, 2, BufferedImage.TYPE_INT_ARGB), "PNG")); }
    private static PlatformBrandingDto.Update request(int version, String name) {
        return new PlatformBrandingDto.Update(version, name, "Company Alias", "平台", "", "#0F766E", "#2DD4BF", "", "", "", "", null, false);
    }
}
