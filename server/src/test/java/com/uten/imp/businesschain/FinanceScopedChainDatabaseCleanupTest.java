package com.uten.imp.businesschain;

import com.uten.imp.support.MigratedSchemaBaseline;
import com.zaxxer.hikari.HikariDataSource;
import org.junit.jupiter.api.Test;
import org.springframework.context.support.GenericApplicationContext;
import org.springframework.test.context.TestContext;

import java.util.Map;
import javax.sql.DataSource;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Real Spring context/Hikari lifecycle; no connection is opened and no PostgreSQL is started. */
class FinanceScopedChainDatabaseCleanupTest {
    private static final String OWNED="jdbc:postgresql://127.0.0.1:1/never_connected_owned_fixture";
    private static final class FailedOwner { }
    private static final class SpiedOwner { }
    private static final class OrdinaryOwner { }
    private static final class OtherOwner { }

    @Test void failedStartupRetainsItsCloneAndNeverReloadsTheApplicationContext() throws Exception {
        var context=mock(TestContext.class);doReturn(FailedOwner.class).when(context).getTestClass();
        when(context.hasApplicationContext()).thenReturn(false);
        var lease=mock(MigratedSchemaBaseline.ScopedDatabase.class);own(FailedOwner.class,lease);
        try{
            assertThatThrownBy(()->new FinanceScopedChainDatabase.Cleanup().afterTestClass(context))
                .isInstanceOf(IllegalStateException.class).hasMessageContaining("without reloading");
            verify(context,never()).getApplicationContext();verify(lease,never()).close();
            assertThat(owned().get(FailedOwner.class)).isSameAs(lease);
        }finally{owned().remove(FailedOwner.class);}
    }

    @Test void aSpiedPoolWithoutSpringDestroyInferenceClosesAfterItsContextAndBeforeItsClone() throws Exception {
        exercise(SpiedOwner.class,false);
    }

    @Test void ordinarySpringPoolDestructionRemainsAnIdempotentSingleClose() throws Exception {
        exercise(OrdinaryOwner.class,true);
    }

    @Test void aPoolFromAnotherDatabaseCannotBeClosedOrReleaseTheOwnedClone() throws Exception {
        var context=mock(TestContext.class);doReturn(OtherOwner.class).when(context).getTestClass();
        when(context.hasApplicationContext()).thenReturn(true);
        var lease=mock(MigratedSchemaBaseline.ScopedDatabase.class);when(lease.getJdbcUrl()).thenReturn(OWNED);
        var pool=new HikariDataSource();pool.setJdbcUrl(OWNED+"_different");
        try(var application=new GenericApplicationContext()){
            application.registerBean("dataSource",DataSource.class,()->pool);application.refresh();
            when(context.getApplicationContext()).thenReturn(application);own(OtherOwner.class,lease);
            try{
                assertThatThrownBy(()->new FinanceScopedChainDatabase.Cleanup().afterTestClass(context))
                    .isInstanceOf(IllegalStateException.class).hasMessageContaining("different datasource");
                assertThat(application.isActive()).isTrue();assertThat(pool.isClosed()).isFalse();
                verify(lease,never()).close();assertThat(owned().get(OtherOwner.class)).isSameAs(lease);
            }finally{owned().remove(OtherOwner.class);}
        }finally{pool.close();}
    }

    private void exercise(Class<?> owner,boolean springCloses) throws Exception {
        var context=mock(TestContext.class);doReturn(owner).when(context).getTestClass();
        when(context.hasApplicationContext()).thenReturn(true);
        var lease=mock(MigratedSchemaBaseline.ScopedDatabase.class);when(lease.getJdbcUrl()).thenReturn(OWNED);
        var pool=spy(new HikariDataSource());pool.setJdbcUrl(OWNED);
        try(var application=new GenericApplicationContext()){
            application.registerBean("dataSource",DataSource.class,()->pool,
                definition->definition.setDestroyMethodName(springCloses?"close":""));application.refresh();
            when(context.getApplicationContext()).thenReturn(application);
            doAnswer(call->{application.close();return null;}).when(context).markApplicationContextDirty(any());
            doAnswer(call->{assertThat(application.isActive()).isFalse();assertThat(pool.isClosed()).isTrue();return null;}).when(lease).close();
            own(owner,lease);
            try{
                new FinanceScopedChainDatabase.Cleanup().afterTestClass(context);
                assertThat(application.isActive()).isFalse();assertThat(pool.isClosed()).isTrue();
                verify(pool,times(1)).close();verify(lease,times(1)).close();assertThat(owned().containsKey(owner)).isFalse();
                // A repeated cleanup no longer touches the context or the pool.
                new FinanceScopedChainDatabase.Cleanup().afterTestClass(context);verify(pool,times(1)).close();
            }finally{owned().remove(owner);}
        }finally{if(!pool.isClosed())pool.close();}
    }

    private static void own(Class<?> owner,MigratedSchemaBaseline.ScopedDatabase lease) throws Exception {
        var map=owned();Map.class.getMethod("put",Object.class,Object.class).invoke(map,owner,lease);
    }
    private static Map<?,?> owned() throws Exception {
        var field=FinanceScopedChainDatabase.class.getDeclaredField("OWNED");field.setAccessible(true);
        return (Map<?,?>)field.get(null);
    }
}
