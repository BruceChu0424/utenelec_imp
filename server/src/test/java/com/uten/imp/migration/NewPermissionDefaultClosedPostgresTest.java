package com.uten.imp.migration;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.sql.Connection;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
class NewPermissionDefaultClosedPostgresTest {
    @Test void newCapabilitiesDoNotInheritExistingGrantsAndFutureCatalogInsertDefaultsClosed() throws Exception {
        try(var postgres = new PostgreSQLContainer("postgres:16-alpine")) {
            postgres.start();
            migrate(postgres,"935");
            var source=new DriverManagerDataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword());
            var sql=new JdbcTemplate(source);
            UUID department=sql.queryForObject("SELECT id FROM departments WHERE NOT is_deleted ORDER BY id LIMIT 1",UUID.class);
            sql.update("INSERT INTO department_permissions(department_id,permission_id) SELECT ?,id FROM permissions WHERE code='goods:edit' ON CONFLICT DO NOTHING",department);
            int before=sql.queryForObject("SELECT count(*) FROM department_permissions",Integer.class);
            migrate(postgres,"936");
            assertThat(sql.queryForObject("SELECT count(*) FROM department_permissions",Integer.class)).isEqualTo(before);
            assertThat(sql.queryForObject("SELECT count(*) FROM permissions WHERE code IN ('goods:purchase:edit','goods:sales:edit') AND NOT baseline AND explicit_grant_required",Integer.class)).isEqualTo(2);
            assertThat(sql.queryForObject("SELECT count(*) FROM permissions WHERE baseline_pinned AND baseline",Integer.class)).isEqualTo(5);
            sql.update("INSERT INTO permissions(code,name,module,category,action_type,description,sort_order,baseline) VALUES('staff_probe:edit','probe','测试','测试','EDIT','probe',1,true)");
            assertThat(sql.queryForObject("SELECT baseline FROM permissions WHERE code='staff_probe:edit'",Boolean.class)).isFalse();
            assertThatThrownBy(()->sql.update("INSERT INTO department_permissions(department_id,permission_id) SELECT ?,id FROM permissions WHERE code='goods:purchase:edit'",department)).hasMessageContaining("automatically granted");
            assertThatThrownBy(()->sql.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'grant' FROM permissions WHERE code='goods:purchase:edit'",UUID.randomUUID()))
                    .hasMessageContaining("automatically granted");
            assertThatThrownBy(()->sql.update("INSERT INTO manager_permission_delegations(user_id,permission_id,department_id,surface_key,granted_by_user_id) SELECT ?,id,?,'basic.goods',? FROM permissions WHERE code='goods:purchase:edit'",
                    UUID.randomUUID(),department,UUID.randomUUID())).hasMessageContaining("automatically granted");
            assertThatThrownBy(()->sql.update("UPDATE permissions SET baseline=true WHERE code='goods:purchase:edit'")).hasMessageContaining("explicit administrator grant");
            assertThatThrownBy(()->sql.update("UPDATE permissions SET baseline_pinned=true WHERE code='goods:purchase:edit'"))
                    .hasMessageContaining("permissions_baseline_pinned_chk");
            assertThatThrownBy(()->sql.update("UPDATE permissions SET baseline=true,baseline_pinned=true WHERE code='goods:purchase:edit'"))
                    .hasMessageContaining("explicit administrator grant");
            assertThat(sql.queryForObject("SELECT count(*) FROM permissions WHERE code IN ('goods:purchase:edit','goods:sales:edit') AND (baseline OR baseline_pinned)",Integer.class)).isZero();
            UUID actor=UUID.randomUUID(),employee=UUID.randomUUID();
            sql.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,'授权测试人员','其他',?,current_date,'active','regular')",employee,"STAFF-GRANT-"+employee,department);
            sql.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status) VALUES(?,?,?,'not-a-login-hash',false,true,'active')",actor,employee,"staff-grant-"+actor);
            try(Connection connection=source.getConnection();
                    var actorStatement=connection.prepareStatement("SELECT set_config('app.actor_id',?,false)");
                    var grantStatement=connection.prepareStatement("INSERT INTO department_permissions(department_id,permission_id) SELECT ?,id FROM permissions WHERE code='goods:purchase:edit'")) {
                actorStatement.setString(1,actor.toString());
                actorStatement.execute();
                grantStatement.setObject(1,department);
                assertThat(grantStatement.executeUpdate()).isEqualTo(1);
            }
        }
    }
    private static void migrate(PostgreSQLContainer postgres,String version) {
        com.uten.imp.testsupport.TestFlyway.configure().dataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword())
            .locations("classpath:db/migration").target(version).load().migrate();
    }
}
