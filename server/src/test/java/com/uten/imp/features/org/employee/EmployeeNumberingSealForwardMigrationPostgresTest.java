package com.uten.imp.features.org.employee;

import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;

/** Real non-superuser V976 -> V977 upgrade and unchanged V965 strict adoption. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class EmployeeNumberingSealForwardMigrationPostgresTest {
    static PostgreSQLContainer postgres;
    static String numbering,mergeInstaller,codeInstaller;
    String databaseName,jdbcUrl;
    JdbcTemplate db;

    @BeforeAll static void template() throws Exception {
        postgres=new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("numbering_seal_template");
        postgres.start();
        try(var c=DriverManager.getConnection(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword());var s=c.createStatement()) {
            s.execute("CREATE ROLE uten_migrator NOLOGIN NOSUPERUSER");
            s.execute("CREATE ROLE uten NOLOGIN NOSUPERUSER");
            s.execute("ALTER DATABASE numbering_seal_template OWNER TO uten_migrator");
            s.execute("GRANT USAGE,CREATE ON SCHEMA public TO uten_migrator");
        }
        TestFlyway.configureWithInitSql("SET ROLE uten_migrator")
                .dataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword())
                .locations("classpath:db/migration").target("976").load().migrate();
        numbering=resource("V977__employee_six_digit_numbers.sql");
        mergeInstaller=resource("V964__employee_identity_merge_extension_v1.sql");
        codeInstaller=resource("V965__employee_code_reuse_extension.sql");
    }
    @AfterAll static void stop(){if(postgres!=null)postgres.stop();}
    @BeforeEach void cloneTemplate() throws Exception {
        databaseName="numbering_seal_"+UUID.randomUUID().toString().replace("-","");
        try(var c=DriverManager.getConnection(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword());var s=c.createStatement()) {
            s.execute("CREATE DATABASE "+databaseName+" OWNER uten_migrator TEMPLATE numbering_seal_template");
        }
        jdbcUrl=postgres.getJdbcUrl().replace("/numbering_seal_template","/"+databaseName);
        db=new JdbcTemplate(new DriverManagerDataSource(jdbcUrl,postgres.getUsername(),postgres.getPassword()));
    }
    @AfterEach void dropClone() throws Exception {
        if(databaseName!=null)try(var c=DriverManager.getConnection(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword());var s=c.createStatement()) {
            s.execute("DROP DATABASE "+databaseName+" WITH (FORCE)");
        }
    }

    @Test void exactForwardUpgradePreservesInstallerIdentityAndStrictReadoption() throws Exception {
        String identity=identity();
        String oldSeal=db.queryForObject("SELECT catalog_sha256 FROM employee_code_reuse_installation",String.class);
        Long functionOid=db.queryForObject("SELECT 'fn_employee_code_requires_identity_mapping(text)'::regprocedure::oid",Long.class);
        var flyway=TestFlyway.configureWithInitSql("SET ROLE uten_migrator")
                .dataSource(jdbcUrl,postgres.getUsername(),postgres.getPassword())
                .locations("classpath:db/migration").target("977").load();
        assertThat(flyway.migrate().migrationsExecuted).isEqualTo(1);
        assertThat(flyway.migrate().migrationsExecuted).isZero();
        assertThat(identity()).isEqualTo(identity);
        assertThat(db.queryForObject("SELECT catalog_sha256 FROM employee_code_reuse_installation",String.class)).isNotEqualTo(oldSeal);
        assertThat(db.queryForObject("SELECT 'fn_employee_code_requires_identity_mapping(text)'::regprocedure::oid",Long.class)).isEqualTo(functionOid);
        try(var c=owner();var s=c.createStatement()) {
            s.execute(mergeInstaller);s.execute(codeInstaller);
            assertThatThrownBy(()->s.execute("UPDATE employee_code_reuse_installation SET catalog_sha256=repeat('a',64)"))
                    .isInstanceOf(SQLException.class).hasMessageContaining("append-only");
        }
        assertThat(identity()).isEqualTo(identity);
        assertThat(db.queryForObject("SELECT rolsuper FROM pg_roles WHERE rolname='uten_migrator'",Boolean.class)).isFalse();
        assertThat(db.queryForObject("SELECT has_table_privilege('uten','employee_code_numbering_receipts','SELECT')",Boolean.class)).isFalse();
    }

    @Test void forwardUpgradeRejectsFunctionAclTriggerAndPayloadDriftWithoutResealingIt() throws Exception {
        String original=db.queryForObject("SELECT to_jsonb(i)::text FROM employee_code_reuse_installation i",String.class);
        for(String mutation:mutations()) {
            try(var c=owner();var s=c.createStatement()) {
                c.setAutoCommit(false);
                try {
                    s.execute(mutation);
                    assertThatThrownBy(()->s.execute(numbering)).isInstanceOf(SQLException.class)
                            .hasMessageContaining("forward adoption refused");
                } finally {c.rollback();}
            }
            assertThat(db.queryForObject("SELECT to_jsonb(i)::text FROM employee_code_reuse_installation i",String.class)).isEqualTo(original);
            assertThat(db.queryForObject("SELECT to_regclass('employee_code_numbering_receipts') IS NULL",Boolean.class)).isTrue();
        }
    }

    @Test void aPreviouslySealedNormalImmutableGuardRetainsItsOriginalMode() throws Exception {
        // Fixture-only owner setup: seal the NORMAL variant with V965's own
        // independent catalog expression, and prove the old installer adopts it.
        // An unsealed A -> O mutation remains rejected by the negative cases.
        int start=codeInstaller.indexOf("    SELECT encode(public.digest(convert_to(jsonb_build_object(");
        String originalVerifier=codeInstaller.substring(start,codeInstaller.indexOf(" INTO actual_catalog;",start));
        try(var c=owner();var s=c.createStatement()) {
            c.setAutoCommit(false);
            s.execute("ALTER TABLE employee_code_reuse_installation ENABLE TRIGGER trg_employee_code_installation_immutable");
            String seal;
            try(var rows=s.executeQuery(originalVerifier)){assertThat(rows.next()).isTrue();seal=rows.getString(1);}
            s.execute("ALTER TABLE employee_code_reuse_installation DISABLE TRIGGER trg_employee_code_installation_immutable");
            try(var update=c.prepareStatement("UPDATE employee_code_reuse_installation SET catalog_sha256=?")) {
                update.setString(1,seal);assertThat(update.executeUpdate()).isEqualTo(1);
            }
            s.execute("ALTER TABLE employee_code_reuse_installation ENABLE TRIGGER trg_employee_code_installation_immutable");
            s.execute(codeInstaller);
            c.commit();
            String identity=identity();
            s.execute(numbering);
            s.execute(codeInstaller);
            c.commit();
            assertThat(identity()).isEqualTo(identity);
        }
        assertThat(db.queryForObject("SELECT tgenabled::text FROM pg_trigger WHERE tgrelid='employee_code_reuse_installation'::regclass AND tgname='trg_employee_code_installation_immutable'",String.class)).isEqualTo("O");
    }

    @Test void unchangedV965StillRejectsEveryCatalogMutationAfterTheReviewedForwardUpgrade() throws Exception {
        try(var c=owner();var s=c.createStatement()){s.execute(numbering);}
        String original=db.queryForObject("SELECT to_jsonb(i)::text FROM employee_code_reuse_installation i",String.class);
        for(String mutation:mutations()) {
            try(var c=owner();var s=c.createStatement()) {
                c.setAutoCommit(false);
                try {
                    s.execute(mutation);
                    assertThatThrownBy(()->s.execute(codeInstaller)).isInstanceOf(SQLException.class)
                            .hasMessageContaining("payload or catalog differs");
                } finally {c.rollback();}
            }
            assertThat(db.queryForObject("SELECT to_jsonb(i)::text FROM employee_code_reuse_installation i",String.class)).isEqualTo(original);
        }
        try(var c=owner();var s=c.createStatement()){s.execute(codeInstaller);}
    }

    @Test void failureAfterReceiptCasRollsBackTheReceiptDefinitionAndAlwaysGuardTogether() throws Exception {
        String original=db.queryForObject("SELECT to_jsonb(i)::text FROM employee_code_reuse_installation i",String.class);
        String function=db.queryForObject("SELECT pg_get_functiondef('fn_employee_code_requires_identity_mapping(text)'::regprocedure)",String.class);
        // Deterministic fault at the narrowest unsafe point: the receipt was
        // updated and its one guard is still disabled inside the owner DDL.
        String faulted=numbering.replace("GET DIAGNOSTICS affected=ROW_COUNT;",
                "GET DIAGNOSTICS affected=ROW_COUNT; RAISE EXCEPTION 'intentional post-CAS fixture failure';");
        assertThat(faulted).isNotEqualTo(numbering);
        try(var c=owner();var s=c.createStatement()) {
            c.setAutoCommit(false);
            try {
                assertThatThrownBy(()->s.execute(faulted)).isInstanceOf(SQLException.class)
                        .hasMessageContaining("intentional post-CAS fixture failure");
            } finally {c.rollback();}
        }
        assertThat(db.queryForObject("SELECT to_jsonb(i)::text FROM employee_code_reuse_installation i",String.class)).isEqualTo(original);
        assertThat(db.queryForObject("SELECT pg_get_functiondef('fn_employee_code_requires_identity_mapping(text)'::regprocedure)",String.class)).isEqualTo(function);
        assertThat(db.queryForObject("SELECT tgenabled::text FROM pg_trigger WHERE tgrelid='employee_code_reuse_installation'::regclass AND tgname='trg_employee_code_installation_immutable'",String.class)).isEqualTo("A");
        assertThat(db.queryForObject("SELECT to_regclass('employee_code_numbering_receipts') IS NULL",Boolean.class)).isTrue();
        try(var c=owner();var s=c.createStatement()){s.execute(codeInstaller);}
    }

    private static String[] mutations(){return new String[]{
            "ALTER FUNCTION fn_employee_code_requires_identity_mapping(text) SECURITY INVOKER",
            "ALTER FUNCTION fn_claim_next_released_employee_code(uuid) SECURITY INVOKER",
            "GRANT EXECUTE ON FUNCTION fn_employee_code_reuse_actor() TO PUBLIC",
            "GRANT SELECT ON employee_code_reuse_claims TO uten",
            "ALTER TABLE employee_code_reuse_claims DISABLE TRIGGER trg_finish_employee_code_reuse_claim",
            "ALTER TABLE employees DISABLE TRIGGER trg_employee_code_reuse_legacy_import",
            "ALTER TABLE employee_code_reuse_installation ENABLE TRIGGER trg_employee_code_installation_immutable",
            "ALTER TABLE employee_code_reuse_installation DISABLE TRIGGER trg_employee_code_installation_immutable;"
                    +"UPDATE employee_code_reuse_installation SET payload_sha256=repeat('a',64);"
                    +"ALTER TABLE employee_code_reuse_installation ENABLE TRIGGER trg_employee_code_installation_immutable"
    };}
    private String identity(){return db.queryForObject("SELECT (to_jsonb(i)-'catalog_sha256')::text FROM employee_code_reuse_installation i",String.class);}
    private Connection owner() throws Exception {
        var c=DriverManager.getConnection(jdbcUrl,postgres.getUsername(),postgres.getPassword());
        try(var s=c.createStatement()){s.execute("SET ROLE uten_migrator");}
        return c;
    }
    private static String resource(String name) throws Exception {
        return new ClassPathResource("db/migration/"+name).getContentAsString(StandardCharsets.UTF_8);
    }
}
