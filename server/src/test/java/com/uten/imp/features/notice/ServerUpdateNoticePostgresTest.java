package com.uten.imp.features.notice;

import com.uten.imp.features.admin.serveroperations.ServerOperationsActorAuthority;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.support.BatchPermissionFixture;
import com.uten.imp.support.MigratedProjectionSchema;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

@Testcontainers
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ServerUpdateNoticePostgresTest {
    @Container static final PostgreSQLContainer DB=new PostgreSQLContainer("postgres:16-alpine");
    @Test void concurrentScansAndRestartKeepOnePersistentReceiptPerRecipientSourceAndVersion() throws Exception {
        var source=new DriverManagerDataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword());
        var jdbc=new JdbcTemplate(source);var data=new BatchPermissionFixture(jdbc);
        MigratedProjectionSchema.createCurrentTables(jdbc,"notices","notice_user_states");
        UUID user=data.account(data.finance,false);var authority=mock(ServerOperationsActorAuthority.class);
        var permissions=mock(PermissionResolver.class);var notices=mock(NoticeService.class);
        when(authority.mayUpdate(user)).thenReturn(true);when(permissions.usersGrantedAll(List.of(user),Set.of("notice:read"))).thenReturn(List.of(user));
        doAnswer(call->{UUID id=UUID.randomUUID();
            jdbc.update("INSERT INTO notices(id,title,content,type,publisher,source_event) VALUES (?,?,?,?,?,?)",
                    id,call.getArgument(1),call.getArgument(2),call.getArgument(3),call.getArgument(4),call.getArgument(6));
            jdbc.update("INSERT INTO notice_user_states(notice_id,user_id) VALUES (?,?)",id,call.getArgument(0));return null;
        }).when(notices).publishForUser(eq(user),anyString(),anyString(),anyString(),anyString(),anyString(),anyString(),anyString());
        var tx=new TransactionTemplate(new DataSourceTransactionManager(source));var start=new CountDownLatch(1);
        try(var pool=Executors.newFixedThreadPool(2)) {
            var one=pool.submit(()->{start.await();tx.executeWithoutResult(s->new ServerUpdateNoticePublisher(authority,permissions,notices,jdbc).publishOnce(user,"rev1","v2.5.18"));return true;});
            var two=pool.submit(()->{start.await();tx.executeWithoutResult(s->new ServerUpdateNoticePublisher(authority,permissions,notices,jdbc).publishOnce(user,"rev1","v2.5.18"));return true;});
            start.countDown();assertThat(one.get(20,TimeUnit.SECONDS)).isTrue();assertThat(two.get(20,TimeUnit.SECONDS)).isTrue();
        }
        tx.executeWithoutResult(s->new ServerUpdateNoticePublisher(authority,permissions,notices,jdbc).publishOnce(user,"rev1","v2.5.18"));
        assertThat(jdbc.queryForObject("SELECT count(*) FROM notices",Integer.class)).isEqualTo(1);
        tx.executeWithoutResult(s->new ServerUpdateNoticePublisher(authority,permissions,notices,jdbc).publishOnce(user,"rev2","v2.5.18"));
        assertThat(jdbc.queryForObject("SELECT count(*) FROM notices",Integer.class)).isEqualTo(2);
        when(authority.mayUpdate(user)).thenReturn(false);
        tx.executeWithoutResult(s->new ServerUpdateNoticePublisher(authority,permissions,notices,jdbc).publishOnce(user,"rev3","v2.5.18"));
        assertThat(jdbc.queryForObject("SELECT count(*) FROM notices",Integer.class)).isEqualTo(2);
    }
}
