package com.uten.imp.migration;

import com.uten.imp.features.admin.serveroperations.ServerOperationsActorAuthority;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.department.staffpermission.*;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.org.employee.EmployeeSecondaryDepartmentRepository;
import com.uten.imp.features.rbac.*;
import com.uten.imp.security.PermissionDelegationPolicy;
import com.uten.imp.support.MigratedSchemaBaseline;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.mock;

/** Actual V866 catalog, existing database guards and fresh runtime authority; no mocked schema. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ServerOperationsPermissionMigrationPostgresTest {
    private static final Set<String> CODES=Set.of("server:update","server:cleanup");
    private MigratedSchemaBaseline.ScopedDatabase database;
    private JdbcTemplate jdbc;
    private UUID department;
    @BeforeEach void open() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("server_operations_permissions");
        jdbc=new JdbcTemplate(new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword()));
        department=jdbc.queryForObject("SELECT id FROM departments WHERE code='DEPT_FIN'",UUID.class);
    }
    @AfterEach void close() throws Exception { if(database!=null)database.close(); }

    @Test void migratedCatalogHasOnlyExplicitPersonalCapabilitiesAndExactRuntimeSurface() {
        var catalog=new PermissionGrantPolicyCatalog(jdbc);
        var delegation=new PermissionDelegationPolicy(catalog);
        var registry=new PermissionSurfaceRegistry(new PermissionSurfaceCatalogRepository(jdbc));
        assertThat(registry.permissionsFor("admin.server-operations")).containsExactlyInAnyOrderElementsOf(CODES);
        assertThat(jdbc.queryForObject("SELECT id FROM permission_surfaces WHERE surface_key='admin.server-operations'",UUID.class))
                .isEqualTo(UUID.fromString("beed11ef-3158-4735-a05c-bca84c63bb74"));
        assertThat(jdbc.queryForObject("SELECT action_type FROM permissions WHERE code='server:update'",String.class)).isEqualTo("EXECUTE");
        assertThat(jdbc.queryForObject("SELECT action_type FROM permissions WHERE code='server:cleanup'",String.class)).isEqualTo("DELETE");
        for(String code:CODES) {
            var policy=catalog.policyOf(code).orElseThrow();
            assertThat(policy).containsExactly(GrantPolicy.INDIVIDUAL_ONLY);
            assertThat(GrantPolicy.individuallyGrantable(policy)).isTrue();
            assertThat(GrantPolicy.departmentGrantable(policy)).isFalse();
            assertThat(GrantPolicy.bulkEligible(policy)).isFalse();
            assertThat(delegation.isDelegable(code)).isFalse();
            assertThat(jdbc.queryForObject("SELECT high_risk AND NOT baseline FROM permissions WHERE code=?",Boolean.class,code)).isTrue();
        }
        assertThat(jdbc.queryForObject("""
                SELECT count(*) FROM department_permissions allocation JOIN permissions permission ON permission.id=allocation.permission_id
                WHERE permission.code IN ('server:update','server:cleanup')
                """,Long.class)).isZero();
        assertThat(jdbc.queryForObject("""
                SELECT count(*) FROM user_permission_overrides allocation JOIN permissions permission ON permission.id=allocation.permission_id
                WHERE permission.code IN ('server:update','server:cleanup')
                """,Long.class)).isZero();
    }

    @Test void databaseRejectsDepartmentDelegationAndBaselineGrantForBothCapabilities() {
        UUID target=account(false),admin=account(true);
        for(String code:CODES) {
            assertThatThrownBy(()->jdbc.update("""
                    INSERT INTO department_permissions(department_id,permission_id)
                    SELECT ?,id FROM permissions WHERE code=?
                    """,department,code)).isInstanceOfSatisfying(DataAccessException.class,
                    failure->assertThat(failure.getMostSpecificCause().getMessage()).contains("不能配置给整个部门"));
            assertThatThrownBy(()->jdbc.update("""
                    INSERT INTO manager_permission_delegations(user_id,department_id,permission_id,granted_by_user_id,
                        surface_key,scope_source,target_user_generation,target_employee_generation,target_department_generation,
                        grantor_user_generation,grantor_auth_version,grantor_authorization_epoch)
                    SELECT target.id,employee.department_id,permission.id,grantor.id,'admin.server-operations','SUPER_ADMIN',
                        target.permission_delegation_generation,employee.permission_delegation_generation,department.permission_delegation_generation,
                        grantor.permission_delegation_generation,grantor.auth_version,auth.epoch
                    FROM users target JOIN employees employee ON employee.id=target.employee_id
                    JOIN departments department ON department.id=employee.department_id
                    CROSS JOIN users grantor CROSS JOIN authorization_state auth CROSS JOIN permissions permission
                    WHERE target.id=? AND grantor.id=? AND auth.singleton_id=1 AND permission.code=?
                    """,target,admin,code)).isInstanceOfSatisfying(DataAccessException.class,
                    failure->assertThat(failure.getMostSpecificCause().getMessage()).contains("不能由负责人转授"));
            assertThatThrownBy(()->jdbc.update("UPDATE permissions SET baseline=true WHERE code=?",code))
                    .isInstanceOfSatisfying(DataAccessException.class,
                            failure->assertThat(failure.getMostSpecificCause().getMessage()).contains("permissions_baseline_policy_chk"));
        }
    }

    @Test void confirmedIndividualGrantAndRevocationAreReadFromRealAuthorityWithoutGivingCleanupTheUpdateCapability() {
        UUID target=account(false),legacy=account(false),admin=account(true);
        var authority=new ServerOperationsActorAuthority(jdbc);
        var resolver=resolver();
        assertThat(authority.mayUpdate(target)).isFalse();assertThat(authority.mayUpdate(admin)).isTrue();
        assertThat(resolver.grantedPermissionsFor(List.of(target),CODES)).doesNotContainKey(target);
        grant(legacy,"server:update","LEGACY_UNKNOWN");
        assertThat(authority.mayUpdate(legacy)).isFalse();
        grant(target,"server:cleanup","SUPER_ADMIN_CONFIRMED");
        assertThat(authority.mayUpdate(target)).isFalse();
        assertThat(resolver.grantedPermissionsFor(List.of(target),CODES).get(target)).containsExactly("server:cleanup");
        grant(target,"server:update","SUPER_ADMIN_CONFIRMED");
        assertThat(authority.mayUpdate(target)).isTrue();
        assertThat(authority.currentUpdaters()).contains(target,admin).doesNotContain(legacy);
        assertThat(resolver.grantedPermissionsFor(List.of(target),CODES).get(target)).containsExactlyInAnyOrderElementsOf(CODES);
        jdbc.update("UPDATE user_permission_overrides SET effect='revoke' WHERE user_id=? AND permission_id=(SELECT id FROM permissions WHERE code='server:update')",target);
        assertThat(authority.mayUpdate(target)).isFalse();
        assertThat(resolver.grantedPermissionsFor(List.of(target),CODES).get(target)).containsExactly("server:cleanup");
        jdbc.update("UPDATE users SET is_super_admin=false WHERE id=?",admin);
        assertThat(authority.mayUpdate(admin)).isFalse();
    }

    @Test void exactV864UpgradeAppliesOnlyThreeForwardMigrationsWithoutReplacingSettingsOrExistingGrants() {
        try(var upgrade=new PostgreSQLContainer("postgres:16-alpine")) {
            upgrade.start();
            var source=new DriverManagerDataSource(upgrade.getJdbcUrl(),upgrade.getUsername(),upgrade.getPassword());
            Flyway.configure().dataSource(source).locations("classpath:db/migration").target("864").load().migrate();
            var current=new JdbcTemplate(source);
            assertThat(current.queryForObject("SELECT count(*) FROM flyway_schema_history WHERE success",Long.class)).isEqualTo(790);
            current.update("UPDATE system_settings SET value='17' WHERE key='sms_code_ttl_minutes'");
            String existingGrants=current.queryForObject("""
                    SELECT string_agg(row_to_json(grants)::text,'|' ORDER BY department_id,permission_id)
                    FROM department_permissions grants
                    """,String.class);
            assertThat(existingGrants).isNotBlank();
            String existingHistory=current.queryForObject("""
                    SELECT string_agg(version||':'||checksum::text,'|' ORDER BY installed_rank)
                    FROM flyway_schema_history WHERE success
                    """,String.class);
            var result=Flyway.configure().dataSource(source).locations("classpath:db/migration").target("867").load().migrate();
            assertThat(result.migrationsExecuted).isEqualTo(3);
            assertThat(current.queryForObject("SELECT count(*) FROM flyway_schema_history WHERE success",Long.class)).isEqualTo(793);
            assertThat(current.queryForObject("SELECT count(*) FROM flyway_schema_history WHERE NOT success",Long.class)).isZero();
            assertThat(current.queryForObject("SELECT value FROM system_settings WHERE key='sms_code_ttl_minutes'",String.class)).isEqualTo("17");
            assertThat(current.queryForObject("""
                    SELECT string_agg(row_to_json(grants)::text,'|' ORDER BY department_id,permission_id)
                    FROM department_permissions grants
                    """,String.class)).isEqualTo(existingGrants);
            assertThat(current.queryForObject("""
                    SELECT string_agg(version||':'||checksum::text,'|' ORDER BY installed_rank)
                    FROM flyway_schema_history WHERE success AND version::int<=864
                    """,String.class)).isEqualTo(existingHistory);
            assertThat(current.queryForObject("""
                    SELECT mode='ENV' AND version=0 AND access_key_id_cipher IS NULL AND access_key_secret_cipher IS NULL
                    FROM sms_gateway_settings
                    """,Boolean.class)).isTrue();
        }
    }

    @Test void exactV864UpgradeAppliesFourForwardMigrationsIncludingSharedKitAuthorityWithoutChangingPriorHistory() {
        try(var upgrade=new PostgreSQLContainer("postgres:16-alpine")) {
            upgrade.start();
            var source=new DriverManagerDataSource(upgrade.getJdbcUrl(),upgrade.getUsername(),upgrade.getPassword());
            Flyway.configure().dataSource(source).locations("classpath:db/migration").target("864").load().migrate();
            var current=new JdbcTemplate(source);
            assertThat(current.queryForObject("SELECT count(*) FROM flyway_schema_history WHERE success",Long.class)).isEqualTo(790);
            current.update("UPDATE system_settings SET value='17' WHERE key='sms_code_ttl_minutes'");
            String existingGrants=current.queryForObject("""
                    SELECT string_agg(row_to_json(grants)::text,'|' ORDER BY department_id,permission_id)
                    FROM department_permissions grants
                    """,String.class);
            assertThat(existingGrants).isNotBlank();
            String existingHistory=current.queryForObject("""
                    SELECT string_agg(version||':'||checksum::text,'|' ORDER BY installed_rank)
                    FROM flyway_schema_history WHERE success
                    """,String.class);
            var result=Flyway.configure().dataSource(source).locations("classpath:db/migration").target("868").load().migrate();
            assertThat(result.migrationsExecuted).isEqualTo(4);
            assertThat(current.queryForObject("SELECT count(*) FROM flyway_schema_history WHERE success",Long.class)).isEqualTo(794);
            assertThat(current.queryForObject("SELECT count(*) FROM flyway_schema_history WHERE NOT success",Long.class)).isZero();
            assertThat(current.queryForObject("SELECT to_regprocedure('fn_subcontract_application_orderable_batch(uuid[])') IS NOT NULL",Boolean.class)).isTrue();
            assertThat(current.queryForObject("SELECT count(*) FROM fn_subcontract_application_orderable_batch(ARRAY[]::uuid[])",Long.class)).isZero();
            assertThat(current.queryForObject("SELECT fn_subcontract_application_orderable_qty(gen_random_uuid())",java.math.BigDecimal.class)).isZero();
            assertThat(current.queryForObject("SELECT value FROM system_settings WHERE key='sms_code_ttl_minutes'",String.class)).isEqualTo("17");
            assertThat(current.queryForObject("""
                    SELECT string_agg(row_to_json(grants)::text,'|' ORDER BY department_id,permission_id)
                    FROM department_permissions grants
                    """,String.class)).isEqualTo(existingGrants);
            assertThat(current.queryForObject("""
                    SELECT string_agg(version||':'||checksum::text,'|' ORDER BY installed_rank)
                    FROM flyway_schema_history WHERE success AND version::int<=864
                    """,String.class)).isEqualTo(existingHistory);
            assertThat(current.queryForObject("""
                    SELECT mode='ENV' AND version=0 AND access_key_id_cipher IS NULL AND access_key_secret_cipher IS NULL
                    FROM sms_gateway_settings
                    """,Boolean.class)).isTrue();
        }
    }

    private UUID account(boolean superAdmin) {
        UUID id=UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES(?,?,'Operations fixture','其他',?,CURRENT_DATE,'active','regular')
                """,id,"OPS-"+id,department);
        jdbc.update("""
                INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status,is_super_admin)
                VALUES(?,?,?,'fixture-only',false,'active',?)
                """,id,id,"ops-fixture-"+id,superAdmin);
        return id;
    }
    private void grant(UUID user,String code,String source) {
        jdbc.update("""
                INSERT INTO user_permission_overrides(user_id,permission_id,effect,authority_source)
                SELECT ?,id,'grant',? FROM permissions WHERE code=?
                """,user,source,code);
    }
    private PermissionResolver resolver() {
        return new PermissionResolver(mock(PermissionRepository.class),mock(DepartmentPermissionRepository.class),
                mock(UserPermissionOverrideRepository.class),mock(EmployeeRepository.class),mock(EmployeeSecondaryDepartmentRepository.class),
                mock(UserAccountRepository.class),mock(DepartmentRepository.class),mock(ManagerPermissionDelegationRepository.class),
                new PermissionDelegationPolicy(new PermissionGrantPolicyCatalog(jdbc)),
                new PermissionSurfaceRegistry(new PermissionSurfaceCatalogRepository(jdbc)),new PagePermissionDelegationFeatureGate(true),jdbc);
    }
}
