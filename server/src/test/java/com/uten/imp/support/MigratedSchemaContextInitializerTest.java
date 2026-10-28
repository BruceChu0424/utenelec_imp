package com.uten.imp.support;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.util.TestPropertyValues;
import org.springframework.context.support.GenericApplicationContext;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class MigratedSchemaContextInitializerTest {
    @Test void bothPoolsCloseBeforeTheirLeaseAndFlywayCannotEscapeThePrivateFixture() throws Exception {
        var lease=mock(MigratedSchemaBaseline.ScopedDatabase.class);
        var closed=new AtomicBoolean();var order=new ArrayList<String>();
        when(lease.getJdbcUrl()).thenAnswer(call->{
            if(closed.get())throw new IllegalStateException("lease already closed");
            return "jdbc:postgresql://isolated.invalid/private_fixture";
        });
        when(lease.getUsername()).thenReturn("fixture-role");when(lease.getPassword()).thenReturn("fixture-only");
        doAnswer(call->{closed.set(true);order.add("lease");return null;}).when(lease).close();
        try(var baselines=mockStatic(MigratedSchemaBaseline.class);var context=new GenericApplicationContext()) {
            baselines.when(()->MigratedSchemaBaseline.openDatabase("spring_fixture")).thenReturn(lease);
            TestPropertyValues.of("spring.flyway.url=jdbc:postgresql://wrong.invalid/other",
                    "spring.flyway.user=external-migrator").applyTo(context.getEnvironment());
            new MigratedSchemaContextInitializer().initialize(context);
            context.registerBean("dataSource",DriverManagerDataSource.class,()->pool(lease,order,"dataSource"),
                    definition->definition.setDestroyMethodName("close"));
            context.registerBean("evidenceDataSource",DriverManagerDataSource.class,()->pool(lease,order,"evidenceDataSource"),
                    definition->{definition.setDependsOn("dataSource");definition.setDestroyMethodName("close");});
            context.refresh();
            assertEquals("jdbc:postgresql://isolated.invalid/private_fixture",context.getEnvironment().getProperty("spring.flyway.url"));
            assertEquals("fixture-role",context.getEnvironment().getProperty("spring.flyway.user"));
            assertEquals(context.getEnvironment().getProperty("spring.datasource.password"),context.getEnvironment().getProperty("spring.flyway.password"));
        }
        assertEquals(List.of("evidenceDataSource","dataSource","lease"),order);
        verify(lease,times(1)).close();
    }

    @Test void registrationFailureClosesTheAcquiredLeaseWithoutStartingAnyPool() throws Exception {
        var lease=mock(MigratedSchemaBaseline.ScopedDatabase.class);
        try(var baselines=mockStatic(MigratedSchemaBaseline.class);var context=new GenericApplicationContext()) {
            baselines.when(()->MigratedSchemaBaseline.openDatabase("spring_fixture")).thenReturn(lease);
            context.getDefaultListableBeanFactory().setAllowBeanDefinitionOverriding(false);
            context.registerBean("migratedSchemaDatabaseLease",Object.class,Object::new);
            assertThrows(RuntimeException.class,()->new MigratedSchemaContextInitializer().initialize(context));
            verify(lease).close();
        }
    }

    private static DriverManagerDataSource pool(MigratedSchemaBaseline.ScopedDatabase lease,List<String> order,String name) {
        return new DriverManagerDataSource() {
            public void close() {assertDoesNotThrow(lease::getJdbcUrl);order.add(name);}
        };
    }
}
