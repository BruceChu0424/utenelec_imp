package com.uten.imp.ops;

import com.uten.imp.application.port.BusinessTestResetFilesPort;
import com.uten.imp.features.attachment.ResetEndToEndFixture;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.io.IOException;
import java.net.URISyntaxException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicLong;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.*;

/**
 * Real forward migration of the single object rule (ADR-155) with a retained owner, one-way migrator
 * membership, production-like default EXECUTE grants to the runtime login and a restricted runtime login.
 * The application's own check and delete path (BusinessTestResetFiles, whose refusal, object list and
 * fingerprint reads are SECURITY INVOKER) runs as that restricted login with the hardening script's grants.
 */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class TestResetCurrentOwnerPostgresTest {
    private static final String[] RUNTIME_FUNCTIONS = {
            "public.fn_business_test_reset_objects()", "public.fn_business_test_reset_object_fingerprint()",
            "public.fn_business_reset_table_policy()", "public.fn_business_data_reset_refusals()",
            "public.fn_business_test_reset_require_caller()", "public.fn_business_test_reset_lock_sources()"};

    @TempDir Path storage;

    @Test void currentResetWorksThroughTheOriginalOwnerWithoutGrantingRuntimeTheVerificationHelpers() throws Exception {
        int[] versions = singleObjectRuleVersions();
        String previous = Integer.toString(versions[0]), current = Integer.toString(versions[1]);
        String password=UUID.randomUUID().toString();
        try(var pg=new PostgreSQLContainer<>("postgres:16-alpine").withDatabaseName("reset_current_owner").withUsername("fixture_admin")) {
            pg.start();
            var admin=new JdbcTemplate(new DriverManagerDataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()));
            admin.execute("CREATE ROLE uten_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE");
            admin.execute("CREATE ROLE uten_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT PASSWORD '"+password+"'");
            admin.execute("CREATE ROLE uten LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD '"+password+"'");
            admin.execute("GRANT uten_owner TO uten_migrator");
            admin.execute("ALTER DATABASE reset_current_owner OWNER TO uten_migrator; ALTER SCHEMA public OWNER TO uten_migrator");
            admin.execute("REVOKE ALL ON DATABASE reset_current_owner FROM PUBLIC; REVOKE ALL ON SCHEMA public FROM PUBLIC; GRANT CONNECT ON DATABASE reset_current_owner TO uten; GRANT USAGE ON SCHEMA public TO uten");
            // Production hardening grants EXECUTE on new functions to the runtime login by default.
            admin.execute("ALTER DEFAULT PRIVILEGES FOR ROLE uten_migrator, uten_owner IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO uten");
            Flyway.configure().dataSource(pg.getJdbcUrl(),"uten_migrator",password).locations("classpath:db/migration").target(previous).load().migrate();
            admin.execute("REASSIGN OWNED BY uten_migrator TO uten_owner");
            assertThat(Flyway.configure().dataSource(pg.getJdbcUrl(),"uten_migrator",password).locations("classpath:db/migration").target(current).load().migrate().migrationsExecuted).isEqualTo(1);
            assertThat(admin.queryForObject("SELECT pg_has_role('uten_migrator','uten_owner','MEMBER')",Boolean.class)).isTrue();
            assertThat(admin.queryForObject("SELECT pg_has_role('uten_owner','uten_migrator','MEMBER')",Boolean.class)).isFalse();
            assertThat(admin.queryForObject("SELECT proowner::regrole::text FROM pg_proc WHERE oid='public.business_data_reset()'::regprocedure",String.class)).isEqualTo("uten_owner");
            assertThat(admin.queryForObject("SELECT proowner::regrole::text FROM pg_proc WHERE oid='public.fn_business_test_reset_lock_sources()'::regprocedure",String.class)).isEqualTo("uten_migrator");
            for (String function : RUNTIME_FUNCTIONS) {
                assertThat(admin.queryForObject("SELECT has_function_privilege('uten',?,'EXECUTE')",Boolean.class,function)).as(function).isTrue();
            }
            for (String function : List.of("public.fn_business_test_reset_verify_purged()","public.fn_clear_business_test_object_metadata()")) {
                assertThat(admin.queryForObject("SELECT has_function_privilege('uten',?,'EXECUTE')",Boolean.class,function))
                        .as(function+" stays private although default privileges grant EXECUTE").isFalse();
            }
            assertThat(admin.queryForObject("SELECT to_regclass('public.business_test_object_cleanup_intents') IS NULL",Boolean.class)).isTrue();
            assertThat(admin.queryForObject("SELECT to_regclass('public.v_business_test_object_sources') IS NULL",Boolean.class)).isTrue();

            UUID employee=UUID.randomUUID(),actor=UUID.randomUUID(),document=UUID.randomUUID();
            admin.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,?,'测试维护管理员','其他',id,CURRENT_DATE,'active','regular' FROM departments WHERE code='DEPT_FIN'",employee,"RST-ACL-"+employee);
            admin.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status,is_super_admin) VALUES(?,?,?,'test-only',false,'active',true)",actor,employee,"reset-acl-admin");
            admin.update("INSERT INTO sales_quotes(id,bill_no,bill_date,status) VALUES(?,'XB'||to_char(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai','YYYYMMDD')||'991901',(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai')::date,0)",document);
            // A listed test object whose file is already gone: the check and the locked purge read it as uten.
            String ticket=selfContainedTicket(admin);
            // harden-existing-postgres-roles.sh: the runtime login reads and writes every table, nothing else.
            admin.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO uten");
            admin.execute("GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO uten");
            var runtimeSource=new DriverManagerDataSource(pg.getJdbcUrl(),"uten",password);
            var runtime=new JdbcTemplate(runtimeSource);
            assertThat(runtime.queryForObject("SELECT pg_has_role(current_user,'uten_owner','MEMBER')",Boolean.class)).isFalse();
            assertThat(runtime.queryForObject("SELECT pg_has_role(current_user,'uten_migrator','MEMBER')",Boolean.class)).isFalse();
            assertThat(runtime.queryForObject("SELECT has_schema_privilege(current_user,'public','CREATE')",Boolean.class)).isFalse();
            assertThatThrownBy(()->runtime.queryForMap("SELECT * FROM business_data_reset()"))
                    .satisfies(error->assertThat(org.springframework.core.NestedExceptionUtils.getMostSpecificCause(error))
                            .isInstanceOf(java.sql.SQLException.class).hasMessageContaining("authenticated active super-admin"));
            assertThatThrownBy(()->runtime.queryForObject("SELECT fn_clear_business_test_object_metadata()::text",String.class))
                    .satisfies(error->assertThat(org.springframework.core.NestedExceptionUtils.getMostSpecificCause(error))
                            .hasMessageContaining("permission denied"));
            long before=admin.queryForObject("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1",Long.class);
            resetAsRuntime(runtimeSource,actor,"reset-acl-admin");
            assertThat(admin.queryForObject("SELECT count(*) FROM attachment_object_outbox WHERE storage_key=?",Integer.class,ticket)).isZero();
            assertThat(admin.queryForObject("SELECT count(*) FROM sales_quotes WHERE id=?",Integer.class,document)).isZero();
            assertThat(admin.queryForObject("SELECT count(*) FROM users WHERE id=?",Integer.class,actor)).isEqualTo(1);
            assertThat(admin.queryForObject("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1",Long.class)).isEqualTo(before+1);
            assertThat(runtime.queryForObject("SELECT fn_business_test_reset_active()",Boolean.class)).isFalse();

            // A login that is neither the runtime role nor a member of the reset owner cannot pass the caller check.
            admin.execute("CREATE ROLE reset_probe_login LOGIN NOSUPERUSER NOINHERIT PASSWORD '"+password+"'");
            admin.execute("GRANT CONNECT ON DATABASE reset_current_owner TO reset_probe_login; GRANT USAGE ON SCHEMA public TO reset_probe_login; GRANT SELECT ON public.users TO reset_probe_login");
            admin.execute("GRANT EXECUTE ON FUNCTION public.fn_business_test_reset_require_caller() TO reset_probe_login");
            var probe=new JdbcTemplate(new DriverManagerDataSource(pg.getJdbcUrl(),"reset_probe_login",password));
            assertThatThrownBy(()->probe.queryForObject("SELECT fn_business_test_reset_require_caller()::text",String.class))
                    .satisfies(error->{
                        var cause=org.springframework.core.NestedExceptionUtils.getMostSpecificCause(error);
                        assertThat(cause).isInstanceOf(java.sql.SQLException.class).hasMessageContaining("runtime maintenance caller is not authorized");
                        assertThat(((java.sql.SQLException)cause).getSQLState()).isEqualTo("42501");
                    });
        }
    }

    /** An unprotected self-contained staging delete task whose staging file does not exist. */
    private static String selfContainedTicket(JdbcTemplate admin) {
        String key="i1_SALES_QUOTE_202610_"+UUID.randomUUID().toString().replace("-","")+".pdf";
        admin.update("INSERT INTO attachment_object_outbox(operation,storage_provider,storage_key,storage_version,dedupe_key,status) VALUES('DELETE_STAGING','internal',?,NULL,?,'PENDING')",
                key,"internal|DELETE_STAGING|"+key+"|<local>");
        return key;
    }

    /**
     * The application path as the runtime login: BusinessTestResetFiles.check() (caller check, refusals,
     * object list, storage check), then in one transaction purge() (lock, the same reads, fingerprint),
     * the declared fingerprint and business_data_reset().
     */
    private void resetAsRuntime(DriverManagerDataSource runtimeSource, UUID actor, String account) throws Exception {
        var runtime=new JdbcTemplate(runtimeSource);
        var transactions=new DataSourceTransactionManager(runtimeSource);
        BusinessTestResetFilesPort files=ResetEndToEndFixture.files(runtimeSource,transactions,storage.resolve("internal-"+UUID.randomUUID()));
        var check=files.check(new BusinessTestResetFilesPort.Actor(actor,account),Duration.ofSeconds(30));
        assertThat(check.refusals()).as("the INVOKER reads succeed as uten and find nothing to refuse").isEmpty();
        assertThat(check.locations()).isEqualTo(1);
        assertThat(check.absentFiles()).isEqualTo(1);
        new TransactionTemplate(transactions).executeWithoutResult(status->{
            runtime.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,actor.toString());
            runtime.queryForObject("SELECT set_config('app.actor_account',?,true)",String.class,account);
            runtime.queryForObject("SELECT set_config('app.audit_request_id',?,true)",String.class,UUID.randomUUID().toString());
            var purge=files.purge(Instant.now().plusSeconds(60),new AtomicLong());
            assertThat(purge.fingerprint()).startsWith("1:");
            assertThat(purge.deletedFiles()).isZero();
            runtime.queryForObject("SELECT set_config('app.business_test_reset_objects',?,true)",String.class,purge.fingerprint());
            assertThat(((Number)runtime.queryForMap("SELECT * FROM business_data_reset()").get("cleared_table_count")).intValue()).isPositive();
        });
    }

    /** {previous, current}: the migration that creates the single object rule and the one before it (numbers follow renumbering). */
    static int[] singleObjectRuleVersions() throws IOException, URISyntaxException {
        Path directory = Path.of(TestResetCurrentOwnerPostgresTest.class.getResource("/db/migration").toURI());
        Pattern file = Pattern.compile("V(\\d+)__.*\\.sql");
        int current = -1, previous = -1;
        List<Path> migrations;
        try (var files = Files.list(directory)) { migrations = files.toList(); }
        for (Path migration : migrations) {
            Matcher matcher = file.matcher(migration.getFileName().toString());
            if (matcher.matches() && Files.readString(migration, StandardCharsets.UTF_8)
                    .contains("CREATE FUNCTION public.fn_business_test_reset_objects()")) {
                assertThat(current).as("one migration creates the single object rule").isEqualTo(-1);
                current = Integer.parseInt(matcher.group(1));
            }
        }
        assertThat(current).isPositive();
        for (Path migration : migrations) {
            Matcher matcher = file.matcher(migration.getFileName().toString());
            if (matcher.matches()) {
                int version = Integer.parseInt(matcher.group(1));
                if (version < current) previous = Math.max(previous, version);
            }
        }
        assertThat(previous).isPositive();
        return new int[]{previous, current};
    }
}
