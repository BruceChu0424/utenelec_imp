package com.uten.imp.features.reporting.export;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SubmitterPrincipalRestorer;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.dao.QueryTimeoutException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.*;
import org.springframework.transaction.support.SimpleTransactionStatus;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.io.OutputStream;
import java.nio.file.*;
import java.sql.ResultSet;
import java.time.OffsetDateTime;
import java.util.*;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** A normal MVCC read of RUNNING cannot resolve an in-flight COMMIT acknowledgement failure. */
@SuppressWarnings({"unchecked", "rawtypes"})
class ReportExportPublicationUncertaintyTest {
    @TempDir Path directory;
    private final ReportExportRepository repository = mock(ReportExportRepository.class);
    private final ReportExportService service = mock(ReportExportService.class);
    private final ReportExportSource source = mock(ReportExportSource.class);
    private final SubmitterPrincipalRestorer restorer = mock(SubmitterPrincipalRestorer.class);
    private final XlsxExportService xlsx = mock(XlsxExportService.class);
    private final JdbcTemplate jdbc = mock(JdbcTemplate.class);
    private final MetadataTransactions transactions = new MetadataTransactions();
    private ReportExportWorker worker;
    private ReportExportRepository.Job running;
    private Path candidate;
    private static final byte[] BYTES = {80, 75, 3, 4, 9};

    @BeforeEach void setup() throws Exception {
        UUID id = UUID.randomUUID(), owner = UUID.randomUUID();
        running = job(id, owner, "RUNNING"); candidate = directory.resolve(id + "-1.xlsx");
        var request = new ReportExportRequest(id, "sales", "ORDER/detail", Map.of(), null, null, null);
        when(service.artifact(running)).thenReturn(candidate); when(service.requireStorage()).thenReturn(directory);
        when(service.decode(running.request())).thenReturn(request);
        when(restorer.restore(owner, 1, 1L)).thenReturn(new AuthUser(owner, UUID.randomUUID(), "reader",
                Set.of("sales_report:view", "sales_report:export"), false, true, false));
        when(repository.heartbeat(eq(running), anyInt())).thenReturn(true);
        when(source.read(request)).thenReturn(new ExportPayload(List.of(new ExportColumn("n", "原文", ExportColumn.TEXT)),
                List.of(Map.of("n", "0001. 原文")), 1));
        var writer = mock(XlsxExportService.StreamingWorkbook.class); when(writer.rowCount()).thenReturn(1);
        when(xlsx.openStream(isNull(), eq("view_sales"), eq(directory))).thenReturn(writer);
        doAnswer(call -> { ((OutputStream) call.getArgument(0)).write(BYTES); return null; }).when(writer).finish(any());
        when(jdbc.queryForObject(anyString(), any(RowMapper.class))).thenAnswer(call -> {
            ResultSet row = mock(ResultSet.class); when(row.getObject("at", OffsetDateTime.class)).thenReturn(OffsetDateTime.now());
            when(row.getString("identity")).thenReturn("1:2:"); return ((RowMapper<?>) call.getArgument(1)).mapRow(row, 0);
        });
        when(repository.succeed(eq(running), eq(1), anyLong(), anyString())).thenAnswer(call -> {
            transactions.loseNextCommitAcknowledgement = true; return true;
        });
        worker = new ReportExportWorker(repository, service, source, restorer, xlsx, jdbc, transactions);
    }
    @AfterEach void close() {
        if (worker != null) worker.close();
        TransactionSynchronizationManager.clear();
    }

    @Test void aConfirmedSuccessfulCommitKeepsThePublishedFileAndDoesNotMarkFailure() throws Exception {
        when(repository.find(running.id())).thenReturn(Optional.of(job(running.id(), running.owner(), "SUCCEEDED")));
        run();
        assertThat(Files.readAllBytes(candidate)).isEqualTo(BYTES);
        verify(repository, never()).fail(any(), anyString());
    }

    @Test void staleRunningReadsAndATimedOutFailureUpdateKeepTheUnknownCandidate() throws Exception {
        when(repository.find(running.id())).thenReturn(Optional.of(running));
        doThrow(new QueryTimeoutException("An unresolved publication still owns the row lock"))
                .when(repository).fail(eq(running), anyString());
        run();
        assertThat(Files.readAllBytes(candidate)).isEqualTo(BYTES);
        assertThat(Files.exists(candidate.resolveSibling(candidate.getFileName() + ".part"))).isFalse();
    }

    @Test void anAuthoritativelyCancelledTaskCanRemoveItsReproducibleCandidate() {
        when(repository.find(running.id())).thenReturn(Optional.of(job(running.id(), running.owner(), "CANCELLED")));
        run();
        assertThat(Files.exists(candidate)).isFalse();
    }

    private void run() {
        try { ReflectionTestUtils.invokeMethod(worker, "run", running); }
        catch (RuntimeException ignored) { /* Availability may be unknown; it never authorizes deleting a pending candidate. */ }
        verify(repository).succeed(eq(running), eq(1), eq((long) BYTES.length), anyString());
    }
    private static ReportExportRepository.Job job(UUID id, UUID owner, String status) {
        String sha = null;
        if ("SUCCEEDED".equals(status)) {
            try { sha = HexFormat.of().formatHex(java.security.MessageDigest.getInstance("SHA-256").digest(BYTES)); }
            catch (java.security.GeneralSecurityException impossible) { throw new IllegalStateException(impossible); }
        }
        return new ReportExportRepository.Job(id, owner, 1, 1, "fixture-request", status, false, 1, 0,
                OffsetDateTime.now(), null, null, sha == null ? null : OffsetDateTime.now().plusHours(1), null, sha,
                sha == null ? 0 : BYTES.length, ReportExportBuildIdentity.CONTRACT, "fixture-build", "a".repeat(64));
    }

    /** Only transaction metadata is modeled; the test exercises real artifact move/cleanup and actual worker control flow. */
    private static final class MetadataTransactions implements PlatformTransactionManager {
        boolean loseNextCommitAcknowledgement;
        private static final class State extends SimpleTransactionStatus {
            final boolean active = TransactionSynchronizationManager.isActualTransactionActive();
            final boolean readOnly = TransactionSynchronizationManager.isCurrentTransactionReadOnly();
            final Integer isolation = TransactionSynchronizationManager.getCurrentTransactionIsolationLevel();
        }
        @Override public TransactionStatus getTransaction(TransactionDefinition definition) {
            State status = new State();
            TransactionSynchronizationManager.setActualTransactionActive(true);
            TransactionSynchronizationManager.setCurrentTransactionReadOnly(definition.isReadOnly());
            TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(
                    definition.getIsolationLevel() == TransactionDefinition.ISOLATION_DEFAULT ? null : definition.getIsolationLevel());
            return status;
        }
        @Override public void commit(TransactionStatus status) {
            restore((State) status);
            if (loseNextCommitAcknowledgement) {
                loseNextCommitAcknowledgement = false;
                throw new TransactionSystemException("COMMIT acknowledgement was lost; its result is unknown");
            }
        }
        @Override public void rollback(TransactionStatus status) { restore((State) status); }
        private static void restore(State status) {
            TransactionSynchronizationManager.setActualTransactionActive(status.active);
            TransactionSynchronizationManager.setCurrentTransactionReadOnly(status.readOnly);
            TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(status.isolation);
        }
    }
}
