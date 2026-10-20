package com.uten.imp.features.admin.serveroperations;

import com.uten.imp.support.BatchPermissionFixture;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import static org.assertj.core.api.Assertions.*;

@Testcontainers
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ServerOperationsActorAuthorityPostgresTest {
    @Container static final PostgreSQLContainer DB=new PostgreSQLContainer("postgres:16-alpine");
    @Test void runtimeIdentityIsQueriedFromTheRealPostgresSessionRatherThanAGuessedJdbcUrl() {
        var source=new DriverManagerDataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword());
        var active=org.mockito.Mockito.mock(com.uten.imp.common.storage.StorageService.class);
        org.mockito.Mockito.when(active.backend()).thenReturn("disabled");
        var binding=new ServerOperationsRuntimeBinding(source,active,new com.uten.imp.config.props.StorageProperties()).capture();
        assertThat(binding).containsEntry("database",DB.getDatabaseName()).containsEntry("port",5432)
                .containsEntry("storageProvider","disabled").containsEntry("mediaRoot",null);
        assertThat(binding.get("host")).asString().isNotBlank();
        var peerTime=new JdbcTemplate(source).queryForObject("SELECT pg_postmaster_start_time()",java.sql.Timestamp.class);
        assertThat(java.time.Instant.parse((String)binding.get("postmasterStartedAt"))).isEqualTo(peerTime.toInstant());
        assertThat(binding.keySet()).doesNotContain("url","jdbcUrl","password","username");
    }
    @Test void actualJdbcSearchPathOutsidePublicCannotAuthorizeTheFixedPublicMigrationWorkflow() {
        var source=new DriverManagerDataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword());
        new JdbcTemplate(source).execute("CREATE SCHEMA IF NOT EXISTS ops_private_scope");
        var other=new DriverManagerDataSource(DB.getJdbcUrl()+(DB.getJdbcUrl().contains("?")?"&":"?")+"currentSchema=ops_private_scope",DB.getUsername(),DB.getPassword());
        var active=org.mockito.Mockito.mock(com.uten.imp.common.storage.StorageService.class);
        org.mockito.Mockito.when(active.backend()).thenReturn("disabled");
        assertThatThrownBy(()->new ServerOperationsRuntimeBinding(other,active,new com.uten.imp.config.props.StorageProperties()).capture())
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageNotContaining("ops_private_scope");
    }
    @Test void onlyFreshActiveSuperAdminOrConfirmedDirectGrantCanExecuteUnattended() {
        var jdbc=new JdbcTemplate(new DriverManagerDataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword()));
        var data=new BatchPermissionFixture(jdbc);UUID permission=UUID.randomUUID();
        jdbc.update("INSERT INTO permissions(id,code) VALUES (?,'server:update')",permission);
        UUID confirmed=data.account(data.finance,false),legacy=data.account(data.finance,false),department=data.account(data.finance,false),
                revoked=data.account(data.finance,false),disabled=data.account(data.finance,false),deleted=data.account(data.finance,false),
                mustChange=data.account(data.finance,false),visitorLike=data.account(data.finance,false),admin=data.account(data.other,true),
                resigned=data.account(data.finance,false),deletedEmployee=data.account(data.finance,false),
                probation=data.account(data.finance,false),onLeave=data.account(data.finance,false);
        jdbc.update("UPDATE users SET must_change_password=false");
        for(UUID user:java.util.List.of(confirmed,revoked,disabled,deleted,mustChange,visitorLike,resigned,deletedEmployee,probation,onLeave)) data.grant(user,permission);
        data.override(legacy,permission,"grant","LEGACY_UNKNOWN");
        jdbc.update("INSERT INTO department_permissions VALUES (?,?)",data.finance,permission);
        data.override(revoked,permission,"revoke","SUPER_ADMIN_CONFIRMED");
        jdbc.update("UPDATE users SET status='disabled' WHERE id=?",disabled);
        jdbc.update("UPDATE users SET is_deleted=true WHERE id=?",deleted);
        jdbc.update("UPDATE users SET must_change_password=true WHERE id=?",mustChange);
        jdbc.update("UPDATE users SET employee_id=null WHERE id=?",visitorLike);
        jdbc.update("UPDATE employees SET status='resigned' WHERE id=?",resigned);
        jdbc.update("UPDATE employees SET is_deleted=true WHERE id=?",deletedEmployee);
        jdbc.update("UPDATE employees SET status='probation' WHERE id=?",probation);
        jdbc.update("UPDATE employees SET status='onLeave' WHERE id=?",onLeave);
        jdbc.update("UPDATE users SET employee_id=null WHERE id=?",admin);
        var authority=new ServerOperationsActorAuthority(jdbc);
        assertThat(authority.currentUpdaters()).containsExactlyInAnyOrder(confirmed,admin,probation,onLeave);
        assertThat(authority.mayUpdate(confirmed)).isTrue();assertThat(authority.mayUpdate(admin)).isTrue();
        for(UUID user:java.util.List.of(legacy,department,revoked,disabled,deleted,mustChange,visitorLike,resigned,deletedEmployee,UUID.randomUUID()))
            assertThat(authority.mayUpdate(user)).as("fresh authority %s",user).isFalse();
        data.override(confirmed,permission,"revoke","SUPER_ADMIN_CONFIRMED");
        assertThat(authority.mayUpdate(confirmed)).isFalse(); // no JWT or resolver-cache stale permission
        jdbc.update("UPDATE users SET is_super_admin=false WHERE id=?",admin);
        assertThat(authority.currentUpdaters()).containsExactlyInAnyOrder(probation,onLeave);
    }
}
