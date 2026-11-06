package com.uten.imp.businesschain;

import com.uten.imp.support.MigratedSchemaBaseline;
import com.uten.imp.support.ObservedSqlDataSource;
import com.zaxxer.hikari.HikariDataSource;
import java.util.HashMap;
import java.util.concurrent.atomic.AtomicInteger;
import javax.sql.DataSource;
import org.junit.jupiter.api.Test;
import org.springframework.context.support.GenericApplicationContext;
import org.springframework.test.context.TestContext;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Context ownership and inferred delegate destruction; never opens a network connection. */
class FinanceScopedChainDatabaseCleanupTest {
    private static final String OWNED="jdbc:postgresql://127.0.0.1:1/never_connected_owned_fixture";
    private static final class Owner { }

    @Test void failedOrRetiredStartupNeverReloadsTheApplicationContext() throws Exception {
        var test=mock(TestContext.class);when(test.hasApplicationContext()).thenReturn(false);
        var evidence=new FinanceScopedChainDatabase.BoundaryEvidence();
        evidence.beforeTestMethod(test);evidence.afterTestExecution(test);evidence.afterTestClass(test);
        verify(test,never()).getApplicationContext();
    }

    @Test void aDelegateObserverKeepsSpringInferredCloseOnTheActualPoolBeforeItsLease() throws Exception {
        exercise(true);
    }

    @Test void ordinarySpringPoolDestructionRemainsAnIdempotentSingleClose() throws Exception {
        exercise(false);
    }

    @Test void aForeignDatasourceIsRefusedWithoutClosingItOrReleasingThePrivateLease() throws Exception {
        var lease=lease();var pool=new CountingPool();pool.setJdbcUrl(OWNED+"_different");
        try(var baselines=mockStatic(MigratedSchemaBaseline.class);var application=new GenericApplicationContext()) {
            baselines.when(()->MigratedSchemaBaseline.openDatabase("finance_chain")).thenReturn(lease);
            new FinanceScopedChainDatabase.Initializer().initialize(application);
            application.registerBean("dataSource",DataSource.class,()->pool,definition->definition.setDestroyMethodName("close"));
            application.refresh();var test=context(application);
            assertThatThrownBy(()->new FinanceScopedChainDatabase.BoundaryEvidence().beforeTestMethod(test))
                .isInstanceOf(IllegalStateException.class).hasMessageContaining("foreign datasource");
            assertThat(application.isActive()).isTrue();assertThat(pool.isClosed()).isFalse();verify(lease,never()).close();
        }
    }

    private static void exercise(boolean observed) throws Exception {
        var lease=lease();var pool=new CountingPool();pool.setJdbcUrl(OWNED);
        try(var baselines=mockStatic(MigratedSchemaBaseline.class);var application=new GenericApplicationContext()) {
            baselines.when(()->MigratedSchemaBaseline.openDatabase("finance_chain")).thenReturn(lease);
            new FinanceScopedChainDatabase.Initializer().initialize(application);
            DataSource exposed=observed?new ObservedSqlDataSource.Pooled(pool):pool;
            application.registerBean("dataSource",DataSource.class,()->exposed,
                definition->definition.setDestroyMethodName(org.springframework.beans.factory.support.AbstractBeanDefinition.INFER_METHOD));
            doAnswer(call->{assertThat(application.isActive()).isFalse();assertThat(pool.isClosed()).isTrue();return null;}).when(lease).close();
            application.refresh();var test=context(application);var evidence=new FinanceScopedChainDatabase.BoundaryEvidence();
            evidence.beforeTestMethod(test);application.close();evidence.afterTestClass(test);
            assertThat(pool.closes.get()).isOne();verify(lease,times(1)).close();
            evidence.afterTestClass(test);assertThat(pool.closes.get()).isOne();
        }
    }

    private static MigratedSchemaBaseline.ScopedDatabase lease() {
        var lease=mock(MigratedSchemaBaseline.ScopedDatabase.class);when(lease.getJdbcUrl()).thenReturn(OWNED);
        when(lease.getUsername()).thenReturn("fixture-role");when(lease.getPassword()).thenReturn("fixture-only");return lease;
    }
    private static TestContext context(GenericApplicationContext application) {
        var test=mock(TestContext.class);var attributes=new HashMap<String,Object>();
        doReturn(Owner.class).when(test).getTestClass();when(test.hasApplicationContext()).thenReturn(true);
        when(test.getApplicationContext()).thenReturn(application);
        when(test.getAttribute(anyString())).thenAnswer(call->attributes.get(call.getArgument(0)));
        doAnswer(call->{attributes.put(call.getArgument(0),call.getArgument(1));return null;}).when(test).setAttribute(anyString(),any());
        when(test.removeAttribute(anyString())).thenAnswer(call->attributes.remove(call.getArgument(0)));return test;
    }
    private static final class CountingPool extends HikariDataSource {
        final AtomicInteger closes=new AtomicInteger();
        @Override public void close() { closes.incrementAndGet();super.close(); }
    }
}
