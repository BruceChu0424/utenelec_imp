package com.uten.imp.audit;

import org.junit.jupiter.api.Test;

import javax.sql.DataSource;
import java.sql.SQLException;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;

/**
 * 调度壳的两条规则(ADR-105); 分区搬迁与完成事件由 AuditRetentionPostgresTest 在真库上证明。
 */
class AuditRetentionSchedulerTest {

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
