package com.uten.imp.migration;

import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.department.staffpermission.PagePermissionDelegationFeatureGate;
import com.uten.imp.features.org.department.staffpermission.PermissionSurfaceCatalogRepository;
import com.uten.imp.features.org.department.staffpermission.PermissionSurfaceRegistry;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.org.employee.EmployeeSecondaryDepartmentRepository;
import com.uten.imp.features.rbac.DepartmentPermissionRepository;
import com.uten.imp.features.rbac.ManagerPermissionDelegationRepository;
import com.uten.imp.features.rbac.Permission;
import com.uten.imp.features.rbac.PermissionGrantPolicyCatalog;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.features.rbac.UserPermissionOverrideRepository;
import com.uten.imp.security.PermissionDelegationPolicy;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Real pre-upgrade grants and a currently valid department-manager delegation must survive regrouping. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PermissionCatalogSharedToolsMigrationPostgresTest {
    @Test
    void regroupingPreservesConfiguredAndEffectivePermissionsWhileAuthorityChangesStillInvalidate() throws Exception {
        try (var database = new PostgreSQLContainer("postgres:16-alpine")) {
            database.start();
            var source = new DriverManagerDataSource(database.getJdbcUrl(), database.getUsername(), database.getPassword());
            com.uten.imp.testsupport.TestFlyway.configure().dataSource(source).target("874").load().migrate();
            var jdbc = new JdbcTemplate(source);
            UUID department = jdbc.queryForObject("SELECT id FROM departments WHERE code='DEPT_FIN'", UUID.class);
            UUID manager = account(jdbc, department, "manager");
            UUID target = account(jdbc, department, "target");
            jdbc.update("UPDATE departments SET manager_id=? WHERE id=?", manager, department);
            // Make the delegated capability available only through the real manager grant.
            jdbc.update("DELETE FROM department_permissions WHERE permission_id=(SELECT id FROM permissions WHERE code='goods:view')");
            override(jdbc, manager, "goods:view", "grant");
            override(jdbc, target, "color:view", "grant");
            override(jdbc, target, "ai:use", "revoke");
            // A previously saved custom baseline must not be reset to the seed default by regrouping.
            jdbc.update("UPDATE permissions SET baseline=true WHERE code='ai:use'");
            jdbc.update("""
                    INSERT INTO manager_permission_delegations(
                        user_id,permission_id,department_id,enabled,surface_key,granted_by_user_id,
                        target_user_generation,target_employee_generation,target_department_generation,
                        grantor_user_generation,grantor_employee_generation,grantor_auth_version,
                        grantor_authorization_epoch,scope_source,scope_department_id,scope_generation)
                    SELECT target.id,permission.id,department.id,true,surface.surface_key,grantor.id,
                           target.permission_delegation_generation,employee.permission_delegation_generation,
                           department.permission_delegation_generation,grantor.permission_delegation_generation,
                           manager.permission_delegation_generation,grantor.auth_version,auth.epoch,
                           'DEPARTMENT_MANAGER',department.id,department.permission_delegation_generation
                    FROM users target JOIN employees employee ON employee.id=target.employee_id
                    JOIN departments department ON department.id=employee.department_id
                    CROSS JOIN users grantor JOIN employees manager ON manager.id=grantor.employee_id
                    CROSS JOIN permissions permission CROSS JOIN authorization_state auth
                    JOIN permission_surface_permissions link ON link.permission_id=permission.id
                    JOIN permission_surfaces surface ON surface.id=link.surface_id
                    WHERE target.id=? AND grantor.id=? AND permission.code='goods:view'
                      AND surface.surface_key='basic.goods' AND auth.singleton_id=1
                    """, target, manager);
            assertThat(jdbc.queryForObject("SELECT count(*) FROM manager_permission_delegations WHERE user_id=? AND enabled",
                    Long.class, target)).isEqualTo(1);
            var resolver = resolver(jdbc);
            var codes = new LinkedHashSet<>(jdbc.queryForList("SELECT code FROM permissions ORDER BY code", String.class));
            var beforeEffective = resolver.grantedPermissionsFor(List.of(target, manager), codes);
            assertThat(beforeEffective.get(target)).contains("goods:view", "color:view").doesNotContain("ai:use");
            assertThat(beforeEffective.get(manager)).contains("goods:view", "ai:use");
            String beforePermissions = permissionAuthority(jdbc);
            String beforeDepartment = rows(jdbc, "department_permissions");
            String beforeOverrides = rows(jdbc, "user_permission_overrides");
            String beforeDelegations = rows(jdbc, "manager_permission_delegations");
            long beforeEpoch = epoch(jdbc);

            var migrated = com.uten.imp.testsupport.TestFlyway.configure().dataSource(source).target("875").load().migrate();

            assertThat(migrated.migrationsExecuted).isEqualTo(1);
            assertThat(epoch(jdbc)).isEqualTo(beforeEpoch);
            assertThat(permissionAuthority(jdbc)).isEqualTo(beforePermissions);
            assertThat(rows(jdbc, "department_permissions")).isEqualTo(beforeDepartment);
            assertThat(rows(jdbc, "user_permission_overrides")).isEqualTo(beforeOverrides);
            assertThat(rows(jdbc, "manager_permission_delegations")).isEqualTo(beforeDelegations);
            assertThat(resolver(jdbc).grantedPermissionsFor(List.of(target, manager), codes)).isEqualTo(beforeEffective);
            assertThat(jdbc.queryForObject("SELECT module || '/' || category FROM permissions WHERE code='ai:use'", String.class))
                    .isEqualTo("通用/AI 助手");
            assertThat(jdbc.queryForObject("SELECT category FROM permissions WHERE code='sales_quote:export'", String.class))
                    .isEqualTo("销售报价");
            assertThat(jdbc.queryForObject("SELECT count(*) FROM permissions WHERE category='销售报价单'", Long.class)).isZero();
            assertThat(jdbc.queryForObject("SELECT count(*) FROM permissions WHERE module IS NULL OR category IS NULL OR module='其他'",
                    Long.class)).isZero();
            assertThat(jdbc.queryForList("SELECT DISTINCT module FROM permissions ORDER BY module", String.class))
                    .containsExactlyInAnyOrder("常用模块", "通用", "基础资料", "销售管理", "采购管理", "委外管理",
                            "生产管理", "仓库管理", "财税管理", "工程研发", "人事行政", "品质检测", "系统管理");
            // A reviewable inventory comes from the fully migrated catalog, never a second frontend mapping.
            Path inventory = Path.of(System.getProperty("uten.taxonomy.inventory", "target/permission-taxonomy.tsv"));
            Files.createDirectories(inventory.toAbsolutePath().getParent());
            Files.write(inventory, jdbc.queryForList("""
                    SELECT module || E'\t' || category || E'\t' || count(*) || E'\t' || string_agg(code,', ' ORDER BY code)
                    FROM permissions GROUP BY module,category ORDER BY module,min(sort_order),category
                    """, String.class));

            jdbc.update("UPDATE permissions SET module='通用',category='临时分类',sort_order=sort_order+1 WHERE code='ai:use'");
            assertThat(epoch(jdbc)).isEqualTo(beforeEpoch);
            assertThat(resolver(jdbc).grantedPermissionsFor(List.of(target, manager), codes)).isEqualTo(beforeEffective);
            jdbc.update("UPDATE permissions SET baseline=baseline WHERE code='ai:use'");
            assertThat(epoch(jdbc)).isEqualTo(beforeEpoch);
            // The same baseline change must still invalidate stale snapshots and manager delegations.
            jdbc.update("UPDATE permissions SET baseline=false WHERE code='ai:use'");
            assertThat(epoch(jdbc)).isEqualTo(++beforeEpoch);
            assertThat(resolver(jdbc).grantedPermissionsFor(List.of(target), codes).get(target)).doesNotContain("goods:view");
            jdbc.update("UPDATE permissions SET grant_policy=ARRAY['BULK_EXCLUDED']::text[] WHERE code='ai:use'");
            assertThat(epoch(jdbc)).isEqualTo(++beforeEpoch);
            jdbc.update("UPDATE permissions SET baseline_pinned=false WHERE code='notice:read'");
            assertThat(epoch(jdbc)).isEqualTo(++beforeEpoch);
            jdbc.update("UPDATE permissions SET high_risk=NOT high_risk WHERE code='ai:use'");
            assertThat(epoch(jdbc)).isEqualTo(++beforeEpoch);
            // A multi-row real change advances once per statement, preserving the original bounded fanout.
            jdbc.update("UPDATE permissions SET high_risk=NOT high_risk WHERE code IN ('ai:use','color:view')");
            assertThat(epoch(jdbc)).isEqualTo(++beforeEpoch);
            UUID fixture = UUID.randomUUID();
            jdbc.update("""
                    INSERT INTO permissions(id,code,name,module,category,action_type,description)
                    VALUES(?,'taxonomy:fixture','fixture','通用','测试','VIEW','fixture')
                    """, fixture);
            assertThat(epoch(jdbc)).isEqualTo(++beforeEpoch);
            jdbc.update("UPDATE permissions SET code='taxonomy:renamed' WHERE id=?", fixture);
            assertThat(epoch(jdbc)).isEqualTo(++beforeEpoch);
            UUID replacement = UUID.randomUUID();
            jdbc.update("UPDATE permissions SET id=? WHERE id=?", replacement, fixture);
            assertThat(epoch(jdbc)).isEqualTo(++beforeEpoch);
            jdbc.update("DELETE FROM permissions WHERE id=?", replacement);
            // Existing FK cascades can also run statement-level authorization triggers.
            assertThat(epoch(jdbc)).isGreaterThan(beforeEpoch);
        }
    }

    private static UUID account(JdbcTemplate jdbc, UUID department, String label) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES(?,?,?,'其他',?,CURRENT_DATE,'active','regular')
                """, id, "TAX-" + label, label, department);
        jdbc.update("""
                INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status,is_super_admin)
                VALUES(?,?,?,'fixture-only',false,'active',false)
                """, id, id, "taxonomy-" + label);
        return id;
    }

    private static void override(JdbcTemplate jdbc, UUID user, String code, String effect) {
        jdbc.update("""
                INSERT INTO user_permission_overrides(user_id,permission_id,effect,authority_source)
                SELECT ?,id,?,'SUPER_ADMIN_CONFIRMED' FROM permissions WHERE code=?
                """, user, effect, code);
    }

    private static long epoch(JdbcTemplate jdbc) {
        return jdbc.queryForObject("SELECT epoch FROM authorization_state WHERE singleton_id=1", Long.class);
    }

    private static String permissionAuthority(JdbcTemplate jdbc) {
        return jdbc.queryForObject("""
                SELECT jsonb_agg(to_jsonb(permission)-ARRAY['module','category','sort_order','updated_at','updated_by'] ORDER BY id)::text
                FROM permissions permission
                """, String.class);
    }

    private static String rows(JdbcTemplate jdbc, String table) {
        // Table names are fixed test-owned literals above.
        return jdbc.queryForObject("SELECT jsonb_agg(to_jsonb(entry) ORDER BY to_jsonb(entry)::text)::text FROM " + table + " entry", String.class);
    }

    private static PermissionResolver resolver(JdbcTemplate jdbc) {
        var catalog = mock(PermissionRepository.class);
        when(catalog.findAll()).thenReturn(jdbc.query("SELECT code,action_type FROM permissions", (rs, index) -> {
            var permission = new Permission();
            permission.setCode(rs.getString("code"));
            permission.setActionType(rs.getString("action_type"));
            return permission;
        }));
        var resolver = new PermissionResolver(catalog, mock(DepartmentPermissionRepository.class),
                mock(UserPermissionOverrideRepository.class), mock(EmployeeRepository.class), mock(EmployeeSecondaryDepartmentRepository.class),
                mock(UserAccountRepository.class), mock(DepartmentRepository.class), mock(ManagerPermissionDelegationRepository.class),
                new PermissionDelegationPolicy(new PermissionGrantPolicyCatalog(jdbc)),
                new PermissionSurfaceRegistry(new PermissionSurfaceCatalogRepository(jdbc)),
                new PagePermissionDelegationFeatureGate(true), jdbc);
        resolver.initializeDependencyCatalog();
        return resolver;
    }
}
