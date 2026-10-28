package com.uten.imp.migration;

import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.clientupdates.ClientReleaseService;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.department.staffpermission.PagePermissionDelegationFeatureGate;
import com.uten.imp.features.org.department.staffpermission.PermissionSurfaceCatalogRepository;
import com.uten.imp.features.org.department.staffpermission.PermissionSurfaceRegistry;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.org.employee.EmployeeSecondaryDepartmentRepository;
import com.uten.imp.features.rbac.DepartmentPermissionRepository;
import com.uten.imp.features.rbac.GrantPolicy;
import com.uten.imp.features.rbac.ManagerPermissionDelegationRepository;
import com.uten.imp.features.rbac.PermissionGrantPolicyCatalog;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.features.rbac.UserPermissionOverrideRepository;
import com.uten.imp.security.PermissionDelegationPolicy;
import com.uten.imp.support.MigratedSchemaBaseline;
import java.sql.Connection;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ClientReleasePermissionMigrationPostgresTest {
    private static final String CODE = ClientReleaseService.PUBLISH_PERMISSION;

    @Test
    void newCapabilityIsClosedByDefaultAndOnlyConfirmedIndividualGrantCanEnableOrdinaryEmployee() throws Exception {
        try (var database = MigratedSchemaBaseline.openDatabase("client_release_permission")) {
            var jdbc = new JdbcTemplate(new DriverManagerDataSource(database.getJdbcUrl(), database.getUsername(), database.getPassword()));
            var catalog = new PermissionGrantPolicyCatalog(jdbc);
            var policy = catalog.policyOf(CODE).orElseThrow();
            assertThat(policy).containsExactly(GrantPolicy.INDIVIDUAL_ONLY);
            assertThat(GrantPolicy.individuallyGrantable(policy)).isTrue();
            assertThat(GrantPolicy.departmentGrantable(policy)).isFalse();
            assertThat(GrantPolicy.bulkEligible(policy)).isFalse();
            assertThat(GrantPolicy.baselineEligible(policy)).isFalse();
            assertThat(new PermissionDelegationPolicy(catalog).isDelegable(CODE)).isFalse();
            assertThat(jdbc.queryForObject("SELECT name FROM permissions WHERE code=?", String.class, CODE)).isEqualTo("发布客户端版本");
            assertThat(jdbc.queryForObject("SELECT action_type FROM permissions WHERE code=?", String.class, CODE)).isEqualTo("EXECUTE");
            assertThat(jdbc.queryForObject("SELECT high_risk AND explicit_grant_required AND NOT baseline AND NOT baseline_pinned FROM permissions WHERE code=?",
                    Boolean.class, CODE)).isTrue();
            var registry = new PermissionSurfaceRegistry(new PermissionSurfaceCatalogRepository(jdbc));
            assertThat(registry.permissionsFor("admin.client-releases")).containsExactly(CODE);
            assertThat(jdbc.queryForObject("""
                    SELECT count(*) FROM (
                      SELECT permission_id FROM department_permissions
                      UNION ALL SELECT permission_id FROM user_permission_overrides
                      UNION ALL SELECT permission_id FROM manager_permission_delegations
                    ) allocation JOIN permissions permission ON permission.id=allocation.permission_id
                    WHERE permission.code=?
                    """, Long.class, CODE)).isZero();

            UUID department = jdbc.queryForObject("SELECT id FROM departments WHERE code='DEPT_FIN'", UUID.class);
            UUID target = account(jdbc, department, false), admin = account(jdbc, department, true);
            var resolver = resolver(jdbc, catalog, registry);
            assertThat(resolver.grantedPermissionsFor(List.of(target), Set.of(CODE))).doesNotContainKey(target);
            var administrator = new UserAccount();
            administrator.setSuperAdmin(true);
            assertThat(resolver.permsOf(administrator)).contains(CODE);

            assertThatThrownBy(() -> jdbc.update("""
                    INSERT INTO user_permission_overrides(user_id,permission_id,effect,authority_source)
                    SELECT ?,id,'grant','SUPER_ADMIN_CONFIRMED' FROM permissions WHERE code=?
                    """, target, CODE)).isInstanceOf(DataAccessException.class).hasMessageContaining("automatically granted");

            try (Connection connection = database.openConnection()) {
                var actorJdbc = new JdbcTemplate(new SingleConnectionDataSource(connection, true));
                actorJdbc.queryForObject("SELECT set_config('app.actor_id',?,false)", String.class, admin.toString());
                assertThatThrownBy(() -> actorJdbc.update("""
                        INSERT INTO department_permissions(department_id,permission_id)
                        SELECT ?,id FROM permissions WHERE code=?
                        """, department, CODE)).isInstanceOf(DataAccessException.class).hasMessageContaining("不能配置给整个部门");
                assertThatThrownBy(() -> actorJdbc.update("""
                        INSERT INTO manager_permission_delegations(user_id,department_id,permission_id,granted_by_user_id,
                            surface_key,scope_source,target_user_generation,target_employee_generation,target_department_generation,
                            grantor_user_generation,grantor_auth_version,grantor_authorization_epoch)
                        SELECT target.id,employee.department_id,permission.id,grantor.id,'admin.client-releases','SUPER_ADMIN',
                            target.permission_delegation_generation,employee.permission_delegation_generation,department.permission_delegation_generation,
                            grantor.permission_delegation_generation,grantor.auth_version,auth.epoch
                        FROM users target JOIN employees employee ON employee.id=target.employee_id
                        JOIN departments department ON department.id=employee.department_id
                        CROSS JOIN users grantor CROSS JOIN authorization_state auth CROSS JOIN permissions permission
                        WHERE target.id=? AND grantor.id=? AND auth.singleton_id=1 AND permission.code=?
                        """, target, admin, CODE)).isInstanceOf(DataAccessException.class).hasMessageContaining("不能由负责人转授");
                assertThatThrownBy(() -> actorJdbc.update("UPDATE permissions SET baseline=true WHERE code=?", CODE))
                        .isInstanceOf(DataAccessException.class).hasMessageContaining("permissions_baseline_policy_chk");
                actorJdbc.update("""
                        INSERT INTO user_permission_overrides(user_id,permission_id,effect,authority_source)
                        SELECT ?,id,'grant','SUPER_ADMIN_CONFIRMED' FROM permissions WHERE code=?
                        """, target, CODE);
                assertThat(resolver.grantedPermissionsFor(List.of(target), Set.of(CODE)).get(target)).containsExactly(CODE);
                actorJdbc.update("""
                        UPDATE user_permission_overrides SET effect='revoke'
                        WHERE user_id=? AND permission_id=(SELECT id FROM permissions WHERE code=?)
                        """, target, CODE);
                assertThat(resolver.grantedPermissionsFor(List.of(target), Set.of(CODE))).doesNotContainKey(target);
            }
        }
    }

    private static UUID account(JdbcTemplate jdbc, UUID department, boolean superAdmin) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES(?,?,?,'其他',?,CURRENT_DATE,'active','regular')
                """, id, "RELEASE-" + id,com.uten.imp.support.SyntheticEmployeeIdentity.name("Client release fixture",id), department);
        jdbc.update("""
                INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status,is_super_admin)
                VALUES(?,?,?,'fixture-only',false,'active',?)
                """, id, id, "release-fixture-" + id, superAdmin);
        return id;
    }

    private static PermissionResolver resolver(JdbcTemplate jdbc, PermissionGrantPolicyCatalog catalog, PermissionSurfaceRegistry registry) {
        var permissions = mock(PermissionRepository.class);
        when(permissions.findAllCodes()).thenAnswer(invocation -> jdbc.queryForList("SELECT code FROM permissions", String.class));
        return new PermissionResolver(permissions, mock(DepartmentPermissionRepository.class),
                mock(UserPermissionOverrideRepository.class), mock(EmployeeRepository.class), mock(EmployeeSecondaryDepartmentRepository.class),
                mock(UserAccountRepository.class), mock(DepartmentRepository.class), mock(ManagerPermissionDelegationRepository.class),
                new PermissionDelegationPolicy(catalog), registry, new PagePermissionDelegationFeatureGate(true), jdbc);
    }
}
