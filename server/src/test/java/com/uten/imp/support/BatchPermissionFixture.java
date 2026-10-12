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
        jdbc.execute("""
                DROP SCHEMA public CASCADE; CREATE SCHEMA public;
                CREATE TABLE permissions(id uuid PRIMARY KEY,code text UNIQUE,baseline boolean NOT NULL DEFAULT false);
                CREATE TABLE departments(id uuid PRIMARY KEY,code text,name text,level text,parent_id uuid,manager_id uuid,
                  is_deleted boolean NOT NULL DEFAULT false,permission_delegation_generation bigint NOT NULL DEFAULT 0);
                CREATE TABLE employees(id uuid PRIMARY KEY,department_id uuid,full_name text NOT NULL DEFAULT 'Staff',code text NOT NULL DEFAULT '',status text NOT NULL DEFAULT 'active',
                  is_deleted boolean NOT NULL DEFAULT false,permission_delegation_generation bigint NOT NULL DEFAULT 0);
                CREATE TABLE users(id uuid PRIMARY KEY,employee_id uuid,is_super_admin boolean NOT NULL DEFAULT false,
                  is_deleted boolean NOT NULL DEFAULT false,status text NOT NULL DEFAULT 'active',
                  permission_delegation_generation bigint NOT NULL DEFAULT 0,auth_version bigint NOT NULL DEFAULT 0);
                CREATE TABLE employee_secondary_departments(employee_id uuid,department_id uuid);
                CREATE TABLE department_permissions(department_id uuid,permission_id uuid);
                CREATE TABLE user_permission_overrides(user_id uuid,permission_id uuid,effect text,active boolean NOT NULL DEFAULT true,
                  authority_source text NOT NULL DEFAULT 'SUPER_ADMIN_CONFIRMED',PRIMARY KEY(user_id,permission_id));
                CREATE TABLE authorization_state(singleton_id integer PRIMARY KEY,epoch bigint NOT NULL);
                INSERT INTO authorization_state VALUES (1,0);
                CREATE TABLE manager_permission_delegations(user_id uuid,department_id uuid,permission_id uuid,
                  granted_by_user_id uuid,surface_key text,enabled boolean NOT NULL DEFAULT true,
                  target_user_generation bigint NOT NULL DEFAULT 0,target_employee_generation bigint NOT NULL DEFAULT 0,
                  target_department_generation bigint NOT NULL DEFAULT 0,grantor_user_generation bigint NOT NULL DEFAULT 0,
                  grantor_employee_generation bigint,grantor_auth_version bigint NOT NULL DEFAULT 0,
                  grantor_authorization_epoch bigint NOT NULL DEFAULT 0,scope_source text,
                  scope_department_id uuid,scope_generation bigint,scope_assignment_id uuid,scope_assignment_version bigint,
                  PRIMARY KEY(user_id,department_id,permission_id));
                """);
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
        jdbc.update("INSERT INTO employees(id,department_id) VALUES (?,?)", id, department);
        jdbc.update("INSERT INTO users(id,employee_id,is_super_admin) VALUES (?,?,?)", id, id, superAdmin);
        return id;
    }

    public List<UUID> accounts(int count, UUID department, boolean superAdmin) {
        List<UUID> ids = new ArrayList<>();
        List<Object[]> employees = new ArrayList<>(), users = new ArrayList<>();
        for (int index=0; index<count; index++) {
            UUID id=UUID.randomUUID(); ids.add(id);
            employees.add(new Object[]{id,department}); users.add(new Object[]{id,id,superAdmin});
        }
        jdbc.batchUpdate("INSERT INTO employees(id,department_id) VALUES (?,?)",employees);
        jdbc.batchUpdate("INSERT INTO users(id,employee_id,is_super_admin) VALUES (?,?,?)",users);
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
        jdbc.update("""
                INSERT INTO manager_permission_delegations(user_id,department_id,permission_id,granted_by_user_id,
                  surface_key,scope_source,grantor_employee_generation,scope_department_id,scope_generation)
                VALUES (?,?,?,?,'sales.finance',?,?,?,?)
                """, target, department, permission, grantor,
                superAdminSource ? "SUPER_ADMIN" : "DEPARTMENT_MANAGER",
                superAdminSource ? null : 0L, superAdminSource ? null : scope, superAdminSource ? null : 0L);
    }
}
