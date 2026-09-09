package com.uten.imp.features.notice;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Real SQL superset proof; dynamic final authority is covered by PermissionResolver tests. */
@Testcontainers
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="true")
class NoticePermissionCandidatePostgresTest {
    @Container static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withLabel("uten.test", "notice-permission-candidate");
    private JdbcTemplate jdbc;
    private NoticePermissionCandidateQuery query;
    private final UUID action = UUID.randomUUID();
    private final UUID parent = UUID.randomUUID();
    private final UUID child = UUID.randomUUID();

    @BeforeEach
    void schema() {
        jdbc = new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
        query = new NoticePermissionCandidateQuery(jdbc);
        jdbc.execute("""
                DROP SCHEMA public CASCADE; CREATE SCHEMA public;
                CREATE TABLE permissions(id uuid PRIMARY KEY,code text,active boolean);
                CREATE TABLE users(id uuid PRIMARY KEY,employee_id uuid,is_super_admin boolean,is_deleted boolean,status text);
                CREATE TABLE employees(id uuid PRIMARY KEY,department_id uuid);
                CREATE TABLE departments(id uuid PRIMARY KEY,parent_id uuid);
                CREATE TABLE department_permissions(department_id uuid,permission_id uuid);
                CREATE TABLE employee_secondary_departments(employee_id uuid,department_id uuid);
                CREATE TABLE roles(id uuid PRIMARY KEY,code text);
                CREATE TABLE role_permissions(role_id uuid,permission_id uuid);
                CREATE TABLE user_roles(user_id uuid,role_id uuid);
                CREATE TABLE user_permission_overrides(user_id uuid,permission_id uuid,active boolean,effect text);
                CREATE TABLE manager_permission_delegations(user_id uuid,permission_id uuid,enabled boolean);
                """);
        jdbc.update("INSERT INTO permissions VALUES (?,'procurement_iqc_rejection:confirm_credit',true)", action);
        jdbc.update("INSERT INTO departments VALUES (?,null),(?,?)", parent, child, parent);
    }

    @Test
    void everyPositiveSourceIsIncludedAndRevokeDoesNotPrematurelyRemoveCandidate() {
        UUID primary = user(false), secondary = user(false), personal = user(false), manager = user(false);
        UUID admin = user(true), roleOnly = user(false), ordinary = user(false), revoked = user(false);
        jdbc.update("UPDATE employees SET department_id=? WHERE id IN (?,?)", child, primary, revoked);
        jdbc.update("INSERT INTO department_permissions VALUES (?,?)", parent, action);
        jdbc.update("INSERT INTO employee_secondary_departments VALUES (?,?)", secondary, child);
        jdbc.update("INSERT INTO user_permission_overrides VALUES (?,?,true,'grant'),(?,?,true,'revoke')", personal, action, revoked, action);
        jdbc.update("INSERT INTO manager_permission_delegations VALUES (?,?,true)", manager, action);
        UUID role = UUID.randomUUID();
        jdbc.update("INSERT INTO roles VALUES (?,'historical-role')", role);
        jdbc.update("INSERT INTO role_permissions VALUES (?,?)", role, action);
        jdbc.update("INSERT INTO user_roles VALUES (?,?)", roleOnly, role);
        assertEquals(Set.of(primary, secondary, personal, manager, admin, roleOnly, revoked), candidates());
        assertFalse(candidates().contains(ordinary));
    }

    @Test
    void baselineRoleKeepsEveryActiveUserWithoutRequiringAnEmployeeProfile() {
        UUID normal = user(false), noEmployee = user(false), disabled = user(true), deleted = user(true);
        jdbc.update("UPDATE users SET employee_id=null WHERE id=?", noEmployee);
        jdbc.update("UPDATE users SET status='disabled' WHERE id=?", disabled);
        jdbc.update("UPDATE users SET is_deleted=true WHERE id=?", deleted);
        UUID baseline = UUID.randomUUID();
        jdbc.update("INSERT INTO roles VALUES (?,'employee')", baseline);
        jdbc.update("INSERT INTO role_permissions VALUES (?,?)", baseline, action);
        assertEquals(Set.of(normal, noEmployee), candidates());
    }

    @Test
    void newGrantRevocationInactiveCatalogAndDisabledDelegationAreReadFresh() {
        UUID personal = user(false), manager = user(false);
        assertTrue(candidates().isEmpty());
        jdbc.update("INSERT INTO user_permission_overrides VALUES (?,?,true,'grant')", personal, action);
        jdbc.update("INSERT INTO manager_permission_delegations VALUES (?,?,true)", manager, action);
        assertEquals(Set.of(personal, manager), candidates());
        jdbc.update("UPDATE user_permission_overrides SET effect='revoke'");
        jdbc.update("UPDATE manager_permission_delegations SET enabled=false");
        assertTrue(candidates().isEmpty());
        jdbc.update("UPDATE user_permission_overrides SET effect='legacy-non-revoke-expression'");
        assertEquals(Set.of(personal), candidates(), "unknown non-revoke grant must remain over-selected");
        jdbc.update("UPDATE permissions SET active=false");
        assertTrue(candidates().isEmpty());
    }

    @Test
    void unknownOldSchemaFallsBackToFullResolutionInsteadOfLosingRecipients() {
        user(false);
        jdbc.execute("DROP TABLE manager_permission_delegations");
        assertTrue(query.possibleUsers(Set.of("procurement_iqc_rejection:confirm_credit")).isEmpty());
    }

    @Test
    void missingSourceFallbackKeepsCallerWriteAndTransactionUsable() {
        UUID caller = user(false);
        jdbc.execute("DROP TABLE manager_permission_delegations");
        var transaction = new TransactionTemplate(new DataSourceTransactionManager(jdbc.getDataSource()));
        transaction.executeWithoutResult(status -> {
            jdbc.update("INSERT INTO user_permission_overrides VALUES (?,?,true,'grant')", caller, action);
            assertTrue(query.possibleUsers(Set.of("procurement_iqc_rejection:confirm_credit")).isEmpty());
            // This is the same original connection/transaction after fallback. A
            // swallowed PostgreSQL error would make both reads fail with 25P02.
            assertEquals(1, jdbc.queryForObject("SELECT COUNT(*) FROM user_permission_overrides", Integer.class));
            assertEquals(Set.of("procurement_iqc_rejection:confirm_credit"), Set.copyOf(
                    jdbc.queryForList("SELECT code FROM permissions WHERE active=TRUE", String.class)));
        });
        assertEquals(1, jdbc.queryForObject("SELECT COUNT(*) FROM user_permission_overrides WHERE user_id=?", Integer.class, caller));
    }

    @Test
    void missingColumnAndUnrecognizedTypeAlsoFallBackBeforeAbortingTransaction() {
        var transaction = new TransactionTemplate(new DataSourceTransactionManager(jdbc.getDataSource()));
        transaction.executeWithoutResult(status -> {
            jdbc.execute("ALTER TABLE user_permission_overrides DROP COLUMN active");
            assertTrue(query.possibleUsers(Set.of("procurement_iqc_rejection:confirm_credit")).isEmpty());
            assertEquals(1, jdbc.queryForObject("SELECT COUNT(*) FROM permissions", Integer.class));
        });
        jdbc.execute("ALTER TABLE user_permission_overrides ADD COLUMN active text");
        transaction.executeWithoutResult(status -> {
            assertTrue(query.possibleUsers(Set.of("procurement_iqc_rejection:confirm_credit")).isEmpty());
            assertEquals(1, jdbc.queryForObject("SELECT COUNT(*) FROM permissions", Integer.class));
        });
    }

    @Test
    void validEmptyCandidateSetIsNotAnUnavailableOptimization() {
        user(false);
        var transaction = new TransactionTemplate(new DataSourceTransactionManager(jdbc.getDataSource()));
        transaction.executeWithoutResult(status -> {
            var result = query.possibleUsers(Set.of("procurement_iqc_rejection:confirm_credit"));
            assertTrue(result.isPresent());
            assertTrue(result.orElseThrow().isEmpty());
        });
    }

    @Test
    void permissionDenialIsPropagatedAndNeverConvertedToFullScanFallback() {
        String role = "notice_denied_" + UUID.randomUUID().toString().replace("-", "");
        jdbc.execute("CREATE ROLE " + role);
        jdbc.execute("GRANT USAGE ON SCHEMA public TO " + role);
        try {
            var transaction = new TransactionTemplate(new DataSourceTransactionManager(jdbc.getDataSource()));
            var failure = assertThrows(org.springframework.dao.DataAccessException.class, () ->
                    transaction.executeWithoutResult(status -> {
                        jdbc.execute("SET LOCAL ROLE " + role);
                        query.possibleUsers(Set.of("procurement_iqc_rejection:confirm_credit"));
                    }));
            Throwable cause = failure;
            while (cause.getCause() != null) cause = cause.getCause();
            assertInstanceOf(java.sql.SQLException.class, cause);
            assertEquals("42501", ((java.sql.SQLException) cause).getSQLState());
        } finally {
            jdbc.execute("DROP OWNED BY " + role);
            jdbc.execute("DROP ROLE " + role);
        }
    }

    @Test
    void connectionFailureIsNotMistakenForUnsupportedSourceShape() {
        var unavailable = org.mockito.Mockito.mock(JdbcTemplate.class);
        var failure = new org.springframework.dao.DataAccessResourceFailureException("connection unavailable");
        org.mockito.Mockito.when(unavailable.queryForObject(NoticePermissionCandidateQuery.SHAPE_SQL, Boolean.class))
                .thenThrow(failure);
        assertSame(failure, assertThrows(org.springframework.dao.DataAccessResourceFailureException.class, () ->
                new NoticePermissionCandidateQuery(unavailable)
                        .possibleUsers(Set.of("procurement_iqc_rejection:confirm_credit"))));
    }

    @Test
    void thousandsOfUnrelatedUsersDoNotEnterFinalPermissionResolution() {
        for (int index = 0; index < 1000; index++) user(false);
        UUID administrator = user(true), grant = user(false);
        jdbc.update("INSERT INTO user_permission_overrides VALUES (?,?,true,'grant')", grant, action);
        assertEquals(Set.of(administrator, grant), candidates());
    }

    private Set<UUID> candidates() {
        return query.possibleUsers(Set.of("procurement_iqc_rejection:confirm_credit")).orElseThrow();
    }

    private UUID user(boolean admin) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO employees VALUES (?,null)", id);
        jdbc.update("INSERT INTO users VALUES (?,?,?,false,'active')", id, id, admin);
        return id;
    }
}
