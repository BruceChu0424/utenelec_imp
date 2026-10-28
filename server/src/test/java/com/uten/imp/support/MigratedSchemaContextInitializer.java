package com.uten.imp.support;

import java.util.Arrays;
import java.util.LinkedHashSet;
import org.springframework.beans.factory.support.BeanDefinitionRegistry;
import org.springframework.beans.factory.support.RootBeanDefinition;
import org.springframework.boot.test.util.TestPropertyValues;
import org.springframework.context.ApplicationContextInitializer;
import org.springframework.context.ConfigurableApplicationContext;

/** A private current-schema lease belongs to one Spring context, after all of its pools close. */
public class MigratedSchemaContextInitializer implements ApplicationContextInitializer<ConfigurableApplicationContext> {
    protected String databaseLabel() { return "spring_fixture"; }
    protected String leaseBeanName() { return "migratedSchemaDatabaseLease"; }

    @Override public final void initialize(ConfigurableApplicationContext context) {
        final MigratedSchemaBaseline.ScopedDatabase database;
        try { database=MigratedSchemaBaseline.openDatabase(databaseLabel()); }
        catch(java.sql.SQLException failure) { throw new IllegalStateException("Cannot create isolated fixture database",failure); }
        String leaseName=leaseBeanName();
        try {
            var definition=new RootBeanDefinition(MigratedSchemaBaseline.ScopedDatabase.class,()->database);
            definition.setDestroyMethodName("close");
            ((BeanDefinitionRegistry)context.getBeanFactory()).registerBeanDefinition(leaseName,definition);
            TestPropertyValues.of("spring.datasource.url="+database.getJdbcUrl(),
                    "spring.datasource.username="+database.getUsername(),"spring.datasource.password="+database.getPassword(),
                    "spring.flyway.url="+database.getJdbcUrl(),"spring.flyway.user="+database.getUsername(),
                    "spring.flyway.password="+database.getPassword()).applyTo(context.getEnvironment());
            context.addBeanFactoryPostProcessor(factory->{
                for(String name:factory.getBeanNamesForType(javax.sql.DataSource.class,true,false)) {
                    factory.registerDependentBean(leaseName,name);
                    if(factory.containsBeanDefinition(name)) {
                        var source=factory.getBeanDefinition(name);
                        var dependencies=new LinkedHashSet<String>();
                        if(source.getDependsOn()!=null)dependencies.addAll(Arrays.asList(source.getDependsOn()));
                        dependencies.add(leaseName);source.setDependsOn(dependencies.toArray(String[]::new));
                    }
                }
            });
        } catch(RuntimeException|Error failure) {
            try { database.close(); } catch(java.sql.SQLException cleanup) { failure.addSuppressed(cleanup); }
            throw failure;
        }
    }
}
