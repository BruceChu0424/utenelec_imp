package com.uten.imp.migration;

import org.flywaydb.core.api.MigrationInfo;
import org.flywaydb.core.api.MigrationVersion;
import org.flywaydb.core.api.callback.Context;
import org.flywaydb.core.api.callback.Event;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class AppliedMigrationAuditOverloadCompatibilityTest {
    @Test void compatibilityIsLimitedToBeforeTheTwoImmutableAuditRegistrations() {
        var callback = new AppliedMigrationCompatibilityCallback();
        var context = mock(Context.class);
        var migration = mock(MigrationInfo.class);
        when(context.getMigrationInfo()).thenReturn(migration);
        for (String version : new String[]{"845", "846", "847", "848", "849", "850", "851", "852"}) {
            when(migration.getVersion()).thenReturn(MigrationVersion.fromVersion(version));
            assertEquals(version.equals("846") || version.equals("851"), callback.supports(Event.BEFORE_EACH_MIGRATE, context), version);
            assertFalse(callback.supports(Event.AFTER_EACH_MIGRATE, context), version);
            assertFalse(callback.supports(Event.BEFORE_MIGRATE, context), version);
        }
        assertTrue(callback.canHandleInTransaction(Event.BEFORE_EACH_MIGRATE, context));
    }
}
