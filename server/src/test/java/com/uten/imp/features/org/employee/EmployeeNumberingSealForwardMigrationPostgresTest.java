package com.uten.imp.features.org.employee;

import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;

/** Real non-superuser V976 -> V977 upgrade and unchanged V965 strict adoption. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class EmployeeNumberingSealForwardMigrationPostgresTest {
    static PostgreSQLContainer postgres;
    static String numbering,mergeInstaller,codeInstaller,restoreHelper;
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
        restoreHelper=Files.readString(Path.of("maintenance/restore_employee_sealed_owner_default_acls.sql"),StandardCharsets.UTF_8);
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

    @Test void migrationEmbedsTheOneCanonicalOwnerInvokedRestoreEntry() {
        assertThat(numbering).startsWith("-- BEGIN CANONICAL EMPLOYEE SEALED OWNER-DEFAULT ACL RESTORE\n"
                +restoreHelper.stripTrailing()+"\n-- END CANONICAL EMPLOYEE SEALED OWNER-DEFAULT ACL RESTORE\n\n");
        assertThat(restoreHelper).doesNotContain("CREATE FUNCTION", "DISABLE TRIGGER", "UPDATE public.");
    }

    @Test void realDumpRestoreBeforeAndAfterUpgradePreservesOldInstallerNoopAdoption() throws Exception {
        String restored=dumpRestore(databaseName);
        try {
            String url=urlOf(restored);
            var restoredDb=new JdbcTemplate(new DriverManagerDataSource(url,postgres.getUsername(),postgres.getPassword()));
            assertThat(restoredDb.queryForObject("SELECT count(*) FROM pg_class WHERE relkind='r' AND relname LIKE 'employee_code_reuse_%' AND relacl IS NULL",Integer.class)).isEqualTo(3);
            writeRestoreCatalogEvidence(jdbcUrl,url);
            assertThat(TestFlyway.configureWithInitSql("SET ROLE uten_migrator")
                    .dataSource(url,postgres.getUsername(),postgres.getPassword()).locations("classpath:db/migration")
                    .target("980").load().migrate().migrationsExecuted).isEqualTo(4);
            try(var c=owner(url);var s=c.createStatement()){s.execute(mergeInstaller);s.execute(codeInstaller);}
            String seals=seals(restoredDb);
            String again=dumpRestore(restored);
            try {
                String restoredAgain=urlOf(again);
                var againDb=new JdbcTemplate(new DriverManagerDataSource(restoredAgain,postgres.getUsername(),postgres.getPassword()));
                String privileges=privileges(againDb);
                String functionPrivileges=functionPrivileges(againDb);
                try(var c=owner(restoredAgain);var s=c.createStatement()) {
                    assertThatThrownBy(()->s.execute(mergeInstaller)).isInstanceOf(SQLException.class).hasMessageContaining("adoption refused");
                    s.execute(restoreHelper);s.execute(mergeInstaller);s.execute(codeInstaller);s.execute(restoreHelper);
                }
                assertThat(seals(againDb)).isEqualTo(seals);
                assertThat(privileges(againDb)).isEqualTo(privileges);
                assertThat(functionPrivileges(againDb)).isEqualTo(functionPrivileges);
            } finally {drop(again);}
        } finally {drop(restored);}
    }

    @Test void restoredNullAclsDoNotPermitUnknownPrivilegesDefinitionsOrOrdinaryCallers() throws Exception {
        String restored=dumpRestore(databaseName);
        try {
            try(var c=owner(urlOf(restored));var s=c.createStatement()) {
                c.setAutoCommit(false);
                try {s.execute(restoreHelper);} finally {c.rollback();}
            }
            for(String mutation:java.util.stream.Stream.concat(java.util.Arrays.stream(mutations()),java.util.stream.Stream.of(
                    "GRANT SELECT ON employee_identity_merge_payloads TO PUBLIC",
                    "GRANT SELECT(payload_sha256) ON employee_code_reuse_installation TO uten",
                    "ALTER TABLE employee_code_reuse_claims ENABLE ROW LEVEL SECURITY",
                    "ALTER FUNCTION fn_guard_employee_code_claim_insert() SECURITY INVOKER",
                    "ALTER FUNCTION fn_employee_merge_completed(uuid,uuid,text) SECURITY INVOKER")).toList()) {
                try(var c=owner(urlOf(restored));var s=c.createStatement()) {
                    c.setAutoCommit(false);
                    try {s.execute(mutation);assertThatThrownBy(()->s.execute(restoreHelper))
                            .isInstanceOf(SQLException.class).hasMessageContaining("forward adoption refused");}
                    finally {c.rollback();}
                }
            }
            try(var c=DriverManager.getConnection(urlOf(restored),postgres.getUsername(),postgres.getPassword());var s=c.createStatement()) {
                s.execute("SET ROLE uten");
                assertThatThrownBy(()->s.execute(restoreHelper)).isInstanceOf(SQLException.class).hasMessageContaining("existing employees owner");
            }
        } finally {drop(restored);}
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
        return owner(jdbcUrl);
    }
    private Connection owner(String url) throws Exception {
        var c=DriverManager.getConnection(url,postgres.getUsername(),postgres.getPassword());
        try(var s=c.createStatement()){s.execute("SET ROLE uten_migrator");}
        return c;
    }
    private static String urlOf(String name){return postgres.getJdbcUrl().replace("/numbering_seal_template","/"+name);}
    private void writeRestoreCatalogEvidence(String beforeUrl,String afterUrl) throws Exception {
        Path directory=Path.of(System.getProperty("uten.build.directory","target"),"restore-catalog-evidence");
        Files.createDirectories(directory);
        for(String kind:java.util.List.of("code","merge")) {
            String query=restoreHelper.split(java.util.regex.Pattern.quote("$"+kind+"_catalog$"))[1];
            for(String phase:java.util.List.of("before","after")) {
                try(var c=owner(phase.equals("before")?beforeUrl:afterUrl);var s=c.createStatement()) {
                    s.execute("SET search_path=pg_catalog,public,pg_temp");
                    try(var rows=s.executeQuery(query)) {
                        assertThat(rows.next()).isTrue();
                        Files.writeString(directory.resolve(kind+"-"+phase+".json"),rows.getString(1),StandardCharsets.UTF_8);
                    }
                }
            }
        }
    }
    private static String dumpRestore(String source) throws Exception {
        String target="seal_restore_"+UUID.randomUUID().toString().replace("-","");
        String archive="/tmp/"+target+".dump";
        try(var c=DriverManager.getConnection(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword());var s=c.createStatement()) {
            s.execute("CREATE DATABASE "+target+" OWNER uten_migrator TEMPLATE template0");
        }
        var dump=postgres.execInContainer("pg_dump","-U",postgres.getUsername(),"-d",source,"-Fc","-f",archive);
        assertThat(dump.getExitCode()).withFailMessage(dump.getStderr()).isZero();
        var restore=postgres.execInContainer("pg_restore","-U",postgres.getUsername(),"-d",target,"--exit-on-error",archive);
        assertThat(restore.getExitCode()).withFailMessage(restore.getStderr()).isZero();
        return target;
    }
    private static void drop(String name) throws Exception {
        try(var c=DriverManager.getConnection(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword());var s=c.createStatement()) {
            s.execute("DROP DATABASE "+name+" WITH (FORCE)");
        }
    }
    private static String seals(JdbcTemplate database) {
        return database.queryForObject("SELECT jsonb_build_array(to_jsonb(c),to_jsonb(m))::text FROM employee_code_reuse_installation c CROSS JOIN employee_identity_merge_installation m WHERE c.singleton AND m.version='v1'",String.class);
    }
    private static String privileges(JdbcTemplate database) {
        return database.queryForObject("""
            SELECT jsonb_agg(jsonb_build_array(c.relname,r.rolname,p.privilege,has_table_privilege(r.oid,c.oid,p.privilege))
                ORDER BY c.relname,r.rolname,p.privilege)::text FROM pg_class c CROSS JOIN pg_roles r CROSS JOIN unnest(ARRAY[
                'SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER','SELECT WITH GRANT OPTION',
                'INSERT WITH GRANT OPTION','UPDATE WITH GRANT OPTION','DELETE WITH GRANT OPTION',
                'TRUNCATE WITH GRANT OPTION','REFERENCES WITH GRANT OPTION','TRIGGER WITH GRANT OPTION']) p(privilege)
            WHERE c.relnamespace='public'::regnamespace AND c.relname IN('employee_code_reuse_claims',
                'employee_code_reuse_installation','employee_code_reuse_releases','employee_identity_legacy_roles',
                'employee_identity_merge_installation','employee_identity_merge_payloads',
                'employee_identity_review_certificates','employee_identity_user_tombstones')
            """,String.class);
    }
    private static String functionPrivileges(JdbcTemplate database) {
        return database.queryForObject("""
            SELECT jsonb_agg(jsonb_build_array(p.proname,r.rolname,a.privilege,has_function_privilege(r.oid,p.oid,a.privilege))
                ORDER BY p.proname,r.rolname,a.privilege)::text FROM pg_proc p
                JOIN pg_namespace n ON n.oid=p.pronamespace CROSS JOIN pg_roles r
                CROSS JOIN unnest(ARRAY['EXECUTE','EXECUTE WITH GRANT OPTION']) a(privilege)
            WHERE n.nspname='public' AND p.pronargs=0 AND p.proname IN('fn_employee_code_reuse_evidence_immutable',
                'fn_finish_employee_code_reuse_claim','fn_guard_employee_code_claim_insert',
                'fn_guard_employee_code_release_insert','fn_guard_employee_code_reuse_legacy_import')
            """,String.class);
    }
    private static String resource(String name) throws Exception {
        return new ClassPathResource("db/migration/"+name).getContentAsString(StandardCharsets.UTF_8);
    }
}
