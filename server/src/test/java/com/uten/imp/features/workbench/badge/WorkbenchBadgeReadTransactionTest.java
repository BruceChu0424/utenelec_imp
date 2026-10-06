package com.uten.imp.features.workbench.badge;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.application.port.WorkbenchBadgeSources;
import jakarta.persistence.EntityManager;
import org.hibernate.Session;
import org.hibernate.jdbc.ReturningWork;
import org.hibernate.jdbc.Work;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.jdbc.datasource.ConnectionHolder;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.TransactionManager;
import org.springframework.transaction.annotation.AnnotationTransactionAttributeSource;
import org.springframework.transaction.interceptor.TransactionInterceptor;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.Savepoint;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class WorkbenchBadgeReadTransactionTest {
    @ParameterizedTest @ValueSource(ints={0,1,2})
    void badgeSnapshotsMayRollbackTheirOwnReadWithoutPoisoningAParentConversationRead(int entryPoint) throws Exception {
        DataSource dataSource=mock(DataSource.class); List<Connection> connections=new ArrayList<>();
        when(dataSource.getConnection()).thenAnswer(call->{
            Connection connection=mock(Connection.class); when(connection.getAutoCommit()).thenReturn(true);
            when(connection.setSavepoint()).thenReturn(mock(Savepoint.class)); connections.add(connection); return connection;
        });
        var manager=new DataSourceTransactionManager(dataSource);
        var sources=Arrays.stream(WorkbenchBadgeCatalog.values()).flatMap(entry->Stream.concat(entry.todoFacts().stream(),entry.inProgressFacts().stream()))
                .map(WorkbenchBadgeCatalog::sourceOf).distinct().map(key->new WorkbenchBadgeSources.Source(key,
                        ()->Map.of("count",1L,"preparing",2L,"inProgress",3L))).toList();
        WorkbenchBadgeSources contributor=()->sources;
        var scopes=mock(WarehouseTaskScopePort.class);
        when(scopes.withScopeCache(any())).thenAnswer(call->((java.util.function.Supplier<?>)call.getArgument(0)).get());
        var target=new WorkbenchBadgeService(List.of(contributor),manager,scopes);
        EntityManager em=mock(EntityManager.class); Session session=mock(Session.class); when(em.unwrap(Session.class)).thenReturn(session);
        when(session.doReturningWork(any())).thenAnswer(call->((ReturningWork<?>)call.getArgument(0)).execute(
                ((ConnectionHolder)TransactionSynchronizationManager.getResource(dataSource)).getConnection()));
        doAnswer(call->{((Work)call.getArgument(0)).execute(((ConnectionHolder)TransactionSynchronizationManager.getResource(dataSource)).getConnection());return null;}).when(session).doWork(any());
        ReflectionTestUtils.setField(target,"entityManager",em);
        ProxyFactory factory=new ProxyFactory(target); factory.setProxyTargetClass(true);
        factory.addAdvice(new TransactionInterceptor((TransactionManager)manager,new AnnotationTransactionAttributeSource()));
        WorkbenchBadgeService service=(WorkbenchBadgeService)factory.getProxy();
        assertThatCode(()->new TransactionTemplate(manager).execute(status->{
            if(entryPoint==0) assertThat(service.summary(Set.of("productionWorkshop")).entries().get("productionWorkshop").inProgress()).isEqualTo(3);
            else if(entryPoint==1) assertThat(service.entries(Set.of("productionWorkshop")).todo().get("productionWorkshop")).isEqualTo(2);
            else assertThat(service.summary().entries()).containsKey("productionWorkshop");
            return null;
        })).doesNotThrowAnyException();
        assertThat(connections).hasSize(2);
        verify(connections.get(0)).commit(); verify(connections.get(0),never()).rollback();
        verify(connections.get(1)).rollback(); verify(connections.get(1),never()).commit();
        verify(scopes).withScopeCache(any()); // 一次汇总 = 一个范围解析复用窗口(准则 14)
    }
}
