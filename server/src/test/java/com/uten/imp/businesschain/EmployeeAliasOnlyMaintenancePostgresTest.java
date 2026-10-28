package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.org.employee.EmployeeIdentityDirectory;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.test.context.TestPropertySource;

import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Executes the exact maintenance SQL on real current-schema PostgreSQL; no company access. */
@TestPropertySource(properties = "uten.test.alias-only-maintenance=isolated")
class EmployeeAliasOnlyMaintenancePostgresTest extends AuthSessionPostgresTestSupport {
    @Autowired javax.sql.DataSource dataSource;
    @Autowired PermissionResolver permissions;
    @Autowired EmployeeIdentityDirectory identities;
    private final ObjectMapper mapper = new ObjectMapper();

    private record Fixture(Employee account, UUID canonical, UUID user, UUID alias, ObjectNode plan) { }

    private Fixture fixture() throws Exception {
        Employee account = newEmployee(adminToken(), "DEPT_ENG");
        UUID canonical = UUID.fromString(account.employeeId()), user = UUID.fromString(account.userId());
        UUID alias = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type,is_deleted)
                SELECT ?,?,?,'其他',department_id,CURRENT_DATE,'active','regular',true
                FROM employees WHERE id=?
                """, alias, "ALIAS-" + alias,com.uten.imp.support.SyntheticEmployeeIdentity.name("Synthetic historical alias",alias), canonical);
        String databaseIdentity = jdbc.queryForObject("""
                SELECT jsonb_build_object('database',current_database(),
                  'system_identifier',(SELECT system_identifier::text FROM pg_control_system()),
                  'database_oid',(SELECT oid::bigint FROM pg_database WHERE datname=current_database()),
                  'dataset_id',(SELECT business_dataset_id::text FROM authorization_state WHERE singleton_id=1),
                  'generation',(SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1),
                  'migration_max',(SELECT max(version::int) FROM flyway_schema_history WHERE success),
                  'migration_sha256',(SELECT encode(digest(COALESCE(jsonb_agg(jsonb_build_array(version,checksum)
                     ORDER BY installed_rank)::text,'[]'),'sha256'),'hex') FROM flyway_schema_history WHERE success))::text
                """, String.class);
        ObjectNode plan = mapper.createObjectNode();
        plan.put("protocol", "verified-employee-alias-only-v1");
        plan.put("captured_at", OffsetDateTime.now().toString());
        plan.set("database_identity", mapper.readTree(databaseIdentity));
        plan.set("canonical", mapper.valueToTree(Map.of("employee_id", canonical.toString(),
                "code", jdbc.queryForObject("SELECT code FROM employees WHERE id=?", String.class, canonical),
                "version", jdbc.queryForObject("SELECT version FROM employees WHERE id=?", Long.class, canonical))));
        plan.set("retained_user", mapper.valueToTree(Map.of("user_id", user.toString(),
                "version", jdbc.queryForObject("SELECT version FROM users WHERE id=?", Long.class, user),
                "auth_version", jdbc.queryForObject("SELECT auth_version FROM users WHERE id=?", Long.class, user))));
        plan.putArray("aliases").addObject().put("employee_id", alias.toString())
                .put("code", "ALIAS-" + alias).put("version", 0)
                .put("reason", "Synthetic verified identity; retain raw historical ownership");
        plan.putObject("backup").put("reference", "synthetic-paired-backup-receipt")
                .put("manifest_sha256", "a".repeat(64)).put("verified", true);
        plan.put("evidence_reference", "synthetic-alias-proof-" + alias);
        plan.put("maintenance_actor", "ops:alias-only-fixture");
        return new Fixture(account, canonical, user, alias, plan);
    }

    private JsonNode apply(ObjectNode plan, boolean commit) throws Exception {
        try (Connection connection = dataSource.getConnection()) {
            connection.setTransactionIsolation(Connection.TRANSACTION_REPEATABLE_READ);
            connection.setAutoCommit(false);
            try {
                try (var statement = connection.createStatement()) {
                    statement.execute(Files.readString(Path.of("maintenance/verified_employee_alias_only.sql")));
                }
                JsonNode receipt;
                try (var statement = connection.prepareStatement("SELECT pg_temp.apply_verified_employee_alias_only(?::jsonb)::text")) {
                    statement.setString(1, mapper.writeValueAsString(plan));
                    try (var rows = statement.executeQuery()) {
                        assertTrue(rows.next()); receipt = mapper.readTree(rows.getString(1));
                    }
                }
                if (commit) connection.commit(); else connection.rollback();
                return receipt;
            } catch (Exception failure) {
                connection.rollback(); throw failure;
            }
        }
    }

    @Test void aliasOnlyPreservesRestoredAccountEffectiveGrantsMessagesAndRawHistoryAndIsIdempotent() throws Exception {
        Fixture fixture = fixture();
        UUID notice = UUID.randomUUID(), event = UUID.randomUUID();
        jdbc.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'grant' FROM permissions WHERE code='goods:view'", fixture.user());
        jdbc.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'revoke' FROM permissions WHERE code='notice:read'", fixture.user());
        jdbc.update("INSERT INTO notices(id,title,content,type,publisher,created_by) VALUES(?,'Preserved notice','Preserved body','system','Synthetic fixture',?)", notice, fixture.user());
        jdbc.update("INSERT INTO notice_user_states(notice_id,user_id,read_at) VALUES(?,?,now())", notice, fixture.user());
        jdbc.update("INSERT INTO employment_history(id,employee_id,event_type,event_date) VALUES(?,?,'onboard',DATE '2010-01-01')", event, fixture.alias());
        jdbc.update("""
                INSERT INTO audit_log(actor_id,actor_account,action,target_type,target_id,event_source,result,risk_level,event_category)
                VALUES(?,'synthetic-retained-actor','alias_preservation_fixture','employees',?,'business','success','low','business')
                """, fixture.user(), fixture.alias().toString());
        // Grant changes legitimately advanced the account's generation. Refresh the
        // reviewed metadata, never force production facts back to an old count/version.
        ((ObjectNode) fixture.plan().get("retained_user")).put("version", jdbc.queryForObject("SELECT version FROM users WHERE id=?", Long.class, fixture.user()))
                .put("auth_version", jdbc.queryForObject("SELECT auth_version FROM users WHERE id=?", Long.class, fixture.user()));
        String before = jdbc.queryForObject("SELECT to_jsonb(u)::text FROM users u WHERE id=?", String.class, fixture.user());
        Set<String> effective = permissions.authorizationSnapshot(fixture.user(), fixture.canonical(), false).permissions();
        assertTrue(effective.contains("goods:view")); assertFalse(effective.contains("notice:read"));
        long epoch = jdbc.queryForObject("SELECT epoch FROM authorization_state WHERE singleton_id=1", Long.class);
        JsonNode receipt = apply(fixture.plan(), true);
        assertEquals(1, receipt.path("inserted_aliases").asInt());
        assertEquals(0, receipt.path("account_or_credential_writes").asInt());
        // These reads use new pooled connections after COMMIT, independently of
        // the maintenance connection's repeatable-read snapshot.
        assertTrue(before.equals(jdbc.queryForObject("SELECT to_jsonb(u)::text FROM users u WHERE id=?", String.class, fixture.user())), "Original account and credential row changed");
        assertEquals(effective, permissions.authorizationSnapshot(fixture.user(), fixture.canonical(), false).permissions());
        assertEquals(Set.of(fixture.canonical(), fixture.alias()), Set.copyOf(identities.employeeIdentityMembers(fixture.canonical())));
        assertEquals(fixture.alias(), jdbc.queryForObject("SELECT employee_id FROM employment_history WHERE id=?", UUID.class, event));
        assertTrue(jdbc.queryForObject("SELECT read_at IS NOT NULL AND deleted_at IS NULL FROM notice_user_states WHERE notice_id=? AND user_id=?", Boolean.class, notice, fixture.user()));
        assertEquals("Preserved body", jdbc.queryForObject("SELECT content FROM notices WHERE id=?", String.class, notice));
        assertEquals(1L, jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE actor_id=? AND action='alias_preservation_fixture' AND target_id=?", Long.class, fixture.user(), fixture.alias().toString()));
        assertEquals(epoch + 1, jdbc.queryForObject("SELECT epoch FROM authorization_state WHERE singleton_id=1", Long.class));
        JsonNode duplicate = apply(fixture.plan(), true);
        assertEquals(0, duplicate.path("inserted_aliases").asInt());
        assertEquals(1, duplicate.path("already_present").asInt());
        assertEquals(epoch + 1, jdbc.queryForObject("SELECT epoch FROM authorization_state WHERE singleton_id=1", Long.class));
        login(fixture.account().loginAccount(), EMPLOYEE_PASSWORD);
    }

    @ParameterizedTest
    @ValueSource(strings = {"database", "dataset", "migration", "user-version", "employee-version", "unverified-backup", "expired-plan", "missing-time", "active-alias", "wrong-binding", "empty-credential", "temporary-deadline"})
    void driftedOrMissingReviewedPreconditionsRejectWithoutAnyAliasOrAccountMutation(String drift) throws Exception {
        Fixture fixture = fixture();
        switch (drift) {
            case "database" -> ((ObjectNode) fixture.plan().get("database_identity")).put("database_oid", 1);
            case "dataset" -> ((ObjectNode) fixture.plan().get("database_identity")).put("dataset_id", UUID.randomUUID().toString());
            case "migration" -> ((ObjectNode) fixture.plan().get("database_identity")).put("migration_sha256", "b".repeat(64));
            case "user-version" -> ((ObjectNode) fixture.plan().get("retained_user")).put("auth_version", -1);
            case "employee-version" -> ((ObjectNode) fixture.plan().get("canonical")).put("version", -1);
            case "unverified-backup" -> ((ObjectNode) fixture.plan().get("backup")).put("verified", false);
            case "expired-plan" -> fixture.plan().put("captured_at", OffsetDateTime.now().minusDays(2).toString());
            case "missing-time" -> fixture.plan().remove("captured_at");
            case "active-alias" -> jdbc.update("UPDATE employees SET is_deleted=false WHERE id=?", fixture.alias());
            case "wrong-binding" -> ((ObjectNode) fixture.plan().get("retained_user")).put("user_id", UUID.randomUUID().toString());
            case "empty-credential", "temporary-deadline" -> {
                if (drift.equals("empty-credential")) jdbc.update("UPDATE users SET password_hash='' WHERE id=?", fixture.user());
                else jdbc.update("UPDATE users SET temp_password_expires_at=now()-interval '1 hour' WHERE id=?", fixture.user());
                ((ObjectNode) fixture.plan().get("retained_user")).put("version", jdbc.queryForObject("SELECT version FROM users WHERE id=?", Long.class, fixture.user()))
                        .put("auth_version", jdbc.queryForObject("SELECT auth_version FROM users WHERE id=?", Long.class, fixture.user()));
            }
            default -> throw new AssertionError(drift);
        }
        String before = jdbc.queryForObject("SELECT to_jsonb(u)::text FROM users u WHERE id=?", String.class, fixture.user());
        assertThrows(SQLException.class, () -> apply(fixture.plan(), true));
        assertEquals(0L, jdbc.queryForObject("SELECT count(*) FROM employee_identity_aliases WHERE alias_employee_id=?", Long.class, fixture.alias()));
        assertTrue(before.equals(jdbc.queryForObject("SELECT to_jsonb(u)::text FROM users u WHERE id=?", String.class, fixture.user())), "Rejected plan changed original account");
    }

    @Test void rehearsalRollsBackAndDifferentEvidenceCannotTakeOverAnExistingAlias() throws Exception {
        Fixture fixture = fixture();
        long epoch = jdbc.queryForObject("SELECT epoch FROM authorization_state WHERE singleton_id=1", Long.class);
        assertEquals(1, apply(fixture.plan(), false).path("inserted_aliases").asInt());
        assertEquals(0L, jdbc.queryForObject("SELECT count(*) FROM employee_identity_aliases WHERE alias_employee_id=?", Long.class, fixture.alias()));
        assertEquals(epoch, jdbc.queryForObject("SELECT epoch FROM authorization_state WHERE singleton_id=1", Long.class));
        apply(fixture.plan(), true);
        fixture.plan().put("evidence_reference", "different-proof");
        assertThrows(SQLException.class, () -> apply(fixture.plan(), true));
        assertEquals(fixture.canonical(), identities.canonicalEmployeeId(fixture.alias()));
    }
}
