package com.uten.imp.migration;

import org.flywaydb.core.api.CoreMigrationType;
import org.flywaydb.core.api.FlywayException;
import org.flywaydb.core.api.Location;
import org.flywaydb.core.api.MigrationInfo;
import org.flywaydb.core.api.MigrationVersion;
import org.flywaydb.core.api.callback.Context;
import org.flywaydb.core.api.callback.Event;
import org.flywaydb.core.internal.resolver.ChecksumCalculator;
import org.flywaydb.core.internal.resource.classpath.ClassPathResource;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.sql.Connection;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class ExpenseEventMigrationCompatibilityTest {
    @Test void originalChecksumsMatchTheOwningFlywayCalculatorAndOnlyTheEarlierVocabularyIsAdded() {
        for(String version:new String[]{"1000","1002"}) {
            var plan=ExpenseEventMigrationCompatibility.plan(version);
            var original=new ClassPathResource(Location.fromPath("classpath:","db/migration"),"db/migration/"+plan.script(),getClass().getClassLoader(),StandardCharsets.UTF_8);
            assertThat(plan.checksum()).isEqualTo(ChecksumCalculator.calculate(original));
            assertThat(plan.replacement()).isEqualTo(plan.original().substring(0,plan.original().lastIndexOf("))"))+",'PAYMENT_REVERSED'));");
            assertThat(plan.events()).contains("PAYMENT_REVERSED","STAGE_APPROVED");
            assertThat(plan.events()).hasSize(version.equals("1000")?9:10);
        }
    }

    @Test void callbackSupportsOnlyTheThreeRequiredLifecycleEventsOnTheTwoVersions() {
        var callback=new AppliedMigrationCompatibilityCallback();var context=mock(Context.class);var migration=mock(MigrationInfo.class);
        when(context.getMigrationInfo()).thenReturn(migration);
        for(String version:new String[]{"999.12","1000","1001","1002","1003","1051","1068","1069"}) {
            when(migration.getVersion()).thenReturn(MigrationVersion.fromVersion(version));
            for(Event event:new Event[]{Event.BEFORE_EACH_MIGRATE,Event.BEFORE_EACH_MIGRATE_STATEMENT,Event.AFTER_EACH_MIGRATE})
                assertThat(callback.supports(event,context)).as(version+":"+event).isEqualTo(version.equals("1000")||version.equals("1002"));
            assertThat(callback.supports(Event.BEFORE_MIGRATE,context)).isFalse();
            assertThat(callback.supports(Event.AFTER_EACH_MIGRATE_STATEMENT,context)).isFalse();
        }
    }

    @Test void wrongScriptChecksumOrTypeIsRejectedBeforeTouchingAnyConnection() {
        var context=context("1000");var migration=context.getMigrationInfo();var plan=ExpenseEventMigrationCompatibility.plan("1000");
        when(migration.getChecksum()).thenReturn(plan.checksum()+1);
        assertThatThrownBy(()->ExpenseEventMigrationCompatibility.handle(Event.BEFORE_EACH_MIGRATE,context)).isInstanceOf(FlywayException.class).hasMessageContaining("exact reviewed");
        when(migration.getChecksum()).thenReturn(plan.checksum());when(migration.getScript()).thenReturn("V1000__unrelated.sql");
        assertThatThrownBy(()->ExpenseEventMigrationCompatibility.handle(Event.BEFORE_EACH_MIGRATE,context)).isInstanceOf(FlywayException.class);
        when(migration.getScript()).thenReturn(plan.script());when(migration.getType()).thenReturn(CoreMigrationType.JDBC);
        assertThatThrownBy(()->ExpenseEventMigrationCompatibility.handle(Event.BEFORE_EACH_MIGRATE,context)).isInstanceOf(FlywayException.class);
        verify(context,never()).getConnection();
    }

    @Test void changedCheckTextAndAutocommitCannotUseTheReplacementWindow()throws Exception {
        var context=context("1002");var connection=mock(Connection.class);when(context.getConnection()).thenReturn(connection);
        var statement=mock(org.flywaydb.core.api.callback.Statement.class);when(context.getStatement()).thenReturn(statement);
        when(statement.getSql()).thenReturn(ExpenseEventMigrationCompatibility.plan("1002").original().replace("'ABANDONED'","'UNREVIEWED'"));
        assertThatThrownBy(()->ExpenseEventMigrationCompatibility.handle(Event.BEFORE_EACH_MIGRATE_STATEMENT,context)).isInstanceOf(FlywayException.class).hasMessageContaining("single reviewed");
        verify(connection,never()).createStatement();verify(connection,never()).prepareStatement(anyString());
        when(connection.getAutoCommit()).thenReturn(true);
        assertThatThrownBy(()->ExpenseEventMigrationCompatibility.handle(Event.BEFORE_EACH_MIGRATE,context)).isInstanceOf(FlywayException.class).hasMessageContaining("migration transaction");
    }

    private static Context context(String version) {
        var context=mock(Context.class);var migration=mock(MigrationInfo.class);var plan=ExpenseEventMigrationCompatibility.plan(version);
        when(context.getMigrationInfo()).thenReturn(migration);when(migration.getVersion()).thenReturn(MigrationVersion.fromVersion(version));
        when(migration.getScript()).thenReturn(plan.script());when(migration.getChecksum()).thenReturn(plan.checksum());when(migration.getType()).thenReturn(CoreMigrationType.SQL);
        var configuration=mock(org.flywaydb.core.api.configuration.Configuration.class);when(context.getConfiguration()).thenReturn(configuration);
        var loader=ExpenseEventMigrationCompatibilityTest.class.getClassLoader();when(configuration.getClassLoader()).thenReturn(loader);
        var resource=loader.getResource("db/migration/"+plan.script());assertThat(resource).isNotNull();
        when(migration.getPhysicalLocation()).thenReturn(new java.io.File(java.net.URLDecoder.decode(resource.getPath(),StandardCharsets.UTF_8)).getAbsolutePath());
        return context;
    }
}
