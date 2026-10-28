package com.uten.imp.features.companyfiles;

import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;

/**
 * V958 forward upgrade from the V931 state: the entrance returns to the baseline pack,
 * the download code retires and write codes leave the common-module group, while the
 * department allocations, personal revokes and the ACL subject contract stay exact.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class CompanyFileEveryoneMigrationPostgresTest {
    static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:16-alpine");
    static JdbcTemplate db;
    static UUID revokedEmployee, revokedUser;

    @BeforeAll
    static void history() {
        POSTGRES.start();
        var source = new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        db = new JdbcTemplate(source);
        TestFlyway.configure().dataSource(source).locations("classpath:db/migration")
                .target("931").load().migrate();
        revokedEmployee = UUID.randomUUID();
        revokedUser = UUID.randomUUID();
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) "
                + "SELECT ?,?,'全员可见迁移验证人','其他',id,current_date,'active','regular' FROM departments WHERE code='DEPT_FIN'",
                revokedEmployee, "EV-" + revokedEmployee);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password) "
                + "VALUES(?,?,?,'test-only','active',false)", revokedUser, revokedEmployee, "everyone-" + revokedUser);
        db.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) "
                + "SELECT ?,id,'revoke' FROM permissions WHERE code='company_file:view'", revokedUser);
        db.update("INSERT INTO department_permissions(department_id,permission_id) "
                + "SELECT (SELECT id FROM departments WHERE NOT is_deleted LIMIT 1),id "
                + "FROM permissions WHERE code='company_file:download'");
        assertThat(TestFlyway.configure().dataSource(source).locations("classpath:db/migration")
                .load().migrate().migrationsExecuted).isGreaterThanOrEqualTo(1);
    }

    @AfterAll
    static void stop() {
        POSTGRES.stop();
    }

    @Test
    void entranceReturnsToBaselineAndV931DepartmentAllocationsAreRetired() {
        assertThat(db.queryForObject(
                "SELECT baseline FROM permissions WHERE code='company_file:view'", Boolean.class)).isTrue();
        assertThat(db.queryForObject(
                "SELECT count(*) FROM department_permissions p JOIN permissions permission ON permission.id=p.permission_id "
                        + "WHERE permission.code='company_file:view'", Integer.class)).isZero();
        // Personal revokes survive and still win over the baseline.
        assertThat(db.queryForList(
                "SELECT effect FROM user_permission_overrides p JOIN permissions permission ON permission.id=p.permission_id "
                        + "WHERE p.user_id=? AND permission.code='company_file:view'", String.class, revokedUser))
                .containsExactly("revoke");
    }

    @Test
    void downloadCodeRetiresAndWriteCodesLeaveTheCommonModuleSurface() {
        assertThat(db.queryForObject(
                "SELECT count(*) FROM permissions WHERE code='company_file:download'", Integer.class)).isZero();
        assertThat(db.queryForList(
                "SELECT code FROM permissions WHERE module='常用模块' ORDER BY sort_order", String.class))
                .containsExactly("company_file:view", "expense:apply", "payroll:view:self",
                        "suggestion:submit", "visitor:host_confirm");
        assertThat(db.queryForObject(
                "SELECT count(*) FROM permissions WHERE module='系统管理' AND code LIKE 'company_file:%'",
                Integer.class)).isEqualTo(7);
        assertThat(db.queryForObject(
                "SELECT count(*) FROM permission_surface_permissions p JOIN permission_surfaces s ON s.id=p.surface_id "
                        + "WHERE s.surface_key='common.company-files'", Integer.class)).isEqualTo(1);
        assertThat(db.queryForObject(
                "SELECT count(*) FROM department_permissions p JOIN permissions permission ON permission.id=p.permission_id "
                        + "WHERE permission.code='company_file:download'", Integer.class)).isZero();
    }

    @Test
    void aclAcceptsOnlyTheCanonicalEveryoneMarkerSubject() {
        UUID creatorEmployee = UUID.randomUUID(), creator = UUID.randomUUID();
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) "
                + "SELECT ?,?,'全员主体迁移验证人','其他',id,current_date,'active','regular' FROM departments WHERE code='DEPT_FIN'",
                creatorEmployee, "EV-" + creatorEmployee);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password) "
                + "VALUES(?,?,?,'test-only','active',false)", creator, creatorEmployee, "everyone-node-" + creator);
        UUID node = UUID.randomUUID();
        db.update("INSERT INTO company_file_nodes(id,kind,name,created_by,updated_by) "
                + "VALUES(?,'FOLDER',?,?,?)", node, "everyone-migration-" + node, creator, creator);
        db.update("INSERT INTO company_file_acl(node_id,subject_type,subject_id,effect,actions) "
                + "VALUES(?,'ALL','00000000-0000-0000-0000-000000000000'::uuid,'ALLOW',ARRAY['view','download'])", node);
        // Outside the view/download vocabulary, or a deny / foreign marker id, is rejected.
        for (String rejected : List.of("ARRAY['view','edit']::text[]", "ARRAY['edit']::text[]")) {
            assertThatThrownBy(() -> db.update(
                    "INSERT INTO company_file_acl(node_id,subject_type,subject_id,effect,actions) "
                            + "VALUES(?,'ALL','00000000-0000-0000-0000-000000000000'::uuid,'ALLOW',"
                            + rejected + ")", node))
                    .isInstanceOf(DataIntegrityViolationException.class);
        }
        assertThatThrownBy(() -> db.update(
                "INSERT INTO company_file_acl(node_id,subject_type,subject_id,effect,actions) "
                        + "VALUES(?,'ALL',?::uuid,'DENY',ARRAY['view','download'])", node, UUID.randomUUID()))
                .isInstanceOf(DataIntegrityViolationException.class);
        assertThatThrownBy(() -> db.update(
                "INSERT INTO company_file_acl(node_id,subject_type,subject_id,effect,actions) "
                        + "VALUES(?,'ALL',?::uuid,'ALLOW',ARRAY['view','download'])", node, UUID.randomUUID()))
                .isInstanceOf(DataIntegrityViolationException.class);
    }
}
