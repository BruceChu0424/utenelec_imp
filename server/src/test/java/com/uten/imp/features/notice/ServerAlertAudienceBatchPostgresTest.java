package com.uten.imp.features.notice;

import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.support.BatchPermissionFixture;
import com.uten.imp.support.ObservedSqlDataSource;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

@Testcontainers
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ServerAlertAudienceBatchPostgresTest {
    @Container static final PostgreSQLContainer<?> DB=new PostgreSQLContainer<>("postgres:16-alpine")
            .withLabel("uten.test","server-alert-audience-batch");

    @Test void fourHundredFiftyOneActualRecipientsKeepRevokeActiveAndPageGatesWithoutDetachedProxyReads() {
        var source=new ObservedSqlDataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword());
        var jdbc=new JdbcTemplate(source);var data=new BatchPermissionFixture(jdbc);
        UUID receive=UUID.randomUUID(),read=UUID.randomUUID();
        jdbc.update("INSERT INTO permissions(id,code) VALUES (?,?),(?,?)",receive,ServerStatusAlertScheduler.RECEIVE_AUTHORITY,read,"notice:read");
        jdbc.update("INSERT INTO department_permissions VALUES (?,?),(?,?)",data.finance,receive,data.finance,read);
        List<UUID> all=data.accounts(451,data.finance,false);
        UUID revoked=all.get(0),disabled=all.get(1),deleted=all.get(2),noPageGate=all.get(3);
        data.override(revoked,receive,"revoke","SUPER_ADMIN_CONFIRMED");
        data.override(noPageGate,read,"revoke","SUPER_ADMIN_CONFIRMED");
        jdbc.update("UPDATE users SET status='disabled' WHERE id=?",disabled);
        jdbc.update("UPDATE users SET is_deleted=TRUE WHERE id=?",deleted);
        var users=mock(UserAccountRepository.class);
        var audience=new ServerAlertAudience(new NoticePermissionCandidateQuery(jdbc),users,data.resolver(true));
        source.statements.set(0);
        List<UUID> actual=audience.receivers();
        assertThat(actual).hasSize(447).doesNotContain(revoked,disabled,deleted,noPageGate);
        assertThat(source.statements.get()).isEqualTo(3); // shape + positive superset + coherent actual grants
        verify(users,only()).findActiveSuperAdminIds(); // scalar ID projection; no ORM user/department proxy.
        data.override(all.get(4),receive,"revoke","SUPER_ADMIN_CONFIRMED");
        assertThat(audience.receivers()).hasSize(446).doesNotContain(all.get(4));

        // The compatibility path may supply detached ORM users, but only scalar IDs/status are read.
        var fallback=mock(NoticePermissionCandidateQuery.class);
        when(fallback.possibleUsers(anySet())).thenReturn(java.util.Optional.empty());
        List<UserAccount> detached=all.stream().map(id->{
            var user=spy(new UserAccount());user.setId(id);user.setStatus("active");
            doThrow(new org.hibernate.LazyInitializationException("Detached department proxy")).when(user).getEmployee();
            return user;
        }).toList();
        when(users.findAll()).thenReturn(detached);
        source.statements.set(0);
        assertThat(new ServerAlertAudience(fallback,users,data.resolver(true)).receivers()).hasSize(446);
        assertThat(source.statements.get()).isEqualTo(1);

        // Ops alerts target super administrators themselves (ADR-063 exception): a super
        // admin with no real grant is filtered by the batch statement, then restored by
        // the union — without it the whole audience could silently drop to zero (2026-10-17).
        UUID superAdmin=data.account(data.other,true);
        when(users.findActiveSuperAdminIds()).thenReturn(List.of(superAdmin));
        assertThat(audience.receivers()).hasSize(447).contains(superAdmin);
    }
}
