package com.uten.imp.features.org.employee;

import com.uten.imp.testsupport.TestFlyway;
import com.uten.imp.features.admin.PermissionConfigurationTransferService;
import com.uten.imp.features.admin.dto.PermissionTransferDtos.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.HexFormat;
import java.util.UUID;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Actual V948 plus only the two reviewed maintenance extensions; never migrates dirty V949-V963. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class EmployeeCodeReuseExtensionPostgresTest {
    static PostgreSQLContainer postgres;
    static String codeInstaller;
    static String parentInstaller;
    static String parentSha;
    static final UUID SOURCE=UUID.randomUUID(),CANONICAL=UUID.randomUUID(),AUTH_SOURCE=UUID.randomUUID(),AUTH_CANONICAL=UUID.randomUUID();
    String databaseName;
    String jdbcUrl;
    JdbcTemplate db;
    UUID actor;

    @BeforeAll static void template() throws Exception {
        postgres=new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("employee_code_template").withReuse(false);
        postgres.start();
        try(Connection connection=DriverManager.getConnection(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword());
            var statement=connection.createStatement()) {
            statement.execute("CREATE ROLE uten_migrator NOLOGIN NOSUPERUSER");
            statement.execute("CREATE ROLE uten NOLOGIN NOSUPERUSER");
            statement.execute("ALTER DATABASE employee_code_template OWNER TO uten_migrator");
            statement.execute("GRANT USAGE,CREATE ON SCHEMA public TO uten_migrator");
            statement.execute("GRANT USAGE ON SCHEMA public TO uten");
        }
        TestFlyway.configureWithInitSql("SET ROLE uten_migrator").dataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword())
                .locations("classpath:db/migration").target("948").load().migrate();
        parentInstaller=Files.readString(maintenance("employee_identity_merge_extension_v1.sql"));
        parentSha=HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(parentInstaller.getBytes(StandardCharsets.UTF_8)));
        codeInstaller=Files.readString(maintenance("employee_code_reuse_extension_v1.sql"));
        try(Connection connection=DriverManager.getConnection(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword())) {
            // These are the historical duplicates which existed under V948.
            // Seed before installing the new-name guard; never disable it during actions under test.
            insertEmployee(connection,SOURCE,"UT8171","Original person");
            insertEmployee(connection,CANONICAL,"UT8172","Original person");
            insertEmployee(connection,AUTH_SOURCE,"AUTH9001","Auth original person");
            insertEmployee(connection,AUTH_CANONICAL,"UT8174","Auth original person");
            try(var statement=connection.createStatement()) {
                statement.execute("GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO uten");
                statement.execute("GRANT USAGE,SELECT,UPDATE ON ALL SEQUENCES IN SCHEMA public TO uten");
                statement.execute("ALTER DEFAULT PRIVILEGES FOR ROLE uten_migrator IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO uten");
                statement.execute("CREATE DATABASE employee_code_948 TEMPLATE employee_code_template");
            }
            connection.setAutoCommit(false);
            try(var statement=connection.createStatement()){statement.execute("SET LOCAL ROLE uten_migrator");}
            try(var statement=connection.createStatement()) {
                statement.execute("INSERT INTO users(employee_id,login_account,password_hash,status,must_change_password,is_super_admin) SELECT id,'code-reuse-operator','synthetic-test-only','active',false,false FROM employees WHERE code='ADMIN'");
            }
            try(var config=connection.prepareStatement("SELECT set_config('app.employee_identity_merge_install_sha',?,true)")) {
                config.setString(1,parentSha);config.execute();
            }
            try(var statement=connection.createStatement()) {statement.execute(parentInstaller);statement.execute(codeInstaller);}
            connection.commit();
        }
    }
    @AfterAll static void stop(){if(postgres!=null)postgres.stop();}
    @BeforeEach void freshDatabase() throws Exception {
        databaseName="employee_code_"+UUID.randomUUID().toString().replace("-","");
        try(Connection connection=DriverManager.getConnection(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword());
            var statement=connection.createStatement()) {
            statement.execute("CREATE DATABASE \""+databaseName+"\" TEMPLATE employee_code_template");
        }
        jdbcUrl=postgres.getJdbcUrl().replace("/employee_code_template","/"+databaseName);
        db=new JdbcTemplate(new DriverManagerDataSource(jdbcUrl,postgres.getUsername(),postgres.getPassword()));
        actor=db.queryForObject("SELECT id FROM users WHERE login_account='code-reuse-operator' AND NOT is_deleted AND status='active'",UUID.class);
    }
    @AfterEach void dropDatabase() throws Exception {
        if(databaseName==null)return;
        try(Connection connection=DriverManager.getConnection(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword());
            var statement=connection.createStatement()) {
            statement.execute("DROP DATABASE \""+databaseName+"\" WITH (FORCE)");
        }
    }

    @Test void identicalReinstallAdoptsWithoutChangingHistoryCountersOrMetadata() {
        String metadata=db.queryForObject("SELECT to_jsonb(i)::text FROM employee_code_reuse_installation i",String.class);
        long migrations=count("SELECT count(*) FROM flyway_schema_history");
        String reservations=db.queryForObject("SELECT md5(COALESCE(string_agg(to_jsonb(r)::text,'' ORDER BY normalized_identifier),'')) FROM business_identifier_reservations r",String.class);
        String sequence=db.queryForObject("SELECT to_jsonb(s)::text FROM master_code_sequences s WHERE prefix='UT'",String.class);
        db.execute(codeInstaller);
        assertThat(db.queryForObject("SELECT to_jsonb(i)::text FROM employee_code_reuse_installation i",String.class)).isEqualTo(metadata);
        assertThat(count("SELECT count(*) FROM flyway_schema_history")).isEqualTo(migrations);
        assertThat(db.queryForObject("SELECT max(version::numeric) FROM flyway_schema_history WHERE success AND version~'^[0-9]+$'",Integer.class)).isEqualTo(948);
        assertThat(db.queryForObject("SELECT to_jsonb(s)::text FROM master_code_sequences s WHERE prefix='UT'",String.class)).isEqualTo(sequence);
        assertThat(db.queryForObject("SELECT md5(COALESCE(string_agg(to_jsonb(r)::text,'' ORDER BY normalized_identifier),'')) FROM business_identifier_reservations r",String.class)).isEqualTo(reservations);
    }

    @Test void bothExtensionsRemainStrictlyAdoptableTogetherUnderTheRealNonSuperuserMigrationOwner() throws Exception {
        String before=db.queryForObject("SELECT catalog_sha256 FROM employee_identity_merge_installation WHERE version='v1'",String.class);
        try(Connection connection=connection()) {
            connection.setAutoCommit(false);
            try(var statement=connection.createStatement()) {
                statement.execute("SET LOCAL ROLE uten_migrator");
                try(var config=connection.prepareStatement("SELECT set_config('app.employee_identity_merge_install_sha',?,true)")){
                    config.setString(1,parentSha);config.execute();
                }
                statement.execute(parentInstaller);statement.execute(codeInstaller);
            }
            connection.commit();
        }
        assertThat(db.queryForObject("SELECT catalog_sha256 FROM employee_identity_merge_installation WHERE version='v1'",String.class)).isEqualTo(before);
        assertThat(db.queryForObject("SELECT rolsuper FROM pg_roles WHERE rolname='uten_migrator'",Boolean.class)).isFalse();
        assertThat(db.queryForList("SELECT DISTINCT pg_get_userbyid(relowner) FROM pg_class WHERE relname LIKE 'employee_code_reuse_%' AND relkind='r'",String.class)).containsExactly("uten_migrator");
        assertThat(db.queryForList("SELECT DISTINCT pg_get_userbyid(p.proowner) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND (p.proname LIKE 'fn_employee_code_%' OR p.proname IN('fn_claim_next_released_employee_code','fn_release_merged_employee_code','fn_guard_employee_code_claim_insert','fn_guard_employee_code_release_insert','fn_guard_employee_code_reuse_legacy_import','fn_finish_employee_code_reuse_claim','fn_reserve_master_code','fn_claim_global_business_identifier'))",String.class)).containsExactly("uten_migrator");
        assertThat(db.queryForObject("SELECT has_table_privilege('uten','public.employee_code_reuse_releases','INSERT')",Boolean.class)).isFalse();
        assertThat(db.queryForObject("SELECT has_table_privilege('uten','public.employee_identity_merge_payloads','SELECT')",Boolean.class)).isFalse();
        assertThat(db.queryForObject("SELECT has_function_privilege('uten','public.fn_merge_employee_identity(jsonb)','EXECUTE')",Boolean.class)).isFalse();
        assertThat(db.queryForObject("SELECT has_function_privilege('uten','public.fn_release_merged_employee_code(uuid)','EXECUTE')",Boolean.class)).isFalse();
        assertThat(db.queryForObject("SELECT has_function_privilege('uten','public.fn_employee_code_reuse_actor()','EXECUTE')",Boolean.class)).isFalse();
    }

    @Test void aRealRuntimeRoleCanClaimButCannotForgeReleaseEvidence() throws Exception {
        Merge completed=completedMerge();release(completed);
        UUID newcomer=UUID.randomUUID();
        try(Connection connection=connection()) {
            connection.setAutoCommit(false);
            try(var statement=connection.createStatement()){statement.execute("SET LOCAL ROLE uten");}
            try(var statement=connection.prepareStatement("SELECT fn_employee_code_requires_identity_mapping(?)")) {
                statement.setString(1,completed.code());try(var result=statement.executeQuery()){assertThat(result.next()).isTrue();assertThat(result.getBoolean(1)).isTrue();}
            }
            var savepoint=connection.setSavepoint();
            try(var statement=connection.prepareStatement("SELECT fn_release_merged_employee_code(?)")) {
                statement.setObject(1,completed.source());
                assertThatThrownBy(statement::execute).isInstanceOf(SQLException.class).hasMessageContaining("permission denied");
            }
            connection.rollback(savepoint);
            assertThat(claim(connection,newcomer)).isEqualTo(completed.code());
            insertEmployee(connection,newcomer,completed.code(),"Runtime-created new employee");connection.commit();
        }
        assertThat(db.queryForObject("SELECT full_name FROM employees WHERE id=?",String.class,newcomer)).isEqualTo("Runtime-created new employee");
    }

    @Test void runtimeWithoutAValidCurrentActorCannotConsumeThePool() throws Exception {
        Merge completed=completedMerge();release(completed);
        try(Connection connection=connection()) {
            connection.setAutoCommit(false);
            try(var statement=connection.createStatement()) {statement.execute("SET LOCAL ROLE uten");}
            try(var statement=connection.prepareStatement("SELECT fn_claim_next_released_employee_code(?)")) {
                statement.setObject(1,UUID.randomUUID());
                assertThatThrownBy(statement::execute).isInstanceOf(SQLException.class).hasMessageContaining("active current employee actor");
            } finally {connection.rollback();}
        }
        assertThat(count("SELECT count(*) FROM employee_code_reuse_claims")).isZero();
    }

    @Test void internalAuthLabelsKeepHistoricalReservationsButNeverEnterTheOrdinaryUtPool() throws Exception {
        Merge completed=completedMerge("AUTH9001",false);
        assertThat(db.queryForObject("SELECT fn_release_merged_employee_code(?)",UUID.class,completed.source())).isNull();
        assertThat(count("SELECT count(*) FROM employee_code_reuse_releases")).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM business_identifier_reservation_members WHERE entity_id=?",Long.class,completed.source())).isEqualTo(1);
        try(Connection connection=connection()){assertThat(claim(connection,UUID.randomUUID())).isNull();}
    }

    @Test void missingOrIncompleteMergeEvidenceCannotReleaseAnyNumber() throws Exception {
        assertThatThrownBy(()->db.queryForObject("SELECT fn_release_merged_employee_code(?)",UUID.class,UUID.randomUUID()))
                .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
        assertThat(count("SELECT count(*) FROM employee_code_reuse_releases")).isZero();
        try(Connection connection=connection()){assertThat(claim(connection,UUID.randomUUID())).isNull();}
        assertThat(count("SELECT count(*) FROM employee_code_reuse_claims")).isZero();
    }

    @Test void changedPayloadIsRefusedRatherThanOverwritingInstalledEvidence() {
        String before=db.queryForObject("SELECT payload_sha256 FROM employee_code_reuse_installation",String.class);
        assertThatThrownBy(()->db.execute(codeInstaller.replace("Retired employee number evidence after", "Changed employee number evidence after")))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThat(db.queryForObject("SELECT payload_sha256 FROM employee_code_reuse_installation",String.class)).isEqualTo(before);
    }

    @Test void disabledCompletionGuardAndChangedSecurityDefinerCannotBeSilentlyAdopted() throws Exception {
        for(String mutation:new String[]{
                "ALTER TABLE employee_code_reuse_claims DISABLE TRIGGER trg_finish_employee_code_reuse_claim",
                "ALTER FUNCTION fn_claim_next_released_employee_code(uuid) SECURITY INVOKER",
                "ALTER TABLE employees DISABLE TRIGGER trg_employee_code_reuse_legacy_import",
                "ALTER TABLE employee_sensitive DISABLE TRIGGER trg_employee_code_reuse_legacy_sensitive_import"}) {
            try(Connection connection=connection()) {
                connection.setAutoCommit(false);
                try(var statement=connection.createStatement()) {
                    statement.execute(mutation);
                    assertThatThrownBy(()->statement.execute(codeInstaller)).isInstanceOf(SQLException.class)
                            .hasMessageContaining("catalog differs");
                } finally {connection.rollback();}
            }
        }
        db.execute(codeInstaller);
    }

    @Test void completedPhysicalMergeReusesOnlyTheCodeWhileOldIdentityAndReservationEvidenceStayWithTheOriginalPerson() throws Exception {
        Merge completed=completedMerge();
        String globalBefore=db.queryForObject("SELECT to_jsonb(m)::text FROM business_identifier_reservation_members m WHERE owner_domain='EMPLOYEE' AND entity_id=?",String.class,completed.source());
        String domainBefore=db.queryForObject("SELECT to_jsonb(m)::text FROM master_code_reservation_members m WHERE master_domain='EMPLOYEE' AND entity_id=?",String.class,completed.source());
        String sequence=db.queryForObject("SELECT to_jsonb(s)::text FROM master_code_sequences s WHERE prefix='UT'",String.class);
        release(completed);
        UUID newcomer=UUID.randomUUID();
        try(Connection connection=connection()) {
            connection.setAutoCommit(false);
            assertThat(claim(connection,newcomer)).isEqualTo(completed.code());
            insertEmployee(connection,newcomer,completed.code(),"Another new person");
            connection.commit();
        }
        assertThat(count("SELECT count(*) FROM employees WHERE code='UT8171'")).isEqualTo(1);
        assertThat(db.queryForObject("SELECT full_name FROM employees WHERE id=?",String.class,newcomer)).isEqualTo("Another new person");
        assertThat(db.queryForObject("SELECT canonical_employee_id FROM employee_identity_merges WHERE source_employee_id=?",UUID.class,completed.source())).isEqualTo(completed.canonical());
        assertThat(db.queryForObject("SELECT fn_canonical_employee_identity(?)",UUID.class,completed.source())).isEqualTo(completed.canonical());
        assertThat(db.queryForObject("SELECT to_jsonb(m)::text FROM business_identifier_reservation_members m WHERE owner_domain='EMPLOYEE' AND entity_id=?",String.class,completed.source())).isEqualTo(globalBefore);
        assertThat(db.queryForObject("SELECT to_jsonb(m)::text FROM master_code_reservation_members m WHERE master_domain='EMPLOYEE' AND entity_id=?",String.class,completed.source())).isEqualTo(domainBefore);
        assertThat(db.queryForObject("SELECT to_jsonb(s)::text FROM master_code_sequences s WHERE prefix='UT'",String.class)).isEqualTo(sequence);
        assertThat(db.queryForObject("SELECT new_employee_id FROM employee_code_reuse_claims",UUID.class)).isEqualTo(newcomer);
        assertThat(db.queryForObject("SELECT full_name FROM employees WHERE id=?",String.class,completed.canonical())).isEqualTo("Original person");
    }

    @Test void abandonedClaimFailsDeferredCompletionAndRollbackLeavesTheNumberAvailableForAnotherNewUuid() throws Exception {
        Merge completed=completedMerge();release(completed);
        UUID abandoned=UUID.randomUUID();
        try(Connection connection=connection()) {
            connection.setAutoCommit(false);
            assertThat(claim(connection,abandoned)).isEqualTo(completed.code());
            assertThatThrownBy(connection::commit).isInstanceOf(SQLException.class).hasMessageContaining("did not complete");
            connection.rollback();
        }
        assertThat(count("SELECT count(*) FROM employee_code_reuse_claims")).isZero();
        UUID winner=UUID.randomUUID();
        try(Connection connection=connection()) {
            connection.setAutoCommit(false);
            assertThat(claim(connection,winner)).isEqualTo(completed.code());
            insertEmployee(connection,winner,completed.code(),"New winner");
            connection.commit();
        }
        assertThat(db.queryForObject("SELECT new_employee_id FROM employee_code_reuse_claims",UUID.class)).isEqualTo(winner);
    }

    @Test void rollbackOfACompleteEmployeeInsertAlsoRollsBackBothNewMembershipsAndTheClaim() throws Exception {
        Merge completed=completedMerge();release(completed);
        UUID rolledBack=UUID.randomUUID();
        try(Connection connection=connection()) {
            connection.setAutoCommit(false);
            assertThat(claim(connection,rolledBack)).isEqualTo(completed.code());
            insertEmployee(connection,rolledBack,completed.code(),"Rolled back new person");
            connection.rollback();
        }
        assertThat(db.queryForObject("SELECT count(*) FROM employees WHERE id=?",Long.class,rolledBack)).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM business_identifier_reservation_members WHERE entity_id=?",Long.class,rolledBack)).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM master_code_reservation_members WHERE entity_id=?",Long.class,rolledBack)).isZero();
        assertThat(count("SELECT count(*) FROM employee_code_reuse_claims")).isZero();
    }

    @Test void concurrentNewEmployeesCannotBothClaimTheSameReleasedNumber() throws Exception {
        Merge completed=completedMerge();release(completed);
        UUID first=UUID.randomUUID(),second=UUID.randomUUID();
        try(Connection winner=connection()) {
            winner.setAutoCommit(false);
            assertThat(claim(winner,first)).isEqualTo(completed.code());
            var competing=CompletableFuture.supplyAsync(()->{
                try(Connection connection=connection()) {return claim(connection,second);}
                catch(SQLException failure){throw new RuntimeException(failure);}
            });
            assertThat(competing.get(10,TimeUnit.SECONDS)).isNull();
            insertEmployee(winner,first,completed.code(),"Concurrent winner");winner.commit();
        }
        assertThat(count("SELECT count(*) FROM employee_code_reuse_claims")).isEqualTo(1);
        assertThat(db.queryForObject("SELECT new_employee_id FROM employee_code_reuse_claims",UUID.class)).isEqualTo(first);
    }

    @Test void aLiveEmployeeOrRetiredSourceUuidCannotClaimAndAnotherNamespaceCannotStealEvenInsideTheWinningTransaction() throws Exception {
        Merge completed=completedMerge();release(completed);
        for(UUID invalid:new UUID[]{completed.source(),completed.canonical()}) {
            assertThatThrownBy(()->db.queryForObject("SELECT fn_claim_next_released_employee_code(?)",String.class,invalid))
                    .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
        }
        UUID winner=UUID.randomUUID();
        try(Connection connection=connection()) {
            connection.setAutoCommit(false);
            assertThat(claim(connection,winner)).isEqualTo(completed.code());
            for(String[] namespace:new String[][]{{"GOODS","goods"},{"PURCHASE_ORDER","purchase_orders"}}) {
                var savepoint=connection.setSavepoint();
                try(var statement=connection.prepareStatement("SELECT fn_claim_global_business_identifier(?,?,?,NULL,?)")) {
                    statement.setString(1,completed.code());statement.setString(2,namespace[0]);
                    statement.setObject(3,winner);statement.setString(4,namespace[1]);
                    assertThatThrownBy(statement::execute).isInstanceOf(SQLException.class).hasMessageContaining("another identity");
                }
                connection.rollback(savepoint);
            }
            insertEmployee(connection,winner,completed.code(),"Isolated employee owner");connection.commit();
        }
        assertThat(db.queryForList("SELECT DISTINCT owner_domain FROM business_identifier_reservation_members WHERE entity_id=?",String.class,winner)).containsExactly("EMPLOYEE");
    }

    @Test void staleCodeOnlyLegacyReimportCannotRenameOrReplaceTheNewPersonsIdentifiersButNormalUuidEditsRemainAvailable() throws Exception {
        Merge completed=completedMerge();release(completed);
        UUID newcomer=UUID.randomUUID();
        try(Connection connection=connection()) {
            connection.setAutoCommit(false);assertThat(claim(connection,newcomer)).isEqualTo(completed.code());
            insertEmployee(connection,newcomer,completed.code(),"New person");connection.commit();
        }
        try(Connection connection=connection()) {
            connection.setAutoCommit(false);
            try(var statement=connection.createStatement()) {
                statement.execute("SET LOCAL app.business_identifier_legacy_import='on'");
                assertThatThrownBy(()->statement.execute("UPDATE employees SET full_name='Original person' WHERE code='UT8171'"))
                        .isInstanceOf(SQLException.class).hasMessageContaining("legacy code-only import");
            } finally {connection.rollback();}
        }
        try(Connection connection=connection()) {
            connection.setAutoCommit(false);
            try(var statement=connection.createStatement()) {
                statement.execute("SET LOCAL app.business_identifier_legacy_import='on'");
                try(var sensitive=connection.prepareStatement("INSERT INTO employee_sensitive(employee_id) VALUES(?)")) {
                    sensitive.setObject(1,newcomer);
                    assertThatThrownBy(sensitive::execute).isInstanceOf(SQLException.class).hasMessageContaining("legacy code-only import");
                }
            } finally {connection.rollback();}
        }
        assertThat(db.queryForObject("SELECT full_name FROM employees WHERE id=?",String.class,newcomer)).isEqualTo("New person");
        assertThat(db.update("UPDATE employees SET full_name='New person corrected' WHERE id=?",newcomer)).isEqualTo(1);
        assertThat(db.queryForObject("SELECT full_name FROM employees WHERE id=?",String.class,completed.canonical())).isEqualTo("Original person");
    }

    @Test void permissionImportSuggestionsUseVerifiedRetiredUuidsAndNeverOfferTheNextPersonAtTheSameCode() throws Exception {
        Merge completed=completedMerge("UT8171",true);release(completed);
        UUID newcomer=UUID.randomUUID(),newUser=UUID.randomUUID();
        try(Connection connection=connection()) {
            connection.setAutoCommit(false);assertThat(claim(connection,newcomer)).isEqualTo(completed.code());
            insertEmployee(connection,newcomer,completed.code(),"Later different person");connection.commit();
        }
        insertUser(newUser,newcomer,false);
        Backup backup=new Backup(PermissionConfigurationTransferService.FORMAT,1,"synthetic",List.of(),List.of(),
                List.of(sourceUser(completed.sourceUser().toString(),"UT8171"),sourceUser("foreign-retired-user","UT8171"),
                        sourceUser(newUser.toString(),"UT8171"),sourceUser("foreign-current-user","UT8172")),
                List.of(new ScopeOwner(completed.source().toString(),"UT8171","Original person"),
                        new ScopeOwner("foreign-retired-owner","UT8171","Original person"),
                        new ScopeOwner(newcomer.toString(),"UT8171","Later different person"),
                        new ScopeOwner("foreign-current-owner","UT8172","Original person")));
        long overrides=count("SELECT count(*) FROM user_permission_overrides");
        List<Suggestion> suggested=suggestions(backup);
        assertThat(target(suggested,completed.sourceUser().toString())).isEqualTo(completed.canonicalUser());
        assertThat(target(suggested,"foreign-retired-user")).isNull();
        assertThat(suggested.stream().filter(row->row.sourceKey().equals("foreign-retired-user")).findFirst().orElseThrow().label()).contains("已释放或复用","手动选择");
        assertThat(target(suggested,newUser.toString())).isEqualTo(newUser);
        assertThat(target(suggested,"foreign-current-user")).isEqualTo(completed.canonicalUser());
        assertThat(target(suggested,completed.source().toString())).isEqualTo(completed.canonical());
        assertThat(target(suggested,"foreign-retired-owner")).isNull();
        assertThat(target(suggested,newcomer.toString())).isEqualTo(newcomer);
        assertThat(target(suggested,"foreign-current-owner")).isEqualTo(completed.canonical());
        assertThat(db.queryForObject("SELECT fn_employee_merge_retained_user(?)",UUID.class,UUID.randomUUID())).isNull();
        assertThat(count("SELECT count(*) FROM user_permission_overrides")).isEqualTo(overrides);
    }

    @Test void permissionSuggestionsKeepUnreusedCodeMatchingCompatibleWithAReal948DatabaseWithoutEitherExtension() throws Exception {
        try(Connection connection=DriverManager.getConnection(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword());
            var statement=connection.createStatement()) {
            statement.execute("DROP DATABASE \""+databaseName+"\" WITH (FORCE)");
            statement.execute("CREATE DATABASE \""+databaseName+"\" TEMPLATE employee_code_948");
        }
        UUID employee=UUID.randomUUID(),user=UUID.randomUUID();
        try(Connection connection=connection()){insertEmployee(connection,employee,"UT8200","Existing person");}
        insertUser(user,employee,false);
        assertThat(db.queryForObject("SELECT to_regclass('public.employee_identity_merges')::text",String.class)).isNull();
        Backup backup=new Backup(PermissionConfigurationTransferService.FORMAT,1,"synthetic",List.of(),List.of(),
                List.of(sourceUser("another-environment","UT8200")),List.of(new ScopeOwner("other-environment-owner","UT8200","Existing person")));
        List<Suggestion> suggested=suggestions(backup);
        assertThat(target(suggested,"another-environment")).isEqualTo(user);
        assertThat(target(suggested,"other-environment-owner")).isEqualTo(employee);
    }

    @Test void anAlreadySharedCrossNamespaceReservationCannotBeReleasedByAnEmployeeMergeCertificate() throws Exception {
        Merge completed=completedMerge();
        db.queryForObject("SELECT fn_claim_global_business_identifier(?,?,?,NULL,?,NULL,true,false)",Object.class,
                completed.code(),"PURCHASE_ORDER",UUID.randomUUID(),"purchase_orders");
        assertThatThrownBy(()->release(completed)).isInstanceOf(SQLException.class)
                .hasMessageContaining("Employee code ownership is shared, incomplete or already released");
        assertThat(count("SELECT count(*) FROM employee_code_reuse_releases")).isZero();
    }

    @Test void installed948ExtensionsWithCompletedEvidenceAndRolledBackClaimAdoptThroughTheFutureFullFlyway965() throws Exception {
        Merge completed=completedMerge();release(completed);
        try(Connection connection=connection()) {
            connection.setAutoCommit(false);UUID abandoned=UUID.randomUUID();
            assertThat(claim(connection,abandoned)).isEqualTo(completed.code());
            insertEmployee(connection,abandoned,completed.code(),"Rolled back before upgrade");connection.rollback();
        }
        try(Connection connection=connection()) {
            connection.setAutoCommit(false);
            try(var statement=connection.createStatement()) {
                statement.execute("SET LOCAL ROLE uten_migrator");
                try(var config=connection.prepareStatement("SELECT set_config('app.employee_identity_merge_install_sha',?,true)")) {
                    config.setString(1,parentSha);config.execute();
                }
                statement.execute(parentInstaller);statement.execute(codeInstaller);
            }
            connection.commit();
        }
        String codeSha=db.queryForObject("SELECT payload_sha256 FROM employee_code_reuse_installation",String.class);
        TestFlyway.configureWithInitSql("SET ROLE uten_migrator")
                .dataSource(jdbcUrl,postgres.getUsername(),postgres.getPassword()).locations("classpath:db/migration").target("965").load().migrate();
        assertThat(count("SELECT count(*) FROM flyway_schema_history WHERE version IN('964','965') AND success")).isEqualTo(2);
        assertThat(db.queryForObject("SELECT payload_sha256 FROM employee_code_reuse_installation",String.class)).isEqualTo(codeSha);
        assertThat(count("SELECT count(*) FROM employee_code_reuse_claims")).isZero();
        UUID newcomer=UUID.randomUUID();
        try(Connection connection=connection()) {
            connection.setAutoCommit(false);assertThat(claim(connection,newcomer)).isEqualTo(completed.code());
            insertEmployee(connection,newcomer,completed.code(),"After future migration");connection.commit();
        }
        assertThat(db.queryForObject("SELECT canonical_employee_id FROM employee_identity_merges WHERE source_employee_id=?",UUID.class,completed.source())).isEqualTo(completed.canonical());
    }

    private static UserConfiguration sourceUser(String key,String code){return new UserConfiguration(key,code,"Historical source","synthetic",List.of(),List.of(),List.of(),List.of(),Map.of());}
    private static UUID target(List<Suggestion> suggestions,String key){return suggestions.stream().filter(row->row.sourceKey().equals(key)).findFirst().orElseThrow().targetId();}
    private List<Suggestion> suggestions(Backup backup) {
        var bean=new LocalContainerEntityManagerFactoryBean();bean.setDataSource(new DriverManagerDataSource(jdbcUrl,postgres.getUsername(),postgres.getPassword()));
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());bean.setPackagesToScan("com.uten.imp.security");
        bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none"));bean.afterPropertiesSet();
        try(var factory=bean.getObject();var em=factory.createEntityManager()) {
            var service=mock(PermissionConfigurationTransferService.class,CALLS_REAL_METHODS);
            ReflectionTestUtils.setField(service,"em",em);
            return ReflectionTestUtils.invokeMethod(service,"suggestions",backup);
        }
    }
    private void insertUser(UUID id,UUID employee,boolean retired){db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,is_deleted,must_change_password) VALUES(?,?,?,'synthetic-fixture-only',?,?,false)",id,employee,"fixture-user-"+id,retired?"disabled":"active",retired);}

    private record Merge(UUID source,UUID canonical,String code,UUID sourceUser,UUID canonicalUser) { }
    private Merge completedMerge() throws Exception {
        return completedMerge("UT8171",false);
    }
    private Merge completedMerge(String sourceCode,boolean withAccounts) throws Exception {
        UUID source="AUTH9001".equals(sourceCode)?AUTH_SOURCE:SOURCE,canonical="AUTH9001".equals(sourceCode)?AUTH_CANONICAL:CANONICAL;
        assertThat(db.queryForObject("SELECT code FROM employees WHERE id=?",String.class,source)).isEqualTo(sourceCode);
        UUID sourceUser=withAccounts?UUID.randomUUID():null,canonicalUser=withAccounts?UUID.randomUUID():null;
        if(withAccounts) {
            db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,is_deleted,must_change_password) VALUES(?,?,?,'synthetic-fixture-only','disabled',true,false)",sourceUser,source,"retired-"+sourceUser);
            db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,is_deleted,must_change_password) VALUES(?,?,?,'synthetic-fixture-only','active',false,false)",canonicalUser,canonical,"retained-"+canonicalUser);
        }
        String planSql="""
            WITH scope AS MATERIALIZED(SELECT fn_employee_merge_source_snapshot(?) AS data),
            envelope AS MATERIALIZED(SELECT 'v1:'||encode(pgp_sym_encrypt(data::text,'synthetic-test-preservation-key'),'base64') AS cipher FROM scope)
            SELECT jsonb_build_object('protocol','employee-identity-merge-v1','database_identity',fn_employee_merge_database_identity(),
              'captured_at',clock_timestamp(),'paired_backup_verified',true,
              'paired_backup_reference','synthetic-paired-backup','paired_backup_manifest_sha256',repeat('c',64),
              'source_employee_id',source.id,'canonical_employee_id',retained.id,'source_code',source.code,
              'source_version',source.version,'canonical_version',retained.version,
              'canonical_row_sha256',encode(digest(to_jsonb(retained)::text,'sha256'),'hex'),
              'source_scope_sha256',encode(digest(scope.data::text,'sha256'),'hex'),'snapshot_enc',envelope.cipher,
              'snapshot_ciphertext_sha256',encode(digest(envelope.cipher,'sha256'),'hex'),'human_same_person_confirmed',true,
              'preservation_verified',true,'preservation_reference','synthetic-private-proof',
              'preservation_sha256',repeat('a',64),'evidence_reference','synthetic-reviewed','evidence_sha256',repeat('b',64),
              'actor','ops:synthetic','reason','Synthetic verified duplicate fixture','expected_stock_worker_count',0,'claims','[]'::jsonb)::text
            FROM employees source CROSS JOIN employees retained CROSS JOIN scope CROSS JOIN envelope WHERE source.id=? AND retained.id=?
            """;
        try(Connection connection=connection()) {
            connection.setAutoCommit(false);
            try(var statement=connection.createStatement()){statement.execute("SET LOCAL ROLE uten_migrator");}
            String plan;
            try(var statement=connection.prepareStatement(planSql)) {
                statement.setObject(1,source);statement.setObject(2,source);statement.setObject(3,canonical);
                try(var row=statement.executeQuery()){assertThat(row.next()).isTrue();plan=row.getString(1);}
            }
            try(var statement=connection.prepareStatement("SELECT fn_merge_employee_identity(CAST(? AS jsonb))->>'status'")) {
                statement.setString(1,plan);try(var row=statement.executeQuery()){assertThat(row.next()).isTrue();assertThat(row.getString(1)).isEqualTo("MERGED");}
            }
            connection.commit();
        }
        assertThat(db.queryForObject("SELECT count(*) FROM employees WHERE id=?",Long.class,source)).isZero();
        return new Merge(source,canonical,sourceCode,sourceUser,canonicalUser);
    }
    private void release(Merge completed) throws SQLException {
        try(Connection connection=connection()) {
            connection.setAutoCommit(false);
            try(var statement=connection.createStatement()){statement.execute("SET LOCAL ROLE uten_migrator");}
            try(var statement=connection.prepareStatement("SELECT fn_release_merged_employee_code(?)")) {
                statement.setObject(1,completed.source());UUID id;
                try(var row=statement.executeQuery()){assertThat(row.next()).isTrue();id=row.getObject(1,UUID.class);}
                try(var row=statement.executeQuery()){assertThat(row.next()).isTrue();assertThat(row.getObject(1,UUID.class)).isEqualTo(id);}
            }
            connection.commit();
        }
    }
    private String claim(Connection connection,UUID employee) throws SQLException {
        try(var statement=connection.prepareStatement("WITH bound_actor AS MATERIALIZED(SELECT set_config('app.actor_id',?,true)) SELECT fn_claim_next_released_employee_code(?) FROM bound_actor")) {
            statement.setString(1,actor.toString());statement.setObject(2,employee);try(var row=statement.executeQuery()){row.next();return row.getString(1);}
        }
    }
    private static void insertEmployee(Connection connection,UUID id,String code,String name) throws SQLException {
        try(var statement=connection.prepareStatement("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,confirmed_at,status,employment_type)
                SELECT ?,?,?,'其他',department_id,DATE '2020-01-01',DATE '2020-01-01','active','regular'
                FROM employees WHERE code='ADMIN'
                """)) {
            statement.setObject(1,id);statement.setString(2,code);statement.setString(3,name);assertThat(statement.executeUpdate()).isEqualTo(1);
        }
    }

    Connection connection() throws SQLException {return DriverManager.getConnection(jdbcUrl,postgres.getUsername(),postgres.getPassword());}
    long count(String sql){return db.queryForObject(sql,Long.class);}
    static Path maintenance(String name){Path file=Path.of("maintenance",name);return Files.exists(file)?file:Path.of("server").resolve(file);}
}
