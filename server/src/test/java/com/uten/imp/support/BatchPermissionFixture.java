package com.uten.imp.support;

import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.department.staffpermission.PagePermissionDelegationFeatureGate;
import com.uten.imp.features.org.department.staffpermission.PermissionSurfaceRegistryTestFixture;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.org.employee.EmployeeSecondaryDepartmentRepository;
import com.uten.imp.features.rbac.*;
import com.uten.imp.security.PermissionDelegationPolicy;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.Map;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.mockito.Mockito.mock;

/** Real PostgreSQL authorization sources, deliberately without a Spring scheduler. */
public final class BatchPermissionFixture {
    public static final String VIEW = "sales_order_finance:view";
    public static final String CONFIRM = "sales_order_finance:confirm";
    public static final Set<String> REQUIRED = Set.of(VIEW, CONFIRM);
    public final JdbcTemplate jdbc;
    public final UUID company = UUID.randomUUID(), finance = UUID.randomUUID(), other = UUID.randomUUID();
    public final UUID view = UUID.randomUUID(), confirm = UUID.randomUUID();

    public BatchPermissionFixture(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
        jdbc.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public");
        MigratedProjectionSchema.createCurrentTables(jdbc,"permissions","departments","employees","users",
                "employee_secondary_departments","department_permissions","user_permission_overrides",
                "authorization_state","manager_permission_delegations","permission_templates",
                "user_permission_template_bindings","department_permission_template_bindings");
        MigratedProjectionSchema.createCurrentViews(jdbc,"authorization_user_template_permission_sources","authorization_department_permission_sources");
        jdbc.update("INSERT INTO authorization_state(singleton_id,epoch) VALUES (1,0)");
        jdbc.update("INSERT INTO permissions(id,code) VALUES (?,?),(?,?)", view, VIEW, confirm, CONFIRM);
        department(company, "COMPANY", "公司", null);
        department(finance, "DEPT_FIN", "一级部门", company);
        department(other, "OTHER", "一级部门", company);
    }

    public PermissionResolver resolver(boolean featureEnabled) {
        return new PermissionResolver(mock(PermissionRepository.class), mock(DepartmentPermissionRepository.class),
                mock(UserPermissionOverrideRepository.class), mock(EmployeeRepository.class),
                mock(EmployeeSecondaryDepartmentRepository.class), mock(UserAccountRepository.class),
                mock(DepartmentRepository.class), mock(ManagerPermissionDelegationRepository.class),
                new PermissionDelegationPolicy(PermissionGrantPolicyCatalog.fixed(
                        Map.of(VIEW, Set.of(GrantPolicy.NORMAL), CONFIRM, Set.of(GrantPolicy.NORMAL)))),
                PermissionSurfaceRegistryTestFixture.registry(Map.of("sales.finance", REQUIRED)),
                new PagePermissionDelegationFeatureGate(featureEnabled), jdbc);
    }

    public void department(UUID id, String code, String level, UUID parent) {
        jdbc.update("INSERT INTO departments(id,code,name,level,parent_id) VALUES (?,?,?,?,?)", id, code, code, level, parent);
    }

    public UUID account(UUID department, boolean superAdmin) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO employees(id,department_id,full_name,code,status) VALUES (?,?,'Staff',?,'active')",
                id, department,"FIX-"+id);
        jdbc.update("INSERT INTO users(id,employee_id,is_super_admin,status) VALUES (?,?,?,'active')", id, id, superAdmin);
        return id;
    }

    public List<UUID> accounts(int count, UUID department, boolean superAdmin) {
        List<UUID> ids = new ArrayList<>();
        List<Object[]> employees = new ArrayList<>(), users = new ArrayList<>();
        for (int index=0; index<count; index++) {
            UUID id=UUID.randomUUID(); ids.add(id);
            employees.add(new Object[]{id,department,"FIX-"+id}); users.add(new Object[]{id,id,superAdmin});
        }
        jdbc.batchUpdate("INSERT INTO employees(id,department_id,full_name,code,status) VALUES (?,?,'Staff',?,'active')",employees);
        jdbc.batchUpdate("INSERT INTO users(id,employee_id,is_super_admin,status) VALUES (?,?,?,'active')",users);
        return List.copyOf(ids);
    }

    public void grant(UUID user, UUID permission) {
        override(user, permission, "grant", "SUPER_ADMIN_CONFIRMED");
    }

    public void override(UUID user, UUID permission, String effect, String source) {
        jdbc.update("""
                INSERT INTO user_permission_overrides(user_id,permission_id,effect,authority_source) VALUES (?,?,?,?)
                ON CONFLICT(user_id,permission_id) DO UPDATE SET effect=excluded.effect,
                  authority_source=excluded.authority_source,active=true
                """,
                user, permission, effect, source);
    }

    public void departmentGrants(UUID department) {
        jdbc.update("INSERT INTO department_permissions VALUES (?,?),(?,?)", department, view, department, confirm);
    }

    public void delegation(UUID target, UUID department, UUID grantor, UUID permission, boolean superAdminSource, UUID scope) {
        // The real V322 catalog deliberately leaves historical snapshot columns
        // NULL. A new fixture grant must capture its actual subjects, never turn
        // unknown snapshots into a permissive default.
        Map<String,Object> current=jdbc.queryForMap("""
                SELECT target.permission_delegation_generation target_user_generation,
                       target_employee.permission_delegation_generation target_employee_generation,
                       target_department.permission_delegation_generation target_department_generation,
                       grantor.permission_delegation_generation grantor_user_generation,
                       grantor_employee.permission_delegation_generation grantor_employee_generation,
                       grantor.auth_version grantor_auth_version,auth_state.epoch grantor_authorization_epoch
                FROM users target JOIN employees target_employee ON target_employee.id=target.employee_id
                JOIN departments target_department ON target_department.id=?
                CROSS JOIN users grantor
                LEFT JOIN employees grantor_employee ON grantor_employee.id=grantor.employee_id
                CROSS JOIN authorization_state auth_state
                WHERE target.id=? AND grantor.id=? AND auth_state.singleton_id=1
                """,department,target,grantor);
        for(String key:List.of("target_user_generation","target_employee_generation","target_department_generation",
                "grantor_user_generation","grantor_auth_version","grantor_authorization_epoch")) {
            if(!(current.get(key) instanceof Number))throw new IllegalStateException("Unknown fixture delegation snapshot: "+key);
        }
        Long scopeGeneration=superAdminSource?null:jdbc.queryForObject(
                "SELECT permission_delegation_generation FROM departments WHERE id=?",Long.class,scope);
        jdbc.update("""
                INSERT INTO manager_permission_delegations(user_id,department_id,permission_id,granted_by_user_id,
                  surface_key,scope_source,grantor_employee_generation,scope_department_id,scope_generation,
                  target_user_generation,target_employee_generation,target_department_generation,
                  grantor_user_generation,grantor_auth_version,grantor_authorization_epoch)
                VALUES (?,?,?,?,'sales.finance',?,?,?,?,?,?,?,?,?,?)
                """, target, department, permission, grantor,
                superAdminSource ? "SUPER_ADMIN" : "DEPARTMENT_MANAGER",
                superAdminSource ? null : current.get("grantor_employee_generation"), superAdminSource ? null : scope,scopeGeneration,
                current.get("target_user_generation"),current.get("target_employee_generation"),current.get("target_department_generation"),
                current.get("grantor_user_generation"),current.get("grantor_auth_version"),current.get("grantor_authorization_epoch"));
    }
}
