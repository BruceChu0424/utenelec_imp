package com.uten.imp.audit;

import org.junit.jupiter.api.Test;

import javax.sql.DataSource;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class AuditRetentionSchedulerTest {

    @Test
    void monthCutoffsUseShanghaiCalendarSemanticsAtMonthEnd() {
        Clock clock = Clock.fixed(
                Instant.parse("2026-03-30T19:17:00Z"),
                ZoneOffset.UTC);

        AuditRetentionScheduler.Cutoffs cutoffs =
                AuditRetentionScheduler.cutoffs(clock, 1, 2);

        assertEquals(
                Instant.parse("2026-02-27T19:17:00Z"),
                cutoffs.hotCutoff());
        assertEquals(
                Instant.parse("2025-12-30T19:17:00Z"),
                cutoffs.archiveCutoff());
    }

    @Test
    void invalidDatabaseSettingFailsClosedBeforeOpeningAConnection()
            throws Exception {
        DataSource dataSource = mock(DataSource.class);
        AuditRuntimeSettings settings = mock(AuditRuntimeSettings.class);
        AuditService audit = mock(AuditService.class);
        when(settings.hotRetentionMonths()).thenReturn(0);
        when(settings.archiveRetentionMonths()).thenReturn(30);
        AuditRetentionScheduler scheduler = new AuditRetentionScheduler(
                dataSource,
                settings,
                audit,
                Clock.fixed(
                        Instant.parse("2026-07-31T00:00:00Z"),
                        ZoneOffset.UTC));

        scheduler.runScheduled();

        verify(dataSource, never()).getConnection();
        verify(audit).logExplicit(
                eq(null),
                eq("system"),
                eq("audit_retention_failed"),
                eq("audit_retention"),
                contains("hotMonths=0"),
                eq("failure"));
    }

    @Test
    void successfulAutomaticRetentionDoesNotCreateUserActivityNoise()
            throws Exception {
        DataSource dataSource = mock(DataSource.class);
        AuditRuntimeSettings settings = mock(AuditRuntimeSettings.class);
        AuditService audit = mock(AuditService.class);
        when(settings.hotRetentionMonths()).thenReturn(6);
        when(settings.archiveRetentionMonths()).thenReturn(30);
        AuditRetentionScheduler scheduler = new AuditRetentionScheduler(
                dataSource,
                settings,
                audit,
                Clock.fixed(Instant.parse("2026-07-31T00:00:00Z"), ZoneOffset.UTC)) {
            @Override
            RetentionResult execute(Cutoffs cutoffs) {
                return new RetentionResult(true, 10, 10, 2);
            }
        };

        scheduler.runScheduled();

        verifyNoInteractions(audit);
    }
}
