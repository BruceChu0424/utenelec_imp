package com.uten.imp.audit;

import org.junit.jupiter.api.Test;

import javax.sql.DataSource;
import java.sql.SQLException;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.never;

/**
 * 调度壳的两条规则(ADR-105); 分区搬迁与完成事件由 AuditRetentionPostgresTest 在真库上证明。
 */
class AuditRetentionSchedulerTest {

    @Test
    void legacyDestructiveAndUnknownCapabilitiesCannotExecuteMaintenance() throws Exception {
        for(String mode:new String[]{"LEGACY_PURGE","UNKNOWN",null}) {
            DataSource source=mock(DataSource.class);Connection connection=mock(Connection.class);
            PreparedStatement lock=mock(PreparedStatement.class),capability=mock(PreparedStatement.class),unlock=mock(PreparedStatement.class);
            ResultSet lockResult=mock(ResultSet.class),modeResult=mock(ResultSet.class);
            when(source.getConnection()).thenReturn(connection);
            when(connection.prepareStatement("SELECT pg_try_advisory_lock(?)")).thenReturn(lock);
            when(connection.prepareStatement("SELECT pg_advisory_unlock(?)")).thenReturn(unlock);
            when(connection.prepareStatement(AuditRetentionModeReader.READ_MODE_SQL)).thenReturn(capability);
            when(lock.executeQuery()).thenReturn(lockResult);when(lockResult.next()).thenReturn(true);when(lockResult.getBoolean(1)).thenReturn(true);
            when(capability.executeQuery()).thenReturn(modeResult);when(modeResult.next()).thenReturn(true);when(modeResult.getString(1)).thenReturn(mode);
            var scheduler=new AuditRetentionScheduler(source,mock(AuditService.class));
            assertThrows(SQLException.class,scheduler::execute);
            verify(connection,never()).prepareStatement(contains("FROM fn_audit_retention_run()"));
            verify(unlock).executeQuery();
        }
    }

    @Test
    void failureIsRecordedIndependentlyAndSurfacedToTheScheduler() {
        AuditService audit = mock(AuditService.class);
        AuditRetentionScheduler scheduler = new AuditRetentionScheduler(mock(DataSource.class), audit) {
            @Override
            RetentionResult execute() throws SQLException {
                throw new SQLException("audit retention months out of range: hot=0, archive=30");
            }
        };

        assertThrows(IllegalStateException.class, scheduler::runScheduled,
                "失败必须抛给调度器, 服务器状态页才会显示后台任务失败");

        verify(audit).logExplicit(
                eq(null),
                eq("system"),
                eq("audit_retention_failed"),
                eq("audit_retention"),
                contains("hot=0"),
                eq("failure"));
    }

    @Test
    void successEvidenceIsWrittenByTheDatabaseFunctionNotDuplicatedInJava() {
        AuditService audit = mock(AuditService.class);
        AuditRetentionScheduler scheduler = new AuditRetentionScheduler(mock(DataSource.class), audit) {
            @Override
            RetentionResult execute() {
                return new RetentionResult(true, 6, 30, List.of("audit_log_archive_p202601"), 10,
                        List.of(), 0, List.of("audit_log_p202610"), 42L);
            }
        };

        scheduler.runScheduled();

        verifyNoInteractions(audit);
    }
}
