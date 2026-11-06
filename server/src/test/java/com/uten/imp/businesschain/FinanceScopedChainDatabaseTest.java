package com.uten.imp.businesschain;

import com.uten.imp.support.MigratedSchemaBaseline;
import com.zaxxer.hikari.HikariDataSource;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.jupiter.api.Test;
import org.springframework.context.support.GenericApplicationContext;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class FinanceScopedChainDatabaseTest {
    @Test void allPoolsCloseBeforeTheContextOwnedLease() throws Exception {
        var lease=mock(MigratedSchemaBaseline.ScopedDatabase.class);
        var closed=new AtomicBoolean();var order=new ArrayList<String>();
        when(lease.getJdbcUrl()).thenAnswer(call->{
            if(closed.get()) { throw new IllegalStateException("retired lease"); }
            return "jdbc:postgresql://isolated.invalid/finance_context";
        });
        when(lease.getUsername()).thenReturn("fixture-role");when(lease.getPassword()).thenReturn("fixture-only");
        doAnswer(call->{closed.set(true);order.add("lease");return null;}).when(lease).close();
        try(var baselines=mockStatic(MigratedSchemaBaseline.class);var context=new GenericApplicationContext()) {
            baselines.when(()->MigratedSchemaBaseline.openDatabase("finance_chain")).thenReturn(lease);
            new FinanceScopedChainDatabase.Initializer().initialize(context);
            context.registerBean("dataSource",HikariDataSource.class,()->pool(lease,order,"primary"),
                    definition->definition.setDestroyMethodName("close"));
            context.registerBean("evidenceDataSource",HikariDataSource.class,()->pool(lease,order,"evidence"),
                    definition->{definition.setDependsOn("dataSource");definition.setDestroyMethodName("close");});
            context.refresh();
            assertThat(context.getBean(FinanceScopedChainDatabase.LEASE_BEAN)).isSameAs(lease);
        }
        assertThat(order).containsExactly("evidence","primary","lease");
        verify(lease,times(1)).close();
    }

    @Test void rebuildingAContextAcquiresANewLeaseInsteadOfReusingARetiredClassLease() throws Exception {
        var first=mock(MigratedSchemaBaseline.ScopedDatabase.class);
        var second=mock(MigratedSchemaBaseline.ScopedDatabase.class);
        for(var lease:List.of(first,second)) {
            when(lease.getJdbcUrl()).thenReturn("jdbc:postgresql://isolated.invalid/finance_context");
            when(lease.getUsername()).thenReturn("fixture-role");when(lease.getPassword()).thenReturn("fixture-only");
        }
        try(var baselines=mockStatic(MigratedSchemaBaseline.class)) {
            baselines.when(()->MigratedSchemaBaseline.openDatabase("finance_chain")).thenReturn(first,second);
            try(var context=new GenericApplicationContext()) {
                new FinanceScopedChainDatabase.Initializer().initialize(context);context.refresh();
                assertThat(context.getBean(FinanceScopedChainDatabase.LEASE_BEAN)).isSameAs(first);
            }
            verify(first,times(1)).close();verify(second,never()).close();
            try(var context=new GenericApplicationContext()) {
                new FinanceScopedChainDatabase.Initializer().initialize(context);context.refresh();
                assertThat(context.getBean(FinanceScopedChainDatabase.LEASE_BEAN)).isSameAs(second);
            }
            verify(second,times(1)).close();
        }
    }

    private static HikariDataSource pool(MigratedSchemaBaseline.ScopedDatabase lease,List<String> order,String name) {
        var pool=mock(HikariDataSource.class);
        doAnswer(call->{assertThatCode(lease::getJdbcUrl).doesNotThrowAnyException();order.add(name);return null;}).when(pool).close();
        return pool;
    }

    @Test void aClosedFlagCannotHideAnActuallyLivePoolAtTheClassBoundary() throws Exception {
        var lease=mock(MigratedSchemaBaseline.ScopedDatabase.class);
        when(lease.getJdbcUrl()).thenReturn("jdbc:postgresql://isolated.invalid/finance_context");
        when(lease.getUsername()).thenReturn("fixture-role");when(lease.getPassword()).thenReturn("fixture-only");
        var source=mock(HikariDataSource.class);var physical=mock(com.zaxxer.hikari.HikariPoolMXBean.class);
        when(source.getJdbcUrl()).thenAnswer(call->lease.getJdbcUrl());when(source.getHikariPoolMXBean()).thenReturn(physical);
        when(physical.getTotalConnections()).thenReturn(4);
        var closed=new AtomicBoolean();when(source.isClosed()).thenAnswer(call->closed.get());
        doAnswer(call->{closed.set(true);return null;}).when(source).close();
        var attributes=new java.util.HashMap<String,Object>();
        var test=mock(org.springframework.test.context.TestContext.class);
        when(test.hasApplicationContext()).thenReturn(true);doReturn(FinanceScopedChainDatabaseTest.class).when(test).getTestClass();
        when(test.getAttribute(anyString())).thenAnswer(call->attributes.get(call.getArgument(0)));
        doAnswer(call->{attributes.put(call.getArgument(0),call.getArgument(1));return null;}).when(test).setAttribute(anyString(),any());
        when(test.removeAttribute(anyString())).thenAnswer(call->attributes.remove(call.getArgument(0)));
        var boundary=new FinanceScopedChainDatabase.BoundaryEvidence();
        try(var baselines=mockStatic(MigratedSchemaBaseline.class);var context=new GenericApplicationContext()) {
            baselines.when(()->MigratedSchemaBaseline.openDatabase("finance_chain")).thenReturn(lease);
            new FinanceScopedChainDatabase.Initializer().initialize(context);
            context.registerBean("dataSource",HikariDataSource.class,()->source,definition->definition.setDestroyMethodName("close"));
            context.refresh();when(test.getApplicationContext()).thenReturn(context);boundary.beforeTestMethod(test);
            context.close();
        }
        assertThat(closed).isTrue();
        assertThatThrownBy(()->boundary.afterTestClass(test)).isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("actual pool alive");
    }
}
