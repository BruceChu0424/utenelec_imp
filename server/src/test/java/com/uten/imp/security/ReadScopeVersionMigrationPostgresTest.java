package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.export.ExportProjectionAccessGuard;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.reporting.export.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.nio.file.*;
import java.time.OffsetDateTime;
import java.util.*;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Actual export V938 data upgraded forward through V939; no repair or fabricated submission proof. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ReadScopeVersionMigrationPostgresTest {
    private static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("scope_upgrade_fixture").withReuse(false)
            .withCreateContainerCmdModifier(cmd -> cmd.getHostConfig().withMemory(768L * 1024 * 1024).withNanoCPUs(1_000_000_000L));
    @org.junit.jupiter.api.io.TempDir Path directory;
    @AfterAll static void close() { POSTGRES.stop(); }

    @Test void preexistingTaskIdentitySurvivesWithoutInventingASubmissionStampAndOldFilesRequireExplicitRecreation() throws Exception {
        POSTGRES.start();
        var first = com.uten.imp.testsupport.TestFlyway.configure().dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration").target("938").load();
        first.migrate();
        var source = new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        var db = new JdbcTemplate(source);
        UUID owner = UUID.randomUUID(), id = UUID.randomUUID(), employee = UUID.randomUUID();
        db.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                SELECT ?,?,'Scope migration reader',id_type,department_id,CURRENT_DATE,'active','regular'
                FROM employees WHERE code='ADMIN'
                """, employee, "RS-UP-" + employee);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password) VALUES(?,?,?,'test-only-fixture',false)",
                owner, employee, "scope-upgrade-" + owner);
        long auth = db.queryForObject("SELECT auth_version FROM users WHERE id=?", Long.class, owner);
        long epoch = db.queryForObject("SELECT epoch FROM authorization_state WHERE singleton_id=1", Long.class);
        var mapper = new ObjectMapper(); var request = new ReportExportRequest(id, "sales", "ORDER/detail", Map.of(), null, null, null);
        db.update("INSERT INTO report_export_jobs(id,submitted_by,submitted_auth_version,submitted_auth_epoch,request,read_contract,build_identity,status,attempt,artifact_bytes,artifact_sha256,expires_at)"
                + " VALUES(?,?,?,?,CAST(? AS jsonb),?,'fixture-build','SUCCEEDED',1,5,?,clock_timestamp()+interval '1 hour')", id, owner, auth, epoch,
                mapper.writeValueAsString(request), ReportExportBuildIdentity.CONTRACT, "a".repeat(64));
        String original = db.queryForObject("SELECT request::text FROM report_export_jobs WHERE id=?", String.class, id);
        String guard = db.queryForObject("SELECT md5(prosrc) FROM pg_proc WHERE oid='public.fn_guard_report_export_identity()'::regprocedure", String.class);
        com.uten.imp.testsupport.TestFlyway.configure().dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration").load().migrate();
        assertThat(db.queryForObject("SELECT access_stamp FROM report_export_jobs WHERE id=?", String.class, id)).isNull();
        assertThat(db.queryForObject("SELECT request::text FROM report_export_jobs WHERE id=?", String.class, id)).isEqualTo(original);
        assertThat(db.queryForObject("SELECT md5(prosrc) FROM pg_proc WHERE oid='public.fn_guard_report_export_identity()'::regprocedure", String.class)).isEqualTo(guard);
        assertThatThrownBy(() -> db.update("UPDATE report_export_jobs SET access_stamp=? WHERE id=?", "b".repeat(64), id))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);

        var repository = new ReportExportRepository(new NamedParameterJdbcTemplate(source));
        var old = repository.find(id).orElseThrow();
        var user = new AuthUser(owner, employee, "scope-upgrade", Set.of("sales_report:view", "sales_report:export"), false, true, false);
        var users = mock(SecurityContextCurrentUser.class); when(users.get()).thenReturn(Optional.of(user));
        var restorer = mock(SubmitterPrincipalRestorer.class); when(restorer.restore(owner, auth, epoch)).thenReturn(user);
        @SuppressWarnings("unchecked") var projections = (org.springframework.beans.factory.ObjectProvider<ExportProjectionAccessGuard>) mock(org.springframework.beans.factory.ObjectProvider.class);
        var scopes = mock(ReadScopeVersionAuthority.class);
        var build = mock(ReportExportBuildIdentity.class); when(build.revision()).thenReturn(old.buildIdentity());
        var service = new ReportExportService(repository, users, restorer, mapper, build, mock(ExportRateLimiter.class),
                scopes, projections, directory.toString());
        Path cache = service.artifact(old); byte[] originalFile = {80, 75, 3, 4, 9}; Files.write(cache, originalFile);
        assertThatThrownBy(() -> service.authorizedArtifact(id)).isInstanceOfSatisfying(ApiException.class,
                failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.CONFLICT));
        assertThat(Files.readAllBytes(cache)).isEqualTo(originalFile); assertThat(repository.find(id).orElseThrow().request()).isEqualTo(original);
        verifyNoInteractions(scopes);
    }
}
