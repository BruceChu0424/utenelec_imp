package com.uten.imp.features.attachment;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;
import java.sql.Connection;
import java.sql.DriverManager;
import java.nio.charset.StandardCharsets;
import static org.assertj.core.api.Assertions.*;

/** Dedicated cluster: old reset owner and new migration owner preserve the real one-way migration membership, never granting the reset owner the new owner role. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class BusinessTestObjectCleanupOwnerPostgresTest {
    PostgreSQLContainer<?> postgres;
    @BeforeAll void start() throws Exception {
        postgres=new PostgreSQLContainer<>("postgres:16-alpine");postgres.start();
        Flyway.configure().dataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword()).target("781").load().migrate();
        try(Connection c=open();var s=c.createStatement()) {
            s.execute("CREATE ROLE uten_owner NOLOGIN; CREATE ROLE uten_migrator NOLOGIN; CREATE ROLE uten NOLOGIN; GRANT uten_owner TO uten_migrator");
            s.execute("GRANT USAGE,CREATE ON SCHEMA public TO uten_owner,uten_migrator; GRANT ALL ON ALL TABLES IN SCHEMA public TO uten_owner; GRANT SELECT ON ALL TABLES IN SCHEMA public TO uten_migrator");
            s.execute("ALTER FUNCTION public.business_data_reset() OWNER TO uten_owner; ALTER TABLE public.authorization_state OWNER TO uten_owner; ALTER FUNCTION public.fn_attachment_retained_identity_guard() OWNER TO uten_owner; GRANT EXECUTE ON FUNCTION public.fn_require_runtime_maintenance(boolean) TO uten_owner");
            s.execute("GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO uten_migrator");
            s.execute("SET ROLE uten_migrator");
            for(String file:new String[]{"010-root-test-context.sql","020-test-object-intents.sql","030-attachment-test-clear-guards.sql"})
                try(var input=getClass().getResourceAsStream("/test-reset/"+file)){assertThat(input).isNotNull();s.execute(new String(input.readAllBytes(),StandardCharsets.UTF_8));}
            s.execute("RESET ROLE");
        }
    }
    @AfterAll void stop(){if(postgres!=null)postgres.stop();}
    @Test void oldResetOwnerCanAssertAndClearWithoutReverseMembershipOrOrdinaryRuntimeWriteGrant() throws Exception {
        try(Connection c=open();var s=c.createStatement()) {
            try(var r=s.executeQuery("SELECT pg_has_role('uten_owner','uten_migrator','MEMBER'),pg_has_role('uten_migrator','uten_owner','MEMBER'),has_table_privilege('uten','business_test_object_cleanup_intents','INSERT'),has_table_privilege('uten_owner','business_test_object_cleanup_intents','TRUNCATE')")) {
                assertThat(r.next()).isTrue();assertThat(r.getBoolean(1)).isFalse();assertThat(r.getBoolean(2)).isTrue();assertThat(r.getBoolean(3)).isFalse();assertThat(r.getBoolean(4)).isTrue();
            }
            c.setAutoCommit(false);s.execute("SET LOCAL ROLE uten_owner; SELECT set_config('app.test_business_reset','CLEAR_TEST_BUSINESS_WITH_HISTORY',true)");
            s.execute("SELECT fn_assert_business_test_objects_cleared(); SELECT fn_clear_business_test_object_metadata(); TRUNCATE business_test_object_cleanup_intents");
            c.rollback();
        }
    }
    @Test void ordinaryRoleCannotEnableMaintenanceByForgingFlagOrCallPrivateClearHelper() throws Exception {
        try(Connection c=open();var s=c.createStatement()) {
            c.setAutoCommit(false);s.execute("SET LOCAL ROLE uten; SELECT set_config('app.test_business_reset','CLEAR_TEST_BUSINESS_WITH_HISTORY',true)");
            try(var r=s.executeQuery("SELECT fn_business_test_reset_active()")){assertThat(r.next()).isTrue();assertThat(r.getBoolean(1)).isFalse();}
            assertThatThrownBy(()->s.execute("SELECT fn_clear_business_test_object_metadata()" )).hasMessageContaining("permission denied");c.rollback();
            c.setAutoCommit(false);s.execute("SET LOCAL ROLE uten");
            assertThatThrownBy(()->s.execute("TRUNCATE business_test_object_cleanup_intents")).hasMessageContaining("permission denied");c.rollback();
        }
    }
    private Connection open()throws Exception{return DriverManager.getConnection(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword());}
}
