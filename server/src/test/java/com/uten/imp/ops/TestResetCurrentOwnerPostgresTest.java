package com.uten.imp.ops;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

/** Real current migration with a retained owner, one-way migrator membership and restricted runtime login. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class TestResetCurrentOwnerPostgresTest {
    @Test void currentResetWorksThroughTheOriginalOwnerWithoutGrantingRuntimeDdlOrIntentWrites() {
        String password=UUID.randomUUID().toString();
        try(var pg=new PostgreSQLContainer<>("postgres:16-alpine").withDatabaseName("reset_current_owner").withUsername("fixture_admin")) {
            pg.start();
            var admin=new JdbcTemplate(new DriverManagerDataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()));
            admin.execute("CREATE ROLE uten_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE");
            admin.execute("CREATE ROLE uten_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT PASSWORD '"+password+"'");
            admin.execute("CREATE ROLE uten LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD '"+password+"'");
            admin.execute("GRANT uten_owner TO uten_migrator");
            admin.execute("ALTER DATABASE reset_current_owner OWNER TO uten_migrator; ALTER SCHEMA public OWNER TO uten_migrator");
            admin.execute("REVOKE ALL ON DATABASE reset_current_owner FROM PUBLIC; REVOKE ALL ON SCHEMA public FROM PUBLIC; GRANT CONNECT ON DATABASE reset_current_owner TO uten; GRANT USAGE ON SCHEMA public TO uten");
            Flyway.configure().dataSource(pg.getJdbcUrl(),"uten_migrator",password).locations("classpath:db/migration").target("781").load().migrate();
            admin.execute("REASSIGN OWNED BY uten_migrator TO uten_owner");
            assertThat(Flyway.configure().dataSource(pg.getJdbcUrl(),"uten_migrator",password).locations("classpath:db/migration").target("782").load().migrate().migrationsExecuted).isEqualTo(1);
            assertThat(admin.queryForObject("SELECT pg_has_role('uten_migrator','uten_owner','MEMBER')",Boolean.class)).isTrue();
            assertThat(admin.queryForObject("SELECT pg_has_role('uten_owner','uten_migrator','MEMBER')",Boolean.class)).isFalse();
            assertThat(admin.queryForObject("SELECT proowner::regrole::text FROM pg_proc WHERE oid='public.business_data_reset()'::regprocedure",String.class)).isEqualTo("uten_owner");
            assertThat(admin.queryForObject("SELECT proowner::regrole::text FROM pg_proc WHERE oid='public.fn_clear_business_test_object_metadata()'::regprocedure",String.class)).isEqualTo("uten_migrator");
            UUID employee=UUID.randomUUID(),actor=UUID.randomUUID(),document=UUID.randomUUID();
            admin.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,?,'测试维护管理员','其他',id,CURRENT_DATE,'active','regular' FROM departments WHERE code='DEPT_FIN'",employee,"RST-ACL-"+employee);
            admin.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status,is_super_admin) VALUES(?,?,?,'test-only',false,'active',true)",actor,employee,"reset-acl-admin");
            admin.update("INSERT INTO sales_quotes(id,bill_no,bill_date,status) VALUES(?,'XB'||to_char(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai','YYYYMMDD')||'991901',(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai')::date,0)",document);
            var runtimeSource=new DriverManagerDataSource(pg.getJdbcUrl(),"uten",password);
            var runtime=new JdbcTemplate(runtimeSource);
            assertThat(runtime.queryForObject("SELECT pg_has_role(current_user,'uten_owner','MEMBER')",Boolean.class)).isFalse();
            assertThat(runtime.queryForObject("SELECT pg_has_role(current_user,'uten_migrator','MEMBER')",Boolean.class)).isFalse();
            assertThat(runtime.queryForObject("SELECT has_schema_privilege(current_user,'public','CREATE')",Boolean.class)).isFalse();
            assertThat(runtime.queryForObject("SELECT has_table_privilege(current_user,'public.business_test_object_cleanup_intents','UPDATE')",Boolean.class)).isFalse();
            assertThatThrownBy(()->runtime.queryForMap("SELECT * FROM business_data_reset()"))
                    .satisfies(error->assertThat(org.springframework.core.NestedExceptionUtils.getMostSpecificCause(error))
                            .isInstanceOf(java.sql.SQLException.class).hasMessageContaining("authenticated active super-admin"));
            long before=admin.queryForObject("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1",Long.class);
            new TransactionTemplate(new DataSourceTransactionManager(runtimeSource)).executeWithoutResult(status->{
                runtime.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,actor.toString());
                runtime.queryForObject("SELECT set_config('app.actor_account','reset-acl-admin',true)",String.class);
                runtime.queryForObject("SELECT set_config('app.audit_request_id',?,true)",String.class,UUID.randomUUID().toString());
                assertThat(((Number)runtime.queryForMap("SELECT * FROM business_data_reset()").get("cleared_table_count")).intValue()).isPositive();
            });
            assertThat(admin.queryForObject("SELECT count(*) FROM sales_quotes WHERE id=?",Integer.class,document)).isZero();
            assertThat(admin.queryForObject("SELECT count(*) FROM users WHERE id=?",Integer.class,actor)).isEqualTo(1);
            assertThat(admin.queryForObject("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1",Long.class)).isEqualTo(before+1);
            assertThat(runtime.queryForObject("SELECT fn_business_test_reset_active()",Boolean.class)).isFalse();
            assertThat(runtime.queryForObject("SELECT has_table_privilege(current_user,'public.business_test_object_cleanup_intents','TRUNCATE')",Boolean.class)).isFalse();
        }
    }
}
